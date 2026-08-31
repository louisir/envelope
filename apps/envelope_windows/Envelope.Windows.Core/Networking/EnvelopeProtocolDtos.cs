using System.Text.Json.Serialization;

namespace Envelope.Windows.Core.Networking;

/// <summary>
/// Wire-level DTOs for the Envelope Server v1 protocol. Property names deliberately
/// mirror the Rust <c>serde</c> contracts in envelope-server-core.
/// </summary>
public static class EnvelopeProtocol
{
    public const int Version = 1;
    public const int MaxEnvelopeBytes = 8 * 1024 * 1024;
    public const string StatusOk = "ok";
    public const string DeliveredStatus = "delivered";
}

public sealed record HealthResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status);

public sealed record ContactDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("signing_public")] string SigningPublic,
    [property: JsonPropertyName("agreement_public")] string AgreementPublic,
    [property: JsonPropertyName("key_id")] string KeyId);

public sealed record DeviceEndpointUpdateDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("owner_identity_key_id")] string OwnerIdentityKeyId,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("device_list_version")] long DeviceListVersion,
    [property: JsonPropertyName("p2p_ticket")] string P2pTicket,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("created_at_unix_ms")] long CreatedAtUnixMs,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature)
{
    [JsonIgnore]
    public bool IsExpired => ExpiresAtUnixMs <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

public sealed record DeviceRegistrationRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("owner_contact")] ContactDto OwnerContact,
    [property: JsonPropertyName("endpoint")] DeviceEndpointUpdateDto Endpoint)
{
    public DeviceRegistrationRequestDto(ContactDto ownerContact, DeviceEndpointUpdateDto endpoint)
        : this(EnvelopeProtocol.Version, ownerContact, endpoint)
    {
    }
}

public sealed record DeviceRegistrationResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("owner_identity_key_id")] string OwnerIdentityKeyId,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs);

public sealed record RouteLookupResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("owner_identity_key_id")] string OwnerIdentityKeyId,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("endpoint")] DeviceEndpointUpdateDto? Endpoint)
{
    [JsonIgnore]
    public bool HasEndpoint => Endpoint is not null;
}

public sealed record EnvelopeSubmitRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("envelope_b64")] string EnvelopeBase64,
    [property: JsonPropertyName("envelope_sha256")] string EnvelopeSha256,
    [property: JsonPropertyName("envelope_len")] long EnvelopeLength,
    [property: JsonPropertyName("ttl_seconds")] long? TtlSeconds,
    [property: JsonPropertyName("submitted_at_unix_ms")] long SubmittedAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record EnvelopeSubmitResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("stored_until_unix_ms")] long StoredUntilUnixMs);

public sealed record MailboxEnvelopeDto(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("envelope_b64")] string EnvelopeBase64,
    [property: JsonPropertyName("received_at_unix_ms")] long ReceivedAtUnixMs,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs);

public sealed record MailboxPullRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("limit")] int? Limit,
    [property: JsonPropertyName("requested_at_unix_ms")] long RequestedAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record MailboxPullResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("envelopes")] IReadOnlyList<MailboxEnvelopeDto> Envelopes);

public sealed record MailboxAckRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("recipient_key_id")] string RecipientKeyId,
    [property: JsonPropertyName("envelope_ids")] IReadOnlyList<string> EnvelopeIds,
    [property: JsonPropertyName("acked_at_unix_ms")] long AckedAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record MailboxAckResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("deleted_count")] long DeletedCount);

public sealed record DeliveryStatusRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("envelope_ids")] IReadOnlyList<string> EnvelopeIds,
    [property: JsonPropertyName("requested_at_unix_ms")] long RequestedAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record DeliveryStatusItemDto(
    [property: JsonPropertyName("envelope_id")] string EnvelopeId,
    [property: JsonPropertyName("recipient_key_id")] string? RecipientKeyId,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("delivered_at_unix_ms")] long? DeliveredAtUnixMs)
{
    [JsonIgnore]
    public bool IsDelivered => string.Equals(Status, EnvelopeProtocol.DeliveredStatus, StringComparison.Ordinal);
}

