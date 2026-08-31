namespace Envelope.Windows.Core.Security;

public enum LocalUnlockAvailabilityStatus
{
    Available,
    DeviceNotPresent,
    NotConfiguredForUser,
    DisabledByPolicy,
    DeviceBusy,
    UnsupportedPlatform,
    RuntimeUnavailable,
    Canceled,
    Error,
}

public sealed record LocalUnlockAvailability(
    LocalUnlockAvailabilityStatus Status,
    string Provider,
    string Detail,
    int? HResult = null)
{
    public bool IsAvailable => Status == LocalUnlockAvailabilityStatus.Available;
}

public enum LocalUnlockVerificationStatus
{
    Verified,
    DeviceNotPresent,
    NotConfiguredForUser,
    DisabledByPolicy,
    DeviceBusy,
    RetriesExhausted,
    Canceled,
    UnsupportedPlatform,
    RuntimeUnavailable,
    Error,
}

public sealed record LocalUnlockResult(
    LocalUnlockVerificationStatus Status,
    string Provider,
    string Detail,
    int? HResult = null)
{
    /// <summary>
    /// This is intentionally true for exactly one status. Callers must never
    /// treat unavailable, canceled, or an interop error as successful unlock.
    /// </summary>
    public bool IsVerified => Status == LocalUnlockVerificationStatus.Verified;
}

public interface ILocalUnlockService
{
    Task<LocalUnlockAvailability> GetAvailabilityAsync(
        CancellationToken cancellationToken = default);

    Task<LocalUnlockResult> VerifyAsync(
        string message,
        CancellationToken cancellationToken = default);
}

public interface ILocalUnlockGuard
{
    /// <summary>
    /// Returns only when local lock is disabled or Windows has positively
    /// verified the current user. Every other outcome throws fail-closed.
    /// </summary>
    Task RequireUnlockAsync(
        bool localLockEnabled,
        string message,
        CancellationToken cancellationToken = default);
}

public sealed class LocalUnlockDeniedException : Exception
{
    public LocalUnlockDeniedException(
        string message,
        LocalUnlockAvailabilityStatus availabilityStatus,
        int? hResult = null)
        : base(message)
    {
        AvailabilityStatus = availabilityStatus;
        VerificationStatus = null;
        NativeHResult = hResult;
    }

    public LocalUnlockDeniedException(
        string message,
        LocalUnlockVerificationStatus verificationStatus,
        int? hResult = null)
        : base(message)
    {
        VerificationStatus = verificationStatus;
        AvailabilityStatus = null;
        NativeHResult = hResult;
    }

    public LocalUnlockAvailabilityStatus? AvailabilityStatus { get; }

    public LocalUnlockVerificationStatus? VerificationStatus { get; }

    public int? NativeHResult { get; }
}

public sealed class LocalUnlockGuard(
    ILocalUnlockService unlockService) : ILocalUnlockGuard
{
    private readonly ILocalUnlockService _unlockService =
        unlockService ?? throw new ArgumentNullException(nameof(unlockService));

    public async Task RequireUnlockAsync(
        bool localLockEnabled,
        string message,
        CancellationToken cancellationToken = default)
    {
        if (!localLockEnabled)
        {
            return;
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        var availability = await _unlockService.GetAvailabilityAsync(cancellationToken)
            .ConfigureAwait(false);
        if (!availability.IsAvailable)
        {
            throw new LocalUnlockDeniedException(
                availability.Detail,
                availability.Status,
                availability.HResult);
        }

        var verification = await _unlockService.VerifyAsync(message, cancellationToken)
            .ConfigureAwait(false);
        if (!verification.IsVerified)
        {
            throw new LocalUnlockDeniedException(
                verification.Detail,
                verification.Status,
                verification.HResult);
        }
    }
}
