using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Security;

public static class SecureStateSlots
{
    public const string WindowsClientState = "windows-client-state";
}

/// <summary>
/// Per-Windows-user encrypted persistence. Implementations must not write
/// identity, recovery words, contacts, messages, or settings as plaintext.
/// </summary>
public interface IWindowsSecureStore
{
    string StoreDirectory { get; }

    Task<T?> LoadStateAsync<T>(
        string stateName,
        CancellationToken cancellationToken = default);

    Task SaveStateAsync<T>(
        string stateName,
        T state,
        CancellationToken cancellationToken = default);

    Task<bool> DeleteStateAsync(
        string stateName,
        CancellationToken cancellationToken = default);

    Task<bool> HasIdentityAsync(CancellationToken cancellationToken = default);

    Task<SecureIdentityRecord?> ReadIdentityAsync(
        CancellationToken cancellationToken = default);

    Task SaveIdentityAsync(
        SecureIdentityRecord identity,
        CancellationToken cancellationToken = default);

    Task ClearIdentityAsync(
        bool clearRecoveryPhrase = true,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns recovery words only when the user explicitly enabled their
    /// encrypted persistence. Android parity defaults to not persisting them.
    /// </summary>
    Task<RecoveryPhrase?> ReadRecoveryPhraseAsync(
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Explicitly opts in to storing recovery words inside the DPAPI/AES-GCM
    /// vault. Call <see cref="ClearRecoveryPhraseAsync"/> to opt out again.
    /// </summary>
    Task SaveRecoveryPhraseAsync(
        RecoveryPhrase recoveryPhrase,
        CancellationToken cancellationToken = default);

    Task ClearRecoveryPhraseAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<StoredContact>> ListContactsAsync(
        CancellationToken cancellationToken = default);

    Task<StoredContact?> GetContactAsync(
        string keyId,
        CancellationToken cancellationToken = default);

    Task UpsertContactAsync(
        StoredContact contact,
        CancellationToken cancellationToken = default);

    Task<bool> RemoveContactAsync(
        string keyId,
        CancellationToken cancellationToken = default);

    Task<SecureStoreSettings> ReadSettingsAsync(
        CancellationToken cancellationToken = default);

    Task WriteSettingsAsync(
        SecureStoreSettings settings,
        CancellationToken cancellationToken = default);

    Task ClearAllAsync(CancellationToken cancellationToken = default);
}
