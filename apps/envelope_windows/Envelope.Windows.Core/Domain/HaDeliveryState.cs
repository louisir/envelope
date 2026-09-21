using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;

namespace Envelope.Windows.Core.Domain;

public enum HaStorageState { LocalPending, StagedSingle, Replicated }
public enum HaDeliveryState { Pending, Deferred, Delivered, Rejected, Expired }

/// <summary>Immutable submission identity and independently evidenced states.
/// This is persisted in the same authenticated slot as its original ciphertext.</summary>
public sealed record HaOutboundState(
    string OperationId,
    string SenderKeyId,
    string EnvelopeSha256,
    long NotAfterUnixMs,
    HaStorageState StorageState = HaStorageState.LocalPending,
    HaDeliveryState DeliveryState = HaDeliveryState.Pending,
    string? CommitReceiptJson = null,
    string? RecipientResultJson = null,
    string? ExpiryReceiptJson = null,
    bool LegacyTransportObserved = false)
{
    public const long RetentionMs = 7L * 24 * 60 * 60 * 1000;

    public static HaOutboundState Create(string senderKeyId, string opaqueBase64, long createdAtUnixMs) =>
        new(Guid.NewGuid().ToString("N"), senderKeyId, Hash(opaqueBase64),
            checked(createdAtUnixMs + RetentionMs));

    public void Validate(PendingEnvelopeRecord pending)
    {
        if (string.IsNullOrWhiteSpace(OperationId) || string.IsNullOrWhiteSpace(SenderKeyId) ||
            string.IsNullOrWhiteSpace(EnvelopeSha256) || NotAfterUnixMs <= pending.CreatedAtUnixMs ||
            NotAfterUnixMs - pending.CreatedAtUnixMs > RetentionMs)
            throw new InvalidDataException("待发信封的固定身份或期限无效。");
        if (!string.IsNullOrEmpty(pending.EnvelopeBase64) && Hash(pending.EnvelopeBase64) != EnvelopeSha256)
            throw new InvalidDataException("待发信封内容与已持久化 hash 不一致。");
        if (StorageState != HaStorageState.LocalPending && string.IsNullOrWhiteSpace(CommitReceiptJson))
            throw new InvalidDataException("服务端存储状态缺少验证证据。");
        if (DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected or HaDeliveryState.Deferred &&
            string.IsNullOrWhiteSpace(RecipientResultJson))
            throw new InvalidDataException("业务接收状态缺少收件方签名证据。");
        if (DeliveryState == HaDeliveryState.Expired && string.IsNullOrWhiteSpace(ExpiryReceiptJson))
            throw new InvalidDataException("服务端到期状态缺少正式提交证据。");
    }

    public static string Hash(string opaqueBase64)
    {
        var normalized = opaqueBase64.Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight((normalized.Length + 3) / 4 * 4, '=');
        return Convert.ToBase64String(SHA256.HashData(Convert.FromBase64String(normalized)))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}

/// <summary>Written with the incoming business transaction, before signing.
/// Retries preserve result ID, sequence and receive time across process death.</summary>
public sealed record HaRecipientResultDescriptor(
    string SenderKeyId,
    string RecipientKeyId,
    string EnvelopeId,
    string EnvelopeSha256,
    HaDeliveryState Outcome,
    string? ReasonCode,
    long ReceivedAtUnixMs,
    string ResultId,
    string ResultSequence,
    string? SignedResultJson = null,
    bool Replicated = false,
    string? LogicalMessageId = null,
    long? LastSentAtUnixMs = null,
    bool BusinessApplied = true);

public sealed record HaClusterWatermark(
    string ClusterId,
    string ControlGeneration,
    string ConfigEpoch,
    string LeaderTerm,
    string? ActiveBaseUri = null);

public static class HaSequence
{
    public static BigInteger Parse(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 40 ||
            value.Length > 1 && value[0] == '0' || value.Any(character => character is < '0' or > '9'))
            throw new InvalidDataException("HA 序号必须使用规范十进制字符串。");
        var parsed = BigInteger.Parse(value, CultureInfo.InvariantCulture);
        if (parsed > ulong.MaxValue) throw new InvalidDataException("HA 序号超过 u64 范围。");
        return parsed;
    }
}

public static class HaDeliveryPolling
{
    // Expired remains eligible: a later-arriving recipient proof may establish
    // that durable delivery actually occurred before the envelope deadline.
    public static PendingEnvelopeRecord[] Select(IEnumerable<PendingEnvelopeRecord> records, string? cursor)
    {
        var eligible = records.Where(item => item.Ha is { DeliveryState: HaDeliveryState.Pending or HaDeliveryState.Deferred or HaDeliveryState.Expired })
            .OrderBy(item => item.EnvelopeId, StringComparer.Ordinal).ToArray();
        var next = eligible.Where(item => cursor is null || StringComparer.Ordinal.Compare(item.EnvelopeId, cursor) > 0).Take(100).ToArray();
        return next.Length == 0 ? eligible.Take(100).ToArray() : next;
    }
}
