using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Native;

/// <summary>
/// Managed surface for every C ABI exported by crates/envelope-ffi.
/// All cryptographic and protocol validation remains authoritative in Rust.
/// </summary>
public interface IEnvelopeNativeClient
{
    System.Text.Json.JsonElement HaV2(string requestJson) =>
        throw new NotSupportedException("当前加密库不支持 HA v2。");

    ProtocolInfo GetProtocolInfo();

    RecoveryPhrase GenerateRecoveryPhrase();

    IdentitySummary RecoverIdentity(string displayName, RecoveryPhrase recoveryPhrase);

    IdentitySummary RecoverIdentity(string displayName, string recoveryPhrase);

    string EncryptLocalBackup(RecoveryPhrase recoveryPhrase, string plaintextJson);

    string DecryptLocalBackup(RecoveryPhrase recoveryPhrase, string backupJson);

    string ContactFromIdentity(string identityJson);

    ContactSummary ParseContact(string contactJson);

    IntroBundleSummary CreateIntroBundle(
        string identityJson,
        string deviceId,
        string p2pTicket = "",
        ulong ttlSeconds = 300);

    IntroBundleSummary VerifyIntroBundle(string bundleJson);

    SignatureSummary SignContextPayload(
        string identityJson,
        string context,
        string payload);

    SignatureVerificationSummary VerifyContactSignature(
        string contactJson,
        string context,
        string payload,
        string signature);

    NodeSetManifestVerificationSummary VerifyNodeSetManifest(
        string manifestJson,
        string manifestSigningPublic,
        ulong nowUnixMs = 0);

    NodeChallengeVerificationSummary VerifyNodeChallenge(
        string requestJson,
        string responseJson,
        string nodePublicKey,
        ulong nowUnixMs = 0,
        ulong maxClockSkewMs = 300_000);

    OutboundOpaqueTextSummary EncryptOpaqueText(
        string identityJson,
        string recipientContactJson,
        string text,
        ulong messageCounter);

    OutboundOpaquePayloadSummary EncryptOpaqueFile(
        string identityJson,
        string recipientContactJson,
        string filename,
        string mime,
        byte[] payloadBytes,
        ulong messageCounter);

    InboundOpaqueTextSummary DecryptOpaqueText(
        string identityJson,
        string senderContactJson,
        string envelopeBase64);

    InboundOpaquePayloadSummary DecryptOpaquePayload(
        string identityJson,
        string senderContactJson,
        string envelopeBase64);

    DeviceEndpointUpdateSummary CreateDeviceEndpointUpdate(
        string identityJson,
        string deviceId,
        string p2pTicket,
        string sessionId,
        ulong deviceListVersion = 1,
        ulong ttlSeconds = 1_800);

    ServerRequestSummary CreateMailboxPullRequest(
        string identityJson,
        uint limit = 50,
        ulong requestedAtUnixMs = 0);

    ServerRequestSummary CreateEnvelopeSubmitRequest(
        string identityJson,
        string recipientKeyId,
        string envelopeId,
        string envelopeBase64,
        ulong ttlSeconds = 0,
        ulong submittedAtUnixMs = 0);

    ServerRequestSummary CreateMailboxAckRequest(
        string identityJson,
        IReadOnlyCollection<string> envelopeIds,
        ulong ackedAtUnixMs = 0);

    ServerRequestSummary CreateDeliveryStatusRequest(
        string identityJson,
        IReadOnlyCollection<string> envelopeIds,
        ulong requestedAtUnixMs = 0);
}
