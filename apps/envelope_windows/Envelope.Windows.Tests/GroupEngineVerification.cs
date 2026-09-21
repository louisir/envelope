using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Tests;

internal static class GroupEngineVerification
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static async Task RunAsync()
    {
        await VerifyOwnerCanInviteAdditionalMembersAsync();
        await VerifyPendingControlRecipientsAsync();
        await VerifyRecipientlessControlPersistsAsync();
        await VerifyGroupFanoutOutboxAsync();
        await VerifyGroupStageFailureRollsBackAsync();
        await VerifyControlDeltaInjectionRejectedAsync();
        await VerifyConcurrentMembershipForksConvergeAsync();
        await VerifyCausalStaleEventsAsync();
        await VerifyAndroidUnicodeSignatureCanonicalizationAsync();
        await VerifyCanonicalInitialInviteAndLocalTrustAsync();
        await VerifyConsensusDeduplicationAndAdmissionAsync();
        await VerifyInboundEndorsementSignatureAsync();
        Console.WriteLine("[PASS] Group invitation and consensus verification");
    }

    private static async Task VerifyRecipientlessControlPersistsAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("owner");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified));

        var result = await fixture.Engine.RenameGroupAsync(group.GroupId, "Persisted without recipients");

        Equal(0, result.DeliveryDetails.Count, "recipientless control has no delivery children");
        Require(fixture.Store.Observations.Any(observation => observation.GroupEventCount == 1),
            "recipientless group control persists its signed event transaction");
    }

    private static async Task VerifyPendingControlRecipientsAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("owner");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Left, GroupTrustState.Unverified));

        var result = await fixture.Engine.RenameGroupAsync(group.GroupId, "Pending recipient coverage");

        Equal(2, result.DeliveryDetails.Count,
            "group controls broadcast to active and pending members but not left members");
        var groupEvent = fixture.Engine.State.GroupEvents.Single(item => item.Type == "group_renamed");
        var recipients = fixture.Engine.State.PendingEnvelopes
            .Where(item => item.LogicalMessageId == $"group-event:{groupEvent.EventId}")
            .Select(item => item.RecipientKeyId)
            .ToHashSet(StringComparer.Ordinal);
        Require(recipients.SetEquals(["bob", "carol"]),
            "pending control recipient is durably staged alongside active recipients");
    }

    private static async Task VerifyOwnerCanInviteAdditionalMembersAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("owner");
        var state = fixture.Engine.State;
        var group = fixture.AddConsensusGroup(
            epoch: 1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("alice", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("dave", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.ConsensusPending,
                invitedBy: "owner"));
        state.Contacts.Add(Contact("carol"));

        var result = await fixture.Engine.InviteGroupMembersAsync(group.GroupId, ["carol", "carol"]);

        Equal(2L, result.Group.Epoch, "additional invitation increments epoch");
        var carol = state.GroupMembers.Single(member => member.GroupId == group.GroupId && member.KeyId == "carol");
        Equal(GroupMemberStatus.Pending, carol.Status, "additional invitee status");
        Equal(GroupTrustState.ConsensusPending, carol.TrustState, "additional invitee trust state");
        Equal("owner", carol.InvitedByKeyId, "additional invitee inviter");
        Equal(4, result.DeliveryDetails.Count,
            "invite broadcasts to new, active, and already-pending members");
        var inviteEvent = state.GroupEvents.Single(item =>
            item.GroupId == group.GroupId && item.Type == "group_invite");
        Require(state.PendingEnvelopes.Any(item =>
                item.LogicalMessageId == $"group-event:{inviteEvent.EventId}" &&
                item.RecipientKeyId == "dave"),
            "additional invite durably stages the event for an existing pending member");
        Equal(1, state.GroupEvents.Count(item => item.GroupId == group.GroupId && item.Type == "group_invite"),
            "additional group_invite event persisted");
    }

    private static async Task VerifyControlDeltaInjectionRejectedAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            5,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("erin", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        fixture.Engine.State.Contacts.AddRange([Contact("bob"), Contact("carol")]);

        var acceptedGroup = group with { Epoch = 6, UpdatedAtUnixMs = group.UpdatedAtUnixMs + 100 };
        var validAcceptedMembers = fixture.Engine.State.GroupMembers
            .Where(member => member.GroupId == group.GroupId)
            .Select(member => member.KeyId == "bob"
                ? member with
                {
                    Status = GroupMemberStatus.Active,
                    TrustState = GroupTrustState.Verified,
                    JoinedAtUnixMs = acceptedGroup.UpdatedAtUnixMs,
                    UpdatedAtUnixMs = acceptedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();

        var jumpedEpoch = acceptedGroup with { Epoch = 9 };
        fixture.Native.RegisterInbound(
            "accepted-epoch-jump",
            InboundGroupControl(jumpedEpoch, validAcceptedMembers, "member_accepted", "bob", 20));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("accepted-epoch-jump", "bob"),
            "member_accepted epoch jump");

        var forgedGroup = acceptedGroup with { Name = "Injected", IsActive = false };
        fixture.Native.RegisterInbound(
            "accepted-group-fields",
            InboundGroupControl(forgedGroup, validAcceptedMembers, "member_accepted", "bob", 21));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("accepted-group-fields", "bob"),
            "member_accepted group metadata injection");

        var ownerInjection = validAcceptedMembers.Select(member => member.KeyId == "owner"
                ? member with
                {
                    Status = GroupMemberStatus.Removed,
                    TrustState = GroupTrustState.Unverified,
                    UpdatedAtUnixMs = acceptedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "accepted-owner-injection",
            InboundGroupControl(acceptedGroup, ownerInjection, "member_accepted", "bob", 22));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("accepted-owner-injection", "bob"),
            "member_accepted owner state injection");
        Equal(5L, fixture.Engine.State.RequireGroup(group.GroupId).Epoch, "rejected accepted events preserve epoch");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "owner").Status,
            "rejected accepted events preserve owner");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter is not (20 or 21 or 22)),
            "rejected accepted injections do not consume counters");

        fixture.Native.RegisterInbound(
            "accepted-valid",
            InboundGroupControl(acceptedGroup, validAcceptedMembers, "member_accepted", "bob", 23));
        await fixture.ImportEnvelopeAsync("accepted-valid", "bob");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "bob").Status,
            "valid member_accepted applies actor delta");

        var current = fixture.Engine.State.RequireGroup(group.GroupId);
        var leftGroup = current with { Epoch = current.Epoch + 1, UpdatedAtUnixMs = current.UpdatedAtUnixMs + 100 };
        var validLeftMembers = fixture.Engine.State.GroupMembers
            .Where(member => member.GroupId == group.GroupId)
            .Select(member => member.KeyId == "carol"
                ? member with
                {
                    Status = GroupMemberStatus.Left,
                    TrustState = GroupTrustState.Verified,
                    UpdatedAtUnixMs = leftGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        var bystanderInjection = validLeftMembers.Select(member => member.KeyId == "erin"
                ? member with
                {
                    Status = GroupMemberStatus.Removed,
                    TrustState = GroupTrustState.Unverified,
                    UpdatedAtUnixMs = leftGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "left-bystander-injection",
            InboundGroupControl(leftGroup, bystanderInjection, "member_left", "carol", 24));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("left-bystander-injection", "carol"),
            "member_left bystander state injection");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "erin").Status,
            "rejected member_left preserves bystander");

        fixture.Native.RegisterInbound(
            "left-valid",
            InboundGroupControl(leftGroup, validLeftMembers, "member_left", "carol", 25));
        await fixture.ImportEnvelopeAsync("left-valid", "carol");
        Equal(GroupMemberStatus.Left,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "carol").Status,
            "valid member_left applies only actor delta");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "erin").Status,
            "valid member_left preserves bystander");

        current = fixture.Engine.State.RequireGroup(group.GroupId);
        var removedGroup = current with { Epoch = current.Epoch + 1, UpdatedAtUnixMs = current.UpdatedAtUnixMs + 100 };
        var validRemovedMembers = fixture.Engine.State.GroupMembers
            .Where(member => member.GroupId == group.GroupId)
            .Select(member => member.KeyId == "bob"
                ? member with
                {
                    Status = GroupMemberStatus.Removed,
                    TrustState = GroupTrustState.Unverified,
                    UpdatedAtUnixMs = removedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        var removalBystanderInjection = validRemovedMembers.Select(member => member.KeyId == "dave"
                ? member with
                {
                    Status = GroupMemberStatus.Left,
                    TrustState = GroupTrustState.Verified,
                    UpdatedAtUnixMs = removedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        var removeExtra = new Dictionary<string, object?> { ["target_key_id"] = "bob" };
        fixture.Native.RegisterInbound(
            "removed-bystander-injection",
            InboundGroupControl(
                removedGroup,
                removalBystanderInjection,
                "member_removed",
                "owner",
                26,
                removeExtra));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("removed-bystander-injection", "owner"),
            "member_removed bystander state injection");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "dave").Status,
            "rejected member_removed preserves bystander");

        fixture.Native.RegisterInbound(
            "removed-valid",
            InboundGroupControl(removedGroup, validRemovedMembers, "member_removed", "owner", 27, removeExtra));
        await fixture.ImportEnvelopeAsync("removed-valid", "owner");
        Equal(GroupMemberStatus.Removed,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "bob").Status,
            "valid member_removed applies only target delta");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "dave").Status,
            "valid member_removed preserves bystander");
    }

    private static async Task VerifyGroupFanoutOutboxAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("owner");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            4,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var initialPending = fixture.Engine.State.PendingEnvelopes.Count;
        var initialEvents = fixture.Engine.State.GroupEvents.Count;
        var initialSaves = fixture.Store.Observations.Count;
        fixture.Native.EncryptedCounters.Clear();

        var message = await fixture.Engine.SendGroupTextAsync(group.GroupId, "durable fanout");

        var children = fixture.Engine.State.PendingEnvelopes
            .Where(item => item.LogicalMessageId == message.LogicalMessageId)
            .OrderBy(item => item.ChildIndex)
            .ToArray();
        Equal(2, children.Length, "group text stages every recipient child");
        Require(children.All(item => item.ChildCount == 2), "group child count is stable");
        Equal("0,1", string.Join(',', children.Select(item => item.ChildIndex)), "group child indexes");
        Equal(message.MessageCounter, fixture.Native.EncryptedCounters[0], "logical message uses first reserved counter");
        Require(message.MessageCounter != fixture.Engine.State.NextMessageCounter - 1,
            "group message does not derive counter using stride-unsafe subtraction");
        var firstOutboxSave = fixture.Store.Observations
            .Skip(initialSaves)
            .First(item => item.PendingCount > initialPending);
        Require(firstOutboxSave.MessageCount > 0, "logical message is atomic with first outbox save");
        Require(firstOutboxSave.GroupEventCount > initialEvents, "group event is atomic with first outbox save");
    }

    private static async Task VerifyGroupStageFailureRollsBackAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("owner");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            4,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var membersBefore = fixture.Engine.State.GroupMembers.ToArray();
        var eventsBefore = fixture.Engine.State.GroupEvents.ToArray();
        var pendingBefore = fixture.Engine.State.PendingEnvelopes.ToArray();
        var messagesBefore = fixture.Engine.State.Messages.ToArray();
        var counterBefore = fixture.Engine.State.NextMessageCounter;
        fixture.Store.SuccessfulSavesBeforeFailure = 1;

        await ExpectAsync<IOException>(
            () => fixture.Engine.RenameGroupAsync(group.GroupId, "must roll back"),
            "group batch stage persistence failure");

        Equal(group, fixture.Engine.State.RequireGroup(group.GroupId),
            "failed batch stage restores group record");
        Require(membersBefore.SequenceEqual(fixture.Engine.State.GroupMembers),
            "failed batch stage restores member records");
        Require(eventsBefore.SequenceEqual(fixture.Engine.State.GroupEvents),
            "failed batch stage restores group event records");
        Require(pendingBefore.SequenceEqual(fixture.Engine.State.PendingEnvelopes),
            "failed batch stage restores pending outbox");
        Require(messagesBefore.SequenceEqual(fixture.Engine.State.Messages),
            "failed batch stage restores logical messages");
        Require(fixture.Engine.State.NextMessageCounter > counterBefore,
            "failed batch stage burns already-durable reserved counters");
    }

    private static async Task VerifyConcurrentMembershipForksConvergeAsync()
    {
        var acceptedForward = await RunConcurrentAcceptedForkAsync(firstActor: "bob", injectBystander: true);
        var acceptedReverse = await RunConcurrentAcceptedForkAsync(firstActor: "carol", injectBystander: false);
        Equal(acceptedForward, acceptedReverse, "same-epoch member_accepted forks converge independent of order");

        var mixedForward = await RunConcurrentAcceptedEndorsedForkAsync(acceptFirst: true);
        var mixedReverse = await RunConcurrentAcceptedEndorsedForkAsync(acceptFirst: false);
        Equal(mixedForward, mixedReverse, "same-epoch accepted/endorsed forks converge independent of order");
    }

    private static async Task<string> RunConcurrentAcceptedForkAsync(
        string firstActor,
        bool injectBystander)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            5,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("erin", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        var bobGroup = group with { Epoch = 6, UpdatedAtUnixMs = 2_000 };
        var carolGroup = group with { Epoch = 6, UpdatedAtUnixMs = 2_100 };
        var bobMembers = AcceptedMembers(baseline, "bob", bobGroup.UpdatedAtUnixMs, consensus: false);
        var carolMembers = AcceptedMembers(baseline, "carol", carolGroup.UpdatedAtUnixMs, consensus: false);
        fixture.Native.RegisterInbound(
            "fork-bob",
            InboundGroupControl(bobGroup, bobMembers, "member_accepted", "bob", 40));
        fixture.Native.RegisterInbound(
            "fork-carol",
            InboundGroupControl(carolGroup, carolMembers, "member_accepted", "carol", 41));

        var firstEnvelope = firstActor == "bob" ? "fork-bob" : "fork-carol";
        var secondEnvelope = firstActor == "bob" ? "fork-carol" : "fork-bob";
        await fixture.ImportEnvelopeAsync(firstEnvelope, firstActor);
        if (injectBystander)
        {
            var injected = carolMembers.Select(member => member.KeyId == "owner"
                    ? member with { Status = GroupMemberStatus.Removed, UpdatedAtUnixMs = 2_100 }
                    : member)
                .ToArray();
            fixture.Native.RegisterInbound(
                "fork-injected",
                InboundGroupControl(carolGroup, injected, "member_accepted", "carol", 42));
            await ExpectAsync<InvalidDataException>(
                () => fixture.ImportEnvelopeAsync("fork-injected", "carol"),
                "concurrent accepted fork rejects bystander injection");
            Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 42),
                "rejected concurrent fork does not consume counter");
        }
        await fixture.ImportEnvelopeAsync(secondEnvelope, firstActor == "bob" ? "carol" : "bob");

        var stored = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId)
            .OrderBy(item => item.KeyId)
            .Select(item => $"{item.KeyId}:{item.Status}:{item.JoinedAtUnixMs}");
        return $"{fixture.Engine.State.RequireGroup(group.GroupId).Epoch}:" +
               $"{fixture.Engine.State.RequireGroup(group.GroupId).UpdatedAtUnixMs}:" +
               string.Join('|', stored);
    }

    private static async Task<string> RunConcurrentAcceptedEndorsedForkAsync(bool acceptFirst)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddConsensusGroup(
            5,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.ConsensusPending, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("erin", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("candidate", GroupRole.Member, GroupMemberStatus.Accepted, GroupTrustState.ConsensusPending,
                invitedBy: "owner"));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        var acceptedGroup = group with { Epoch = 6, UpdatedAtUnixMs = 2_000 };
        var endorsedGroup = group with { Epoch = 6, UpdatedAtUnixMs = 2_100 };
        fixture.Native.RegisterInbound(
            "mixed-accepted",
            InboundGroupControl(
                acceptedGroup,
                AcceptedMembers(baseline, "bob", acceptedGroup.UpdatedAtUnixMs, consensus: true),
                "member_accepted",
                "bob",
                50));
        fixture.Native.RegisterInbound(
            "mixed-endorsed",
            InboundGroupEnvelope(
                endorsedGroup,
                baseline,
                "candidate",
                "carol",
                51,
                validInnerSignature: true));
        if (acceptFirst)
        {
            await fixture.ImportEnvelopeAsync("mixed-accepted", "bob");
            await fixture.ImportEnvelopeAsync("mixed-endorsed", "carol");
        }
        else
        {
            await fixture.ImportEnvelopeAsync("mixed-endorsed", "carol");
            await fixture.ImportEnvelopeAsync("mixed-accepted", "bob");
        }
        var stored = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId)
            .OrderBy(item => item.KeyId)
            .Select(item => $"{item.KeyId}:{item.Status}:{item.TrustState}");
        return $"{fixture.Engine.State.RequireGroup(group.GroupId).Epoch}:" +
               $"{fixture.Engine.State.RequireGroup(group.GroupId).UpdatedAtUnixMs}:" +
               string.Join('|', stored);
    }

    private static async Task VerifyCausalStaleEventsAsync()
    {
        var ownerFirst = await RunStaleAcceptedMetadataForkAsync(ownerFirst: true);
        var memberFirst = await RunStaleAcceptedMetadataForkAsync(ownerFirst: false);
        Equal(ownerFirst, memberFirst,
            "stale member_accepted and owner metadata chain converge independent of arrival order");
        var acceptFirst = await RunConcurrentAcceptRemoveForkAsync(acceptFirst: true);
        var removeFirst = await RunConcurrentAcceptRemoveForkAsync(acceptFirst: false);
        Equal(acceptFirst, removeFirst,
            "concurrent owner removal deterministically dominates member acceptance");
        var acceptBeforeInvite = await RunConcurrentAcceptInviteForkAsync(acceptFirst: true);
        var inviteBeforeAccept = await RunConcurrentAcceptInviteForkAsync(acceptFirst: false);
        Equal(acceptBeforeInvite, inviteBeforeAccept,
            "concurrent owner invitation and member acceptance converge independent of arrival order");
        await VerifyStaleLeftAndEndorsementAsync();
        await VerifyStaleGroupMessageAuthorizationAsync();
    }

    private static async Task VerifyAndroidUnicodeSignatureCanonicalizationAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            2,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));

        // This byte-for-byte vector is produced by Dart jsonEncode. It intentionally covers
        // non-ASCII text, a surrogate-pair emoji, HTML-sensitive characters, JSON controls,
        // a quote and a backslash. Do not rebuild it with the C# serializer in this test.
        const string dartUnsignedJson =
            """{"version":1,"type":"group_message","event_id":"gvt-vector","actor_key_id":"bob","created_at_unix_ms":1700000000123,"group":{"group_id":"grp-consensus-test","name":"中文😀<&>\n\t\u0001\"\\","owner_key_id":"owner","policy":"normal","epoch":1,"created_at_unix_ms":1000,"updated_at_unix_ms":1001,"avatar_seed":"种子😀<&>","is_active":1},"members":[{"group_id":"grp-consensus-test","key_id":"bob","display_name":"成员😀<&>","contact_json":"{\"name\":\"联系😀<&>\"}","role":"member","status":"active","trust_state":"inviter","invited_by_key_id":"owner","joined_at_unix_ms":1000,"updated_at_unix_ms":1000}],"text":"消息😀<&>\n\t\u0001\"\\"}""";
        var signature = FakeNative.Sign(
            "bob",
            EnvelopeClientEngine.GroupEventSignatureContext,
            dartUnsignedJson);
        var signedJson = dartUnsignedJson[..^1] + ",\"signature\":\"" + signature + "\"}";
        var bytes = Encoding.UTF8.GetBytes(signedJson);
        fixture.Native.RegisterInbound(
            "dart-unicode-vector",
            new InboundOpaquePayloadSummary(
                "env-dart-unicode-vector",
                group.GroupId,
                "bob",
                "dave",
                1_700_000_000_123,
                87,
                "file",
                EnvelopeClientEngine.GroupControlMime,
                "group-control.json",
                bytes.Length,
                Base64Url(bytes)));

        EnvelopeImportResult imported;
        try
        {
            imported = await fixture.ImportEnvelopeAsync("dart-unicode-vector", "bob");
        }
        catch (InvalidDataException)
        {
            Equal(dartUnsignedJson, fixture.Native.VerifiedPayloads.Last(),
                "Dart and Windows unsigned group JSON diagnostic");
            throw;
        }
        Equal("消息😀<&>\n\t\u0001\"\\", imported.Message.Text,
            "Windows verifies and decodes the Dart Unicode group signature vector");
        Require(fixture.Native.VerifiedPayloads.Contains(dartUnsignedJson, StringComparer.Ordinal),
            "Windows signature reconstruction is byte-identical to Dart jsonEncode");

        const string outboundText = "消息😀<&>\n\t\u0001\"\\";
        await fixture.Engine.SendGroupTextAsync(group.GroupId, outboundText);
        var outboundSigningJson = fixture.Native.SignedPayloads.Last(item =>
            item.Context == EnvelopeClientEngine.GroupEventSignatureContext).Payload;
        Require(outboundSigningJson.Contains(
                "\"text\":\"消息😀<&>\\n\\t\\u0001\\\"\\\\\"",
                StringComparison.Ordinal),
            "Windows outbound group signature uses Dart-compatible Unicode and control escaping");
        Require(!outboundSigningJson.Contains("\\u4e2d", StringComparison.OrdinalIgnoreCase) &&
                !outboundSigningJson.Contains("\\u003c", StringComparison.OrdinalIgnoreCase) &&
                !outboundSigningJson.Contains("\\u003e", StringComparison.OrdinalIgnoreCase) &&
                !outboundSigningJson.Contains("\\u0026", StringComparison.OrdinalIgnoreCase),
            "Windows outbound group signature does not apply incompatible Unicode or HTML escaping");
    }

    private static async Task<string> RunStaleAcceptedMetadataForkAsync(bool ownerFirst)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("erin", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        fixture.Engine.State.GroupEvents.Add(
            SnapshotEvent(group, baseline, "group_invite", "owner", "history-invite"));

        var renamed = group with { Name = "Renamed", Epoch = 2, UpdatedAtUnixMs = 2_000 };
        var avatar = renamed with { AvatarSeed = "avatar-v2", Epoch = 3, UpdatedAtUnixMs = 3_000 };
        var accepted = group with { Epoch = 2, UpdatedAtUnixMs = 2_500 };
        var acceptedMembers = AcceptedMembers(baseline, "bob", accepted.UpdatedAtUnixMs, consensus: false);
        fixture.Native.RegisterInbound(
            "causal-rename",
            InboundGroupControl(renamed, baseline, "group_renamed", "owner", 70, eventId: "causal-rename"));
        fixture.Native.RegisterInbound(
            "causal-avatar",
            InboundGroupControl(avatar, baseline, "group_avatar_updated", "owner", 71, eventId: "causal-avatar"));
        fixture.Native.RegisterInbound(
            "causal-accept",
            InboundGroupControl(
                accepted,
                acceptedMembers,
                "member_accepted",
                "bob",
                72,
                eventId: "causal-accept"));

        if (ownerFirst)
        {
            await fixture.ImportEnvelopeAsync("causal-rename", "owner");
            await fixture.ImportEnvelopeAsync("causal-avatar", "owner");

            var injected = acceptedMembers.Select(member => member.KeyId == "carol"
                    ? member with
                    {
                        Status = GroupMemberStatus.Removed,
                        TrustState = GroupTrustState.Unverified,
                        UpdatedAtUnixMs = accepted.UpdatedAtUnixMs,
                    }
                    : member)
                .ToArray();
            fixture.Native.RegisterInbound(
                "causal-injected",
                InboundGroupControl(
                    accepted,
                    injected,
                    "member_accepted",
                    "bob",
                    73,
                    eventId: "causal-injected"));
            await ExpectAsync<InvalidDataException>(
                () => fixture.ImportEnvelopeAsync("causal-injected", "bob"),
                "stale accepted fork rejects bystander injection");
            Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 73),
                "rejected stale bystander injection does not consume counter");
            await fixture.ImportEnvelopeAsync("causal-accept", "bob");

            var acceptedEventCount = fixture.Engine.State.GroupEvents.Count(item => item.EventId == "causal-accept");
            fixture.Native.RegisterInbound(
                "causal-accept-replay",
                InboundGroupControl(
                    accepted,
                    acceptedMembers,
                    "member_accepted",
                    "bob",
                    74,
                    eventId: "causal-accept"));
            await fixture.ImportEnvelopeAsync("causal-accept-replay", "bob");
            Equal(acceptedEventCount,
                fixture.Engine.State.GroupEvents.Count(item => item.EventId == "causal-accept"),
                "event_id replay is idempotent");
        }
        else
        {
            await fixture.ImportEnvelopeAsync("causal-accept", "bob");
            await fixture.ImportEnvelopeAsync("causal-rename", "owner");
            await fixture.ImportEnvelopeAsync("causal-avatar", "owner");
        }

        var storedGroup = fixture.Engine.State.RequireGroup(group.GroupId);
        Equal(3L, storedGroup.Epoch, "causal merge keeps highest group epoch");
        Equal("Renamed", storedGroup.Name, "causal merge keeps owner rename");
        Equal("avatar-v2", storedGroup.AvatarSeed, "causal merge keeps owner avatar");
        Equal(GroupMemberStatus.Active,
            fixture.Engine.State.GroupMembers.Single(item => item.GroupId == group.GroupId && item.KeyId == "bob").Status,
            "causal merge applies stale accepted target delta");
        return CausalStateFingerprint(fixture.Engine.State, group.GroupId);
    }

    private static async Task<string> RunConcurrentAcceptRemoveForkAsync(bool acceptFirst)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        fixture.Engine.State.GroupEvents.Add(
            SnapshotEvent(group, baseline, "group_invite", "owner", "accept-remove-history"));
        var acceptedGroup = group with { Epoch = 2, UpdatedAtUnixMs = 2_200 };
        var acceptedMembers = AcceptedMembers(baseline, "bob", acceptedGroup.UpdatedAtUnixMs, consensus: false);
        var removedGroup = group with { Epoch = 2, UpdatedAtUnixMs = 2_300 };
        var removedMembers = baseline.Select(member => member.KeyId == "bob"
                ? member with
                {
                    Status = GroupMemberStatus.Removed,
                    TrustState = GroupTrustState.Unverified,
                    UpdatedAtUnixMs = removedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "accept-remove-accepted",
            InboundGroupControl(
                acceptedGroup,
                acceptedMembers,
                "member_accepted",
                "bob",
                88,
                eventId: "accept-remove-accepted"));
        fixture.Native.RegisterInbound(
            "accept-remove-removed",
            InboundGroupControl(
                removedGroup,
                removedMembers,
                "member_removed",
                "owner",
                89,
                new Dictionary<string, object?> { ["target_key_id"] = "bob" },
                eventId: "accept-remove-removed"));
        if (acceptFirst)
        {
            await fixture.ImportEnvelopeAsync("accept-remove-accepted", "bob");
            await fixture.ImportEnvelopeAsync("accept-remove-removed", "owner");
        }
        else
        {
            await fixture.ImportEnvelopeAsync("accept-remove-removed", "owner");
            await ExpectAsync<InvalidDataException>(
                () => fixture.ImportEnvelopeAsync("accept-remove-accepted", "bob"),
                "owner removal prevents a concurrent stale acceptance from reactivating target");
            Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 88),
                "rejected post-removal acceptance does not consume counter");
        }
        var storedGroup = fixture.Engine.State.RequireGroup(group.GroupId);
        var bob = fixture.Engine.State.GroupMembers.Single(item => item.KeyId == "bob");
        Equal(GroupMemberStatus.Removed, bob.Status, "owner removal dominates concurrent acceptance");
        return $"{storedGroup.Epoch}:{storedGroup.UpdatedAtUnixMs}:{storedGroup.IsActive}:" +
               $"{bob.Status}:{bob.TrustState}:{bob.UpdatedAtUnixMs}";
    }

    private static async Task<string> RunConcurrentAcceptInviteForkAsync(bool acceptFirst)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner"),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        fixture.Engine.State.GroupEvents.Add(
            SnapshotEvent(group, baseline, "group_invite", "owner", "accept-invite-history"));
        var acceptedGroup = group with { Epoch = 2, UpdatedAtUnixMs = 2_200 };
        var acceptedMembers = AcceptedMembers(baseline, "bob", acceptedGroup.UpdatedAtUnixMs, consensus: false);
        var inviteGroup = group with { Epoch = 2, UpdatedAtUnixMs = 2_300 };
        var invited = Member(
            "erin",
            GroupRole.Member,
            GroupMemberStatus.Pending,
            GroupTrustState.Inviter,
            invitedBy: "owner") with
        {
            JoinedAtUnixMs = null,
            UpdatedAtUnixMs = inviteGroup.UpdatedAtUnixMs,
        };
        var inviteMembers = baseline.Append(invited).ToArray();
        fixture.Native.RegisterInbound(
            "accept-invite-accepted",
            InboundGroupControl(
                acceptedGroup,
                acceptedMembers,
                "member_accepted",
                "bob",
                90,
                eventId: "accept-invite-accepted"));
        fixture.Native.RegisterInbound(
            "accept-invite-invited",
            InboundGroupControl(
                inviteGroup,
                inviteMembers,
                "group_invite",
                "owner",
                91,
                eventId: "accept-invite-invited"));
        if (acceptFirst)
        {
            await fixture.ImportEnvelopeAsync("accept-invite-accepted", "bob");
            await fixture.ImportEnvelopeAsync("accept-invite-invited", "owner");
        }
        else
        {
            await fixture.ImportEnvelopeAsync("accept-invite-invited", "owner");
            await fixture.ImportEnvelopeAsync("accept-invite-accepted", "bob");
        }
        var storedGroup = fixture.Engine.State.RequireGroup(group.GroupId);
        var bob = fixture.Engine.State.GroupMembers.Single(item => item.KeyId == "bob");
        var erin = fixture.Engine.State.GroupMembers.Single(item => item.KeyId == "erin");
        Equal(GroupMemberStatus.Active, bob.Status,
            "concurrent invitation preserves accepted existing member");
        Equal(GroupMemberStatus.Pending, erin.Status,
            "concurrent invitation adds canonical pending member");
        var members = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId)
            .OrderBy(item => item.KeyId)
            .Select(item => $"{item.KeyId}:{item.Status}:{item.TrustState}:{item.UpdatedAtUnixMs}");
        return $"{storedGroup.Epoch}:{storedGroup.UpdatedAtUnixMs}:{string.Join('|', members)}";
    }

    private static async Task VerifyStaleLeftAndEndorsementAsync()
    {
        await using (var fixture = await GroupFixture.CreateAsync("dave"))
        {
            var group = fixture.AddGroup(
                GroupPolicy.Normal,
                1,
                Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
                Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
                Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
                Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
                Member("erin", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
            var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
            fixture.Engine.State.GroupEvents.Add(
                SnapshotEvent(group, baseline, "group_invite", "owner", "left-history"));
            var renamed = group with { Name = "After rename", Epoch = 2, UpdatedAtUnixMs = 2_000 };
            var avatar = renamed with { AvatarSeed = "after-avatar", Epoch = 3, UpdatedAtUnixMs = 3_000 };
            fixture.Native.RegisterInbound(
                "left-rename",
                InboundGroupControl(renamed, baseline, "group_renamed", "owner", 75));
            fixture.Native.RegisterInbound(
                "left-avatar",
                InboundGroupControl(avatar, baseline, "group_avatar_updated", "owner", 76));
            await fixture.ImportEnvelopeAsync("left-rename", "owner");
            await fixture.ImportEnvelopeAsync("left-avatar", "owner");

            var leftGroup = group with { Epoch = 2, UpdatedAtUnixMs = 2_400 };
            var leftMembers = baseline.Select(member => member.KeyId == "carol"
                    ? member with
                    {
                        Status = GroupMemberStatus.Left,
                        TrustState = GroupTrustState.Verified,
                        UpdatedAtUnixMs = leftGroup.UpdatedAtUnixMs,
                    }
                    : member)
                .ToArray();
            fixture.Native.RegisterInbound(
                "stale-left",
                InboundGroupControl(leftGroup, leftMembers, "member_left", "carol", 77));
            await fixture.ImportEnvelopeAsync("stale-left", "carol");
            Equal(GroupMemberStatus.Left,
                fixture.Engine.State.GroupMembers.Single(item => item.KeyId == "carol").Status,
                "causal stale member_left applies actor delta");
            Equal(3L, fixture.Engine.State.RequireGroup(group.GroupId).Epoch,
                "stale member_left does not roll back group epoch");
        }

        await using (var fixture = await GroupFixture.CreateAsync("dave"))
        {
            var group = fixture.AddConsensusGroup(
                2,
                Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
                Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
                Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
                Member("candidate", GroupRole.Member, GroupMemberStatus.Accepted, GroupTrustState.ConsensusPending,
                    invitedBy: "owner"));
            var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
            fixture.Engine.State.GroupEvents.Add(
                SnapshotEvent(group, baseline, "member_accepted", "candidate", "endorse-history"));
            fixture.Engine.State.GroupEvents.Add(
                EndorsementEvent(group, "candidate", "dave", 2, "existing-endorsement"));
            var renamed = group with { Name = "Consensus renamed", Epoch = 3, UpdatedAtUnixMs = 2_600 };
            var avatar = renamed with { AvatarSeed = "consensus-avatar", Epoch = 4, UpdatedAtUnixMs = 3_600 };
            fixture.Native.RegisterInbound(
                "endorse-rename",
                InboundGroupControl(renamed, baseline, "group_renamed", "owner", 78));
            fixture.Native.RegisterInbound(
                "endorse-avatar",
                InboundGroupControl(avatar, baseline, "group_avatar_updated", "owner", 79));
            await fixture.ImportEnvelopeAsync("endorse-rename", "owner");
            await fixture.ImportEnvelopeAsync("endorse-avatar", "owner");

            var endorsedGroup = group with { Epoch = 3, UpdatedAtUnixMs = 2_800 };
            var injected = baseline.Select(member => member.KeyId == "owner"
                    ? member with { Status = GroupMemberStatus.Removed, UpdatedAtUnixMs = 2_800 }
                    : member)
                .ToArray();
            fixture.Native.RegisterInbound(
                "stale-endorse-injected",
                InboundGroupEnvelope(
                    endorsedGroup,
                    injected,
                    "candidate",
                    "carol",
                    80,
                    validInnerSignature: true));
            await ExpectAsync<InvalidDataException>(
                () => fixture.ImportEnvelopeAsync("stale-endorse-injected", "carol"),
                "stale endorsement rejects bystander injection");
            Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 80),
                "rejected stale endorsement does not consume counter");

            fixture.Native.RegisterInbound(
                "stale-endorse",
                InboundGroupEnvelope(
                    endorsedGroup,
                    baseline,
                    "candidate",
                    "carol",
                    81,
                    validInnerSignature: true));
            await fixture.ImportEnvelopeAsync("stale-endorse", "carol");
            Equal(GroupMemberStatus.Active,
                fixture.Engine.State.GroupMembers.Single(item => item.KeyId == "candidate").Status,
                "causal stale endorsement participates in consensus admission");
            Equal(4L, fixture.Engine.State.RequireGroup(group.GroupId).Epoch,
                "stale endorsement does not roll back group epoch");
        }
    }

    private static async Task VerifyStaleGroupMessageAuthorizationAsync()
    {
        var ownerFirst = await RunStaleGroupMessageOrderAsync(ownerFirst: true);
        var messageFirst = await RunStaleGroupMessageOrderAsync(ownerFirst: false);
        Equal(ownerFirst, messageFirst,
            "stale group_message and rename converge independent of arrival order");

        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        fixture.Engine.State.GroupEvents.Add(
            SnapshotEvent(group, baseline, "group_invite", "owner", "message-remove-history"));
        var renamed = group with { Name = "Before removal", Epoch = 2, UpdatedAtUnixMs = 2_000 };
        fixture.Native.RegisterInbound(
            "message-remove-rename",
            InboundGroupControl(renamed, baseline, "group_renamed", "owner", 84));
        await fixture.ImportEnvelopeAsync("message-remove-rename", "owner");

        var removedGroup = renamed with { Epoch = 3, UpdatedAtUnixMs = 3_000 };
        var removedMembers = baseline.Select(member => member.KeyId == "bob"
                ? member with
                {
                    Status = GroupMemberStatus.Removed,
                    TrustState = GroupTrustState.Unverified,
                    UpdatedAtUnixMs = removedGroup.UpdatedAtUnixMs,
                }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "message-remove-bob",
            InboundGroupControl(
                removedGroup,
                removedMembers,
                "member_removed",
                "owner",
                85,
                new Dictionary<string, object?> { ["target_key_id"] = "bob" }));
        await fixture.ImportEnvelopeAsync("message-remove-bob", "owner");

        fixture.Native.RegisterInbound(
            "message-after-remove",
            InboundGroupControl(
                group,
                baseline,
                "group_message",
                "bob",
                86,
                new Dictionary<string, object?> { ["text"] = "forged stale after removal" },
                eventId: "post-removal-stale"));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("message-after-remove", "bob"),
            "removed member cannot backdate a newly signed stale group_message");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 86),
            "rejected post-removal stale message does not consume counter");
    }

    private static async Task<string> RunStaleGroupMessageOrderAsync(bool ownerFirst)
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddGroup(
            GroupPolicy.Normal,
            1,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter));
        var baseline = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId).ToArray();
        fixture.Engine.State.GroupEvents.Add(
            SnapshotEvent(group, baseline, "group_invite", "owner", "message-history"));
        var renamed = group with { Name = "Message rename", Epoch = 2, UpdatedAtUnixMs = 2_000 };
        fixture.Native.RegisterInbound(
            "message-rename",
            InboundGroupControl(renamed, baseline, "group_renamed", "owner", 82));
        fixture.Native.RegisterInbound(
            "stale-message",
            InboundGroupControl(
                group,
                baseline,
                "group_message",
                "bob",
                83,
                new Dictionary<string, object?> { ["text"] = "delayed group text" },
                eventId: "stale-message"));
        if (ownerFirst)
        {
            await fixture.ImportEnvelopeAsync("message-rename", "owner");
            await fixture.ImportEnvelopeAsync("stale-message", "bob");
        }
        else
        {
            await fixture.ImportEnvelopeAsync("stale-message", "bob");
            await fixture.ImportEnvelopeAsync("message-rename", "owner");
        }
        Require(fixture.Engine.State.Messages.Any(item => item.Text == "delayed group text"),
            "stale group message is accepted while actor and self remain active");
        Equal("Message rename", fixture.Engine.State.RequireGroup(group.GroupId).Name,
            "stale message cannot roll back group metadata");
        return CausalStateFingerprint(fixture.Engine.State, group.GroupId);
    }

    private static string CausalStateFingerprint(WindowsClientState state, string groupId)
    {
        var group = state.RequireGroup(groupId);
        var members = state.GroupMembers.Where(item => item.GroupId == groupId)
            .OrderBy(item => item.KeyId)
            .Select(item => $"{item.KeyId}:{item.Status}:{item.TrustState}:{item.JoinedAtUnixMs}:{item.UpdatedAtUnixMs}");
        var events = state.GroupEvents.Where(item => item.GroupId == groupId)
            .OrderBy(item => item.EventId, StringComparer.Ordinal)
            .Select(item => $"{item.EventId}:{item.Type}:{item.GroupEpoch}");
        return $"{group.Epoch}:{group.Name}:{group.AvatarSeed}:{group.UpdatedAtUnixMs}:" +
               $"{string.Join('|', members)}::{string.Join('|', events)}";
    }

    private static GroupMemberRecord[] AcceptedMembers(
        IReadOnlyList<GroupMemberRecord> baseline,
        string actorKeyId,
        long eventCreatedAt,
        bool consensus) => baseline.Select(member => member.KeyId == actorKeyId
            ? member with
            {
                Status = consensus ? GroupMemberStatus.Accepted : GroupMemberStatus.Active,
                TrustState = consensus ? GroupTrustState.ConsensusPending : GroupTrustState.Verified,
                JoinedAtUnixMs = consensus ? member.JoinedAtUnixMs : eventCreatedAt,
                UpdatedAtUnixMs = eventCreatedAt,
            }
            : member).ToArray();

    private static async Task VerifyCanonicalInitialInviteAndLocalTrustAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("bob");
        fixture.Engine.State.Contacts.Add(Contact("owner"));
        var group = new GroupRecord(
            "grp-consensus-test",
            "Verified",
            "owner",
            GroupPolicy.Verified,
            1,
            2_000,
            2_000,
            "seed");
        var owner = Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified) with
        {
            UpdatedAtUnixMs = 2_000,
            JoinedAtUnixMs = 2_000,
        };
        var bob = Member("bob", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner") with
        {
            UpdatedAtUnixMs = 2_000,
            JoinedAtUnixMs = null,
        };
        var carol = Member("carol", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.Inviter, invitedBy: "owner") with
        {
            UpdatedAtUnixMs = 2_000,
            JoinedAtUnixMs = null,
        };
        var forgedBystander = carol with
        {
            Status = GroupMemberStatus.Active,
            TrustState = GroupTrustState.Verified,
            JoinedAtUnixMs = 2_000,
        };
        fixture.Native.RegisterInbound(
            "initial-wrong-epoch",
            InboundGroupControl(
                group with { Epoch = 2 },
                [owner, bob, carol],
                "group_invite",
                "owner",
                57,
                recipientKeyId: "bob"));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("initial-wrong-epoch", "owner"),
            "initial invite epoch must be one");
        fixture.Native.RegisterInbound(
            "initial-wrong-inviter",
            InboundGroupControl(
                group,
                [owner, bob, carol with { InvitedByKeyId = "mallory" }],
                "group_invite",
                "owner",
                58,
                recipientKeyId: "bob"));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("initial-wrong-inviter", "owner"),
            "initial invite requires canonical inviter");
        fixture.Native.RegisterInbound(
            "initial-wrong-updated",
            InboundGroupControl(
                group,
                [owner, bob, carol with { UpdatedAtUnixMs = 1_999 }],
                "group_invite",
                "owner",
                59,
                recipientKeyId: "bob"));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("initial-wrong-updated", "owner"),
            "initial invite requires canonical member timestamp");
        fixture.Native.RegisterInbound(
            "initial-forged",
            InboundGroupControl(
                group,
                [owner, bob, forgedBystander],
                "group_invite",
                "owner",
                60,
                recipientKeyId: "bob"));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("initial-forged", "owner"),
            "initial invite rejects active verified bystander");
        Require(fixture.Engine.State.Groups.Count == 0, "forged initial invite creates no group");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter is not (57 or 58 or 59 or 60)),
            "rejected initial invites do not consume counters");

        fixture.Native.RegisterInbound(
            "initial-valid",
            InboundGroupControl(
                group,
                [owner, bob, carol],
                "group_invite",
                "owner",
                61,
                recipientKeyId: "bob"));
        await fixture.ImportEnvelopeAsync("initial-valid", "owner");
        Equal(GroupTrustState.Inviter, LocalMember(fixture, "owner").TrustState,
            "initial invite owner is locally recorded as inviter");
        Equal(GroupTrustState.Verified, LocalMember(fixture, "bob").TrustState,
            "local identity trust is local-only verified");
        Equal(GroupTrustState.Unverified, LocalMember(fixture, "carol").TrustState,
            "initial invite cannot remotely trust a bystander fingerprint");

        await fixture.Engine.AcceptGroupInviteAsync(group.GroupId);
        var current = fixture.Engine.State.RequireGroup(group.GroupId);
        var acceptedGroup = current with { Epoch = current.Epoch + 1, UpdatedAtUnixMs = 3_000 };
        var remoteMembers = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId)
            .Select(member => member.KeyId == "carol"
                ? member with
                {
                    Status = GroupMemberStatus.Active,
                    TrustState = GroupTrustState.Verified,
                    JoinedAtUnixMs = 3_000,
                    UpdatedAtUnixMs = 3_000,
                }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "carol-self-verified",
            InboundGroupControl(acceptedGroup, remoteMembers, "member_accepted", "carol", 62, recipientKeyId: "bob"));
        await fixture.ImportEnvelopeAsync("carol-self-verified", "carol");
        Equal(GroupTrustState.Unverified, LocalMember(fixture, "carol").TrustState,
            "remote member_accepted cannot self-report local Verified trust");
        Require(!GroupRules.MessageRecipients(
                acceptedGroup,
                fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId),
                "bob").Any(item => item.KeyId == "carol"),
            "untrusted verified-group member is excluded from recipients");

        var untrustedMessage = InboundGroupControl(
            acceptedGroup,
            remoteMembers,
            "group_message",
            "carol",
            64,
            new Dictionary<string, object?> { ["text"] = "must be locally trusted" },
            recipientKeyId: "bob");
        fixture.Native.RegisterInbound("untrusted-group-message", untrustedMessage);
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("untrusted-group-message", "carol"),
            "untrusted active member cannot send verified-group text");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 64),
            "rejected untrusted group text does not consume counter");
        var groupFileManifest = InboundGroupFileManifest(acceptedGroup, "carol", "bob", 65);
        fixture.Native.RegisterInbound("untrusted-group-file", groupFileManifest);
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("untrusted-group-file", "carol"),
            "untrusted active member cannot send verified-group file");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 65),
            "rejected untrusted group file does not consume counter");

        await fixture.Engine.SetGroupMemberLocalTrustAsync(group.GroupId, "carol", trusted: true);
        Equal(GroupTrustState.Verified, LocalMember(fixture, "carol").TrustState,
            "local trust API records verified fingerprint");
        Require(GroupRules.MessageRecipients(
                acceptedGroup,
                fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId),
                "bob").Any(item => item.KeyId == "carol"),
            "locally trusted verified-group member is eligible for messages and files");
        fixture.Native.RegisterInbound("trusted-group-message", untrustedMessage);
        var trustedMessage = await fixture.ImportEnvelopeAsync("trusted-group-message", "carol");
        Equal("must be locally trusted", trustedMessage.Message.Text,
            "same verified-group text imports after local trust");
        Equal(1, fixture.Engine.State.ReceivedCounters.Count(item => item.MessageCounter == 64),
            "trusted retry records counter exactly once");
        fixture.Native.RegisterInbound("trusted-group-file", groupFileManifest);
        await fixture.ImportEnvelopeAsync("trusted-group-file", "carol");
        Require(fixture.Engine.State.InboundFileTransfers.Any(item =>
                item.TransferId == "verified-trust-empty" && item.SenderKeyId == "carol"),
            "same verified-group file manifest imports after local trust");
        Equal(1, fixture.Engine.State.ReceivedCounters.Count(item => item.MessageCounter == 65),
            "trusted group file retry records counter exactly once");

        var messageSnapshot = fixture.Engine.State.GroupMembers.Where(item => item.GroupId == group.GroupId)
            .Select(member => member with { TrustState = GroupTrustState.Unverified })
            .ToArray();
        fixture.Native.RegisterInbound(
            "remote-trust-reset",
            InboundGroupControl(acceptedGroup, messageSnapshot, "group_message", "owner", 63, recipientKeyId: "bob"));
        await fixture.ImportEnvelopeAsync("remote-trust-reset", "owner");
        Equal(GroupTrustState.Verified, LocalMember(fixture, "carol").TrustState,
            "wire trust differences neither reject nor overwrite local trust");
        await fixture.Engine.SetGroupMemberLocalTrustAsync(group.GroupId, "carol", trusted: false);
        Equal(GroupTrustState.Unverified, LocalMember(fixture, "carol").TrustState,
            "local trust API can revoke fingerprint trust");
    }

    private static GroupMemberRecord LocalMember(GroupFixture fixture, string keyId) =>
        fixture.Engine.State.GroupMembers.Single(item => item.GroupId == "grp-consensus-test" && item.KeyId == keyId);

    private static async Task VerifyConsensusDeduplicationAndAdmissionAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("candidate");
        var group = fixture.AddConsensusGroup(
            epoch: 2,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("candidate", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.ConsensusPending,
                invitedBy: "owner"));
        var duplicateEndorsement = EndorsementEvent(group, "candidate", "bob", epoch: 2, eventId: "endorse-bob-1");
        fixture.Engine.State.GroupEvents.Add(duplicateEndorsement);
        fixture.Engine.State.GroupEvents.Add(duplicateEndorsement with { EventId = "endorse-bob-duplicate" });

        await fixture.Engine.AcceptGroupInviteAsync(group.GroupId);

        var accepted = fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "candidate");
        Equal(GroupMemberStatus.Accepted, accepted.Status,
            "duplicate endorsement by one actor does not satisfy 60 percent threshold");

        fixture.SetIdentity("carol");
        await fixture.Engine.EndorseGroupMemberAsync(group.GroupId, "candidate");

        var admitted = fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "candidate");
        Equal(GroupMemberStatus.Active, admitted.Status, "candidate admitted at unique endorser threshold");
        Equal(GroupTrustState.Verified, admitted.TrustState, "local endorser records candidate as verified");
        Require(admitted.JoinedAtUnixMs is > 0, "admitted candidate join timestamp");
        Require(fixture.Native.SignedContexts.Contains(EnvelopeClientEngine.GroupConsensusEndorsementContext),
            "inner consensus signature context used");

        var current = fixture.Engine.State.RequireGroup(group.GroupId);
        var remoteTrustSnapshot = fixture.Engine.State.GroupMembers
            .Where(member => member.GroupId == group.GroupId)
            .Select(member => member.KeyId == "candidate"
                ? member with { TrustState = GroupTrustState.ConsensusAdmitted }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "consensus-local-trust-difference",
            InboundGroupControl(
                current,
                remoteTrustSnapshot,
                "group_message",
                "bob",
                70,
                new Dictionary<string, object?> { ["text"] = "consensus trust remains local" },
                recipientKeyId: "carol"));
        await fixture.ImportEnvelopeAsync("consensus-local-trust-difference", "bob");
        Equal(GroupTrustState.Verified,
            fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "candidate").TrustState,
            "consensus local verification tolerates remote admitted wire state without overwrite");
    }

    private static async Task VerifyInboundEndorsementSignatureAsync()
    {
        await using var fixture = await GroupFixture.CreateAsync("dave");
        var group = fixture.AddConsensusGroup(
            epoch: 2,
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("bob", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("carol", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("dave", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.ConsensusAdmitted),
            Member("candidate", GroupRole.Member, GroupMemberStatus.Pending, GroupTrustState.ConsensusPending,
                invitedBy: "owner"));
        fixture.Engine.State.Contacts.Add(Contact("carol"));
        fixture.Engine.State.GroupEvents.Add(EndorsementEvent(
            group, "candidate", "bob", epoch: 2, eventId: "endorse-bob"));

        var incomingGroup = group with { Epoch = 3, UpdatedAtUnixMs = group.UpdatedAtUnixMs + 1 };
        var members = fixture.Engine.State.GroupMembers.Where(member => member.GroupId == group.GroupId)
            .Select(member => member.KeyId == "candidate"
                ? member with { Status = GroupMemberStatus.Accepted, UpdatedAtUnixMs = member.UpdatedAtUnixMs + 1 }
                : member)
            .ToArray();
        fixture.Native.RegisterInbound(
            "candidate-not-accepted-locally",
            InboundGroupEnvelope(incomingGroup, members, "candidate", "carol", 9, validInnerSignature: true));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("candidate-not-accepted-locally", "carol"),
            "sender snapshot cannot pre-accept candidate");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 9),
            "pre-accept endorsement does not consume message counter");

        var localCandidateIndex = fixture.Engine.State.GroupMembers.FindIndex(member => member.KeyId == "candidate");
        fixture.Engine.State.GroupMembers[localCandidateIndex] = fixture.Engine.State.GroupMembers[localCandidateIndex] with
        {
            Status = GroupMemberStatus.Accepted,
        };
        var acceptedMembers = fixture.Engine.State.GroupMembers
            .Where(member => member.GroupId == group.GroupId)
            .ToArray();
        fixture.Native.RegisterInbound(
            "bad-inner-signature",
            InboundGroupEnvelope(incomingGroup, acceptedMembers, "candidate", "carol", 10, validInnerSignature: false));
        await ExpectAsync<InvalidDataException>(
            () => fixture.ImportEnvelopeAsync("bad-inner-signature", "carol"),
            "tampered inner endorsement signature");
        Equal(2L, fixture.Engine.State.RequireGroup(group.GroupId).Epoch,
            "rejected endorsement does not update group epoch");
        Require(fixture.Engine.State.ReceivedCounters.All(item => item.MessageCounter != 10),
            "rejected endorsement does not consume message counter");

        fixture.Native.RegisterInbound(
            "valid-inner-signature",
            InboundGroupEnvelope(incomingGroup, acceptedMembers, "candidate", "carol", 10, validInnerSignature: true));
        await fixture.ImportEnvelopeAsync("valid-inner-signature", "carol");

        var admitted = fixture.Engine.State.GroupMembers.Single(member => member.KeyId == "candidate");
        Equal(GroupMemberStatus.Active, admitted.Status, "valid incoming endorsement admits candidate");
        Equal(GroupTrustState.ConsensusAdmitted, admitted.TrustState,
            "remote consensus admission uses consensus_admitted trust");
        Equal(3L, fixture.Engine.State.RequireGroup(group.GroupId).Epoch, "valid endorsement updates epoch");
        Equal(1, fixture.Engine.State.ReceivedCounters.Count(item => item.MessageCounter == 10),
            "valid endorsement records counter once");
    }

    private static GroupEventRecord EndorsementEvent(
        GroupRecord group,
        string candidateKeyId,
        string endorserKeyId,
        long epoch,
        string eventId)
    {
        var createdAt = group.UpdatedAtUnixMs + epoch;
        var endorsement = Endorsement(group.GroupId, epoch, candidateKeyId, endorserKeyId, createdAt, true);
        var payload = new Dictionary<string, object?>
        {
            ["candidate_key_id"] = candidateKeyId,
            ["endorsement"] = endorsement,
        };
        return new GroupEventRecord(
            eventId,
            group.GroupId,
            "member_endorsed",
            endorserKeyId,
            epoch,
            createdAt,
            JsonSerializer.Serialize(payload, Json));
    }

    private static GroupEventRecord SnapshotEvent(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> members,
        string type,
        string actorKeyId,
        string eventId)
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
            ["signature"] = "historical-test-signature",
        };
        return new GroupEventRecord(
            eventId,
            group.GroupId,
            type,
            actorKeyId,
            group.Epoch,
            group.UpdatedAtUnixMs,
            JsonSerializer.Serialize(payload, Json));
    }

    private static InboundOpaquePayloadSummary InboundGroupEnvelope(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> members,
        string candidateKeyId,
        string endorserKeyId,
        ulong counter,
        bool validInnerSignature)
    {
        var createdAt = group.UpdatedAtUnixMs;
        var payload = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["type"] = "member_endorsed",
            ["event_id"] = $"incoming-{counter}",
            ["actor_key_id"] = endorserKeyId,
            ["created_at_unix_ms"] = createdAt,
            ["group"] = GroupWire(group),
            ["members"] = members.Select(MemberWire).ToArray(),
            ["candidate_key_id"] = candidateKeyId,
            ["endorsement"] = Endorsement(
                group.GroupId,
                group.Epoch,
                candidateKeyId,
                endorserKeyId,
                createdAt,
                validInnerSignature),
        };
        var unsigned = JsonSerializer.Serialize(payload, Json);
        payload["signature"] = FakeNative.Sign(endorserKeyId, EnvelopeClientEngine.GroupEventSignatureContext, unsigned);
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, Json));
        return new InboundOpaquePayloadSummary(
            $"env-{counter}",
            group.GroupId,
            endorserKeyId,
            "dave",
            (ulong)createdAt,
            counter,
            "file",
            EnvelopeClientEngine.GroupControlMime,
            "group-control.json",
            bytes.Length,
            Base64Url(bytes));
    }

    private static InboundOpaquePayloadSummary InboundGroupControl(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> members,
        string type,
        string actorKeyId,
        ulong counter,
        IReadOnlyDictionary<string, object?>? extra = null,
        string recipientKeyId = "dave",
        string? eventId = null)
    {
        var payload = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["type"] = type,
            ["event_id"] = eventId ?? $"control-{counter}",
            ["actor_key_id"] = actorKeyId,
            ["created_at_unix_ms"] = group.UpdatedAtUnixMs,
            ["group"] = GroupWire(group),
            ["members"] = members.Select(MemberWire).ToArray(),
        };
        if (extra is not null)
        {
            foreach (var item in extra) payload[item.Key] = item.Value;
        }
        var unsigned = JsonSerializer.Serialize(payload, Json);
        payload["signature"] = FakeNative.Sign(actorKeyId, EnvelopeClientEngine.GroupEventSignatureContext, unsigned);
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, Json));
        return new InboundOpaquePayloadSummary(
            $"env-{counter}",
            group.GroupId,
            actorKeyId,
            recipientKeyId,
            (ulong)group.UpdatedAtUnixMs,
            counter,
            "file",
            EnvelopeClientEngine.GroupControlMime,
            "group-control.json",
            bytes.Length,
            Base64Url(bytes));
    }

    private static InboundOpaquePayloadSummary InboundGroupFileManifest(
        GroupRecord group,
        string senderKeyId,
        string recipientKeyId,
        ulong counter)
    {
        var emptyHash = Base64Url(SHA256.HashData(Array.Empty<byte>()));
        var payload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_manifest",
            ["transfer_id"] = "verified-trust-empty",
            ["conversation_id"] = group.GroupId,
            ["group_id"] = group.GroupId,
            ["group_epoch"] = group.Epoch,
            ["filename"] = "empty.txt",
            ["mime"] = "text/plain",
            ["total_size"] = 0,
            ["chunk_size"] = 4 * 1024 * 1024,
            ["chunk_count"] = 1,
            ["file_sha256"] = emptyHash,
            ["chunk_sha256"] = new[] { emptyHash },
        }, Json);
        return new InboundOpaquePayloadSummary(
            $"env-file-{counter}",
            group.GroupId,
            senderKeyId,
            recipientKeyId,
            (ulong)group.UpdatedAtUnixMs,
            counter,
            "file",
            EnvelopeClientEngine.FileManifestMime,
            "empty.txt.manifest.json",
            payload.Length,
            Base64Url(payload));
    }

    private static Dictionary<string, object?> Endorsement(
        string groupId,
        long epoch,
        string candidateKeyId,
        string endorserKeyId,
        long createdAt,
        bool valid)
    {
        var signing = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["group_id"] = groupId,
            ["epoch"] = epoch,
            ["candidate_key_id"] = candidateKeyId,
            ["endorser_key_id"] = endorserKeyId,
            ["created_at_unix_ms"] = createdAt,
        };
        var signature = FakeNative.Sign(
            endorserKeyId,
            EnvelopeClientEngine.GroupConsensusEndorsementContext,
            JsonSerializer.Serialize(signing, Json));
        signing["signature"] = valid ? signature : signature + "tampered";
        return signing;
    }

    private static Dictionary<string, object?> GroupWire(GroupRecord group) => new()
    {
        ["group_id"] = group.GroupId,
        ["name"] = group.Name,
        ["owner_key_id"] = group.OwnerKeyId,
        ["policy"] = group.Policy switch
        {
            GroupPolicy.Verified => "verified",
            GroupPolicy.Consensus => "consensus",
            _ => "normal",
        },
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
        ["status"] = member.Status.ToString().ToLowerInvariant(),
        ["trust_state"] = member.TrustState switch
        {
            GroupTrustState.ConsensusPending => "consensus_pending",
            GroupTrustState.ConsensusAdmitted => "consensus_admitted",
            _ => member.TrustState.ToString().ToLowerInvariant(),
        },
        ["invited_by_key_id"] = member.InvitedByKeyId,
        ["joined_at_unix_ms"] = member.JoinedAtUnixMs,
        ["updated_at_unix_ms"] = member.UpdatedAtUnixMs,
    };

    private static GroupMemberRecord Member(
        string keyId,
        GroupRole role,
        GroupMemberStatus status,
        GroupTrustState trust,
        string? invitedBy = null) => new(
        "grp-consensus-test",
        keyId,
        keyId,
        $"contact:{keyId}",
        role,
        status,
        trust,
        1_000,
        invitedBy,
        status == GroupMemberStatus.Active ? 1_000 : null);

    private static StoredContact Contact(string keyId) => new(keyId, keyId, $"contact:{keyId}");

    private static string Base64Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static async Task ExpectAsync<T>(Func<Task> action, string label) where T : Exception
    {
        try
        {
            await action();
        }
        catch (T)
        {
            return;
        }
        throw new InvalidOperationException($"Verification failed: {label}; expected {typeof(T).Name}.");
    }

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

    private sealed class GroupFixture : IAsyncDisposable
    {
        private readonly string _root;

        private GroupFixture(
            string root,
            EnvelopeClientEngine engine,
            FakeNative native,
            MemoryStateStore store)
        {
            _root = root;
            Engine = engine;
            Native = native;
            Store = store;
        }

        public EnvelopeClientEngine Engine { get; }
        public FakeNative Native { get; }
        public MemoryStateStore Store { get; }

        public Task<EnvelopeImportResult> ImportEnvelopeAsync(string fixtureLabel, string? sender = null) =>
            Engine.ImportEnvelopeAsync(Base64Url(Encoding.UTF8.GetBytes(fixtureLabel)), sender);

        public static async Task<GroupFixture> CreateAsync(string identityKeyId)
        {
            var root = Path.Combine(Path.GetTempPath(), "Envelope.Windows.GroupTests", Guid.NewGuid().ToString("N"));
            var paths = new EnvelopePaths(Path.Combine(root, "profile"), Path.Combine(root, "local"));
            var native = new FakeNative();
            var store = new MemoryStateStore();
            var engine = new EnvelopeClientEngine(
                native,
                store,
                paths,
                new DiagnosticLogService(paths.Logs));
            await engine.InitializeAsync();
            var fixture = new GroupFixture(root, engine, native, store);
            fixture.SetIdentity(identityKeyId);
            return fixture;
        }

        public void SetIdentity(string keyId)
        {
            Engine.State.Identity = new SecureIdentityRecord($"identity:{keyId}", keyId, keyId, 1_000);
        }

        public GroupRecord AddConsensusGroup(long epoch, params GroupMemberRecord[] members)
            => AddGroup(GroupPolicy.Consensus, epoch, members);

        public GroupRecord AddGroup(GroupPolicy policy, long epoch, params GroupMemberRecord[] members)
        {
            var group = new GroupRecord(
                "grp-consensus-test",
                "Consensus",
                "owner",
                policy,
                epoch,
                1_000,
                1_000 + epoch,
                "seed");
            Engine.State.Groups.Add(group);
            Engine.State.GroupMembers.AddRange(members);
            return group;
        }

        public async ValueTask DisposeAsync()
        {
            await Engine.DisposeAsync();
            if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
        }
    }

    private sealed class MemoryStateStore : IClientStateStore
    {
        private WindowsClientState _state = new();

        public List<StateSaveObservation> Observations { get; } = [];
        public int SuccessfulSavesBeforeFailure { get; set; } = -1;

        public Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(_state);

        public Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default)
        {
            if (SuccessfulSavesBeforeFailure == 0)
            {
                SuccessfulSavesBeforeFailure = -1;
                throw new IOException("injected group batch persistence failure");
            }
            if (SuccessfulSavesBeforeFailure > 0) SuccessfulSavesBeforeFailure--;
            _state = state;
            Observations.Add(new StateSaveObservation(
                state.PendingEnvelopes.Count,
                state.Messages.Count,
                state.GroupEvents.Count));
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _state = new WindowsClientState();
            return Task.CompletedTask;
        }
    }

    private sealed record StateSaveObservation(int PendingCount, int MessageCount, int GroupEventCount);

    private sealed class FakeNative : IEnvelopeNativeClient
    {
        private readonly Dictionary<string, InboundOpaquePayloadSummary> _inbound = new(StringComparer.Ordinal);

        public HashSet<string> SignedContexts { get; } = new(StringComparer.Ordinal);
        public List<(string Context, string Payload)> SignedPayloads { get; } = [];
        public List<string> VerifiedPayloads { get; } = [];
        public List<ulong> EncryptedCounters { get; } = [];

        public void RegisterInbound(string encoded, InboundOpaquePayloadSummary payload) =>
            _inbound[Base64Url(Encoding.UTF8.GetBytes(encoded))] = payload;

        public static string Sign(string keyId, string context, string payload) =>
            Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes($"{keyId}\n{context}\n{payload}")));

        public string ContactFromIdentity(string identityJson) => $"contact:{IdentityKey(identityJson)}";

        public ContactSummary ParseContact(string contactJson)
        {
            var keyId = ContactKey(contactJson);
            return new ContactSummary(keyId, keyId, contactJson);
        }

        public SignatureSummary SignContextPayload(string identityJson, string context, string payload)
        {
            var keyId = IdentityKey(identityJson);
            SignedContexts.Add(context);
            SignedPayloads.Add((context, payload));
            return new SignatureSummary(keyId, Sign(keyId, context, payload));
        }

        public SignatureVerificationSummary VerifyContactSignature(
            string contactJson,
            string context,
            string payload,
            string signature)
        {
            var keyId = ContactKey(contactJson);
            VerifiedPayloads.Add(payload);
            return new SignatureVerificationSummary(keyId, signature == Sign(keyId, context, payload));
        }

        public OutboundOpaquePayloadSummary EncryptOpaqueFile(
            string identityJson,
            string recipientContactJson,
            string filename,
            string mime,
            byte[] payloadBytes,
            ulong messageCounter)
        {
            var sender = IdentityKey(identityJson);
            var recipient = ContactKey(recipientContactJson);
            EncryptedCounters.Add(messageCounter);
            return new OutboundOpaquePayloadSummary(
                $"out-{sender}-{recipient}-{messageCounter}",
                recipient,
                sender,
                recipient,
                1_000,
                messageCounter,
                "file",
                mime,
                filename,
                payloadBytes.Length,
                "AQ",
                1);
        }

        public InboundOpaquePayloadSummary DecryptOpaquePayload(
            string identityJson,
            string senderContactJson,
            string envelopeBase64) => _inbound.TryGetValue(envelopeBase64, out var payload)
            ? payload
            : throw new EnvelopeNativeException("unknown fake envelope");

        private static string IdentityKey(string value) => value.StartsWith("identity:", StringComparison.Ordinal)
            ? value["identity:".Length..]
            : value;

        private static string ContactKey(string value) => value.StartsWith("contact:", StringComparison.Ordinal)
            ? value["contact:".Length..]
            : value;

        public ProtocolInfo GetProtocolInfo() => throw new NotSupportedException();
        public RecoveryPhrase GenerateRecoveryPhrase() => throw new NotSupportedException();
        public IdentitySummary RecoverIdentity(string displayName, RecoveryPhrase recoveryPhrase) => throw new NotSupportedException();
        public IdentitySummary RecoverIdentity(string displayName, string recoveryPhrase) => throw new NotSupportedException();
        public string EncryptLocalBackup(RecoveryPhrase recoveryPhrase, string plaintextJson) => throw new NotSupportedException();
        public string DecryptLocalBackup(RecoveryPhrase recoveryPhrase, string backupJson) => throw new NotSupportedException();
        public IntroBundleSummary CreateIntroBundle(string identityJson, string deviceId, string p2pTicket = "", ulong ttlSeconds = 300) => throw new NotSupportedException();
        public IntroBundleSummary VerifyIntroBundle(string bundleJson) => throw new NotSupportedException();
        public NodeSetManifestVerificationSummary VerifyNodeSetManifest(string manifestJson, string manifestSigningPublic, ulong nowUnixMs = 0) => throw new NotSupportedException();
        public NodeChallengeVerificationSummary VerifyNodeChallenge(string requestJson, string responseJson, string nodePublicKey, ulong nowUnixMs = 0, ulong maxClockSkewMs = 300_000) => throw new NotSupportedException();
        public OutboundOpaqueTextSummary EncryptOpaqueText(string identityJson, string recipientContactJson, string text, ulong messageCounter) => throw new NotSupportedException();
        public InboundOpaqueTextSummary DecryptOpaqueText(string identityJson, string senderContactJson, string envelopeBase64) => throw new NotSupportedException();
        public DeviceEndpointUpdateSummary CreateDeviceEndpointUpdate(string identityJson, string deviceId, string p2pTicket, string sessionId, ulong deviceListVersion = 1, ulong ttlSeconds = 1_800) => throw new NotSupportedException();
        public ServerRequestSummary CreateMailboxPullRequest(string identityJson, uint limit = 50, ulong requestedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateEnvelopeSubmitRequest(string identityJson, string recipientKeyId, string envelopeId, string envelopeBase64, ulong ttlSeconds = 0, ulong submittedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateMailboxAckRequest(string identityJson, IReadOnlyCollection<string> envelopeIds, ulong ackedAtUnixMs = 0) => throw new NotSupportedException();
        public ServerRequestSummary CreateDeliveryStatusRequest(string identityJson, IReadOnlyCollection<string> envelopeIds, ulong requestedAtUnixMs = 0) => throw new NotSupportedException();
    }
}
