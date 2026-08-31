using System.Text.Json;
using System.Text;
using System.Security.Cryptography;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Security;

namespace Envelope.Windows.Tests;

internal static class NativeSecurityVerification
{
    public static async Task RunAsync()
    {
        var native = new EnvelopeNativeClient();
        var protocol = native.GetProtocolInfo();
        Require(protocol.ProtocolVersion == 1, "native protocol version");
        Require(protocol.RecoveryWordCount == 24, "native recovery word count");

        var alicePhrase = native.GenerateRecoveryPhrase();
        var bobPhrase = native.GenerateRecoveryPhrase();
        var alice = native.RecoverIdentity("Alice", alicePhrase);
        var bob = native.RecoverIdentity("Bob", bobPhrase);
        var aliceContact = native.ContactFromIdentity(alice.IdentityJson);
        var bobContact = native.ContactFromIdentity(bob.IdentityJson);
        Require(native.ParseContact(aliceContact).KeyId == alice.KeyId, "Alice contact roundtrip");
        Require(native.ParseContact(bobContact).KeyId == bob.KeyId, "Bob contact roundtrip");

        var outbound = native.EncryptOpaqueText(alice.IdentityJson, bobContact, "native-roundtrip", 1);
        var inbound = native.DecryptOpaqueText(bob.IdentityJson, aliceContact, outbound.EnvelopeBase64);
        Require(inbound.Text == "native-roundtrip", "opaque text roundtrip");
        Require(inbound.SenderKeyId == alice.KeyId && inbound.RecipientKeyId == bob.KeyId,
            "opaque text identities");

        var root = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.NativeSecurityVerification",
            Guid.NewGuid().ToString("N")));
        var expectedRoot = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.NativeSecurityVerification"));
        Require(root.StartsWith(expectedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase),
            "native/security temporary root confinement");
        Directory.CreateDirectory(root);
        try
        {
            await VerifySecureStateAndPortableBackupAsync(
                root, native, alicePhrase.Value, alice.KeyId, aliceContact,
                bobPhrase.Value, bobContact, bob.KeyId);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }

        Console.WriteLine("[PASS] Native FFI, secure state, and portable backup verification");
    }

    private static async Task VerifySecureStateAndPortableBackupAsync(
        string root,
        EnvelopeNativeClient native,
        string alicePhrase,
        string aliceKeyId,
        string aliceContact,
        string bobPhrase,
        string bobContact,
        string bobKeyId)
    {
        var profile = Path.Combine(root, "profile");
        var local = Path.Combine(root, "local");
        var vault = Path.Combine(root, "vault");
        var paths = new EnvelopePaths(profile, local);
        paths.EnsureCreated();
        using var secureStore = new WindowsSecureStore(vault);
        var stateStore = new SecureClientStateStore(secureStore);
        var diagnostics = new DiagnosticLogService(paths.Logs);
        await using var engine = new EnvelopeClientEngine(native, stateStore, paths, diagnostics);
        await engine.InitializeAsync();
        await engine.RestoreIdentityAsync("Alice", alicePhrase, replaceExisting: false);
        await engine.ImportHumanVerifiedContactAsync(bobContact, "Bob verified");

        var backupPath = await engine.ExportLocalBackupAsync();
        var backupJson = await File.ReadAllTextAsync(backupPath);
        using (var document = JsonDocument.Parse(backupJson))
        {
            var rootElement = document.RootElement;
            Require(rootElement.GetProperty("version").GetInt32() == 2, "portable backup v2");
            Require(rootElement.GetProperty("kind").GetString() == "envelope.android.local-backup-file",
                "portable backup Android-compatible kind");
            Require(rootElement.GetProperty("identity").GetProperty("key_id").GetString() == aliceKeyId,
                "portable backup identity");
        }
        Require(!backupJson.Contains(alicePhrase, StringComparison.Ordinal), "backup does not contain recovery phrase");
        Require(!backupJson.Contains("identity_json", StringComparison.OrdinalIgnoreCase),
            "backup does not contain private identity JSON");

        var vaultFiles = Directory.EnumerateFiles(vault, "*", SearchOption.AllDirectories).ToArray();
        Require(vaultFiles.Any(path => path.EndsWith("master-key.dpapi", StringComparison.OrdinalIgnoreCase)),
            "DPAPI master key exists");
        var vaultText = string.Join('\n', vaultFiles.Select(path => Encoding.UTF8.GetString(File.ReadAllBytes(path))));
        Require(!vaultText.Contains(aliceKeyId, StringComparison.Ordinal), "vault has no plaintext key id");
        Require(!vaultText.Contains("Bob verified", StringComparison.Ordinal), "vault has no plaintext contact remark");

        await engine.ClearIdentityAsync();
        await engine.RestoreLocalBackupAsync(alicePhrase, backupPath);
        Require(engine.State.Identity?.KeyId == aliceKeyId, "portable backup identity restore");
        Require(engine.State.Contacts.Any(contact => contact.KeyId == bobKeyId), "portable backup contact restore");
        Require(engine.State.Contacts.Single(contact => contact.KeyId == bobKeyId).HumanVerified,
            "portable backup human-verified contact restore");

        await VerifyPortableGroupEventBackupAsync(
            root,
            native,
            alicePhrase,
            bobContact);

        await VerifyPortableBackupSafetyAsync(
            root,
            native,
            engine,
            alicePhrase,
            aliceKeyId,
            aliceContact,
            bobPhrase,
            bobContact,
            bobKeyId,
            backupPath);

        await VerifyOfflineStreamIntegrityAsync(
            root, native, engine, aliceContact, bobPhrase, bobKeyId);
    }

    private static async Task VerifyPortableGroupEventBackupAsync(
        string root,
        EnvelopeNativeClient native,
        string ownerPhrase,
        string bobContact)
    {
        var paths = new EnvelopePaths(
            Path.Combine(root, "group-event-backup-profile"),
            Path.Combine(root, "group-event-backup-local"));
        paths.EnsureCreated();
        var store = new FailingOnceStateStore(new WindowsClientState());
        await using var engine = new EnvelopeClientEngine(
            native,
            store,
            paths,
            new DiagnosticLogService(paths.Logs));
        await engine.InitializeAsync();
        await engine.RestoreIdentityAsync("Owner", ownerPhrase, replaceExisting: false);
        await engine.ImportContactAsync(bobContact);
        var carol = native.RecoverIdentity("Carol portable events", native.GenerateRecoveryPhrase());
        await engine.ImportContactAsync(native.ContactFromIdentity(carol.IdentityJson));
        var created = await engine.CreateGroupAsync(
            "Portable causal history",
            GroupPolicy.Normal,
            engine.State.Contacts.Select(contact => contact.KeyId).ToArray());
        var originalEvent = engine.State.GroupEvents.Single(item => item.GroupId == created.Group.GroupId);
        for (var index = 0; index < EnvelopeClientEngine.MaximumPortableGroupEvents + 1; index++)
        {
            engine.State.GroupEvents.Add(new GroupEventRecord(
                $"chat-event-{index:D5}",
                created.Group.GroupId,
                "group_message",
                engine.State.Identity!.KeyId,
                created.Group.Epoch,
                originalEvent.CreatedAtUnixMs + index + 1,
                "{\"legacy_chat_data\":true}"));
        }

        var backupPath = await engine.ExportLocalBackupAsync(ownerPhrase);
        var plaintext = native.DecryptLocalBackup(
            RecoveryPhrase.Parse(ownerPhrase),
            await File.ReadAllTextAsync(backupPath));
        var rootNode = System.Text.Json.Nodes.JsonNode.Parse(plaintext)!.AsObject();
        var eventNodes = rootNode["store"]!["group_events"]!.AsArray();
        Equal(1, eventNodes.Count, "portable backup exports bounded causal group history");
        Require(eventNodes.All(node => node!["type"]!.GetValue<string>() != "group_message"),
            "long group chat data is excluded before portable event limits are applied");
        var eventNode = eventNodes[0]!.AsObject();
        var expectedWireKeys = new HashSet<string>(StringComparer.Ordinal)
        {
            "event_id", "group_id", "type", "actor_key_id",
            "group_epoch", "created_at_unix_ms", "payload_json",
        };
        Require(eventNode.Select(property => property.Key).ToHashSet(StringComparer.Ordinal)
                .SetEquals(expectedWireKeys),
            "portable group event uses the Android-compatible exact wire fields");
        Equal(originalEvent.EventId, eventNode["event_id"]!.GetValue<string>(),
            "portable group event id roundtrip");
        Equal(originalEvent.GroupEpoch, eventNode["group_epoch"]!.GetValue<long>(),
            "portable group event epoch mapper");

        engine.State.GroupEvents.Clear();
        await engine.RestoreLocalBackupAsync(ownerPhrase, backupPath);
        Equal(1, engine.State.GroupEvents.Count(item => item.EventId == originalEvent.EventId),
            "portable restore preserves signed causal proof");
        Require(engine.State.GroupEvents.All(item => item.Type != "group_message"),
            "portable restore does not retain non-causal group message data");

        var legacyChatRoot = System.Text.Json.Nodes.JsonNode.Parse(plaintext)!.AsObject();
        legacyChatRoot["store"]!["group_events"]!.AsArray().Add(
            new System.Text.Json.Nodes.JsonObject
            {
                ["event_id"] = "legacy-portable-group-message",
                ["group_id"] = created.Group.GroupId,
                ["type"] = "group_message",
                ["actor_key_id"] = engine.State.Identity!.KeyId,
                ["group_epoch"] = created.Group.Epoch,
                ["created_at_unix_ms"] = originalEvent.CreatedAtUnixMs + 1,
                ["payload_json"] = "{\"legacy_chat_data\":true}",
            });
        var legacyChatPath = Path.Combine(root, "portable-group-events-legacy-chat.json");
        await File.WriteAllTextAsync(
            legacyChatPath,
            native.EncryptLocalBackup(
                RecoveryPhrase.Parse(ownerPhrase),
                legacyChatRoot.ToJsonString()),
            new UTF8Encoding(false));
        await engine.RestoreLocalBackupAsync(ownerPhrase, legacyChatPath);
        Require(engine.State.GroupEvents.All(item => item.Type != "group_message"),
            "legacy portable group_message entries are accepted but discarded");

        var duplicateRoot = System.Text.Json.Nodes.JsonNode.Parse(plaintext)!.AsObject();
        var duplicateEvents = duplicateRoot["store"]!["group_events"]!.AsArray();
        duplicateEvents.Add(duplicateEvents[0]!.DeepClone());
        var duplicatePath = Path.Combine(root, "portable-group-events-duplicate.json");
        await File.WriteAllTextAsync(
            duplicatePath,
            native.EncryptLocalBackup(
                RecoveryPhrase.Parse(ownerPhrase),
                duplicateRoot.ToJsonString()),
            new UTF8Encoding(false));
        await engine.RestoreLocalBackupAsync(ownerPhrase, duplicatePath);
        Equal(1, engine.State.GroupEvents.Count(item => item.EventId == originalEvent.EventId),
            "exact duplicate portable group events deduplicate");

        var conflictRoot = System.Text.Json.Nodes.JsonNode.Parse(plaintext)!.AsObject();
        var conflictEvents = conflictRoot["store"]!["group_events"]!.AsArray();
        var conflict = conflictEvents[0]!.DeepClone().AsObject();
        conflict["created_at_unix_ms"] = originalEvent.CreatedAtUnixMs + 1;
        conflictEvents.Add(conflict);
        var conflictPath = Path.Combine(root, "portable-group-events-conflict.json");
        await File.WriteAllTextAsync(
            conflictPath,
            native.EncryptLocalBackup(
                RecoveryPhrase.Parse(ownerPhrase),
                conflictRoot.ToJsonString()),
            new UTF8Encoding(false));
        await ExpectAsync<InvalidDataException>(
            () => engine.RestoreLocalBackupAsync(ownerPhrase, conflictPath),
            "conflicting duplicate portable group event is rejected");

        var tamperedRoot = System.Text.Json.Nodes.JsonNode.Parse(plaintext)!.AsObject();
        var tamperedEvent = tamperedRoot["store"]!["group_events"]![0]!.AsObject();
        var payloadNode = System.Text.Json.Nodes.JsonNode.Parse(
            tamperedEvent["payload_json"]!.GetValue<string>())!.AsObject();
        payloadNode["signature"] = "tampered-signature";
        tamperedEvent["payload_json"] = payloadNode.ToJsonString();
        var tamperedPath = Path.Combine(root, "portable-group-events-tampered.json");
        await File.WriteAllTextAsync(
            tamperedPath,
            native.EncryptLocalBackup(
                RecoveryPhrase.Parse(ownerPhrase),
                tamperedRoot.ToJsonString()),
            new UTF8Encoding(false));
        await ExpectAsync<InvalidDataException>(
            () => engine.RestoreLocalBackupAsync(ownerPhrase, tamperedPath),
            "portable group event signature tamper is rejected before restore mutation");
    }

    private static async Task VerifyPortableBackupSafetyAsync(
        string root,
        EnvelopeNativeClient native,
        EnvelopeClientEngine engine,
        string alicePhrase,
        string aliceKeyId,
        string aliceContact,
        string bobPhrase,
        string bobContact,
        string bobKeyId,
        string baselineBackupPath)
    {
        const string verifiedGroupId = "grp-portable-local-trust";
        const string otherKeyId = "other-portable-member";
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var localNamespace = engine.State.CounterNamespace;
        engine.State.NextMessageCounter = WindowsClientState.ComposeCounter(250, localNamespace);
        engine.State.ReceivedCounters.Add(new ReceivedCounterRecord(bobKeyId, 7));
        engine.State.ReceivedCounters.Add(new ReceivedCounterRecord(bobKeyId, 9));
        engine.State.Groups.Add(new GroupRecord(
            verifiedGroupId,
            "Portable trust",
            bobKeyId,
            GroupPolicy.Verified,
            1,
            now,
            now,
            "seed"));
        engine.State.GroupMembers.Add(new GroupMemberRecord(
            verifiedGroupId,
            aliceKeyId,
            "Alice",
            aliceContact,
            GroupRole.Member,
            GroupMemberStatus.Active,
            GroupTrustState.Unverified,
            now));
        engine.State.GroupMembers.Add(new GroupMemberRecord(
            verifiedGroupId,
            bobKeyId,
            "Bob",
            bobContact,
            GroupRole.Owner,
            GroupMemberStatus.Active,
            GroupTrustState.Verified,
            now));
        engine.State.GroupMembers.Add(new GroupMemberRecord(
            verifiedGroupId,
            otherKeyId,
            "Other",
            "{\"key_id\":\"other-portable-member\"}",
            GroupRole.Member,
            GroupMemberStatus.Active,
            GroupTrustState.Verified,
            now));
        await engine.UpdateSettingsAsync(engine.State.Settings with
        {
            LocalLockEnabled = true,
            PersistRecoveryPhrase = true,
        });

        var verifiedBackupPath = await engine.ExportLocalBackupAsync(alicePhrase);
        var verifiedEncrypted = await File.ReadAllTextAsync(verifiedBackupPath);
        var verifiedPlaintext = native.DecryptLocalBackup(
            RecoveryPhrase.Parse(alicePhrase),
            verifiedEncrypted);
        using (var document = JsonDocument.Parse(verifiedPlaintext))
        {
            var members = document.RootElement.GetProperty("store").GetProperty("group_members")
                .EnumerateArray()
                .ToDictionary(
                    member => member.GetProperty("key_id").GetString()!,
                    member => member.GetProperty("trust_state").GetString()!,
                    StringComparer.Ordinal);
            Require(members[aliceKeyId] == "verified", "portable trust export keeps self baseline");
            Require(members[bobKeyId] == "inviter", "portable trust export keeps owner inviter baseline");
            Require(members[otherKeyId] == "unverified",
                "portable trust export strips remote member local verification");
        }

        engine.State.NextMessageCounter = WindowsClientState.ComposeCounter(5_000, localNamespace);
        engine.State.ReceivedCounters.Add(new ReceivedCounterRecord(bobKeyId, 11));
        var otherIndex = engine.State.GroupMembers.FindIndex(member =>
            member.GroupId == verifiedGroupId && member.KeyId == otherKeyId);
        engine.State.GroupMembers[otherIndex] = engine.State.GroupMembers[otherIndex] with
        {
            TrustState = GroupTrustState.Unverified,
        };
        await engine.UpdateSettingsAsync(engine.State.Settings with { LocalLockEnabled = true });
        await engine.RestoreLocalBackupAsync(alicePhrase, verifiedBackupPath);
        Require(WindowsClientState.CounterSequence(engine.State.NextMessageCounter) >= 6_024,
            "same-identity restore keeps current outbound high-water plus reservation");
        Require(new ulong[] { 7, 9, 11 }.All(counter => engine.State.ReceivedCounters.Any(item =>
                item.SenderKeyId == bobKeyId && item.MessageCounter == counter)),
            "same-identity restore merges inbound anti-replay ranges");
        Require(engine.State.Settings.LocalLockEnabled && engine.State.Settings.PersistRecoveryPhrase,
            "portable restore preserves enabled device-local security settings");
        Require(engine.State.GroupMembers.Single(member => member.KeyId == otherKeyId).TrustState ==
                GroupTrustState.Unverified,
            "same-device restore preserves local untrusted overlay");

        var bob = native.RecoverIdentity("Bob", bobPhrase);
        var replay = native.EncryptOpaqueText(bob.IdentityJson, aliceContact, "replay", 7);
        await ExpectAsync<CryptographicException>(
            () => engine.ImportEnvelopeAsync(replay.EnvelopeBase64, bobKeyId),
            "backup-restored inbound counter rejects old envelope replay");

        otherIndex = engine.State.GroupMembers.FindIndex(member => member.KeyId == otherKeyId);
        engine.State.GroupMembers[otherIndex] = engine.State.GroupMembers[otherIndex] with
        {
            TrustState = GroupTrustState.Verified,
        };
        await engine.UpdateSettingsAsync(engine.State.Settings with { LocalLockEnabled = false });
        await engine.RestoreLocalBackupAsync(alicePhrase, verifiedBackupPath);
        Require(!engine.State.Settings.LocalLockEnabled,
            "portable restore preserves disabled device-local lock even when backup says enabled");
        Require(engine.State.GroupMembers.Single(member => member.KeyId == otherKeyId).TrustState ==
                GroupTrustState.Verified,
            "same-device restore preserves local trusted overlay");

        var legacyPlaintext = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "envelope.android.local-backup",
            ["created_at_unix_ms"] = now,
            ["identity"] = new Dictionary<string, object?>
            {
                ["key_id"] = aliceKeyId,
                ["display_name"] = "Alice",
            },
            ["settings"] = new Dictionary<string, object?>
            {
                ["sync_service_url"] = null,
                ["auto_backup_interval_hours"] = 24,
                ["auto_backup_retention_count"] = 7,
            },
            ["store"] = new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["contacts"] = Array.Empty<object>(),
                ["messages"] = Array.Empty<object>(),
                ["groups"] = Array.Empty<object>(),
                ["group_members"] = Array.Empty<object>(),
                ["next_message_counter"] = 20_000_000UL,
                ["received_counter_ranges"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["sender_key_id"] = bobKeyId,
                        ["ranges"] = new ulong[][] { [13, 13] },
                    },
                },
            },
        });
        var legacyEncrypted = native.EncryptLocalBackup(
            RecoveryPhrase.Parse(alicePhrase),
            legacyPlaintext);
        var legacyPath = Path.Combine(root, "legacy-portable-backup.json");
        await File.WriteAllTextAsync(legacyPath, legacyEncrypted, new UTF8Encoding(false));

        await engine.UpdateSettingsAsync(engine.State.Settings with { LocalLockEnabled = true });
        await engine.RestoreLocalBackupAsync(alicePhrase, legacyPath);
        Require(engine.State.Settings.LocalLockEnabled,
            "backup missing local_lock_enabled cannot disable current local lock");
        Require(WindowsClientState.CounterSequence(engine.State.NextMessageCounter) >= 20_001_024,
            "raw Android counter above 2^24 is not misread as a Windows lane");
        Require(engine.State.ReceivedCounters.Any(item =>
                item.SenderKeyId == bobKeyId && item.MessageCounter == 13),
            "legacy portable anti-replay range restored");

        const uint reexportedWindowsNamespace = 0xA1B2C3D4;
        var reexportedNode = System.Text.Json.Nodes.JsonNode.Parse(legacyPlaintext)!.AsObject();
        var reexportedStore = reexportedNode["store"]!.AsObject();
        reexportedStore["next_message_counter"] = WindowsClientState.ComposeCounter(
            42,
            reexportedWindowsNamespace);
        reexportedStore.Remove("counter_namespace");
        reexportedStore.Remove("counter_namespace_bits");
        reexportedStore.Remove("counter_device_id");
        var reexportedEncrypted = native.EncryptLocalBackup(
            RecoveryPhrase.Parse(alicePhrase),
            reexportedNode.ToJsonString());
        var reexportedPath = Path.Combine(root, "android-reexported-windows-counter.json");
        await File.WriteAllTextAsync(reexportedPath, reexportedEncrypted, new UTF8Encoding(false));
        var namespaceBeforeReexportRestore = engine.State.CounterNamespace;
        await engine.RestoreLocalBackupAsync(alicePhrase, reexportedPath);
        Require(engine.State.CounterNamespace != namespaceBeforeReexportRestore &&
                engine.State.CounterNamespace != reexportedWindowsNamespace,
            "backup without counter metadata rotates away from current and inferred Windows lanes");
        Require(WindowsClientState.CounterSequence(engine.State.NextMessageCounter) > 42,
            "Android re-exported Windows high-water is extracted without overflow");

        await engine.UpdateSettingsAsync(engine.State.Settings with { LocalLockEnabled = false });
        await engine.RestoreLocalBackupAsync(alicePhrase, legacyPath);
        Require(!engine.State.Settings.LocalLockEnabled,
            "backup missing local_lock_enabled cannot enable current local lock");

        await engine.ClearIdentityAsync();
        await engine.RestoreLocalBackupAsync(alicePhrase, verifiedBackupPath);
        var freshMembers = engine.State.GroupMembers
            .Where(member => member.GroupId == verifiedGroupId)
            .ToDictionary(member => member.KeyId, StringComparer.Ordinal);
        Require(freshMembers[aliceKeyId].TrustState == GroupTrustState.Verified,
            "fresh-device portable trust baseline marks self verified");
        Require(freshMembers[bobKeyId].TrustState == GroupTrustState.Inviter,
            "fresh-device portable trust baseline marks owner inviter");
        Require(freshMembers[otherKeyId].TrustState == GroupTrustState.Unverified,
            "fresh-device portable restore does not migrate remote verified trust");

        await engine.RestoreLocalBackupAsync(alicePhrase, baselineBackupPath);
    }

    private static async Task VerifyOfflineStreamIntegrityAsync(
        string root,
        EnvelopeNativeClient native,
        EnvelopeClientEngine aliceEngine,
        string aliceContact,
        string bobPhrase,
        string bobKeyId)
    {
        var source = Path.Combine(root, "offline-source.bin");
        var expected = Enumerable.Range(0, 8193).Select(index => (byte)(index % 251)).ToArray();
        await File.WriteAllBytesAsync(source, expected);
        var sealedPath = await aliceEngine.SealFileAsync(bobKeyId, source);

        var bobPaths = new EnvelopePaths(
            Path.Combine(root, "bob-profile"),
            Path.Combine(root, "bob-local"));
        bobPaths.EnsureCreated();
        using var bobSecureStore = new WindowsSecureStore(Path.Combine(root, "bob-vault"));
        var bobStateStore = new SecureClientStateStore(bobSecureStore);
        var bobDiagnostics = new DiagnosticLogService(bobPaths.Logs);
        await using var bobEngine = new EnvelopeClientEngine(native, bobStateStore, bobPaths, bobDiagnostics);
        await bobEngine.InitializeAsync();
        await bobEngine.RestoreIdentityAsync("Bob", bobPhrase, replaceExisting: false);
        await bobEngine.ImportContactAsync(aliceContact, "Alice verified");

        var withExtraChunk = Path.Combine(root, "offline-extra.envelope");
        File.Copy(sealedPath, withExtraChunk);
        await File.AppendAllTextAsync(withExtraChunk, "not-an-envelope\n", new UTF8Encoding(false));
        await ExpectAsync<InvalidDataException>(
            () => bobEngine.OpenOfflineEnvelopeFileAsync(withExtraChunk),
            "offline stream trailing chunk rejection");
        Require(!Directory.EnumerateFiles(bobPaths.Received).Any(),
            "trailing chunk failure leaves no partial received file");

        var missingChunk = Path.Combine(root, "offline-missing.envelope");
        var lines = await File.ReadAllLinesAsync(sealedPath);
        await File.WriteAllLinesAsync(missingChunk, lines.Take(2), new UTF8Encoding(false));
        await ExpectAsync<InvalidDataException>(
            () => bobEngine.OpenOfflineEnvelopeFileAsync(missingChunk),
            "offline stream missing chunk rejection");
        Require(!Directory.EnumerateFiles(bobPaths.Received).Any(),
            "missing chunk failure leaves no partial received file");

        await VerifyOfflinePersistenceRollbackAsync(
            root,
            native,
            sealedPath,
            aliceContact,
            bobPhrase);

        var opened = await bobEngine.OpenOfflineEnvelopeFileAsync(sealedPath);
        Require(opened.Message.AttachmentPath is { } receivedPath && File.Exists(receivedPath),
            "valid offline stream produces attachment");
        Require(expected.SequenceEqual(await File.ReadAllBytesAsync(opened.Message.AttachmentPath!)),
            "valid offline stream payload roundtrip");
    }

    private static async Task VerifyOfflinePersistenceRollbackAsync(
        string root,
        EnvelopeNativeClient native,
        string sealedPath,
        string aliceContact,
        string bobPhrase)
    {
        var bob = native.RecoverIdentity("Bob", bobPhrase);
        var alice = native.ParseContact(aliceContact);
        var state = new WindowsClientState
        {
            Identity = SecureIdentityRecord.FromSummary(bob),
        };
        state.Validate();
        state.Contacts.Add(StoredContact.FromSummary(alice));
        var store = new FailingOnceStateStore(state);
        var paths = new EnvelopePaths(
            Path.Combine(root, "offline-rollback-profile"),
            Path.Combine(root, "offline-rollback-local"));
        paths.EnsureCreated();
        await using var engine = new EnvelopeClientEngine(
            native,
            store,
            paths,
            new DiagnosticLogService(paths.Logs));
        await engine.InitializeAsync();

        store.FailNextSave();
        await ExpectAsync<IOException>(
            () => engine.OpenOfflineEnvelopeFileAsync(sealedPath),
            "offline final rolls back when state persistence fails");
        Require(!Directory.EnumerateFiles(paths.Received).Any(),
            "offline persistence failure leaves no final or partial plaintext");
        Require(engine.State.Messages.Count == 0 && engine.State.ReceivedCounters.Count == 0,
            "offline persistence failure restores message and replay state");

        var retry = await engine.OpenOfflineEnvelopeFileAsync(sealedPath);
        Require(retry.Message.AttachmentPath is { } retryPath && File.Exists(retryPath),
            "offline envelope can retry successfully after durable-store recovery");
    }

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

    private sealed class FailingOnceStateStore(WindowsClientState initial) : IClientStateStore
    {
        private WindowsClientState _state = initial;
        private bool _failNext;

        public void FailNextSave() => _failNext = true;

        public Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(_state);

        public Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default)
        {
            if (_failNext)
            {
                _failNext = false;
                throw new IOException("simulated secure state save failure");
            }
            _state = state;
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _state = new WindowsClientState();
            _state.Validate();
            return Task.CompletedTask;
        }
    }
}
