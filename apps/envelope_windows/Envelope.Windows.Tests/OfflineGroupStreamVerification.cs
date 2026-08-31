using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Tests;

internal static class OfflineGroupStreamVerification
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static async Task RunAsync()
    {
        var legacyMessage = JsonSerializer.Deserialize<ChatMessageRecord>(
            """{"envelopeId":"legacy","conversationId":"peer","direction":0,"peerKeyId":"peer","peerDisplayName":"Peer","createdAtUnixMs":1,"messageCounter":1,"text":"old","opaqueEnvelopeBase64":"","deliveryState":4}""",
            Json) ?? throw new InvalidDataException("Unable to parse legacy chat message.");
        Require(legacyMessage.IsRead, "pre-unread-schema messages default to read");

        var root = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.OfflineGroupStreamVerification",
            Guid.NewGuid().ToString("N")));
        var expectedRoot = Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "Envelope.Windows.OfflineGroupStreamVerification"));
        Require(
            root.StartsWith(expectedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase),
            "offline group temporary root confinement");
        Directory.CreateDirectory(root);

        var native = new EnvelopeNativeClient();
        var owner = native.RecoverIdentity("群主你好😀", native.GenerateRecoveryPhrase());
        var bob = native.RecoverIdentity("Bob", native.GenerateRecoveryPhrase());
        var carol = native.RecoverIdentity("Carol", native.GenerateRecoveryPhrase());
        var ownerContact = native.ContactFromIdentity(owner.IdentityJson);
        var bobContact = native.ContactFromIdentity(bob.IdentityJson);
        var carolContact = native.ContactFromIdentity(carol.IdentityJson);
        var group = new GroupRecord(
            "grp-offline-stream",
            "离线互通群😀<&>",
            owner.KeyId,
            GroupPolicy.Normal,
            1,
            1_000,
            1_000,
            "offline-seed",
            true);
        var members = new[]
        {
            new GroupMemberRecord(
                group.GroupId, owner.KeyId, owner.DisplayName, ownerContact,
                GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified, 1_000,
                JoinedAtUnixMs: 1_000),
            new GroupMemberRecord(
                group.GroupId, bob.KeyId, bob.DisplayName, bobContact,
                GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter, 1_000,
                owner.KeyId, 1_000),
            new GroupMemberRecord(
                group.GroupId, carol.KeyId, carol.DisplayName, carolContact,
                GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter, 1_000,
                owner.KeyId, 1_000),
        };

        var ownerStore = new CloningStateStore();
        var bobStore = new CloningStateStore();
        var carolStore = new CloningStateStore();
        EnvelopeClientEngine? ownerEngine = null;
        EnvelopeClientEngine? bobEngine = null;
        EnvelopeClientEngine? carolEngine = null;
        try
        {
            var ownerPaths = new EnvelopePaths(
                Path.Combine(root, "owner-profile"),
                Path.Combine(root, "owner-local"));
            var bobPaths = new EnvelopePaths(
                Path.Combine(root, "bob-profile"),
                Path.Combine(root, "bob-local"));
            var carolPaths = new EnvelopePaths(
                Path.Combine(root, "carol-profile"),
                Path.Combine(root, "carol-local"));
            ownerEngine = NewEngine(native, ownerStore, ownerPaths);
            bobEngine = NewEngine(native, bobStore, bobPaths);
            carolEngine = NewEngine(native, carolStore, carolPaths);
            await ownerEngine.InitializeAsync();
            await bobEngine.InitializeAsync();
            await carolEngine.InitializeAsync();
            Configure(ownerEngine.State, owner, group, members);
            Configure(bobEngine.State, bob, group, members);
            Configure(carolEngine.State, carol, group, members);

            ownerStore.FailSaveAfter(successfulSavesBeforeFailure: 1);
            await ExpectAsync<IOException>(
                () => ownerEngine.SealGroupTextAsync(group.GroupId, "commit must roll back"),
                "group stream commit persistence failure");
            Require(!Directory.EnumerateFiles(ownerPaths.Sealed, "*.envelope").Any() &&
                    ownerEngine.State.SealedEnvelopes.Count == 0,
                "failed group stream commit removes final file and state record");

            const string text = "Android / WPF 群组离线文本：你好😀 <&>\n第二行";
            var textEnvelope = await ownerEngine.SealGroupTextAsync(group.GroupId, text);
            var expectedMagic = Encoding.ASCII.GetBytes(EnvelopeClientEngine.OfflineGroupStreamMagic + "\n");
            var actualMagic = new byte[expectedMagic.Length];
            await using (var input = File.OpenRead(textEnvelope))
                await input.ReadExactlyAsync(actualMagic);
            Require(actualMagic.AsSpan().SequenceEqual(expectedMagic),
                "Windows group stream uses Android-compatible LF magic without CR");
            var textLines = await File.ReadAllLinesAsync(textEnvelope);
            Equal(EnvelopeClientEngine.OfflineGroupStreamMagic, textLines[0], "group text stream magic");
            Equal(3, textLines.Length, "group text stream has one encrypted copy per recipient");

            var importedText = await bobEngine.OpenOfflineEnvelopeFileAsync(textEnvelope);
            Equal(text, importedText.Message.Text, "group text roundtrip");
            Equal(group.GroupId, importedText.Message.ConversationId, "group text conversation");
            Require(!importedText.Message.IsRead, "new inbound group text is unread");
            Require(
                bobEngine.State.Messages.Any(item => item.EnvelopeId == importedText.Message.EnvelopeId),
                "group text is persisted in chat state");
            var carolText = await carolEngine.OpenOfflineEnvelopeFileAsync(textEnvelope);
            Equal(text, carolText.Message.Text,
                "later recipient skips non-decryptable group text lines");
            Equal(1, await bobEngine.MarkConversationReadAsync(group.GroupId),
                "opening a conversation persists its unread transition");
            Require(
                bobEngine.State.Messages.Single(item => item.EnvelopeId == importedText.Message.EnvelopeId).IsRead,
                "group text is marked read");
            await ExpectAsync<CryptographicException>(
                () => bobEngine.OpenOfflineEnvelopeFileAsync(textEnvelope),
                "group text replay is rejected");

            var source = Path.Combine(root, "source.bin");
            var sourceBytes = RandomNumberGenerator.GetBytes(4 * 1024 * 1024 + 137);
            await File.WriteAllBytesAsync(source, sourceBytes);
            var fileEnvelope = await ownerEngine.SealGroupFileAsync(
                group.GroupId,
                source,
                "application/octet-stream");
            var fileLines = await File.ReadAllLinesAsync(fileEnvelope);
            Equal(EnvelopeClientEngine.OfflineGroupStreamMagic, fileLines[0], "group file stream magic");
            Equal(7, fileLines.Length, "group file stream interleaves two manifests and two chunks per recipient");

            bobStore.FailSaveAfter(successfulSavesBeforeFailure: 0);
            await ExpectAsync<IOException>(
                () => bobEngine.OpenOfflineEnvelopeFileAsync(fileEnvelope),
                "group file final persistence failure");
            Require(!Directory.EnumerateFiles(bobPaths.Received).Any() &&
                    bobEngine.State.Messages.All(item => item.AttachmentPath is null),
                "failed group file import removes final and restores message state");

            var importedFile = await bobEngine.OpenOfflineEnvelopeFileAsync(fileEnvelope);
            Require(importedFile.Message.AttachmentPath is { Length: > 0 }, "group file attachment path");
            var receivedBytes = await File.ReadAllBytesAsync(importedFile.Message.AttachmentPath!);
            Require(sourceBytes.AsSpan().SequenceEqual(receivedBytes), "group file bytes and whole hash roundtrip");
            Equal(group.GroupId, importedFile.Message.ConversationId, "group file conversation");
            Require(!importedFile.Message.IsRead, "new inbound group file is unread");
            Equal(1, await bobEngine.MarkConversationReadAsync(group.GroupId),
                "group file unread transition");
            var carolFile = await carolEngine.OpenOfflineEnvelopeFileAsync(fileEnvelope);
            var carolReceivedBytes = carolFile.Message.AttachmentPath is { Length: > 0 } carolPath
                ? await File.ReadAllBytesAsync(carolPath)
                : Array.Empty<byte>();
            Require(carolFile.Message.AttachmentPath is { Length: > 0 } &&
                    sourceBytes.AsSpan().SequenceEqual(carolReceivedBytes),
                "later recipient skips interleaved manifests/chunks and reconstructs the file");
            Require(carolFile.Message.OpaqueEnvelopeBase64.Length == 0,
                "group offline file does not persist its opaque manifest envelope");

            var receivedFileCount = Directory.EnumerateFiles(bobPaths.Received).Count();
            await ExpectAsync<CryptographicException>(
                () => bobEngine.OpenOfflineEnvelopeFileAsync(fileEnvelope),
                "group file replay is rejected before creating another final");
            Equal(receivedFileCount, Directory.EnumerateFiles(bobPaths.Received).Count(),
                "group file replay creates no duplicate plaintext");

            var blockedPaths = new EnvelopePaths(
                Path.Combine(root, "blocked-profile"),
                Path.Combine(root, "blocked-local"));
            await using (var blockedEngine = NewEngine(native, new CloningStateStore(), blockedPaths))
            {
                await blockedEngine.InitializeAsync();
                var blockedMembers = members.Select(member => member.KeyId == owner.KeyId
                        ? member with { Status = GroupMemberStatus.Pending }
                        : member)
                    .ToArray();
                Configure(blockedEngine.State, bob, group, blockedMembers);
                await ExpectAsync<InvalidDataException>(
                    () => blockedEngine.OpenOfflineEnvelopeFileAsync(fileEnvelope),
                    "inactive sender cannot inject a group offline file");
                Require(!Directory.EnumerateFiles(blockedPaths.Received).Any(),
                    "unauthorized group offline file writes no plaintext");
            }

            var oversizedLinePath = Path.Combine(root, "oversized-group-line.envelope");
            await using (var oversized = new FileStream(
                             oversizedLinePath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None))
            {
                await oversized.WriteAsync(expectedMagic);
                oversized.SetLength(expectedMagic.Length +
                                    EnvelopeClientEngine.MaximumOfflineEnvelopeLineCharacters + 1L);
            }
            await ExpectAsync<InvalidDataException>(
                () => bobEngine.OpenOfflineEnvelopeFileAsync(oversizedLinePath),
                "group stream line length resource limit");

            await bobEngine.DisposeAsync();
            bobEngine = NewEngine(native, bobStore, bobPaths);
            await bobEngine.InitializeAsync();
            Equal(2, bobEngine.State.Messages.Count(item => item.ConversationId == group.GroupId),
                "group text and file survive state reload");
            Require(
                bobEngine.State.Messages.Where(item => item.ConversationId == group.GroupId).All(item => item.IsRead),
                "read state survives reload");
            await ExpectAsync<CryptographicException>(
                () => bobEngine.OpenOfflineEnvelopeFileAsync(textEnvelope),
                "group replay remains rejected after reload");
        }
        finally
        {
            if (ownerEngine is not null) await ownerEngine.DisposeAsync();
            if (bobEngine is not null) await bobEngine.DisposeAsync();
            if (carolEngine is not null) await carolEngine.DisposeAsync();
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }

        Console.WriteLine("[PASS] Android-compatible group offline stream verification");
    }

    private static EnvelopeClientEngine NewEngine(
        IEnvelopeNativeClient native,
        IClientStateStore store,
        EnvelopePaths paths) => new(native, store, paths, new DiagnosticLogService(paths.Logs));

    private static void Configure(
        WindowsClientState state,
        IdentitySummary identity,
        GroupRecord group,
        IEnumerable<GroupMemberRecord> members)
    {
        state.Identity = SecureIdentityRecord.FromSummary(identity);
        state.Groups.Add(group);
        state.GroupMembers.AddRange(members);
    }

    private sealed class CloningStateStore : IClientStateStore
    {
        private WindowsClientState _state = new();
        private int _successfulSavesBeforeFailure = -1;

        public void FailSaveAfter(int successfulSavesBeforeFailure)
        {
            if (successfulSavesBeforeFailure < 0)
                throw new ArgumentOutOfRangeException(nameof(successfulSavesBeforeFailure));
            _successfulSavesBeforeFailure = successfulSavesBeforeFailure;
        }

        public Task<WindowsClientState> LoadAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(Clone(_state));

        public Task SaveAsync(WindowsClientState state, CancellationToken cancellationToken = default)
        {
            if (_successfulSavesBeforeFailure == 0)
            {
                _successfulSavesBeforeFailure = -1;
                throw new IOException("simulated state persistence failure");
            }
            if (_successfulSavesBeforeFailure > 0) _successfulSavesBeforeFailure--;
            _state = Clone(state);
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _state = new WindowsClientState();
            return Task.CompletedTask;
        }

        private static WindowsClientState Clone(WindowsClientState state) =>
            JsonSerializer.Deserialize<WindowsClientState>(JsonSerializer.Serialize(state, Json), Json)
            ?? throw new InvalidDataException("Unable to clone Windows client state.");
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

    private static void Equal<T>(T expected, T actual, string label)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException(
                $"Verification failed: {label}; expected '{expected}', actual '{actual}'.");
    }

    private static void Require(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException($"Verification failed: {label}.");
    }
}
