using Envelope.Windows.Core.Security;
using System.Security.Principal;

namespace Envelope.Windows.Tests;

internal static class LocalUnlockFallbackVerification
{
    public static async Task RunAsync()
    {
        foreach (var missing in new[] { LocalUnlockAvailabilityStatus.DeviceNotPresent,
                     LocalUnlockAvailabilityStatus.NotConfiguredForUser, LocalUnlockAvailabilityStatus.RuntimeUnavailable })
        {
            var hello = new Verifier(missing, LocalUnlockVerificationStatus.Error);
            var password = new Verifier(LocalUnlockAvailabilityStatus.Available, LocalUnlockVerificationStatus.Verified);
            await new LocalUnlockGuard(new FallbackLocalUnlockService(hello, password)).RequireUnlockAsync(true, "verify");
            Require(password.Calls == 1 && hello.Calls == 0, "unavailable Hello uses Windows credential verification");
        }
        foreach (var blocked in new[] { LocalUnlockAvailabilityStatus.DisabledByPolicy,
                     LocalUnlockAvailabilityStatus.DeviceBusy, LocalUnlockAvailabilityStatus.Error })
        {
            var fallback = new Verifier(LocalUnlockAvailabilityStatus.Available, LocalUnlockVerificationStatus.Verified);
            await Denied(new LocalUnlockGuard(new FallbackLocalUnlockService(new Verifier(blocked, LocalUnlockVerificationStatus.Error), fallback)));
            Require(fallback.Calls == 0, "policy and transient failures cannot trigger fallback");
        }
        foreach (var result in Enum.GetValues<LocalUnlockVerificationStatus>().Where(x => x != LocalUnlockVerificationStatus.Verified))
        {
            var fallback = new Verifier(LocalUnlockAvailabilityStatus.Available, LocalUnlockVerificationStatus.Verified);
            await Denied(new LocalUnlockGuard(new FallbackLocalUnlockService(new Verifier(LocalUnlockAvailabilityStatus.Available, result), fallback)));
            Require(fallback.Calls == 0, "failed or canceled Hello cannot fall through to another verifier");
            await Denied(new LocalUnlockGuard(new FallbackLocalUnlockService(
                new Verifier(LocalUnlockAvailabilityStatus.DeviceNotPresent, LocalUnlockVerificationStatus.Error),
                new Verifier(LocalUnlockAvailabilityStatus.Available, result))));
        }
        using var identity = WindowsIdentity.GetCurrent();
        var validate = typeof(WindowsPasswordLocalUnlockService).GetMethod("IsCurrentWindowsUser",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
        Require((bool)validate.Invoke(null, new object[] { identity.AccessToken, identity.User! })!, "same Windows SID accepted");
        var other = new SecurityIdentifier(identity.User!.Value == "S-1-5-18" ? "S-1-5-19" : "S-1-5-18");
        Require(!(bool)validate.Invoke(null, new object[] { identity.AccessToken, other })!, "different Windows SID rejected even with a valid token");
        Console.WriteLine("[PASS] Windows credential fallback, fail-closed outcomes and current-user SID verification");
    }

    private static async Task Denied(LocalUnlockGuard guard)
    {
        try { await guard.RequireUnlockAsync(true, "verify"); }
        catch (LocalUnlockDeniedException) { return; }
        throw new InvalidOperationException("Nonverified identity was allowed to unlock.");
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Verifier(LocalUnlockAvailabilityStatus available, LocalUnlockVerificationStatus result) : ILocalUnlockService
    {
        public int Calls { get; private set; }
        public Task<LocalUnlockAvailability> GetAvailabilityAsync(CancellationToken cancellationToken = default) => Task.FromResult(new LocalUnlockAvailability(available, "test", "test"));
        public Task<LocalUnlockResult> VerifyAsync(string message, CancellationToken cancellationToken = default)
        { Calls++; return Task.FromResult(new LocalUnlockResult(result, "test", "test")); }
    }
}
