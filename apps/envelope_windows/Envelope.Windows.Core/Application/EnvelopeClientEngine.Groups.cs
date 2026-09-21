using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Application;

public sealed record GroupOperationResult(GroupRecord Group, IReadOnlyList<string> DeliveryDetails);

public sealed partial class EnvelopeClientEngine
{
    private sealed record PreparedGroupBroadcastChild(
        OutboundWorkItem Work,
        string DisplayLabel,
        ulong MessageCounter);

    private sealed record GroupHistorySnapshot(
        GroupRecord Group,
        IReadOnlyList<GroupMemberRecord> Members);

    private sealed record GroupMutationSnapshot(
        IReadOnlyList<GroupRecord> Groups,
        IReadOnlyList<GroupMemberRecord> Members,
        IReadOnlyList<GroupEventRecord> Events);

    private static readonly HashSet<string> SupportedGroupEventTypes = new(StringComparer.Ordinal)
    {
        "group_invite",
        "group_message",
        "member_accepted",
        "member_endorsed",
        "group_renamed",
        "group_avatar_updated",
        "member_removed",
        "member_left",
    };

    public async Task<GroupOperationResult> CreateGroupAsync(
        string name,
        GroupPolicy policy,
        IReadOnlyCollection<string> inviteeKeyIds,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var invitees = inviteeKeyIds.Distinct(StringComparer.Ordinal)
                .Where(key => key != identity.KeyId)
                .Select(_state.RequireContact)
                .ToArray();
            if (invitees.Length < 2) throw new InvalidOperationException("创建群组至少需要选择 2 位联系人。");
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var normalizedName = string.IsNullOrWhiteSpace(name) ? "未命名群组" : name.Trim();
            var group = new GroupRecord(
                $"grp-{Guid.NewGuid():N}", normalizedName, identity.KeyId, policy, 1, now, now, normalizedName);
            var selfContact = _native.ParseContact(_native.ContactFromIdentity(identity.IdentityJson));
            var members = new List<GroupMemberRecord>
            {
                new(group.GroupId, identity.KeyId, identity.DisplayName, selfContact.ContactJson,
                    GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified, now, JoinedAtUnixMs: now),
            };
            members.AddRange(invitees.Select(contact => new GroupMemberRecord(
                group.GroupId, contact.KeyId, contact.DisplayLabel, contact.ContactJson,
                GroupRole.Member, GroupMemberStatus.Pending,
                policy == GroupPolicy.Consensus ? GroupTrustState.ConsensusPending : GroupTrustState.Inviter,
                now, identity.KeyId)));
            var payload = CreateSignedGroupPayload("group_invite", group, members, now);
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    invitees,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            _state.Groups.Add(group);
            _state.GroupMembers.AddRange(members);
            _state.GroupEvents.Add(ToGroupEvent(group, payload));
            var delivery = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(group, delivery);
        }
        finally { _gate.Release(); }
    }

    public async Task<GroupOperationResult> InviteGroupMembersAsync(
        string groupId,
        IReadOnlyCollection<string> inviteeKeyIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(inviteeKeyIds);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
            if (group.OwnerKeyId != identity.KeyId) throw new InvalidOperationException("只有群主可以邀请新成员。");

            var existing = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
            var existingKeys = existing.Select(item => item.KeyId).ToHashSet(StringComparer.Ordinal);
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var newMembers = inviteeKeyIds
                .Distinct(StringComparer.Ordinal)
                .Where(keyId => keyId != identity.KeyId && !existingKeys.Contains(keyId))
                .Select(_state.RequireContact)
                .Select(contact => new GroupMemberRecord(
                    group.GroupId,
                    contact.KeyId,
                    contact.DisplayLabel,
                    contact.ContactJson,
                    GroupRole.Member,
                    GroupMemberStatus.Pending,
                    group.Policy == GroupPolicy.Consensus
                        ? GroupTrustState.ConsensusPending
                        : GroupTrustState.Inviter,
                    now,
                    identity.KeyId))
                .ToArray();
            if (newMembers.Length == 0) throw new InvalidOperationException("没有可邀请的新联系人。");

            var members = existing.Concat(newMembers).ToArray();
            var updatedGroup = group with { Epoch = group.Epoch + 1, UpdatedAtUnixMs = now };
            var payload = CreateSignedGroupPayload("group_invite", updatedGroup, members, now);
            var recipients = GroupControlRecipients(members, identity.KeyId)
                .GroupBy(member => member.KeyId, StringComparer.Ordinal)
                .Select(items => items.First())
                .Select(member => new StoredContact(member.KeyId, member.DisplayName, member.ContactJson))
                .ToArray();
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            ReplaceGroupAndMembers(updatedGroup, members);
            _state.GroupEvents.Add(ToGroupEvent(updatedGroup, payload));
            var delivery = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(updatedGroup, delivery);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<ChatMessageRecord> SendGroupTextAsync(
        string groupId,
        string text,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("群消息不能为空。", nameof(text));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
            var recipients = GroupRules.MessageRecipients(group, members, identity.KeyId);
            if (recipients.Count == 0) throw new InvalidOperationException("该群没有可投递的活跃成员。");
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var payload = CreateSignedGroupPayload(
                "group_message", group, members, now,
                new Dictionary<string, object?> { ["text"] = text.Trim() });
            var logicalMessageId = $"group-message:{payload["event_id"]}";
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients.Select(member => new StoredContact(
                        member.KeyId,
                        member.DisplayName,
                        member.ContactJson)),
                    logicalMessageId,
                    cancellationToken)
                .ConfigureAwait(false);
            var first = prepared[0];
            var stagedMessage = new ChatMessageRecord(
                first.Work.EnvelopeId,
                group.GroupId,
                MessageDirection.Outgoing,
                identity.KeyId,
                identity.DisplayName,
                now,
                first.MessageCounter,
                text.Trim(),
                string.Empty,
                DeliveryState.Pending,
                LogicalMessageId: logicalMessageId);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            _state.GroupEvents.Add(ToGroupEvent(group, payload));
            var details = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    stagedMessage,
                    mutationSnapshot)
                .ConfigureAwait(false);
            var message = (_state.Messages.FirstOrDefault(item => item.EnvelopeId == stagedMessage.EnvelopeId) ?? stagedMessage) with
            {
                DeliveryState = AggregateLogicalDeliveryStateCore(logicalMessageId),
                DeliveryDetail = string.Join(Environment.NewLine, details),
            };
            _state.Messages.RemoveAll(item => item.EnvelopeId == message.EnvelopeId);
            _state.Messages.Add(message);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return message;
        }
        finally { _gate.Release(); }
    }

    public async Task<GroupOperationResult> EndorseGroupMemberAsync(
        string groupId,
        string candidateKeyId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
            if (group.Policy != GroupPolicy.Consensus) throw new InvalidOperationException("该群不是共识群。");
            if (candidateKeyId == identity.KeyId) throw new InvalidOperationException("不能为本机身份背书。");

            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
            var self = members.FirstOrDefault(item => item.KeyId == identity.KeyId);
            var candidate = members.FirstOrDefault(item => item.KeyId == candidateKeyId);
            if (self?.IsActive != true) throw new InvalidOperationException("只有活跃群成员可以背书新成员。");
            if (candidate?.Status != GroupMemberStatus.Accepted)
                throw new InvalidOperationException("候选成员状态不是等待共识。");

            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var updatedGroup = group with { Epoch = group.Epoch + 1, UpdatedAtUnixMs = now };
            var endorsement = CreateConsensusEndorsement(updatedGroup, candidate, now);
            var payload = CreateSignedGroupPayload(
                "member_endorsed",
                updatedGroup,
                members,
                now,
                new Dictionary<string, object?>
                {
                    ["candidate_key_id"] = candidate.KeyId,
                    ["endorsement"] = endorsement,
                });
            var recipients = GroupControlRecipients(members, identity.KeyId)
                .GroupBy(member => member.KeyId, StringComparer.Ordinal)
                .Select(items => items.First())
                .Select(member => new StoredContact(member.KeyId, member.DisplayName, member.ContactJson))
                .ToArray();
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            _state.GroupEvents.Add(ToGroupEvent(updatedGroup, payload));
            var locallyVerified = members.Select(member => member.KeyId == candidate.KeyId
                    ? member with { TrustState = GroupTrustState.Verified }
                    : member)
                .ToArray();
            var admittedMembers = ApplyConsensusAdmissions(updatedGroup, locallyVerified);
            ReplaceGroupAndMembers(updatedGroup, admittedMembers);
            var delivery = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(updatedGroup, delivery);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<GroupMemberRecord> SetGroupMemberLocalTrustAsync(
        string groupId,
        string memberKeyId,
        bool trusted,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (group.Policy != GroupPolicy.Verified)
                throw new InvalidOperationException("只有指纹验证群支持本机成员信任设置。");
            if (memberKeyId == identity.KeyId)
                throw new InvalidOperationException("本机身份始终由本机信任，不能修改。");
            var index = _state.GroupMembers.FindIndex(item =>
                item.GroupId == groupId && item.KeyId == memberKeyId);
            if (index < 0) throw new KeyNotFoundException("群成员不存在。");
            var member = _state.GroupMembers[index];
            if (member.Status is GroupMemberStatus.Left or GroupMemberStatus.Removed)
                throw new InvalidOperationException("不能修改已退出或已移除成员的本机信任。");
            ValidateMemberContactIdentity(member);
            var updated = member with
            {
                TrustState = trusted ? GroupTrustState.Verified : GroupTrustState.Unverified,
            };
            _state.GroupMembers[index] = updated;
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return updated;
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<GroupOperationResult> AcceptGroupInviteAsync(string groupId, CancellationToken cancellationToken = default) =>
        ChangeOwnMembershipAsync(groupId, "member_accepted", accept: true, cancellationToken);

    public Task<GroupOperationResult> LeaveOrDeclineGroupAsync(string groupId, CancellationToken cancellationToken = default) =>
        ChangeOwnMembershipAsync(groupId, "member_left", accept: false, cancellationToken);

    private async Task<GroupOperationResult> ChangeOwnMembershipAsync(
        string groupId,
        string eventType,
        bool accept,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (accept && !group.IsActive) throw new InvalidOperationException("群邀请已失效，群组不再处于活动状态。");
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToList();
            var selfIndex = members.FindIndex(item => item.KeyId == identity.KeyId);
            if (selfIndex < 0) throw new InvalidOperationException("本机不是该群成员。");
            var self = members[selfIndex];
            if (accept && self.Status != GroupMemberStatus.Pending)
                throw new InvalidOperationException("本机没有可接受的待处理群邀请。");
            if (!accept && self.Status is GroupMemberStatus.Left or GroupMemberStatus.Removed)
                throw new InvalidOperationException("本机已经退出该群或已被移除。");
            var nextStatus = accept
                ? (group.Policy == GroupPolicy.Consensus ? GroupMemberStatus.Accepted : GroupMemberStatus.Active)
                : GroupMemberStatus.Left;
            members[selfIndex] = self with
            {
                Status = nextStatus,
                TrustState = accept
                    ? (group.Policy == GroupPolicy.Consensus ? GroupTrustState.ConsensusPending : GroupTrustState.Verified)
                    : GroupTrustState.Verified,
                JoinedAtUnixMs = accept && group.Policy != GroupPolicy.Consensus ? now : self.JoinedAtUnixMs,
                UpdatedAtUnixMs = now,
            };
            var updatedGroup = group with { Epoch = group.Epoch + 1, UpdatedAtUnixMs = now };
            if (!accept && GroupRules.ShouldDissolve(members)) updatedGroup = updatedGroup with { IsActive = false };
            var payload = CreateSignedGroupPayload(
                eventType,
                updatedGroup,
                members,
                now,
                !accept && !updatedGroup.IsActive
                    ? new Dictionary<string, object?> { ["dissolution_reasons"] = DissolutionReasons(members) }
                    : null);
            var recipients = GroupControlRecipients(members, identity.KeyId)
                .Select(item => new StoredContact(item.KeyId, item.DisplayName, item.ContactJson))
                .ToArray();
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            ReplaceGroupAndMembers(updatedGroup, members);
            _state.GroupEvents.Add(ToGroupEvent(updatedGroup, payload));
            if (accept && updatedGroup.Policy == GroupPolicy.Consensus)
            {
                var admittedMembers = ApplyConsensusAdmissions(updatedGroup, members);
                ReplaceGroupAndMembers(updatedGroup, admittedMembers);
            }
            var details = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(updatedGroup, details);
        }
        finally { _gate.Release(); }
    }

    public async Task<GroupOperationResult> RenameGroupAsync(
        string groupId,
        string name,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("群名称不能为空。", nameof(name));
        return await MutateOwnedGroupAsync(groupId, "group_renamed",
            group => group with { Name = name.Trim() }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<GroupOperationResult> UpdateGroupAvatarAsync(
        string groupId,
        string avatarSeed,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(avatarSeed)) throw new ArgumentException("群头像标识不能为空。", nameof(avatarSeed));
        return await MutateOwnedGroupAsync(groupId, "group_avatar_updated",
            group => group with { AvatarSeed = avatarSeed.Trim() }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<GroupOperationResult> RemoveGroupMemberAsync(
        string groupId,
        string memberKeyId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (group.OwnerKeyId != identity.KeyId) throw new InvalidOperationException("只有群主可以移除成员。");
            if (memberKeyId == identity.KeyId) throw new InvalidOperationException("群主退出请使用退出群组。");
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToList();
            var index = members.FindIndex(item => item.KeyId == memberKeyId);
            if (index < 0) throw new KeyNotFoundException("群成员不存在。");
            members[index] = members[index] with
            {
                Status = GroupMemberStatus.Removed,
                TrustState = GroupTrustState.Unverified,
                UpdatedAtUnixMs = now,
            };
            var updated = group with { Epoch = group.Epoch + 1, UpdatedAtUnixMs = now };
            if (GroupRules.ShouldDissolve(members)) updated = updated with { IsActive = false };
            var extra = new Dictionary<string, object?> { ["target_key_id"] = memberKeyId };
            if (!updated.IsActive) extra["dissolution_reasons"] = DissolutionReasons(members);
            var payload = CreateSignedGroupPayload("member_removed", updated, members, now, extra);
            var recipients = GroupControlRecipients(members, identity.KeyId)
                .Append(members[index])
                .GroupBy(item => item.KeyId, StringComparer.Ordinal)
                .Select(item => item.First())
                .Select(item => new StoredContact(item.KeyId, item.DisplayName, item.ContactJson))
                .ToArray();
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            ReplaceGroupAndMembers(updated, members);
            _state.GroupEvents.Add(ToGroupEvent(updated, payload));
            var details = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(updated, details);
        }
        finally { _gate.Release(); }
    }

    private async Task<GroupOperationResult> MutateOwnedGroupAsync(
        string groupId,
        string eventType,
        Func<GroupRecord, GroupRecord> mutate,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (group.OwnerKeyId != identity.KeyId) throw new InvalidOperationException("只有群主可以修改群组。");
            if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var updated = mutate(group) with { Epoch = group.Epoch + 1, UpdatedAtUnixMs = now };
            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
            var payload = CreateSignedGroupPayload(eventType, updated, members, now);
            var recipients = GroupControlRecipients(members, identity.KeyId)
                .Select(item => new StoredContact(item.KeyId, item.DisplayName, item.ContactJson)).ToArray();
            var prepared = await PrepareGroupBroadcastCoreAsync(
                    payload,
                    recipients,
                    GroupEventLogicalMessageId(payload),
                    cancellationToken)
                .ConfigureAwait(false);
            var mutationSnapshot = CaptureGroupMutationSnapshot();
            ReplaceGroupAndMembers(updated, members);
            _state.GroupEvents.Add(ToGroupEvent(updated, payload));
            var details = await StageAndDeliverGroupBroadcastCoreAsync(
                    prepared,
                    cancellationToken,
                    rollbackSnapshot: mutationSnapshot)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return new GroupOperationResult(updated, details);
        }
        finally { _gate.Release(); }
    }

    private Dictionary<string, object?> CreateConsensusEndorsement(
        GroupRecord group,
        GroupMemberRecord candidate,
        long now)
    {
        var identity = RequireIdentity();
        var signingPayload = ConsensusEndorsementSigningPayload(
            group.GroupId,
            group.Epoch,
            candidate.KeyId,
            identity.KeyId,
            now);
        var signature = _native.SignContextPayload(
            identity.IdentityJson,
            GroupConsensusEndorsementContext,
            signingPayload);
        if (signature.KeyId != identity.KeyId)
            throw new InvalidDataException("共识背书签名身份与本机身份不匹配。");
        return new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["group_id"] = group.GroupId,
            ["epoch"] = group.Epoch,
            ["candidate_key_id"] = candidate.KeyId,
            ["endorser_key_id"] = identity.KeyId,
            ["created_at_unix_ms"] = now,
            ["signature"] = signature.Signature,
        };
    }

    private static string ConsensusEndorsementSigningPayload(
        string groupId,
        long epoch,
        string candidateKeyId,
        string endorserKeyId,
        long createdAtUnixMs) => SerializeDartCompatibleJson(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["group_id"] = groupId,
            ["epoch"] = epoch,
            ["candidate_key_id"] = candidateKeyId,
            ["endorser_key_id"] = endorserKeyId,
            ["created_at_unix_ms"] = createdAtUnixMs,
        });

    private bool VerifyConsensusEndorsement(
        GroupRecord group,
        GroupMemberRecord endorser,
        string candidateKeyId,
        JsonElement endorsement)
    {
        if (endorsement.ValueKind != JsonValueKind.Object || string.IsNullOrWhiteSpace(endorser.ContactJson)) return false;
        if (!endorsement.TryGetProperty("version", out var version) || !version.TryGetInt32(out var protocolVersion) || protocolVersion != 1 ||
            !endorsement.TryGetProperty("epoch", out var epochElement) || !epochElement.TryGetInt64(out var epoch) || epoch <= 0 || epoch > group.Epoch ||
            GetJsonString(endorsement, "group_id") != group.GroupId ||
            GetJsonString(endorsement, "candidate_key_id") != candidateKeyId ||
            GetJsonString(endorsement, "endorser_key_id") != endorser.KeyId ||
            !endorsement.TryGetProperty("created_at_unix_ms", out var createdElement) || !createdElement.TryGetInt64(out var createdAt) || createdAt <= 0)
            return false;
        var signature = GetJsonString(endorsement, "signature");
        if (signature.Length == 0) return false;
        var signingPayload = ConsensusEndorsementSigningPayload(
            group.GroupId,
            epoch,
            candidateKeyId,
            endorser.KeyId,
            createdAt);
        try
        {
            var verified = _native.VerifyContactSignature(
                endorser.ContactJson,
                GroupConsensusEndorsementContext,
                signingPayload,
                signature);
            return verified.Valid && verified.KeyId == endorser.KeyId;
        }
        catch
        {
            return false;
        }
    }

    private void ValidateIncomingConsensusEndorsement(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> members,
        string actorKeyId,
        JsonElement payload)
    {
        if (group.Policy != GroupPolicy.Consensus)
            throw new InvalidDataException("非共识群不能接收共识背书事件。");
        var candidateKeyId = GetJsonString(payload, "candidate_key_id");
        var candidate = members.FirstOrDefault(member => member.KeyId == candidateKeyId);
        var endorser = members.FirstOrDefault(member => member.KeyId == actorKeyId);
        if (candidate is null || candidate.Status is not (GroupMemberStatus.Accepted or GroupMemberStatus.Active))
            throw new InvalidDataException("共识背书候选人状态无效。");
        if (endorser?.IsActive != true || endorser.KeyId == candidate.KeyId)
            throw new InvalidDataException("共识背书者不是独立的活跃群成员。");
        if (!payload.TryGetProperty("endorsement", out var endorsement) ||
            !VerifyConsensusEndorsement(group, endorser, candidate.KeyId, endorsement))
            throw new InvalidDataException("共识背书内层签名校验失败。");
    }

    private IReadOnlyList<GroupMemberRecord> ApplyConsensusAdmissions(
        GroupRecord group,
        IEnumerable<GroupMemberRecord> members)
    {
        var updated = members.ToList();
        if (group.Policy != GroupPolicy.Consensus) return updated;
        var events = _state.GroupEvents.Where(item => item.GroupId == group.GroupId).ToArray();
        var identityKeyId = RequireIdentity().KeyId;
        for (var index = 0; index < updated.Count; index++)
        {
            var candidate = updated[index];
            if (candidate.Status != GroupMemberStatus.Accepted) continue;
            var activeCount = updated.Count(member => member.IsActive && member.KeyId != candidate.KeyId);
            var threshold = ConsensusInitialInviteBootstrapApplies(group, candidate, events)
                ? 1
                : GroupRules.ConsensusThreshold(activeCount);
            if (threshold <= 0) continue;
            var endorsers = ConsensusEndorsersForCandidate(group, candidate, updated, events);
            if (endorsers.Count < threshold) continue;
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var trustState = candidate.KeyId == identityKeyId
                ? GroupTrustState.Verified
                : candidate.TrustState is GroupTrustState.Verified or GroupTrustState.Inviter or GroupTrustState.ConsensusAdmitted
                    ? candidate.TrustState
                    : GroupTrustState.ConsensusAdmitted;
            updated[index] = candidate with
            {
                Status = GroupMemberStatus.Active,
                TrustState = trustState,
                JoinedAtUnixMs = candidate.JoinedAtUnixMs ?? now,
                UpdatedAtUnixMs = now,
            };
        }
        return updated;
    }

    private HashSet<string> ConsensusEndorsersForCandidate(
        GroupRecord group,
        GroupMemberRecord candidate,
        IReadOnlyList<GroupMemberRecord> members,
        IReadOnlyList<GroupEventRecord> events)
    {
        var eligible = members
            .Where(member => member.IsActive && member.KeyId != candidate.KeyId)
            .ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        var endorsers = new HashSet<string>(StringComparer.Ordinal);
        if (!string.IsNullOrWhiteSpace(candidate.InvitedByKeyId) && eligible.ContainsKey(candidate.InvitedByKeyId))
            endorsers.Add(candidate.InvitedByKeyId);
        foreach (var groupEvent in events.Where(item => item.Type == "member_endorsed"))
        {
            if (!eligible.TryGetValue(groupEvent.ActorKeyId, out var endorser)) continue;
            try
            {
                using var document = JsonDocument.Parse(groupEvent.PayloadJson);
                var payload = document.RootElement;
                if (GetJsonString(payload, "candidate_key_id") != candidate.KeyId ||
                    !payload.TryGetProperty("endorsement", out var endorsement) ||
                    !VerifyConsensusEndorsement(group, endorser, candidate.KeyId, endorsement))
                    continue;
                endorsers.Add(endorser.KeyId);
            }
            catch (JsonException)
            {
                // Corrupt historical events are ignored rather than counted.
            }
        }
        return endorsers;
    }

    private static bool ConsensusInitialInviteBootstrapApplies(
        GroupRecord group,
        GroupMemberRecord candidate,
        IEnumerable<GroupEventRecord> events)
    {
        if (group.Policy != GroupPolicy.Consensus || candidate.InvitedByKeyId != group.OwnerKeyId) return false;
        foreach (var groupEvent in events.Where(item => item.Type == "group_invite"))
        {
            try
            {
                using var document = JsonDocument.Parse(groupEvent.PayloadJson);
                var root = document.RootElement;
                var eventGroup = ParseGroup(root.GetProperty("group"));
                if (eventGroup.GroupId != group.GroupId || eventGroup.Epoch != 1) continue;
                var invited = root.GetProperty("members").EnumerateArray()
                    .Select(ParseGroupMember)
                    .FirstOrDefault(member => member.GroupId == group.GroupId && member.KeyId == candidate.KeyId);
                if (invited is not null && invited.InvitedByKeyId == group.OwnerKeyId &&
                    invited.Status is GroupMemberStatus.Pending or GroupMemberStatus.Accepted)
                    return true;
            }
            catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException)
            {
                // Ignore malformed historical invitations.
            }
        }
        return false;
    }

    private static string GetJsonString(JsonElement value, string propertyName) =>
        value.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;

    private async Task<ChatMessageRecord> ProcessGroupPayloadCoreAsync(
        InboundOpaquePayloadSummary inbound,
        StoredContact sender,
        string envelopeBase64,
        CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(inbound.PayloadBytes);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("群组事件不是 JSON object。");
        if (!root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var protocolVersion) || protocolVersion != 1)
            throw new InvalidDataException("不支持的群组控制载荷版本。");
        var type = root.TryGetProperty("type", out var typeElement) && typeElement.ValueKind == JsonValueKind.String
            ? typeElement.GetString() ?? string.Empty
            : string.Empty;
        if (!SupportedGroupEventTypes.Contains(type)) throw new InvalidDataException($"未知群组事件类型：{type}。");
        var actorKeyId = root.GetProperty("actor_key_id").GetString() ?? string.Empty;
        if (actorKeyId != sender.KeyId) throw new InvalidDataException("群组事件 actor 与发送方不一致。");
        var signature = root.GetProperty("signature").GetString() ?? string.Empty;
        if (signature.Length == 0) throw new InvalidDataException("群组事件缺少签名。");
        var unsignedJson = SerializeWithoutSignature(root);
        var verified = _native.VerifyContactSignature(sender.ContactJson, GroupEventSignatureContext, unsignedJson, signature);
        if (!verified.Valid || verified.KeyId != sender.KeyId) throw new InvalidDataException("群组事件签名校验失败。");

        var eventId = GetJsonString(root, "event_id");
        if (eventId.Length == 0) throw new InvalidDataException("群组事件缺少 event_id。");
        if (!root.TryGetProperty("created_at_unix_ms", out var createdAtElement) ||
            !createdAtElement.TryGetInt64(out var eventCreatedAt) || eventCreatedAt <= 0)
            throw new InvalidDataException("群组事件 created_at_unix_ms 无效。");

        var incomingGroup = ParseGroup(root.GetProperty("group"));
        if (string.IsNullOrWhiteSpace(incomingGroup.GroupId) || !incomingGroup.GroupId.StartsWith("grp-", StringComparison.Ordinal) ||
            incomingGroup.Epoch <= 0)
            throw new InvalidDataException("群组事件 group_id 无效。");
        var incomingMembers = root.GetProperty("members").EnumerateArray()
            .Select(ParseGroupMember)
            .Where(member => member.GroupId == incomingGroup.GroupId)
            .ToArray();
        if (incomingMembers.Length == 0 || incomingMembers.Any(member => string.IsNullOrWhiteSpace(member.KeyId)) ||
            incomingMembers.Select(member => member.KeyId).Distinct(StringComparer.Ordinal).Count() != incomingMembers.Length)
            throw new InvalidDataException("群组事件没有有效且唯一的成员列表。");
        var existing = _state.Groups.FirstOrDefault(item => item.GroupId == incomingGroup.GroupId);
        var existingMembers = existing is null
            ? Array.Empty<GroupMemberRecord>()
            : _state.GroupMembers.Where(item => item.GroupId == incomingGroup.GroupId).ToArray();
        var recordedEvent = _state.GroupEvents.FirstOrDefault(item => item.EventId == eventId);
        if (recordedEvent is not null)
        {
            ValidateRecordedGroupEventReplay(recordedEvent, incomingGroup, type, sender.KeyId, root.GetRawText());
            if (existing is null) throw new InvalidDataException("已记录群事件所属群组不可用。");
            var replayConversation = type == "group_invite" ? sender.KeyId : existing.GroupId;
            return InboundMessage(
                inbound,
                sender,
                envelopeBase64,
                $"重复群事件已忽略：{existing.Name}",
                replayConversation);
        }

        var concurrentMembershipFork = IsConcurrentMembershipFork(type, incomingGroup, existing);
        GroupHistorySnapshot? causalAuthorizationSnapshot = null;
        if (existing is null || type == "group_message" || concurrentMembershipFork)
        {
            ValidateIncomingGroupAuthorization(
                type,
                incomingGroup,
                incomingMembers,
                existing,
                existingMembers,
                sender,
                root,
                concurrentMembershipFork);
        }
        else
        {
            InvalidDataException? currentValidationError = null;
            try
            {
                ValidateIncomingGroupAuthorization(
                    type,
                    incomingGroup,
                    incomingMembers,
                    existing,
                    existingMembers,
                    sender,
                    root,
                    concurrentMembershipFork: false);
            }
            catch (InvalidDataException error)
            {
                currentValidationError = error;
            }

            if (currentValidationError is not null)
            {
                if (!ShouldTryCausalAuthorization(type, incomingGroup, existing))
                    throw currentValidationError;
                causalAuthorizationSnapshot = FindCausalAuthorizationSnapshot(
                    type,
                    incomingGroup,
                    incomingMembers,
                    sender,
                    root);
                if (causalAuthorizationSnapshot is null)
                {
                    var hasPredecessorHistory = HasGroupHistoryAtEpoch(
                        incomingGroup.GroupId,
                        incomingGroup.Epoch - 1);
                    if (incomingGroup.Epoch <= existing.Epoch || hasPredecessorHistory)
                        throw new InvalidDataException("群组事件缺少可证明的前置历史快照。", currentValidationError);
                    throw currentValidationError;
                }
                ValidateCurrentCausalAuthorization(
                    type,
                    existing,
                    existingMembers,
                    sender,
                    root,
                    incomingMembers,
                    causalAuthorizationSnapshot.Members);
            }
        }

        var incomingIsNewer = existing is null || incomingGroup.Epoch > existing.Epoch ||
            (incomingGroup.Epoch == existing.Epoch && incomingGroup.UpdatedAtUnixMs >= existing.UpdatedAtUnixMs);
        var causalMerge = concurrentMembershipFork || causalAuthorizationSnapshot is not null;
        var staleEvent = existing is not null && !incomingIsNewer && !causalMerge;
        var membershipEvent = type is "group_invite" or "member_accepted" or "member_left" or "member_removed" or "member_endorsed";
        var storedGroup = type == "group_message"
            ? existing!
            : existing is not null && membershipEvent
                ? existing with
                {
                    Epoch = Math.Max(existing.Epoch, incomingGroup.Epoch),
                    UpdatedAtUnixMs = Math.Max(existing.UpdatedAtUnixMs, incomingGroup.UpdatedAtUnixMs),
                }
            : existing is not null && type is ("group_renamed" or "group_avatar_updated")
                ? MergeCausalGroupMetadata(existing, incomingGroup, type, eventId)
            : concurrentMembershipFork
                ? existing! with
            {
                UpdatedAtUnixMs = Math.Max(existing.UpdatedAtUnixMs, incomingGroup.UpdatedAtUnixMs),
            }
            : incomingIsNewer ? incomingGroup : existing!;
        IReadOnlyList<GroupMemberRecord> storedMembers;
        var preserveMembership = type is "group_message" or "group_renamed" or "group_avatar_updated" or "member_endorsed";
        if (preserveMembership || (staleEvent && !causalMerge))
        {
            storedMembers = existingMembers;
        }
        else
        {
            storedMembers = MergeIncomingGroupMembers(
                storedGroup.Policy,
                type,
                actorKeyId,
                GetJsonString(root, "target_key_id"),
                existingMembers,
                incomingMembers);
        }
        storedMembers = ApplyVerifiedLocalTrustOverlay(storedGroup, existingMembers, storedMembers, sender.KeyId);
        if (type != "group_message") ReplaceGroupAndMembers(storedGroup, storedMembers);

        if (_state.GroupEvents.All(item => item.EventId != eventId))
        {
            _state.GroupEvents.Add(new GroupEventRecord(
                eventId, storedGroup.GroupId, type, sender.KeyId, incomingGroup.Epoch,
                eventCreatedAt, root.GetRawText()));
        }

        if (storedGroup.Policy == GroupPolicy.Consensus && type != "group_message")
        {
            storedMembers = ApplyConsensusAdmissions(storedGroup, storedMembers);
            ReplaceGroupAndMembers(storedGroup, storedMembers);
        }

        if (type == "group_message")
        {
            var self = storedMembers.FirstOrDefault(item => item.KeyId == RequireIdentity().KeyId);
            var actor = storedMembers.FirstOrDefault(item => item.KeyId == sender.KeyId);
            if (self?.IsActive != true || actor?.IsActive != true) throw new InvalidDataException("非活跃成员不能收发群消息。");
            if (storedGroup.Policy == GroupPolicy.Verified && actor.TrustState is not (
                    GroupTrustState.Verified or GroupTrustState.Inviter or GroupTrustState.ConsensusAdmitted))
                throw new InvalidDataException("发送方尚未通过本机 fingerprint 验证，拒绝导入群消息。");
            var text = root.TryGetProperty("text", out var textElement) ? textElement.GetString() ?? string.Empty : string.Empty;
            return InboundMessage(inbound, sender, envelopeBase64, text, storedGroup.GroupId);
        }

        if (type is ("member_left" or "member_removed") && GroupRules.ShouldDissolve(storedMembers))
        {
            storedGroup = storedGroup with { IsActive = false };
            ReplaceGroupAndMembers(storedGroup, storedMembers);
        }
        var summary = type switch
        {
            "group_invite" => $"收到群邀请：{storedGroup.Name}",
            "member_accepted" => $"群成员已接受邀请：{storedGroup.Name}",
            "member_endorsed" => $"群成员已背书：{storedGroup.Name}",
            "group_renamed" => $"群名称已更新：{storedGroup.Name}",
            "group_avatar_updated" => $"群头像已更新：{storedGroup.Name}",
            "member_removed" => $"群成员已移除：{storedGroup.Name}",
            "member_left" => $"群成员已退出：{storedGroup.Name}",
            _ => $"收到群组事件：{storedGroup.Name}",
        };
        var conversation = type == "group_invite" ? sender.KeyId : storedGroup.GroupId;
        return InboundMessage(inbound, sender, envelopeBase64, summary, conversation);
    }

    private Dictionary<string, object?> CreateSignedGroupPayload(
        string type,
        GroupRecord group,
        IReadOnlyCollection<GroupMemberRecord> members,
        long now,
        IReadOnlyDictionary<string, object?>? extra = null)
    {
        var identity = RequireIdentity();
        var payload = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["type"] = type,
            ["event_id"] = $"gvt-{Guid.NewGuid():N}",
            ["actor_key_id"] = identity.KeyId,
            ["created_at_unix_ms"] = now,
            ["group"] = GroupToWire(group),
            ["members"] = members.Select(MemberToWire).ToArray(),
        };
        if (extra is not null) foreach (var item in extra) payload[item.Key] = item.Value;
        var unsignedJson = SerializeDartCompatibleJson(payload);
        var signature = _native.SignContextPayload(identity.IdentityJson, GroupEventSignatureContext, unsignedJson);
        if (signature.KeyId != identity.KeyId)
            throw new InvalidDataException("群事件签名身份与本机身份不匹配。");
        payload["signature"] = signature.Signature;
        return payload;
    }

    private static string GroupEventLogicalMessageId(IReadOnlyDictionary<string, object?> payload) =>
        $"group-event:{payload["event_id"]}";

    private static IEnumerable<GroupMemberRecord> GroupControlRecipients(
        IEnumerable<GroupMemberRecord> members,
        string selfKeyId) =>
        members.Where(member =>
            member.KeyId != selfKeyId &&
            member.Status is not (GroupMemberStatus.Left or GroupMemberStatus.Removed));

    private async Task<IReadOnlyList<PreparedGroupBroadcastChild>> PrepareGroupBroadcastCoreAsync(
        Dictionary<string, object?> payload,
        IEnumerable<StoredContact> recipients,
        string logicalMessageId,
        CancellationToken cancellationToken)
    {
        var identity = RequireIdentity();
        var uniqueRecipients = recipients
            .GroupBy(item => item.KeyId, StringComparer.Ordinal)
            .Select(item => item.First())
            .ToArray();
        if (uniqueRecipients.Length == 0) return [];
        var counters = await ReserveMessageCountersCoreAsync(uniqueRecipients.Length, cancellationToken)
            .ConfigureAwait(false);
        var bytes = Encoding.UTF8.GetBytes(SerializeDartCompatibleJson(payload));
        var children = new List<PreparedGroupBroadcastChild>(uniqueRecipients.Length);
        for (var index = 0; index < uniqueRecipients.Length; index++)
        {
            var contact = uniqueRecipients[index];
            var outbound = _native.EncryptOpaqueFile(
                identity.IdentityJson,
                contact.ContactJson,
                "group-control.json",
                GroupControlMime,
                bytes,
                counters[index]);
            children.Add(new PreparedGroupBroadcastChild(
                new OutboundWorkItem(
                    contact,
                    outbound.EnvelopeId,
                    outbound.EnvelopeBase64,
                    logicalMessageId,
                    index,
                    uniqueRecipients.Length),
                contact.DisplayLabel,
                counters[index]));
        }
        return children;
    }

    private async Task<IReadOnlyList<string>> StageAndDeliverGroupBroadcastCoreAsync(
        IReadOnlyList<PreparedGroupBroadcastChild> children,
        CancellationToken cancellationToken,
        ChatMessageRecord? logicalMessage = null,
        GroupMutationSnapshot? rollbackSnapshot = null)
    {
        if (children.Count == 0)
        {
            try
            {
                // Android commits the local group/event transaction before it
                // attempts broadcast. An owner-only active group can therefore
                // produce a valid control event with no current recipients; it
                // still must survive restart instead of existing only in RAM.
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            }
            catch
            {
                if (rollbackSnapshot is not null) RestoreGroupMutationSnapshot(rollbackSnapshot);
                throw;
            }
            return [];
        }
        try
        {
            await StageOutboundBatchCoreAsync(
                    children.Select(item => item.Work).ToArray(),
                    cancellationToken,
                    logicalMessage)
                .ConfigureAwait(false);
        }
        catch
        {
            if (rollbackSnapshot is not null) RestoreGroupMutationSnapshot(rollbackSnapshot);
            throw;
        }
        var details = new List<string>(children.Count);
        foreach (var child in children)
        {
            try
            {
                var work = child.Work;
                var delivery = await DeliverEnvelopeCoreAsync(
                        work.Contact,
                        work.EnvelopeId,
                        work.EnvelopeBase64,
                        cancellationToken,
                        work.LogicalMessageId,
                        work.ChildIndex,
                        work.ChildCount)
                    .ConfigureAwait(false);
                details.Add($"{child.DisplayLabel}: {delivery.Route}");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception error)
            {
                details.Add($"{child.DisplayLabel}: {error.Message}");
            }
        }
        return details;
    }

    private GroupMutationSnapshot CaptureGroupMutationSnapshot() => new(
        _state.Groups.ToArray(),
        _state.GroupMembers.ToArray(),
        _state.GroupEvents.ToArray());

    private void RestoreGroupMutationSnapshot(GroupMutationSnapshot snapshot)
    {
        _state.Groups.Clear();
        _state.Groups.AddRange(snapshot.Groups);
        _state.GroupMembers.Clear();
        _state.GroupMembers.AddRange(snapshot.Members);
        _state.GroupEvents.Clear();
        _state.GroupEvents.AddRange(snapshot.Events);
    }

    private static Dictionary<string, object?> GroupToWire(GroupRecord group) => new()
    {
        ["group_id"] = group.GroupId,
        ["name"] = group.Name,
        ["owner_key_id"] = group.OwnerKeyId,
        ["policy"] = EnumWire(group.Policy),
        ["epoch"] = group.Epoch,
        ["created_at_unix_ms"] = group.CreatedAtUnixMs,
        ["updated_at_unix_ms"] = group.UpdatedAtUnixMs,
        ["avatar_seed"] = group.AvatarSeed,
        ["is_active"] = group.IsActive ? 1 : 0,
    };

    private static Dictionary<string, object?> MemberToWire(GroupMemberRecord member) => new()
    {
        ["group_id"] = member.GroupId,
        ["key_id"] = member.KeyId,
        ["display_name"] = member.DisplayName,
        ["contact_json"] = member.ContactJson,
        ["role"] = EnumWire(member.Role),
        ["status"] = EnumWire(member.Status),
        ["trust_state"] = EnumWire(member.TrustState),
        ["invited_by_key_id"] = member.InvitedByKeyId,
        ["joined_at_unix_ms"] = member.JoinedAtUnixMs,
        ["updated_at_unix_ms"] = member.UpdatedAtUnixMs,
    };

    private static GroupRecord ParseGroup(JsonElement value) => new(
        value.GetProperty("group_id").GetString() ?? string.Empty,
        value.GetProperty("name").GetString() ?? string.Empty,
        value.GetProperty("owner_key_id").GetString() ?? string.Empty,
        ParseEnum(value.GetProperty("policy").GetString(), GroupPolicy.Normal),
        value.GetProperty("epoch").GetInt64(),
        value.GetProperty("created_at_unix_ms").GetInt64(),
        value.GetProperty("updated_at_unix_ms").GetInt64(),
        value.TryGetProperty("avatar_seed", out var avatar) && avatar.ValueKind == JsonValueKind.String ? avatar.GetString() ?? string.Empty : string.Empty,
        !value.TryGetProperty("is_active", out var active) || active.ValueKind == JsonValueKind.True || (active.ValueKind == JsonValueKind.Number && active.GetInt32() != 0));

    private static GroupMemberRecord ParseGroupMember(JsonElement value) => new(
        value.GetProperty("group_id").GetString() ?? string.Empty,
        value.GetProperty("key_id").GetString() ?? string.Empty,
        value.GetProperty("display_name").GetString() ?? string.Empty,
        value.GetProperty("contact_json").GetString() ?? string.Empty,
        ParseEnum(value.GetProperty("role").GetString(), GroupRole.Member),
        ParseEnum(value.GetProperty("status").GetString(), GroupMemberStatus.Pending),
        ParseEnum(value.GetProperty("trust_state").GetString(), GroupTrustState.Unverified),
        value.GetProperty("updated_at_unix_ms").GetInt64(),
        value.TryGetProperty("invited_by_key_id", out var invited) && invited.ValueKind == JsonValueKind.String ? invited.GetString() : null,
        value.TryGetProperty("joined_at_unix_ms", out var joined) && joined.ValueKind == JsonValueKind.Number ? joined.GetInt64() : null);

    private bool IsConcurrentMembershipFork(
        string type,
        GroupRecord incomingGroup,
        GroupRecord? existingGroup) =>
        existingGroup is not null &&
        type is "member_accepted" or "member_endorsed" &&
        incomingGroup.Epoch == existingGroup.Epoch &&
        _state.GroupEvents.Any(item =>
            item.GroupId == existingGroup.GroupId &&
            item.GroupEpoch == existingGroup.Epoch &&
            item.Type is "member_accepted" or "member_endorsed");

    private static void ValidateRecordedGroupEventReplay(
        GroupEventRecord recorded,
        GroupRecord incomingGroup,
        string type,
        string actorKeyId,
        string payloadJson)
    {
        if (recorded.GroupId != incomingGroup.GroupId || recorded.GroupEpoch != incomingGroup.Epoch ||
            recorded.Type != type || recorded.ActorKeyId != actorKeyId ||
            !string.Equals(recorded.PayloadJson, payloadJson, StringComparison.Ordinal))
            throw new InvalidDataException("群组事件 event_id 与已记录事件冲突。");
    }

    private bool ShouldTryCausalAuthorization(
        string type,
        GroupRecord incomingGroup,
        GroupRecord existingGroup)
    {
        if (incomingGroup.Epoch <= 1 || existingGroup.Epoch == long.MaxValue ||
            incomingGroup.Epoch > existingGroup.Epoch + 1)
            return false;
        if (type is "group_invite" or "member_accepted" or "member_left" or "member_removed" or "member_endorsed")
            return true;
        if (type is not ("group_renamed" or "group_avatar_updated")) return false;
        if (incomingGroup.Epoch == existingGroup.Epoch + 1) return true;
        return incomingGroup.Epoch == existingGroup.Epoch &&
               _state.GroupEvents.Any(item =>
                   item.GroupId == existingGroup.GroupId &&
                   item.GroupEpoch == existingGroup.Epoch &&
                   item.Type is "group_invite" or "member_accepted" or "member_left" or "member_removed" or "member_endorsed");
    }

    private GroupHistorySnapshot? FindCausalAuthorizationSnapshot(
        string type,
        GroupRecord incomingGroup,
        IReadOnlyList<GroupMemberRecord> incomingMembers,
        StoredContact sender,
        JsonElement root)
    {
        var eventCreatedAt = root.GetProperty("created_at_unix_ms").GetInt64();
        foreach (var snapshot in GroupHistoryAtEpoch(incomingGroup.GroupId, incomingGroup.Epoch - 1))
        {
            if (eventCreatedAt < snapshot.Group.UpdatedAtUnixMs) continue;
            try
            {
                ValidateIncomingGroupAuthorization(
                    type,
                    incomingGroup,
                    incomingMembers,
                    snapshot.Group,
                    snapshot.Members,
                    sender,
                    root,
                    concurrentMembershipFork: false);
                return snapshot;
            }
            catch (InvalidDataException)
            {
                // A different authenticated branch at the same predecessor epoch may still arrive later.
            }
        }
        return null;
    }

    private bool HasGroupHistoryAtEpoch(string groupId, long epoch) =>
        epoch > 0 && GroupHistoryAtEpoch(groupId, epoch).Count > 0;

    private IReadOnlyList<GroupHistorySnapshot> GroupHistoryAtEpoch(string groupId, long epoch)
    {
        if (epoch <= 0) return [];
        var snapshots = new List<GroupHistorySnapshot>();
        foreach (var groupEvent in _state.GroupEvents.Where(item =>
                     item.GroupId == groupId && item.GroupEpoch == epoch && item.Type != "group_message"))
        {
            try
            {
                using var document = JsonDocument.Parse(groupEvent.PayloadJson);
                var root = document.RootElement;
                if (!root.TryGetProperty("group", out var groupElement) ||
                    !root.TryGetProperty("members", out var membersElement) ||
                    membersElement.ValueKind != JsonValueKind.Array)
                    continue;
                var historicalGroup = ParseGroup(groupElement);
                var historicalMembers = membersElement.EnumerateArray()
                    .Select(ParseGroupMember)
                    .Where(member => member.GroupId == groupId)
                    .ToArray();
                if (historicalGroup.GroupId != groupId || historicalGroup.Epoch != epoch ||
                    historicalMembers.Length == 0 ||
                    historicalMembers.Select(member => member.KeyId)
                        .Distinct(StringComparer.Ordinal).Count() != historicalMembers.Length)
                    continue;
                snapshots.Add(new GroupHistorySnapshot(historicalGroup, historicalMembers));
            }
            catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException)
            {
                // Corrupt history is never accepted as causal authorization evidence.
            }
        }
        return snapshots;
    }

    private void ValidateCurrentCausalAuthorization(
        string type,
        GroupRecord currentGroup,
        IReadOnlyList<GroupMemberRecord> currentMembers,
        StoredContact sender,
        JsonElement root,
        IReadOnlyList<GroupMemberRecord> incomingMembers,
        IReadOnlyList<GroupMemberRecord> predecessorMembers)
    {
        var actor = currentMembers.FirstOrDefault(member => member.KeyId == sender.KeyId)
                    ?? throw new InvalidDataException("群组事件发送方不是已知群成员。");
        if (type == "group_invite")
        {
            RequireActiveOwner(currentGroup, actor, sender.KeyId);
            if (!currentGroup.IsActive)
                throw new InvalidDataException("已解散群组不能合并 causal group_invite。");
            var predecessorKeys = predecessorMembers.Select(member => member.KeyId)
                .ToHashSet(StringComparer.Ordinal);
            var additions = incomingMembers.Where(member => !predecessorKeys.Contains(member.KeyId)).ToArray();
            if (additions.Length == 0)
                throw new InvalidDataException("causal group_invite 没有可证明的新增成员。");
            foreach (var addition in additions)
            {
                var current = currentMembers.FirstOrDefault(member => member.KeyId == addition.KeyId);
                if (current is null) continue;
                ValidateStableMemberIdentityFields(current, addition);
                if (!MemberSnapshotMatches(currentGroup.Policy, current, addition))
                    throw new InvalidDataException("causal group_invite 与当前同 key 成员状态冲突。");
            }
            return;
        }
        if (type == "member_accepted")
        {
            if (!currentGroup.IsActive || actor.Status != GroupMemberStatus.Pending)
                throw new InvalidDataException("stale member_accepted 的发送方当前已不具备 pending 转换资格。");
            return;
        }
        if (type == "member_left")
        {
            if (!currentGroup.IsActive || actor.Status is GroupMemberStatus.Left or GroupMemberStatus.Removed)
                throw new InvalidDataException("stale member_left 的发送方当前已退出、被移除或群组已解散。");
            return;
        }
        if (type == "member_endorsed")
        {
            if (!currentGroup.IsActive || currentGroup.Policy != GroupPolicy.Consensus || !actor.IsActive)
                throw new InvalidDataException("stale member_endorsed 的发送方当前不再是共识群活跃成员。");
            ValidateIncomingConsensusEndorsement(currentGroup, currentMembers, sender.KeyId, root);
            return;
        }
        if (type == "member_removed")
        {
            RequireActiveOwner(currentGroup, actor, sender.KeyId);
            if (!currentGroup.IsActive)
                throw new InvalidDataException("已解散群组不能合并 stale member_removed。");
            var targetKeyId = GetJsonString(root, "target_key_id");
            var target = currentMembers.FirstOrDefault(member => member.KeyId == targetKeyId);
            if (target is null || target.KeyId == currentGroup.OwnerKeyId || target.Status == GroupMemberStatus.Removed)
                throw new InvalidDataException("stale member_removed 的当前目标状态无效。");
            return;
        }
        if (type is "group_renamed" or "group_avatar_updated")
        {
            RequireActiveOwner(currentGroup, actor, sender.KeyId);
            if (!currentGroup.IsActive) throw new InvalidDataException("已解散群组不能修改群元数据。");
            return;
        }
        throw new InvalidDataException("该群组事件类型不能作为 causal 分支合并。");
    }

    private GroupRecord MergeCausalGroupMetadata(
        GroupRecord existing,
        GroupRecord incoming,
        string type,
        string incomingEventId)
    {
        var competing = _state.GroupEvents
            .Where(item => item.GroupId == existing.GroupId && item.GroupEpoch == incoming.Epoch && item.Type == type)
            .OrderByDescending(item => item.CreatedAtUnixMs)
            .ThenByDescending(item => item.EventId, StringComparer.Ordinal)
            .FirstOrDefault();
        var incomingWins = competing is null || incoming.UpdatedAtUnixMs > competing.CreatedAtUnixMs ||
            (incoming.UpdatedAtUnixMs == competing.CreatedAtUnixMs &&
             string.CompareOrdinal(incomingEventId, competing.EventId) > 0);
        return existing with
        {
            Epoch = Math.Max(existing.Epoch, incoming.Epoch),
            UpdatedAtUnixMs = Math.Max(existing.UpdatedAtUnixMs, incoming.UpdatedAtUnixMs),
            Name = type == "group_renamed" && incomingWins ? incoming.Name : existing.Name,
            AvatarSeed = type == "group_avatar_updated" && incomingWins ? incoming.AvatarSeed : existing.AvatarSeed,
        };
    }

    private void ValidateIncomingGroupAuthorization(
        string type,
        GroupRecord incomingGroup,
        IReadOnlyList<GroupMemberRecord> incomingMembers,
        GroupRecord? existingGroup,
        IReadOnlyList<GroupMemberRecord> existingMembers,
        StoredContact sender,
        JsonElement root,
        bool concurrentMembershipFork)
    {
        var eventCreatedAt = root.GetProperty("created_at_unix_ms").GetInt64();
        if (existingGroup is not null && type == "group_message")
        {
            if (incomingGroup.OwnerKeyId != existingGroup.OwnerKeyId ||
                incomingGroup.Policy != existingGroup.Policy ||
                incomingGroup.CreatedAtUnixMs != existingGroup.CreatedAtUnixMs)
                throw new InvalidDataException("群消息试图修改不可变的群主、策略或创建时间。");
            if (incomingGroup.Epoch > existingGroup.Epoch)
                throw new InvalidDataException(
                    $"群组事件 epoch 必须为 {existingGroup.Epoch}，实际为 {incomingGroup.Epoch}。");
            var currentActor = existingMembers.FirstOrDefault(member => member.KeyId == sender.KeyId);
            var currentSelf = existingMembers.FirstOrDefault(member => member.KeyId == RequireIdentity().KeyId);
            if (!existingGroup.IsActive || currentActor?.IsActive != true || currentSelf?.IsActive != true)
                throw new InvalidDataException("非活跃成员不能收发群消息。");
            if (existingGroup.Policy == GroupPolicy.Verified && currentActor.TrustState is not (
                    GroupTrustState.Verified or GroupTrustState.Inviter or GroupTrustState.ConsensusAdmitted))
                throw new InvalidDataException("发送方尚未通过本机 fingerprint 验证，拒绝导入群消息。");
            return;
        }

        var incomingOwner = incomingMembers.FirstOrDefault(member =>
            member.KeyId == incomingGroup.OwnerKeyId && member.Role == GroupRole.Owner);
        if (incomingOwner is null || incomingMembers.Count(member => member.Role == GroupRole.Owner) != 1)
            throw new InvalidDataException("群组事件必须包含唯一且匹配 owner_key_id 的群主成员。");

        if (existingGroup is null)
        {
            if (type != "group_invite" || sender.KeyId != incomingGroup.OwnerKeyId || !incomingOwner.IsActive)
                throw new InvalidDataException("只有活跃群主发送的 group_invite 才能创建本地群组。");
            if (incomingGroup.Epoch != 1 || !incomingGroup.IsActive || string.IsNullOrWhiteSpace(incomingGroup.Name) ||
                incomingGroup.CreatedAtUnixMs != eventCreatedAt || incomingGroup.UpdatedAtUnixMs != eventCreatedAt ||
                incomingMembers.Count < GroupRules.MinimumGroupMembers)
                throw new InvalidDataException("新群邀请的群字段或成员数量无效。");
            foreach (var member in incomingMembers)
            {
                ValidateMemberContactIdentity(member);
                if (member.KeyId == incomingGroup.OwnerKeyId)
                {
                    if (member.Role != GroupRole.Owner || member.Status != GroupMemberStatus.Active ||
                        member.TrustState != GroupTrustState.Verified || member.InvitedByKeyId is not null ||
                        member.JoinedAtUnixMs != eventCreatedAt || member.UpdatedAtUnixMs != eventCreatedAt)
                        throw new InvalidDataException("新群邀请的群主成员字段不是 canonical 状态。");
                    continue;
                }
                var expectedTrust = incomingGroup.Policy == GroupPolicy.Consensus
                    ? GroupTrustState.ConsensusPending
                    : GroupTrustState.Inviter;
                if (member.Role != GroupRole.Member || member.Status != GroupMemberStatus.Pending ||
                    member.TrustState != expectedTrust || member.InvitedByKeyId != incomingGroup.OwnerKeyId ||
                    member.JoinedAtUnixMs is not null || member.UpdatedAtUnixMs != eventCreatedAt)
                    throw new InvalidDataException("新群邀请包含非 canonical 的待邀请成员。");
            }
            var self = incomingMembers.FirstOrDefault(member => member.KeyId == RequireIdentity().KeyId);
            if (self is null)
                throw new InvalidDataException("群邀请没有把本机身份列为合法的 pending 成员。");
            return;
        }

        if (incomingGroup.OwnerKeyId != existingGroup.OwnerKeyId ||
            incomingGroup.Policy != existingGroup.Policy ||
            incomingGroup.CreatedAtUnixMs != existingGroup.CreatedAtUnixMs)
            throw new InvalidDataException("群组事件试图修改不可变的群主、策略或创建时间。");

        var expectedEpoch = existingGroup.Epoch == long.MaxValue
            ? throw new InvalidDataException("群 epoch 已达到上限。")
            : existingGroup.Epoch + 1;
        if (!concurrentMembershipFork && incomingGroup.Epoch != expectedEpoch)
            throw new InvalidDataException($"群组事件 epoch 必须为 {expectedEpoch}，实际为 {incomingGroup.Epoch}。");
        if (incomingGroup.UpdatedAtUnixMs != eventCreatedAt)
        {
            throw new InvalidDataException("群控制事件的群更新时间必须等于事件创建时间。");
        }

        var actor = existingMembers.FirstOrDefault(member => member.KeyId == sender.KeyId);
        if (actor is null) throw new InvalidDataException("群组事件发送方不是已知群成员。");

        if (type == "group_invite")
        {
            RequireActiveOwner(existingGroup, actor, sender.KeyId);
            if (!existingGroup.IsActive) throw new InvalidDataException("已解散群组不能继续邀请成员。");
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: false, existingGroup.IsActive);
            ValidateUnchangedMemberSnapshot(
                existingGroup.Policy,
                existingMembers,
                incomingMembers,
                exceptKeyId: null,
                allowAdditional: true);
            var existingKeys = existingMembers.Select(member => member.KeyId).ToHashSet(StringComparer.Ordinal);
            var invitedMembers = incomingMembers.Where(member => !existingKeys.Contains(member.KeyId)).ToArray();
            if (invitedMembers.Length == 0) throw new InvalidDataException("后续群邀请没有新增成员。");
            foreach (var invited in invitedMembers)
            {
                var expectedTrust = existingGroup.Policy == GroupPolicy.Consensus
                    ? GroupTrustState.ConsensusPending
                    : GroupTrustState.Inviter;
                if (invited.Role != GroupRole.Member || invited.Status != GroupMemberStatus.Pending ||
                    invited.TrustState != expectedTrust || invited.InvitedByKeyId != existingGroup.OwnerKeyId ||
                    invited.JoinedAtUnixMs is not null || invited.UpdatedAtUnixMs != eventCreatedAt)
                    throw new InvalidDataException("后续群邀请的新成员字段无效。");
                ValidateMemberContactIdentity(invited);
            }
            return;
        }

        if (type == "member_accepted")
        {
            if (!existingGroup.IsActive || actor.Status != GroupMemberStatus.Pending)
                throw new InvalidDataException("只有活动群中的 pending 成员可以接受邀请。");
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: false, existingGroup.IsActive);
            if (concurrentMembershipFork)
                ValidateConcurrentMemberSnapshot(existingGroup, existingMembers, incomingMembers, sender.KeyId);
            else
                ValidateUnchangedMemberSnapshot(existingGroup.Policy, existingMembers, incomingMembers, sender.KeyId);
            var incomingActor = incomingMembers.FirstOrDefault(member => member.KeyId == sender.KeyId);
            var expectedStatus = existingGroup.Policy == GroupPolicy.Consensus
                ? GroupMemberStatus.Accepted
                : GroupMemberStatus.Active;
            var expectedTrust = existingGroup.Policy == GroupPolicy.Consensus
                ? GroupTrustState.ConsensusPending
                : GroupTrustState.Verified;
            ValidateTargetMemberDelta(
                existingGroup.Policy,
                actor,
                incomingActor,
                expectedStatus,
                expectedTrust,
                existingGroup.Policy == GroupPolicy.Consensus ? actor.JoinedAtUnixMs : eventCreatedAt,
                eventCreatedAt,
                "member_accepted");
            return;
        }

        if (type == "member_left")
        {
            if (actor.Status is GroupMemberStatus.Left or GroupMemberStatus.Removed)
                throw new InvalidDataException("已退出或被移除成员不能再次发送 member_left。");
            ValidateUnchangedMemberSnapshot(existingGroup.Policy, existingMembers, incomingMembers, sender.KeyId);
            var incomingActor = incomingMembers.FirstOrDefault(member => member.KeyId == sender.KeyId);
            ValidateTargetMemberDelta(
                existingGroup.Policy,
                actor,
                incomingActor,
                GroupMemberStatus.Left,
                GroupTrustState.Verified,
                actor.JoinedAtUnixMs,
                eventCreatedAt,
                "member_left");
            var projected = MergeIncomingGroupMembers(
                existingGroup.Policy,
                type,
                sender.KeyId,
                string.Empty,
                existingMembers,
                incomingMembers);
            var expectedActive = !GroupRules.ShouldDissolve(projected) && existingGroup.IsActive;
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: false, expectedActive);
            return;
        }

        if (type == "member_removed")
        {
            RequireActiveOwner(existingGroup, actor, sender.KeyId);
            var targetKeyId = GetJsonString(root, "target_key_id");
            var existingTarget = existingMembers.FirstOrDefault(member => member.KeyId == targetKeyId);
            var incomingTarget = incomingMembers.FirstOrDefault(member => member.KeyId == targetKeyId);
            if (existingTarget is null || targetKeyId == existingGroup.OwnerKeyId)
                throw new InvalidDataException("member_removed 的目标成员不存在或是群主。");
            ValidateUnchangedMemberSnapshot(existingGroup.Policy, existingMembers, incomingMembers, targetKeyId);
            ValidateTargetMemberDelta(
                existingGroup.Policy,
                existingTarget,
                incomingTarget,
                GroupMemberStatus.Removed,
                GroupTrustState.Unverified,
                existingTarget.JoinedAtUnixMs,
                eventCreatedAt,
                "member_removed");
            var projected = MergeIncomingGroupMembers(
                existingGroup.Policy,
                type,
                sender.KeyId,
                targetKeyId,
                existingMembers,
                incomingMembers);
            var expectedActive = !GroupRules.ShouldDissolve(projected) && existingGroup.IsActive;
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: false, expectedActive);
            return;
        }

        if (type == "member_endorsed")
        {
            if (!existingGroup.IsActive || existingGroup.Policy != GroupPolicy.Consensus || !actor.IsActive)
                throw new InvalidDataException("只有共识群活跃成员可以发送背书事件。");
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: false, existingGroup.IsActive);
            if (concurrentMembershipFork)
                ValidateConcurrentMemberSnapshot(existingGroup, existingMembers, incomingMembers, exceptKeyId: null);
            else
                ValidateUnchangedMemberSnapshot(
                    existingGroup.Policy,
                    existingMembers,
                    incomingMembers,
                    exceptKeyId: null);
            // Eligibility is local state, not the sender-provided membership snapshot. This prevents
            // an endorser from claiming that a still-pending candidate has already accepted.
            ValidateIncomingConsensusEndorsement(incomingGroup, existingMembers, sender.KeyId, root);
            return;
        }

        if (type == "group_renamed")
        {
            RequireActiveOwner(existingGroup, actor, sender.KeyId);
            if (!existingGroup.IsActive) throw new InvalidDataException("已解散群组不能重命名。");
            ValidateUnchangedMemberSnapshot(existingGroup.Policy, existingMembers, incomingMembers, exceptKeyId: null);
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: true, allowAvatar: false, existingGroup.IsActive);
            return;
        }

        if (type == "group_avatar_updated")
        {
            RequireActiveOwner(existingGroup, actor, sender.KeyId);
            if (!existingGroup.IsActive) throw new InvalidDataException("已解散群组不能更新头像。");
            ValidateUnchangedMemberSnapshot(existingGroup.Policy, existingMembers, incomingMembers, exceptKeyId: null);
            ValidateGroupDelta(existingGroup, incomingGroup, allowName: false, allowAvatar: true, existingGroup.IsActive);
            return;
        }

        throw new InvalidDataException($"未处理的群组事件类型：{type}。");
    }

    private static void RequireActiveOwner(GroupRecord group, GroupMemberRecord actor, string senderKeyId)
    {
        if (senderKeyId != group.OwnerKeyId || !actor.IsActive || actor.Role != GroupRole.Owner)
            throw new InvalidDataException("该群组事件只能由活跃群主发送。");
    }

    private static void ValidateGroupDelta(
        GroupRecord existing,
        GroupRecord incoming,
        bool allowName,
        bool allowAvatar,
        bool expectedActive)
    {
        if ((!allowName && incoming.Name != existing.Name) ||
            (allowName && string.IsNullOrWhiteSpace(incoming.Name)))
            throw new InvalidDataException("该群组事件不能修改群名称或群名称无效。");
        if ((!allowAvatar && incoming.AvatarSeed != existing.AvatarSeed) ||
            (allowAvatar && string.IsNullOrWhiteSpace(incoming.AvatarSeed)))
            throw new InvalidDataException("该群组事件不能修改群头像或群头像无效。");
        if (incoming.IsActive != expectedActive)
            throw new InvalidDataException("群组事件的 is_active 与允许的状态转换不一致。");
    }

    private static void ValidateUnchangedMemberSnapshot(
        GroupPolicy policy,
        IReadOnlyList<GroupMemberRecord> existingMembers,
        IReadOnlyList<GroupMemberRecord> incomingMembers,
        string? exceptKeyId,
        bool allowAdditional = false)
    {
        var incomingByKey = incomingMembers.ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        if (!allowAdditional && incomingByKey.Count != existingMembers.Count)
            throw new InvalidDataException("群组事件不能增加或删除非目标成员。");
        foreach (var existing in existingMembers)
        {
            if (!incomingByKey.TryGetValue(existing.KeyId, out var incoming))
                throw new InvalidDataException("群组事件遗漏了既有成员。");
            if (existing.KeyId == exceptKeyId) continue;
            ValidateStableMemberIdentityFields(existing, incoming);
            if (incoming.Status != existing.Status || incoming.JoinedAtUnixMs != existing.JoinedAtUnixMs ||
                incoming.UpdatedAtUnixMs != existing.UpdatedAtUnixMs ||
                !StableTrustMatches(policy, existing, incoming))
                throw new InvalidDataException("群组事件篡改了非目标成员状态。");
        }
    }

    private static void ValidateTargetMemberDelta(
        GroupPolicy policy,
        GroupMemberRecord existing,
        GroupMemberRecord? incoming,
        GroupMemberStatus expectedStatus,
        GroupTrustState expectedTrust,
        long? expectedJoinedAt,
        long eventCreatedAt,
        string eventType)
    {
        if (incoming is null) throw new InvalidDataException($"{eventType} 缺少目标成员。");
        ValidateStableMemberIdentityFields(existing, incoming);
        if (incoming.Status != expectedStatus ||
            (policy != GroupPolicy.Verified && incoming.TrustState != expectedTrust) ||
            incoming.JoinedAtUnixMs != expectedJoinedAt || incoming.UpdatedAtUnixMs != eventCreatedAt)
            throw new InvalidDataException($"{eventType} 包含未授权的目标成员字段变化。");
    }

    private static void ValidateStableMemberIdentityFields(
        GroupMemberRecord existing,
        GroupMemberRecord incoming)
    {
        if (incoming.GroupId != existing.GroupId || incoming.KeyId != existing.KeyId ||
            incoming.DisplayName != existing.DisplayName || incoming.ContactJson != existing.ContactJson ||
            incoming.Role != existing.Role || incoming.InvitedByKeyId != existing.InvitedByKeyId)
            throw new InvalidDataException("群组事件篡改了成员不可变字段。");
    }

    private void ValidateConcurrentMemberSnapshot(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> existingMembers,
        IReadOnlyList<GroupMemberRecord> incomingMembers,
        string? exceptKeyId)
    {
        var incomingByKey = incomingMembers.ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        if (incomingByKey.Count != existingMembers.Count)
            throw new InvalidDataException("并发群成员事件不能增加或删除成员。");
        foreach (var existing in existingMembers)
        {
            if (!incomingByKey.TryGetValue(existing.KeyId, out var incoming))
                throw new InvalidDataException("并发群成员事件遗漏了既有成员。");
            if (existing.KeyId == exceptKeyId) continue;
            ValidateStableMemberIdentityFields(existing, incoming);
            if (MemberSnapshotMatches(group.Policy, existing, incoming) ||
                IsAllowedConcurrentSnapshotLag(group, existing, incoming))
                continue;
            throw new InvalidDataException("并发群成员事件包含无法由本机事件历史解释的旁观者状态变化。");
        }
    }

    private static bool MemberSnapshotMatches(
        GroupPolicy policy,
        GroupMemberRecord existing,
        GroupMemberRecord incoming) =>
        incoming.Status == existing.Status &&
        incoming.JoinedAtUnixMs == existing.JoinedAtUnixMs &&
        incoming.UpdatedAtUnixMs == existing.UpdatedAtUnixMs &&
        StableTrustMatches(policy, existing, incoming);

    private static bool StableTrustMatches(
        GroupPolicy policy,
        GroupMemberRecord existing,
        GroupMemberRecord incoming)
    {
        if (policy == GroupPolicy.Verified || incoming.TrustState == existing.TrustState) return true;
        if (policy != GroupPolicy.Consensus || existing.Status != GroupMemberStatus.Active ||
            incoming.Status != GroupMemberStatus.Active)
            return false;
        return existing.TrustState is GroupTrustState.Verified or GroupTrustState.ConsensusAdmitted &&
               incoming.TrustState is GroupTrustState.Verified or GroupTrustState.ConsensusAdmitted;
    }

    private bool IsAllowedConcurrentSnapshotLag(
        GroupRecord group,
        GroupMemberRecord existing,
        GroupMemberRecord incoming)
    {
        if (incoming.UpdatedAtUnixMs > existing.UpdatedAtUnixMs) return false;
        var sameEpochEvents = _state.GroupEvents.Where(item =>
            item.GroupId == group.GroupId && item.GroupEpoch == group.Epoch).ToArray();
        var acceptedAtEpoch = sameEpochEvents.Any(item =>
            item.Type == "member_accepted" && item.ActorKeyId == existing.KeyId);
        if (acceptedAtEpoch && incoming.Status == GroupMemberStatus.Pending && incoming.JoinedAtUnixMs is null)
        {
            var expectedPendingTrust = group.Policy == GroupPolicy.Consensus
                ? GroupTrustState.ConsensusPending
                : GroupTrustState.Inviter;
            var locallyAdvanced = group.Policy == GroupPolicy.Consensus
                ? existing.Status is GroupMemberStatus.Accepted or GroupMemberStatus.Active
                : existing.Status == GroupMemberStatus.Active;
            if (locallyAdvanced &&
                (group.Policy == GroupPolicy.Verified || incoming.TrustState == expectedPendingTrust))
                return true;
        }

        if (group.Policy != GroupPolicy.Consensus || incoming.Status != GroupMemberStatus.Accepted ||
            incoming.TrustState != GroupTrustState.ConsensusPending || existing.Status != GroupMemberStatus.Active)
            return false;
        return sameEpochEvents.Any(item =>
        {
            if (item.Type != "member_endorsed") return false;
            try
            {
                using var document = JsonDocument.Parse(item.PayloadJson);
                return GetJsonString(document.RootElement, "candidate_key_id") == existing.KeyId;
            }
            catch (JsonException)
            {
                return false;
            }
        });
    }

    private void ValidateMemberContactIdentity(GroupMemberRecord member)
    {
        if (string.IsNullOrWhiteSpace(member.ContactJson))
            throw new InvalidDataException($"群成员 {member.KeyId} 缺少 contact_json。");
        try
        {
            var parsed = _native.ParseContact(member.ContactJson);
            if (parsed.KeyId != member.KeyId)
                throw new InvalidDataException($"群成员 {member.KeyId} 的 contact_json 身份不匹配。");
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new InvalidDataException($"群成员 {member.KeyId} 的 contact_json 无效。", error);
        }
    }

    private static IReadOnlyList<GroupMemberRecord> MergeIncomingGroupMembers(
        GroupPolicy policy,
        string type,
        string actorKeyId,
        string targetKeyId,
        IReadOnlyList<GroupMemberRecord> existingMembers,
        IReadOnlyList<GroupMemberRecord> incomingMembers)
    {
        var existingByKey = existingMembers.ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        if (type == "group_invite" && existingMembers.Count > 0)
        {
            var invited = new Dictionary<string, GroupMemberRecord>(existingByKey, StringComparer.Ordinal);
            foreach (var incoming in incomingMembers)
            {
                if (!invited.ContainsKey(incoming.KeyId)) invited[incoming.KeyId] = incoming;
            }
            return invited.Values.ToArray();
        }
        if (existingMembers.Count == 0) return incomingMembers.ToArray();

        var changedKeyId = type switch
        {
            "member_accepted" or "member_left" => actorKeyId,
            "member_removed" => targetKeyId,
            _ => string.Empty,
        };
        if (changedKeyId.Length == 0) return existingMembers.ToArray();
        var incomingByKey = incomingMembers.ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        return existingMembers.Select(existing =>
                existing.KeyId == changedKeyId && incomingByKey.TryGetValue(changedKeyId, out var changed)
                    ? policy == GroupPolicy.Verified
                        ? changed with { TrustState = existing.TrustState }
                        : changed
                    : existing)
            .ToArray();
    }

    private IReadOnlyList<GroupMemberRecord> ApplyVerifiedLocalTrustOverlay(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> existingMembers,
        IReadOnlyList<GroupMemberRecord> proposedMembers,
        string senderKeyId)
    {
        if (group.Policy != GroupPolicy.Verified) return proposedMembers;
        var existingByKey = existingMembers.ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        var selfKeyId = RequireIdentity().KeyId;
        return proposedMembers.Select(member =>
        {
            if (existingByKey.TryGetValue(member.KeyId, out var existing))
                return member with { TrustState = existing.TrustState };
            var localTrust = member.KeyId == selfKeyId
                ? GroupTrustState.Verified
                : member.KeyId == senderKeyId
                    ? GroupTrustState.Inviter
                    : GroupTrustState.Unverified;
            return member with { TrustState = localTrust };
        }).ToArray();
    }

    private static string SerializeWithoutSignature(JsonElement root)
    {
        return SerializeDartCompatibleJson(root, omitRootSignature: true);
    }

    private static string SerializeDartCompatibleJson(object? value)
    {
        if (value is JsonElement element) return SerializeDartCompatibleJson(element, omitRootSignature: false);
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(value, Json));
        return SerializeDartCompatibleJson(document.RootElement, omitRootSignature: false);
    }

    private static string SerializeDartCompatibleJson(JsonElement root, bool omitRootSignature)
    {
        var builder = new StringBuilder();
        AppendDartCompatibleJson(builder, root, omitRootSignature);
        return builder.ToString();
    }

    private static void AppendDartCompatibleJson(
        StringBuilder builder,
        JsonElement value,
        bool omitRootSignature = false)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
            {
                builder.Append('{');
                var first = true;
                foreach (var property in value.EnumerateObject())
                {
                    if (omitRootSignature && property.NameEquals("signature")) continue;
                    if (!first) builder.Append(',');
                    first = false;
                    AppendDartCompatibleJsonString(builder, property.Name);
                    builder.Append(':');
                    AppendDartCompatibleJson(builder, property.Value);
                }
                builder.Append('}');
                return;
            }
            case JsonValueKind.Array:
            {
                builder.Append('[');
                var first = true;
                foreach (var item in value.EnumerateArray())
                {
                    if (!first) builder.Append(',');
                    first = false;
                    AppendDartCompatibleJson(builder, item);
                }
                builder.Append(']');
                return;
            }
            case JsonValueKind.String:
                AppendDartCompatibleJsonString(builder, value.GetString() ?? string.Empty);
                return;
            case JsonValueKind.Number:
                builder.Append(value.GetRawText());
                return;
            case JsonValueKind.True:
                builder.Append("true");
                return;
            case JsonValueKind.False:
                builder.Append("false");
                return;
            case JsonValueKind.Null:
                builder.Append("null");
                return;
            default:
                throw new InvalidDataException("群签名 JSON 包含不支持的值。");
        }
    }

    private static void AppendDartCompatibleJsonString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var rune in value.EnumerateRunes())
        {
            switch (rune.Value)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                case < 0x20:
                    builder.Append("\\u");
                    builder.Append(rune.Value.ToString("x4"));
                    break;
                default:
                    builder.Append(rune.ToString());
                    break;
            }
        }
        builder.Append('"');
    }

    private void ReplaceGroupAndMembers(GroupRecord group, IEnumerable<GroupMemberRecord> members)
    {
        _state.Groups.RemoveAll(item => item.GroupId == group.GroupId);
        _state.Groups.Add(group);
        _state.GroupMembers.RemoveAll(item => item.GroupId == group.GroupId);
        _state.GroupMembers.AddRange(members);
    }

    private static IReadOnlyList<string> DissolutionReasons(IEnumerable<GroupMemberRecord> members)
    {
        var snapshot = members.ToArray();
        var reasons = new List<string>();
        if (!snapshot.Any(member => member.Role == GroupRole.Owner && member.Status == GroupMemberStatus.Active))
            reasons.Add("owner_left");
        if (snapshot.Count(member => member.Status is not (
                GroupMemberStatus.Left or GroupMemberStatus.Removed)) < GroupRules.MinimumGroupMembers)
            reasons.Add("minimum_member_count");
        return reasons;
    }

    private static GroupEventRecord ToGroupEvent(GroupRecord group, Dictionary<string, object?> payload) => new(
        payload["event_id"]?.ToString() ?? $"gvt-{Guid.NewGuid():N}", group.GroupId,
        payload["type"]?.ToString() ?? "unknown", payload["actor_key_id"]?.ToString() ?? string.Empty,
        group.Epoch, Convert.ToInt64(payload["created_at_unix_ms"]), SerializeDartCompatibleJson(payload));

    private static string EnumWire<T>(T value) where T : struct, Enum
    {
        var name = value.ToString();
        var builder = new StringBuilder();
        for (var index = 0; index < name.Length; index++)
        {
            var character = name[index];
            if (char.IsUpper(character) && index > 0) builder.Append('_');
            builder.Append(char.ToLowerInvariant(character));
        }
        return builder.ToString();
    }

    private static T ParseEnum<T>(string? value, T fallback) where T : struct, Enum
    {
        var normalized = (value ?? string.Empty).Replace("_", string.Empty, StringComparison.Ordinal);
        return Enum.GetValues<T>().FirstOrDefault(
            item => item.ToString().Equals(normalized, StringComparison.OrdinalIgnoreCase),
            fallback);
    }
}
