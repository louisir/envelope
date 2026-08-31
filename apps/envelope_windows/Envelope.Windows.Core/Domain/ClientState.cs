using System.Security.Cryptography;
using System.Text.Json.Serialization;
using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Domain;

public enum MessageDirection { Incoming, Outgoing, System }
public enum DeliveryState { Pending, Sent, ServerMailbox, Delivered, Received, Failed }
public enum GroupPolicy { Normal, Verified, Consensus }
public enum GroupRole { Owner, Member }
public enum GroupMemberStatus { Pending, Accepted, Active, Left, Removed }
public enum GroupTrustState { Verified, Inviter, Unverified, ConsensusPending, ConsensusAdmitted }

public sealed record ChatMessageRecord(
    string EnvelopeId,
    string ConversationId,
    MessageDirection Direction,
    string PeerKeyId,
    string PeerDisplayName,
    long CreatedAtUnixMs,
    ulong MessageCounter,
    string Text,
    string OpaqueEnvelopeBase64,
    DeliveryState DeliveryState,
    string? AttachmentPath = null,
    string? AttachmentMime = null,
    string? AttachmentFileName = null,
    string? DeliveryDetail = null,
    bool IsHidden = false,
    string? LogicalMessageId = null,
    bool IsRead = true)
{
    [JsonIgnore]
    public DateTimeOffset CreatedAt => DateTimeOffset.FromUnixTimeMilliseconds(CreatedAtUnixMs);
}

public sealed record GroupRecord(
    string GroupId,
    string Name,
    string OwnerKeyId,
    GroupPolicy Policy,
    long Epoch,
    long CreatedAtUnixMs,
    long UpdatedAtUnixMs,
    string AvatarSeed,
    bool IsActive = true);

public sealed record GroupMemberRecord(
    string GroupId,
    string KeyId,
    string DisplayName,
    string ContactJson,
    GroupRole Role,
    GroupMemberStatus Status,
    GroupTrustState TrustState,
    long UpdatedAtUnixMs,
    string? InvitedByKeyId = null,
    long? JoinedAtUnixMs = null)
{
    [JsonIgnore]
    public bool IsActive => Status == GroupMemberStatus.Active;
}

public sealed record GroupEventRecord(
    string EventId,
    string GroupId,
    string Type,
    string ActorKeyId,
    long GroupEpoch,
    long CreatedAtUnixMs,
    string PayloadJson);

public sealed record PendingEnvelopeRecord(
    string EnvelopeId,
    string RecipientKeyId,
    string EnvelopeBase64,
    long CreatedAtUnixMs,
    int AttemptCount = 0,
    long? NextAttemptAtUnixMs = null,
    string? LastError = null,
    string? RecipientContactJson = null,
    string? LogicalMessageId = null,
    int ChildIndex = 0,
    int ChildCount = 1,
    DeliveryState DeliveryState = DeliveryState.Pending,
    string? LastRoute = null);

public sealed record MailboxQuarantineRecord(
    string EnvelopeId,
    string SenderKeyId,
    string ReasonCode,
    string ReasonDetail,
    string EnvelopeSha256,
    int EnvelopeSizeBytes,
    long QuarantinedAtUnixMs,
    long? AcknowledgedAtUnixMs = null);

public sealed record DeferredMailboxEnvelopeRecord(
    string EnvelopeId,
    string SenderKeyId,
    string EnvelopeBase64,
    string ReasonCode,
    string ReasonDetail,
    int EnvelopeSizeBytes,
    long FirstDeferredAtUnixMs,
    long LastAttemptAtUnixMs,
    int AttemptCount = 1);

public sealed record SealedEnvelopeRecord(
    string EnvelopeId,
    string PeerKeyId,
    string Path,
    string PayloadKind,
    long CreatedAtUnixMs,
    bool FileExists = true);

public sealed record ReceivedCounterRecord(string SenderKeyId, ulong MessageCounter);

