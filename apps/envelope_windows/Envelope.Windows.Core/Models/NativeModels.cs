using System.Text;
using System.Text.Json.Serialization;

namespace Envelope.Windows.Core.Models;

public sealed record ProtocolInfo(
    [property: JsonPropertyName("protocol_version")] ushort ProtocolVersion,
    [property: JsonPropertyName("opaque_offline_envelope_version")] ushort OpaqueOfflineEnvelopeVersion,
    [property: JsonPropertyName("recovery_word_count")] int RecoveryWordCount,
    [property: JsonPropertyName("contexts")] IReadOnlyList<string> Contexts);

public sealed record IdentitySummary(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("contact_json")] string ContactJson,
    [property: JsonPropertyName("identity_json")] string IdentityJson);

public sealed record ContactSummary(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("contact_json")] string ContactJson)
{
    [JsonIgnore]
    public string Fingerprint => KeyId;
}

public sealed record IntroBundleSummary(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("contact_json")] string ContactJson,
    [property: JsonPropertyName("bundle_json")] string BundleJson,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("p2p_ticket")] string? P2pTicket,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("expires_at_unix_ms")] ulong ExpiresAtUnixMs);

public sealed record SignatureSummary(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record SignatureVerificationSummary(
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("valid")] bool Valid);

public sealed record NodeSetManifestVerificationSummary(
    [property: JsonPropertyName("manifest_id")] string ManifestId,
    [property: JsonPropertyName("epoch")] ulong Epoch,
    [property: JsonPropertyName("node_count")] int NodeCount,
    [property: JsonPropertyName("valid_until_unix_ms")] ulong ValidUntilUnixMs);

public sealed record NodeChallengeVerificationSummary(
    [property: JsonPropertyName("node_id")] string NodeId,
    [property: JsonPropertyName("valid")] bool Valid);

public sealed record OutboundOpaqueTextSummary(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("conversation_id")] string ConversationId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("message_counter")] ulong MessageCounter,
    [property: JsonPropertyName("payload_kind")] string PayloadKind,
    [property: JsonPropertyName("mime")] string Mime,
    [property: JsonPropertyName("filename")] string? Filename,
    [property: JsonPropertyName("envelope_b64")] string EnvelopeBase64,
    [property: JsonPropertyName("envelope_len")] int EnvelopeLength,
    [property: JsonPropertyName("text")] string Text)
{
    [JsonIgnore]
    public byte[] EnvelopeBytes => Base64UrlCodec.Decode(EnvelopeBase64);
}

public sealed record OutboundOpaquePayloadSummary(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("conversation_id")] string ConversationId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("message_counter")] ulong MessageCounter,
    [property: JsonPropertyName("payload_kind")] string PayloadKind,
    [property: JsonPropertyName("mime")] string Mime,
    [property: JsonPropertyName("filename")] string? Filename,
    [property: JsonPropertyName("payload_len")] int PayloadLength,
    [property: JsonPropertyName("envelope_b64")] string EnvelopeBase64,
    [property: JsonPropertyName("envelope_len")] int EnvelopeLength)
{
    [JsonIgnore]
    public byte[] EnvelopeBytes => Base64UrlCodec.Decode(EnvelopeBase64);
}

public sealed record InboundOpaqueTextSummary(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("conversation_id")] string ConversationId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("message_counter")] ulong MessageCounter,
    [property: JsonPropertyName("payload_kind")] string PayloadKind,
    [property: JsonPropertyName("mime")] string Mime,
    [property: JsonPropertyName("filename")] string? Filename,
    [property: JsonPropertyName("text")] string Text);

public sealed record InboundOpaquePayloadSummary(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("conversation_id")] string ConversationId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("message_counter")] ulong MessageCounter,
    [property: JsonPropertyName("payload_kind")] string PayloadKind,
    [property: JsonPropertyName("mime")] string Mime,
    [property: JsonPropertyName("filename")] string? Filename,
    [property: JsonPropertyName("payload_len")] int PayloadLength,
    [property: JsonPropertyName("payload_b64")] string PayloadBase64)
{
    [JsonIgnore]
    public byte[] PayloadBytes => Base64UrlCodec.Decode(PayloadBase64);

    [JsonIgnore]
    public bool IsUtf8Text => string.Equals(
        Mime,
        "text/plain; charset=utf-8",
        StringComparison.OrdinalIgnoreCase);

    public string GetText() => IsUtf8Text
        ? Encoding.UTF8.GetString(PayloadBytes)
        : throw new InvalidOperationException("Opaque payload is not UTF-8 text.");
}

public sealed record DeviceEndpointUpdateSummary(
    [property: JsonPropertyName("owner_key_id")] string OwnerKeyId,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("endpoint_json")] string EndpointJson,
    [property: JsonPropertyName("owner_contact_json")] string OwnerContactJson,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs,
    [property: JsonPropertyName("expires_at_unix_ms")] ulong ExpiresAtUnixMs);

public sealed record ServerRequestSummary(
    [property: JsonPropertyName("request_json")] string RequestJson,
    [property: JsonPropertyName("key_id")] string KeyId,
    [property: JsonPropertyName("created_at_unix_ms")] ulong CreatedAtUnixMs);

internal static class Base64UrlCodec
{
    public static byte[] Decode(string encoded)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(encoded);
        var normalized = encoded.Replace('-', '+').Replace('_', '/');
        normalized = (normalized.Length % 4) switch
        {
            0 => normalized,
            2 => normalized + "==",
            3 => normalized + "=",
            _ => throw new FormatException("Invalid base64url length."),
        };
        return Convert.FromBase64String(normalized);
    }
}
