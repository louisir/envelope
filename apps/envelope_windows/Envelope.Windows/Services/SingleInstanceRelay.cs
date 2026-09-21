using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Envelope.Windows.Services;

public sealed class SingleInstanceRelay : IAsyncDisposable
{
    private const int MaximumPayloadBytes = 64 * 1024;
    private readonly string _pipeName;
    private readonly Func<IReadOnlyList<string>, Task> _handler;
    private readonly CancellationTokenSource _stopping = new();
    private Task? _listenTask;

    public SingleInstanceRelay(
        string pipeName,
        Func<IReadOnlyList<string>, Task> handler)
    {
        _pipeName = pipeName;
        _handler = handler;
    }

    public static string PipeNameFor(string privateRoot)
    {
        var scope = $"{Environment.UserDomainName}\\{Environment.UserName}|{Path.GetFullPath(privateRoot)}";
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(scope))).ToLowerInvariant();
        return $"westwardsoft-envelope-{digest[..24]}";
    }

    public void Start()
    {
        _listenTask ??= Task.Run(ListenAsync);
    }

    public static async Task<bool> TrySendAsync(
        string pipeName,
        IReadOnlyList<string> arguments,
        TimeSpan timeout)
    {
        try
        {
            var payload = JsonSerializer.SerializeToUtf8Bytes(arguments);
            if (payload.Length > MaximumPayloadBytes)
                return false;

            using var timeoutSource = new CancellationTokenSource(timeout);
            await using var client = new NamedPipeClientStream(
                ".",
                pipeName,
                PipeDirection.Out,
                PipeOptions.Asynchronous);
            await client.ConnectAsync(timeoutSource.Token).ConfigureAwait(false);
            await client.WriteAsync(payload, timeoutSource.Token).ConfigureAwait(false);
            await client.FlushAsync(timeoutSource.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception error) when (
            error is IOException or OperationCanceledException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task ListenAsync()
    {
        while (!_stopping.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    _pipeName,
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(_stopping.Token).ConfigureAwait(false);
                using var buffer = new MemoryStream();
                var chunk = new byte[4096];
                while (buffer.Length <= MaximumPayloadBytes)
                {
                    var read = await server.ReadAsync(chunk, _stopping.Token).ConfigureAwait(false);
                    if (read == 0) break;
                    await buffer.WriteAsync(chunk.AsMemory(0, read), _stopping.Token).ConfigureAwait(false);
                }
                if (buffer.Length > MaximumPayloadBytes)
                    continue;

                var arguments = JsonSerializer.Deserialize<string[]>(buffer.ToArray());
                if (arguments is not null)
                    _ = DispatchAsync(arguments);
            }
            catch (OperationCanceledException) when (_stopping.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error) when (error is IOException or JsonException)
            {
                // Keep the primary instance available after malformed or interrupted local requests.
            }
        }
    }

    private async Task DispatchAsync(IReadOnlyList<string> arguments)
    {
        try { await _handler(arguments).ConfigureAwait(false); }
        catch (Exception)
        {
            // The UI may be closing while a secondary launch request is in flight.
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (!_stopping.IsCancellationRequested)
            _stopping.Cancel();
        if (_listenTask is not null)
        {
            try { await _listenTask.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _stopping.Dispose();
    }
}
