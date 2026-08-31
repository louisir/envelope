using System.Security.Cryptography;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Tests;

internal static class DomainFileStateVerification
{
    public static async Task RunAsync()
    {
        VerifyStateNormalizationAndCounters();
        VerifyGroupRules();
        await VerifyFilesAndPathsAsync();
        Console.WriteLine("[PASS] Domain, file, and state verification");
    }

    private static void VerifyStateNormalizationAndCounters()
    {
        var state = new WindowsClientState
        {
            DeviceId = " ",
            NextMessageCounter = 0,
            Settings = new SecureStoreSettings(
                SyncServiceUrl: "  https://node.example/  ",
                AutoBackupIntervalHours: -1,
                AutoBackupRetentionCount: 0,
                AutoBackupLastAtUnixMs: 0),
        };

        state.Validate();

        Require(state.DeviceId.StartsWith("windows-", StringComparison.Ordinal), "state device id repair");
        Require(state.CounterNamespace > 0 &&
                state.CounterNamespace <= (uint)WindowsClientState.CounterNamespaceMask,
            "state counter namespace repair");
        var firstCounter = WindowsClientState.ComposeCounter(1, state.CounterNamespace);
        Equal(firstCounter, state.NextMessageCounter, "state next counter repair");
        Equal("https://node.example/", state.Settings.SyncServiceUrl, "settings URL trim");
        Equal(0, state.Settings.AutoBackupIntervalHours, "settings interval lower bound");
        Equal(1, state.Settings.AutoBackupRetentionCount, "settings retention lower bound");
        Equal(null, state.Settings.AutoBackupLastAtUnixMs, "settings backup timestamp repair");
        Require(state.Settings.AutoSyncEnabled, "settings auto-sync default");
        Equal(firstCounter, state.AllocateMessageCounter(), "first allocated counter");
        Equal(firstCounter + WindowsClientState.CounterStride,
            state.AllocateMessageCounter(), "second allocated counter");

        state.ReceivedCounters.Add(new ReceivedCounterRecord("alice", 7));
        state.ReceivedCounters.Add(new ReceivedCounterRecord("alice", 5));
        Equal(2, state.ReceivedCounters.Count, "out-of-order counters remain individually trackable");

        var phrase = RecoveryPhrase.Parse(string.Join(' ', Enumerable.Range(1, 24).Select(index => $"word{index}")));
        Equal(24, phrase.WordCount, "recovery phrase word count");
        Require(!phrase.ToString().Contains("word1", StringComparison.Ordinal), "recovery phrase ToString redaction");
    }

    private static void VerifyGroupRules()
    {
        Equal(0, GroupRules.ConsensusThreshold(0), "consensus threshold zero members");
        Equal(1, GroupRules.ConsensusThreshold(1), "consensus threshold one member");
        Equal(2, GroupRules.ConsensusThreshold(2), "consensus threshold two members");
        Equal(2, GroupRules.ConsensusThreshold(3), "consensus threshold three members");
        Equal(3, GroupRules.ConsensusThreshold(4), "consensus threshold four members");
        Expect<InvalidOperationException>(
            () => EnvelopeClientEngine.ValidateGroupFileOutboxBudget(
                10,
                FileTransferService.MaximumOnlineFileBytes,
                (int)(FileTransferService.MaximumOnlineFileBytes / FileTransferService.DefaultChunkBytes)),
            "ten-recipient 64 MiB group file rejected by bounded outbox preflight");
        EnvelopeClientEngine.ValidateGroupFileOutboxBudget(2, 1024, 1);

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var group = new GroupRecord("grp-test", "Test", "owner", GroupPolicy.Verified, 1, now, now, "seed");
        var members = new[]
        {
            Member("owner", GroupRole.Owner, GroupMemberStatus.Active, GroupTrustState.Verified),
            Member("trusted", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Inviter),
            Member("untrusted", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Unverified),
            Member("missing-contact", GroupRole.Member, GroupMemberStatus.Active, GroupTrustState.Verified, contactJson: ""),
        };

        Require(!GroupRules.ShouldDissolve(members), "group with active owner and at least three members remains active");
        Require(GroupRules.ShouldDissolve(members.Select(member =>
            member.KeyId == "owner" ? member with { Status = GroupMemberStatus.Left } : member)),
            "group dissolves when owner leaves");
        Require(GroupRules.ShouldDissolve(members.Take(2)), "group dissolves below minimum membership");

        var recipients = GroupRules.MessageRecipients(group, members, "owner");
        SequenceEqual(["trusted"], recipients.Select(member => member.KeyId), "verified-group recipient filter");

        Expect<InvalidOperationException>(
            () => GroupRules.MessageRecipients(group, members, "not-a-member"),
            "non-member cannot send group messages");

        static GroupMemberRecord Member(
            string keyId,
            GroupRole role,
            GroupMemberStatus status,
            GroupTrustState trust,
            string contactJson = "contact") =>
            new("grp-test", keyId, keyId, contactJson, role, status, trust, 1);
    }

