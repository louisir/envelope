using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Core.Application;

public sealed partial class EnvelopeClientEngine
{
    public const string OfflineGroupStreamMagic = "ENVELOPE_GROUP_STREAM_V1";
    internal const int MaximumOfflineGroupRecipients = 1_024;
    internal const int MaximumOfflineGroupChunks = 100_000;
    internal const int MaximumOfflineGroupEnvelopeLines = 1_000_000;
    internal const int MaximumOfflineEnvelopeLineCharacters = 12 * 1024 * 1024;

    public async Task<string> SealGroupTextAsync(
        string groupId,
        string text,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("群组离线密封文本不能为空。", nameof(text));

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var (group, members, recipients) = RequireOfflineGroupRecipientsCore(groupId, identity.KeyId);
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var payload = CreateSignedGroupPayload(
                "group_message",
                group,
                members,
                now,
                new Dictionary<string, object?> { ["text"] = text.Trim() });
            var payloadBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload, Json));
            var counters = await ReserveMessageCountersCoreAsync(recipients.Count, cancellationToken)
                .ConfigureAwait(false);

            var output = UniquePath(
                _paths.Sealed,
                $"envelope-group-{DateTime.Now:yyyyMMdd-HHmmss}-{group.GroupId}.envelope");
            var temporaryOutput = output + $".partial-{Guid.NewGuid():N}";
            string? firstEnvelopeId = null;
            try
            {
                await using (var stream = new FileStream(
                                 temporaryOutput,
                                 FileMode.CreateNew,
                                 FileAccess.Write,
                                 FileShare.None,
                                 64 * 1024,
                                 FileOptions.Asynchronous | FileOptions.SequentialScan))
                await using (var writer = new StreamWriter(
                                 stream,
                                 new UTF8Encoding(false),
                                 64 * 1024,
                                 leaveOpen: false))
                {
                    // Android's format detector compares the exact ASCII magic
                    // ending in LF. StreamWriter defaults to CRLF on Windows.
                    writer.NewLine = "\n";
                    await writer.WriteLineAsync(OfflineGroupStreamMagic).ConfigureAwait(false);
                    for (var index = 0; index < recipients.Count; index++)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var recipient = recipients[index];
                        var envelope = _native.EncryptOpaqueFile(
                            identity.IdentityJson,
                            recipient.ContactJson,
                            "group-control.json",
                            GroupControlMime,
                            payloadBytes,
                            counters[index]);
                        firstEnvelopeId ??= envelope.EnvelopeId;
                        await writer.WriteLineAsync(envelope.EnvelopeBase64).ConfigureAwait(false);
                    }
                    await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
                }
                File.Move(temporaryOutput, output);
                await CommitSealedGroupStreamCoreAsync(
                        firstEnvelopeId ?? throw new InvalidOperationException("群组离线密封未生成任何收件人信封。"),
                        group.GroupId,
                        output,
                        "group_text",
                        cancellationToken)
                    .ConfigureAwait(false);
                return output;
            }
            finally
            {
                if (File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> SealGroupFileAsync(
        string groupId,
        string sourcePath,
        string mime = "application/octet-stream",
        CancellationToken cancellationToken = default)
    {
        var source = new FileInfo(sourcePath);
        if (!source.Exists) throw new FileNotFoundException("待密封文件不存在。", sourcePath);
        var estimatedChunkCount = source.Length == 0
            ? 1
            : checked((source.Length + FileTransferService.DefaultChunkBytes - 1) /
                      FileTransferService.DefaultChunkBytes);
        if (estimatedChunkCount > MaximumOfflineGroupChunks)
            throw new InvalidOperationException(
                $"群组离线文件需要 {estimatedChunkCount} 个分片，超过 {MaximumOfflineGroupChunks} 个资源上限。");
        var scan = await ScanAnySizeAsync(sourcePath, mime, cancellationToken).ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var (group, _, recipients) = RequireOfflineGroupRecipientsCore(groupId, identity.KeyId);
            var envelopesPerRecipient = checked(scan.Chunks.Count + 1);
            var envelopeCount = checked(recipients.Count * envelopesPerRecipient);
            if (envelopeCount > MaximumOfflineGroupEnvelopeLines)
                throw new InvalidOperationException(
                    $"群组离线文件需要 {envelopeCount} 条密文，超过 {MaximumOfflineGroupEnvelopeLines} 条资源上限。");
            var counters = await ReserveMessageCountersCoreAsync(
                    envelopeCount,
                    cancellationToken)
                .ConfigureAwait(false);
            var manifestObject = new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["kind"] = "offline_file_manifest",
                ["transfer_id"] = scan.TransferId,
                ["conversation_id"] = group.GroupId,
                ["group_id"] = group.GroupId,
                ["group_epoch"] = group.Epoch,
                ["filename"] = scan.FileName,
                ["mime"] = scan.Mime,
                ["total_size"] = scan.TotalSize,
                ["chunk_size"] = scan.ChunkSize,
                ["chunk_count"] = scan.Chunks.Count,
                ["file_sha256"] = scan.FileSha256,
                ["chunk_sha256"] = scan.Chunks.Select(item => item.Sha256).ToArray(),
            };
            var manifestBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(manifestObject, Json));
            var output = UniquePath(
                _paths.Sealed,
                $"envelope-group-{DateTime.Now:yyyyMMdd-HHmmss}-{scan.TransferId}.envelope");
            var temporaryOutput = output + $".partial-{Guid.NewGuid():N}";
            string? firstEnvelopeId = null;
            var writtenChunks = 0;
            long writtenBytes = 0;
            using var writtenHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            try
            {
                await using (var stream = new FileStream(
                                 temporaryOutput,
                                 FileMode.CreateNew,
                                 FileAccess.Write,
                                 FileShare.None,
                                 64 * 1024,
                                 FileOptions.Asynchronous | FileOptions.SequentialScan))
                await using (var writer = new StreamWriter(
                                 stream,
                                 new UTF8Encoding(false),
                                 64 * 1024,
                                 leaveOpen: false))
                {
                    writer.NewLine = "\n";
                    await writer.WriteLineAsync(OfflineGroupStreamMagic).ConfigureAwait(false);
                    for (var recipientIndex = 0; recipientIndex < recipients.Count; recipientIndex++)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var recipient = recipients[recipientIndex];
                        var envelope = _native.EncryptOpaqueFile(
                            identity.IdentityJson,
                            recipient.ContactJson,
                            $"{scan.FileName}.manifest.json",
                            OfflineFileManifestMime,
                            manifestBytes,
                            counters[recipientIndex * envelopesPerRecipient]);
                        firstEnvelopeId ??= envelope.EnvelopeId;
                        await writer.WriteLineAsync(envelope.EnvelopeBase64).ConfigureAwait(false);
                    }

                    await foreach (var chunk in ReadAnySizeChunksAsync(sourcePath, cancellationToken))
                    {
                        if (chunk.Index >= scan.Chunks.Count)
                            throw new IOException("群组离线密封期间源文件长度增加，已拒绝生成不一致信封。");
                        var descriptor = scan.Chunks[chunk.Index];
                        VerifyHash(chunk.Bytes, descriptor.Sha256, $"群组离线分片 {chunk.Index}");
                        writtenHash.AppendData(chunk.Bytes);
                        writtenBytes += chunk.Bytes.Length;
                        writtenChunks++;
                        for (var recipientIndex = 0; recipientIndex < recipients.Count; recipientIndex++)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            var recipient = recipients[recipientIndex];
                            var envelope = _native.EncryptOpaqueFile(
                                identity.IdentityJson,
                                recipient.ContactJson,
                                $"{scan.TransferId}.part{chunk.Index:000000}",
                                OfflineFileChunkMime,
                                chunk.Bytes,
                                counters[recipientIndex * envelopesPerRecipient + chunk.Index + 1]);
                            await writer.WriteLineAsync(envelope.EnvelopeBase64).ConfigureAwait(false);
                        }
                    }
                    await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
                }

                if (writtenChunks != scan.Chunks.Count ||
                    writtenBytes != scan.TotalSize ||
                    EncodeBase64Url(writtenHash.GetHashAndReset()) != scan.FileSha256)
                    throw new IOException("群组离线密封期间源文件发生变化，已拒绝生成不一致信封。");

                File.Move(temporaryOutput, output);
                await CommitSealedGroupStreamCoreAsync(
                        firstEnvelopeId ?? throw new InvalidOperationException("群组离线密封未生成 manifest。"),
                        group.GroupId,
                        output,
                        "group_file",
                        cancellationToken)
                    .ConfigureAwait(false);
                return output;
            }
            finally
            {
                if (File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task CommitSealedGroupStreamCoreAsync(
        string envelopeId,
        string groupId,
        string output,
        string kind,
        CancellationToken cancellationToken)
    {
        var record = new SealedEnvelopeRecord(
            envelopeId,
            groupId,
            output,
            kind,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        _state.SealedEnvelopes.Add(record);
        try
        {
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            _state.SealedEnvelopes.Remove(record);
            try
            {
                if (File.Exists(output)) DeleteManagedFileOrThrow(output, _paths.Sealed);
            }
            catch (Exception rollbackError)
            {
                _state.SealedEnvelopes.Add(record);
                throw new IOException(
                    "群组离线密封状态保存失败，且密文文件回滚不完整。",
                    new AggregateException(error, rollbackError));
            }
            throw;
        }
        RaiseStateChanged();
    }

    private (GroupRecord Group, GroupMemberRecord[] Members, IReadOnlyList<StoredContact> Recipients)
        RequireOfflineGroupRecipientsCore(string groupId, string selfKeyId)
    {
        var group = _state.RequireGroup(groupId);
        if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
        var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
        var recipients = GroupRules.MessageRecipients(group, members, selfKeyId)
            .Select(member => new StoredContact(member.KeyId, member.DisplayName, member.ContactJson))
            .GroupBy(contact => contact.KeyId, StringComparer.Ordinal)
            .Select(items => items.First())
            .ToArray();
        if (recipients.Length == 0)
            throw new InvalidOperationException("该群没有可离线密封的活跃成员。");
        if (recipients.Length > MaximumOfflineGroupRecipients)
            throw new InvalidOperationException(
                $"群组离线密封收件人超过 {MaximumOfflineGroupRecipients} 人资源上限。");
        return (group, members, recipients);
    }

    private async Task<EnvelopeImportResult> OpenOfflineGroupStreamFileCoreAsync(
        Stream input,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            input.Position = 0;
            using var reader = new BoundedOfflineLineReader(
                input,
                MaximumOfflineEnvelopeLineCharacters);
            if (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) != OfflineGroupStreamMagic)
                throw new InvalidDataException("群组离线流式信封 magic 无效。");

            InboundOpaquePayloadSummary? manifestInbound = null;
            StoredContact? manifestSender = null;
            Dictionary<string, JsonElement>? manifest = null;
            HashSet<ulong>? receivedCounters = null;
            string? output = null;
            string? temporaryOutput = null;
            FileStream? destination = null;
            IncrementalHash? wholeHash = null;
            string[]? chunkHashes = null;
            int chunkCount = 0;
            int chunkIndex = 0;
            long expectedSize = 0;
            long total = 0;
            string? expectedHash = null;
            string? fileName = null;
            string? conversationId = null;
            var decryptableLines = 0;
            var envelopeLines = 0;

            try
            {
                while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    envelopeLines++;
                    if (envelopeLines > MaximumOfflineGroupEnvelopeLines)
                        throw new InvalidDataException(
                            $"群组离线流密文行超过 {MaximumOfflineGroupEnvelopeLines} 条资源上限。");

                    if (manifestInbound is null)
                    {
                        if (!TryDecryptGroupStreamLineCore(line, out var inbound, out var sender)) continue;
                        decryptableLines++;
                        EnsureFreshCounter(sender.KeyId, inbound.MessageCounter);
                        if (inbound.Mime == GroupControlMime)
                        {
                            var textSnapshot = CaptureInboundStateSnapshotCore();
                            try
                            {
                                var message = await ProcessGroupPayloadCoreAsync(
                                        inbound,
                                        sender,
                                        line,
                                        cancellationToken)
                                    .ConfigureAwait(false);
                                RecordReceivedCounter(sender.KeyId, inbound.MessageCounter);
                                _state.Messages.Add(message);
                                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
                                RaiseStateChanged();
                                return new EnvelopeImportResult(message, false);
                            }
                            catch
                            {
                                RollbackInboundMutationCore(textSnapshot);
                                throw;
                            }
                        }

                        if (inbound.Mime != OfflineFileManifestMime)
                            throw new InvalidDataException($"群组离线流首个可拆封 MIME 无效：{inbound.Mime}。");
                        var map = DeserializeMap(inbound.PayloadBytes);
                        if (GetInt32(map, "version") != 1 ||
                            GetString(map, "kind") != "offline_file_manifest")
                            throw new InvalidDataException("群组离线 manifest 版本或类型无效。");
                        ValidateTransferId(GetString(map, "transfer_id"));
                        conversationId = ValidateInboundFileConversation(map, sender);
                        fileName = SafeFileName(GetString(map, "filename"));
                        var fileMime = GetString(map, "mime");
                        if (string.IsNullOrWhiteSpace(fileMime))
                            throw new InvalidDataException("群组离线 manifest MIME 为空。");
                        chunkCount = GetInt32(map, "chunk_count");
                        var chunkSize = GetInt32(map, "chunk_size");
                        expectedSize = GetInt64(map, "total_size");
                        expectedHash = GetString(map, "file_sha256");
                        chunkHashes = map["chunk_sha256"].EnumerateArray()
                            .Select(item => item.GetString() ?? string.Empty)
                            .ToArray();
                        if (expectedSize < 0 || chunkSize <= 0 ||
                            chunkSize > FileTransferService.DefaultChunkBytes ||
                            chunkCount <= 0 || chunkCount > MaximumOfflineGroupChunks ||
                            chunkCount != chunkHashes.Length)
                            throw new InvalidDataException("群组离线 manifest 分片数量无效。");
                        var expectedChunkCount = expectedSize == 0
                            ? 1
                            : checked((int)((expectedSize + chunkSize - 1) / chunkSize));
                        if (chunkCount != expectedChunkCount)
                            throw new InvalidDataException("群组离线 manifest 大小与分片数量不一致。");
                        ValidateSha256(expectedHash, "群组离线文件整体");
                        foreach (var hash in chunkHashes) ValidateSha256(hash, "群组离线文件分片");

                        manifestInbound = inbound;
                        manifestSender = sender;
                        manifest = map;
                        receivedCounters = [inbound.MessageCounter];
                        output = UniquePath(_paths.Received, fileName);
                        temporaryOutput = output + $".partial-{Guid.NewGuid():N}";
                        destination = new FileStream(
                            temporaryOutput,
                            FileMode.CreateNew,
                            FileAccess.Write,
                            FileShare.None,
                            64 * 1024,
                            FileOptions.Asynchronous | FileOptions.SequentialScan);
                        wholeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                        continue;
                    }

                    InboundOpaquePayloadSummary chunk;
                    try
                    {
                        chunk = _native.DecryptOpaquePayload(
                            RequireIdentity().IdentityJson,
                            manifestSender!.ContactJson,
                            line);
                        ValidateInboundIdentity(chunk, manifestSender);
                    }
                    catch (Exception error) when (error is EnvelopeNativeException or CryptographicException or FormatException)
                    {
                        continue;
                    }

                    decryptableLines++;
                    if (chunk.Mime != OfflineFileChunkMime)
                        throw new InvalidDataException($"群组离线分片 {chunkIndex} MIME 无效。");
                    EnsureFreshCounter(manifestSender.KeyId, chunk.MessageCounter);
                    if (!receivedCounters!.Add(chunk.MessageCounter))
                        throw new CryptographicException($"群组离线流中出现重复消息计数器：{chunk.MessageCounter}。");
                    VerifyHash(chunk.PayloadBytes, chunkHashes![chunkIndex], $"群组离线分片 {chunkIndex}");
                    total += chunk.PayloadBytes.Length;
                    wholeHash!.AppendData(chunk.PayloadBytes);
                    await destination!.WriteAsync(chunk.PayloadBytes, cancellationToken).ConfigureAwait(false);
                    chunkIndex++;
                    if (chunkIndex == chunkCount) break;
                }

                if (manifestInbound is null)
                    throw new CryptographicException(
                        decryptableLines == 0
                            ? "未找到可由本机身份解密的群组离线内容。"
                            : "群组离线流缺少文件 manifest。");
                if (chunkIndex != chunkCount)
                    throw new InvalidDataException($"群组离线流分片不完整：{chunkIndex}/{chunkCount}。");

                await destination!.FlushAsync(cancellationToken).ConfigureAwait(false);
                await destination.DisposeAsync().ConfigureAwait(false);
                destination = null;
                if (total != expectedSize ||
                    EncodeBase64Url(wholeHash!.GetHashAndReset()) != expectedHash)
                    throw new CryptographicException("群组离线文件长度或 SHA-256 校验失败。");

                File.Move(temporaryOutput!, output!);
                var fileSnapshot = CaptureInboundStateSnapshotCore();
                try
                {
                    foreach (var counter in receivedCounters!)
                        RecordReceivedCounter(manifestSender!.KeyId, counter);
                    var message = InboundMessage(
                        manifestInbound,
                        manifestSender!,
                        string.Empty,
                        $"拆封群文件：{fileName}",
                        conversationId!,
                        output,
                        GetString(manifest!, "mime"),
                        fileName);
                    _state.Messages.Add(message);
                    await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
                    RaiseStateChanged();
                    return new EnvelopeImportResult(message, false);
                }
                catch (Exception error)
                {
                    try
                    {
                        RollbackInboundMutationCore(fileSnapshot);
                        if (File.Exists(output)) DeleteInboundRollbackFileCore(output);
                    }
                    catch (Exception rollbackError)
                    {
                        throw new IOException(
                            "群组离线文件状态保存失败，且 final 文件回滚不完整。",
                            new AggregateException(error, rollbackError));
                    }
                    throw;
                }
            }
            finally
            {
                if (destination is not null) await destination.DisposeAsync().ConfigureAwait(false);
                wholeHash?.Dispose();
                if (temporaryOutput is not null && File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private bool TryDecryptGroupStreamLineCore(
        string line,
        out InboundOpaquePayloadSummary inbound,
        out StoredContact sender)
    {
        foreach (var candidate in KnownSenderCandidates(null))
        {
            try
            {
                var decrypted = _native.DecryptOpaquePayload(
                    RequireIdentity().IdentityJson,
                    candidate.ContactJson,
                    line);
                ValidateInboundIdentity(decrypted, candidate);
                inbound = decrypted;
                sender = candidate;
                return true;
            }
            catch (Exception error) when (error is EnvelopeNativeException or CryptographicException or FormatException)
            {
            }
        }
        inbound = null!;
        sender = null!;
        return false;
    }

    private sealed class BoundedOfflineLineReader : IDisposable
    {
        private readonly StreamReader _reader;
        private readonly char[] _buffer = ArrayPool<char>.Shared.Rent(64 * 1024);
        private readonly int _maximumLineCharacters;
        private int _offset;
        private int _count;
        private bool _disposed;

        public BoundedOfflineLineReader(Stream input, int maximumLineCharacters)
        {
            _reader = new StreamReader(input, Encoding.UTF8, true, 64 * 1024, leaveOpen: true);
            _maximumLineCharacters = maximumLineCharacters;
        }

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var line = new StringBuilder();
            while (true)
            {
                if (_offset >= _count)
                {
                    _count = await _reader.ReadAsync(_buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                    _offset = 0;
                    if (_count == 0)
                        return line.Length == 0 ? null : line.ToString();
                }

                var newline = Array.IndexOf(_buffer, '\n', _offset, _count - _offset);
                var end = newline >= 0 ? newline : _count;
                var segmentLength = end - _offset;
                if (line.Length > _maximumLineCharacters - segmentLength)
                    throw new InvalidDataException(
                        $"离线信封单行超过 {_maximumLineCharacters} 字符资源上限。");
                line.Append(_buffer, _offset, segmentLength);
                _offset = newline >= 0 ? newline + 1 : _count;
                if (newline < 0) continue;
                if (line.Length > 0 && line[^1] == '\r') line.Length--;
                return line.ToString();
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _reader.Dispose();
            ArrayPool<char>.Shared.Return(_buffer, clearArray: true);
        }
    }
}
