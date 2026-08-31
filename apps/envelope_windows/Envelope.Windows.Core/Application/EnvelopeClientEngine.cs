using System.Buffers;
using System.Security.Cryptography;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Core.Application;

public sealed record IdentityCreationResult(IdentitySummary Identity, RecoveryPhrase RecoveryPhrase);
public sealed record DeliveryResult(string Route, DeliveryState State, string Detail);
public sealed record MailboxSyncResult(
    int Pulled,
    int Imported,
    int Duplicates,
    int Acknowledged,
    int DeliveredUpdated,
    int Quarantined = 0);
public sealed record EnvelopeImportResult(ChatMessageRecord Message, bool Duplicate);

public sealed partial class EnvelopeClientEngine : IAsyncDisposable
{
    private sealed record OutboundWorkItem(
        StoredContact Contact,
        string EnvelopeId,
        string EnvelopeBase64,
        string LogicalMessageId,
        int ChildIndex,
        int ChildCount);

    private sealed class EnvelopeCiphertextRejectedException(
        string message,
        Exception? innerException = null) : CryptographicException(message, innerException);

    public const string ClientStateSlot = "windows-client-state";
    public const string GroupControlMime = "application/vnd.westwardsoft.envelope.group-control+json";
    public const string ContactControlMime = "application/vnd.westwardsoft.envelope.contact-control+json";
    public const string FileManifestMime = "application/vnd.westwardsoft.envelope.file-manifest+json";
    public const string FileChunkMime = "application/vnd.westwardsoft.envelope.file-chunk+json";
    public const string OfflineFileManifestMime = "application/vnd.westwardsoft.envelope.offline-file-manifest+json";
    public const string OfflineFileChunkMime = "application/vnd.westwardsoft.envelope.offline-file-chunk";
    public const string OfflineStreamMagic = "ENVELOPE_STREAM_V1";
    public const string GroupEventSignatureContext = "envelope/v1/group/event";
    public const string GroupConsensusEndorsementContext = "envelope/v1/group/consensus-endorsement";
    internal const int MaximumDeferredMailboxEnvelopeCount = 256;
    internal const int MaximumDeferredMailboxEnvelopeBytes = 12 * 1024 * 1024;
    internal const long MaximumDeferredMailboxTotalBytes = 64L * 1024 * 1024;
    internal static readonly TimeSpan DeferredMailboxRetention = TimeSpan.FromDays(7);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
    };

    private readonly IEnvelopeNativeClient _native;
    private readonly IClientStateStore _stateStore;
    private readonly EnvelopePaths _paths;
    private readonly DiagnosticLogService _diagnostics;
    private readonly EnvelopeP2pTransport _p2p;
    private readonly EnvelopeP2pCooldownTracker _p2pCooldown = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WindowsClientState _state = new();
    private bool _initialized;
    private bool _disposed;

    public EnvelopeClientEngine(
        IEnvelopeNativeClient native,
        IClientStateStore stateStore,
        EnvelopePaths paths,
        DiagnosticLogService diagnostics,
        EnvelopeP2pTransport? p2p = null)
    {
        _native = native;
        _stateStore = stateStore;
        _paths = paths;
        _diagnostics = diagnostics;
        _p2p = p2p ?? new EnvelopeP2pTransport();
    }

    public event EventHandler? StateChanged;

    public WindowsClientState State => _state;
    public bool IsInitialized => _initialized;
    public bool HasIdentity => _state.Identity is not null;
    public EnvelopeP2pStatus? P2pStatus => _p2p.Status;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_initialized) return;
            _paths.EnsureCreated();
            _state = await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            _state.Validate();
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (RecoverManagedPlaintextTransitionsCore(cancellationToken) +
                PruneMailboxQuarantineCore(now) +
                PruneDeferredMailboxCore(now) +
                PruneExpiredInboundFileCacheCore(now) > 0)
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            await ResumeInboundTransferCleanupCoreAsync(cancellationToken).ConfigureAwait(false);
            _initialized = true;
        }
        finally
        {
            _gate.Release();
        }

        if (_state.Identity is not null)
        {
            await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        }
        await LogAsync("info", "windows_client_initialized", new Dictionary<string, object?>
        {
            ["has_identity"] = _state.Identity is not null,
            ["contact_count"] = _state.Contacts.Count,
            ["message_count"] = _state.Messages.Count,
        }, cancellationToken).ConfigureAwait(false);
        RaiseStateChanged();
    }

    public async Task<IdentityCreationResult> CreateIdentityAsync(
        string displayName,
        CancellationToken cancellationToken = default)
    {
        var phrase = _native.GenerateRecoveryPhrase();
        var summary = _native.RecoverIdentity(NormalizeDisplayName(displayName), phrase);
        await ReplaceIdentityAsync(summary, cancellationToken).ConfigureAwait(false);
        return new IdentityCreationResult(summary, phrase);
    }

    public async Task<IdentitySummary> RestoreIdentityAsync(
        string displayName,
        string recoveryPhrase,
        bool replaceExisting,
        CancellationToken cancellationToken = default)
    {
        var phrase = RecoveryPhrase.Parse(recoveryPhrase);
        var summary = _native.RecoverIdentity(NormalizeDisplayName(displayName), phrase);
        if (_state.Identity is not null && !replaceExisting)
        {
            throw new InvalidOperationException("当前已有身份；恢复将替换联系人、消息、群组和缓存，必须明确确认。");
        }
        await ReplaceIdentityAsync(summary, cancellationToken).ConfigureAwait(false);
        return summary;
    }

    private async Task ReplaceIdentityAsync(IdentitySummary summary, CancellationToken cancellationToken)
    {
        EnsureInitialized();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var previousState = CloneClientStateCore(_state);
            ManagedPlaintextQuarantine? quarantine = null;
            try
            {
                quarantine = StageManagedIdentityPlaintextCore(cancellationToken);
                ArchiveCurrentReceivedCountersCore();
                var sameIdentity = string.Equals(
                    _state.Identity?.KeyId,
                    summary.KeyId,
                    StringComparison.Ordinal);
                var preservedNextCounter = _state.NextMessageCounter;
                if (!sameIdentity && _state.CounterNamespace != 0 &&
                    !_state.RetiredCounterNamespaces.Contains(_state.CounterNamespace))
                    _state.RetiredCounterNamespaces.Add(_state.CounterNamespace);
                var targetCounterNamespace = sameIdentity
                    ? _state.CounterNamespace
                    : WindowsClientState.CreateCounterNamespace(
                        _state.RetiredCounterNamespaces.ToHashSet());
                var preservedReceivedCounters = ArchivedReceivedCountersForCore(summary.KeyId);
                var preservedReplayArchive = _state.ReceivedCounterArchive.ToArray();
                var preservedPending = sameIdentity
                    ? _state.PendingEnvelopes.ToArray()
                    : Array.Empty<PendingEnvelopeRecord>();
                var preservedQuarantine = sameIdentity
                    ? _state.MailboxQuarantine.ToArray()
                    : Array.Empty<MailboxQuarantineRecord>();
                var preservedDeferredMailbox = sameIdentity
                    ? _state.DeferredMailboxEnvelopes.ToArray()
                    : Array.Empty<DeferredMailboxEnvelopeRecord>();
                _state.Identity = SecureIdentityRecord.FromSummary(summary);
                _state.Contacts.Clear();
                _state.Messages.Clear();
                _state.Groups.Clear();
                _state.GroupMembers.Clear();
                _state.GroupEvents.Clear();
                _state.PendingEnvelopes.Clear();
                _state.PendingEnvelopes.AddRange(preservedPending);
                _state.SealedEnvelopes.Clear();
                _state.ReceivedCounters.Clear();
                _state.ReceivedCounters.AddRange(preservedReceivedCounters);
                _state.ReceivedCounterArchive.Clear();
                _state.ReceivedCounterArchive.AddRange(preservedReplayArchive);
                _state.InboundFileTransfers.Clear();
                _state.InboundFileChunks.Clear();
                _state.MailboxQuarantine.Clear();
                _state.MailboxQuarantine.AddRange(preservedQuarantine);
                _state.DeferredMailboxEnvelopes.Clear();
                _state.DeferredMailboxEnvelopes.AddRange(preservedDeferredMailbox);
                _state.CounterNamespace = targetCounterNamespace;
                _state.NextMessageCounter = sameIdentity
                    ? preservedNextCounter
                    : WindowsClientState.ComposeCounter(1, targetCounterNamespace);
                _state.ManagedPlaintextCleanupId = quarantine?.TransitionId;
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                _state = previousState;
                if (quarantine is not null)
                {
                    try
                    {
                        RollbackManagedPlaintextCore(quarantine, CancellationToken.None);
                    }
                    catch (Exception rollbackError)
                    {
                        throw new IOException(
                            "身份切换状态提交失败，且托管明文 rollback 未能完整恢复。",
                            new AggregateException(error, rollbackError));
                    }
                }
                throw;
            }
            await CommitManagedPlaintextTransitionCoreAsync(quarantine, CancellationToken.None)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        RaiseStateChanged();
    }

    public string ExportOwnContactJson()
    {
        var identity = RequireIdentity();
        return _native.ContactFromIdentity(identity.IdentityJson);
    }

    public async Task<StoredContact> ImportContactAsync(
        string contactOrIntroJson,
        string? remark = null,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        ContactSummary summary;
        string? deviceId = null;
        string? p2pTicket = null;
        try
        {
            summary = _native.ParseContact(contactOrIntroJson);
        }
        catch (EnvelopeNativeException)
        {
            var bundle = _native.VerifyIntroBundle(contactOrIntroJson);
            summary = _native.ParseContact(bundle.ContactJson);
            deviceId = bundle.DeviceId;
            p2pTicket = bundle.P2pTicket;
        }

        if (summary.KeyId == RequireIdentity().KeyId)
        {
            throw new InvalidOperationException("不能把本机身份添加为联系人。");
        }

        var contact = new StoredContact(
            summary.KeyId,
            summary.DisplayName,
            summary.ContactJson,
            string.IsNullOrWhiteSpace(remark) ? null : remark.Trim(),
            deviceId,
            p2pTicket,
            string.IsNullOrWhiteSpace(p2pTicket) ? null : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _state.Contacts.RemoveAll(item => item.KeyId == contact.KeyId);
            _state.Contacts.Add(contact);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        RaiseStateChanged();
        return contact;
    }

    public async Task UpdateContactRemarkAsync(
        string keyId,
        string? remark,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var contact = _state.RequireContact(keyId);
            _state.Contacts.Remove(contact);
            _state.Contacts.Add(contact with { Remark = string.IsNullOrWhiteSpace(remark) ? null : remark.Trim() });
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
    }

    public async Task DeleteContactAsync(string keyId, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var contact = _state.RequireContact(keyId);
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var control = JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["type"] = "contact_deleted",
                ["event_id"] = $"cct-{Guid.NewGuid():N}",
                ["actor_key_id"] = identity.KeyId,
                ["target_key_id"] = contact.KeyId,
                ["created_at_unix_ms"] = now,
            }, Json);
            var messageCounter = await ReserveMessageCounterCoreAsync(cancellationToken).ConfigureAwait(false);
            var outbound = _native.EncryptOpaqueFile(
                identity.IdentityJson,
                contact.ContactJson,
                "contact-control.json",
                ContactControlMime,
                Encoding.UTF8.GetBytes(control),
                messageCounter);
            await DeliverEnvelopeCoreAsync(contact, outbound.EnvelopeId, outbound.EnvelopeBase64, cancellationToken)
                .ConfigureAwait(false);
            _state.Contacts.RemoveAll(item => item.KeyId == keyId);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
    }

    public async Task<ChatMessageRecord> SendTextAsync(
        string recipientKeyId,
        string text,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("消息不能为空。", nameof(text));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        ChatMessageRecord message;
        try
        {
            var identity = RequireIdentity();
            var contact = _state.RequireContact(recipientKeyId);
            var messageCounter = await ReserveMessageCounterCoreAsync(cancellationToken).ConfigureAwait(false);
            var outbound = _native.EncryptOpaqueText(
                identity.IdentityJson,
                contact.ContactJson,
                text.Trim(),
                messageCounter);
            var stagedMessage = new ChatMessageRecord(
                outbound.EnvelopeId,
                contact.KeyId,
                MessageDirection.Outgoing,
                contact.KeyId,
                contact.DisplayLabel,
                checked((long)outbound.CreatedAtUnixMs),
                outbound.MessageCounter,
                outbound.Text,
                outbound.EnvelopeBase64,
                DeliveryState.Pending,
                DeliveryDetail: "已持久化到 outbox，等待投递。",
                LogicalMessageId: outbound.EnvelopeId);
            await StageOutboundBatchCoreAsync(
                    [new OutboundWorkItem(
                        contact,
                        outbound.EnvelopeId,
                        outbound.EnvelopeBase64,
                        outbound.EnvelopeId,
                        0,
                        1)],
                    cancellationToken,
                    stagedMessage)
                .ConfigureAwait(false);
            var delivery = await DeliverEnvelopeCoreAsync(
                contact,
                outbound.EnvelopeId,
                outbound.EnvelopeBase64,
                cancellationToken,
                outbound.EnvelopeId,
                0,
                1).ConfigureAwait(false);
            message = stagedMessage with { DeliveryState = delivery.State, DeliveryDetail = delivery.Detail };
            _state.Messages.RemoveAll(item => item.EnvelopeId == message.EnvelopeId);
            _state.Messages.Add(message);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
        return message;
    }

    public async Task<MailboxSyncResult> SynchronizeAsync(CancellationToken cancellationToken = default)
    {
        await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var syncStartedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (PruneMailboxQuarantineCore(syncStartedAt) +
                PruneDeferredMailboxCore(syncStartedAt) +
                PruneExpiredInboundFileCacheCore(syncStartedAt) > 0)
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            using var server = CreateServerClient();
            await RegisterRouteCoreAsync(server, cancellationToken).ConfigureAwait(false);
            var pullSummary = _native.CreateMailboxPullRequest(identity.IdentityJson, 50);
            var pullRequest = DeserializeWire<MailboxPullRequestDto>(pullSummary.RequestJson);
            var response = await server.PullMailboxAsync(identity.KeyId, pullRequest, cancellationToken)
                .ConfigureAwait(false);
            var acknowledgedIds = new List<string>();
            var imported = 0;
            var duplicates = 0;
            var quarantined = 0;
            foreach (var item in response.Envelopes)
            {
                var existingQuarantine = _state.MailboxQuarantine.FirstOrDefault(record =>
                    record.EnvelopeId == item.EnvelopeId);
                if (existingQuarantine is not null)
                {
                    acknowledgedIds.Add(item.EnvelopeId);
                    continue;
                }
                if (_state.DeferredMailboxEnvelopes.Any(record => record.EnvelopeId == item.EnvelopeId))
                {
                    // A previous ACK may have been lost. The authenticated raw
                    // item is already durable and will be retried below.
                    acknowledgedIds.Add(item.EnvelopeId);
                    continue;
                }
                if (KnownSenderCandidates(item.SenderKeyId).Count == 0)
                {
                    AddMailboxQuarantineCore(
                        item.EnvelopeId,
                        item.SenderKeyId,
                        "unknown_sender",
                        "mailbox sender_key_id 不在联系人或群成员目录中。",
                        item.EnvelopeBase64,
                        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    acknowledgedIds.Add(item.EnvelopeId);
                    quarantined++;
                    continue;
                }
                try
                {
                    var result = await ImportEnvelopeAndPersistCoreAsync(
                        item.EnvelopeBase64,
                        item.SenderKeyId,
                        cancellationToken).ConfigureAwait(false);
                    acknowledgedIds.Add(item.EnvelopeId);
                    if (result.Duplicate) duplicates++; else imported++;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception error)
                {
                    var permanent = TryClassifyPermanentMailboxPoison(error, out var classification);
                    if (!permanent && classification.ReasonCode == "missing_prerequisite")
                    {
                        var stagedAsRaw = StageDeferredMailboxEnvelopeCore(
                            item.EnvelopeId,
                            item.SenderKeyId,
                            item.EnvelopeBase64,
                            classification,
                            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                        acknowledgedIds.Add(item.EnvelopeId);
                        if (!stagedAsRaw) quarantined++;
                    }
                    else if (permanent)
                    {
                        var quarantinedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                        AddMailboxQuarantineCore(
                            item.EnvelopeId,
                            item.SenderKeyId,
                            classification.ReasonCode,
                            classification.Detail,
                            item.EnvelopeBase64,
                            quarantinedAt);
                        acknowledgedIds.Add(item.EnvelopeId);
                        quarantined++;
                    }
                    await LogAsync("warn", permanent ? "mailbox_item_quarantined" : "mailbox_item_deferred", new Dictionary<string, object?>
                    {
                        ["envelope_id"] = item.EnvelopeId,
                        ["sender_key_id"] = item.SenderKeyId,
                        ["reason_code"] = classification.ReasonCode,
                        ["error"] = classification.Detail,
                    }, cancellationToken).ConfigureAwait(false);
                }
            }

            // A predecessor may have appeared later in this same mailbox page.
            // Retry after the whole page so causal events can settle before ACK.
            var deferredResult = await RetryDeferredMailboxCoreAsync(cancellationToken).ConfigureAwait(false);
            imported += deferredResult.Imported;
            duplicates += deferredResult.Duplicates;
            quarantined += deferredResult.Quarantined;

            // Messages, replay counters, and quarantine tombstones must be
            // durable before the server is allowed to delete mailbox items.
            if (acknowledgedIds.Count > 0)
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);

            var acknowledged = 0;
            if (acknowledgedIds.Count > 0)
            {
                var ackSummary = _native.CreateMailboxAckRequest(identity.IdentityJson, acknowledgedIds);
                var ackRequest = DeserializeWire<MailboxAckRequestDto>(ackSummary.RequestJson);
                var ack = await server.AcknowledgeMailboxAsync(identity.KeyId, ackRequest, cancellationToken)
                    .ConfigureAwait(false);
                acknowledged = checked((int)ack.DeletedCount);
                var acknowledgedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                for (var index = 0; index < _state.MailboxQuarantine.Count; index++)
                {
                    if (acknowledgedIds.Contains(_state.MailboxQuarantine[index].EnvelopeId, StringComparer.Ordinal))
                        _state.MailboxQuarantine[index] = _state.MailboxQuarantine[index] with
                        {
                            AcknowledgedAtUnixMs = acknowledgedAt,
                        };
                }
            }

            var pendingIds = _state.PendingEnvelopes
                .Where(item => item.DeliveryState == DeliveryState.ServerMailbox)
                .Select(item => item.EnvelopeId)
                .Distinct(StringComparer.Ordinal)
                .Take(100)
                .ToArray();
            var deliveredUpdated = 0;
            if (pendingIds.Length > 0)
            {
                var statusSummary = _native.CreateDeliveryStatusRequest(identity.IdentityJson, pendingIds);
                var statusRequest = DeserializeWire<DeliveryStatusRequestDto>(statusSummary.RequestJson);
                var statuses = await server.GetDeliveryStatusAsync(identity.KeyId, statusRequest, cancellationToken)
                    .ConfigureAwait(false);
                foreach (var status in statuses.Items.Where(item => item.IsDelivered))
                {
                    var index = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == status.EnvelopeId);
                    if (index < 0) continue;
                    var child = _state.PendingEnvelopes[index];
                    _state.PendingEnvelopes[index] = child with
                    {
                        DeliveryState = DeliveryState.Delivered,
                        LastError = null,
                        NextAttemptAtUnixMs = null,
                    };
                    RefreshLogicalMessageDeliveryCore(child.LogicalMessageId ?? child.EnvelopeId, "服务器已确认投递。");
                    deliveredUpdated++;
                }
            }
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return new MailboxSyncResult(
                response.Envelopes.Count,
                imported,
                duplicates,
                acknowledged,
                deliveredUpdated,
                quarantined);
        }
        finally { _gate.Release(); }
    }

    private static bool TryClassifyPermanentMailboxPoison(
        Exception error,
        out (string ReasonCode, string Detail) classification)
    {
        if (error is EnvelopeCiphertextRejectedException)
        {
            classification = ("authentication_failed", SanitizeQuarantineDetail(error.Message));
            return true;
        }
        var cause = error;
        while (cause.InnerException is not null && cause is CryptographicException)
            cause = cause.InnerException;
        var detail = SanitizeQuarantineDetail(error.Message);
        if (cause is IOException or UnauthorizedAccessException ||
            cause.GetType().Name.Contains("SecureStore", StringComparison.OrdinalIgnoreCase))
        {
            classification = ("transient_local_failure", detail);
            return false;
        }
        if (cause is CryptographicException &&
            (cause.Message.Contains("counter", StringComparison.OrdinalIgnoreCase) ||
             cause.Message.Contains("计数器", StringComparison.Ordinal) ||
             cause.Message.Contains("重放", StringComparison.Ordinal)))
        {
            classification = ("replay", detail);
            return true;
        }
        if (cause is JsonException)
        {
            classification = ("invalid_json", detail);
            return true;
        }
        if (cause is InvalidDataException)
        {
            var prerequisiteMissing = cause.Message.Contains("创建本地群组", StringComparison.Ordinal) ||
                                      cause.Message.Contains("所属群组不可用", StringComparison.Ordinal) ||
                                      cause.Message.Contains("不是已知群成员", StringComparison.Ordinal) ||
                                      cause.Message.Contains("没有找到群组", StringComparison.Ordinal) ||
                                      cause.Message.Contains("缺少可证明的前置历史快照", StringComparison.Ordinal) ||
                                      cause.Message.Contains("共识背书候选人状态无效", StringComparison.Ordinal) ||
                                      IsFutureGroupEpoch(cause.Message);
            classification = prerequisiteMissing
                ? ("missing_prerequisite", detail)
                : ("invalid_payload", detail);
            return !prerequisiteMissing;
        }
        // Native authentication may become possible after the matching contact
        // or group invitation arrives. Unknown failures are likewise deferred;
        // only explicit, deterministic poison is acknowledged.
        classification = cause is EnvelopeNativeException
            ? ("contact_or_key_unavailable", detail)
            : ("transient_processing_failure", detail);
        return false;
    }

    private static bool IsFutureGroupEpoch(string message)
    {
        const string expectedMarker = "epoch 必须为 ";
        const string actualMarker = "，实际为 ";
        var expectedStart = message.IndexOf(expectedMarker, StringComparison.Ordinal);
        if (expectedStart < 0) return false;
        expectedStart += expectedMarker.Length;
        var actualStart = message.IndexOf(actualMarker, expectedStart, StringComparison.Ordinal);
        if (actualStart < 0 ||
            !long.TryParse(message.AsSpan(expectedStart, actualStart - expectedStart), out var expected))
            return false;
        actualStart += actualMarker.Length;
        var actualEnd = message.IndexOf('。', actualStart);
        if (actualEnd < 0) actualEnd = message.Length;
        return long.TryParse(message.AsSpan(actualStart, actualEnd - actualStart), out var actual) &&
               actual > expected;
    }

    private static string SanitizeQuarantineDetail(string detail)
    {
        const int maximumLength = 512;
        var normalized = detail.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return normalized.Length <= maximumLength ? normalized : normalized[..maximumLength];
    }

    private int PruneMailboxQuarantineCore(long nowUnixMs)
    {
        var originalCount = _state.MailboxQuarantine.Count;
        var cutoff = nowUnixMs - (long)TimeSpan.FromDays(7).TotalMilliseconds;
        _state.MailboxQuarantine.RemoveAll(item => item.QuarantinedAtUnixMs < cutoff);
        if (_state.MailboxQuarantine.Count > 1_000)
        {
            var keep = _state.MailboxQuarantine
                .OrderByDescending(item => item.QuarantinedAtUnixMs)
                .ThenByDescending(item => item.EnvelopeId, StringComparer.Ordinal)
                .Take(1_000)
                .ToArray();
            _state.MailboxQuarantine.Clear();
            _state.MailboxQuarantine.AddRange(keep);
        }
        return originalCount - _state.MailboxQuarantine.Count;
    }

    private void AddMailboxQuarantineCore(
        string envelopeId,
        string senderKeyId,
        string reasonCode,
        string detail,
        string envelopeBase64,
        long quarantinedAtUnixMs,
        bool alreadyAcknowledged = false)
    {
        var size = Encoding.UTF8.GetByteCount(envelopeBase64);
        _state.MailboxQuarantine.RemoveAll(item => item.EnvelopeId == envelopeId);
        _state.MailboxQuarantine.Add(new MailboxQuarantineRecord(
            envelopeId,
            senderKeyId,
            reasonCode,
            SanitizeQuarantineDetail(detail),
            Sha256Utf8(envelopeBase64),
            size,
            quarantinedAtUnixMs,
            alreadyAcknowledged ? quarantinedAtUnixMs : null));
        PruneMailboxQuarantineCore(quarantinedAtUnixMs);
    }

    private bool StageDeferredMailboxEnvelopeCore(
        string envelopeId,
        string senderKeyId,
        string envelopeBase64,
        (string ReasonCode, string Detail) classification,
        long nowUnixMs)
    {
        var size = Encoding.UTF8.GetByteCount(envelopeBase64);
        if (size <= 0 || size > MaximumDeferredMailboxEnvelopeBytes)
        {
            AddMailboxQuarantineCore(
                envelopeId,
                senderKeyId,
                "deferred_payload_too_large",
                $"需要因果前置的 mailbox 信封为 {size} bytes，超过 {MaximumDeferredMailboxEnvelopeBytes} bytes 上限。",
                envelopeBase64,
                nowUnixMs);
            return false;
        }

        var existing = _state.DeferredMailboxEnvelopes.FirstOrDefault(item => item.EnvelopeId == envelopeId);
        var record = existing is null
            ? new DeferredMailboxEnvelopeRecord(
                envelopeId,
                senderKeyId,
                envelopeBase64,
                classification.ReasonCode,
                SanitizeQuarantineDetail(classification.Detail),
                size,
                nowUnixMs,
                nowUnixMs)
            : existing with
            {
                SenderKeyId = senderKeyId,
                EnvelopeBase64 = envelopeBase64,
                ReasonCode = classification.ReasonCode,
                ReasonDetail = SanitizeQuarantineDetail(classification.Detail),
                EnvelopeSizeBytes = size,
                LastAttemptAtUnixMs = nowUnixMs,
                AttemptCount = existing.AttemptCount == int.MaxValue
                    ? int.MaxValue
                    : existing.AttemptCount + 1,
            };
        _state.DeferredMailboxEnvelopes.RemoveAll(item => item.EnvelopeId == envelopeId);
        _state.DeferredMailboxEnvelopes.Add(record);
        PruneDeferredMailboxCore(nowUnixMs);
        return _state.DeferredMailboxEnvelopes.Any(item => item.EnvelopeId == envelopeId);
    }

    private int PruneDeferredMailboxCore(long nowUnixMs)
    {
        var removed = 0;
        var cutoff = nowUnixMs - (long)DeferredMailboxRetention.TotalMilliseconds;
        foreach (var record in _state.DeferredMailboxEnvelopes
                     .OrderBy(item => item.FirstDeferredAtUnixMs)
                     .ThenBy(item => item.EnvelopeId, StringComparer.Ordinal)
                     .ToArray())
        {
            var invalid = string.IsNullOrWhiteSpace(record.EnvelopeId) ||
                          string.IsNullOrWhiteSpace(record.SenderKeyId) ||
                          string.IsNullOrWhiteSpace(record.EnvelopeBase64) ||
                          record.EnvelopeSizeBytes <= 0 ||
                          record.EnvelopeSizeBytes > MaximumDeferredMailboxEnvelopeBytes;
            var expired = record.FirstDeferredAtUnixMs < cutoff;
            if (!invalid && !expired) continue;
            _state.DeferredMailboxEnvelopes.Remove(record);
            AddMailboxQuarantineCore(
                record.EnvelopeId,
                record.SenderKeyId,
                invalid ? "deferred_metadata_invalid" : "deferred_expired",
                invalid
                    ? "持久化 deferred mailbox metadata 无效，已移除 raw body。"
                    : "等待群组因果前置超过 7 天，已移除 raw body。",
                record.EnvelopeBase64,
                nowUnixMs,
                alreadyAcknowledged: true);
            removed++;
        }

        while (_state.DeferredMailboxEnvelopes.Count > MaximumDeferredMailboxEnvelopeCount ||
               _state.DeferredMailboxEnvelopes.Sum(item => (long)Math.Max(0, item.EnvelopeSizeBytes)) >
               MaximumDeferredMailboxTotalBytes)
        {
            var oldest = _state.DeferredMailboxEnvelopes
                .OrderBy(item => item.FirstDeferredAtUnixMs)
                .ThenBy(item => item.EnvelopeId, StringComparer.Ordinal)
                .First();
            _state.DeferredMailboxEnvelopes.Remove(oldest);
            AddMailboxQuarantineCore(
                oldest.EnvelopeId,
                oldest.SenderKeyId,
                "deferred_capacity_evicted",
                "deferred mailbox raw queue 达到容量上限，最旧项目已仅保留审计 metadata。",
                oldest.EnvelopeBase64,
                nowUnixMs,
                alreadyAcknowledged: true);
            removed++;
        }
        return removed;
    }

    private async Task<(int Imported, int Duplicates, int Quarantined)> RetryDeferredMailboxCoreAsync(
        CancellationToken cancellationToken)
    {
        var imported = 0;
        var duplicates = 0;
        var quarantined = 0;
        var changed = PruneDeferredMailboxCore(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) > 0;
        foreach (var record in _state.DeferredMailboxEnvelopes
                     .OrderBy(item => item.FirstDeferredAtUnixMs)
                     .ThenBy(item => item.EnvelopeId, StringComparer.Ordinal)
                     .ToArray())
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var result = await ImportEnvelopeAndPersistCoreAsync(
                    record.EnvelopeBase64,
                    record.SenderKeyId,
                    cancellationToken).ConfigureAwait(false);
                _state.DeferredMailboxEnvelopes.RemoveAll(item => item.EnvelopeId == record.EnvelopeId);
                if (result.Duplicate) duplicates++; else imported++;
                changed = true;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception error)
            {
                var permanent = TryClassifyPermanentMailboxPoison(error, out var classification);
                if (permanent)
                {
                    _state.DeferredMailboxEnvelopes.RemoveAll(item => item.EnvelopeId == record.EnvelopeId);
                    AddMailboxQuarantineCore(
                        record.EnvelopeId,
                        record.SenderKeyId,
                        classification.ReasonCode,
                        classification.Detail,
                        record.EnvelopeBase64,
                        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                        alreadyAcknowledged: true);
                    quarantined++;
                }
                else
                {
                    var index = _state.DeferredMailboxEnvelopes.FindIndex(item =>
                        item.EnvelopeId == record.EnvelopeId);
                    if (index >= 0)
                        _state.DeferredMailboxEnvelopes[index] = record with
                        {
                            ReasonCode = classification.ReasonCode,
                            ReasonDetail = SanitizeQuarantineDetail(classification.Detail),
                            LastAttemptAtUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                            AttemptCount = record.AttemptCount == int.MaxValue
                                ? int.MaxValue
                                : record.AttemptCount + 1,
                        };
                }
                changed = true;
            }
        }
        if (changed) await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        return (imported, duplicates, quarantined);
    }

    private static string Sha256Utf8(string value)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = ArrayPool<byte>.Shared.Rent(12 * 1024);
        try
        {
            const int characterBlock = 4 * 1024;
            for (var offset = 0; offset < value.Length; offset += characterBlock)
            {
                var length = Math.Min(characterBlock, value.Length - offset);
                var written = Encoding.UTF8.GetBytes(value.AsSpan(offset, length), buffer);
                hash.AppendData(buffer.AsSpan(0, written));
            }
            return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
        }
    }

    public async Task<EnvelopeImportResult> ImportEnvelopeAsync(
        string envelopeBase64,
        string? senderKeyId = null,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var result = await ImportEnvelopeAndPersistCoreAsync(
                    envelopeBase64,
                    senderKeyId,
                    cancellationToken)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return result;
        }
        finally { _gate.Release(); }
    }

    private async Task<EnvelopeImportResult> ImportEnvelopeCoreAsync(
        string envelopeBase64,
        string? senderKeyId,
        CancellationToken cancellationToken)
    {
        var normalized = envelopeBase64.Trim();
        var identity = RequireIdentity();
        var candidates = KnownSenderCandidates(senderKeyId);
        Exception? lastError = null;
        foreach (var contact in candidates)
        {
            InboundOpaquePayloadSummary inbound;
            try
            {
                inbound = _native.DecryptOpaquePayload(identity.IdentityJson, contact.ContactJson, normalized);
            }
            catch (Exception error) when (error is EnvelopeNativeException or CryptographicException)
            {
                lastError = error;
                continue;
            }

            // Once authenticated decryption succeeds, this is the one sender.
            // Identity, replay, JSON and authorization failures must propagate;
            // trying unrelated candidates would hide the actionable cause and
            // could turn a deferred mailbox prerequisite into a poison ACK.
            if (inbound.SenderKeyId != contact.KeyId || inbound.RecipientKeyId != identity.KeyId)
                throw new CryptographicException("信封身份与本机联系人不一致。");
            var existing = _state.Messages.FirstOrDefault(item => item.EnvelopeId == inbound.EnvelopeId);
            if (existing is not null) return new EnvelopeImportResult(existing, true);
            EnsureFreshCounter(contact.KeyId, inbound.MessageCounter);
            var message = await ProcessInboundPayloadCoreAsync(inbound, contact, normalized, cancellationToken)
                .ConfigureAwait(false);
            RecordReceivedCounter(contact.KeyId, inbound.MessageCounter);
            _state.Messages.Add(message);
            return new EnvelopeImportResult(message, false);
        }
        throw new EnvelopeCiphertextRejectedException(
            "已知发送方的信封认证或解密失败。",
            lastError);
    }

    private async Task<EnvelopeImportResult> ImportEnvelopeAndPersistCoreAsync(
        string envelopeBase64,
        string? senderKeyId,
        CancellationToken cancellationToken)
    {
        if (PruneExpiredInboundFileCacheCore(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) > 0)
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        var snapshot = CaptureInboundStateSnapshotCore();
        EnvelopeImportResult result;
        try
        {
            result = await ImportEnvelopeCoreAsync(envelopeBase64, senderKeyId, cancellationToken)
                .ConfigureAwait(false);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            try
            {
                RollbackInboundMutationCore(snapshot);
            }
            catch (Exception rollbackError)
            {
                throw new IOException(
                    "入站状态保存失败，且托管文件回滚不完整；已阻止确认该信封。",
                    new AggregateException(error, rollbackError));
            }
            throw;
        }

        try
        {
            // CompletedPath/CleanupPending, message and replay counters are now
            // durable. Cache deletion may safely proceed and is resumable.
            await ResumeInboundTransferCleanupCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception cleanupError)
        {
            await LogAsync("warn", "inbound_transfer_cleanup_deferred", new Dictionary<string, object?>
            {
                ["envelope_id"] = result.Message.EnvelopeId,
                ["error"] = cleanupError.Message,
            }, cancellationToken).ConfigureAwait(false);
        }
        return result;
    }

    private InboundStateSnapshot CaptureInboundStateSnapshotCore() => new(
        _state.Contacts.ToArray(),
        _state.Messages.ToArray(),
        _state.Groups.ToArray(),
        _state.GroupMembers.ToArray(),
        _state.GroupEvents.ToArray(),
        _state.ReceivedCounters.ToArray(),
        _state.ReceivedCounterArchive.ToArray(),
        _state.InboundFileTransfers.ToArray(),
        _state.InboundFileChunks.ToArray());

    private void RollbackInboundMutationCore(InboundStateSnapshot snapshot)
    {
        var beforePaths = InboundManagedPaths(snapshot.Messages, snapshot.Transfers, snapshot.Chunks);
        var newPaths = InboundManagedPaths(
                _state.Messages,
                _state.InboundFileTransfers,
                _state.InboundFileChunks)
            .Where(path => !beforePaths.Contains(path))
            .ToArray();

        Restore(_state.Contacts, snapshot.Contacts);
        Restore(_state.Messages, snapshot.Messages);
        Restore(_state.Groups, snapshot.Groups);
        Restore(_state.GroupMembers, snapshot.Members);
        Restore(_state.GroupEvents, snapshot.Events);
        Restore(_state.ReceivedCounters, snapshot.ReceivedCounters);
        Restore(_state.ReceivedCounterArchive, snapshot.ReplayArchive);
        Restore(_state.InboundFileTransfers, snapshot.Transfers);
        Restore(_state.InboundFileChunks, snapshot.Chunks);

        foreach (var path in newPaths) DeleteInboundRollbackFileCore(path);

        static void Restore<T>(List<T> destination, IReadOnlyCollection<T> source)
        {
            destination.Clear();
            destination.AddRange(source);
        }
    }

    private static HashSet<string> InboundManagedPaths(
        IEnumerable<ChatMessageRecord> messages,
        IEnumerable<InboundFileTransferRecord> transfers,
        IEnumerable<InboundFileChunkRecord> chunks)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in messages.Select(item => item.AttachmentPath)
                     .Concat(transfers.Select(item => item.CompletedPath))
                     .Concat(chunks.Select(item => (string?)item.CachePath))
                     .Where(path => !string.IsNullOrWhiteSpace(path)))
        {
            try { result.Add(Path.GetFullPath(path!)); }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        return result;
    }

    private void DeleteInboundRollbackFileCore(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var receivedRoot = Path.GetFullPath(_paths.Received);
        var transferRoot = Path.GetFullPath(Path.Combine(_paths.Cache, "transfers"));
        if (!IsPathInsideRoot(fullPath, receivedRoot) && !IsPathInsideRoot(fullPath, transferRoot))
            throw new IOException($"拒绝回滚托管根目录外的入站文件：{fullPath}");
        if (!File.Exists(fullPath)) return;
        if ((File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"拒绝跟随 reparse point 回滚入站文件：{fullPath}");
        File.Delete(fullPath);
        if (File.Exists(fullPath)) throw new IOException($"入站文件回滚删除失败：{fullPath}");
    }

    private sealed record InboundStateSnapshot(
        IReadOnlyList<StoredContact> Contacts,
        IReadOnlyList<ChatMessageRecord> Messages,
        IReadOnlyList<GroupRecord> Groups,
        IReadOnlyList<GroupMemberRecord> Members,
        IReadOnlyList<GroupEventRecord> Events,
        IReadOnlyList<ReceivedCounterRecord> ReceivedCounters,
        IReadOnlyList<IdentityReceivedCounterRecord> ReplayArchive,
        IReadOnlyList<InboundFileTransferRecord> Transfers,
        IReadOnlyList<InboundFileChunkRecord> Chunks);

    private IReadOnlyList<StoredContact> KnownSenderCandidates(string? senderKeyId)
    {
        var candidates = new List<StoredContact>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var contact in _state.Contacts)
        {
            AddCandidate(contact.KeyId, contact.ContactJson, contact);
        }

        foreach (var member in _state.GroupMembers)
        {
            if (string.IsNullOrWhiteSpace(member.ContactJson)) continue;
            AddCandidate(
                member.KeyId,
                member.ContactJson,
                new StoredContact(member.KeyId, member.DisplayName, member.ContactJson));
        }

        if (string.IsNullOrWhiteSpace(senderKeyId)) return candidates;
        var expectedSenderKeyId = senderKeyId.Trim();
        return candidates
            .Where(candidate => string.Equals(candidate.KeyId, expectedSenderKeyId, StringComparison.Ordinal))
            .ToArray();

        void AddCandidate(string expectedKeyId, string contactJson, StoredContact candidate)
        {
            if (string.IsNullOrWhiteSpace(expectedKeyId) || string.IsNullOrWhiteSpace(contactJson)) return;
            ContactSummary parsed;
            try
            {
                parsed = _native.ParseContact(contactJson);
            }
            catch (EnvelopeNativeException)
            {
                return;
            }

            if (!string.Equals(parsed.KeyId, expectedKeyId, StringComparison.Ordinal) || !seen.Add(parsed.KeyId))
                return;
            candidates.Add(candidate with
            {
                KeyId = parsed.KeyId,
                DisplayName = string.IsNullOrWhiteSpace(candidate.DisplayName)
                    ? parsed.DisplayName
                    : candidate.DisplayName,
                ContactJson = parsed.ContactJson,
            });
        }
    }

    private async Task<ChatMessageRecord> ProcessInboundPayloadCoreAsync(
        InboundOpaquePayloadSummary inbound,
        StoredContact sender,
        string envelopeBase64,
        CancellationToken cancellationToken)
    {
        if (inbound.Mime == GroupControlMime)
        {
            return await ProcessGroupPayloadCoreAsync(inbound, sender, envelopeBase64, cancellationToken)
                .ConfigureAwait(false);
        }

        if (inbound.Mime is FileManifestMime or FileChunkMime)
        {
            return await ProcessFileTransferPayloadCoreAsync(inbound, sender, envelopeBase64, cancellationToken)
                .ConfigureAwait(false);
        }

        RequireOrdinaryContactSender(sender.KeyId);
        if (inbound.Mime == ContactControlMime)
        {
            var map = DeserializeMap(inbound.PayloadBytes);
            if (GetString(map, "type") != "contact_deleted" ||
                GetString(map, "actor_key_id") != sender.KeyId ||
                GetString(map, "target_key_id") != RequireIdentity().KeyId)
            {
                throw new InvalidDataException("联系人删除事件身份无效。");
            }
            _state.Contacts.RemoveAll(item => item.KeyId == sender.KeyId);
            return InboundMessage(inbound, sender, envelopeBase64, $"联系人已删除：{sender.DisplayLabel}", sender.KeyId);
        }

        if (inbound.PayloadKind == "text" || inbound.Mime.StartsWith("text/plain", StringComparison.OrdinalIgnoreCase))
        {
            return InboundMessage(inbound, sender, envelopeBase64, Encoding.UTF8.GetString(inbound.PayloadBytes), sender.KeyId);
        }

        var fileName = SafeFileName(inbound.Filename ?? $"received-{inbound.EnvelopeId}.bin");
        var path = UniquePath(_paths.Received, fileName);
        await File.WriteAllBytesAsync(path, inbound.PayloadBytes, cancellationToken).ConfigureAwait(false);
        return InboundMessage(
            inbound,
            sender,
            envelopeBase64,
            $"收到文件：{fileName}",
            sender.KeyId,
            path,
            inbound.Mime,
            fileName);
    }

    private void RequireOrdinaryContactSender(string senderKeyId)
    {
        foreach (var contact in _state.Contacts.Where(item => item.KeyId == senderKeyId))
        {
            try
            {
                if (_native.ParseContact(contact.ContactJson).KeyId == senderKeyId) return;
            }
            catch (EnvelopeNativeException)
            {
            }
        }
        throw new InvalidDataException("发送方仅存在于群成员目录，不能发送普通联系人载荷。");
    }

    private async Task<DeliveryResult> DeliverEnvelopeCoreAsync(
        StoredContact contact,
        string envelopeId,
        string envelopeBase64,
        CancellationToken cancellationToken,
        string? logicalMessageId = null,
        int childIndex = 0,
        int childCount = 1)
    {
        var logicalId = string.IsNullOrWhiteSpace(logicalMessageId) ? envelopeId : logicalMessageId;
        await EnsureOutboundStagedCoreAsync(
                new OutboundWorkItem(contact, envelopeId, envelopeBase64, logicalId, childIndex, childCount),
                cancellationToken)
            .ConfigureAwait(false);

        if (!string.IsNullOrWhiteSpace(contact.P2pTicket) &&
            _p2pCooldown.CanAttempt(contact.KeyId, contact.P2pTicket))
        {
            try
            {
                var ack = await _p2p.SendEnvelopeAsync(
                        contact.P2pTicket,
                        DecodeBase64Url(envelopeBase64),
                        envelopeId,
                        cancellationToken: cancellationToken)
                    .ConfigureAwait(false);
                if (!string.Equals(ack.EnvelopeId, envelopeId, StringComparison.Ordinal))
                    throw new CryptographicException("P2P ACK envelope_id 与发送信封不匹配。");
                _p2pCooldown.RecordSuccess(contact.KeyId, contact.P2pTicket);
                return await CompleteOutboundDeliveryCoreAsync(
                        envelopeId,
                        new DeliveryResult("p2p", DeliveryState.Sent, ack.Detail),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception error)
            {
                _p2pCooldown.RecordFailure(contact.KeyId, contact.P2pTicket);
                await LogAsync("warn", "p2p_delivery_failed", new Dictionary<string, object?>
                {
                    ["recipient_key_id"] = contact.KeyId,
                    ["envelope_id"] = envelopeId,
                    ["error"] = error.Message,
                }, cancellationToken).ConfigureAwait(false);
            }
        }

        if (!string.IsNullOrWhiteSpace(_state.Settings.SyncServiceUrl))
        {
            try
            {
                using var server = CreateServerClient();
                if (!string.IsNullOrWhiteSpace(contact.DeviceId))
                {
                    try
                    {
                        var route = await server.LookupRouteAsync(contact.KeyId, contact.DeviceId, cancellationToken)
                            .ConfigureAwait(false);
                        if (route.Endpoint is { IsExpired: false } endpoint && !string.IsNullOrWhiteSpace(endpoint.P2pTicket))
                        {
                            if (_p2pCooldown.CanAttempt(contact.KeyId, endpoint.P2pTicket))
                            {
                                try
                                {
                                    var ack = await _p2p.SendEnvelopeAsync(
                                            endpoint.P2pTicket,
                                            DecodeBase64Url(envelopeBase64),
                                            envelopeId,
                                            cancellationToken: cancellationToken)
                                        .ConfigureAwait(false);
                                    if (!string.Equals(ack.EnvelopeId, envelopeId, StringComparison.Ordinal))
                                        throw new CryptographicException("P2P ACK envelope_id 与发送信封不匹配。");
                                    _p2pCooldown.RecordSuccess(contact.KeyId, endpoint.P2pTicket);
                                    return await CompleteOutboundDeliveryCoreAsync(
                                            envelopeId,
                                            new DeliveryResult("server_route_p2p", DeliveryState.Sent, ack.Detail),
                                            cancellationToken)
                                        .ConfigureAwait(false);
                                }
                                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                                {
                                    throw;
                                }
                                catch (Exception)
                                {
                                    _p2pCooldown.RecordFailure(contact.KeyId, endpoint.P2pTicket);
                                }
                            }
                        }
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                    catch { /* Mailbox below is authoritative. */ }
                }
                var requestSummary = _native.CreateEnvelopeSubmitRequest(
                    RequireIdentity().IdentityJson,
                    contact.KeyId,
                    envelopeId,
                    envelopeBase64);
                var request = DeserializeWire<EnvelopeSubmitRequestDto>(requestSummary.RequestJson);
                await server.SubmitEnvelopeAsync(request, cancellationToken).ConfigureAwait(false);
                return await CompleteOutboundDeliveryCoreAsync(
                        envelopeId,
                        new DeliveryResult("server_mailbox", DeliveryState.ServerMailbox, "已写入服务器 mailbox。"),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (Exception error)
            {
                return await CompleteOutboundDeliveryCoreAsync(
                        envelopeId,
                        new DeliveryResult("pending", DeliveryState.Pending, error.Message),
                        cancellationToken)
                    .ConfigureAwait(false);
            }
        }

        return await CompleteOutboundDeliveryCoreAsync(
                envelopeId,
                new DeliveryResult("pending", DeliveryState.Pending, "未配置同步服务，已保留待重试。"),
                cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<ulong> ReserveMessageCounterCoreAsync(CancellationToken cancellationToken) =>
        (await ReserveMessageCountersCoreAsync(1, cancellationToken).ConfigureAwait(false))[0];

    private async Task<IReadOnlyList<ulong>> ReserveMessageCountersCoreAsync(
        int count,
        CancellationToken cancellationToken)
    {
        if (count <= 0) throw new ArgumentOutOfRangeException(nameof(count));
        var counters = new ulong[count];
        for (var index = 0; index < count; index++) counters[index] = _state.AllocateMessageCounter();
        // This durable write is deliberately before envelope construction and
        // every P2P, route lookup, or mailbox side effect. A failed send burns
        // counters rather than ever reusing them after a crash.
        await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        return counters;
    }

    private async Task StageOutboundBatchCoreAsync(
        IReadOnlyCollection<OutboundWorkItem> workItems,
        CancellationToken cancellationToken,
        ChatMessageRecord? logicalMessage = null)
    {
        if (workItems.Count == 0) return;
        var pendingBefore = _state.PendingEnvelopes.ToArray();
        var messagesBefore = _state.Messages.ToArray();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var work in workItems)
        {
            var existing = _state.PendingEnvelopes.FirstOrDefault(item => item.EnvelopeId == work.EnvelopeId);
            var staged = existing is null
                ? new PendingEnvelopeRecord(
                    work.EnvelopeId,
                    work.Contact.KeyId,
                    work.EnvelopeBase64,
                    now,
                    RecipientContactJson: work.Contact.ContactJson,
                    LogicalMessageId: work.LogicalMessageId,
                    ChildIndex: work.ChildIndex,
                    ChildCount: work.ChildCount)
                : existing with
                {
                    RecipientKeyId = work.Contact.KeyId,
                    RecipientContactJson = work.Contact.ContactJson,
                    EnvelopeBase64 = work.EnvelopeBase64,
                    LogicalMessageId = work.LogicalMessageId,
                    ChildIndex = work.ChildIndex,
                    ChildCount = work.ChildCount,
                };
            _state.PendingEnvelopes.RemoveAll(item => item.EnvelopeId == work.EnvelopeId);
            _state.PendingEnvelopes.Add(staged);
        }
        if (logicalMessage is not null)
        {
            _state.Messages.RemoveAll(item => item.EnvelopeId == logicalMessage.EnvelopeId);
            _state.Messages.Add(logicalMessage);
        }
        try
        {
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            _state.PendingEnvelopes.Clear();
            _state.PendingEnvelopes.AddRange(pendingBefore);
            _state.Messages.Clear();
            _state.Messages.AddRange(messagesBefore);
            throw;
        }
    }

    private async Task EnsureOutboundStagedCoreAsync(
        OutboundWorkItem work,
        CancellationToken cancellationToken)
    {
        var existing = _state.PendingEnvelopes.FirstOrDefault(item => item.EnvelopeId == work.EnvelopeId);
        if (existing is not null &&
            !string.IsNullOrWhiteSpace(existing.RecipientContactJson) &&
            existing.LogicalMessageId == work.LogicalMessageId &&
            existing.ChildIndex == work.ChildIndex &&
            existing.ChildCount == work.ChildCount)
            return;
        await StageOutboundBatchCoreAsync([work], cancellationToken).ConfigureAwait(false);
    }

    private async Task<DeliveryResult> CompleteOutboundDeliveryCoreAsync(
        string envelopeId,
        DeliveryResult result,
        CancellationToken cancellationToken)
    {
        var index = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == envelopeId);
        if (index < 0) throw new InvalidOperationException("投递完成时找不到已持久化的 outbox child。");
        var existing = _state.PendingEnvelopes[index];
        var messagesBefore = _state.Messages.ToArray();
        _state.PendingEnvelopes[index] = existing with
        {
            AttemptCount = checked(existing.AttemptCount + 1),
            NextAttemptAtUnixMs = result.State == DeliveryState.Pending
                ? DateTimeOffset.UtcNow.AddSeconds(30).ToUnixTimeMilliseconds()
                : null,
            LastError = result.State == DeliveryState.Pending ? result.Detail : null,
            DeliveryState = result.State,
            LastRoute = result.Route,
            EnvelopeBase64 = result.State == DeliveryState.Pending ? existing.EnvelopeBase64 : string.Empty,
        };
        RefreshLogicalMessageDeliveryCore(existing.LogicalMessageId ?? envelopeId, result.Detail);
        try
        {
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            var currentIndex = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == envelopeId);
            if (currentIndex >= 0) _state.PendingEnvelopes[currentIndex] = existing;
            _state.Messages.Clear();
            _state.Messages.AddRange(messagesBefore);
            throw;
        }
        return result;
    }

    private DeliveryState AggregateLogicalDeliveryStateCore(string logicalMessageId)
    {
        var children = _state.PendingEnvelopes
            .Where(item => (item.LogicalMessageId ?? item.EnvelopeId) == logicalMessageId)
            .ToArray();
        if (children.Length == 0) return DeliveryState.Pending;
        var expected = children.Max(item => Math.Max(1, item.ChildCount));
        if (children.Select(item => item.ChildIndex).Distinct().Count() < expected ||
            children.Any(item => item.DeliveryState == DeliveryState.Pending))
            return DeliveryState.Pending;
        if (children.Any(item => item.DeliveryState == DeliveryState.Failed)) return DeliveryState.Failed;
        if (children.All(item => item.DeliveryState == DeliveryState.Delivered)) return DeliveryState.Delivered;
        if (children.Any(item => item.DeliveryState == DeliveryState.ServerMailbox)) return DeliveryState.ServerMailbox;
        return DeliveryState.Sent;
    }

    private void RefreshLogicalMessageDeliveryCore(string logicalMessageId, string? detail = null)
    {
        var aggregate = AggregateLogicalDeliveryStateCore(logicalMessageId);
        for (var index = 0; index < _state.Messages.Count; index++)
        {
            var message = _state.Messages[index];
            if ((message.LogicalMessageId ?? message.EnvelopeId) != logicalMessageId) continue;
            _state.Messages[index] = message with
            {
                DeliveryState = aggregate,
                DeliveryDetail = string.IsNullOrWhiteSpace(detail) ? message.DeliveryDetail : detail,
            };
        }
    }

    public async Task<EnvelopeP2pStatus> EnsureP2pListeningAsync(CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        var status = await _p2p.StartAsync(
            _state.DeviceId,
            ImportP2pEnvelopeAsync,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _state.CurrentP2pTicket = status.Ticket;
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
        return status;
    }

    private async Task<EnvelopeP2pAck> ImportP2pEnvelopeAsync(
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken)
    {
        // Outbound operations may hold the state gate while waiting for a P2P
        // acknowledgement. Waiting here would let two peers sending at the same
        // time deadlock each other. Rejecting a busy listener is safe: the sender
        // immediately falls back to its mailbox/pending-delivery path.
        if (!await _gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return EnvelopeP2pAck.Error(string.Empty, "客户端正忙，请回退到 mailbox 后重试。");
        }

        EnvelopeImportResult result;
        try
        {
            result = await ImportEnvelopeAndPersistCoreAsync(
                    EncodeBase64Url(bytes.Span),
                    senderKeyId: null,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception error)
        {
            return EnvelopeP2pAck.Error(string.Empty, error.Message);
        }
        finally
        {
            _gate.Release();
        }

        RaiseStateChanged();
        return EnvelopeP2pAck.Ok(
            result.Message.EnvelopeId,
            result.Duplicate ? "duplicate" : "stored");
    }

    private async Task RegisterRouteCoreAsync(EnvelopeServerClient server, CancellationToken cancellationToken)
    {
        if (_p2p.Status is null) return;
        var identity = RequireIdentity();
        var update = _native.CreateDeviceEndpointUpdate(
            identity.IdentityJson,
            _state.DeviceId,
            _p2p.Status.Ticket,
            Guid.NewGuid().ToString("N"));
        var ownerContact = DeserializeWire<ContactDto>(_native.ContactFromIdentity(identity.IdentityJson));
        var endpoint = DeserializeWire<DeviceEndpointUpdateDto>(update.EndpointJson);
        await server.RegisterDeviceAsync(new DeviceRegistrationRequestDto(ownerContact, endpoint), cancellationToken)
            .ConfigureAwait(false);
    }

    private EnvelopeServerClient CreateServerClient()
    {
        var url = _state.Settings.SyncServiceUrl?.Trim() ?? string.Empty;
        if (url.Length == 0) throw new InvalidOperationException("请先配置消息同步服务入口。");
        return new EnvelopeServerClient(url, nodeTrustVerifier: new NativeEnvelopeNodeTrustVerifier(_native));
    }

    private void EnsureFreshCounter(string senderKeyId, ulong counter)
    {
        if (counter == 0)
        {
            throw new CryptographicException("消息计数器必须大于 0。");
        }

        if (_state.ReceivedCounters.Any(item =>
                item.SenderKeyId == senderKeyId && item.MessageCounter == counter))
        {
            throw new CryptographicException($"检测到重复的消息计数器：{counter}。");
        }
    }

    private void RecordReceivedCounter(string senderKeyId, ulong counter)
    {
        EnsureFreshCounter(senderKeyId, counter);
        _state.ReceivedCounters.Add(new ReceivedCounterRecord(senderKeyId, counter));
        var identityKeyId = RequireIdentity().KeyId;
        if (!_state.ReceivedCounterArchive.Any(item =>
                item.RecipientIdentityKeyId == identityKeyId &&
                item.SenderKeyId == senderKeyId &&
                item.MessageCounter == counter))
            _state.ReceivedCounterArchive.Add(new IdentityReceivedCounterRecord(
                identityKeyId,
                senderKeyId,
                counter));
    }

    private void ArchiveCurrentReceivedCountersCore()
    {
        var identityKeyId = _state.Identity?.KeyId;
        if (string.IsNullOrWhiteSpace(identityKeyId)) return;
        foreach (var counter in _state.ReceivedCounters)
        {
            if (_state.ReceivedCounterArchive.Any(item =>
                    item.RecipientIdentityKeyId == identityKeyId &&
                    item.SenderKeyId == counter.SenderKeyId &&
                    item.MessageCounter == counter.MessageCounter))
                continue;
            _state.ReceivedCounterArchive.Add(new IdentityReceivedCounterRecord(
                identityKeyId,
                counter.SenderKeyId,
                counter.MessageCounter));
        }
    }

    private IReadOnlyList<ReceivedCounterRecord> ArchivedReceivedCountersForCore(string identityKeyId) =>
        _state.ReceivedCounterArchive
            .Where(item => item.RecipientIdentityKeyId == identityKeyId)
            .Select(item => new ReceivedCounterRecord(item.SenderKeyId, item.MessageCounter))
            .DistinctBy(item => (item.SenderKeyId, item.MessageCounter))
            .ToArray();

    private static ChatMessageRecord InboundMessage(
        InboundOpaquePayloadSummary inbound,
        StoredContact sender,
        string envelopeBase64,
        string text,
        string conversationId,
        string? attachmentPath = null,
        string? attachmentMime = null,
        string? attachmentFileName = null) => new(
            inbound.EnvelopeId,
            conversationId,
            MessageDirection.Incoming,
            sender.KeyId,
            sender.DisplayLabel,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            inbound.MessageCounter,
            text,
            envelopeBase64,
            DeliveryState.Received,
            attachmentPath,
            attachmentMime,
            attachmentFileName,
            IsRead: false);

    private async Task PersistCoreAsync(CancellationToken cancellationToken) =>
        await _stateStore.SaveAsync(_state, cancellationToken).ConfigureAwait(false);

    private async Task LogAsync(
        string level,
        string name,
        IReadOnlyDictionary<string, object?> fields,
        CancellationToken cancellationToken)
    {
        try { await _diagnostics.WriteAsync(level, name, fields, cancellationToken).ConfigureAwait(false); }
        catch { /* Diagnostics must never break messaging. */ }
    }

    private static T DeserializeWire<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Json)
        ?? throw new JsonException($"Envelope wire object {typeof(T).Name} is null.");

    private static Dictionary<string, JsonElement> DeserializeMap(byte[] bytes) =>
        JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(bytes, Json)
        ?? throw new JsonException("Envelope payload is not an object.");

    private static string GetString(IReadOnlyDictionary<string, JsonElement> map, string key) =>
        map.TryGetValue(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? string.Empty : string.Empty;

    private static string SafeFileName(string value)
    {
        var name = Path.GetFileName(value.Trim());
        foreach (var invalid in Path.GetInvalidFileNameChars()) name = name.Replace(invalid, '_');
        return string.IsNullOrWhiteSpace(name) ? "file" : name;
    }

    private static string UniquePath(string directory, string fileName)
    {
        Directory.CreateDirectory(directory);
        var first = Path.Combine(directory, fileName);
        if (!File.Exists(first)) return first;
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 1; ; index++)
        {
            var candidate = Path.Combine(directory, $"{stem}-{index}{extension}");
            if (!File.Exists(candidate)) return candidate;
        }
    }

    private static string NormalizeDisplayName(string displayName) =>
        string.IsNullOrWhiteSpace(displayName) ? "Envelope User" : displayName.Trim();

    private SecureIdentityRecord RequireIdentity() =>
        _state.Identity ?? throw new InvalidOperationException("请先创建或恢复本机身份。");

    private void EnsureInitialized()
    {
        ThrowIfDisposed();
        if (!_initialized) throw new InvalidOperationException("Envelope Windows 客户端尚未初始化。");
    }

    private void RaiseStateChanged() => StateChanged?.Invoke(this, EventArgs.Empty);

    private static string EncodeBase64Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized = (normalized.Length % 4) switch { 0 => normalized, 2 => normalized + "==", 3 => normalized + "=", _ => throw new FormatException("base64url 长度无效。") };
        return Convert.FromBase64String(normalized);
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await _p2p.DisposeAsync().ConfigureAwait(false);
        _gate.Dispose();
    }
}