    private static async Task VerifyFilesAndPathsAsync()
    {
        var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Envelope.Windows.Tests", Guid.NewGuid().ToString("N")));
        var expectedRoot = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Envelope.Windows.Tests"));
        Require(root.StartsWith(expectedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase),
            "temporary test root confinement");
        Directory.CreateDirectory(root);
        try
        {
            var profile = Path.Combine(root, "profile");
            var local = Path.Combine(root, "local");
            var paths = new EnvelopePaths(profile, local);
            paths.EnsureCreated();
            foreach (var directory in new[]
                     {
                         paths.Received, paths.Sealed, paths.Backups, paths.DiagnosticsExport,
                         paths.State, paths.Cache, paths.Logs,
                     })
            {
                Require(Directory.Exists(directory), $"created directory {directory}");
            }

            var service = new FileTransferService();
            var emptyPath = Path.Combine(root, "empty.bin");
            await File.WriteAllBytesAsync(emptyPath, []);
            var emptyManifest = await service.ScanAsync(emptyPath);
            Equal(0L, emptyManifest.TotalSize, "empty file size");
            Equal(1, emptyManifest.Chunks.Count, "Android-compatible empty chunk count");
            Equal(0, emptyManifest.Chunks[0].Size, "empty chunk size");
            Equal(Base64Url(SHA256.HashData(ReadOnlySpan<byte>.Empty)), emptyManifest.FileSha256, "empty file hash");
            var emptyChunks = await ReadAllChunksAsync(service, emptyPath);
            Equal(1, emptyChunks.Count, "empty file chunk enumeration");
            Equal(0, emptyChunks[0].Bytes.Length, "empty enumerated chunk size");
            FileTransferService.VerifyChunk(emptyManifest.Chunks[0], emptyChunks[0].Bytes);

            var payload = Enumerable.Range(0, 257).Select(index => (byte)(index % 251)).ToArray();
            var filePath = Path.Combine(root, "payload.bin");
            await File.WriteAllBytesAsync(filePath, payload);
            var manifest = await service.ScanAsync(filePath, "application/test");
            Equal(payload.LongLength, manifest.TotalSize, "file scan size");
            Equal("application/test", manifest.Mime, "file scan MIME");
            Equal(Base64Url(SHA256.HashData(payload)), manifest.FileSha256, "file scan hash");
            var chunks = await ReadAllChunksAsync(service, filePath);
            Equal(1, chunks.Count, "small file chunk count");
            SequenceEqual(payload, chunks[0].Bytes, "small file chunk bytes");
            FileTransferService.VerifyChunk(manifest.Chunks[0], chunks[0].Bytes);
            var tampered = chunks[0].Bytes.ToArray();
            tampered[0] ^= 0xff;
            Expect<CryptographicException>(
                () => FileTransferService.VerifyChunk(manifest.Chunks[0], tampered),
                "tampered chunk rejection");

            var growthPath = Path.Combine(root, "source-growth.bin");
            await File.WriteAllBytesAsync(growthPath, new byte[FileTransferService.DefaultChunkBytes]);
            var growthManifest = await service.ScanAsync(growthPath);
            await using (var append = new FileStream(growthPath, FileMode.Append, FileAccess.Write, FileShare.Read))
                await append.WriteAsync(new byte[] { 1 });
            await ExpectAsync<InvalidDataException>(
                () => service.ReadVerifiedChunksAsync(growthPath, growthManifest),
                "source growth after scan rejection");

            var shrinkPath = Path.Combine(root, "source-shrink.bin");
            await File.WriteAllBytesAsync(
                shrinkPath,
                new byte[FileTransferService.DefaultChunkBytes + 1]);
            var shrinkManifest = await service.ScanAsync(shrinkPath);
            await using (var shrink = new FileStream(shrinkPath, FileMode.Open, FileAccess.Write, FileShare.Read))
                shrink.SetLength(FileTransferService.DefaultChunkBytes);
            await ExpectAsync<InvalidDataException>(
                () => service.ReadVerifiedChunksAsync(shrinkPath, shrinkManifest),
                "source truncation after scan rejection");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static async Task<List<(int Index, byte[] Bytes)>> ReadAllChunksAsync(
        FileTransferService service,
        string path)
    {
        var chunks = new List<(int Index, byte[] Bytes)>();
        await foreach (var chunk in service.ReadChunksAsync(path)) chunks.Add(chunk);
        return chunks;
    }

    private static string Base64Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static void Expect<T>(Action action, string label) where T : Exception
    {
        try
        {
            action();
        }
        catch (T)
        {
            return;
        }
        throw new InvalidOperationException($"Verification failed: {label}; expected {typeof(T).Name}.");
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

    private static void SequenceEqual<T>(IEnumerable<T> expected, IEnumerable<T> actual, string label)
    {
        if (!expected.SequenceEqual(actual))
            throw new InvalidOperationException($"Verification failed: {label}.");
    }
}
