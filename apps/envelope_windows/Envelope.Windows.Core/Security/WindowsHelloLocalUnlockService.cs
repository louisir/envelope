using System.Runtime.InteropServices;

namespace Envelope.Windows.Core.Security;

/// <summary>
/// Windows Hello / PIN / system-credential verification through the inbox
/// Windows Runtime UserConsentVerifier API. No third-party or NuGet projection
/// is required; unsupported runtime states are returned explicitly.
/// </summary>
public sealed class WindowsHelloLocalUnlockService : ILocalUnlockService
{
    public const string ProviderName = "Windows Hello UserConsentVerifier";

    private readonly SemaphoreSlim _verificationGate = new(1, 1);

    public async Task<LocalUnlockAvailability> GetAvailabilityAsync(
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            return new LocalUnlockAvailability(
                LocalUnlockAvailabilityStatus.UnsupportedPlatform,
                ProviderName,
                "Windows Hello local unlock requires Windows 10 or later.");
        }

        try
        {
            var value = await UserConsentVerifierAbi.CheckAvailabilityAsync(cancellationToken)
                .ConfigureAwait(false);
            return value switch
            {
                UserConsentVerifierAvailability.Available => new(
                    LocalUnlockAvailabilityStatus.Available,
                    ProviderName,
                    "Windows Hello or a system credential is available."),
                UserConsentVerifierAvailability.DeviceNotPresent => new(
                    LocalUnlockAvailabilityStatus.DeviceNotPresent,
                    ProviderName,
                    "No Windows Hello verification device is present."),
                UserConsentVerifierAvailability.NotConfiguredForUser => new(
                    LocalUnlockAvailabilityStatus.NotConfiguredForUser,
                    ProviderName,
                    "Windows Hello or a system credential is not configured for this user."),
                UserConsentVerifierAvailability.DisabledByPolicy => new(
                    LocalUnlockAvailabilityStatus.DisabledByPolicy,
                    ProviderName,
                    "Windows Hello verification is disabled by policy."),
                UserConsentVerifierAvailability.DeviceBusy => new(
                    LocalUnlockAvailabilityStatus.DeviceBusy,
                    ProviderName,
                    "The Windows Hello verification device is busy."),
                _ => new(
                    LocalUnlockAvailabilityStatus.Error,
                    ProviderName,
                    $"Windows returned an unknown verifier availability value: {(int)value}."),
            };
        }
        catch (OperationCanceledException)
        {
            return new LocalUnlockAvailability(
                LocalUnlockAvailabilityStatus.Canceled,
                ProviderName,
                "Windows Hello availability check was canceled.");
        }
        catch (Exception error) when (IsRuntimeUnavailable(error))
        {
            return new LocalUnlockAvailability(
                LocalUnlockAvailabilityStatus.RuntimeUnavailable,
                ProviderName,
                "The Windows UserConsentVerifier runtime is unavailable.",
                error.HResult);
        }
        catch (Exception error)
        {
            return new LocalUnlockAvailability(
                LocalUnlockAvailabilityStatus.Error,
                ProviderName,
                "Windows Hello availability check failed.",
                error.HResult);
        }
    }

    public async Task<LocalUnlockResult> VerifyAsync(
        string message,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        var normalizedMessage = message.Trim();
        if (normalizedMessage.Length > 256)
        {
            throw new ArgumentOutOfRangeException(
                nameof(message),
                "Windows Hello verification message must not exceed 256 characters.");
        }

        var availability = await GetAvailabilityAsync(cancellationToken)
            .ConfigureAwait(false);
        if (!availability.IsAvailable)
        {
            return FromUnavailable(availability);
        }

        try
        {
            if (!await _verificationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            {
                return new LocalUnlockResult(
                    LocalUnlockVerificationStatus.DeviceBusy,
                    ProviderName,
                    "Another Envelope local-unlock request is already active.");
            }
        }
        catch (OperationCanceledException)
        {
            return new LocalUnlockResult(
                LocalUnlockVerificationStatus.Canceled,
                ProviderName,
                "Windows Hello verification was canceled.");
        }

        try
        {
            var value = await UserConsentVerifierAbi.RequestVerificationAsync(
                    normalizedMessage,
                    cancellationToken)
                .ConfigureAwait(false);
            return value switch
            {
                UserConsentVerificationResult.Verified => new(
                    LocalUnlockVerificationStatus.Verified,
                    ProviderName,
                    "The current Windows user was verified."),
                UserConsentVerificationResult.DeviceNotPresent => new(
                    LocalUnlockVerificationStatus.DeviceNotPresent,
                    ProviderName,
                    "No Windows Hello verification device is present."),
                UserConsentVerificationResult.NotConfiguredForUser => new(
                    LocalUnlockVerificationStatus.NotConfiguredForUser,
                    ProviderName,
                    "Windows Hello or a system credential is not configured for this user."),
                UserConsentVerificationResult.DisabledByPolicy => new(
                    LocalUnlockVerificationStatus.DisabledByPolicy,
                    ProviderName,
                    "Windows Hello verification is disabled by policy."),
                UserConsentVerificationResult.DeviceBusy => new(
                    LocalUnlockVerificationStatus.DeviceBusy,
                    ProviderName,
                    "The Windows Hello verification device is busy."),
                UserConsentVerificationResult.RetriesExhausted => new(
                    LocalUnlockVerificationStatus.RetriesExhausted,
                    ProviderName,
                    "Windows Hello verification retries were exhausted."),
                UserConsentVerificationResult.Canceled => new(
                    LocalUnlockVerificationStatus.Canceled,
                    ProviderName,
                    "Windows Hello verification was canceled."),
                _ => new(
                    LocalUnlockVerificationStatus.Error,
                    ProviderName,
                    $"Windows returned an unknown verification value: {(int)value}."),
            };
        }
        catch (OperationCanceledException)
        {
            return new LocalUnlockResult(
                LocalUnlockVerificationStatus.Canceled,
                ProviderName,
                "Windows Hello verification was canceled.");
        }
        catch (Exception error) when (IsRuntimeUnavailable(error))
        {
            return new LocalUnlockResult(
                LocalUnlockVerificationStatus.RuntimeUnavailable,
                ProviderName,
                "The Windows UserConsentVerifier runtime is unavailable.",
                error.HResult);
        }
        catch (Exception error)
        {
            return new LocalUnlockResult(
                LocalUnlockVerificationStatus.Error,
                ProviderName,
                "Windows Hello verification failed.",
                error.HResult);
        }
        finally
        {
            _verificationGate.Release();
        }
    }

    private static LocalUnlockResult FromUnavailable(
        LocalUnlockAvailability availability) => availability.Status switch
    {
        LocalUnlockAvailabilityStatus.DeviceNotPresent => new(
            LocalUnlockVerificationStatus.DeviceNotPresent,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.NotConfiguredForUser => new(
            LocalUnlockVerificationStatus.NotConfiguredForUser,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.DisabledByPolicy => new(
            LocalUnlockVerificationStatus.DisabledByPolicy,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.DeviceBusy => new(
            LocalUnlockVerificationStatus.DeviceBusy,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.UnsupportedPlatform => new(
            LocalUnlockVerificationStatus.UnsupportedPlatform,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.RuntimeUnavailable => new(
            LocalUnlockVerificationStatus.RuntimeUnavailable,
            ProviderName,
            availability.Detail,
            availability.HResult),
        LocalUnlockAvailabilityStatus.Canceled => new(
            LocalUnlockVerificationStatus.Canceled,
            ProviderName,
            availability.Detail,
            availability.HResult),
        _ => new(
            LocalUnlockVerificationStatus.Error,
            ProviderName,
            availability.Detail,
            availability.HResult),
    };

    private static bool IsRuntimeUnavailable(Exception error)
    {
        if (error is DllNotFoundException or EntryPointNotFoundException)
        {
            return true;
        }

        return error.HResult is
            unchecked((int)0x80040154) or // REGDB_E_CLASSNOTREG
            unchecked((int)0x80004002) or // E_NOINTERFACE
            unchecked((int)0x8007007E) or // ERROR_MOD_NOT_FOUND
            unchecked((int)0x8007007F);   // ERROR_PROC_NOT_FOUND
    }
}