public sealed record IdentityReceivedCounterRecord(
    string RecipientIdentityKeyId,
    string SenderKeyId,
    ulong MessageCounter);

public sealed record InboundFileTransferRecord(
    string TransferId,
    string ConversationId,
    string SenderKeyId,
    string FileName,
    string Mime,
    long TotalSize,
    int ChunkSize,
    int ChunkCount,
    string FileSha256,
    IReadOnlyList<string> ChunkSha256,
    long CreatedAtUnixMs,
    string? CompletedPath = null,
    bool CleanupPending = false);

public sealed record InboundFileChunkRecord(
    string TransferId,
    int ChunkIndex,
    string ChunkSha256,
    string CachePath,
    int Size,
    string SenderKeyId = "",
    int ChunkCount = 0,
    string ConversationId = "",
    long CreatedAtUnixMs = 0);

public sealed class WindowsClientState
{
    public const int CurrentSchemaVersion = 1;
    public const int CounterNamespaceBits = 32;
    public const ulong CounterStride = 1UL << CounterNamespaceBits;
    public const ulong CounterNamespaceMask = CounterStride - 1;

    public int SchemaVersion { get; init; } = CurrentSchemaVersion;
    public string DeviceId { get; set; } = $"windows-{Guid.NewGuid():N}";
    public string? CurrentP2pTicket { get; set; }
    public SecureIdentityRecord? Identity { get; set; }
    public SecureStoreSettings Settings { get; set; } = new();
    public List<StoredContact> Contacts { get; init; } = [];
    public List<ChatMessageRecord> Messages { get; init; } = [];
    public List<GroupRecord> Groups { get; init; } = [];
    public List<GroupMemberRecord> GroupMembers { get; init; } = [];
    public List<GroupEventRecord> GroupEvents { get; init; } = [];
    public List<PendingEnvelopeRecord> PendingEnvelopes { get; init; } = [];
    public List<SealedEnvelopeRecord> SealedEnvelopes { get; init; } = [];
    public List<ReceivedCounterRecord> ReceivedCounters { get; init; } = [];
    public List<IdentityReceivedCounterRecord> ReceivedCounterArchive { get; init; } = [];
    public List<InboundFileTransferRecord> InboundFileTransfers { get; init; } = [];
    public List<InboundFileChunkRecord> InboundFileChunks { get; init; } = [];
    public List<MailboxQuarantineRecord> MailboxQuarantine { get; init; } = [];
    public List<DeferredMailboxEnvelopeRecord> DeferredMailboxEnvelopes { get; init; } = [];
    public List<uint> RetiredCounterNamespaces { get; init; } = [];
    public string? ManagedPlaintextCleanupId { get; set; }
    public uint CounterNamespace { get; set; } = CreateCounterNamespace();
    public ulong NextMessageCounter { get; set; } = 1;

    public void Validate()
    {
        if (SchemaVersion != CurrentSchemaVersion)
        {
            throw new InvalidDataException($"不支持的 Windows 客户端状态版本：{SchemaVersion}。");
        }

        if (CounterNamespace == 0 || CounterNamespace > CounterNamespaceMask)
        {
            CounterNamespace = CreateCounterNamespace(RetiredCounterNamespaces.ToHashSet());
        }
        RetiredCounterNamespaces.RemoveAll(value => value == 0 || value == CounterNamespace);
        var distinctRetired = RetiredCounterNamespaces.Distinct().ToArray();
        RetiredCounterNamespaces.Clear();
        RetiredCounterNamespaces.AddRange(distinctRetired);

        if (NextMessageCounter < CounterStride)
        {
            // Schema-v1 states and Android backups stored a single monotonic
            // counter. Move that high-water into this device's disjoint lane.
            NextMessageCounter = ComposeCounter(Math.Max(1, NextMessageCounter), CounterNamespace);
        }
        else if ((NextMessageCounter & CounterNamespaceMask) != CounterNamespace)
        {
            // The namespace is device-local. Never continue allocating in a
            // namespace imported from another machine.
            var nextSequence = checked(CounterSequence(NextMessageCounter) + 1);
            NextMessageCounter = ComposeCounter(nextSequence, CounterNamespace);
        }

        if (string.IsNullOrWhiteSpace(DeviceId))
        {
            DeviceId = $"windows-{Guid.NewGuid():N}";
        }

        Settings = Settings.Normalize();

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        for (var index = 0; index < InboundFileChunks.Count; index++)
        {
            if (InboundFileChunks[index].CreatedAtUnixMs <= 0)
                InboundFileChunks[index] = InboundFileChunks[index] with { CreatedAtUnixMs = now };
        }
    }

