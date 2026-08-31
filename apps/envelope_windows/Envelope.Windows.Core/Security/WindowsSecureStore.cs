using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Security;

/// <summary>
/// Uses a random 256-bit AES-GCM master key protected by Windows DPAPI
/// CurrentUser. Each named state has a unique nonce and AAD-bound slot name,
/// so encrypted files cannot be swapped between slots undetected.
/// </summary>
public sealed class WindowsSecureStore : IWindowsSecureStore, IDisposable
{
    private const int MasterKeyLength = 32;
    private const int NonceLength = 12;
    private const int TagLength = 16;
    private const int EnvelopeVersion = 1;
    private const string Algorithm = "AES-256-GCM";
    private const string ProfileStateName = "profile-v1";
    private const string MasterKeyFileName = "master-key.dpapi";
    private const string AeadContext = "Envelope.Windows.SecureStore.State.v1|";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false,
    };

    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _disposed;

    public WindowsSecureStore(string? storeDirectory = null)
    {
        StoreDirectory = Path.GetFullPath(storeDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Envelope",
            "Windows",
            "SecureStore"));
    }

    public string StoreDirectory { get; }

    public async Task<T?> LoadStateAsync<T>(
        string stateName,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalizedName = NormalizeStateName(stateName);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await LoadStateUnlockedAsync<T>(normalizedName, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveStateAsync<T>(
        string stateName,
        T state,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(state);
        var normalizedName = NormalizeStateName(stateName);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await SaveStateUnlockedAsync(normalizedName, state, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<bool> DeleteStateAsync(
        string stateName,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalizedName = NormalizeStateName(stateName);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var path = GetStatePath(normalizedName);
            if (!File.Exists(path))
            {
                return false;
            }

            File.Delete(path);
            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SecureStoreException(
                $"Could not delete encrypted state '{normalizedName}'.",
                error);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<bool> HasIdentityAsync(
        CancellationToken cancellationToken = default) =>
        await ReadIdentityAsync(cancellationToken).ConfigureAwait(false) is not null;

    public async Task<SecureIdentityRecord?> ReadIdentityAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            return profile.Identity;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveIdentityAsync(
        SecureIdentityRecord identity,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ValidateIdentity(identity);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            profile.Identity = identity;
            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ClearIdentityAsync(
        bool clearRecoveryPhrase = true,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            profile.Identity = null;
            if (clearRecoveryPhrase)
            {
                profile.RecoveryPhrase = null;
                profile.Settings = profile.Settings with { PersistRecoveryPhrase = false };
            }

            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<RecoveryPhrase?> ReadRecoveryPhraseAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!profile.Settings.PersistRecoveryPhrase ||
                string.IsNullOrWhiteSpace(profile.RecoveryPhrase))
            {
                return null;
            }

            try
            {
                return RecoveryPhrase.Parse(profile.RecoveryPhrase);
            }
            catch (FormatException error)
            {
                throw new SecureStoreException(
                    "The encrypted recovery phrase record is invalid.",
                    error);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveRecoveryPhraseAsync(
        RecoveryPhrase recoveryPhrase,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(recoveryPhrase);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            profile.RecoveryPhrase = recoveryPhrase.Value;
            profile.Settings = profile.Settings with { PersistRecoveryPhrase = true };
            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ClearRecoveryPhraseAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            profile.RecoveryPhrase = null;
            profile.Settings = profile.Settings with { PersistRecoveryPhrase = false };
            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<IReadOnlyList<StoredContact>> ListContactsAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            return profile.Contacts
                .OrderBy(static contact => contact.DisplayLabel, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(static contact => contact.KeyId, StringComparer.Ordinal)
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<StoredContact?> GetContactAsync(
        string keyId,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalizedKeyId = RequireValue(keyId, nameof(keyId));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            return profile.Contacts.FirstOrDefault(contact =>
                string.Equals(contact.KeyId, normalizedKeyId, StringComparison.Ordinal));
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task UpsertContactAsync(
        StoredContact contact,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ValidateContact(contact);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            var existingIndex = profile.Contacts.FindIndex(candidate =>
                string.Equals(candidate.KeyId, contact.KeyId, StringComparison.Ordinal));
            if (existingIndex >= 0)
            {
                profile.Contacts[existingIndex] = contact;
            }
            else
            {
                profile.Contacts.Add(contact);
            }

            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<bool> RemoveContactAsync(
        string keyId,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalizedKeyId = RequireValue(keyId, nameof(keyId));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            var removed = profile.Contacts.RemoveAll(contact =>
                string.Equals(contact.KeyId, normalizedKeyId, StringComparison.Ordinal)) > 0;
            if (removed)
            {
                await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
            }

            return removed;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<SecureStoreSettings> ReadSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            return profile.Settings.Normalize();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task WriteSettingsAsync(
        SecureStoreSettings settings,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(settings);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var profile = await LoadProfileUnlockedAsync(cancellationToken)
                .ConfigureAwait(false);
            profile.Settings = settings.Normalize();
            if (!profile.Settings.PersistRecoveryPhrase)
            {
                profile.RecoveryPhrase = null;
            }

            await SaveProfileUnlockedAsync(profile, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ClearAllAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Directory.Exists(StoreDirectory))
            {
                return;
            }

            foreach (var path in Directory.EnumerateFiles(
                         StoreDirectory,
                         "state-*.vault.json",
                         SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                File.Delete(path);
            }

            // Delete the key only after every encrypted state file is gone.
            var keyPath = GetMasterKeyPath();
            if (File.Exists(keyPath))
            {
                File.Delete(keyPath);
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SecureStoreException("Could not clear the Windows secure store.", error);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _gate.Dispose();
    }

    private async Task<ProfileState> LoadProfileUnlockedAsync(
        CancellationToken cancellationToken)
    {
        var profile = await LoadStateUnlockedAsync<ProfileState>(
                ProfileStateName,
                cancellationToken)
            .ConfigureAwait(false) ?? new ProfileState();
        if (profile.Version != 1)
        {
            throw new SecureStoreException(
                $"Unsupported secure profile version: {profile.Version}.");
        }

        profile.Contacts ??= [];
        profile.Settings = (profile.Settings ?? new SecureStoreSettings()).Normalize();
        return profile;
    }

    private Task SaveProfileUnlockedAsync(
        ProfileState profile,
        CancellationToken cancellationToken) =>
        SaveStateUnlockedAsync(ProfileStateName, profile, cancellationToken);

    private async Task<T?> LoadStateUnlockedAsync<T>(
        string normalizedName,
        CancellationToken cancellationToken)
    {
        var path = GetStatePath(normalizedName);
        if (!File.Exists(path))
        {
            return default;
        }

        byte[]? key = null;
        byte[]? plaintext = null;
        try
        {
            var envelopeBytes = await File.ReadAllBytesAsync(path, cancellationToken)
                .ConfigureAwait(false);
            var envelope = JsonSerializer.Deserialize<EncryptedStateEnvelope>(
                    envelopeBytes,
                    JsonOptions)
                ?? throw new SecureStoreException(
                    $"Encrypted state '{normalizedName}' has an empty envelope.");
            ValidateEnvelope(envelope, normalizedName);

            key = await LoadMasterKeyUnlockedAsync(createIfMissing: false, cancellationToken)
                .ConfigureAwait(false);
            var nonce = Convert.FromBase64String(envelope.Nonce);
            var tag = Convert.FromBase64String(envelope.Tag);
            var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
            plaintext = new byte[ciphertext.Length];
            using (var aes = new AesGcm(key, TagLength))
            {
                aes.Decrypt(
                    nonce,
                    ciphertext,
                    tag,
                    plaintext,
                    GetAdditionalAuthenticatedData(normalizedName));
            }

            return JsonSerializer.Deserialize<T>(plaintext, JsonOptions)
                ?? throw new SecureStoreException(
                    $"Encrypted state '{normalizedName}' contained no JSON value.");
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (SecureStoreException)
        {
            throw;
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                CryptographicException or
                FormatException or
                JsonException or
                System.ComponentModel.Win32Exception)
        {
            throw new SecureStoreException(
                $"Could not decrypt state '{normalizedName}'. The file may be corrupt, " +
                "tampered with, or owned by another Windows account.",
                error);
        }
        finally
        {
            if (key is not null)
            {
                CryptographicOperations.ZeroMemory(key);
            }

            if (plaintext is not null)
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }

    private async Task SaveStateUnlockedAsync<T>(
        string normalizedName,
        T state,
        CancellationToken cancellationToken)
    {
        byte[]? key = null;
        byte[]? plaintext = null;
        try
        {
            Directory.CreateDirectory(StoreDirectory);
            key = await LoadMasterKeyUnlockedAsync(createIfMissing: true, cancellationToken)
                .ConfigureAwait(false);
            plaintext = JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions);
            var nonce = RandomNumberGenerator.GetBytes(NonceLength);
            var tag = new byte[TagLength];
            var ciphertext = new byte[plaintext.Length];
            using (var aes = new AesGcm(key, TagLength))
            {
                aes.Encrypt(
                    nonce,
                    plaintext,
                    ciphertext,
                    tag,
                    GetAdditionalAuthenticatedData(normalizedName));
            }

            var envelope = new EncryptedStateEnvelope(
                EnvelopeVersion,
                Algorithm,
                Convert.ToBase64String(nonce),
                Convert.ToBase64String(tag),
                Convert.ToBase64String(ciphertext));
            var envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
            _ = await WriteAtomicAsync(
                    GetStatePath(normalizedName),
                    envelopeBytes,
                    overwrite: true,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (SecureStoreException)
        {
            throw;
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                CryptographicException or
                JsonException or
                System.ComponentModel.Win32Exception)
        {
            throw new SecureStoreException(
                $"Could not encrypt state '{normalizedName}'.",
                error);
        }
        finally
        {
            if (key is not null)
            {
                CryptographicOperations.ZeroMemory(key);
            }

            if (plaintext is not null)
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }

    private async Task<byte[]> LoadMasterKeyUnlockedAsync(
        bool createIfMissing,
        CancellationToken cancellationToken)
    {
        var keyPath = GetMasterKeyPath();
        if (File.Exists(keyPath))
        {
            var protectedKey = await File.ReadAllBytesAsync(keyPath, cancellationToken)
                .ConfigureAwait(false);
            var key = WindowsDataProtection.Unprotect(protectedKey);
            if (key.Length != MasterKeyLength)
            {
                CryptographicOperations.ZeroMemory(key);
                throw new SecureStoreException(
                    "The DPAPI-protected secure-store master key has an invalid length.");
            }

            return key;
        }

        if (!createIfMissing)
        {
            throw new SecureStoreException(
                "The DPAPI-protected master key is missing for an existing encrypted state.");
        }

        if (Directory.Exists(StoreDirectory) && Directory.EnumerateFiles(
                StoreDirectory,
                "state-*.vault.json",
                SearchOption.TopDirectoryOnly).Any())
        {
            throw new SecureStoreException(
                "The DPAPI-protected master key is missing while encrypted state files still " +
                "exist. Refusing to create a replacement key that would orphan them.");
        }

        Directory.CreateDirectory(StoreDirectory);
        var newKey = RandomNumberGenerator.GetBytes(MasterKeyLength);
        try
        {
            var protectedKey = WindowsDataProtection.Protect(newKey);
            var created = await WriteAtomicAsync(
                    keyPath,
                    protectedKey,
                    overwrite: false,
                    cancellationToken)
                .ConfigureAwait(false);
            if (created)
            {
                return newKey;
            }

            // Another process won initial key creation. Never encrypt state with
            // this losing key; discard it and use the DPAPI-protected winner.
            CryptographicOperations.ZeroMemory(newKey);
            return await LoadMasterKeyUnlockedAsync(
                    createIfMissing: false,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            CryptographicOperations.ZeroMemory(newKey);
            throw;
        }
    }

    private static async Task<bool> WriteAtomicAsync(
        string targetPath,
        byte[] bytes,
        bool overwrite,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(targetPath)
            ?? throw new IOException("Secure-store target has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(targetPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             bufferSize: 16 * 1024,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            if (overwrite)
            {
                File.Move(temporaryPath, targetPath, overwrite: true);
            }
            else
            {
                try
                {
                    File.Move(temporaryPath, targetPath, overwrite: false);
                }
                catch (IOException) when (File.Exists(targetPath))
                {
                    return false;
                }
            }

            return true;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void ValidateEnvelope(
        EncryptedStateEnvelope envelope,
        string stateName)
    {
        if (envelope.Version != EnvelopeVersion ||
            !string.Equals(envelope.Algorithm, Algorithm, StringComparison.Ordinal))
        {
            throw new SecureStoreException(
                $"Encrypted state '{stateName}' uses an unsupported envelope format.");
        }

        try
        {
            if (Convert.FromBase64String(envelope.Nonce).Length != NonceLength ||
                Convert.FromBase64String(envelope.Tag).Length != TagLength)
            {
                throw new SecureStoreException(
                    $"Encrypted state '{stateName}' has invalid AES-GCM parameters.");
            }
        }
        catch (FormatException error)
        {
            throw new SecureStoreException(
                $"Encrypted state '{stateName}' has invalid base64 fields.",
                error);
        }
    }

    private static byte[] GetAdditionalAuthenticatedData(string stateName) =>
        Encoding.UTF8.GetBytes(AeadContext + stateName);

    private string GetStatePath(string normalizedName) =>
        Path.Combine(StoreDirectory, $"state-{normalizedName}.vault.json");

    private string GetMasterKeyPath() => Path.Combine(StoreDirectory, MasterKeyFileName);

    private static string NormalizeStateName(string stateName)
    {
        var value = RequireValue(stateName, nameof(stateName)).ToLowerInvariant();
        if (value.Length > 80 || value.Any(static character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.')))
        {
            throw new ArgumentException(
                "State name may contain only ASCII letters, digits, dot, dash, and underscore " +
                "and must be at most 80 characters.",
                nameof(stateName));
        }

        return value;
    }

    private static string RequireValue(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, parameterName);
        if (value.IndexOf('\0') >= 0)
        {
            throw new ArgumentException("Value contains a NUL character.", parameterName);
        }

        return value.Trim();
    }

    private static void ValidateIdentity(SecureIdentityRecord identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        RequireValue(identity.IdentityJson, nameof(identity.IdentityJson));
        RequireValue(identity.KeyId, nameof(identity.KeyId));
        RequireValue(identity.DisplayName, nameof(identity.DisplayName));
    }

    private static void ValidateContact(StoredContact contact)
    {
        ArgumentNullException.ThrowIfNull(contact);
        RequireValue(contact.KeyId, nameof(contact.KeyId));
        RequireValue(contact.DisplayName, nameof(contact.DisplayName));
        RequireValue(contact.ContactJson, nameof(contact.ContactJson));
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private sealed record EncryptedStateEnvelope(
        int Version,
        string Algorithm,
        string Nonce,
        string Tag,
        string Ciphertext);

    private sealed class ProfileState
    {
        public int Version { get; set; } = 1;

        public SecureIdentityRecord? Identity { get; set; }

        public string? RecoveryPhrase { get; set; }

        public List<StoredContact> Contacts { get; set; } = [];

        public SecureStoreSettings Settings { get; set; } = new();
    }
}
