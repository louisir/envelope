namespace Envelope.Windows.Models;

public sealed record IdentityUiModel(
    string DisplayName,
    string KeyId,
    string Fingerprint,
    bool IsReady);

public sealed record ContactUiModel(
    string Id,
    string DisplayName,
    string Subtitle,
    string KeyId,
    string Fingerprint,
    string Remark,
    bool IsGroup,
    bool IsVerified,
    int MemberCount,
    int UnreadCount)
{
    public string Initials
    {
        get
        {
            var value = string.IsNullOrWhiteSpace(DisplayName) ? "?" : DisplayName.Trim();
            return value.Length == 1 ? value : value[..1].ToUpperInvariant();
        }
    }
}

public enum MessageDirection
{
    Incoming,
    Outgoing,
}

public enum MessageDeliveryState
{
    Pending,
    Sent,
    Delivered,
    Failed,
    LegacyUnverified,
    StagedSingle,
    Replicated,
    Deferred,
    Rejected,
    Expired,
}

public sealed record MessageUiModel(
    string Id,
    MessageDirection Direction,
    string Text,
    DateTimeOffset Timestamp,
    MessageDeliveryState DeliveryState,
    string? AttachmentName = null,
    long? AttachmentSize = null,
    string? AttachmentPath = null)
{
    public bool HasAttachment =>
        !string.IsNullOrWhiteSpace(AttachmentName) || !string.IsNullOrWhiteSpace(AttachmentPath);
}

public sealed record ConversationUiModel(
    string Id,
    string DisplayName,
    string Preview,
    DateTimeOffset? LastActivity,
    bool IsGroup,
    bool IsVerified,
    int UnreadCount,
    IReadOnlyList<MessageUiModel> Messages,
    bool HasPendingGroupInvitation = false,
    string? PendingGroupInvitationId = null,
    string? PendingGroupInvitationName = null,
    bool HasEarlierMessages = false,
    int TotalMessageCount = 0)
{
    public string Initials
    {
        get
        {
            var value = string.IsNullOrWhiteSpace(DisplayName) ? "?" : DisplayName.Trim();
            return value.Length == 1 ? value : value[..1].ToUpperInvariant();
        }
    }
}

public sealed record RecentEnvelopeUiModel(
    string Id,
    string Sender,
    string Summary,
    DateTimeOffset OpenedAt,
    bool SignatureVerified);

public sealed record SettingsUiModel(
    bool LocalLockEnabled,
    bool AutoBackupEnabled,
    bool AutoSyncEnabled,
    string BackupInterval,
    string BackupRetention,
    string SyncEntry,
    DateTimeOffset? LastSyncAt,
    DateTimeOffset? LastBackupAt);

public sealed record UiWorkspaceSnapshot(
    IdentityUiModel? Identity,
    IReadOnlyList<ContactUiModel> Contacts,
    IReadOnlyList<ConversationUiModel> Conversations,
    IReadOnlyList<RecentEnvelopeUiModel> RecentEnvelopes,
    SettingsUiModel Settings,
    string? SigningFingerprint,
    bool ServicesConnected)
{
    public static UiWorkspaceSnapshot Empty { get; } = new(
        null,
        Array.Empty<ContactUiModel>(),
        Array.Empty<ConversationUiModel>(),
        Array.Empty<RecentEnvelopeUiModel>(),
        new SettingsUiModel(false, false, true, "24h", "7", string.Empty, null, null),
        null,
        false);
}