    public StoredContact RequireContact(string keyId) =>
        Contacts.FirstOrDefault(item => string.Equals(item.KeyId, keyId, StringComparison.Ordinal))
        ?? throw new KeyNotFoundException($"没有找到联系人：{keyId}");

    public GroupRecord RequireGroup(string groupId) =>
        Groups.FirstOrDefault(item => string.Equals(item.GroupId, groupId, StringComparison.Ordinal))
        ?? throw new KeyNotFoundException($"没有找到群组：{groupId}");

    public ulong AllocateMessageCounter()
    {
        var value = NextMessageCounter;
        checked { NextMessageCounter += CounterStride; }
        return value;
    }

    public static ulong CounterSequence(ulong counterOrHighWater) =>
        counterOrHighWater < CounterStride ? counterOrHighWater : counterOrHighWater >> CounterNamespaceBits;

    public static ulong ComposeCounter(ulong sequence, uint counterNamespace)
    {
        if (sequence == 0 || sequence > (ulong.MaxValue >> CounterNamespaceBits))
            throw new OverflowException("消息计数器序号超出可编码范围。");
        if (counterNamespace == 0 || counterNamespace > CounterNamespaceMask)
            throw new ArgumentOutOfRangeException(nameof(counterNamespace));
        return checked((sequence << CounterNamespaceBits) | counterNamespace);
    }

    public static uint CreateCounterNamespace(IReadOnlySet<uint>? excludedNamespaces = null)
    {
        uint value;
        do
        {
            value = BitConverter.ToUInt32(RandomNumberGenerator.GetBytes(sizeof(uint)));
        } while (value == 0 || excludedNamespaces?.Contains(value) == true);
        return value;
    }
}

public static class GroupRules
{
    public const int MinimumGroupMembers = 3;

    public static int ConsensusThreshold(int activeMembersExcludingCandidate) =>
        activeMembersExcludingCandidate <= 0
            ? 0
            : checked((activeMembersExcludingCandidate * 6 + 9) / 10);

    public static bool ShouldDissolve(IEnumerable<GroupMemberRecord> members)
    {
        var snapshot = members.ToArray();
        var remaining = snapshot.Count(member => member.Status is not (
            GroupMemberStatus.Left or GroupMemberStatus.Removed));
        var hasActiveOwner = snapshot.Any(member =>
            member.Role == GroupRole.Owner && member.Status == GroupMemberStatus.Active);
        return remaining < MinimumGroupMembers || !hasActiveOwner;
    }

    public static IReadOnlyList<GroupMemberRecord> MessageRecipients(
        GroupRecord group,
        IEnumerable<GroupMemberRecord> members,
        string selfKeyId)
    {
        var snapshot = members.ToArray();
        var self = snapshot.FirstOrDefault(member => member.KeyId == selfKeyId);
        if (self?.Status != GroupMemberStatus.Active)
        {
            throw new InvalidOperationException("你尚未加入该群，不能发送群消息。");
        }

        return snapshot
            .Where(member => member.KeyId != selfKeyId && member.Status == GroupMemberStatus.Active)
            .Where(member => !string.IsNullOrWhiteSpace(member.ContactJson))
            .Where(member => group.Policy != GroupPolicy.Verified || member.TrustState is
                GroupTrustState.Verified or GroupTrustState.Inviter or GroupTrustState.ConsensusAdmitted)
            .ToArray();
    }
}
