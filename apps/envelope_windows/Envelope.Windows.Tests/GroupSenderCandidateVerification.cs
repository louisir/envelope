using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Tests;

internal static class GroupSenderCandidateVerification
{
    private const string GroupId = "grp-sender-union";

    public static async Task RunAsync()
    {
        var testRoot = Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.GroupSenderCandidateTests",
            Guid.NewGuid().ToString("N"));
        var paths = new EnvelopePaths(Path.Combine(testRoot, "profile"), Path.Combine(testRoot, "local"));
        var native = new FakeNative();
        var engine = new EnvelopeClientEngine(
            native,
            new MemoryStateStore(),
            paths,
            new DiagnosticLogService(paths.Logs));

        try
        {
            await engine.InitializeAsync();
            SeedGroupOnlyContacts(engine.State);
            Equal(0, engine.State.Contacts.Count, "senders are absent from ordinary contacts");

            var original = engine.State.Groups.Single();
            var renamed = original with { Name = "Renamed by Alice", Epoch = 2, UpdatedAtUnixMs = 2_000 };
            native.RegisterInbound(
                "envelope-from-alice",
                Inbound(
                    "env-alice-event",
                    "alice",
                    1,
                    GroupPayload("group_renamed", "evt-alice-rename", "alice", renamed, engine.State.GroupMembers)));

            var eventResult = await engine.ImportEnvelopeAsync("envelope-from-alice", "alice");
            Require(!eventResult.Duplicate, "Alice group event imported");
            Equal("alice", eventResult.Message.PeerKeyId, "Alice event sender");
            Equal(GroupId, eventResult.Message.ConversationId, "Alice event conversation");
            Equal("Renamed by Alice", engine.State.Groups.Single().Name, "Alice event applied");

            native.RegisterInbound(
                "envelope-from-carol",
                Inbound(
                    "env-carol-message",
                    "carol",
                    2,
                    GroupPayload(
                        "group_message",
                        "evt-carol-message",
                        "carol",
                        renamed,
                        engine.State.GroupMembers,
                        "hello from a group-only contact")));

            var messageResult = await engine.ImportEnvelopeAsync("envelope-from-carol");
            Require(!messageResult.Duplicate, "Carol group message imported");
            Equal("carol", messageResult.Message.PeerKeyId, "Carol message sender");
            Equal(GroupId, messageResult.Message.ConversationId, "Carol message conversation");
            Equal("hello from a group-only contact", messageResult.Message.Text, "Carol message text");

            Require(native.ParsedContactKeyIds.Contains("alice"), "Alice group contact parsed before use");
            Require(native.ParsedContactKeyIds.Contains("carol"), "Carol group contact parsed before use");
            Equal(
                "alice,alice,carol",
                string.Join(',', native.DecryptAttempts),
                "explicit Alice lookup and implicit Carol union traversal");

            Console.WriteLine("[PASS] Group-only sender candidate verification");
        }
        finally
        {
            await engine.DisposeAsync();
            if (Directory.Exists(testRoot)) Directory.Delete(testRoot, recursive: true);
        }
    }

    private static void SeedGroupOnlyContacts(WindowsClientState state)
    {
        state.Identity = new SecureIdentityRecord("identity:bob", "bob", "Bob", 1_000);
        state.Groups.Add(new GroupRecord(
            GroupId,
            "Original",
            "alice",
            GroupPolicy.Normal,
            1,
            1_000,
            1_000,
            "seed"));
        state.GroupMembers.AddRange([
            Member("alice", "Alice", GroupRole.Owner),
            Member("carol", "Carol", GroupRole.Member),
            Member("bob", "Bob", GroupRole.Member),
        ]);
    }

    private static GroupMemberRecord Member(string keyId, string displayName, GroupRole role) => new(
        GroupId,
        keyId,
        displayName,
        $"contact:{keyId}",
        role,
        GroupMemberStatus.Active,
        GroupTrustState.Verified,
        1_000,
        role == GroupRole.Owner ? null : "alice",
        1_000);

    private static byte[] GroupPayload(
        string type,
        string eventId,
        string actorKeyId,
        GroupRecord group,
        IReadOnlyCollection<GroupMemberRecord> members,
        string? text = null)
    {
        var payload = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["type"] = type,
            ["event_id"] = eventId,
            ["actor_key_id"] = actorKeyId,
            ["created_at_unix_ms"] = group.UpdatedAtUnixMs,
            ["group"] = GroupWire(group),
            ["members"] = members.Select(MemberWire).ToArray(),
        };
        if (text is not null) payload["text"] = text;
        payload["signature"] = $"sig:{actorKeyId}";
        return JsonSerializer.SerializeToUtf8Bytes(payload, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    }

    private static Dictionary<string, object?> GroupWire(GroupRecord group) => new()
    {
        ["group_id"] = group.GroupId,
        ["name"] = group.Name,
        ["owner_key_id"] = group.OwnerKeyId,
        ["policy"] = "normal",
        ["epoch"] = group.Epoch,
        ["created_at_unix_ms"] = group.CreatedAtUnixMs,
        ["updated_at_unix_ms"] = group.UpdatedAtUnixMs,
        ["avatar_seed"] = group.AvatarSeed,
        ["is_active"] = group.IsActive ? 1 : 0,
    };

    private static Dictionary<string, object?> MemberWire(GroupMemberRecord member) => new()
    {
        ["group_id"] = member.GroupId,
        ["key_id"] = member.KeyId,
        ["display_name"] = member.DisplayName,
        ["contact_json"] = member.ContactJson,
        ["role"] = member.Role == GroupRole.Owner ? "owner" : "member",
        ["status"] = "active",
        ["trust_state"] = "verified",
        ["invited_by_key_id"] = member.InvitedByKeyId,
        ["joined_at_unix_ms"] = member.JoinedAtUnixMs,
        ["updated_at_unix_ms"] = member.UpdatedAtUnixMs,
    };

    private static InboundOpaquePayloadSummary Inbound(
        string envelopeId,
        string senderKeyId,
        ulong counter,
        byte[] payload) => new(
            envelopeId,
            GroupId,
            senderKeyId,
            "bob",
            2_000 + counter,
            counter,
            "file",
            EnvelopeClientEngine.GroupControlMime,
            "group-control.json",
            payload.Length,
            Base64Url(payload));

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static void Require(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException($"Verification failed: {label}.");
    }

    private static void Equal<T>(T expected, T actual, string label)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException(
                $"Verification failed: {label}; expected '{expected}', actual '{actual}'.");
    }

    private sealed class MemoryStateStore : IClientStateStore
    {
        private WindowsClientState _state = new();

        public Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(_state);

        public Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default)
        {
            _state = state;
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _state = new WindowsClientState();
            return Task.CompletedTask;
        }
    }

    private sealed class FakeNative : IEnvelopeNativeClient
    {
        private readonly Dictionary<string, InboundOpaquePayloadSummary> _inbound = new(StringComparer.Ordinal);

        public HashSet<string> ParsedContactKeyIds { get; } = new(StringComparer.Ordinal);
        public List<string> DecryptAttempts { get; } = [];

        public void RegisterInbound(string envelope, InboundOpaquePayloadSummary payload) =>
            _inbound[envelope] = payload;

        public ContactSummary ParseContact(string contactJson)
        {
            var keyId = ContactKey(contactJson);
            if (keyId.Length == 0) throw new EnvelopeNativeException("invalid fake contact");
            ParsedContactKeyIds.Add(keyId);
            return new ContactSummary(keyId, char.ToUpperInvariant(keyId[0]) + keyId[1..], contactJson);
        }

        public InboundOpaquePayloadSummary DecryptOpaquePayload(
            string identityJson,
            string senderContactJson,
            string envelopeBase64)
        {
            if (!_inbound.TryGetValue(envelopeBase64, out var payload))
                throw new EnvelopeNativeException("unknown fake envelope");
            var attemptedKeyId = ContactKey(senderContactJson);
            DecryptAttempts.Add(attemptedKeyId);
            if (attemptedKeyId != payload.SenderKeyId)
                throw new EnvelopeNativeException("fake sender contact mismatch");
            return payload;
        }

        public SignatureVerificationSummary VerifyContactSignature(
            string contactJson,
            string context,
            string payload,
            string signature)
        {
            var keyId = ContactKey(contactJson);
            return new SignatureVerificationSummary(
                keyId,
                context == EnvelopeClientEngine.GroupEventSignatureContext && signature == $"sig:{keyId}");
        }

        private static string ContactKey(string value) => value.StartsWith("contact:", StringComparison.Ordinal)
            ? value["contact:".Length..]
            : string.Empty;

        public ProtocolInfo GetProtocolInfo() => throw new NotSupportedException();
        public RecoveryPhrase GenerateRecoveryPhrase() => throw new NotSupportedException();
        public IdentitySummary RecoverIdentity(string displayName, RecoveryPhrase recoveryPhrase) => throw new NotSupportedException();
        public IdentitySummary RecoverIdentity(string displayName, string recoveryPhrase) => throw new NotSupportedException();
        public string EncryptLocalBackup(RecoveryPhrase recoveryPhrase, string plaintextJson) => throw new NotSupportedException();
        public string DecryptLocalBackup(RecoveryPhrase recoveryPhrase, string backupJson) => throw new NotSupportedException();
        public string ContactFromIdentity(string identityJson) => throw new NotSupportedException();
        public IntroBundleSummary CreateIntroBundle(string identityJson, string deviceId, string p2pTicket = "", ulong ttlSeconds = 300) => throw new NotSupportedException();
        public IntroBundleSummary VerifyIntroBundle(string bundleJson) => throw new NotSupportedException();
        public SignatureSummary SignContextPayload(string identityJson, string context, string payload) => throw new NotSupportedException();
        public NodeSetManifestVerificationSummary VerifyNodeSetManifest(string manifestJson, string manifestSigningPublic, ulong nowUnixMs = 0) => throw new NotSupportedException();
        public NodeChallengeVerificationSummary VerifyNodeChallenge(string requestJson, string responseJson, string nodePublicKey, ulong nowUnixMs = 0, ulong maxClockSkewMs = 300_000) => throw new NotSupportedException();
        public OutboundOpaqueTextSummary EncryptOpaqueText(string identityJson, string recipientContactJson, string text, ulong messageCounter) => throw new NotSupportedException();
        public OutboundOpaquePayloadSummary EncryptOpaqueFile(string identityJson, string recipientContactJson, string filename, string mime, byte[] payloadBytes, ulong messageCounter) => throw new NotSupportedException();
        public InboundOpaqueTextSummary DecryptOpaqueText(string identityJson, string senderContactJson, string envelopeBase64) => throw new NotSupportedException();
        public DeviceEndpointUpdateSummary CreateDeviceEndpointUpdate(string identityJson, string deviceId, string p2pTicket, string sessionId, ulong deviceListVersion = 1, ulong ttlSeconds = 1_800) => throw new NotSupportedException();
        public ServerRequestSummary CreateMailboxPullRequest(string identityJson, uint limit = 50, ulong requestedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateEnvelopeSubmitRequest(string identityJson, string recipientKeyId, string envelopeId, string envelopeBase64, ulong ttlSeconds = 0, ulong submittedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateMailboxAckRequest(string identityJson, IReadOnlyCollection<string> envelopeIds, ulong ackedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateDeliveryStatusRequest(string identityJson, IReadOnlyCollection<string> envelopeIds, ulong requestedAtUnixMs = 0) => throw new NotSupportedException();
    }
}