public sealed record DeliveryStatusResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("sender_key_id")] string SenderKeyId,
    [property: JsonPropertyName("items")] IReadOnlyList<DeliveryStatusItemDto> Items);

public sealed record EnvelopeIntroBundleDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("contact")] ContactDto Contact,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("p2p_ticket")] string? P2pTicket,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string> Capabilities,
    [property: JsonPropertyName("created_at_unix_ms")] long CreatedAtUnixMs,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record IntroSessionPublishRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("owner_bundle")] EnvelopeIntroBundleDto OwnerBundle)
{
    public IntroSessionPublishRequestDto(EnvelopeIntroBundleDto ownerBundle)
        : this(EnvelopeProtocol.Version, ownerBundle)
    {
    }
}

public sealed record IntroSessionPublishResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("owner_key_id")] string OwnerKeyId,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs);

public sealed record IntroSessionRespondRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("responder_bundle")] EnvelopeIntroBundleDto ResponderBundle)
{
    public IntroSessionRespondRequestDto(EnvelopeIntroBundleDto responderBundle)
        : this(EnvelopeProtocol.Version, responderBundle)
    {
    }
}

public sealed record IntroSessionRespondResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("responder_key_id")] string ResponderKeyId,
    [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs);

public sealed record IntroSessionPollResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("owner_key_id")] string OwnerKeyId,
    [property: JsonPropertyName("responder_bundle")] EnvelopeIntroBundleDto? ResponderBundle,
    [property: JsonPropertyName("updated_at_unix_ms")] long UpdatedAtUnixMs)
{
    [JsonIgnore]
    public bool HasResponderBundle => ResponderBundle is not null;

    [JsonIgnore]
    public string? ResponderBundleJson => ResponderBundle is null
        ? null
        : System.Text.Json.JsonSerializer.Serialize(ResponderBundle);
}

public sealed record NodeDescriptorDto(
    [property: JsonPropertyName("node_id")] string NodeId,
    [property: JsonPropertyName("base_url")] string BaseUrl,
    [property: JsonPropertyName("public_key")] string PublicKey,
    [property: JsonPropertyName("capabilities")] IReadOnlyList<string> Capabilities,
    [property: JsonPropertyName("weight")] int Weight,
    [property: JsonPropertyName("region")] string? Region,
    [property: JsonPropertyName("valid_until_unix_ms")] long ValidUntilUnixMs);

public sealed record NodeSetManifestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("manifest_id")] string ManifestId,
    [property: JsonPropertyName("epoch")] long Epoch,
    [property: JsonPropertyName("valid_from_unix_ms")] long ValidFromUnixMs,
    [property: JsonPropertyName("valid_until_unix_ms")] long ValidUntilUnixMs,
    [property: JsonPropertyName("prev_manifest_hash")] string? PreviousManifestHash,
    [property: JsonPropertyName("nodes")] IReadOnlyList<NodeDescriptorDto> Nodes,
    [property: JsonPropertyName("revoked_node_ids")] IReadOnlyList<string> RevokedNodeIds,
    [property: JsonPropertyName("signature")] string Signature);

public sealed record NodeChallengeRequestDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("node_id")] string NodeId,
    [property: JsonPropertyName("challenge_b64")] string ChallengeBase64,
    [property: JsonPropertyName("requested_at_unix_ms")] long RequestedAtUnixMs);

public sealed record NodeChallengeResponseDto(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("node_id")] string NodeId,
    [property: JsonPropertyName("challenge_b64")] string ChallengeBase64,
    [property: JsonPropertyName("requested_at_unix_ms")] long RequestedAtUnixMs,
    [property: JsonPropertyName("signed_at_unix_ms")] long SignedAtUnixMs,
    [property: JsonPropertyName("signature")] string Signature);
