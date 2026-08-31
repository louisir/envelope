using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Envelope.Windows.Core.Networking;

public delegate Task<EnvelopeP2pAck> EnvelopeP2pEnvelopeHandler(
    ReadOnlyMemory<byte> envelopeBytes,
    CancellationToken cancellationToken);

/// <summary>
/// TCP v1 peer-to-peer transport used by the Android client. Each message is one
/// unsigned 32-bit big-endian length followed by an opaque envelope; the response
/// uses the same framing and contains a JSON acknowledgement.
/// </summary>
public sealed class EnvelopeP2pTransport : IAsyncDisposable
{
    public static readonly TimeSpan DefaultTicketTtl = TimeSpan.FromMinutes(30);
    public static readonly TimeSpan DefaultTicketRefreshBefore = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan FastAttemptTimeout = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan ListenerFrameTimeout = TimeSpan.FromSeconds(15);
    public const int MaximumConcurrentConnections = 16;

    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _connectionSlots = new(MaximumConcurrentConnections, MaximumConcurrentConnections);
    private readonly ConcurrentDictionary<long, Task> _connectionTasks = new();

    private TcpListener? _listener;
    private CancellationTokenSource? _listenerCancellation;
    private Task? _acceptLoopTask;
    private EnvelopeP2pEnvelopeHandler? _handler;
    private EnvelopeP2pStatus? _status;
    private long _nextConnectionId;
    private bool _disposed;

    public bool IsListening => _listener is not null;

    public EnvelopeP2pStatus? Status => _status;

    public int ActiveConnectionCount => MaximumConcurrentConnections - _connectionSlots.CurrentCount;

