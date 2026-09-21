using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Tests;

internal static class DeliveryReliabilityVerification
{
    public static async Task RunAsync()
    {
        var root = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.DeliveryReliabilityVerification",
            Guid.NewGuid().ToString("N")));
        var expectedRoot = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.DeliveryReliabilityVerification"));
        Require(root.StartsWith(expectedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase),
            "delivery reliability temporary root confinement");
        Directory.CreateDirectory(root);
        try
        {
            var native = new EnvelopeNativeClient();
            var alicePhrase = native.GenerateRecoveryPhrase();
            var bobPhrase = native.GenerateRecoveryPhrase();
            var carolPhrase = native.GenerateRecoveryPhrase();
            var malloryPhrase = native.GenerateRecoveryPhrase();
            var alice = native.RecoverIdentity("Alice", alicePhrase);
            var bob = native.RecoverIdentity("Bob", bobPhrase);
            var carol = native.RecoverIdentity("Carol", carolPhrase);
            var mallory = native.RecoverIdentity("Mallory", malloryPhrase);

            await VerifyDurableOutboxAndPartialFanoutAsync(root, native, alice, bob);
            await VerifySignedP2pBusinessResultsAsync(root, native, alice, bob);
            await VerifyPendingRecipientUnionAsync(root, native, alice, bob, carol);
            await VerifyMailboxPoisonPolicyAndPruningAsync(root);
            await VerifyUnknownMailboxSenderAcknowledgedAsync(root, native, alice);
            await VerifyKnownSenderMalformedPageAcknowledgedAsync(root, native, alice, bob);
            await VerifyDeferredCausalMailboxQueueAsync(root, native, alice, bob, carol);
            await VerifySenderScopedFileTransfersAsync(root, native, alice, bob, carol, mallory);
            await VerifyInboundChunkCacheLimitsAsync(root, native, alice, bob);
            await VerifyManifestOnlyTransferLimitsAsync(root, native, alice, bob);
            await VerifyInboundFilePersistenceRollbackAsync(root, native, alice, bob);
            await VerifyCompletedTransferCleanupRecoveryAsync(root);
            await VerifyIdentityPlaintextCleanupAsync(root, native, alice, bobPhrase);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }

        Console.WriteLine("[PASS] Durable delivery, mailbox poison, and scoped transfer verification");
    }

    private static async Task VerifyDurableOutboxAndPartialFanoutAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary alice,
        IdentitySummary bob)
    {
        await using var recipient = new EnvelopeP2pTransport();
        MemoryStateStore? store = null;
        var connectionCount = 0;
        var rejectAttempt = 0;
        var textStageObserved = false;
        var fileBatchStageObserved = false;
        var recipientStatus = await recipient.StartAsync(
            "bob-test",
            (payload, _) =>
            {
                var attempt = Interlocked.Increment(ref connectionCount);
                var encoded = EncodeBase64Url(payload.Span);
                var snapshot = store!.Snapshot;
                var child = snapshot.PendingEnvelopes.SingleOrDefault(item => item.EnvelopeBase64 == encoded)
                    ?? throw new InvalidOperationException("P2P side effect occurred before its child was durable.");
                var logicalId = child.LogicalMessageId ?? child.EnvelopeId;
                var logicalChildren = snapshot.PendingEnvelopes
                    .Where(item => (item.LogicalMessageId ?? item.EnvelopeId) == logicalId)
                    .ToArray();
                var logicalMessageExists = snapshot.Messages.Any(message =>
                    (message.LogicalMessageId ?? message.EnvelopeId) == logicalId &&
                    message.DeliveryState == DeliveryState.Pending);
                if (child.ChildCount == 1)
                    textStageObserved = logicalChildren.Length == 1 && logicalMessageExists;
                else
                    fileBatchStageObserved = logicalChildren.Length == child.ChildCount && logicalMessageExists;

                return Task.FromResult(attempt == Volatile.Read(ref rejectAttempt)
                    ? EnvelopeP2pAck.Error(child.EnvelopeId, "simulated partial fanout failure")
                    : EnvelopeP2pAck.Ok(child.EnvelopeId, "stored"));
            });
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var ticket = new EnvelopeP2pTicket(
            "bob-test",
            [IPAddress.Loopback.ToString()],
            recipientStatus.Port,
            now,
            now + 60_000).Encode();
        var bobContact = native.ParseContact(native.ContactFromIdentity(bob.IdentityJson));
        var state = StateFor(alice);
        state.Contacts.Add(new StoredContact(
            bobContact.KeyId,
            bobContact.DisplayName,
            bobContact.ContactJson,
            DeviceId: "bob-test",
            P2pTicket: ticket));
        store = new MemoryStateStore(state);
        var paths = Paths(root, "durable-outbox");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();

        var persistedBeforeFailure = store.Snapshot.NextMessageCounter;
        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.SendTextAsync(bob.KeyId, "must not reach network"),
            "counter reservation persistence failure aborts before network");
        Equal(0, Volatile.Read(ref connectionCount), "no network side effect before counter reservation save");
        Equal(persistedBeforeFailure, store.Snapshot.NextMessageCounter,
            "failed reservation does not claim durability");
        Equal(persistedBeforeFailure + WindowsClientState.CounterStride, engine.State.NextMessageCounter,
            "failed in-process reservation is burned");

        var sent = await engine.SendTextAsync(bob.KeyId, "durable text");
        Require(textStageObserved, "logical text and child are staged before P2P delivery");
        Equal(persistedBeforeFailure + WindowsClientState.CounterStride,
            sent.MessageCounter,
            "next send does not reuse failed in-process reservation");
        Equal(DeliveryState.Sent, sent.DeliveryState, "successful text P2P state");
        var textChild = engine.State.PendingEnvelopes.Single(item => item.EnvelopeId == sent.EnvelopeId);
        Require(textChild.EnvelopeBase64.Length > 0, "unsigned transport ACK retains recovery ciphertext");
        Require(textChild.Ha is { StorageState: HaStorageState.LocalPending, DeliveryState: HaDeliveryState.Pending },
            "unsigned transport ACK cannot advance verified HA state");
        Require(!string.IsNullOrWhiteSpace(textChild.RecipientContactJson),
            "outbox child persists recipient contact");

        var source = Path.Combine(root, "partial-fanout-source.bin");
        await File.WriteAllBytesAsync(source, [1, 2, 3, 4]);
        Volatile.Write(ref rejectAttempt, Volatile.Read(ref connectionCount) + 2);
        var fileMessage = await engine.SendFileAsync(bob.KeyId, source, "application/test");
        Require(fileBatchStageObserved, "all file children and logical message stage atomically before delivery");
        var fileChildren = engine.State.PendingEnvelopes
            .Where(item => item.LogicalMessageId == fileMessage.LogicalMessageId)
            .OrderBy(item => item.ChildIndex)
            .ToArray();
        Equal(2, fileChildren.Length, "manifest and one chunk are represented as child envelopes");
        Require(fileChildren.All(item => item.ChildCount == 2), "file child_count metadata");
        Equal(DeliveryState.Sent, fileChildren[0].DeliveryState, "partial fanout successful child state");
        Require(fileChildren[0].EnvelopeBase64.Length > 0, "partial fanout unsigned ACK retains recovery ciphertext");
        Equal(DeliveryState.Pending, fileChildren[1].DeliveryState, "partial fanout failed child remains pending");
        Require(fileChildren[1].EnvelopeBase64.Length > 0, "pending child retains retry envelope");
        Equal(DeliveryState.Pending, fileMessage.DeliveryState, "logical message aggregates partial fanout as pending");
    }

    private static async Task VerifySignedP2pBusinessResultsAsync(string root, EnvelopeNativeClient native,
        IdentitySummary alice, IdentitySummary bob)
    {
        var receiverState = StateFor(bob);
        receiverState.Contacts.Add(new StoredContact(alice.KeyId, alice.DisplayName, native.ContactFromIdentity(alice.IdentityJson)));
        var receiverStore = new MemoryStateStore(receiverState);
        await using var receiver = Engine(native, receiverStore, Paths(root, "ha-p2p-receiver"));
        await receiver.InitializeAsync();
        var status = receiver.P2pStatus!;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var ticket = new EnvelopeP2pTicket(receiver.State.DeviceId, [IPAddress.Loopback.ToString()], status.Port, now, now + 30 * 60_000).Encode();
        var senderState = StateFor(alice);
        senderState.Contacts.Add(new StoredContact(bob.KeyId, bob.DisplayName, native.ContactFromIdentity(bob.IdentityJson),
            DeviceId: receiver.State.DeviceId, P2pTicket: ticket));
        var senderStore = new MemoryStateStore(senderState);
        await using var sender = Engine(native, senderStore, Paths(root, "ha-p2p-sender"));
        await sender.InitializeAsync();
        var text = await sender.SendTextAsync(bob.KeyId, "signed and durable");
        Require(text.VerifiedRecipientResultJson is not null && text.VerifiedDeliveryState == HaDeliveryState.Delivered,
            "text sender advances only on persisted recipient signature");
        var receivedResult = receiverStore.Snapshot.RecipientResultOutbox.Single(item => item.EnvelopeId == text.EnvelopeId);
        Require(receivedResult.SignedResultJson is not null && receivedResult.Outcome == HaDeliveryState.Delivered,
            "recipient signature exists in durable slot before P2P ACK");
        var child = senderStore.Snapshot.PendingEnvelopes.Single(item => item.EnvelopeId == text.EnvelopeId);
        var beforeMessages = receiver.State.Messages.Count;
        Require(child.EnvelopeBase64.Length == 0, "verified terminal result atomically releases recovery body");
        var duplicate = await receiver.ImportEnvelopeAsync(text.OpaqueEnvelopeBase64, alice.KeyId);
        Require(duplicate.Duplicate && beforeMessages == receiver.State.Messages.Count,
            "mailbox/P2P duplicate shares durable business dedup key");
        var source = Path.Combine(root, "ha-p2p-source.bin");
        if (Environment.GetEnvironmentVariable("ENVELOPE_HA_LARGE_FILE_CHECK") == "1")
        {
            await using var large = File.Create(source);
            large.SetLength(64L * 1024 * 1024);
        }
        else await File.WriteAllBytesAsync(source, [9, 8, 7, 6]);
        var file = await sender.SendFileAsync(bob.KeyId, source, "application/test");
        if (file.VerifiedDeliveryState != HaDeliveryState.Delivered)
        {
            Console.WriteLine("HA file child outcomes: " + string.Join("; ", sender.State.PendingEnvelopes
                .Where(item => item.LogicalMessageId == file.LogicalMessageId)
                .Select(item => $"{item.ChildIndex}:{item.DeliveryState}/{item.Ha?.DeliveryState}/{item.LastError}")));
            foreach (var log in Directory.EnumerateFiles(Paths(root, "ha-p2p-sender").Logs, "*", SearchOption.AllDirectories))
                foreach (var line in File.ReadLines(log).Where(line => line.Contains("p2p_delivery_failed", StringComparison.Ordinal)))
                    Console.WriteLine(line);
        }
        Require(file.VerifiedDeliveryState == HaDeliveryState.Delivered && file.VerifiedRecipientResultJson is not null,
            "completed file bundle verifies every manifest/chunk child");
        Require(senderStore.Snapshot.PendingEnvelopes.Where(item => item.LogicalMessageId == file.LogicalMessageId)
            .All(item => item.Ha is { DeliveryState: HaDeliveryState.Delivered }), "no file child remains at unsigned transport success");
    }

    private static async Task VerifyPendingRecipientUnionAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary alice,
        IdentitySummary bob,
        IdentitySummary carol)
    {
        var state = StateFor(alice);
        var bobContact = native.ParseContact(native.ContactFromIdentity(bob.IdentityJson));
        var carolContact = native.ParseContact(native.ContactFromIdentity(carol.IdentityJson));
        state.GroupMembers.Add(new GroupMemberRecord(
            "grp-union",
            bob.KeyId,
            bob.DisplayName,
            bobContact.ContactJson,
            GroupRole.Member,
            GroupMemberStatus.Active,
            GroupTrustState.Unverified,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        var bobEnvelope = native.EncryptOpaqueText(
            alice.IdentityJson, bobContact.ContactJson, "bob pending", state.NextMessageCounter);
        var carolEnvelope = native.EncryptOpaqueText(
            alice.IdentityJson,
            carolContact.ContactJson,
            "carol pending",
            state.NextMessageCounter + WindowsClientState.CounterStride);
        state.PendingEnvelopes.Add(new PendingEnvelopeRecord(
            bobEnvelope.EnvelopeId,
            bob.KeyId,
            bobEnvelope.EnvelopeBase64,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            RecipientContactJson: null));
        state.PendingEnvelopes.Add(new PendingEnvelopeRecord(
            carolEnvelope.EnvelopeId,
            carol.KeyId,
            carolEnvelope.EnvelopeBase64,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            RecipientContactJson: carolContact.ContactJson));
        state.PendingEnvelopes.Add(new PendingEnvelopeRecord(
            "missing-recipient",
            "missing-key",
            "AQID",
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));

        var store = new MemoryStateStore(state);
        var paths = Paths(root, "pending-union");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();
        await engine.RetryPendingAsync();

        var bobPending = engine.State.PendingEnvelopes.Single(item => item.EnvelopeId == bobEnvelope.EnvelopeId);
        var carolPending = engine.State.PendingEnvelopes.Single(item => item.EnvelopeId == carolEnvelope.EnvelopeId);
        var missing = engine.State.PendingEnvelopes.Single(item => item.EnvelopeId == "missing-recipient");
        Equal(1, bobPending.AttemptCount, "retry resolves recipient from group-member union");
        Equal(1, carolPending.AttemptCount, "retry resolves persisted recipient contact after contact removal");
        Equal(0, missing.AttemptCount, "unresolved recipient is not falsely attempted");
        Require(missing.LastError?.Contains("outbox 已保留", StringComparison.Ordinal) == true,
            "unresolved recipient remains auditable and is never silently dropped");
        Equal(3, engine.State.PendingEnvelopes.Count, "retry preserves all pending children");
    }

    private static async Task VerifyMailboxPoisonPolicyAndPruningAsync(string root)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var state = new WindowsClientState();
        state.Validate();
        state.MailboxQuarantine.Add(new MailboxQuarantineRecord(
            "expired", "sender", "invalid_payload", "old", "00", 1,
            now - (long)TimeSpan.FromDays(8).TotalMilliseconds));
        for (var index = 0; index < 1_005; index++)
            state.MailboxQuarantine.Add(new MailboxQuarantineRecord(
                $"poison-{index:0000}", "sender", "invalid_payload", "metadata only", "00", 1, now + index));
        state.DeferredMailboxEnvelopes.Add(new DeferredMailboxEnvelopeRecord(
            "deferred-expired", "sender", "AQID", "missing_prerequisite", "old", 4,
            now - (long)TimeSpan.FromDays(8).TotalMilliseconds,
            now - (long)TimeSpan.FromDays(8).TotalMilliseconds));
        for (var index = 0; index < EnvelopeClientEngine.MaximumDeferredMailboxEnvelopeCount + 4; index++)
            state.DeferredMailboxEnvelopes.Add(new DeferredMailboxEnvelopeRecord(
                $"deferred-{index:0000}", "sender", "AQID", "missing_prerequisite", "waiting", 4,
                now + index,
                now + index));
        var store = new MemoryStateStore(state);
        var paths = Paths(root, "quarantine-prune");
        await using (var engine = Engine(new EnvelopeNativeClient(), store, paths))
        {
            await engine.InitializeAsync();
            Equal(1_000, engine.State.MailboxQuarantine.Count, "quarantine bounded to 1000 records");
            Require(engine.State.MailboxQuarantine.All(item => item.EnvelopeId != "expired"),
                "quarantine prunes records older than seven days at initialization");
            Equal(EnvelopeClientEngine.MaximumDeferredMailboxEnvelopeCount,
                engine.State.DeferredMailboxEnvelopes.Count,
                "deferred raw mailbox queue is count-bounded at initialization");
            Require(engine.State.DeferredMailboxEnvelopes.All(item => item.EnvelopeId != "deferred-expired"),
                "deferred raw mailbox queue prunes items older than seven days");
            Require(store.Snapshot.DeferredMailboxEnvelopes.Count ==
                    EnvelopeClientEngine.MaximumDeferredMailboxEnvelopeCount,
                "deferred raw pruning is durably persisted");
            var serialized = JsonSerializer.Serialize(engine.State.MailboxQuarantine);
            Require(!serialized.Contains("EnvelopeBase64", StringComparison.OrdinalIgnoreCase),
                "quarantine metadata does not retain opaque envelope bodies");
        }

        Require(!ClassifyPermanent(new IOException("disk unavailable")), "I/O failure is deferred");
        Require(!ClassifyPermanent(new UnauthorizedAccessException("vault locked")),
            "authorization failure is deferred");
        Require(!ClassifyPermanent(new EnvelopeNativeException("contact missing")),
            "native key/contact failure is deferred");
        Require(!ClassifyPermanent(new InvalidDataException(
                "群组事件 epoch 必须为 5，实际为 7。")),
            "future group epoch is deferred for missing prerequisite events");
        Require(ClassifyPermanent(new InvalidDataException(
                "群组事件 epoch 必须为 5，实际为 4。")),
            "stale group epoch is deterministic poison");
        Require(!ClassifyPermanent(new InvalidDataException("共识背书候选人状态无效。")),
            "endorsement before acceptance is deferred");
        Require(ClassifyPermanent(new JsonException("invalid payload")), "invalid JSON is permanent poison");
        Require(ClassifyPermanent(new CryptographicException("检测到重放计数器")),
            "explicit replay is permanent poison");
        Require(!ClassifyPermanent(new InvalidOperationException("unknown processing failure")),
            "unknown processing failure is deferred");
    }

    private static async Task VerifyUnknownMailboxSenderAcknowledgedAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver)
    {
        await using var server = new MailboxTestServer();
        const string envelopeId = "mailbox-unknown-sender";
        server.SetEnvelopes([
            new MailboxEnvelopeDto(
                envelopeId,
                "unknown-key-id",
                receiver.KeyId,
                "AQID",
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeMilliseconds()),
        ]);
        var state = StateFor(receiver);
        state.Settings = state.Settings with { SyncServiceUrl = server.BaseUrl };
        var store = new MemoryStateStore(state);
        var paths = Paths(root, "unknown-mailbox-sender");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();

        var result = await engine.SynchronizeAsync();

        Equal(1, result.Acknowledged, "unknown mailbox sender is permanently acknowledged");
        Require(server.AcknowledgedEnvelopeIds.Contains(envelopeId),
            "unknown sender tombstone reaches the mailbox ACK endpoint");
        var quarantine = engine.State.MailboxQuarantine.Single(item => item.EnvelopeId == envelopeId);
        Equal("unknown_sender", quarantine.ReasonCode, "unknown sender has auditable reason code");
        Equal(4, quarantine.EnvelopeSizeBytes, "unknown sender audit retains only envelope size");
        Require(quarantine.AcknowledgedAtUnixMs is not null,
            "unknown sender audit metadata records successful ACK");
        Require(!JsonSerializer.Serialize(quarantine).Contains("AQID", StringComparison.Ordinal),
            "unknown sender quarantine never retains the raw envelope body");
        Require(store.Snapshot.MailboxQuarantine.Any(item =>
                item.EnvelopeId == envelopeId && item.AcknowledgedAtUnixMs is not null),
            "unknown sender quarantine and ACK tombstone are durable");
    }

    private static async Task VerifyKnownSenderMalformedPageAcknowledgedAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver,
        IdentitySummary sender)
    {
        await using var server = new MailboxTestServer();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var receiverContact = native.ContactFromIdentity(receiver.IdentityJson);
        var legal = native.EncryptOpaqueText(
            sender.IdentityJson,
            receiverContact,
            "legal envelope after malformed page",
            1);
        var mailboxItems = Enumerable.Range(0, 50)
            .Select(index => new MailboxEnvelopeDto(
                $"known-malformed-{index:D2}",
                sender.KeyId,
                receiver.KeyId,
                EncodeBase64Url(RandomNumberGenerator.GetBytes(48)),
                now + index,
                now + (long)TimeSpan.FromDays(1).TotalMilliseconds))
            .Append(new MailboxEnvelopeDto(
                legal.EnvelopeId,
                sender.KeyId,
                receiver.KeyId,
                legal.EnvelopeBase64,
                now + 51,
                now + (long)TimeSpan.FromDays(1).TotalMilliseconds))
            .ToArray();
        server.SetEnvelopes(mailboxItems);
        var state = StateFor(receiver);
        state.Contacts.Add(StoredContact.FromSummary(native.ParseContact(
            native.ContactFromIdentity(sender.IdentityJson))));
        state.Settings = state.Settings with { SyncServiceUrl = server.BaseUrl };
        var store = new MemoryStateStore(state);
        var paths = Paths(root, "known-malformed-mailbox-page");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();

        var poisonPage = await engine.SynchronizeAsync();
        Equal(50, poisonPage.Pulled, "mailbox pull honors the oldest-50 page boundary");
        Equal(50, poisonPage.Quarantined,
            "known-sender deterministic authentication failures are quarantined");
        Equal(50, poisonPage.Acknowledged,
            "known-sender malformed page is fully acknowledged");
        Require(engine.State.MailboxQuarantine.Count(item =>
                item.ReasonCode == "authentication_failed") == 50,
            "known-sender ciphertext poison has an explicit permanent reason");
        Require(engine.State.DeferredMailboxEnvelopes.Count == 0,
            "deterministic ciphertext poison never enters the causal deferred queue");

        var legalPage = await engine.SynchronizeAsync();
        Equal(1, legalPage.Pulled, "legal item behind poison becomes the next mailbox page");
        Equal(1, legalPage.Imported, "legal item behind 50 malformed ciphertexts imports normally");
        Require(engine.State.Messages.Any(item =>
                item.EnvelopeId == legal.EnvelopeId &&
                item.Text == "legal envelope after malformed page"),
            "known-sender poison cannot cause mailbox head-of-line blocking");
    }

    private static async Task VerifySenderScopedFileTransfersAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver,
        IdentitySummary bob,
        IdentitySummary carol,
        IdentitySummary mallory)
    {
        const string groupId = "grp-transfer-scope";
        const string transferId = "same-transfer";
        var state = StateFor(receiver);
        var receiverContact = native.ContactFromIdentity(receiver.IdentityJson);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        state.Groups.Add(new GroupRecord(
            groupId, "Transfer", receiver.KeyId, GroupPolicy.Normal, 1, now, now, "seed"));
        state.GroupMembers.Add(Member(receiver, GroupRole.Owner, GroupMemberStatus.Active));
        state.GroupMembers.Add(Member(bob, GroupRole.Member, GroupMemberStatus.Active));
        state.GroupMembers.Add(Member(carol, GroupRole.Member, GroupMemberStatus.Active));
        state.GroupMembers.Add(Member(mallory, GroupRole.Member, GroupMemberStatus.Pending));
        var store = new MemoryStateStore(state);
        var paths = Paths(root, "sender-scoped-transfer");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();

        var bobBytes = new byte[] { 1, 2, 3 };
        var carolBytes = new byte[] { 9, 8, 7, 6 };
        var bobEnvelope = FileChunkEnvelope(native, bob, receiverContact, groupId, transferId, bobBytes, 1);
        var carolEnvelope = FileChunkEnvelope(native, carol, receiverContact, groupId, transferId, carolBytes, 1);
        await engine.ImportEnvelopeAsync(bobEnvelope.EnvelopeBase64, bob.KeyId);
        await engine.ImportEnvelopeAsync(carolEnvelope.EnvelopeBase64, carol.KeyId);
        Require(engine.State.Messages
                .Where(item => item.EnvelopeId is not null &&
                               (item.EnvelopeId == bobEnvelope.EnvelopeId || item.EnvelopeId == carolEnvelope.EnvelopeId))
                .All(item => item.ConversationId == groupId),
            "group file chunks remain in the authenticated group conversation");

        var directText = native.EncryptOpaqueText(
            bob.IdentityJson,
            receiverContact,
            "group directory must not grant direct messaging",
            2);
        await ExpectAsync<InvalidDataException>(
            () => engine.ImportEnvelopeAsync(directText.EnvelopeBase64, bob.KeyId),
            "group-only sender direct text capability rejection");
        Require(engine.State.ReceivedCounters.All(item =>
                item.SenderKeyId != bob.KeyId || item.MessageCounter != 2),
            "rejected group-only direct text does not consume replay counter");
        var directFile = native.EncryptOpaqueFile(
            bob.IdentityJson,
            receiverContact,
            "direct.bin",
            "application/octet-stream",
            [7, 7, 7],
            3);
        await ExpectAsync<InvalidDataException>(
            () => engine.ImportEnvelopeAsync(directFile.EnvelopeBase64, bob.KeyId),
            "group-only sender generic direct file capability rejection");
        Require(engine.State.ReceivedCounters.All(item =>
                item.SenderKeyId != bob.KeyId || item.MessageCounter != 3),
            "rejected group-only generic file does not consume replay counter");

        var chunks = engine.State.InboundFileChunks
            .Where(item => item.TransferId == transferId)
            .OrderBy(item => item.SenderKeyId, StringComparer.Ordinal)
            .ToArray();
        Equal(2, chunks.Length, "same transfer_id from two senders remains independent");
        Require(chunks[0].SenderKeyId != chunks[1].SenderKeyId, "transfer state is sender-scoped");
        Require(!string.Equals(chunks[0].CachePath, chunks[1].CachePath, StringComparison.OrdinalIgnoreCase),
            "sender-scoped transfers use distinct cache paths");
        var payloads = chunks.Select(item => Convert.ToHexString(File.ReadAllBytes(item.CachePath))).ToHashSet();
        Require(payloads.SetEquals([Convert.ToHexString(bobBytes), Convert.ToHexString(carolBytes)]),
            "sender-scoped cache retains both independent payloads");

        var filesBeforeAttack = Directory.EnumerateFiles(
            Path.Combine(paths.Cache, "transfers"), "*.part", SearchOption.AllDirectories).Count();
        var malloryEnvelope = FileChunkEnvelope(
            native, mallory, receiverContact, groupId, "unauthorized-transfer", [4, 2], 1);
        await ExpectAsync<InvalidDataException>(
            () => engine.ImportEnvelopeAsync(malloryEnvelope.EnvelopeBase64, mallory.KeyId),
            "pending group member chunk authorization rejection");
        Equal(filesBeforeAttack, Directory.EnumerateFiles(
                Path.Combine(paths.Cache, "transfers"), "*.part", SearchOption.AllDirectories).Count(),
            "unauthorized chunk performs no file write");
        Require(engine.State.InboundFileChunks.All(item => item.SenderKeyId != mallory.KeyId),
            "unauthorized chunk creates no state record");

        GroupMemberRecord Member(
            IdentitySummary identity,
            GroupRole role,
            GroupMemberStatus status) => new(
            groupId,
            identity.KeyId,
            identity.DisplayName,
            native.ContactFromIdentity(identity.IdentityJson),
            role,
            status,
            GroupTrustState.Unverified,
            now);
    }

    private static async Task VerifyDeferredCausalMailboxQueueAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary owner,
        IdentitySummary recipient,
        IdentitySummary otherInvitee)
    {
        var ownerState = StateFor(owner);
        ownerState.Contacts.Add(StoredContact.FromSummary(native.ParseContact(
            native.ContactFromIdentity(recipient.IdentityJson))));
        ownerState.Contacts.Add(StoredContact.FromSummary(native.ParseContact(
            native.ContactFromIdentity(otherInvitee.IdentityJson))));
        var ownerStore = new MemoryStateStore(ownerState);
        var ownerPaths = Paths(root, "deferred-mailbox-owner");
        await using var ownerEngine = Engine(native, ownerStore, ownerPaths);
        await ownerEngine.InitializeAsync();

        var recipientState = StateFor(recipient);
        recipientState.Contacts.Add(StoredContact.FromSummary(native.ParseContact(
            native.ContactFromIdentity(owner.IdentityJson))));
        var recipientStore = new MemoryStateStore(recipientState);
        var recipientPaths = Paths(root, "deferred-mailbox-recipient");
        await using var recipientEngine = Engine(native, recipientStore, recipientPaths);
        await recipientEngine.InitializeAsync();

        var created = await ownerEngine.CreateGroupAsync(
            "Deferred causal queue",
            GroupPolicy.Normal,
            [recipient.KeyId, otherInvitee.KeyId]);
        var inviteEvent = ownerEngine.State.GroupEvents.Single(item =>
            item.GroupId == created.Group.GroupId && item.Type == "group_invite");
        var inviteChild = RequireGroupChild(ownerEngine, inviteEvent.EventId, recipient.KeyId);
        await recipientEngine.ImportEnvelopeAsync(inviteChild.EnvelopeBase64, owner.KeyId);
        await recipientEngine.AcceptGroupInviteAsync(created.Group.GroupId);
        var acceptanceEvent = recipientEngine.State.GroupEvents.Single(item =>
            item.GroupId == created.Group.GroupId && item.Type == "member_accepted");
        var acceptanceChild = RequireGroupChild(recipientEngine, acceptanceEvent.EventId, owner.KeyId);
        await ownerEngine.ImportEnvelopeAsync(acceptanceChild.EnvelopeBase64, recipient.KeyId);

        await ownerEngine.RenameGroupAsync(created.Group.GroupId, "Causal predecessor");
        var renameEvent = ownerEngine.State.GroupEvents.Single(item =>
            item.GroupId == created.Group.GroupId && item.Type == "group_renamed");
        var renameChild = RequireGroupChild(ownerEngine, renameEvent.EventId, recipient.KeyId);
        await ownerEngine.UpdateGroupAvatarAsync(created.Group.GroupId, "future-avatar");
        var avatarEvent = ownerEngine.State.GroupEvents.Single(item =>
            item.GroupId == created.Group.GroupId && item.Type == "group_avatar_updated");
        var avatarChild = RequireGroupChild(ownerEngine, avatarEvent.EventId, recipient.KeyId);

        var futureError = await CaptureAsync<InvalidDataException>(
            () => recipientEngine.ImportEnvelopeAsync(avatarChild.EnvelopeBase64, owner.KeyId),
            "future group epoch is deferred before replay counter consumption");
        var classification = Classify(futureError);
        Require(!classification.Permanent && classification.ReasonCode == "missing_prerequisite",
            "future epoch is classified as a durable causal prerequisite");
        var mailboxEnvelopeId = $"mailbox-{avatarChild.EnvelopeId}";
        await using var server = new MailboxTestServer();
        server.SetEnvelopes([
            new MailboxEnvelopeDto(
                mailboxEnvelopeId,
                owner.KeyId,
                recipient.KeyId,
                avatarChild.EnvelopeBase64,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                DateTimeOffset.UtcNow.AddDays(1).ToUnixTimeMilliseconds()),
        ]);
        await recipientEngine.UpdateSettingsAsync(recipientEngine.State.Settings with
        {
            SyncServiceUrl = server.BaseUrl,
        });
        var firstSync = await recipientEngine.SynchronizeAsync();
        Equal(1, firstSync.Acknowledged,
            "authenticated future-epoch item is ACKed only after raw deferred persistence");
        Require(server.AcknowledgedEnvelopeIds.Contains(mailboxEnvelopeId),
            "future-epoch mailbox item no longer blocks the oldest mailbox page");
        var durableDeferred = recipientStore.Snapshot.DeferredMailboxEnvelopes.Single(item =>
            item.EnvelopeId == mailboxEnvelopeId);
        Equal(avatarChild.EnvelopeBase64, durableDeferred.EnvelopeBase64,
            "causal deferred queue durably retains the authenticated raw envelope");

        await recipientEngine.ImportEnvelopeAsync(renameChild.EnvelopeBase64, owner.KeyId);
        await recipientEngine.SynchronizeAsync();
        Equal("future-avatar", recipientEngine.State.RequireGroup(created.Group.GroupId).AvatarSeed,
            "deferred future event imports after its predecessor arrives");
        Require(recipientEngine.State.DeferredMailboxEnvelopes.All(item =>
                item.EnvelopeId != mailboxEnvelopeId),
            "successful causal retry removes the raw deferred body");
        Require(recipientStore.Snapshot.DeferredMailboxEnvelopes.All(item =>
                item.EnvelopeId != mailboxEnvelopeId),
            "successful causal retry removal is durable");
    }

    private static PendingEnvelopeRecord RequireGroupChild(
        EnvelopeClientEngine engine,
        string eventId,
        string recipientKeyId) =>
        engine.State.PendingEnvelopes.Single(item =>
            item.LogicalMessageId == $"group-event:{eventId}" &&
            item.RecipientKeyId == recipientKeyId);

    private static (bool Permanent, string ReasonCode, string Detail) Classify(Exception error)
    {
        var method = typeof(EnvelopeClientEngine).GetMethod(
            "TryClassifyPermanentMailboxPoison",
            BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new MissingMethodException("Mailbox poison classifier was not found.");
        object?[] arguments = [error, null];
        var permanent = (bool)(method.Invoke(null, arguments)
            ?? throw new InvalidOperationException("Mailbox classifier returned null."));
        var classification = ((string ReasonCode, string Detail))arguments[1]!;
        return (permanent, classification.ReasonCode, classification.Detail);
    }


    private static async Task VerifyCompletedTransferCleanupRecoveryAsync(string root)
    {
        const string sender = "sender-cleanup";
        const string conversation = "grp-cleanup";
        const string transfer = "cleanup-transfer";
        var paths = Paths(root, "cleanup-recovery");
        var namespaceDirectory = TransferCacheNamespace(sender, conversation, transfer);
        var cacheDirectory = Path.Combine(paths.Cache, "transfers", namespaceDirectory);
        Directory.CreateDirectory(cacheDirectory);
        var partPath = Path.Combine(cacheDirectory, "000000.part");
        await File.WriteAllBytesAsync(partPath, [1, 2, 3]);
        var completedPath = Path.Combine(paths.Received, "complete.bin");
        await File.WriteAllBytesAsync(completedPath, [1, 2, 3]);
        var state = new WindowsClientState();
        state.Validate();
        state.InboundFileTransfers.Add(new InboundFileTransferRecord(
            transfer,
            conversation,
            sender,
            "complete.bin",
            "application/test",
            3,
            FileTransferService.DefaultChunkBytes,
            1,
            EncodeBase64Url(SHA256.HashData(new byte[] { 1, 2, 3 })),
            [EncodeBase64Url(SHA256.HashData(new byte[] { 1, 2, 3 }))],
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            completedPath,
            CleanupPending: true));
        state.InboundFileChunks.Add(new InboundFileChunkRecord(
            transfer,
            0,
            EncodeBase64Url(SHA256.HashData(new byte[] { 1, 2, 3 })),
            partPath,
            3,
            sender,
            1,
            conversation));
        var store = new MemoryStateStore(state);
        await using var engine = Engine(new EnvelopeNativeClient(), store, paths);
        await engine.InitializeAsync();
        Require(!File.Exists(partPath), "startup resumes cleanup after completed-path persistence crash point");
        Equal(0, engine.State.InboundFileChunks.Count, "resumed completion removes durable chunk metadata");
        Require(!engine.State.InboundFileTransfers.Single().CleanupPending,
            "resumed completion clears cleanup-pending only after deletion");
        Require(File.Exists(completedPath), "resumed cleanup preserves completed output");

        File.SetAttributes(completedPath, FileAttributes.ReadOnly);
        try
        {
            await engine.ClearFileCacheAsync();
            Require(File.Exists(completedPath) && engine.State.InboundFileTransfers.Count == 1,
                "failed cache deletion retains completed transfer state");
        }
        finally
        {
            if (File.Exists(completedPath)) File.SetAttributes(completedPath, FileAttributes.Normal);
        }
        await engine.ClearFileCacheAsync();
        Require(!File.Exists(completedPath) && engine.State.InboundFileTransfers.Count == 0,
            "successful cache deletion clears completed transfer state");
    }

    private static async Task VerifyInboundChunkCacheLimitsAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver,
        IdentitySummary sender)
    {
        var receiverContact = native.ContactFromIdentity(receiver.IdentityJson);
        var senderContact = native.ParseContact(native.ContactFromIdentity(sender.IdentityJson));
        var state = StateFor(receiver);
        state.Contacts.Add(StoredContact.FromSummary(senderContact));
        var paths = Paths(root, "inbound-chunk-quota");
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        for (var index = 0; index < EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender; index++)
        {
            var transferId = $"quota-transfer-{index:D2}";
            var directory = Path.Combine(
                paths.Cache,
                "transfers",
                TransferCacheNamespace(sender.KeyId, sender.KeyId, transferId));
            Directory.CreateDirectory(directory);
            var cachePath = Path.Combine(directory, "000000.part");
            await File.WriteAllBytesAsync(cachePath, [(byte)index]);
            state.InboundFileChunks.Add(new InboundFileChunkRecord(
                transferId,
                0,
                EncodeBase64Url(SHA256.HashData([(byte)index])),
                cachePath,
                1,
                sender.KeyId,
                1,
                sender.KeyId,
                now));
        }

        var store = new MemoryStateStore(state);
        await using (var engine = Engine(native, store, paths))
        {
            await engine.InitializeAsync();
            const string rejectedTransfer = "quota-transfer-rejected";
            var rejectedDirectory = Path.Combine(
                paths.Cache,
                "transfers",
                TransferCacheNamespace(sender.KeyId, sender.KeyId, rejectedTransfer));
            var envelope = FileChunkEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                rejectedTransfer,
                [42],
                1);
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(envelope.EnvelopeBase64, sender.KeyId),
                "pre-manifest chunks enforce per-sender transfer-count quota");
            Require(!Directory.Exists(rejectedDirectory),
                "transfer-count quota rejects before creating a cache directory");
            Require(engine.State.ReceivedCounters.All(item =>
                    item.SenderKeyId != sender.KeyId || item.MessageCounter != 1),
                "quota rejection does not consume the inbound replay counter");

            engine.State.InboundFileChunks.Clear();
            var existingTransfer = "quota-byte-existing";
            var existingDirectory = Path.Combine(
                paths.Cache,
                "transfers",
                TransferCacheNamespace(sender.KeyId, sender.KeyId, existingTransfer));
            Directory.CreateDirectory(existingDirectory);
            var existingPath = Path.Combine(existingDirectory, "000000.part");
            await File.WriteAllBytesAsync(existingPath, [1]);
            engine.State.InboundFileChunks.Add(new InboundFileChunkRecord(
                existingTransfer,
                0,
                EncodeBase64Url(SHA256.HashData(new byte[] { 1 })),
                existingPath,
                checked((int)EnvelopeClientEngine.MaximumInboundChunkCacheBytesPerSender),
                sender.KeyId,
                1,
                sender.KeyId,
                now));
            const string byteRejectedTransfer = "quota-byte-rejected";
            var byteRejectedDirectory = Path.Combine(
                paths.Cache,
                "transfers",
                TransferCacheNamespace(sender.KeyId, sender.KeyId, byteRejectedTransfer));
            var byteEnvelope = FileChunkEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                byteRejectedTransfer,
                [43],
                2);
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(byteEnvelope.EnvelopeBase64, sender.KeyId),
                "pre-manifest chunks enforce per-sender byte quota");
            Require(!Directory.Exists(byteRejectedDirectory),
                "byte quota rejects before writing any new chunk bytes");
        }

        var expiryPaths = Paths(root, "inbound-chunk-expiry");
        var expiryState = StateFor(receiver);
        var expiredTransfer = "expired-pre-manifest";
        var expiredDirectory = Path.Combine(
            expiryPaths.Cache,
            "transfers",
            TransferCacheNamespace(sender.KeyId, sender.KeyId, expiredTransfer));
        Directory.CreateDirectory(expiredDirectory);
        var expiredPath = Path.Combine(expiredDirectory, "000000.part");
        await File.WriteAllBytesAsync(expiredPath, [9]);
        var orphanPartialPath = Path.Combine(expiredDirectory, $"000001.part.partial-{Guid.NewGuid():N}");
        await File.WriteAllBytesAsync(orphanPartialPath, [8]);
        var orphanCompletePath = Path.Combine(
            expiryPaths.Cache,
            "transfers",
            $"complete-orphan-{Guid.NewGuid():N}.tmp");
        await File.WriteAllBytesAsync(orphanCompletePath, [7]);
        var expiredAt = now - (long)EnvelopeClientEngine.InboundChunkCacheRetention.TotalMilliseconds - 1;
        expiryState.InboundFileChunks.Add(new InboundFileChunkRecord(
            expiredTransfer,
            0,
            EncodeBase64Url(SHA256.HashData(new byte[] { 9 })),
            expiredPath,
            1,
            sender.KeyId,
            1,
            sender.KeyId,
            expiredAt));
        const string expiredManifestTransfer = "expired-manifest-only";
        var emptyHash = EncodeBase64Url(SHA256.HashData(Array.Empty<byte>()));
        expiryState.InboundFileTransfers.Add(new InboundFileTransferRecord(
            expiredManifestTransfer,
            sender.KeyId,
            sender.KeyId,
            "expired.bin",
            "application/test",
            0,
            FileTransferService.DefaultChunkBytes,
            1,
            emptyHash,
            [emptyHash],
            expiredAt));
        expiryState.Messages.Add(new ChatMessageRecord(
            "expired-manifest-envelope",
            sender.KeyId,
            MessageDirection.Incoming,
            sender.KeyId,
            "Sender",
            expiredAt,
            99,
            "等待文件分片：expired.bin",
            string.Empty,
            DeliveryState.Received,
            IsHidden: true,
            LogicalMessageId: $"inbound-file:{sender.KeyId}:{sender.KeyId}:{expiredManifestTransfer}"));
        var expiryStore = new MemoryStateStore(expiryState);
        await using (var expiryEngine = Engine(native, expiryStore, expiryPaths))
        {
            await expiryEngine.InitializeAsync();
            Require(!File.Exists(expiredPath) && expiryEngine.State.InboundFileChunks.Count == 0,
                "startup prunes expired pre-manifest chunk bytes and metadata");
            Require(!File.Exists(orphanPartialPath) && !File.Exists(orphanCompletePath),
                "startup prunes crash-orphan partial and completion plaintext");
            Require(expiryStore.Snapshot.InboundFileChunks.Count == 0,
                "expired chunk pruning is persisted durably");
            Require(expiryEngine.State.InboundFileTransfers.All(item =>
                        item.TransferId != expiredManifestTransfer) &&
                    expiryEngine.State.Messages.All(item =>
                        item.LogicalMessageId !=
                        $"inbound-file:{sender.KeyId}:{sender.KeyId}:{expiredManifestTransfer}"),
                "expired manifest-only transfer and hidden progress row are pruned together");
        }
    }

    private static async Task VerifyManifestOnlyTransferLimitsAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver,
        IdentitySummary sender)
    {
        var receiverContact = native.ContactFromIdentity(receiver.IdentityJson);
        var senderContact = native.ParseContact(native.ContactFromIdentity(sender.IdentityJson));
        var countState = StateFor(receiver);
        countState.Contacts.Add(StoredContact.FromSummary(senderContact));
        var countStore = new MemoryStateStore(countState);
        var countPaths = Paths(root, "manifest-only-count-quota");
        await using (var engine = Engine(native, countStore, countPaths))
        {
            await engine.InitializeAsync();
            for (var index = 0; index < EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender; index++)
            {
                var envelope = FileManifestEnvelope(
                    native,
                    sender,
                    receiverContact,
                    sender.KeyId,
                    $"manifest-only-{index:D2}",
                    totalSize: 0,
                    counter: checked((ulong)(index + 1)));
                await engine.ImportEnvelopeAsync(envelope.EnvelopeBase64, sender.KeyId);
            }
            Equal(EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender,
                engine.State.InboundFileTransfers.Count,
                "legal manifest-only transfers reach the explicit per-sender limit");
            Equal(EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender,
                engine.State.Messages.Count(message => message.IsHidden),
                "manifest-only progress state remains bounded with its transfers");

            var rejected = FileManifestEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                "manifest-only-over-limit",
                totalSize: 0,
                counter: checked((ulong)(EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender + 1)));
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(rejected.EnvelopeBase64, sender.KeyId),
                "manifest-only transfer count is checked before state mutation");
            Equal(EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender,
                engine.State.InboundFileTransfers.Count,
                "rejected manifest creates no transfer state");
            Require(engine.State.Messages.All(message => message.EnvelopeId != rejected.EnvelopeId) &&
                    engine.State.ReceivedCounters.All(counter =>
                        counter.SenderKeyId != sender.KeyId ||
                        counter.MessageCounter !=
                        (ulong)(EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender + 1)),
                "rejected manifest creates no hidden row and consumes no replay counter");
        }

        var byteState = StateFor(receiver);
        byteState.Contacts.Add(StoredContact.FromSummary(senderContact));
        var byteStore = new MemoryStateStore(byteState);
        var bytePaths = Paths(root, "manifest-only-byte-quota");
        await using (var engine = Engine(native, byteStore, bytePaths))
        {
            await engine.InitializeAsync();
            var maximumReservation = FileManifestEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                "manifest-byte-maximum",
                EnvelopeClientEngine.MaximumInboundChunkCacheBytesPerSender,
                1);
            await engine.ImportEnvelopeAsync(maximumReservation.EnvelopeBase64, sender.KeyId);
            var oneMoreByte = FileManifestEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                "manifest-byte-over-limit",
                1,
                2);
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(oneMoreByte.EnvelopeBase64, sender.KeyId),
                "manifest declared bytes reserve the per-sender incomplete-transfer budget");
            Equal(1, engine.State.InboundFileTransfers.Count,
                "byte-budget rejection leaves only the original manifest reservation");
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var placeholderHash = EncodeBase64Url(SHA256.HashData(Array.Empty<byte>()));
        var globalCountState = StateFor(receiver);
        globalCountState.Contacts.Add(StoredContact.FromSummary(senderContact));
        for (var index = 0; index < EnvelopeClientEngine.MaximumInboundPendingTransfers; index++)
        {
            var syntheticSender = $"quota-sender-{index / EnvelopeClientEngine.MaximumInboundPendingTransfersPerSender:D2}";
            globalCountState.InboundFileTransfers.Add(new InboundFileTransferRecord(
                $"global-count-{index:D3}",
                syntheticSender,
                syntheticSender,
                $"global-count-{index:D3}.bin",
                "application/test",
                0,
                FileTransferService.DefaultChunkBytes,
                1,
                placeholderHash,
                [placeholderHash],
                now));
        }
        var globalCountStore = new MemoryStateStore(globalCountState);
        var globalCountPaths = Paths(root, "manifest-global-count-quota");
        await using (var engine = Engine(native, globalCountStore, globalCountPaths))
        {
            await engine.InitializeAsync();
            var rejected = FileManifestEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                "global-count-over-limit",
                0,
                1);
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(rejected.EnvelopeBase64, sender.KeyId),
                "manifest-only transfers enforce the global union count limit");
            Equal(EnvelopeClientEngine.MaximumInboundPendingTransfers,
                engine.State.InboundFileTransfers.Count,
                "global count rejection occurs before manifest state mutation");
        }

        var globalByteState = StateFor(receiver);
        globalByteState.Contacts.Add(StoredContact.FromSummary(senderContact));
        var reservationCount = checked((int)(EnvelopeClientEngine.MaximumInboundChunkCacheBytes /
                                             EnvelopeClientEngine.MaximumInboundChunkCacheBytesPerSender));
        for (var index = 0; index < reservationCount; index++)
        {
            var syntheticSender = $"byte-sender-{index:D2}";
            globalByteState.InboundFileTransfers.Add(new InboundFileTransferRecord(
                $"global-byte-{index:D2}",
                syntheticSender,
                syntheticSender,
                $"global-byte-{index:D2}.bin",
                "application/test",
                EnvelopeClientEngine.MaximumInboundChunkCacheBytesPerSender,
                FileTransferService.DefaultChunkBytes,
                MaximumOnlineChunkCountForTest(),
                placeholderHash,
                Enumerable.Repeat(placeholderHash, MaximumOnlineChunkCountForTest()).ToArray(),
                now));
        }
        var globalByteStore = new MemoryStateStore(globalByteState);
        var globalBytePaths = Paths(root, "manifest-global-byte-quota");
        await using (var engine = Engine(native, globalByteStore, globalBytePaths))
        {
            await engine.InitializeAsync();
            var rejected = FileManifestEnvelope(
                native,
                sender,
                receiverContact,
                sender.KeyId,
                "global-byte-over-limit",
                1,
                1);
            await ExpectAsync<InvalidDataException>(
                () => engine.ImportEnvelopeAsync(rejected.EnvelopeBase64, sender.KeyId),
                "manifest declared bytes enforce the global union byte limit");
            Equal(reservationCount, engine.State.InboundFileTransfers.Count,
                "global byte rejection occurs before manifest state mutation");
        }

        static int MaximumOnlineChunkCountForTest() => checked((int)(
            EnvelopeClientEngine.MaximumInboundChunkCacheBytesPerSender /
            FileTransferService.DefaultChunkBytes));
    }

    private static async Task VerifyInboundFilePersistenceRollbackAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary receiver,
        IdentitySummary sender)
    {
        var receiverContact = native.ContactFromIdentity(receiver.IdentityJson);
        var senderContact = native.ParseContact(native.ContactFromIdentity(sender.IdentityJson));
        var state = StateFor(receiver);
        state.Contacts.Add(StoredContact.FromSummary(senderContact));
        var store = new MemoryStateStore(state);
        var paths = Paths(root, "inbound-file-rollback");
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();

        var generic = native.EncryptOpaqueFile(
            sender.IdentityJson,
            receiverContact,
            "generic-final.bin",
            "application/octet-stream",
            [5, 4, 3, 2, 1],
            1);
        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.ImportEnvelopeAsync(generic.EnvelopeBase64, sender.KeyId),
            "generic inbound final rolls back when state persistence fails");
        Require(!Directory.EnumerateFiles(paths.Received).Any(),
            "generic inbound persistence failure leaves no orphan final file");
        Require(engine.State.Messages.All(item => item.EnvelopeId != generic.EnvelopeId) &&
                engine.State.ReceivedCounters.All(item =>
                    item.SenderKeyId != sender.KeyId || item.MessageCounter != 1),
            "generic inbound persistence failure restores message and replay state");
        var genericRetry = await engine.ImportEnvelopeAsync(generic.EnvelopeBase64, sender.KeyId);
        Require(genericRetry.Message.AttachmentPath is { } genericPath && File.Exists(genericPath),
            "generic inbound can retry successfully after durable-store recovery");

        const string transferId = "persist-failure-transfer";
        var bytes = new byte[] { 8, 6, 7, 5, 3, 0, 9 };
        var chunkHash = EncodeBase64Url(SHA256.HashData(bytes));
        var chunkPayload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_chunk",
            ["transfer_id"] = transferId,
            ["conversation_id"] = sender.KeyId,
            ["chunk_index"] = 0,
            ["chunk_count"] = 1,
            ["chunk_sha256"] = chunkHash,
            ["data_b64"] = EncodeBase64Url(bytes),
        });
        var chunk = native.EncryptOpaqueFile(
            sender.IdentityJson,
            receiverContact,
            "persist.part",
            EnvelopeClientEngine.FileChunkMime,
            chunkPayload,
            2);
        await engine.ImportEnvelopeAsync(chunk.EnvelopeBase64, sender.KeyId);
        var cachedPart = engine.State.InboundFileChunks.Single(item => item.TransferId == transferId).CachePath;
        Require(File.Exists(cachedPart), "pre-manifest chunk is durably cached");
        var progressMessage = engine.State.Messages.Single(item => item.EnvelopeId == chunk.EnvelopeId);
        Require(progressMessage.IsHidden && progressMessage.OpaqueEnvelopeBase64.Length == 0,
            "inbound file progress keeps no large opaque envelope body");

        var manifestPayload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_manifest",
            ["transfer_id"] = transferId,
            ["conversation_id"] = sender.KeyId,
            ["filename"] = "completed-after-retry.bin",
            ["mime"] = "application/test",
            ["total_size"] = bytes.LongLength,
            ["chunk_size"] = FileTransferService.DefaultChunkBytes,
            ["chunk_count"] = 1,
            ["file_sha256"] = chunkHash,
            ["chunk_sha256"] = new[] { chunkHash },
        });
        var manifest = native.EncryptOpaqueFile(
            sender.IdentityJson,
            receiverContact,
            "persist.manifest.json",
            EnvelopeClientEngine.FileManifestMime,
            manifestPayload,
            3);
        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.ImportEnvelopeAsync(manifest.EnvelopeBase64, sender.KeyId),
            "completed transfer final rolls back when state persistence fails");
        Require(!Directory.EnumerateFiles(paths.Received)
                .Any(path => Path.GetFileName(path).StartsWith("completed-after-retry", StringComparison.Ordinal)),
            "completed transfer persistence failure removes unreferenced final");
        Require(File.Exists(cachedPart) && engine.State.InboundFileChunks.Any(item =>
                item.TransferId == transferId && item.CachePath == cachedPart),
            "completed transfer rollback preserves previously durable chunk for retry");
        Require(engine.State.ReceivedCounters.All(item =>
                item.SenderKeyId != sender.KeyId || item.MessageCounter != 3),
            "completed transfer persistence failure restores manifest replay counter");

        var completedRetry = await engine.ImportEnvelopeAsync(manifest.EnvelopeBase64, sender.KeyId);
        Require(completedRetry.Message.AttachmentPath is { } completedPath && File.Exists(completedPath),
            "completed transfer retries successfully after persistence recovery");
        Require(completedRetry.Message.OpaqueEnvelopeBase64.Length == 0 &&
                engine.State.Messages.Count(item => item.IsHidden &&
                    item.LogicalMessageId == completedRetry.Message.LogicalMessageId) == 0,
            "completed inbound file drops hidden progress rows and opaque bodies");
        Require(!File.Exists(cachedPart) && engine.State.InboundFileChunks.All(item => item.TransferId != transferId),
            "completed transfer clears chunks only after durable completed state");

        const string largeTransferId = "large-vault-progress";
        for (var index = 0; index < 2; index++)
        {
            var largeChunkBytes = new byte[2 * 1024 * 1024];
            RandomNumberGenerator.Fill(largeChunkBytes);
            var largeChunkHash = EncodeBase64Url(SHA256.HashData(largeChunkBytes));
            var largeChunkPayload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["kind"] = "file_chunk",
                ["transfer_id"] = largeTransferId,
                ["conversation_id"] = sender.KeyId,
                ["chunk_index"] = index,
                ["chunk_count"] = 2,
                ["chunk_sha256"] = largeChunkHash,
                ["data_b64"] = EncodeBase64Url(largeChunkBytes),
            });
            var largeChunk = native.EncryptOpaqueFile(
                sender.IdentityJson,
                receiverContact,
                $"large-{index}.part",
                EnvelopeClientEngine.FileChunkMime,
                largeChunkPayload,
                checked((ulong)(4 + index)));
            await engine.ImportEnvelopeAsync(largeChunk.EnvelopeBase64, sender.KeyId);
        }
        var largeLogicalId = $"inbound-file:{sender.KeyId}:{sender.KeyId}:{largeTransferId}";
        var largeProgress = engine.State.Messages.Where(item =>
            item.IsHidden && item.LogicalMessageId == largeLogicalId).ToArray();
        Equal(1, largeProgress.Length, "multi-chunk inbound file retains at most one hidden progress row");
        Equal(string.Empty, largeProgress[0].OpaqueEnvelopeBase64,
            "multi-MiB inbound chunks never persist opaque envelope bodies");
        Require(JsonSerializer.Serialize(engine.State).Length < 512 * 1024,
            "multi-MiB inbound progress keeps the persisted vault lightweight");
    }

    private static async Task VerifyIdentityPlaintextCleanupAsync(
        string root,
        EnvelopeNativeClient native,
        IdentitySummary alice,
        RecoveryPhrase bobPhrase)
    {
        var paths = Paths(root, "identity-cleanup");
        var received = Path.Combine(paths.Received, "old-received.bin");
        var sealedFile = Path.Combine(paths.Sealed, "old-sealed.envelope");
        var transferDirectory = Path.Combine(paths.Cache, "transfers", "managed-transfer");
        var transferPart = Path.Combine(transferDirectory, "000000.part");
        var transferPartial = Path.Combine(transferDirectory, $"000001.part.partial-{Guid.NewGuid():N}");
        Directory.CreateDirectory(transferDirectory);
        await File.WriteAllBytesAsync(received, [1]);
        await File.WriteAllBytesAsync(sealedFile, [2]);
        await File.WriteAllBytesAsync(transferPart, [3]);
        var initialState = StateFor(alice);
        initialState.Settings = initialState.Settings with { LocalLockEnabled = true };
        var store = new MemoryStateStore(initialState);
        await using var engine = Engine(native, store, paths);
        await engine.InitializeAsync();
        await File.WriteAllBytesAsync(transferPartial, [4]);

        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.RestoreIdentityAsync("Bob", bobPhrase.Value, replaceExisting: true),
            "identity replacement rolls managed plaintext back when state save fails");
        Equal(alice.KeyId, engine.State.Identity?.KeyId,
            "failed identity replacement restores the previous in-memory state");
        Require(File.Exists(received) && File.Exists(sealedFile) &&
                File.Exists(transferPart) && File.Exists(transferPartial),
            "failed identity replacement restores every managed plaintext file");
        var transitionRoot = Path.Combine(paths.Cache, "identity-transitions");
        Require(!Directory.Exists(transitionRoot) ||
                !Directory.EnumerateFileSystemEntries(transitionRoot).Any(),
            "failed identity replacement leaves no rollback quarantine body");

        File.SetAttributes(received, FileAttributes.ReadOnly);
        try
        {
            await ExpectAsync<UnauthorizedAccessException>(
                () => engine.RestoreIdentityAsync("Bob", bobPhrase.Value, replaceExisting: true),
                "identity replacement is blocked when managed plaintext deletion fails");
            Equal(alice.KeyId, engine.State.Identity?.KeyId, "failed cleanup preserves old identity state");
        }
        finally
        {
            if (File.Exists(received)) File.SetAttributes(received, FileAttributes.Normal);
        }

        var bob = await engine.RestoreIdentityAsync("Bob", bobPhrase.Value, replaceExisting: true);
        Require(bob.KeyId != alice.KeyId, "identity replacement succeeds after plaintext cleanup becomes possible");
        Require(!File.Exists(received) && !File.Exists(sealedFile) &&
                !File.Exists(transferPart) && !File.Exists(transferPartial),
            "identity replacement removes received, sealed, and transfer plaintext");

        var bobBackup = await engine.ExportLocalBackupAsync(bobPhrase.Value);
        var beforeBackupRestoreFailure = Path.Combine(paths.Received, "before-backup-restore-failure.bin");
        await File.WriteAllBytesAsync(beforeBackupRestoreFailure, [6, 5, 4]);
        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.RestoreLocalBackupAsync(bobPhrase.Value, bobBackup),
            "portable restore rolls managed plaintext back when state save fails");
        Require(File.Exists(beforeBackupRestoreFailure) &&
                (await File.ReadAllBytesAsync(beforeBackupRestoreFailure)).SequenceEqual(new byte[] { 6, 5, 4 }),
            "failed portable restore restores the previous managed plaintext bytes");
        Equal(bob.KeyId, engine.State.Identity?.KeyId,
            "failed portable restore restores the previous identity state");

        var aliceContact = native.ContactFromIdentity(alice.IdentityJson);
        await engine.ImportContactAsync(aliceContact);
        var beforeSameIdentityRestore = await engine.SendTextAsync(
            alice.KeyId,
            "counter before same-identity restore");
        var bobContact = native.ContactFromIdentity(bob.IdentityJson);
        var oldInbound = native.EncryptOpaqueText(
            alice.IdentityJson,
            bobContact,
            "inbound before clear",
            77);
        await engine.ImportEnvelopeAsync(oldInbound.EnvelopeBase64, alice.KeyId);
        var nextBeforeSameIdentityRestore = engine.State.NextMessageCounter;
        var namespaceBeforeSameIdentityRestore = engine.State.CounterNamespace;
        await engine.RestoreIdentityAsync("Bob", bobPhrase.Value, replaceExisting: true);
        Equal(namespaceBeforeSameIdentityRestore, engine.State.CounterNamespace,
            "same-identity phrase restore preserves outbound counter namespace");
        Equal(nextBeforeSameIdentityRestore, engine.State.NextMessageCounter,
            "same-identity phrase restore preserves outbound high-water");
        Require(engine.State.PendingEnvelopes.Any(item =>
                item.EnvelopeId == beforeSameIdentityRestore.EnvelopeId),
            "same-identity phrase restore preserves durable outbox children");
        Require(engine.State.ReceivedCounters.Any(item =>
                item.SenderKeyId == alice.KeyId && item.MessageCounter == 77),
            "same-identity phrase restore preserves inbound replay state");
        await engine.ImportContactAsync(aliceContact);
        var afterSameIdentityRestore = await engine.SendTextAsync(
            alice.KeyId,
            "counter after same-identity restore");
        Require(afterSameIdentityRestore.MessageCounter != beforeSameIdentityRestore.MessageCounter &&
                WindowsClientState.CounterSequence(afterSameIdentityRestore.MessageCounter) >
                WindowsClientState.CounterSequence(beforeSameIdentityRestore.MessageCounter),
            "same-identity phrase restore never reuses outbound message counter");
        var messageCountBeforeReplay = engine.State.Messages.Count;
        var restoredDuplicate = await engine.ImportEnvelopeAsync(oldInbound.EnvelopeBase64, alice.KeyId);
        Require(restoredDuplicate.Duplicate && engine.State.Messages.Count == messageCountBeforeReplay,
            "same-identity phrase restore returns durable result without reapplying received envelope");

        await File.WriteAllBytesAsync(Path.Combine(paths.Received, "before-clear.bin"), [4]);
        var namespaceBeforeClear = engine.State.CounterNamespace;
        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.ClearIdentityAsync(),
            "clear identity rolls managed plaintext back when state save fails");
        Require(engine.State.Identity?.KeyId == bob.KeyId &&
                File.Exists(Path.Combine(paths.Received, "before-clear.bin")),
            "failed clear restores identity and managed plaintext");
        await engine.ClearIdentityAsync();
        Require(engine.State.Identity is null, "clear identity removes identity state");
        Require(engine.State.Settings.LocalLockEnabled,
            "clear identity preserves device-local Windows Hello policy");
        Require(engine.State.CounterNamespace != namespaceBeforeClear,
            "clear identity rotates the outbound counter namespace");
        Require(!Directory.EnumerateFiles(paths.Received).Any(),
            "clear identity removes managed received plaintext");

        await engine.RestoreIdentityAsync("Bob", bobPhrase.Value, replaceExisting: false);
        Require(engine.State.CounterNamespace != namespaceBeforeClear,
            "same phrase after clear cannot return to the old outbound counter lane");
        await engine.ImportContactAsync(aliceContact);
        await ExpectAsync<CryptographicException>(
            () => engine.ImportEnvelopeAsync(oldInbound.EnvelopeBase64, alice.KeyId),
            "device-local recipient replay archive survives clear and same-phrase restore");
        await engine.ClearIdentityAsync();
    }

    private static bool ClassifyPermanent(Exception error)
    {
        var method = typeof(EnvelopeClientEngine).GetMethod(
            "TryClassifyPermanentMailboxPoison",
            BindingFlags.Static | BindingFlags.NonPublic)
            ?? throw new MissingMethodException("Mailbox poison classifier was not found.");
        object?[] arguments = [error, null];
        return (bool)(method.Invoke(null, arguments)
            ?? throw new InvalidOperationException("Mailbox classifier returned null."));
    }

    private static OutboundOpaquePayloadSummary FileChunkEnvelope(
        EnvelopeNativeClient native,
        IdentitySummary sender,
        string receiverContact,
        string groupId,
        string transferId,
        byte[] bytes,
        ulong counter)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_chunk",
            ["transfer_id"] = transferId,
            ["conversation_id"] = groupId,
            ["group_id"] = groupId,
            ["chunk_index"] = 0,
            ["chunk_count"] = 1,
            ["chunk_sha256"] = EncodeBase64Url(SHA256.HashData(bytes)),
            ["data_b64"] = EncodeBase64Url(bytes),
        });
        return native.EncryptOpaqueFile(
            sender.IdentityJson,
            receiverContact,
            "chunk.part",
            EnvelopeClientEngine.FileChunkMime,
            payload,
            counter);
    }

    private static OutboundOpaquePayloadSummary FileManifestEnvelope(
        EnvelopeNativeClient native,
        IdentitySummary sender,
        string receiverContact,
        string conversationId,
        string transferId,
        long totalSize,
        ulong counter)
    {
        var chunkSize = FileTransferService.DefaultChunkBytes;
        var chunkCount = totalSize == 0
            ? 1
            : checked((int)((totalSize + chunkSize - 1) / chunkSize));
        var placeholderHash = EncodeBase64Url(SHA256.HashData(Array.Empty<byte>()));
        var payload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_manifest",
            ["transfer_id"] = transferId,
            ["conversation_id"] = conversationId,
            ["filename"] = $"{transferId}.bin",
            ["mime"] = "application/test",
            ["total_size"] = totalSize,
            ["chunk_size"] = chunkSize,
            ["chunk_count"] = chunkCount,
            ["file_sha256"] = placeholderHash,
            ["chunk_sha256"] = Enumerable.Repeat(placeholderHash, chunkCount).ToArray(),
        });
        return native.EncryptOpaqueFile(
            sender.IdentityJson,
            receiverContact,
            $"{transferId}.manifest.json",
            EnvelopeClientEngine.FileManifestMime,
            payload,
            counter);
    }

    private static WindowsClientState StateFor(IdentitySummary identity)
    {
        var state = new WindowsClientState { Identity = SecureIdentityRecord.FromSummary(identity) };
        state.Validate();
        return state;
    }

    private static EnvelopePaths Paths(string root, string name)
    {
        var paths = new EnvelopePaths(
            Path.Combine(root, name, "profile"),
            Path.Combine(root, name, "local"));
        paths.EnsureCreated();
        return paths;
    }

    private static EnvelopeClientEngine Engine(
        IEnvelopeNativeClient native,
        IClientStateStore store,
        EnvelopePaths paths) => new(
        native,
        store,
        paths,
        new DiagnosticLogService(paths.Logs));

    private static string TransferCacheNamespace(string sender, string conversation, string transfer) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
                $"{sender}\n{conversation}\n{transfer}")))
            .ToLowerInvariant();

    private static string EncodeBase64Url(ReadOnlySpan<byte> bytes) =>
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

    private static async Task<T> CaptureAsync<T>(Func<Task> action, string label) where T : Exception
    {
        try
        {
            await action();
        }
        catch (T error)
        {
            return error;
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

    private sealed class MailboxTestServer : IAsyncDisposable
    {
        private readonly object _sync = new();
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _shutdown = new();
        private readonly Task _acceptLoop;
        private List<MailboxEnvelopeDto> _envelopes = [];
        private readonly HashSet<string> _acknowledged = new(StringComparer.Ordinal);

        public MailboxTestServer()
        {
            _listener.Start();
            BaseUrl = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/";
            _acceptLoop = AcceptLoopAsync();
        }

        public string BaseUrl { get; }

        public IReadOnlySet<string> AcknowledgedEnvelopeIds
        {
            get
            {
                lock (_sync) return _acknowledged.ToHashSet(StringComparer.Ordinal);
            }
        }

        public void SetEnvelopes(IEnumerable<MailboxEnvelopeDto> envelopes)
        {
            lock (_sync) _envelopes = envelopes.ToList();
        }

        private async Task AcceptLoopAsync()
        {
            while (!_shutdown.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = await _listener.AcceptTcpClientAsync(_shutdown.Token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                _ = HandleClientAsync(client);
            }
        }

        private async Task HandleClientAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var request = await ReadRequestAsync(client.GetStream(), _shutdown.Token);
                    var (status, body) = HandleRequest(request.Path, request.Body);
                    var payload = Encoding.UTF8.GetBytes(body);
                    var headers = Encoding.ASCII.GetBytes(
                        $"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");
                    await client.GetStream().WriteAsync(headers, _shutdown.Token);
                    await client.GetStream().WriteAsync(payload, _shutdown.Token);
                }
                catch (OperationCanceledException)
                {
                }
                catch (IOException)
                {
                }
            }
        }

        private (string Status, string Body) HandleRequest(string path, string body)
        {
            if (path == "/v1/nodes/manifest")
                return ("503 Service Unavailable", "{\"version\":1,\"error\":\"test discovery unavailable\"}");
            if (path == "/v1/devices/register")
            {
                return ("200 OK", JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["version"] = 1,
                    ["status"] = "ok",
                    ["owner_identity_key_id"] = "test-owner",
                    ["device_id"] = "test-device",
                    ["expires_at_unix_ms"] = DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeMilliseconds(),
                }));
            }
            if (path.Contains("/pull", StringComparison.Ordinal))
            {
                var request = JsonSerializer.Deserialize<MailboxPullRequestDto>(body)
                              ?? throw new InvalidDataException("test mailbox pull request was empty");
                MailboxEnvelopeDto[] snapshot;
                lock (_sync)
                    snapshot = _envelopes.Take(Math.Max(0, request.Limit ?? 50)).ToArray();
                return ("200 OK", JsonSerializer.Serialize(new MailboxPullResponseDto(
                    EnvelopeProtocol.Version,
                    request.RecipientKeyId,
                    snapshot)));
            }
            if (path.Contains("/ack", StringComparison.Ordinal))
            {
                var request = JsonSerializer.Deserialize<MailboxAckRequestDto>(body)
                              ?? throw new InvalidDataException("test mailbox ACK request was empty");
                long deleted = 0;
                lock (_sync)
                {
                    foreach (var envelopeId in request.EnvelopeIds)
                    {
                        if (_envelopes.RemoveAll(item => item.EnvelopeId == envelopeId) > 0) deleted++;
                        _acknowledged.Add(envelopeId);
                    }
                }
                return ("200 OK", JsonSerializer.Serialize(new MailboxAckResponseDto(
                    EnvelopeProtocol.Version,
                    EnvelopeProtocol.StatusOk,
                    deleted)));
            }
            if (path.Contains("/delivery/", StringComparison.Ordinal))
            {
                var request = JsonSerializer.Deserialize<DeliveryStatusRequestDto>(body)
                              ?? throw new InvalidDataException("test delivery request was empty");
                return ("200 OK", JsonSerializer.Serialize(new DeliveryStatusResponseDto(
                    EnvelopeProtocol.Version,
                    request.SenderKeyId,
                    [])));
            }
            return ("404 Not Found", "{\"version\":1,\"error\":\"not found\"}");
        }

        private static async Task<(string Path, string Body)> ReadRequestAsync(
            NetworkStream stream,
            CancellationToken cancellationToken)
        {
            const int maximumHeaderBytes = 64 * 1024;
            const int maximumBodyBytes = 16 * 1024 * 1024;
            using var accumulated = new MemoryStream();
            var buffer = new byte[4096];
            var headerEnd = -1;
            while (headerEnd < 0)
            {
                var read = await stream.ReadAsync(buffer, cancellationToken);
                if (read == 0) throw new IOException("test HTTP request ended before headers");
                accumulated.Write(buffer, 0, read);
                if (accumulated.Length > maximumHeaderBytes)
                    throw new InvalidDataException("test HTTP request headers too large");
                headerEnd = HeaderEnd(accumulated.GetBuffer().AsSpan(0, checked((int)accumulated.Length)));
            }

            var requestBytes = accumulated.ToArray();
            var headerText = Encoding.ASCII.GetString(requestBytes, 0, headerEnd);
            var lines = headerText.Split("\r\n", StringSplitOptions.None);
            var requestParts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (requestParts.Length < 2) throw new InvalidDataException("test HTTP request line invalid");
            var contentLength = lines.Skip(1)
                .Select(line => line.Split(':', 2))
                .Where(parts => parts.Length == 2 &&
                                parts[0].Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                .Select(parts => int.Parse(parts[1].Trim()))
                .DefaultIfEmpty(0)
                .Single();
            if (contentLength < 0 || contentLength > maximumBodyBytes)
                throw new InvalidDataException("test HTTP request body too large");
            var bodyOffset = headerEnd + 4;
            var body = new byte[contentLength];
            var alreadyRead = Math.Min(contentLength, requestBytes.Length - bodyOffset);
            if (alreadyRead > 0) Buffer.BlockCopy(requestBytes, bodyOffset, body, 0, alreadyRead);
            var offset = alreadyRead;
            while (offset < body.Length)
            {
                var read = await stream.ReadAsync(body.AsMemory(offset), cancellationToken);
                if (read == 0) throw new IOException("test HTTP request body ended early");
                offset += read;
            }
            var path = new Uri("http://localhost" + requestParts[1]).AbsolutePath;
            return (path, Encoding.UTF8.GetString(body));
        }

        private static int HeaderEnd(ReadOnlySpan<byte> bytes)
        {
            for (var index = 0; index <= bytes.Length - 4; index++)
            {
                if (bytes[index] == '\r' && bytes[index + 1] == '\n' &&
                    bytes[index + 2] == '\r' && bytes[index + 3] == '\n')
                    return index;
            }
            return -1;
        }

        public async ValueTask DisposeAsync()
        {
            _shutdown.Cancel();
            _listener.Stop();
            try { await _acceptLoop; }
            catch (OperationCanceledException) { }
            _shutdown.Dispose();
        }
    }

    private sealed class MemoryStateStore : IClientStateStore
    {
        private readonly object _sync = new();
        private WindowsClientState _persisted;
        private bool _failNextSave;

        public MemoryStateStore(WindowsClientState initial)
        {
            _persisted = Clone(initial);
        }

        public WindowsClientState Snapshot
        {
            get
            {
                lock (_sync) return Clone(_persisted);
            }
        }

        public void FailNextSave()
        {
            lock (_sync) _failNextSave = true;
        }

        public Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default)
        {
            lock (_sync) return Task.FromResult(Clone(_persisted));
        }

        public Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default)
        {
            lock (_sync)
            {
                if (_failNextSave)
                {
                    _failNextSave = false;
                    throw new IOException("simulated durable-store failure");
                }
                _persisted = Clone(state);
            }
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            lock (_sync)
            {
                _persisted = new WindowsClientState();
                _persisted.Validate();
            }
            return Task.CompletedTask;
        }

        private static WindowsClientState Clone(WindowsClientState state) =>
            JsonSerializer.Deserialize<WindowsClientState>(JsonSerializer.Serialize(state))
            ?? throw new InvalidDataException("Failed to clone test state.");

    }
}
