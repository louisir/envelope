using System.Security.Cryptography;

namespace Envelope.Windows.Core.Security;

public enum PasscodeStatus { Verified, Incorrect, InvalidFormat, CoolingDown }
public sealed record PasscodeResult(PasscodeStatus Status, int RetryAfterSeconds = 0);

/// <summary>Device-local unlock policy, separate from identity and portable backups.</summary>
public sealed class AppPasscodeStore(WindowsSecureStore secureStore, TimeProvider? clock = null)
{
    public const string InitialCode = "123456";
    private const string Slot = "app-unlock-code-v1";
    private const int Iterations = 600_000;
    private readonly TimeProvider _clock = clock ?? TimeProvider.System;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PasscodeState? _state;
    public bool UsesInitialCode => State.UsesInitialCode;
    public bool IsLocked => State.IsLocked;
    private PasscodeState State => _state ?? throw new InvalidOperationException("解锁码尚未初始化。");

    public async Task InitializeAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_state is not null) return;
            var saved = await secureStore.LoadStateAsync<PasscodeState>(Slot).ConfigureAwait(false);
            if (saved is null)
            {
                saved = Create(InitialCode, false);
                await secureStore.SaveStateAsync(Slot, saved).ConfigureAwait(false);
            }
            if (saved.Version != 1 || Convert.FromBase64String(saved.Salt).Length != 16 ||
                Convert.FromBase64String(saved.Hash).Length != 32 || saved.FailedAttempts is < 0 or > 4 || saved.RetryAfterUnixMs < 0)
                throw new InvalidDataException("本地解锁码记录无效，不能自动恢复为初始码。");
            _state = saved;
        }
        finally { _gate.Release(); }
    }

    public async Task<PasscodeResult> VerifyAsync(string code)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { return await VerifyCoreAsync(code).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    public async Task<PasscodeResult> ChangeAsync(string oldCode, string newCode)
    {
        if (!ValidCode(newCode)) return new(PasscodeStatus.InvalidFormat);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var verified = await VerifyCoreAsync(oldCode).ConfigureAwait(false);
            if (verified.Status != PasscodeStatus.Verified) return verified;
            await SaveAsync(Create(newCode, State.IsLocked)).ConfigureAwait(false);
            return verified;
        }
        finally { _gate.Release(); }
    }

    public async Task SetLockedAsync(bool locked)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { if (State.IsLocked != locked) await SaveAsync(State with { IsLocked = locked }).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    private async Task<PasscodeResult> VerifyCoreAsync(string code)
    {
        var remaining = State.RetryAfterUnixMs - _clock.GetUtcNow().ToUnixTimeMilliseconds();
        if (remaining > 0) return new(PasscodeStatus.CoolingDown, (int)Math.Ceiling(remaining / 1000d));
        if (!ValidCode(code)) return new(PasscodeStatus.InvalidFormat);
        var candidate = Rfc2898DeriveBytes.Pbkdf2(code, Convert.FromBase64String(State.Salt), Iterations, HashAlgorithmName.SHA256, 32);
        bool matches;
        try { matches = CryptographicOperations.FixedTimeEquals(candidate, Convert.FromBase64String(State.Hash)); }
        finally { CryptographicOperations.ZeroMemory(candidate); }
        if (matches)
        {
            await SaveAsync(State with { FailedAttempts = 0, RetryAfterUnixMs = 0 }).ConfigureAwait(false);
            return new(PasscodeStatus.Verified);
        }
        var attempts = State.FailedAttempts + 1;
        var coolingDown = attempts >= 5;
        await SaveAsync(State with { FailedAttempts = coolingDown ? 0 : attempts,
            RetryAfterUnixMs = coolingDown ? _clock.GetUtcNow().AddSeconds(30).ToUnixTimeMilliseconds() : 0 }).ConfigureAwait(false);
        return new(coolingDown ? PasscodeStatus.CoolingDown : PasscodeStatus.Incorrect, coolingDown ? 30 : 0);
    }

    public static bool ValidCode(string code) => code.Length == 6 && code.All(c => c is >= '0' and <= '9');
    private static PasscodeState Create(string code, bool locked)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(code, salt, Iterations, HashAlgorithmName.SHA256, 32);
        try { return new(1, Convert.ToBase64String(salt), Convert.ToBase64String(hash), code == InitialCode, 0, 0, locked); }
        finally { CryptographicOperations.ZeroMemory(hash); }
    }
    private async Task SaveAsync(PasscodeState state)
    {
        await secureStore.SaveStateAsync(Slot, state).ConfigureAwait(false);
        _state = state;
    }
    public sealed record PasscodeState(int Version, string Salt, string Hash, bool UsesInitialCode, int FailedAttempts, long RetryAfterUnixMs, bool IsLocked);
}