    public async Task<EnvelopeP2pStatus> StartAsync(
        string deviceId,
        EnvelopeP2pEnvelopeHandler onEnvelope,
        TimeSpan? ticketTtl = null,
        TimeSpan? refreshBefore = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceId);
        ArgumentNullException.ThrowIfNull(onEnvelope);
        var ttl = ticketTtl ?? DefaultTicketTtl;
        var refreshWindow = refreshBefore ?? DefaultTicketRefreshBefore;
        if (ttl <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(ticketTtl), "Ticket TTL must be positive.");
        }

        if (refreshWindow < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(refreshBefore), "Refresh window cannot be negative.");
        }

        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_listener is not null
                && _status is not null
                && !_status.ShouldRefreshAt(DateTimeOffset.UtcNow, refreshWindow))
            {
                _handler = onEnvelope;
                return _status;
            }

            await StopCoreAsync().ConfigureAwait(false);

            var listener = new TcpListener(IPAddress.Any, 0);
            try
            {
                listener.Start();
                var port = ((IPEndPoint)listener.LocalEndpoint).Port;
                var addresses = LocalIpv4Addresses();
                var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                var ticket = new EnvelopeP2pTicket(
                    deviceId,
                    addresses,
                    port,
                    now,
                    checked(now + (long)ttl.TotalMilliseconds));
                var status = new EnvelopeP2pStatus(
                    true,
                    ticket.Encode(),
                    addresses,
                    port,
                    ticket.ExpiresAtUnixMs);

                var listenerCancellation = new CancellationTokenSource();
                _handler = onEnvelope;
                _listener = listener;
                _listenerCancellation = listenerCancellation;
                _status = status;
                _acceptLoopTask = AcceptLoopAsync(listener, listenerCancellation.Token);
                return status;
            }
            catch
            {
                listener.Stop();
                throw;
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task<EnvelopeP2pStatus> RestartAsync(
        string deviceId,
        EnvelopeP2pEnvelopeHandler onEnvelope,
        TimeSpan? ticketTtl = null,
        CancellationToken cancellationToken = default)
    {
        await StopAsync().ConfigureAwait(false);
        return await StartAsync(deviceId, onEnvelope, ticketTtl, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task StopAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await StopCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task<EnvelopeP2pAck> SendEnvelopeAsync(
        string ticket,
        ReadOnlyMemory<byte> envelopeBytes,
        string expectedEnvelopeId,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedEnvelopeId);
        var parsed = EnvelopeP2pTicket.Parse(ticket);
        if (parsed.IsExpired)
        {
            throw new EnvelopeP2pException("P2P ticket has expired; wait for route refresh and retry.");
        }

        if (envelopeBytes.Length > EnvelopeProtocol.MaxEnvelopeBytes)
        {
            throw new EnvelopeP2pException("Opaque envelope exceeds the 8 MiB P2P frame limit.");
        }

        var operationTimeout = timeout ?? FastAttemptTimeout;
        if (operationTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout), "Attempt timeout must be positive.");
        }

        Exception? lastError = null;
        foreach (var address in parsed.Addresses)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var client = new TcpClient();
                await WithTimeoutAsync(
                    token => client.ConnectAsync(address, parsed.Port, token).AsTask(),
                    operationTimeout,
                    cancellationToken).ConfigureAwait(false);
                using var stream = client.GetStream();
                await WithTimeoutAsync(
                    token => WriteFrameAsync(stream, envelopeBytes, token),
                    operationTimeout,
                    cancellationToken).ConfigureAwait(false);
                var acknowledgementBytes = await WithTimeoutAsync(
                    token => ReadFrameAsync(stream, token),
                    operationTimeout,
                    cancellationToken).ConfigureAwait(false);
                var acknowledgement = EnvelopeP2pAck.FromJsonBytes(acknowledgementBytes);
                if (!acknowledgement.IsOk)
                {
                    throw new EnvelopeP2pException(
                        $"P2P delivery was rejected: {acknowledgement.Detail}");
                }
                if (!FixedTimeEquals(acknowledgement.EnvelopeId, expectedEnvelopeId))
                    throw new EnvelopeP2pException("P2P acknowledgement envelope_id does not match the sent envelope.");

                return acknowledgement;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception error)
            {
                lastError = error;
            }
        }

        throw new EnvelopeP2pException(
            $"P2P connection failed: {lastError?.Message ?? "no address"}",
            lastError ?? new InvalidOperationException("No P2P address was attempted."));
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            await StopCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    internal static async Task WriteFrameAsync(
        Stream stream,
        ReadOnlyMemory<byte> payload,
        CancellationToken cancellationToken)
    {
        if (payload.Length > EnvelopeProtocol.MaxEnvelopeBytes)
        {
            throw new EnvelopeP2pException($"P2P frame is too large: {payload.Length} bytes.");
        }

        var header = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)payload.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    internal static async Task<byte[]> ReadFrameAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(uint)];
        await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
        var frameLength = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (frameLength > EnvelopeProtocol.MaxEnvelopeBytes)
        {
            throw new EnvelopeP2pException($"P2P frame is too large: {frameLength} bytes.");
        }

        var payload = GC.AllocateUninitializedArray<byte>((int)frameLength);
        await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        return payload;
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                if (!_connectionSlots.Wait(0))
                {
                    client.Dispose();
                    continue;
                }
                var connectionId = Interlocked.Increment(ref _nextConnectionId);
                var task = HandleClientWithSlotAsync(client, cancellationToken);
                _connectionTasks[connectionId] = task;
                _ = task.ContinueWith(
                    completedTask => _connectionTasks.TryRemove(connectionId, out _),
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (SocketException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task HandleClientWithSlotAsync(TcpClient client, CancellationToken listenerCancellation)
    {
        try
        {
            await HandleClientAsync(client, listenerCancellation).ConfigureAwait(false);
        }
        finally
        {
            _connectionSlots.Release();
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken listenerCancellation)
    {
        using (client)
        using (var stream = client.GetStream())
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(listenerCancellation))
        {
            timeout.CancelAfter(ListenerFrameTimeout);
            try
            {
                var handler = _handler;
                if (handler is null)
                {
                    await WriteFrameAsync(
                        stream,
                        EnvelopeP2pAck.Error(string.Empty, "P2P listener unavailable.").ToJsonBytes(),
                        timeout.Token).ConfigureAwait(false);
                    return;
                }

                var payload = await ReadFrameAsync(stream, timeout.Token).ConfigureAwait(false);
                var acknowledgement = await handler(payload, timeout.Token).ConfigureAwait(false);
                await WriteFrameAsync(stream, acknowledgement.ToJsonBytes(), timeout.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (listenerCancellation.IsCancellationRequested)
            {
            }
            catch (Exception error)
            {
                try
                {
                    using var errorTimeout = new CancellationTokenSource(ListenerFrameTimeout);
                    await WriteFrameAsync(
                        stream,
                        EnvelopeP2pAck.Error(string.Empty, error.Message).ToJsonBytes(),
                        errorTimeout.Token).ConfigureAwait(false);
                }
                catch
                {
                    // The peer may already have disconnected; there is no second recovery channel.
                }
            }
        }
    }

    private async Task StopCoreAsync()
    {
        var cancellation = _listenerCancellation;
        var listener = _listener;
        var acceptLoopTask = _acceptLoopTask;

        _listenerCancellation = null;
        _listener = null;
        _acceptLoopTask = null;
        _handler = null;
        _status = null;

        if (listener is null && cancellation is null)
        {
            return;
        }

        cancellation?.Cancel();
        listener?.Stop();
        if (acceptLoopTask is not null)
        {
            try
            {
                await acceptLoopTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }

        var connections = _connectionTasks.Values.ToArray();
        if (connections.Length > 0)
        {
            try
            {
                await Task.WhenAll(connections).ConfigureAwait(false);
            }
            catch
            {
                // Per-connection errors are converted to protocol error acknowledgements.
            }
        }

        cancellation?.Dispose();
    }

    private static bool FixedTimeEquals(string actual, string expected)
    {
        var actualBytes = Encoding.UTF8.GetBytes(actual);
        var expectedBytes = Encoding.UTF8.GetBytes(expected);
        return actualBytes.Length == expectedBytes.Length &&
               CryptographicOperations.FixedTimeEquals(actualBytes, expectedBytes);
    }

    private static IReadOnlyList<string> LocalIpv4Addresses()
    {
        var records = new List<(string Address, int Priority)>();
        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.OperationalStatus != OperationalStatus.Up
                || networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            try
            {
                var priority = InterfacePriority(networkInterface.NetworkInterfaceType);
                foreach (var unicast in networkInterface.GetIPProperties().UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily == AddressFamily.InterNetwork
                        && !IPAddress.IsLoopback(address))
                    {
                        records.Add((address.ToString(), priority));
                    }
                }
            }
            catch (NetworkInformationException)
            {
            }
        }

        return records
            .OrderBy(record => record.Priority)
            .ThenBy(record => record.Address, StringComparer.Ordinal)
            .Select(record => record.Address)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
    }

    private static int InterfacePriority(NetworkInterfaceType type) => type switch
    {
        NetworkInterfaceType.Wireless80211 => 0,
        NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet => 1,
        NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp => 9,
        _ => 5,
    };

    private static async Task ReadExactlyAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer[offset..], cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EnvelopeP2pException("P2P connection closed before the full frame arrived.");
            }

            offset += read;
        }
    }

    private static async Task WithTimeoutAsync(
        Func<CancellationToken, Task> operation,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        operationCancellation.CancelAfter(timeout);
        try
        {
            await operation(operationCancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"P2P operation timed out after {timeout.TotalSeconds:0.###} seconds.", error);
        }
    }

    private static async Task<T> WithTimeoutAsync<T>(
        Func<CancellationToken, Task<T>> operation,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        operationCancellation.CancelAfter(timeout);
        try
        {
            return await operation(operationCancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"P2P operation timed out after {timeout.TotalSeconds:0.###} seconds.", error);
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
