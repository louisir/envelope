using Envelope.Windows.Core.Security;

namespace Envelope.Windows.Services;

/// <summary>
/// Coalesces concurrent app-unlock requests and records only positively
/// verified unlocks. A canceled or failed prompt can never be consumed as a
/// successful resume token.
/// </summary>
public sealed class LocalUnlockCoordinator(ILocalUnlockGuard inner) : ILocalUnlockGuard
{
    private readonly ILocalUnlockGuard _inner = inner ?? throw new ArgumentNullException(nameof(inner));
    private readonly object _sync = new();
    private Task? _currentUnlock;
    private long _lastSuccessfulUnlockUnixMs;

    public bool IsUnlockInProgress
    {
        get
        {
            lock (_sync) return _currentUnlock is { IsCompleted: false };
        }
    }

    public bool WasSuccessfullyUnlockedWithin(TimeSpan interval)
    {
        var value = Interlocked.Read(ref _lastSuccessfulUnlockUnixMs);
        return value > 0 &&
               DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds(value) <= interval;
    }

    public Task WaitForCurrentUnlockAsync(CancellationToken cancellationToken = default)
    {
        Task? current;
        lock (_sync) current = _currentUnlock;
        return current is null
            ? Task.CompletedTask
            : current.WaitAsync(cancellationToken);
    }

    public Task RequireUnlockAsync(
        bool localLockEnabled,
        string message,
        CancellationToken cancellationToken = default)
    {
        if (!localLockEnabled) return Task.CompletedTask;

        Task operation;
        lock (_sync)
        {
            if (_currentUnlock is { IsCompleted: false } current)
            {
                operation = current;
            }
            else
            {
                var completion = new TaskCompletionSource(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                operation = completion.Task;
                _currentUnlock = operation;
                _ = RunUnlockAsync(completion, message, cancellationToken);
            }
        }
        return operation.WaitAsync(cancellationToken);
    }

    private async Task RunUnlockAsync(
        TaskCompletionSource completion,
        string message,
        CancellationToken cancellationToken)
    {
        try
        {
            await _inner.RequireUnlockAsync(true, message, cancellationToken).ConfigureAwait(false);
            Interlocked.Exchange(
                ref _lastSuccessfulUnlockUnixMs,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            completion.TrySetResult();
        }
        catch (OperationCanceledException error)
        {
            completion.TrySetCanceled(error.CancellationToken);
        }
        catch (Exception error)
        {
            completion.TrySetException(error);
        }
    }
}
