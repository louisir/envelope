namespace Envelope.Windows.Core.Security;

/// <summary>Fall back only when the verifier is unavailable, never after a rejected or canceled verification.</summary>
public sealed class FallbackLocalUnlockService(ILocalUnlockService primary, ILocalUnlockService fallback) : ILocalUnlockService
{
    private static bool CanUseFallback(LocalUnlockAvailabilityStatus status) => status is
        LocalUnlockAvailabilityStatus.DeviceNotPresent or
        LocalUnlockAvailabilityStatus.NotConfiguredForUser or
        LocalUnlockAvailabilityStatus.RuntimeUnavailable;

    public async Task<LocalUnlockAvailability> GetAvailabilityAsync(CancellationToken cancellationToken = default)
    {
        var availability = await primary.GetAvailabilityAsync(cancellationToken).ConfigureAwait(false);
        return CanUseFallback(availability.Status)
            ? await fallback.GetAvailabilityAsync(cancellationToken).ConfigureAwait(false)
            : availability;
    }

    public async Task<LocalUnlockResult> VerifyAsync(string message, CancellationToken cancellationToken = default)
    {
        var availability = await primary.GetAvailabilityAsync(cancellationToken).ConfigureAwait(false);
        return await (CanUseFallback(availability.Status) ? fallback : primary)
            .VerifyAsync(message, cancellationToken).ConfigureAwait(false);
    }
}
