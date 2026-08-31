using System.Text.Json.Serialization;

namespace Envelope.Windows.Core.Models;

/// <summary>
/// A normalized BIP-39 recovery phrase. To avoid accidental disclosure,
/// <see cref="ToString"/> never returns the words; use <see cref="Value"/>
/// only at the native-call or explicit export boundary.
/// </summary>
public sealed class RecoveryPhrase
{
    public const int DefaultWordCount = 24;

    private RecoveryPhrase(string value, IReadOnlyList<string> words)
    {
        Value = value;
        Words = words;
    }

    [JsonIgnore]
    public string Value { get; }

    [JsonIgnore]
    public IReadOnlyList<string> Words { get; }

    public int WordCount => Words.Count;

    public static RecoveryPhrase Parse(
        string value,
        int expectedWordCount = DefaultWordCount)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (expectedWordCount <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(expectedWordCount),
                "Expected word count must be positive.");
        }

        var words = value
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length != expectedWordCount)
        {
            throw new FormatException(
                $"Recovery phrase must contain exactly {expectedWordCount} words.");
        }

        if (words.Any(static word => word.IndexOf('\0') >= 0))
        {
            throw new FormatException("Recovery phrase contains a NUL character.");
        }

        return new RecoveryPhrase(string.Join(' ', words), Array.AsReadOnly(words));
    }

    public static bool TryParse(
        string? value,
        out RecoveryPhrase? phrase,
        int expectedWordCount = DefaultWordCount)
    {
        try
        {
            phrase = Parse(value ?? string.Empty, expectedWordCount);
            return true;
        }
        catch (Exception error) when (
            error is ArgumentException or FormatException)
        {
            phrase = null;
            return false;
        }
    }

    public override string ToString() => $"[protected recovery phrase: {WordCount} words]";
}

public sealed record SecureIdentityRecord(
    string IdentityJson,
    string KeyId,
    string DisplayName,
    long UpdatedAtUnixMs)
{
    public static SecureIdentityRecord FromSummary(
        IdentitySummary summary,
        long? updatedAtUnixMs = null)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return new SecureIdentityRecord(
            summary.IdentityJson,
            summary.KeyId,
            summary.DisplayName,
            updatedAtUnixMs ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }

    [JsonIgnore]
    public string Label => string.IsNullOrWhiteSpace(DisplayName)
        ? KeyId
        : $"{DisplayName} / {KeyId}";
}

public sealed record StoredContact(
    string KeyId,
    string DisplayName,
    string ContactJson,
    string? Remark = null,
    string? DeviceId = null,
    string? P2pTicket = null,
    long? P2pTicketUpdatedAtUnixMs = null,
    bool HumanVerified = false)
{
    public static StoredContact FromSummary(ContactSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return new StoredContact(
            summary.KeyId,
            summary.DisplayName,
            summary.ContactJson);
    }

    [JsonIgnore]
    public bool HasP2pTicket => !string.IsNullOrWhiteSpace(P2pTicket);

    [JsonIgnore]
    public string DisplayLabel => string.IsNullOrWhiteSpace(Remark)
        ? DisplayName
        : Remark.Trim();
}

public sealed record SecureStoreSettings(
    string SyncServiceUrl = "",
    int AutoBackupIntervalHours = 24,
    int AutoBackupRetentionCount = 7,
    long? AutoBackupLastAtUnixMs = null,
    bool LocalLockEnabled = false,
    bool PersistRecoveryPhrase = false,
    bool AutoSyncEnabled = true)
{
    public SecureStoreSettings Normalize() => this with
    {
        SyncServiceUrl = SyncServiceUrl?.Trim() ?? string.Empty,
        AutoBackupIntervalHours = Math.Max(0, AutoBackupIntervalHours),
        AutoBackupRetentionCount = Math.Max(1, AutoBackupRetentionCount),
        AutoBackupLastAtUnixMs = AutoBackupLastAtUnixMs is > 0
            ? AutoBackupLastAtUnixMs
            : null,
    };
}
