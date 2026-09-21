using Envelope.Windows.Core.Security;

namespace Envelope.Windows.Tests;

internal static class AppPasscodeVerification
{
    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "envelope-passcode-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var vault = new WindowsSecureStore(directory);
            var clock = new TestClock();
            var codes = new AppPasscodeStore(vault, clock);
            await codes.InitializeAsync();
            Require(codes.UsesInitialCode && !codes.IsLocked, "first initialization supplies default code");
            Require((await codes.VerifyAsync("123456")).Status == PasscodeStatus.Verified, "initial code works");
            Require((await codes.ChangeAsync("111111", "654321")).Status == PasscodeStatus.Incorrect, "changing code requires current code");
            Require((await codes.ChangeAsync("123456", "abc123")).Status == PasscodeStatus.InvalidFormat, "only six numeric digits accepted");
            Require((await codes.ChangeAsync("123456", "654321")).Status == PasscodeStatus.Verified, "current code changes code");
            await codes.SetLockedAsync(true);
            codes = new AppPasscodeStore(vault, clock);
            await codes.InitializeAsync();
            Require(!codes.UsesInitialCode && codes.IsLocked, "upgrade/restart preserves changed code and manual lock");
            Require((await codes.VerifyAsync("123456")).Status == PasscodeStatus.Incorrect, "initial code no longer unlocks after change");
            Require((await codes.VerifyAsync("654321")).Status == PasscodeStatus.Verified, "new code remains valid after restart");
            for (var i = 0; i < 5; i++) await codes.VerifyAsync("000000");
            codes = new AppPasscodeStore(vault, clock);
            await codes.InitializeAsync();
            Require((await codes.VerifyAsync("654321")).Status == PasscodeStatus.CoolingDown, "five failures lock retries across restart");
            clock.Now += TimeSpan.FromSeconds(31);
            Require((await codes.VerifyAsync("654321")).Status == PasscodeStatus.Verified, "correct code works after cooldown");
            await codes.SetLockedAsync(false);
            var saved = await vault.LoadStateAsync<AppPasscodeStore.PasscodeState>("app-unlock-code-v1");
            Require(saved is { IsLocked: false } && Convert.FromBase64String(saved.Hash).Length == 32, "only salted verifier and local policy are persisted");
            await vault.SaveStateAsync("app-unlock-code-v1", saved! with { Version = 99 });
            try { await new AppPasscodeStore(vault).InitializeAsync(); throw new InvalidOperationException("Corrupt code was reset."); }
            catch (InvalidDataException) { }
            Require((await vault.LoadStateAsync<AppPasscodeStore.PasscodeState>("app-unlock-code-v1"))!.Version == 99, "invalid record fails closed without resetting to initial code");
            Console.WriteLine("[PASS] App unlock code: initial code, change, restart, throttling and corrupt-state protection");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class TestClock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
