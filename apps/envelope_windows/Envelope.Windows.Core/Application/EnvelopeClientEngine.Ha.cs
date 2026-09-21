using System.Globalization;
using System.Text.Json;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Core.Application;

public sealed partial class EnvelopeClientEngine
{
    private long _haRegisteredRouteRenewAfterUnixMs;
    private string? _haRegisteredRouteTicket;

    private async Task<string> SendHaAuthorizedCoreAsync(string path, string kind, object body, string identityJson,
        string actorId, string operationId, CancellationToken cancellationToken)
    {
        var server = RequireHaServerCore();
        try { return await server.SendAsync(path, kind, body, identityJson, actorId, operationId, cancellationToken).ConfigureAwait(false); }
        catch (EnvelopeHaServerException error) when (error.Code == "AUTH_FAILED" && error.Reason == "NOT_REGISTERED")
        {
            _haRegisteredRouteRenewAfterUnixMs = 0;
            await RegisterHaRouteCoreAsync(cancellationToken).ConfigureAwait(false);
            return await server.SendAsync(path, kind, body, identityJson, actorId, operationId, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task ApplyP2pResultBundleCoreAsync(EnvelopeP2pAck ack, string contactJson, CancellationToken cancellationToken)
    {
        foreach (var json in ack.RecipientResultsJson ?? [])
        {
            var result = EnvelopeHaProtocol.Deserialize<HaRecipientResult>(json);
            if (_state.PendingEnvelopes.Any(item => item.EnvelopeId == result.EnvelopeId && item.Ha is not null))
                await ApplyRecipientResultCoreAsync(result.EnvelopeId, json, contactJson, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<DeliveryResult?> TryDeliverHaRouteCoreAsync(Models.StoredContact contact, string envelopeId,
        string envelopeBase64, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(contact.DeviceId)) return null;
        string? ticket = null;
        try
        {
            var identity = RequireIdentity();
            var response = await SendHaAuthorizedCoreAsync($"v2/routes/{Uri.EscapeDataString(contact.KeyId)}/{Uri.EscapeDataString(contact.DeviceId)}",
                "lookup_route", new { owner_key_id = contact.KeyId, device_id = contact.DeviceId }, identity.IdentityJson,
                identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false);
            var endpoint = EnvelopeHaProtocol.RouteEndpoint(response, contact.KeyId, contact.DeviceId, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            if (endpoint is null || !_p2pCooldown.CanAttempt(contact.KeyId, endpoint.P2pTicket)) return null;
            ticket = endpoint.P2pTicket;
            // A route from the authenticated relay only selects transport. The
            // original ciphertext/id remain fixed, and only the contact's signed
            // recipient result can establish delivery at this new address.
            var ack = await _p2p.SendEnvelopeAsync(ticket, DecodeBase64Url(envelopeBase64), envelopeId,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            if (ack.EnvelopeId != envelopeId) throw new InvalidDataException("P2P 路由回执信封 ID 不匹配。");
            await ApplyP2pResultBundleCoreAsync(ack, contact.ContactJson, cancellationToken).ConfigureAwait(false);
            if (ack.RecipientResultJson is { } resultJson &&
                await ApplyRecipientResultCoreAsync(envelopeId, resultJson, contact.ContactJson, cancellationToken).ConfigureAwait(false))
            {
                _p2pCooldown.RecordSuccess(contact.KeyId, ticket);
                return new("server_route_p2p_v2", _state.PendingEnvelopes.Single(item => item.EnvelopeId == envelopeId).DeliveryState,
                    "已通过更新后的 P2P 路由验证并保存收件方签名结果。");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { if (ticket is not null) _p2pCooldown.RecordFailure(contact.KeyId, ticket); }
        return null;
    }

    private async Task<IReadOnlyList<string>?> SignCompletedFileResultBundleCoreAsync(string envelopeId, string senderKeyId, CancellationToken cancellationToken)
    {
        var current = _state.RecipientResultOutbox.FirstOrDefault(item => item.EnvelopeId == envelopeId &&
            item.SenderKeyId == senderKeyId && item.RecipientKeyId == RequireIdentity().KeyId);
        if (current is not { Outcome: HaDeliveryState.Delivered, LogicalMessageId: not null } ||
            !current.LogicalMessageId.StartsWith("inbound-file:", StringComparison.Ordinal)) return null;
        var bundle = new List<string>();
        foreach (var part in _state.RecipientResultOutbox.Where(item => item.SenderKeyId == current.SenderKeyId &&
                     item.RecipientKeyId == current.RecipientKeyId && item.LogicalMessageId == current.LogicalMessageId &&
                     item.Outcome == HaDeliveryState.Delivered).Take(64).ToArray())
        {
            var signed = await SignRecipientResultCoreAsync(part.EnvelopeId, cancellationToken, part.SenderKeyId).ConfigureAwait(false);
            if (signed is not null) bundle.Add(signed);
        }
        return bundle;
    }

    private async Task<OwnedIntroSession> PublishHaIntroAsync(ulong ttlSeconds, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var bundle = _native.CreateIntroBundle(identity.IdentityJson, _state.DeviceId, _state.CurrentP2pTicket ?? "", ttlSeconds);
            var sessionId = "session-" + Guid.NewGuid().ToString("N");
            var server = RequireHaServerCore();
            var result = await SendHaAuthorizedCoreAsync($"v2/intro-sessions/{sessionId}", "intro_publish",
                new { session_id = sessionId, owner_bundle = EnvelopeHaProtocol.Element(bundle.BundleJson) }, identity.IdentityJson, identity.KeyId, sessionId, cancellationToken).ConfigureAwait(false);
            VerifyHaMutationResponse(result);
            return new(sessionId, server.ActiveBaseUri!.AbsoluteUri, bundle, checked((long)bundle.ExpiresAtUnixMs));
        }
        finally { _gate.Release(); }
    }

    private async Task<Models.IntroBundleSummary> RespondHaIntroAsync(string sessionId, string serverUrl, ulong ttlSeconds,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await VerifyHaIntroEndpointCoreAsync(serverUrl, cancellationToken).ConfigureAwait(false);
            var identity = RequireIdentity();
            var bundle = _native.CreateIntroBundle(identity.IdentityJson, _state.DeviceId, _state.CurrentP2pTicket ?? "", ttlSeconds);
            var result = await SendHaAuthorizedCoreAsync($"v2/intro-sessions/{sessionId}/response", "intro_respond",
                new { session_id = sessionId, responder_bundle = EnvelopeHaProtocol.Element(bundle.BundleJson) },
                identity.IdentityJson, identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false);
            VerifyHaMutationResponse(result);
            return bundle;
        }
        finally { _gate.Release(); }
    }

    private async Task<IntroSessionResponse?> PollHaIntroAsync(string sessionId, string serverUrl, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await VerifyHaIntroEndpointCoreAsync(serverUrl, cancellationToken).ConfigureAwait(false);
            var identity = RequireIdentity();
            var response = EnvelopeHaProtocol.Element(await SendHaAuthorizedCoreAsync($"v2/intro-sessions/{sessionId}/response", "intro_lookup",
                new { session_id = sessionId }, identity.IdentityJson, identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false));
            if (response.GetProperty("session_id").GetString() != sessionId || response.GetProperty("owner_key_id").GetString() != identity.KeyId)
                throw new InvalidDataException("互加会话身份不匹配。");
            if (!response.TryGetProperty("responder_bundle", out var result) || result.ValueKind == JsonValueKind.Null) return null;
            var verified = _native.VerifyIntroBundle(result.GetRawText());
            if (verified.KeyId == identity.KeyId) throw new InvalidDataException("互加响应不能来自本机身份。");
            return new(sessionId, verified);
        }
        finally { _gate.Release(); }
    }

    private async Task VerifyHaIntroEndpointCoreAsync(string url, CancellationToken cancellationToken)
    {
        var server = RequireHaServerCore();
        await server.DiscoverAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        var config = EnvelopeHaProtocol.Deserialize<HaClusterConfig>(server.ConfigJson!);
        if (!config.BusinessNodes.Any(node => new Uri(node.PublicUrl.TrimEnd('/') + "/") == new Uri(url.TrimEnd('/') + "/")))
            throw new InvalidDataException("互加邀请包含未授权的服务器地址。");
    }

    private static void VerifyHaMutationResponse(string json)
    {
        var result = EnvelopeHaProtocol.Element(json);
        if (result.GetProperty("protocol_version").GetInt32() != 2 || result.GetProperty("status").GetString() != "replicated" ||
            HaSequence.Parse(result.GetProperty("commit_index").GetString()!) <= 0)
            throw new InvalidDataException("写入尚未获得主备提交确认。");
    }

    private EnvelopeHaServerClient RequireHaServerCore() => _haServer ??= new(_native,
        _haTrust ?? throw new InvalidOperationException("发行包没有 HA 信任配置。"),
        _state.HaClusterConfigJson, _state.HaClusterWatermarks.SingleOrDefault(),
        async (config, watermark, token) =>
        {
            var previousConfig = _state.HaClusterConfigJson;
            var previous = _state.HaClusterWatermarks.ToArray();
            _state.HaClusterConfigJson = config;
            _state.HaClusterWatermarks.Clear(); _state.HaClusterWatermarks.Add(watermark);
            try { await PersistCoreAsync(token).ConfigureAwait(false); }
            catch
            {
                _state.HaClusterConfigJson = previousConfig;
                _state.HaClusterWatermarks.Clear(); _state.HaClusterWatermarks.AddRange(previous);
                throw;
            }
        });

    private async Task<DeliveryResult> DeliverHaEnvelopeCoreAsync(Models.StoredContact contact, string envelopeId,
        CancellationToken cancellationToken)
    {
        var pending = _state.PendingEnvelopes.Single(item => item.EnvelopeId == envelopeId);
        var ha = pending.Ha ?? throw new InvalidDataException("待发项没有固定 v2 身份。");
        if (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() >= ha.NotAfterUnixMs)
            return new("local", DeliveryState.Pending, "保存期限已过，保留原操作记录等待对账。");
        try
        {
            var server = RequireHaServerCore();
            var identity = RequireIdentity();
            var response = await SendHaAuthorizedCoreAsync("v2/envelopes", "store_envelope", new
            {
                binding = EnvelopeHaProtocol.Binding(pending),
                sender_contact = EnvelopeHaProtocol.Element(_native.ContactFromIdentity(identity.IdentityJson)),
                envelope_b64 = pending.EnvelopeBase64.TrimEnd('='),
                created_at = EnvelopeHaProtocol.Decimal(pending.CreatedAtUnixMs),
            }, identity.IdentityJson, identity.KeyId, ha.OperationId, cancellationToken).ConfigureAwait(false);
            await ApplyHaReceiptCoreAsync(envelopeId, response, cancellationToken).ConfigureAwait(false);
            return new("server_mailbox_v2", DeliveryState.ServerMailbox,
                _state.PendingEnvelopes.Single(item => item.EnvelopeId == envelopeId).Ha!.StorageState == HaStorageState.Replicated
                    ? "主备已可靠保存，等待收件方接收。" : "单节点暂存，等待恢复可靠保存。");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception error)
        {
            return await CompleteOutboundDeliveryCoreAsync(envelopeId,
                new("pending", DeliveryState.Pending, error.Message), cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task ApplyHaReceiptCoreAsync(string envelopeId, string receiptJson, CancellationToken cancellationToken)
    {
        var index = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == envelopeId);
        var pending = _state.PendingEnvelopes[index];
        var ha = pending.Ha!;
        var server = RequireHaServerCore();
        var receipt = new EnvelopeHaProtocol(_native).VerifyReceipt(server.ConfigJson!, receiptJson, EnvelopeHaProtocol.Binding(pending), _haTrust!.AdminPublic);
        var storage = receipt.GetProperty("storage_state").GetString() switch
        {
            "replicated" => HaStorageState.Replicated,
            "staged_single" => HaStorageState.StagedSingle,
            _ => throw new InvalidDataException("服务端未提供持久化保存证据。"),
        };
        var expiry = receipt.GetProperty("delivery_state").GetString() == "expired" && storage == HaStorageState.Replicated &&
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() >= ha.NotAfterUnixMs &&
            ha.DeliveryState is not (HaDeliveryState.Delivered or HaDeliveryState.Rejected);
        var messagesBefore = _state.Messages.ToArray();
        _state.PendingEnvelopes[index] = pending with
        {
            Ha = ha with
            {
                StorageState = (HaStorageState)Math.Max((int)ha.StorageState, (int)storage),
                CommitReceiptJson = ha.StorageState > storage ? ha.CommitReceiptJson : receiptJson,
                DeliveryState = expiry ? HaDeliveryState.Expired : ha.DeliveryState,
                ExpiryReceiptJson = expiry ? receiptJson : ha.ExpiryReceiptJson,
            },
            DeliveryState = pending.Ha!.DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected
                ? pending.DeliveryState : DeliveryState.ServerMailbox,
            NextAttemptAtUnixMs = null,
            LastError = null,
        };
        RefreshLogicalMessageDeliveryCore(pending.LogicalMessageId ?? envelopeId);
        try { await PersistCoreAsync(cancellationToken).ConfigureAwait(false); }
        catch
        {
            _state.PendingEnvelopes[index] = pending;
            _state.Messages.Clear(); _state.Messages.AddRange(messagesBefore);
            throw;
        }
    }

    private async Task<MailboxSyncResult> SynchronizeHaCoreAsync(CancellationToken cancellationToken)
    {
        var server = RequireHaServerCore();
        var identity = RequireIdentity();
        await server.DiscoverAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        await RegisterHaRouteCoreAsync(cancellationToken).ConfigureAwait(false);
        var fetched = 0; var imported = 0; var duplicates = 0; var resultsSent = 0; var deliveredUpdated = 0;
        // Server caps page bytes. Cursor advances past deferred entries and is
        // durable so a large transfer cannot block later causal prerequisites.
        for (var page = 0; page < 50; page++)
        {
        var response = EnvelopeHaProtocol.Element(await SendHaAuthorizedCoreAsync($"v2/mailbox/{Uri.EscapeDataString(identity.KeyId)}/pull",
            "pull_mailbox", new { limit = 50, cursor = _state.HaMailboxCursor }, identity.IdentityJson, identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false));
        if (response.GetProperty("protocol_version").GetInt32() != 2) throw new InvalidDataException("不支持的 mailbox 版本。");
        foreach (var item in response.GetProperty("items").EnumerateArray())
        {
            fetched++;
            var binding = EnvelopeHaProtocol.Deserialize<HaEnvelopeBinding>(item.GetProperty("binding").GetRawText());
            if (binding.RecipientKeyId != identity.KeyId) throw new InvalidDataException("mailbox 收件人不匹配。");
            var opaque = item.GetProperty("envelope_b64").GetString()!;
            if (HaOutboundState.Hash(opaque) != binding.EnvelopeSha256) throw new InvalidDataException("mailbox 正文 hash 不匹配。");
            new EnvelopeHaProtocol(_native).VerifyReceipt(server.ConfigJson!, item.GetProperty("receipt").GetRawText(), binding, _haTrust!.AdminPublic);
            try
            {
                var result = await ImportEnvelopeAndPersistCoreAsync(opaque, binding.SenderKeyId, cancellationToken).ConfigureAwait(false);
                if (result.Duplicate) duplicates++; else imported++;
            }
            catch (Exception error) when (error is not OperationCanceledException && TryClassifyPermanentMailboxPoison(error, out _))
            {
                StageRejectedHaResultCore(binding, "INVALID_ENVELOPE");
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OperationCanceledException && error is not IOException && error is not UnauthorizedAccessException)
            {
                var snapshot = _state.DeferredMailboxEnvelopes.ToArray();
                var resultsSnapshot = _state.RecipientResultOutbox.ToArray();
                if (StageDeferredMailboxEnvelopeCore(binding.EnvelopeId, binding.SenderKeyId, opaque,
                    ("CAUSAL_PREREQUISITE", error.Message), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))
                {
                    if (!_state.RecipientResultOutbox.Any(value => value.EnvelopeId == binding.EnvelopeId && value.SenderKeyId == binding.SenderKeyId && value.RecipientKeyId == binding.RecipientKeyId))
                        _state.RecipientResultOutbox.Add(new(binding.SenderKeyId, binding.RecipientKeyId, binding.EnvelopeId,
                            binding.EnvelopeSha256, HaDeliveryState.Deferred, "CAUSAL_PREREQUISITE", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                            Guid.NewGuid().ToString("N"), "1", BusinessApplied: false));
                    try { await PersistCoreAsync(cancellationToken).ConfigureAwait(false); }
                    catch
                    {
                        _state.DeferredMailboxEnvelopes.Clear(); _state.DeferredMailboxEnvelopes.AddRange(snapshot);
                        _state.RecipientResultOutbox.Clear(); _state.RecipientResultOutbox.AddRange(resultsSnapshot);
                        throw;
                    }
                }
            }
        }
        _state.HaMailboxCursor = response.TryGetProperty("next_cursor", out var cursor) && cursor.ValueKind == JsonValueKind.String ? cursor.GetString() : null;
        await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        if (_state.HaMailboxCursor is null) break;
        }
        var deferred = await RetryDeferredMailboxCoreAsync(cancellationToken).ConfigureAwait(false);
        imported += deferred.Imported; duplicates += deferred.Duplicates;
        var retryResultBefore = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 30_000;
        foreach (var descriptor in _state.RecipientResultOutbox.Where(item => !item.Replicated && item.RecipientKeyId == identity.KeyId &&
                         (item.LastSentAtUnixMs is null || item.LastSentAtUnixMs <= retryResultBefore))
                     .OrderBy(item => item.LastSentAtUnixMs ?? 0).Take(20).ToArray())
        {
            var signed = await SignRecipientResultCoreAsync(descriptor.EnvelopeId, cancellationToken, descriptor.SenderKeyId).ConfigureAwait(false);
            if (signed is null) continue;
            // Keep end-to-end evidence even after upload; server acceptance is
            // not proof that both business replicas have the terminal index.
            var resultReply = EnvelopeHaProtocol.Element(await SendHaAuthorizedCoreAsync($"v2/mailbox/{Uri.EscapeDataString(identity.KeyId)}/results", "record_result",
                new { result = EnvelopeHaProtocol.Element(signed), recipient_contact = EnvelopeHaProtocol.Element(_native.ContactFromIdentity(identity.IdentityJson)) },
                identity.IdentityJson, identity.KeyId, descriptor.ResultId, cancellationToken).ConfigureAwait(false));
            if (resultReply.GetProperty("protocol_version").GetInt32() != 2)
                throw new InvalidDataException("接收结果提交版本无效。");
            var replicated = resultReply.GetProperty("status").GetString() == "replicated" &&
                resultReply.TryGetProperty("commit_index", out var commit) && commit.ValueKind == JsonValueKind.String &&
                HaSequence.Parse(commit.GetString()!) > 0;
            resultsSent++;
            var index = _state.RecipientResultOutbox.FindIndex(item => item.ResultId == descriptor.ResultId);
            if (index >= 0)
            {
                _state.RecipientResultOutbox[index] = _state.RecipientResultOutbox[index] with
                { LastSentAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Replicated = replicated };
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        var pending = HaDeliveryPolling.Select(_state.PendingEnvelopes, _state.HaDeliveryPollCursor);
        if (pending.Length > 0)
        {
            var statuses = EnvelopeHaProtocol.Element(await SendHaAuthorizedCoreAsync($"v2/delivery/{Uri.EscapeDataString(identity.KeyId)}/status", "delivery_status",
                new { bindings = pending.Select(EnvelopeHaProtocol.Binding).ToArray() }, identity.IdentityJson, identity.KeyId,
                Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false));
            foreach (var item in statuses.GetProperty("items").EnumerateArray())
            {
                var binding = EnvelopeHaProtocol.Deserialize<HaEnvelopeBinding>(item.GetProperty("binding").GetRawText());
                var original = pending.SingleOrDefault(value => value.EnvelopeId == binding.EnvelopeId);
                if (original is null || EnvelopeHaProtocol.Binding(original) != binding) throw new InvalidDataException("状态响应绑定不匹配。");
                if (item.TryGetProperty("receipt", out var receipt) && receipt.ValueKind == JsonValueKind.Object)
                    await ApplyHaReceiptCoreAsync(original.EnvelopeId, receipt.GetRawText(), cancellationToken).ConfigureAwait(false);
                if (item.TryGetProperty("result", out var result) && result.ValueKind == JsonValueKind.Object)
                {
                    var contact = ResolvePendingRecipient(original);
                    if (contact is not null && await ApplyRecipientResultCoreAsync(original.EnvelopeId, result.GetRawText(), contact.ContactJson, cancellationToken).ConfigureAwait(false))
                        deliveredUpdated++;
                }
                else if (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() < original.Ha!.NotAfterUnixMs)
                {
                    var contact = ResolvePendingRecipient(original);
                    if (contact is not null) await DeliverHaEnvelopeCoreAsync(contact, original.EnvelopeId, cancellationToken).ConfigureAwait(false);
                }
            }
            var priorCursor = _state.HaDeliveryPollCursor;
            _state.HaDeliveryPollCursor = pending[^1].EnvelopeId;
            try { await PersistCoreAsync(cancellationToken).ConfigureAwait(false); }
            catch { _state.HaDeliveryPollCursor = priorCursor; throw; }
        }
        RaiseStateChanged();
        return new(fetched, imported, duplicates, resultsSent, deliveredUpdated);
    }

    private void StageRejectedHaResultCore(HaEnvelopeBinding binding, string reason)
    {
        if (_state.RecipientResultOutbox.Any(item => item.SenderKeyId == binding.SenderKeyId &&
            item.RecipientKeyId == binding.RecipientKeyId && item.EnvelopeId == binding.EnvelopeId)) return;
        _state.RecipientResultOutbox.Add(new(binding.SenderKeyId, binding.RecipientKeyId, binding.EnvelopeId,
            binding.EnvelopeSha256, HaDeliveryState.Rejected, reason, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            Guid.NewGuid().ToString("N"), "1"));
    }

    private async Task RegisterHaRouteCoreAsync(CancellationToken cancellationToken)
    {
        var ticket = _p2p.Status?.Ticket ?? _state.CurrentP2pTicket ?? "";
        if (_haRegisteredRouteTicket == ticket &&
            _haRegisteredRouteRenewAfterUnixMs > DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) return;
        var identity = RequireIdentity();
        var server = RequireHaServerCore();
        var update = _native.CreateDeviceEndpointUpdate(identity.IdentityJson, _state.DeviceId, ticket, Guid.NewGuid().ToString("N"));
        var replicated = false;
        async Task Register(string version)
        {
            var response = await server.SendAsync("v2/devices/register", "register_route", new
            {
            owner_contact = EnvelopeHaProtocol.Element(_native.ContactFromIdentity(identity.IdentityJson)),
            endpoint = EnvelopeHaProtocol.Element(update.EndpointJson), expected_version = version,
            }, identity.IdentityJson, identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false);
            var reply = EnvelopeHaProtocol.Element(response);
            if (reply.GetProperty("protocol_version").GetInt32() != 2) throw new InvalidDataException("路由登记版本无效。");
            if (reply.GetProperty("status").GetString() == "replicated")
            {
                VerifyHaMutationResponse(response);
                replicated = true;
            }
            else if (reply.GetProperty("status").GetString() != "staged_single" ||
                !reply.TryGetProperty("guard_revision", out var guard) || guard.ValueKind != JsonValueKind.String ||
                HaSequence.Parse(guard.GetString()!) <= 0)
                throw new InvalidDataException("路由未获得有效登记结果。");
        }
        try { await Register("0").ConfigureAwait(false); }
        catch (EnvelopeHaServerException error) when (error.Code == "OBJECT_VERSION_CONFLICT")
        {
            var lookup = EnvelopeHaProtocol.Element(await server.SendAsync($"v2/routes/{Uri.EscapeDataString(identity.KeyId)}/{Uri.EscapeDataString(_state.DeviceId)}",
                "lookup_route", new { owner_key_id = identity.KeyId, device_id = _state.DeviceId }, identity.IdentityJson,
                identity.KeyId, Guid.NewGuid().ToString("N"), cancellationToken).ConfigureAwait(false));
            await Register(lookup.GetProperty("object_version").GetString()!).ConfigureAwait(false);
        }
        _haRegisteredRouteTicket = ticket;
        // A staged route only establishes current-leader authentication; retry
        // it soon and never present it as replicated storage or delivery proof.
        _haRegisteredRouteRenewAfterUnixMs = replicated
            ? EnvelopeHaProtocol.Element(update.EndpointJson).GetProperty("expires_at_unix_ms").GetInt64() - 60_000
            : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 30_000;
    }

    private void StageRecipientResultCore(string sender, string recipient, string envelopeId,
        string opaque, ChatMessageRecord message, string? mime)
    {
        var filePart = mime is FileManifestMime or FileChunkMime;
        var outcome = filePart && message.IsHidden ? HaDeliveryState.Deferred : HaDeliveryState.Delivered;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var priorDescriptor = _state.RecipientResultOutbox.FirstOrDefault(item => item.SenderKeyId == sender &&
            item.RecipientKeyId == recipient && item.EnvelopeId == envelopeId);
        _state.RecipientResultOutbox.RemoveAll(item => item.SenderKeyId == sender && item.RecipientKeyId == recipient && item.EnvelopeId == envelopeId);
        _state.RecipientResultOutbox.Add(new(sender, recipient, envelopeId, HaOutboundState.Hash(opaque),
            outcome, outcome == HaDeliveryState.Deferred ? "FILE_INCOMPLETE" : "", now,
            Guid.NewGuid().ToString("N"), priorDescriptor is null ? "1" :
                (HaSequence.Parse(priorDescriptor.ResultSequence) + 1).ToString(CultureInfo.InvariantCulture), LogicalMessageId: message.LogicalMessageId));
        if (filePart && outcome == HaDeliveryState.Delivered && message.LogicalMessageId is not null)
        {
            for (var index = 0; index < _state.RecipientResultOutbox.Count; index++)
            {
                var prior = _state.RecipientResultOutbox[index];
                if (prior.SenderKeyId != sender || prior.RecipientKeyId != recipient ||
                    prior.LogicalMessageId != message.LogicalMessageId || prior.Outcome != HaDeliveryState.Deferred)
                    continue;
                _state.RecipientResultOutbox[index] = prior with
                {
                    Outcome = HaDeliveryState.Delivered, ReasonCode = "", ReceivedAtUnixMs = now,
                    ResultId = Guid.NewGuid().ToString("N"),
                    ResultSequence = (HaSequence.Parse(prior.ResultSequence) + 1).ToString(CultureInfo.InvariantCulture),
                    SignedResultJson = null, Replicated = false,
                };
            }
        }
    }

    // Called only after the business state and descriptor have been persisted.
    // A signing or second-save failure leaves the descriptor available for retry.
    private async Task<string?> SignRecipientResultCoreAsync(string envelopeId, CancellationToken cancellationToken, string? senderKeyId = null)
    {
        var identity = RequireIdentity();
        var index = _state.RecipientResultOutbox.FindIndex(item =>
            item.RecipientKeyId == identity.KeyId && item.EnvelopeId == envelopeId &&
            (senderKeyId is null || item.SenderKeyId == senderKeyId));
        if (index < 0) return null; // Legacy locally stored message; do not invent historical proof.
        var descriptor = _state.RecipientResultOutbox[index];
        if (descriptor.SignedResultJson is not null) return descriptor.SignedResultJson;
        var result = new HaRecipientResult(2, descriptor.SenderKeyId, descriptor.RecipientKeyId,
            descriptor.EnvelopeId, descriptor.EnvelopeSha256, descriptor.Outcome.ToString().ToLowerInvariant(),
            descriptor.ReasonCode ?? "", EnvelopeHaProtocol.Decimal(descriptor.ReceivedAtUnixMs),
            descriptor.ResultId, descriptor.ResultSequence, "");
        var signed = new EnvelopeHaProtocol(_native).SignResult(identity.IdentityJson, result);
        _state.RecipientResultOutbox[index] = descriptor with { SignedResultJson = signed };
        try { await PersistCoreAsync(cancellationToken).ConfigureAwait(false); }
        catch { _state.RecipientResultOutbox[index] = descriptor; throw; }
        return signed;
    }

    private async Task<bool> ApplyRecipientResultCoreAsync(string envelopeId, string resultJson,
        string contactJson, CancellationToken cancellationToken)
    {
        var index = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == envelopeId);
        if (index < 0 || _state.PendingEnvelopes[index].Ha is null) return false;
        var pending = _state.PendingEnvelopes[index];
        var ha = pending.Ha!;
        var result = new EnvelopeHaProtocol(_native).VerifyResult(resultJson, contactJson, EnvelopeHaProtocol.Binding(pending));
        var next = result.Outcome switch
        {
            "delivered" => HaDeliveryState.Delivered,
            "rejected" => HaDeliveryState.Rejected,
            "deferred" => HaDeliveryState.Deferred,
            _ => throw new InvalidDataException("未知收件结果。"),
        };
        if (ha.RecipientResultJson is { } priorJson)
        {
            var prior = EnvelopeHaProtocol.Deserialize<HaRecipientResult>(priorJson);
            if (result.ResultId == prior.ResultId && result != prior)
                throw new InvalidDataException("相同结果 ID 不允许替换内容或序号。");
            var order = HaSequence.Parse(result.ResultSequence).CompareTo(HaSequence.Parse(prior.ResultSequence));
            if (order < 0) return ha.DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected;
            if (order == 0)
            {
                if (result != prior) throw new InvalidDataException("同一结果序号发生内容冲突。");
                return ha.DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected;
            }
            if (ha.DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected)
                throw new InvalidDataException("收件终态不能被后续结果替换。");
        }
        if (ha.DeliveryState == HaDeliveryState.Expired &&
            (next != HaDeliveryState.Delivered || HaSequence.Parse(result.ReceivedAt) >= ha.NotAfterUnixMs))
            throw new InvalidDataException("到期后的结果不允许改写正式到期状态。");
        var messagesBefore = _state.Messages.ToArray();
        _state.PendingEnvelopes[index] = pending with
        {
            Ha = ha with { DeliveryState = next, RecipientResultJson = resultJson },
            DeliveryState = next == HaDeliveryState.Delivered ? DeliveryState.Delivered :
                next == HaDeliveryState.Rejected ? DeliveryState.Failed : pending.DeliveryState,
            LastError = next == HaDeliveryState.Rejected ? result.ReasonCode : null,
            EnvelopeBase64 = next is HaDeliveryState.Delivered or HaDeliveryState.Rejected ? string.Empty : pending.EnvelopeBase64,
        };
        RefreshLogicalMessageDeliveryCore(pending.LogicalMessageId ?? envelopeId);
        var children = _state.PendingEnvelopes.Where(item =>
            (item.LogicalMessageId ?? item.EnvelopeId) == (pending.LogicalMessageId ?? envelopeId)).ToArray();
        if (children.Length > 0 && children.Select(item => item.ChildIndex).Distinct().Count() == children.Max(item => item.ChildCount) &&
            children.All(item => item.Ha is { DeliveryState: HaDeliveryState.Delivered, RecipientResultJson: not null }))
        {
            for (var messageIndex = 0; messageIndex < _state.Messages.Count; messageIndex++)
            {
                var message = _state.Messages[messageIndex];
                if ((message.LogicalMessageId ?? message.EnvelopeId) == (pending.LogicalMessageId ?? envelopeId))
                    _state.Messages[messageIndex] = message with
                    {
                        VerifiedRecipientResultJson = JsonSerializer.Serialize(children.Select(item => item.Ha!.RecipientResultJson)),
                    };
            }
        }
        try { await PersistCoreAsync(cancellationToken).ConfigureAwait(false); }
        catch
        {
            _state.PendingEnvelopes[index] = pending;
            _state.Messages.Clear(); _state.Messages.AddRange(messagesBefore);
            throw;
        }
        return next is HaDeliveryState.Delivered or HaDeliveryState.Rejected;
    }
}
