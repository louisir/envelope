using Envelope.Windows.Core.Security;
using Envelope.Windows.Services;

namespace Envelope.Windows.Tests;

internal static class LocalUnlockCoordinatorVerification
{
    public static async Task RunAsync()
    {
        var controlled = new ControlledGuard();
        var coordinator = new LocalUnlockCoordinator(controlled);
        var first = coordinator.RequireUnlockAsync(true, "first");
        var second = coordinator.RequireUnlockAsync(true, "second");
        Require(controlled.CallCount == 1, "concurrent Hello requests are coalesced");
        Require(coordinator.IsUnlockInProgress, "unlock is reported in progress");
        var current = coordinator.WaitForCurrentUnlockAsync();
        controlled.Succeed();
        await Task.WhenAll(first, second, current).WaitAsync(TimeSpan.FromSeconds(2));
        Require(!coordinator.IsUnlockInProgress, "successful unlock completes");
        Require(coordinator.WasSuccessfullyUnlockedWithin(TimeSpan.FromSeconds(2)),
            "only a verified unlock creates a resume token");

        var deniedGuard = new ControlledGuard();
        var deniedCoordinator = new LocalUnlockCoordinator(deniedGuard);
        var denied = deniedCoordinator.RequireUnlockAsync(true, "denied");
        deniedGuard.Fail();
        await ExpectAsync<LocalUnlockDeniedException>(denied, "failed Hello remains failed");
        await ExpectAsync<LocalUnlockDeniedException>(
            deniedCoordinator.WaitForCurrentUnlockAsync(),
            "resume joins and observes the failed Hello result");
        Require(!deniedCoordinator.WasSuccessfullyUnlockedWithin(TimeSpan.FromMinutes(1)),
            "failed Hello does not create a resume token");

        Console.WriteLine("[PASS] Windows Hello application-session coordinator verification");
    }

    private sealed class ControlledGuard : ILocalUnlockGuard
    {
        private readonly TaskCompletionSource _completion = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public int CallCount { get; private set; }

        public Task RequireUnlockAsync(
            bool localLockEnabled,
            string message,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return _completion.Task.WaitAsync(cancellationToken);
        }

        public void Succeed() => _completion.TrySetResult();

        public void Fail() => _completion.TrySetException(new LocalUnlockDeniedException(
            "denied",
            LocalUnlockVerificationStatus.Canceled));
    }

    private static async Task ExpectAsync<T>(Task task, string label) where T : Exception
    {
        try
        {
            await task;
        }
        catch (T)
        {
            return;
        }
        throw new InvalidOperationException(
            $"Verification failed: {label}; expected {typeof(T).Name}.");
    }

    private static void Require(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException($"Verification failed: {label}.");
    }
}
