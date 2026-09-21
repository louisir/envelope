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
    private const int MaximumOnlineChunkCount =
        (int)(FileTransferService.MaximumOnlineFileBytes / FileTransferService.DefaultChunkBytes);
    internal const long MaximumStagedOutboundEnvelopeBytes = 256L * 1024 * 1024;
    internal const int MaximumInboundPendingTransfers = 256;
    internal const int MaximumInboundPendingTransfersPerSender = 32;
    internal const long MaximumInboundChunkCacheBytes = 256L * 1024 * 1024;
    internal const long MaximumInboundChunkCacheBytesPerSender = 64L * 1024 * 1024;
    internal static readonly TimeSpan InboundChunkCacheRetention = TimeSpan.FromDays(7);
    internal const int MaximumPortableGroupEvents = 10_000;
    internal const int MaximumPortableGroupEventPayloadBytes = 1 * 1024 * 1024;
    internal const long MaximumPortableGroupEventTotalBytes = 16L * 1024 * 1024;
    private const string AndroidLocalBackupKind = "envelope.android.local-backup";
    private const string AndroidLocalBackupFileKind = "envelope.android.local-backup-file";
    private const string AndroidLocalBackupOpaqueScheme = "identity-self-opaque-envelope.local-backup.v2";
    private const string AndroidLocalBackupPayloadMime = "application/vnd.envelope.local-backup.payload+json";

    public async Task<ChatMessageRecord> SendFileAsync(
        string recipientKeyId,
        string path,
        string mime = "application/octet-stream",
        CancellationToken cancellationToken = default)
    {
        var transferService = new FileTransferService();
        var manifest = await transferService.ScanAsync(path, mime, cancellationToken).ConfigureAwait(false);
        var verifiedChunks = await transferService.ReadVerifiedChunksAsync(
                path, manifest, cancellationToken)
            .ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        ChatMessageRecord message;
        try
        {
            var identity = RequireIdentity();
            var contact = _state.RequireContact(recipientKeyId);
            var details = new List<string>();
            var logicalMessageId = $"file:{manifest.TransferId}";
            var childCount = checked(manifest.Chunks.Count + 1);
            var counters = await ReserveMessageCountersCoreAsync(childCount, cancellationToken).ConfigureAwait(false);
            var work = new List<(OutboundWorkItem Item, string Label)>();
            var manifestJson = SerializeFileManifest(manifest, contact.KeyId);
            var manifestEnvelope = _native.EncryptOpaqueFile(
                identity.IdentityJson,
                contact.ContactJson,
                $"{manifest.FileName}.manifest.json",
                FileManifestMime,
                Encoding.UTF8.GetBytes(manifestJson),
                counters[0]);
            work.Add((new OutboundWorkItem(
                contact,
                manifestEnvelope.EnvelopeId,
                manifestEnvelope.EnvelopeBase64,
                logicalMessageId,
                0,
                childCount), "manifest"));

            foreach (var chunk in verifiedChunks)
            {
                var descriptor = manifest.Chunks[chunk.Index];
                FileTransferService.VerifyChunk(descriptor, chunk.Bytes);
                var chunkJson = JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["version"] = 1,
                    ["kind"] = "file_chunk",
                    ["transfer_id"] = manifest.TransferId,
                    ["conversation_id"] = contact.KeyId,
                    ["chunk_index"] = chunk.Index,
                    ["chunk_count"] = manifest.Chunks.Count,
                    ["chunk_sha256"] = descriptor.Sha256,
                    ["data_b64"] = EncodeBase64Url(chunk.Bytes),
                }, Json);
                var outbound = _native.EncryptOpaqueFile(
                    identity.IdentityJson,
                    contact.ContactJson,
                    $"{manifest.FileName}.part{chunk.Index:0000}",
                    FileChunkMime,
                    Encoding.UTF8.GetBytes(chunkJson),
                    counters[chunk.Index + 1]);
                work.Add((new OutboundWorkItem(
                    contact,
                    outbound.EnvelopeId,
                    outbound.EnvelopeBase64,
                    logicalMessageId,
                    chunk.Index + 1,
                    childCount), $"chunk {chunk.Index + 1}/{manifest.Chunks.Count}"));
            }
            var stagedMessage = new ChatMessageRecord(
                manifestEnvelope.EnvelopeId,
                contact.KeyId,
                MessageDirection.Outgoing,
                contact.KeyId,
                contact.DisplayLabel,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                manifestEnvelope.MessageCounter,
                $"发送文件：{manifest.FileName}",
                manifestEnvelope.EnvelopeBase64,
                DeliveryState.Pending,
                path,
                manifest.Mime,
                manifest.FileName,
                "已持久化全部文件 child envelopes，等待投递。",
                LogicalMessageId: logicalMessageId);
            await StageOutboundBatchCoreAsync(
                    work.Select(item => item.Item).ToArray(),
                    cancellationToken,
                    stagedMessage)
                .ConfigureAwait(false);
            foreach (var child in work)
            {
                var delivery = await DeliverEnvelopeCoreAsync(
                        child.Item.Contact,
                        child.Item.EnvelopeId,
                        child.Item.EnvelopeBase64,
                        cancellationToken,
                        child.Item.LogicalMessageId,
                        child.Item.ChildIndex,
                        child.Item.ChildCount)
                    .ConfigureAwait(false);
                details.Add($"{child.Label}: {delivery.Route}");
            }
            var aggregate = AggregateLogicalDeliveryStateCore(logicalMessageId);
            message = (_state.Messages.FirstOrDefault(item => item.EnvelopeId == stagedMessage.EnvelopeId) ?? stagedMessage) with
            {
                DeliveryState = aggregate,
                DeliveryDetail = string.Join(Environment.NewLine, details),
            };
            _state.Messages.RemoveAll(item => item.EnvelopeId == message.EnvelopeId);
            _state.Messages.Add(message);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
        return message;
    }

    public async Task<ChatMessageRecord> SendGroupFileAsync(
        string groupId,
        string path,
        string mime = "application/octet-stream",
        CancellationToken cancellationToken = default)
    {
        var transferService = new FileTransferService();
        var manifest = await transferService.ScanAsync(path, mime, cancellationToken).ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        ChatMessageRecord message;
        try
        {
            var identity = RequireIdentity();
            var group = _state.RequireGroup(groupId);
            if (!group.IsActive) throw new InvalidOperationException("群组已解散。");
            var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
            var recipients = GroupRules.MessageRecipients(group, members, identity.KeyId);
            if (recipients.Count == 0) throw new InvalidOperationException("该群没有可投递的活跃成员。");
            ValidateGroupFileOutboxBudget(recipients.Count, manifest.TotalSize, manifest.Chunks.Count);
            var verifiedChunks = await transferService.ReadVerifiedChunksAsync(
                    path, manifest, cancellationToken)
                .ConfigureAwait(false);

            var details = new List<string>();
            var logicalMessageId = $"group-file:{group.GroupId}:{manifest.TransferId}";
            var childCount = checked(recipients.Count * checked(manifest.Chunks.Count + 1));
            var counters = await ReserveMessageCountersCoreAsync(childCount, cancellationToken).ConfigureAwait(false);
            var work = new List<(OutboundWorkItem Item, string MemberName, string Label)>();
            string? firstEnvelopeId = null;
            var childIndex = 0;
            foreach (var member in recipients)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var contact = new StoredContact(member.KeyId, member.DisplayName, member.ContactJson);
                foreach (var chunk in verifiedChunks)
                {
                    var descriptor = manifest.Chunks[chunk.Index];
                    FileTransferService.VerifyChunk(descriptor, chunk.Bytes);
                    var chunkJson = SerializeFileChunk(
                        manifest,
                        chunk.Index,
                        chunk.Bytes,
                        conversationId: group.GroupId,
                        groupId: group.GroupId);
                    var outboundChunk = _native.EncryptOpaqueFile(
                        identity.IdentityJson,
                        contact.ContactJson,
                        $"{manifest.FileName}.part{chunk.Index:0000}",
                        FileChunkMime,
                        Encoding.UTF8.GetBytes(chunkJson),
                        counters[childIndex]);
                    firstEnvelopeId ??= outboundChunk.EnvelopeId;
                    work.Add((new OutboundWorkItem(
                        contact,
                        outboundChunk.EnvelopeId,
                        outboundChunk.EnvelopeBase64,
                        logicalMessageId,
                        childIndex,
                        childCount), member.DisplayName, $"chunk {chunk.Index + 1}/{manifest.Chunks.Count}"));
                    childIndex++;
                }

                var manifestJson = SerializeFileManifest(
                    manifest,
                    group.GroupId,
                    group.GroupId,
                    group.Epoch);
                var outboundManifest = _native.EncryptOpaqueFile(
                    identity.IdentityJson,
                    contact.ContactJson,
                    $"{manifest.FileName}.manifest.json",
                    FileManifestMime,
                    Encoding.UTF8.GetBytes(manifestJson),
                    counters[childIndex]);
                firstEnvelopeId ??= outboundManifest.EnvelopeId;
                work.Add((new OutboundWorkItem(
                    contact,
                    outboundManifest.EnvelopeId,
                    outboundManifest.EnvelopeBase64,
                    logicalMessageId,
                    childIndex,
                    childCount), member.DisplayName, "manifest"));
                childIndex++;
            }

            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var stagedMessage = new ChatMessageRecord(
                firstEnvelopeId ?? throw new InvalidOperationException("群文件没有生成 child envelope。"),
                group.GroupId,
                MessageDirection.Outgoing,
                group.GroupId,
                group.Name,
                now,
                counters[0],
                $"发送文件：{manifest.FileName}",
                string.Empty,
                DeliveryState.Pending,
                path,
                manifest.Mime,
                manifest.FileName,
                "已持久化全部群文件 child envelopes，等待投递。",
                LogicalMessageId: logicalMessageId);
            await StageOutboundBatchCoreAsync(
                    work.Select(item => item.Item).ToArray(),
                    cancellationToken,
                    stagedMessage)
                .ConfigureAwait(false);
            foreach (var memberWork in work.GroupBy(item => item.MemberName, StringComparer.Ordinal))
            {
                var routes = new List<string>();
                foreach (var child in memberWork)
                {
                    var delivery = await DeliverEnvelopeCoreAsync(
                            child.Item.Contact,
                            child.Item.EnvelopeId,
                            child.Item.EnvelopeBase64,
                            cancellationToken,
                            child.Item.LogicalMessageId,
                            child.Item.ChildIndex,
                            child.Item.ChildCount)
                        .ConfigureAwait(false);
                    routes.Add($"{child.Label}: {delivery.Route}");
                }
                details.Add($"{memberWork.Key}: {string.Join(", ", routes)}");
            }

            var aggregate = AggregateLogicalDeliveryStateCore(logicalMessageId);
            message = (_state.Messages.FirstOrDefault(item => item.EnvelopeId == stagedMessage.EnvelopeId) ?? stagedMessage) with
            {
                DeliveryState = aggregate,
                DeliveryDetail = string.Join(Environment.NewLine, details),
            };
            _state.Messages.RemoveAll(item => item.EnvelopeId == message.EnvelopeId);
            _state.Messages.Add(message);
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }

        RaiseStateChanged();
        return message;
    }

    private static string SerializeFileManifest(
        FileTransferManifest manifest,
        string conversationId,
        string? groupId = null,
        long? groupEpoch = null)
    {
        var value = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_manifest",
            ["transfer_id"] = manifest.TransferId,
            ["conversation_id"] = conversationId,
            ["filename"] = manifest.FileName,
            ["mime"] = manifest.Mime,
            ["total_size"] = manifest.TotalSize,
            ["chunk_size"] = manifest.ChunkSize,
            ["chunk_count"] = manifest.Chunks.Count,
            ["file_sha256"] = manifest.FileSha256,
            ["chunk_sha256"] = manifest.Chunks.Select(item => item.Sha256).ToArray(),
        };
        if (!string.IsNullOrWhiteSpace(groupId)) value["group_id"] = groupId;
        if (groupEpoch is not null) value["group_epoch"] = groupEpoch.Value;
        return JsonSerializer.Serialize(value, Json);
    }

    private static string SerializeFileChunk(
        FileTransferManifest manifest,
        int index,
        byte[] bytes,
        string conversationId,
        string? groupId = null)
    {
        var value = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = "file_chunk",
            ["transfer_id"] = manifest.TransferId,
            ["conversation_id"] = conversationId,
            ["chunk_index"] = index,
            ["chunk_count"] = manifest.Chunks.Count,
            ["chunk_sha256"] = manifest.Chunks[index].Sha256,
            ["data_b64"] = EncodeBase64Url(bytes),
        };
        if (!string.IsNullOrWhiteSpace(groupId)) value["group_id"] = groupId;
        return JsonSerializer.Serialize(value, Json);
    }


    private async Task<ChatMessageRecord> ProcessFileTransferPayloadCoreAsync(
        InboundOpaquePayloadSummary inbound,
        StoredContact sender,
        string envelopeBase64,
        CancellationToken cancellationToken)
    {
        var map = DeserializeMap(inbound.PayloadBytes);
        if (GetInt32(map, "version") != 1) throw new InvalidDataException("不支持的文件传输版本。");
        var kind = GetString(map, "kind");
        var transferId = GetString(map, "transfer_id");
        ValidateTransferId(transferId);

        if (kind == "file_chunk")
        {
            var index = GetInt32(map, "chunk_index");
            var declaredChunkCount = GetInt32(map, "chunk_count");
            if (declaredChunkCount <= 0 || declaredChunkCount > MaximumOnlineChunkCount || index < 0 || index >= declaredChunkCount)
                throw new InvalidDataException($"文件分片序号无效：{index} / {declaredChunkCount}。");
            var hash = GetString(map, "chunk_sha256");
            ValidateSha256(hash, "文件分片");
            byte[] bytes;
            try { bytes = DecodeBase64Url(GetString(map, "data_b64")); }
            catch (FormatException error) { throw new InvalidDataException("文件分片 data_b64 无效。", error); }
            if (bytes.Length > FileTransferService.DefaultChunkBytes)
                throw new InvalidDataException("文件分片超过 4 MiB 上限。");
            VerifyHash(bytes, hash, $"文件分片 {index}");
            var chunkConversationId = ValidateInboundFileConversation(map, sender);
            var knownTransfer = _state.InboundFileTransfers.FirstOrDefault(item =>
                item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
                item.ConversationId == chunkConversationId);
            if (knownTransfer is not null)
            {
                if (knownTransfer.ChunkCount != declaredChunkCount)
                    throw new InvalidDataException("文件分片与已保存 manifest 的发送方或数量不一致。");
                if (index >= knownTransfer.ChunkSha256.Count || knownTransfer.ChunkSha256[index] != hash)
                    throw new InvalidDataException("文件分片与已保存 manifest 的哈希不一致。");
            }

            var existingChunk = _state.InboundFileChunks.FirstOrDefault(item =>
                item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
                item.ConversationId == chunkConversationId && item.ChunkIndex == index);
            if (existingChunk is not null &&
                (existingChunk.ChunkCount != declaredChunkCount || existingChunk.ChunkSha256 != hash ||
                 existingChunk.Size != bytes.Length))
            {
                throw new InvalidDataException("同一 transfer_id/index 的文件分片内容发生冲突。");
            }

            ValidateInboundTransferQuotaCore(
                sender.KeyId,
                chunkConversationId,
                transferId,
                proposedChunkIndex: index,
                proposedChunkBytes: bytes.Length);

            var cacheDir = EnsureSafeTransferCacheDirectory(
                sender.KeyId,
                chunkConversationId,
                transferId);
            var cachePath = Path.Combine(cacheDir, $"{index:000000}.part");
            if (File.Exists(cachePath) &&
                (File.GetAttributes(cachePath) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("文件分片缓存路径是 reparse point，拒绝覆盖。");
            var temporaryCachePath = cachePath + $".partial-{Guid.NewGuid():N}";
            try
            {
                await File.WriteAllBytesAsync(temporaryCachePath, bytes, cancellationToken).ConfigureAwait(false);
                File.Move(temporaryCachePath, cachePath, overwrite: true);
            }
            finally
            {
                if (File.Exists(temporaryCachePath)) File.Delete(temporaryCachePath);
            }
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            _state.InboundFileChunks.RemoveAll(item =>
                item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
                item.ConversationId == chunkConversationId && item.ChunkIndex == index);
            _state.InboundFileChunks.Add(new InboundFileChunkRecord(
                transferId,
                index,
                hash,
                cachePath,
                bytes.Length,
                sender.KeyId,
                declaredChunkCount,
                chunkConversationId,
                now));
            var completed = await TryCompleteTransferAsync(
                    sender.KeyId,
                    chunkConversationId,
                    transferId,
                    cancellationToken)
                .ConfigureAwait(false);
            var chunkMessage = InboundMessage(
                inbound, sender, envelopeBase64,
                completed is null ? $"正在接收文件分片 {index + 1}" : $"收到文件：{Path.GetFileName(completed)}",
                chunkConversationId,
                completed,
                completed is null ? null : _state.InboundFileTransfers.First(item =>
                    item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
                    item.ConversationId == chunkConversationId).Mime,
                completed is null ? null : Path.GetFileName(completed)) with { IsHidden = completed is null };
            return CompactInboundFileMessageCore(
                chunkMessage,
                sender.KeyId,
                chunkConversationId,
                transferId,
                completed is not null);
        }

        if (kind != "file_manifest") throw new InvalidDataException($"未知文件载荷：{kind}");
        var fileName = SafeFileName(GetString(map, "filename"));
        var chunkHashes = map.TryGetValue("chunk_sha256", out var hashes) && hashes.ValueKind == JsonValueKind.Array
            ? hashes.EnumerateArray().Select(item => item.GetString() ?? string.Empty).ToArray()
            : [];
        var totalSize = GetInt64(map, "total_size");
        var chunkSize = GetInt32(map, "chunk_size");
        var chunkCount = GetInt32(map, "chunk_count");
        if (totalSize < 0 || totalSize > FileTransferService.MaximumOnlineFileBytes)
            throw new InvalidDataException("在线文件大小超出 64 MiB 上限。");
        if (chunkSize <= 0 || chunkSize > FileTransferService.DefaultChunkBytes)
            throw new InvalidDataException("文件 manifest chunk_size 无效。");
        if (chunkCount <= 0 || chunkCount > MaximumOnlineChunkCount || chunkCount != chunkHashes.Length)
            throw new InvalidDataException("文件 manifest 分片数量无效。");
        var expectedChunkCount = totalSize == 0 ? 1 : checked((int)((totalSize + chunkSize - 1) / chunkSize));
        if (chunkCount != expectedChunkCount)
            throw new InvalidDataException("文件 manifest 的大小与分片数量不一致。");
        var fileHash = GetString(map, "file_sha256");
        ValidateSha256(fileHash, "文件整体");
        foreach (var chunkHash in chunkHashes) ValidateSha256(chunkHash, "文件分片");
        var conversationId = ValidateInboundFileConversation(map, sender);
        var transfer = new InboundFileTransferRecord(
            transferId,
            conversationId,
            sender.KeyId,
            fileName,
            GetString(map, "mime") is { Length: > 0 } fileMime ? fileMime : "application/octet-stream",
            totalSize,
            chunkSize,
            chunkCount,
            fileHash,
            chunkHashes,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        var existingTransfer = _state.InboundFileTransfers.FirstOrDefault(item =>
            item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
            item.ConversationId == conversationId);
        if (existingTransfer is not null && !SameTransfer(existingTransfer, transfer))
            throw new InvalidDataException("同一 transfer_id 的文件 manifest 内容发生冲突。");
        foreach (var chunk in _state.InboundFileChunks.Where(item =>
                     item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
                     item.ConversationId == conversationId))
        {
            if (chunk.SenderKeyId != sender.KeyId || chunk.ChunkCount != chunkCount ||
                chunk.ChunkIndex < 0 || chunk.ChunkIndex >= chunkCount ||
                chunk.ChunkSha256 != chunkHashes[chunk.ChunkIndex])
            {
                throw new InvalidDataException("缓存分片与文件 manifest 不一致。");
            }
        }
        ValidateInboundTransferQuotaCore(
            sender.KeyId,
            conversationId,
            transferId,
            proposedManifest: existingTransfer?.CompletedPath is null ? transfer : null);
        _state.InboundFileTransfers.RemoveAll(item =>
            item.TransferId == transferId && item.SenderKeyId == sender.KeyId &&
            item.ConversationId == conversationId);
        _state.InboundFileTransfers.Add(existingTransfer?.CompletedPath is null
            ? transfer
            : transfer with
            {
                CompletedPath = existingTransfer.CompletedPath,
                CleanupPending = existingTransfer.CleanupPending,
            });
        var completedPath = await TryCompleteTransferAsync(
                sender.KeyId,
                conversationId,
                transferId,
                cancellationToken)
            .ConfigureAwait(false);
        var manifestMessage = InboundMessage(
            inbound, sender, envelopeBase64,
            completedPath is null ? $"等待文件分片：{fileName}" : $"收到文件：{fileName}",
            transfer.ConversationId,
            completedPath,
            completedPath is null ? null : transfer.Mime,
            completedPath is null ? null : transfer.FileName) with { IsHidden = completedPath is null };
        return CompactInboundFileMessageCore(
            manifestMessage,
            sender.KeyId,
            transfer.ConversationId,
            transferId,
            completedPath is not null);
    }

    private ChatMessageRecord CompactInboundFileMessageCore(
        ChatMessageRecord message,
        string senderKeyId,
        string conversationId,
        string transferId,
        bool completed)
    {
        var logicalMessageId = $"inbound-file:{senderKeyId}:{conversationId}:{transferId}";
        // Transfer/chunk state is the durable progress journal. Keep at most one
        // lightweight hidden progress row, and remove it when the final file is
        // available. Opaque file envelopes can be tens of MiB after nested
        // base64 and must never be retained in the message vault.
        _state.Messages.RemoveAll(item =>
            item.IsHidden && item.LogicalMessageId == logicalMessageId);
        return message with
        {
            OpaqueEnvelopeBase64 = string.Empty,
            LogicalMessageId = logicalMessageId,
            IsHidden = !completed,
        };
    }

    private async Task<string?> TryCompleteTransferAsync(
        string senderKeyId,
        string conversationId,
        string transferId,
        CancellationToken cancellationToken)
    {
        var transfer = _state.InboundFileTransfers.FirstOrDefault(item =>
            item.TransferId == transferId && item.SenderKeyId == senderKeyId &&
            item.ConversationId == conversationId);
        if (transfer is null) return null;
        if (transfer.CompletedPath is not null)
        {
            // Cleanup is intentionally deferred until the enclosing inbound
            // transaction has durably saved this envelope's message/counter.
            // Deleting chunks here would make a later Save failure impossible
            // to roll back without restoring state that references missing files.
            return transfer.CompletedPath;
        }
        var chunks = _state.InboundFileChunks
            .Where(item => item.TransferId == transferId && item.SenderKeyId == senderKeyId &&
                           item.ConversationId == conversationId)
            .OrderBy(item => item.ChunkIndex)
            .ToArray();
        if (chunks.Length != transfer.ChunkCount || chunks.Where((item, index) => item.ChunkIndex != index).Any()) return null;
        if (chunks.Any(item => item.SenderKeyId != transfer.SenderKeyId ||
                               item.ChunkCount != transfer.ChunkCount ||
                               item.Size < 0 || item.Size > transfer.ChunkSize))
            throw new InvalidDataException("文件分片的发送方、数量或大小与 manifest 不一致。");

        var output = UniquePath(_paths.Received, transfer.FileName);
        var temporary = Path.Combine(
            EnsureSafeTransferCacheRoot(),
            $"complete-{TransferCacheNamespace(senderKeyId, conversationId, transferId)}-{Guid.NewGuid():N}.tmp");
        using var wholeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long total = 0;
        try
        {
            await using (var destination = new FileStream(
                             temporary,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             64 * 1024,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                foreach (var chunk in chunks)
                {
                    var cachePath = ValidateTransferCachePath(chunk, transfer);
                    var bytes = await File.ReadAllBytesAsync(cachePath, cancellationToken).ConfigureAwait(false);
                    if (bytes.Length != chunk.Size)
                        throw new InvalidDataException($"文件分片 {chunk.ChunkIndex} 的缓存长度已改变。");
                    VerifyHash(bytes, transfer.ChunkSha256[chunk.ChunkIndex], $"文件分片 {chunk.ChunkIndex}");
                    wholeHash.AppendData(bytes);
                    total += bytes.Length;
                    await destination.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                }
                destination.Flush(flushToDisk: true);
            }

            if (total != transfer.TotalSize || EncodeBase64Url(wholeHash.GetHashAndReset()) != transfer.FileSha256)
                throw new CryptographicException("文件总长度或 SHA-256 校验失败。");
            File.Move(temporary, output);
        }
        catch
        {
            try { File.Delete(temporary); } catch { }
            throw;
        }

        var completedTransfer = transfer with { CompletedPath = output, CleanupPending = true };
        _state.InboundFileTransfers.Remove(transfer);
        _state.InboundFileTransfers.Add(completedTransfer);
        // The caller persists CompletedPath/CleanupPending together with the
        // message and replay counter before invoking resumable cache cleanup.
        return output;
    }

    private async Task CleanupCompletedTransferCoreAsync(
        InboundFileTransferRecord transfer,
        CancellationToken cancellationToken)
    {
        var matching = _state.InboundFileChunks.Where(item =>
                item.TransferId == transfer.TransferId && item.SenderKeyId == transfer.SenderKeyId &&
                item.ConversationId == transfer.ConversationId)
            .ToArray();
        foreach (var chunk in matching)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!File.Exists(chunk.CachePath))
            {
                _state.InboundFileChunks.Remove(chunk);
                continue;
            }
            try
            {
                var cachePath = ValidateTransferCachePath(chunk, transfer);
                File.Delete(cachePath);
            }
            catch
            {
                continue;
            }
            if (!File.Exists(chunk.CachePath)) _state.InboundFileChunks.Remove(chunk);
        }
        var cleanupPending = _state.InboundFileChunks.Any(item =>
            item.TransferId == transfer.TransferId && item.SenderKeyId == transfer.SenderKeyId &&
            item.ConversationId == transfer.ConversationId);
        var index = _state.InboundFileTransfers.FindIndex(item =>
            item.TransferId == transfer.TransferId && item.SenderKeyId == transfer.SenderKeyId &&
            item.ConversationId == transfer.ConversationId);
        if (index >= 0) _state.InboundFileTransfers[index] = _state.InboundFileTransfers[index] with
        {
            CleanupPending = cleanupPending,
        };
        await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task ResumeInboundTransferCleanupCoreAsync(CancellationToken cancellationToken)
    {
        foreach (var transfer in _state.InboundFileTransfers
                     .Where(item => item.CompletedPath is not null && item.CleanupPending)
                     .ToArray())
        {
            await CleanupCompletedTransferCoreAsync(transfer, cancellationToken).ConfigureAwait(false);
        }
    }

    private static string TransferCacheNamespace(
        string senderKeyId,
        string conversationId,
        string transferId)
    {
        var key = Encoding.UTF8.GetBytes($"{senderKeyId}\n{conversationId}\n{transferId}");
        return Convert.ToHexString(SHA256.HashData(key)).ToLowerInvariant();
    }

    private void ValidateInboundTransferQuotaCore(
        string senderKeyId,
        string conversationId,
        string transferId,
        InboundFileTransferRecord? proposedManifest = null,
        int? proposedChunkIndex = null,
        int proposedChunkBytes = 0)
    {
        if (proposedChunkIndex is not null && proposedChunkBytes < 0)
            throw new InvalidDataException("入站文件分片配额长度无效。");
        var transferKey = (Sender: senderKeyId, Conversation: conversationId, Transfer: transferId);
        var manifests = new Dictionary<(string Sender, string Conversation, string Transfer), InboundFileTransferRecord>();
        foreach (var group in _state.InboundFileTransfers
                     .Where(item => item.CompletedPath is null)
                     .GroupBy(item => (
                         Sender: item.SenderKeyId,
                         Conversation: item.ConversationId,
                         Transfer: item.TransferId)))
        {
            if (group.Count() != 1)
                throw new InvalidDataException("入站文件状态包含重复 incomplete transfer key。");
            manifests.Add(group.Key, group.Single());
        }
        if (proposedManifest is not null) manifests[transferKey] = proposedManifest;

        var chunkBytes = new Dictionary<(string Sender, string Conversation, string Transfer), long>();
        foreach (var chunk in _state.InboundFileChunks)
        {
            var key = (
                Sender: chunk.SenderKeyId,
                Conversation: chunk.ConversationId,
                Transfer: chunk.TransferId);
            if (proposedChunkIndex is not null && key == transferKey &&
                chunk.ChunkIndex == proposedChunkIndex.Value)
                continue;
            chunkBytes[key] = checked(
                chunkBytes.GetValueOrDefault(key) + Math.Max(0, (long)chunk.Size));
        }
        if (proposedChunkIndex is not null)
            chunkBytes[transferKey] = checked(
                chunkBytes.GetValueOrDefault(transferKey) + proposedChunkBytes);

        var transferKeys = manifests.Keys.Concat(chunkBytes.Keys).Distinct().ToArray();
        var senderTransferCount = transferKeys.Count(item => item.Sender == senderKeyId);
        if (transferKeys.Length > MaximumInboundPendingTransfers)
            throw new InvalidDataException(
                $"入站文件缓存 transfer 数超过全局 {MaximumInboundPendingTransfers} 个安全上限。");
        if (senderTransferCount > MaximumInboundPendingTransfersPerSender)
            throw new InvalidDataException(
                $"发送方入站文件缓存 transfer 数超过 {MaximumInboundPendingTransfersPerSender} 个安全上限。");

        long globalReservedBytes = 0;
        long senderReservedBytes = 0;
        foreach (var key in transferKeys)
        {
            var cachedBytes = chunkBytes.GetValueOrDefault(key);
            var reservedBytes = manifests.TryGetValue(key, out var manifest)
                ? Math.Max(cachedBytes, manifest.TotalSize)
                : cachedBytes;
            globalReservedBytes = checked(globalReservedBytes + reservedBytes);
            if (key.Sender == senderKeyId)
                senderReservedBytes = checked(senderReservedBytes + reservedBytes);
        }
        if (globalReservedBytes > MaximumInboundChunkCacheBytes)
            throw new InvalidDataException(
                $"入站文件分片缓存超过全局 {MaximumInboundChunkCacheBytes / (1024 * 1024)} MiB 安全上限。");
        if (senderReservedBytes > MaximumInboundChunkCacheBytesPerSender)
            throw new InvalidDataException(
                $"发送方入站文件分片缓存超过 {MaximumInboundChunkCacheBytesPerSender / (1024 * 1024)} MiB 安全上限。");
    }

    private int PruneExpiredInboundFileCacheCore(long nowUnixMs)
    {
        var removed = PruneOrphanInboundCacheFilesCore();
        var cutoff = nowUnixMs - (long)InboundChunkCacheRetention.TotalMilliseconds;
        var knownTransferKeys = _state.InboundFileTransfers
            .Select(item => (item.SenderKeyId, item.ConversationId, item.TransferId))
            .Concat(_state.InboundFileChunks.Select(item =>
                (item.SenderKeyId, item.ConversationId, item.TransferId)))
            .Distinct()
            .ToArray();
        foreach (var chunk in _state.InboundFileChunks.ToArray())
        {
            var missing = !File.Exists(chunk.CachePath);
            var expired = chunk.CreatedAtUnixMs > 0 && chunk.CreatedAtUnixMs < cutoff;
            if (!missing && expired)
            {
                try
                {
                    var path = ValidateExistingInboundChunkCachePathCore(chunk);
                    File.Delete(path);
                    missing = !File.Exists(path);
                    if (missing)
                    {
                        var directory = Path.GetDirectoryName(path);
                        if (directory is not null && Directory.Exists(directory) &&
                            !Directory.EnumerateFileSystemEntries(directory).Any())
                            Directory.Delete(directory);
                    }
                }
                catch
                {
                    // A failed/unsafe deletion retains both file and state so
                    // quota accounting continues to fail closed.
                    missing = false;
                }
            }
            if (!missing) continue;
            _state.InboundFileChunks.Remove(chunk);
            removed++;
        }

        removed += _state.InboundFileTransfers.RemoveAll(transfer =>
            transfer.CompletedPath is null &&
            transfer.CreatedAtUnixMs < cutoff &&
            !_state.InboundFileChunks.Any(chunk =>
                chunk.TransferId == transfer.TransferId &&
                chunk.SenderKeyId == transfer.SenderKeyId &&
                chunk.ConversationId == transfer.ConversationId));
        foreach (var key in knownTransferKeys)
        {
            var stillPending = _state.InboundFileTransfers.Any(transfer =>
                                   transfer.CompletedPath is null &&
                                   transfer.TransferId == key.TransferId &&
                                   transfer.SenderKeyId == key.SenderKeyId &&
                                   transfer.ConversationId == key.ConversationId) ||
                               _state.InboundFileChunks.Any(chunk =>
                                   chunk.TransferId == key.TransferId &&
                                   chunk.SenderKeyId == key.SenderKeyId &&
                                   chunk.ConversationId == key.ConversationId);
            if (stillPending) continue;
            var logicalMessageId =
                $"inbound-file:{key.SenderKeyId}:{key.ConversationId}:{key.TransferId}";
            removed += _state.Messages.RemoveAll(message =>
                message.IsHidden && message.LogicalMessageId == logicalMessageId);
        }
        return removed;
    }

    private int PruneOrphanInboundCacheFilesCore()
    {
        var cacheRoot = Path.GetFullPath(_paths.Cache);
        var transferRoot = Path.GetFullPath(Path.Combine(cacheRoot, "transfers"));
        if (!Directory.Exists(transferRoot)) return 0;
        if (!IsPathInsideRoot(transferRoot, cacheRoot) ||
            (File.GetAttributes(cacheRoot) & FileAttributes.ReparsePoint) != 0 ||
            (File.GetAttributes(transferRoot) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("文件传输缓存根目录不安全，拒绝清理 orphan 临时文件。");

        var removed = 0;
        foreach (var file in Directory.EnumerateFiles(
                     transferRoot,
                     "complete-*.tmp",
                     SearchOption.TopDirectoryOnly))
        {
            var fullPath = Path.GetFullPath(file);
            if (!IsPathInsideRoot(fullPath, transferRoot) ||
                (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("orphan complete 临时文件路径不安全。");
            File.Delete(fullPath);
            if (File.Exists(fullPath)) throw new IOException("orphan complete 临时文件删除失败。");
            removed++;
        }
        foreach (var directory in Directory.EnumerateDirectories(
                     transferRoot,
                     "*",
                     SearchOption.TopDirectoryOnly))
        {
            var fullDirectory = Path.GetFullPath(directory);
            if (!IsPathInsideRoot(fullDirectory, transferRoot) ||
                (File.GetAttributes(fullDirectory) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("sender-scoped 文件传输缓存目录不安全。");
            foreach (var file in Directory.EnumerateFiles(
                         fullDirectory,
                         "*.part.partial-*",
                         SearchOption.TopDirectoryOnly))
            {
                var fullPath = Path.GetFullPath(file);
                if (!IsPathInsideRoot(fullPath, fullDirectory) ||
                    !string.Equals(Path.GetDirectoryName(fullPath), fullDirectory, StringComparison.OrdinalIgnoreCase) ||
                    (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("orphan 分片临时文件路径不安全。");
                File.Delete(fullPath);
                if (File.Exists(fullPath)) throw new IOException("orphan 分片临时文件删除失败。");
                removed++;
            }
            if (!Directory.EnumerateFileSystemEntries(fullDirectory).Any()) Directory.Delete(fullDirectory);
        }
        return removed;
    }

    private string ValidateExistingInboundChunkCachePathCore(InboundFileChunkRecord chunk)
    {
        var cacheRoot = Path.GetFullPath(_paths.Cache);
        var transferRoot = Path.GetFullPath(Path.Combine(cacheRoot, "transfers"));
        var expectedDirectory = Path.GetFullPath(Path.Combine(
            transferRoot,
            TransferCacheNamespace(chunk.SenderKeyId, chunk.ConversationId, chunk.TransferId)));
        var fullPath = Path.GetFullPath(chunk.CachePath);
        if (!IsPathInsideRoot(transferRoot, cacheRoot) ||
            !IsPathInsideRoot(expectedDirectory, transferRoot) ||
            !IsPathInsideRoot(fullPath, expectedDirectory) ||
            !string.Equals(Path.GetDirectoryName(fullPath), expectedDirectory, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetFileName(fullPath), $"{chunk.ChunkIndex:000000}.part", StringComparison.OrdinalIgnoreCase) ||
            !Directory.Exists(expectedDirectory) ||
            (File.GetAttributes(expectedDirectory) & FileAttributes.ReparsePoint) != 0 ||
            (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("过期文件分片缓存路径不在 sender-scoped 安全目录内。");
        return fullPath;
    }

    private string EnsureSafeTransferCacheRoot()
    {
        var cacheRoot = Path.GetFullPath(_paths.Cache);
        if (Directory.Exists(cacheRoot) &&
            (File.GetAttributes(cacheRoot) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Envelope cache 根目录是 reparse point。");
        Directory.CreateDirectory(cacheRoot);
        var transferRoot = Path.GetFullPath(Path.Combine(cacheRoot, "transfers"));
        if (!IsPathInsideRoot(transferRoot, cacheRoot))
            throw new IOException("文件传输缓存根目录越界。");
        Directory.CreateDirectory(transferRoot);
        if ((File.GetAttributes(transferRoot) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("文件传输缓存根目录是 reparse point。");
        return transferRoot;
    }

    private string EnsureSafeTransferCacheDirectory(
        string senderKeyId,
        string conversationId,
        string transferId)
    {
        var transferRoot = EnsureSafeTransferCacheRoot();
        var directory = Path.GetFullPath(Path.Combine(
            transferRoot,
            TransferCacheNamespace(senderKeyId, conversationId, transferId)));
        if (!IsPathInsideRoot(directory, transferRoot))
            throw new IOException("文件传输缓存目录越界。");
        Directory.CreateDirectory(directory);
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("文件传输缓存目录是 reparse point。");
        return directory;
    }

    private string ValidateTransferCachePath(
        InboundFileChunkRecord chunk,
        InboundFileTransferRecord transfer)
    {
        var expectedDirectory = EnsureSafeTransferCacheDirectory(
            transfer.SenderKeyId,
            transfer.ConversationId,
            transfer.TransferId);
        var fullPath = Path.GetFullPath(chunk.CachePath);
        if (!IsPathInsideRoot(fullPath, expectedDirectory) ||
            !string.Equals(Path.GetDirectoryName(fullPath), expectedDirectory, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Path.GetExtension(fullPath), ".part", StringComparison.OrdinalIgnoreCase) ||
            (File.Exists(fullPath) && (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0))
            throw new IOException("文件分片缓存路径不在其 sender-scoped 安全目录内。");
        return fullPath;
    }

    private string ValidateInboundFileConversation(
        IReadOnlyDictionary<string, JsonElement> map,
        StoredContact sender)
    {
        var groupId = GetString(map, "group_id");
        if (string.IsNullOrWhiteSpace(groupId)) groupId = GetString(map, "conversation_id");
        if (string.IsNullOrWhiteSpace(groupId) || !groupId.StartsWith("grp-", StringComparison.Ordinal))
        {
            RequireOrdinaryContactSender(sender.KeyId);
            return sender.KeyId;
        }

        var group = _state.Groups.FirstOrDefault(item => item.GroupId == groupId);
        if (group is null || !group.IsActive)
            throw new InvalidDataException($"群文件所属群组不可用：{groupId}。");
        var members = _state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
        var self = members.FirstOrDefault(item => item.KeyId == RequireIdentity().KeyId);
        var senderMember = members.FirstOrDefault(item => item.KeyId == sender.KeyId);
        if (self?.Status != GroupMemberStatus.Active)
            throw new InvalidDataException("本机身份不是该群活跃成员，拒绝导入群文件。");
        if (senderMember?.Status != GroupMemberStatus.Active)
            throw new InvalidDataException("发送方不是该群活跃成员，拒绝导入群文件。");
        if (group.Policy == GroupPolicy.Verified && senderMember.TrustState is not (
                GroupTrustState.Verified or GroupTrustState.Inviter or GroupTrustState.ConsensusAdmitted))
            throw new InvalidDataException("发送方尚未通过本机 fingerprint 验证，拒绝导入群文件。");
        return groupId;
    }

    internal static void ValidateGroupFileOutboxBudget(
        int recipientCount,
        long totalFileBytes,
        int chunkCount)
    {
        if (recipientCount <= 0) throw new ArgumentOutOfRangeException(nameof(recipientCount));
        if (totalFileBytes < 0) throw new ArgumentOutOfRangeException(nameof(totalFileBytes));
        if (chunkCount <= 0) throw new ArgumentOutOfRangeException(nameof(chunkCount));
        // Each raw chunk is base64 inside JSON and the opaque envelope is then
        // base64 again. 2x plus 128 KiB/child is a conservative upper bound for
        // headers, signatures and manifests. Reject before child encryption so
        // fanout can never multiply a 64 MiB source into an unbounded heap/vault.
        long estimate;
        try
        {
            estimate = checked(recipientCount * checked(
                checked(totalFileBytes * 2) + checked((long)(chunkCount + 1) * 128 * 1024)));
        }
        catch (OverflowException)
        {
            throw new InvalidOperationException("群文件 fanout outbox 预估大小溢出，已拒绝发送。");
        }
        if (estimate > MaximumStagedOutboundEnvelopeBytes)
            throw new InvalidOperationException(
                $"群文件 fanout 预计需要 {estimate / (1024 * 1024)} MiB outbox，超过 256 MiB 安全上限。");
    }

    private static bool SameTransfer(InboundFileTransferRecord left, InboundFileTransferRecord right) =>
        left.TransferId == right.TransferId &&
        left.ConversationId == right.ConversationId &&
        left.SenderKeyId == right.SenderKeyId &&
        left.FileName == right.FileName &&
        left.Mime == right.Mime &&
        left.TotalSize == right.TotalSize &&
        left.ChunkSize == right.ChunkSize &&
        left.ChunkCount == right.ChunkCount &&
        left.FileSha256 == right.FileSha256 &&
        left.ChunkSha256.SequenceEqual(right.ChunkSha256, StringComparer.Ordinal);

    private static void ValidateTransferId(string transferId)
    {
        if (string.IsNullOrWhiteSpace(transferId) || transferId.Length > 128 ||
            transferId.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_'))
        {
            throw new InvalidDataException("文件载荷 transfer_id 无效。");
        }
    }

    private static void ValidateSha256(string value, string label)
    {
        try
        {
            if (DecodeBase64Url(value).Length != SHA256.HashSizeInBytes)
                throw new InvalidDataException($"{label} SHA-256 长度无效。");
        }
        catch (FormatException error)
        {
            throw new InvalidDataException($"{label} SHA-256 编码无效。", error);
        }
    }

    public async Task<string> SealTextAsync(
        string recipientKeyId,
        string text,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("密封文本不能为空。", nameof(text));
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var contact = _state.RequireContact(recipientKeyId);
            var messageCounter = await ReserveMessageCounterCoreAsync(cancellationToken).ConfigureAwait(false);
            var outbound = _native.EncryptOpaqueText(
                identity.IdentityJson, contact.ContactJson, text.Trim(), messageCounter);
            var path = UniquePath(_paths.Sealed, $"envelope-{DateTime.Now:yyyyMMdd-HHmmss}-{outbound.EnvelopeId}.envelope");
            await File.WriteAllBytesAsync(path, DecodeBase64Url(outbound.EnvelopeBase64), cancellationToken).ConfigureAwait(false);
            await CommitSealedEnvelopeCoreAsync(
                    new SealedEnvelopeRecord(
                        outbound.EnvelopeId,
                        contact.KeyId,
                        path,
                        "text",
                        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
                    cancellationToken)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return path;
        }
        finally { _gate.Release(); }
    }

    public async Task<string> SealFileAsync(
        string recipientKeyId,
        string sourcePath,
        string mime = "application/octet-stream",
        CancellationToken cancellationToken = default)
    {
        var scan = await ScanAnySizeAsync(sourcePath, mime, cancellationToken).ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var contact = _state.RequireContact(recipientKeyId);
            var counters = await ReserveMessageCountersCoreAsync(
                    checked(scan.Chunks.Count + 1),
                    cancellationToken)
                .ConfigureAwait(false);
            var manifestObject = new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["kind"] = "offline_file_manifest",
                ["transfer_id"] = scan.TransferId,
                ["filename"] = scan.FileName,
                ["mime"] = scan.Mime,
                ["total_size"] = scan.TotalSize,
                ["chunk_size"] = scan.ChunkSize,
                ["chunk_count"] = scan.Chunks.Count,
                ["file_sha256"] = scan.FileSha256,
                ["chunk_sha256"] = scan.Chunks.Select(item => item.Sha256).ToArray(),
            };
            var manifestEnvelope = _native.EncryptOpaqueFile(
                identity.IdentityJson, contact.ContactJson,
                $"{scan.FileName}.manifest.json", OfflineFileManifestMime,
                Encoding.UTF8.GetBytes(JsonSerializer.Serialize(manifestObject, Json)),
                counters[0]);
            var output = UniquePath(_paths.Sealed, $"envelope-{DateTime.Now:yyyyMMdd-HHmmss}-{scan.TransferId}.envelope");
            var temporaryOutput = output + $".partial-{Guid.NewGuid():N}";
            var writtenChunks = 0;
            long writtenBytes = 0;
            using var writtenHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            try
            {
                await using (var writer = new StreamWriter(
                                 new FileStream(
                                     temporaryOutput, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                                     bufferSize: 64 * 1024,
                                     FileOptions.Asynchronous | FileOptions.SequentialScan),
                                 new UTF8Encoding(false), 64 * 1024, leaveOpen: false))
                {
                    await writer.WriteLineAsync(OfflineStreamMagic).ConfigureAwait(false);
                    await writer.WriteLineAsync(manifestEnvelope.EnvelopeBase64).ConfigureAwait(false);
                    await foreach (var chunk in ReadAnySizeChunksAsync(sourcePath, cancellationToken))
                    {
                        if (chunk.Index >= scan.Chunks.Count)
                            throw new IOException("密封期间源文件长度增加，已拒绝生成不一致的离线信封。");
                        var descriptor = scan.Chunks[chunk.Index];
                        VerifyHash(chunk.Bytes, descriptor.Sha256, $"离线分片 {chunk.Index}");
                        writtenHash.AppendData(chunk.Bytes);
                        writtenBytes += chunk.Bytes.Length;
                        writtenChunks++;
                        var envelope = _native.EncryptOpaqueFile(
                            identity.IdentityJson, contact.ContactJson,
                            $"{scan.TransferId}.part{chunk.Index:000000}", OfflineFileChunkMime,
                            chunk.Bytes, counters[chunk.Index + 1]);
                        await writer.WriteLineAsync(envelope.EnvelopeBase64).ConfigureAwait(false);
                    }
                    await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
                }

                if (writtenChunks != scan.Chunks.Count || writtenBytes != scan.TotalSize ||
                    EncodeBase64Url(writtenHash.GetHashAndReset()) != scan.FileSha256)
                {
                    throw new IOException("密封期间源文件发生变化，已拒绝生成不一致的离线信封。");
                }

                File.Move(temporaryOutput, output);
            }
            finally
            {
                if (File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
            }
            await CommitSealedEnvelopeCoreAsync(
                    new SealedEnvelopeRecord(
                        manifestEnvelope.EnvelopeId,
                        contact.KeyId,
                        output,
                        "file",
                        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
                    cancellationToken)
                .ConfigureAwait(false);
            RaiseStateChanged();
            return output;
        }
        finally { _gate.Release(); }
    }

    private async Task CommitSealedEnvelopeCoreAsync(
        SealedEnvelopeRecord record,
        CancellationToken cancellationToken)
    {
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
                if (File.Exists(record.Path)) DeleteManagedFileOrThrow(record.Path, _paths.Sealed);
            }
            catch (Exception rollbackError)
            {
                // Retain an in-memory reference when rollback cannot remove the
                // ciphertext, so a subsequent successful save can recover it.
                _state.SealedEnvelopes.Add(record);
                throw new IOException(
                    "离线密封状态保存失败，且密文文件回滚不完整。",
                    new AggregateException(error, rollbackError));
            }
            throw;
        }
    }

    public async Task<EnvelopeImportResult> OpenOfflineEnvelopeFileAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        await using var input = File.OpenRead(path);
        var prefixLength = Math.Max(OfflineStreamMagic.Length, OfflineGroupStreamMagic.Length) + 2;
        var prefix = new byte[Math.Min(prefixLength, checked((int)Math.Min(input.Length, int.MaxValue)))];
        var read = await input.ReadAsync(prefix, cancellationToken).ConfigureAwait(false);
        input.Position = 0;
        var prefixText = Encoding.ASCII.GetString(prefix, 0, read);
        if (prefixText.StartsWith(OfflineGroupStreamMagic + "\n", StringComparison.Ordinal) ||
            prefixText.StartsWith(OfflineGroupStreamMagic + "\r\n", StringComparison.Ordinal))
        {
            return await OpenOfflineGroupStreamFileCoreAsync(input, cancellationToken).ConfigureAwait(false);
        }
        if (!prefixText.StartsWith(OfflineStreamMagic + "\n", StringComparison.Ordinal) &&
            !prefixText.StartsWith(OfflineStreamMagic + "\r\n", StringComparison.Ordinal))
        {
            var bytes = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
            var maybeText = Encoding.UTF8.GetString(bytes).Trim();
            var encoded = maybeText.Length > 0 && maybeText.All(character =>
                char.IsLetterOrDigit(character) || character is '-' or '_' or '+' or '/' or '=')
                ? maybeText
                : EncodeBase64Url(bytes);
            return await ImportEnvelopeAsync(encoded, cancellationToken: cancellationToken).ConfigureAwait(false);
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            input.Position = 0;
            using var reader = new StreamReader(input, Encoding.UTF8, false, 64 * 1024, leaveOpen: true);
            if (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) != OfflineStreamMagic)
                throw new InvalidDataException("离线流式信封 magic 无效。");
            var manifestLine = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false)
                ?? throw new InvalidDataException("离线流式信封缺少 manifest。");
            var (manifestInbound, sender) = DecryptWithAnyContact(manifestLine);
            if (manifestInbound.Mime != OfflineFileManifestMime) throw new InvalidDataException("离线 manifest MIME 无效。");
            ValidateInboundIdentity(manifestInbound, sender);
            EnsureFreshCounter(sender.KeyId, manifestInbound.MessageCounter);
            var receivedCounters = new HashSet<ulong> { manifestInbound.MessageCounter };
            var map = DeserializeMap(manifestInbound.PayloadBytes);
            if (GetInt32(map, "version") != 1 || GetString(map, "kind") != "offline_file_manifest")
                throw new InvalidDataException("离线 manifest 版本或类型无效。");
            ValidateTransferId(GetString(map, "transfer_id"));
            var fileName = SafeFileName(GetString(map, "filename"));
            var chunkCount = GetInt32(map, "chunk_count");
            var expectedSize = GetInt64(map, "total_size");
            var expectedHash = GetString(map, "file_sha256");
            var chunkHashes = map["chunk_sha256"].EnumerateArray().Select(item => item.GetString() ?? string.Empty).ToArray();
            if (expectedSize < 0 || chunkCount <= 0 || chunkCount != chunkHashes.Length)
                throw new InvalidDataException("离线 manifest 分片数量无效。");
            ValidateSha256(expectedHash, "离线文件整体");
            foreach (var chunkHash in chunkHashes) ValidateSha256(chunkHash, "离线文件分片");
            var output = UniquePath(_paths.Received, fileName);
            var temporaryOutput = output + $".partial-{Guid.NewGuid():N}";
            var snapshot = CaptureInboundStateSnapshotCore();
            long total = 0;
            using var wholeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            try
            {
                await using (var destination = new FileStream(
                                 temporaryOutput, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                                 bufferSize: 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                {
                    for (var index = 0; index < chunkCount; index++)
                    {
                        var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false)
                            ?? throw new InvalidDataException($"离线信封缺少分片 {index}。");
                        var inbound = _native.DecryptOpaquePayload(RequireIdentity().IdentityJson, sender.ContactJson, line);
                        if (inbound.Mime != OfflineFileChunkMime) throw new InvalidDataException($"离线分片 {index} MIME 无效。");
                        ValidateInboundIdentity(inbound, sender);
                        EnsureFreshCounter(sender.KeyId, inbound.MessageCounter);
                        if (!receivedCounters.Add(inbound.MessageCounter))
                            throw new CryptographicException($"离线流中出现重复消息计数器：{inbound.MessageCounter}。");
                        VerifyHash(inbound.PayloadBytes, chunkHashes[index], $"离线分片 {index}");
                        total += inbound.PayloadBytes.Length;
                        wholeHash.AppendData(inbound.PayloadBytes);
                        await destination.WriteAsync(inbound.PayloadBytes, cancellationToken).ConfigureAwait(false);
                    }

                    await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
                }

                while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } trailingLine)
                {
                    if (!string.IsNullOrWhiteSpace(trailingLine))
                        throw new InvalidDataException("离线流式信封包含多余分片。");
                }

                if (total != expectedSize || EncodeBase64Url(wholeHash.GetHashAndReset()) != expectedHash)
                    throw new CryptographicException("离线文件长度或 SHA-256 校验失败。");

                File.Move(temporaryOutput, output);
            }
            finally
            {
                if (File.Exists(temporaryOutput)) File.Delete(temporaryOutput);
            }
            ChatMessageRecord message;
            try
            {
                foreach (var counter in receivedCounters) RecordReceivedCounter(sender.KeyId, counter);
                message = InboundMessage(
                    manifestInbound, sender, manifestLine, $"拆封文件：{fileName}", sender.KeyId,
                    output, GetString(map, "mime"), fileName);
                _state.Messages.Add(message);
                await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                try
                {
                    RollbackInboundMutationCore(snapshot);
                    if (File.Exists(output)) DeleteInboundRollbackFileCore(output);
                }
                catch (Exception rollbackError)
                {
                    throw new IOException(
                        "离线文件状态保存失败，且 final 文件回滚不完整。",
                        new AggregateException(error, rollbackError));
                }
                throw;
            }
            RaiseStateChanged();
            return new EnvelopeImportResult(message, false);
        }
        finally { _gate.Release(); }
    }

    public async Task<string> ExportLocalBackupAsync(
        string recoveryPhrase,
        CancellationToken cancellationToken = default)
    {
        var phrase = RecoveryPhrase.Parse(recoveryPhrase);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var backupJson = CreatePortableBackupJson(identity);
            var encrypted = _native.EncryptLocalBackup(phrase, backupJson);
            var path = UniquePath(_paths.Backups, $"envelope-local-backup-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            await File.WriteAllTextAsync(path, encrypted, new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            return path;
        }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Writes the current Android-compatible v2 identity-self-encrypted backup.
    /// The private identity is never included in the backup: the recovery phrase
    /// is still required to recover the identity that can decrypt the wrapper.
    /// This overload is suitable for manual and scheduled backups because it does
    /// not require retaining the recovery phrase in process or on disk.
    /// </summary>
    public async Task<string> ExportLocalBackupAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            var messageCounter = await ReserveMessageCounterCoreAsync(cancellationToken).ConfigureAwait(false);
            var plaintext = Encoding.UTF8.GetBytes(CreatePortableBackupJson(identity));
            var ownContact = _native.ContactFromIdentity(identity.IdentityJson);
            var outbound = _native.EncryptOpaqueFile(
                identity.IdentityJson,
                ownContact,
                "envelope-local-backup.json",
                AndroidLocalBackupPayloadMime,
                plaintext,
                messageCounter);
            var createdAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var wrapper = new Dictionary<string, object?>
            {
                ["version"] = 2,
                ["kind"] = AndroidLocalBackupFileKind,
                ["scheme"] = AndroidLocalBackupOpaqueScheme,
                ["created_at_unix_ms"] = createdAt,
                ["identity"] = new Dictionary<string, object?>
                {
                    ["key_id"] = identity.KeyId,
                    ["display_name"] = identity.DisplayName,
                },
                ["contents"] = new Dictionary<string, object?>
                {
                    ["contacts"] = true,
                    ["groups"] = true,
                    ["settings"] = true,
                    ["messages"] = false,
                    ["file_cache"] = false,
                },
                ["payload_filename"] = "envelope-local-backup.json",
                ["payload_mime"] = AndroidLocalBackupPayloadMime,
                ["payload_sha256"] = Convert.ToHexString(SHA256.HashData(plaintext)).ToLowerInvariant(),
                ["envelope_b64"] = outbound.EnvelopeBase64,
                ["envelope_len"] = outbound.EnvelopeLength,
            };
            var path = UniquePath(
                _paths.Backups,
                $"envelope-local-backup-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            await File.WriteAllTextAsync(
                path,
                JsonSerializer.Serialize(wrapper, Json),
                new UTF8Encoding(false),
                cancellationToken).ConfigureAwait(false);

            _state.Settings = _state.Settings with { AutoBackupLastAtUnixMs = createdAt };
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            PruneLocalBackups(_state.Settings.AutoBackupRetentionCount, path);
            return path;
        }
        finally { _gate.Release(); }
    }

    public async Task RestoreLocalBackupAsync(
        string recoveryPhrase,
        string backupPath,
        CancellationToken cancellationToken = default)
    {
        var phrase = RecoveryPhrase.Parse(recoveryPhrase);
        var encrypted = await File.ReadAllTextAsync(backupPath, cancellationToken).ConfigureAwait(false);
        IdentitySummary? recoveredFromWrapper = null;
        var plaintext = TryOpenAndroidBackupWrapper(encrypted, phrase, out recoveredFromWrapper)
            ?? _native.DecryptLocalBackup(phrase, encrypted);
        var backup = ParseLocalBackup(plaintext);
        var recovered = recoveredFromWrapper ?? _native.RecoverIdentity(backup.DisplayName, phrase);
        if (recovered.KeyId != backup.IdentityKeyId) throw new CryptographicException("恢复词身份与备份身份不匹配。");
        var validatedBackupEvents = ValidatePortableGroupEvents(
            backup.Groups,
            backup.GroupMembers,
            backup.GroupEvents);

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var previousState = CloneClientStateCore(_state);
            ManagedPlaintextQuarantine? quarantine = null;
            try
            {
                quarantine = StageManagedIdentityPlaintextCore(cancellationToken);
                ArchiveCurrentReceivedCountersCore();
            var currentIdentityKeyId = _state.Identity?.KeyId;
            var sameIdentity = string.Equals(currentIdentityKeyId, recovered.KeyId, StringComparison.Ordinal);
            var currentSettings = _state.Settings.Normalize();
            var currentNextCounter = _state.NextMessageCounter;
            if (!sameIdentity && _state.CounterNamespace != 0 &&
                !_state.RetiredCounterNamespaces.Contains(_state.CounterNamespace))
                _state.RetiredCounterNamespaces.Add(_state.CounterNamespace);
            var sameCounterDevice = sameIdentity &&
                                    !string.IsNullOrWhiteSpace(backup.CounterDeviceId) &&
                                    string.Equals(backup.CounterDeviceId, _state.DeviceId, StringComparison.Ordinal);
            if (!sameCounterDevice && _state.CounterNamespace != 0 &&
                !_state.RetiredCounterNamespaces.Contains(_state.CounterNamespace))
                _state.RetiredCounterNamespaces.Add(_state.CounterNamespace);
            var excludedCounterNamespaces = _state.RetiredCounterNamespaces.ToHashSet();
            if (backup.CounterNamespace != 0) excludedCounterNamespaces.Add(backup.CounterNamespace);
            var inferredBackupNamespace = InferLegacyNamespacedCounterNamespace(
                backup.NextMessageCounter,
                backup.CounterNamespace,
                backup.CounterNamespaceBits);
            if (inferredBackupNamespace != 0) excludedCounterNamespaces.Add(inferredBackupNamespace);
            var localCounterNamespace = sameCounterDevice
                ? _state.CounterNamespace
                : WindowsClientState.CreateCounterNamespace(excludedCounterNamespaces);
            var currentReceivedCounters = ArchivedReceivedCountersForCore(recovered.KeyId);
            var currentVerifiedGroupTrust = sameIdentity
                ? _state.Groups
                    .Where(group => group.Policy == GroupPolicy.Verified)
                    .SelectMany(group => _state.GroupMembers
                        .Where(member => member.GroupId == group.GroupId)
                        .Select(member => new KeyValuePair<(string GroupId, string KeyId), GroupTrustState>(
                            (member.GroupId, member.KeyId), member.TrustState)))
                    .ToDictionary(item => item.Key, item => item.Value)
                : new Dictionary<(string GroupId, string KeyId), GroupTrustState>();
            var currentPending = sameIdentity
                ? _state.PendingEnvelopes.ToArray()
                : Array.Empty<PendingEnvelopeRecord>();
            var currentQuarantine = sameIdentity
                ? _state.MailboxQuarantine.ToArray()
                : Array.Empty<MailboxQuarantineRecord>();
            var currentDeferredMailbox = sameIdentity
                ? _state.DeferredMailboxEnvelopes.ToArray()
                : Array.Empty<DeferredMailboxEnvelopeRecord>();
            _state.Identity = SecureIdentityRecord.FromSummary(recovered);
            _state.Settings = backup.Settings.Normalize() with
            {
                // Local authentication policy and retained-secret choices are
                // device security state. A portable backup must never disable
                // them; only an authenticated local settings flow may do so.
                LocalLockEnabled = currentSettings.LocalLockEnabled,
                PersistRecoveryPhrase = currentSettings.PersistRecoveryPhrase,
                AutoBackupLastAtUnixMs = currentSettings.AutoBackupLastAtUnixMs,
            };
            _state.Contacts.Clear(); _state.Contacts.AddRange(backup.Contacts);
            _state.Groups.Clear(); _state.Groups.AddRange(backup.Groups);
            var restoredMembers = NormalizePortableGroupTrust(
                    backup.Groups,
                    backup.GroupMembers,
                    recovered.KeyId)
                .Select(member => currentVerifiedGroupTrust.TryGetValue(
                        (member.GroupId, member.KeyId), out var localTrust)
                    ? member with { TrustState = localTrust }
                    : member)
                .ToArray();
            _state.GroupMembers.Clear(); _state.GroupMembers.AddRange(restoredMembers);
            _state.Messages.Clear();
            _state.GroupEvents.Clear(); _state.GroupEvents.AddRange(validatedBackupEvents);
            _state.PendingEnvelopes.Clear(); _state.PendingEnvelopes.AddRange(currentPending);
            _state.ReceivedCounters.Clear();
            _state.ReceivedCounters.AddRange(currentReceivedCounters
                .Concat(backup.ReceivedCounters)
                .DistinctBy(item => (item.SenderKeyId, item.MessageCounter)));
            foreach (var counter in _state.ReceivedCounters)
            {
                if (!_state.ReceivedCounterArchive.Any(item =>
                        item.RecipientIdentityKeyId == recovered.KeyId &&
                        item.SenderKeyId == counter.SenderKeyId &&
                        item.MessageCounter == counter.MessageCounter))
                    _state.ReceivedCounterArchive.Add(new IdentityReceivedCounterRecord(
                        recovered.KeyId,
                        counter.SenderKeyId,
                        counter.MessageCounter));
            }
            _state.MailboxQuarantine.Clear(); _state.MailboxQuarantine.AddRange(currentQuarantine);
            _state.DeferredMailboxEnvelopes.Clear();
            _state.DeferredMailboxEnvelopes.AddRange(currentDeferredMailbox);
            _state.SealedEnvelopes.Clear();
            _state.InboundFileTransfers.Clear();
            _state.InboundFileChunks.Clear();
            _state.CurrentP2pTicket = null;
            _state.CounterNamespace = localCounterNamespace;
            _state.NextMessageCounter = RestoredCounterHighWater(
                sameIdentity ? currentNextCounter : 0,
                backup.NextMessageCounter,
                backup.CounterNamespace,
                backup.CounterNamespaceBits,
                localCounterNamespace,
                namespaceRotated: !sameCounterDevice);
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
                            "恢复备份状态提交失败，且托管明文 rollback 未能完整恢复。",
                            new AggregateException(error, rollbackError));
                    }
                }
                throw;
            }
            await CommitManagedPlaintextTransitionCoreAsync(quarantine, CancellationToken.None)
                .ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        RaiseStateChanged();
    }

    private (InboundOpaquePayloadSummary Inbound, StoredContact Sender) DecryptWithAnyContact(string envelopeBase64)
    {
        Exception? last = null;
        foreach (var contact in _state.Contacts)
        {
            try
            {
                var inbound = _native.DecryptOpaquePayload(RequireIdentity().IdentityJson, contact.ContactJson, envelopeBase64);
                ValidateInboundIdentity(inbound, contact);
                return (inbound, contact);
            }
            catch (EnvelopeNativeException error) { last = error; }
        }
        throw new CryptographicException("无法用任何联系人拆封该离线信封。", last);
    }

    private void ValidateInboundIdentity(InboundOpaquePayloadSummary inbound, StoredContact sender)
    {
        if (inbound.SenderKeyId != sender.KeyId || inbound.RecipientKeyId != RequireIdentity().KeyId)
            throw new CryptographicException("离线信封身份与本机联系人不一致。");
    }

    private static async Task<FileTransferManifest> ScanAnySizeAsync(string path, string mime, CancellationToken cancellationToken)
    {
        var file = new FileInfo(path);
        if (!file.Exists) throw new FileNotFoundException("待密封文件不存在。", path);
        var chunks = new List<FileChunkDescriptor>();
        using var whole = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await foreach (var chunk in ReadAnySizeChunksAsync(path, cancellationToken))
        {
            whole.AppendData(chunk.Bytes);
            chunks.Add(new FileChunkDescriptor(chunk.Index, chunk.Bytes.Length, EncodeBase64Url(SHA256.HashData(chunk.Bytes))));
        }
        return new FileTransferManifest(1, Guid.NewGuid().ToString("N"), file.Name,
            string.IsNullOrWhiteSpace(mime) ? "application/octet-stream" : mime, file.Length,
            FileTransferService.DefaultChunkBytes, EncodeBase64Url(whole.GetHashAndReset()), chunks);
    }

    private static async IAsyncEnumerable<(int Index, byte[] Bytes)> ReadAnySizeChunksAsync(
        string path,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await using var input = File.OpenRead(path);
        var index = 0;
        if (input.Length == 0)
        {
            yield return (0, Array.Empty<byte>());
            yield break;
        }

        while (true)
        {
            var bytes = new byte[FileTransferService.DefaultChunkBytes];
            var offset = 0;
            while (offset < bytes.Length)
            {
                var read = await input.ReadAsync(bytes.AsMemory(offset), cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                offset += read;
            }
            if (offset == 0) yield break;
            if (offset != bytes.Length) Array.Resize(ref bytes, offset);
            yield return (index++, bytes);
        }
    }

    private static DeliveryState MergeDeliveryState(DeliveryState current, DeliveryState next)
    {
        static int Rank(DeliveryState state) => state switch
        {
            DeliveryState.Failed => 5,
            DeliveryState.Pending => 4,
            DeliveryState.ServerMailbox => 3,
            DeliveryState.Sent => 2,
            DeliveryState.Delivered => 1,
            _ => 0,
        };
        return Rank(next) > Rank(current) ? next : current;
    }

    private static void VerifyHash(ReadOnlySpan<byte> bytes, string expected, string label)
    {
        var actual = EncodeBase64Url(SHA256.HashData(bytes));
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(actual), Encoding.ASCII.GetBytes(expected)))
            throw new CryptographicException($"{label} SHA-256 校验失败。");
    }

    private static int GetInt32(IReadOnlyDictionary<string, JsonElement> map, string key) =>
        map.TryGetValue(key, out var value) && value.TryGetInt32(out var number) ? number : 0;

    private static long GetInt64(IReadOnlyDictionary<string, JsonElement> map, string key) =>
        map.TryGetValue(key, out var value) && value.TryGetInt64(out var number) ? number : 0;

    private string CreatePortableBackupJson(SecureIdentityRecord identity)
    {
        var backup = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["kind"] = AndroidLocalBackupKind,
            ["created_at_unix_ms"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            ["identity"] = new Dictionary<string, object?>
            {
                ["key_id"] = identity.KeyId,
                ["display_name"] = identity.DisplayName,
            },
            ["settings"] = new Dictionary<string, object?>
            {
                ["sync_service_url"] = string.IsNullOrWhiteSpace(_state.Settings.SyncServiceUrl)
                    ? null
                    : _state.Settings.SyncServiceUrl,
                ["auto_backup_interval_hours"] = _state.Settings.AutoBackupIntervalHours,
                ["auto_backup_retention_count"] = _state.Settings.AutoBackupRetentionCount,
                ["local_lock_enabled"] = _state.Settings.LocalLockEnabled,
                ["auto_sync_enabled"] = _state.Settings.AutoSyncEnabled,
            },
            ["contents"] = new Dictionary<string, object?>
            {
                ["contacts"] = true,
                ["groups"] = true,
                ["settings"] = true,
                ["messages"] = false,
                ["file_cache"] = false,
            },
            ["store"] = new Dictionary<string, object?>
            {
                ["version"] = 1,
                ["contacts"] = _state.Contacts.Select(ContactToBackupWire).ToArray(),
                ["messages"] = Array.Empty<object>(),
                ["groups"] = _state.Groups.Select(GroupToWire).ToArray(),
                // Verified-group trust is a local human decision. The portable
                // wire carries only a safe baseline; same-device restore overlays
                // the current local state and another device must re-verify.
                ["group_members"] = NormalizePortableGroupTrust(
                        _state.Groups,
                        _state.GroupMembers,
                        identity.KeyId)
                    .Select(MemberToWire)
                    .ToArray(),
                ["group_events"] = ValidatePortableGroupEvents(
                        _state.Groups,
                        _state.GroupMembers,
                        _state.GroupEvents)
                    .Select(GroupEventToBackupWire)
                    .ToArray(),
                ["next_message_counter"] = _state.NextMessageCounter,
                ["counter_namespace"] = _state.CounterNamespace,
                ["counter_namespace_bits"] = WindowsClientState.CounterNamespaceBits,
                ["counter_device_id"] = _state.DeviceId,
                ["received_counter_ranges"] = ReceivedCounterRangesToBackupWire(_state.ReceivedCounters),
            },
        };
        return JsonSerializer.Serialize(backup, Json);
    }

    private static Dictionary<string, object?> ContactToBackupWire(StoredContact contact)
    {
        var value = new Dictionary<string, object?>
        {
            ["key_id"] = contact.KeyId,
            ["display_name"] = contact.DisplayName,
            ["contact_json"] = contact.ContactJson,
        };
        if (!string.IsNullOrWhiteSpace(contact.Remark)) value["remark"] = contact.Remark.Trim();
        if (!string.IsNullOrWhiteSpace(contact.DeviceId)) value["device_id"] = contact.DeviceId;
        if (!string.IsNullOrWhiteSpace(contact.P2pTicket)) value["p2p_ticket"] = contact.P2pTicket;
        if (contact.P2pTicketUpdatedAtUnixMs is not null)
            value["p2p_ticket_updated_at_unix_ms"] = contact.P2pTicketUpdatedAtUnixMs.Value;
        value["human_verified"] = contact.HumanVerified;
        return value;
    }

    private static Dictionary<string, object?> GroupEventToBackupWire(GroupEventRecord groupEvent) => new()
    {
        ["event_id"] = groupEvent.EventId,
        ["group_id"] = groupEvent.GroupId,
        ["type"] = groupEvent.Type,
        ["actor_key_id"] = groupEvent.ActorKeyId,
        ["group_epoch"] = groupEvent.GroupEpoch,
        ["created_at_unix_ms"] = groupEvent.CreatedAtUnixMs,
        ["payload_json"] = groupEvent.PayloadJson,
    };

    private static GroupEventRecord ParseBackupGroupEvent(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("备份 group_event 不是 object。");
        return new GroupEventRecord(
            GetOptionalString(value, "event_id"),
            GetOptionalString(value, "group_id"),
            GetOptionalString(value, "type"),
            GetOptionalString(value, "actor_key_id"),
            value.TryGetProperty("group_epoch", out var epoch) && epoch.TryGetInt64(out var parsedEpoch)
                ? parsedEpoch
                : 0,
            value.TryGetProperty("created_at_unix_ms", out var created) && created.TryGetInt64(out var parsedCreated)
                ? parsedCreated
                : 0,
            value.TryGetProperty("payload_json", out var payload) && payload.ValueKind == JsonValueKind.String
                ? payload.GetString() ?? string.Empty
                : string.Empty);
    }

    private IReadOnlyList<GroupEventRecord> ValidatePortableGroupEvents(
        IReadOnlyList<GroupRecord> groups,
        IReadOnlyList<GroupMemberRecord> members,
        IReadOnlyList<GroupEventRecord> events)
    {
        // group_message is application data, not causal membership/control
        // proof. Messages are intentionally excluded from portable backups;
        // retaining their signed event wrappers would make a long-running chat
        // permanently exceed the history limits even though no proof is needed.
        var causalEvents = events
            .Where(item => item.Type != "group_message")
            .ToArray();
        if (causalEvents.Length > MaximumPortableGroupEvents)
            throw new InvalidDataException(
                $"portable backup group_events 超过 {MaximumPortableGroupEvents} 项上限。");
        Dictionary<string, GroupRecord> groupsById;
        try
        {
            groupsById = groups.ToDictionary(item => item.GroupId, StringComparer.Ordinal);
        }
        catch (ArgumentException error)
        {
            throw new InvalidDataException("portable backup 包含重复 group_id。", error);
        }

        var memberKeys = members
            .GroupBy(item => item.GroupId, StringComparer.Ordinal)
            .ToDictionary(
                group => group.Key,
                group => group.Select(item => item.KeyId).ToHashSet(StringComparer.Ordinal),
                StringComparer.Ordinal);
        var result = new List<GroupEventRecord>(causalEvents.Length);
        var byId = new Dictionary<string, GroupEventRecord>(StringComparer.Ordinal);
        long totalPayloadBytes = 0;
        foreach (var groupEvent in causalEvents)
        {
            var payloadJson = groupEvent.PayloadJson ?? string.Empty;
            var payloadBytes = Encoding.UTF8.GetByteCount(payloadJson);
            totalPayloadBytes = checked(totalPayloadBytes + payloadBytes);
            if (payloadBytes <= 0 || payloadBytes > MaximumPortableGroupEventPayloadBytes ||
                totalPayloadBytes > MaximumPortableGroupEventTotalBytes)
                throw new InvalidDataException("portable backup group_events payload 超出大小上限。");
            if (byId.TryGetValue(groupEvent.EventId, out var duplicate))
            {
                if (duplicate != groupEvent)
                    throw new InvalidDataException($"portable backup group_event id 冲突：{groupEvent.EventId}。");
                continue;
            }
            if (string.IsNullOrWhiteSpace(groupEvent.EventId) ||
                string.IsNullOrWhiteSpace(groupEvent.GroupId) ||
                string.IsNullOrWhiteSpace(groupEvent.ActorKeyId) ||
                !SupportedGroupEventTypes.Contains(groupEvent.Type) ||
                groupEvent.GroupEpoch <= 0 || groupEvent.CreatedAtUnixMs <= 0 ||
                !groupsById.TryGetValue(groupEvent.GroupId, out var currentGroup) ||
                groupEvent.GroupEpoch > currentGroup.Epoch ||
                !memberKeys.TryGetValue(groupEvent.GroupId, out var currentMemberKeys) ||
                !currentMemberKeys.Contains(groupEvent.ActorKeyId))
                throw new InvalidDataException($"portable backup group_event metadata 无效：{groupEvent.EventId}。");

            try
            {
                using var document = JsonDocument.Parse(payloadJson);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var protocol) || protocol != 1 ||
                    GetJsonString(root, "event_id") != groupEvent.EventId ||
                    GetJsonString(root, "type") != groupEvent.Type ||
                    GetJsonString(root, "actor_key_id") != groupEvent.ActorKeyId ||
                    !root.TryGetProperty("created_at_unix_ms", out var created) ||
                    !created.TryGetInt64(out var createdAt) || createdAt != groupEvent.CreatedAtUnixMs ||
                    !root.TryGetProperty("group", out var groupElement) ||
                    !root.TryGetProperty("members", out var membersElement) ||
                    membersElement.ValueKind != JsonValueKind.Array)
                    throw new InvalidDataException("group_event payload 字段不完整。");
                var eventGroup = ParseGroup(groupElement);
                if (eventGroup.GroupId != groupEvent.GroupId || eventGroup.Epoch != groupEvent.GroupEpoch)
                    throw new InvalidDataException("group_event payload group 与 metadata 不一致。");
                var historicalMembers = membersElement.EnumerateArray()
                    .Select(ParseGroupMember)
                    .Where(item => item.GroupId == groupEvent.GroupId)
                    .ToArray();
                var actor = historicalMembers.FirstOrDefault(item => item.KeyId == groupEvent.ActorKeyId)
                    ?? throw new InvalidDataException("group_event payload 缺少 actor member。");
                var parsedActor = _native.ParseContact(actor.ContactJson);
                if (parsedActor.KeyId != actor.KeyId)
                    throw new InvalidDataException("group_event actor contact key_id 不一致。");
                var signature = GetJsonString(root, "signature");
                if (signature.Length == 0)
                    throw new InvalidDataException("group_event payload 缺少 signature。");
                var verified = _native.VerifyContactSignature(
                    parsedActor.ContactJson,
                    GroupEventSignatureContext,
                    SerializeWithoutSignature(root),
                    signature);
                if (!verified.Valid || verified.KeyId != groupEvent.ActorKeyId)
                    throw new InvalidDataException("group_event payload signature 无效。");
            }
            catch (Exception error) when (error is JsonException or EnvelopeNativeException or KeyNotFoundException or InvalidOperationException)
            {
                throw new InvalidDataException(
                    $"portable backup group_event 校验失败：{groupEvent.EventId}。",
                    error);
            }
            byId.Add(groupEvent.EventId, groupEvent);
            result.Add(groupEvent);
        }
        return result;
    }

    private string? TryOpenAndroidBackupWrapper(
        string backupJson,
        RecoveryPhrase phrase,
        out IdentitySummary? recovered)
    {
        recovered = null;
        JsonDocument document;
        try { document = JsonDocument.Parse(backupJson); }
        catch (JsonException) { return null; }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var number) || number != 2 ||
                GetOptionalString(root, "kind") != AndroidLocalBackupFileKind)
                return null;
            if (GetOptionalString(root, "scheme") != AndroidLocalBackupOpaqueScheme)
                throw new InvalidDataException("不支持的 Android 本地备份加密格式。");
            if (!root.TryGetProperty("identity", out var identity) || identity.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("Android 本地备份缺少身份信息。");
            var displayName = GetOptionalString(identity, "display_name");
            var expectedKeyId = GetOptionalString(identity, "key_id");
            recovered = _native.RecoverIdentity(
                string.IsNullOrWhiteSpace(displayName) ? "Envelope User" : displayName,
                phrase);
            if (expectedKeyId.Length > 0 && recovered.KeyId != expectedKeyId)
                throw new CryptographicException("恢复词与 Android 备份身份不匹配。");
            var envelopeBase64 = GetOptionalString(root, "envelope_b64");
            if (envelopeBase64.Length == 0) throw new InvalidDataException("Android 本地备份缺少加密数据。");
            var ownContact = _native.ContactFromIdentity(recovered.IdentityJson);
            var payload = _native.DecryptOpaquePayload(recovered.IdentityJson, ownContact, envelopeBase64);
            if (payload.PayloadKind != "file" || payload.Mime != AndroidLocalBackupPayloadMime ||
                payload.SenderKeyId != recovered.KeyId || payload.RecipientKeyId != recovered.KeyId)
                throw new CryptographicException("Android 本地备份载荷身份或 MIME 无效。");
            var expectedHash = GetOptionalString(root, "payload_sha256").ToLowerInvariant();
            if (expectedHash.Length > 0)
            {
                var actualHash = Convert.ToHexString(SHA256.HashData(payload.PayloadBytes)).ToLowerInvariant();
                if (!CryptographicOperations.FixedTimeEquals(
                        Encoding.ASCII.GetBytes(actualHash),
                        Encoding.ASCII.GetBytes(expectedHash)))
                    throw new CryptographicException("Android 本地备份内容 SHA-256 校验失败。");
            }
            return Encoding.UTF8.GetString(payload.PayloadBytes);
        }
    }

    private static LocalBackupDto ParseLocalBackup(string plaintext)
    {
        using var document = JsonDocument.Parse(plaintext);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("本地备份不是 JSON object。");
        var kind = GetOptionalString(root, "kind");
        if (kind == "envelope.windows.local-backup")
        {
            var legacy = JsonSerializer.Deserialize<LocalBackupDto>(plaintext, Json)
                ?? throw new InvalidDataException("Windows 本地备份内容为空。");
            if (legacy.Version != 1 || string.IsNullOrWhiteSpace(legacy.IdentityKeyId) ||
                legacy.Contacts is null || legacy.Groups is null || legacy.GroupMembers is null)
                throw new InvalidDataException("Windows 本地备份字段不完整。");
            return legacy with { GroupEvents = legacy.GroupEvents ?? Array.Empty<GroupEventRecord>() };
        }

        if (kind != AndroidLocalBackupKind ||
            !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var protocolVersion) || protocolVersion != 1)
            throw new InvalidDataException("不支持的本地备份类型或版本。");
        if (!root.TryGetProperty("identity", out var identity) || identity.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Android 本地备份缺少 identity。");
        if (!root.TryGetProperty("store", out var store) || store.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Android 本地备份缺少 store。");
        var keyId = GetOptionalString(identity, "key_id");
        var displayName = GetOptionalString(identity, "display_name");
        if (keyId.Length == 0) throw new InvalidDataException("Android 本地备份 identity.key_id 为空。");

        var contacts = ReadArray(store, "contacts").Select(ParseBackupContact).ToArray();
        var groups = ReadArray(store, "groups").Select(ParseGroup).ToArray();
        var members = ReadArray(store, "group_members").Select(ParseGroupMember).ToArray();
        var groupEvents = store.TryGetProperty("group_events", out var groupEventsElement) &&
                          groupEventsElement.ValueKind == JsonValueKind.Array
            ? groupEventsElement.EnumerateArray().Select(ParseBackupGroupEvent).ToArray()
            : Array.Empty<GroupEventRecord>();
        var settings = root.TryGetProperty("settings", out var settingsElement) && settingsElement.ValueKind == JsonValueKind.Object
            ? settingsElement
            : default;
        var normalizedSettings = settings.ValueKind == JsonValueKind.Object
            ? new SecureStoreSettings(
                SyncServiceUrl: GetOptionalString(settings, "sync_service_url"),
                AutoBackupIntervalHours: GetOptionalInt32(settings, "auto_backup_interval_hours", 24),
                AutoBackupRetentionCount: GetOptionalInt32(settings, "auto_backup_retention_count", 7),
                LocalLockEnabled: GetOptionalBoolean(settings, "local_lock_enabled", false),
                AutoSyncEnabled: GetOptionalBoolean(settings, "auto_sync_enabled", true)).Normalize()
            : new SecureStoreSettings();
        var nextCounter = store.TryGetProperty("next_message_counter", out var counter) && counter.TryGetUInt64(out var parsedCounter)
            ? Math.Max(1, parsedCounter)
            : 1;
        var counterNamespace = store.TryGetProperty("counter_namespace", out var counterNamespaceElement) &&
                               counterNamespaceElement.TryGetUInt32(out var parsedNamespace)
            ? parsedNamespace
            : 0;
        var counterNamespaceBits = store.TryGetProperty("counter_namespace_bits", out var namespaceBitsElement) &&
                                   namespaceBitsElement.TryGetInt32(out var parsedNamespaceBits)
            ? parsedNamespaceBits
            : 0;
        var counterDeviceId = GetOptionalString(store, "counter_device_id");
        var receivedCounters = ParseReceivedCounterRanges(store);
        var createdAt = root.TryGetProperty("created_at_unix_ms", out var created) && created.TryGetInt64(out var parsedCreated)
            ? parsedCreated
            : 0;
        return new LocalBackupDto(
            AndroidLocalBackupKind,
            1,
            keyId,
            string.IsNullOrWhiteSpace(displayName) ? "Envelope User" : displayName,
            normalizedSettings,
            contacts,
            groups,
            members,
            groupEvents,
            createdAt,
            nextCounter,
            counterNamespace,
            counterNamespaceBits,
            counterDeviceId,
            receivedCounters);
    }

    private static StoredContact ParseBackupContact(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("备份 contact 不是 object。");
        var keyId = GetOptionalString(value, "key_id");
        var contactJson = GetOptionalString(value, "contact_json");
        if (keyId.Length == 0 || contactJson.Length == 0) throw new InvalidDataException("备份 contact 字段不完整。");
        return new StoredContact(
            keyId,
            GetOptionalString(value, "display_name"),
            contactJson,
            NullIfEmpty(GetOptionalString(value, "remark")),
            NullIfEmpty(GetOptionalString(value, "device_id")),
            NullIfEmpty(GetOptionalString(value, "p2p_ticket")),
            value.TryGetProperty("p2p_ticket_updated_at_unix_ms", out var updated) && updated.TryGetInt64(out var parsed)
                ? parsed
                : null,
            GetOptionalBoolean(value, "human_verified", false));
    }

    private static IReadOnlyList<GroupMemberRecord> NormalizePortableGroupTrust(
        IReadOnlyList<GroupRecord> groups,
        IReadOnlyList<GroupMemberRecord> members,
        string selfKeyId)
    {
        var policies = groups.ToDictionary(group => group.GroupId, StringComparer.Ordinal);
        return members.Select(member =>
        {
            if (!policies.TryGetValue(member.GroupId, out var group) || group.Policy != GroupPolicy.Verified)
                return member;
            var baseline = member.KeyId == selfKeyId
                ? GroupTrustState.Verified
                : member.KeyId == group.OwnerKeyId
                    ? GroupTrustState.Inviter
                    : GroupTrustState.Unverified;
            return member with { TrustState = baseline };
        }).ToArray();
    }

    private static IReadOnlyList<Dictionary<string, object?>> ReceivedCounterRangesToBackupWire(
        IEnumerable<ReceivedCounterRecord> counters)
    {
        var result = new List<Dictionary<string, object?>>();
        foreach (var sender in counters
                     .Where(item => !string.IsNullOrWhiteSpace(item.SenderKeyId) && item.MessageCounter > 0)
                     .GroupBy(item => item.SenderKeyId, StringComparer.Ordinal)
                     .OrderBy(group => group.Key, StringComparer.Ordinal))
        {
            var values = sender.Select(item => item.MessageCounter).Distinct().Order().ToArray();
            var ranges = new List<ulong[]>();
            for (var index = 0; index < values.Length;)
            {
                var start = values[index];
                var end = start;
                index++;
                while (index < values.Length && end != ulong.MaxValue && values[index] == end + 1)
                {
                    end = values[index];
                    index++;
                }
                ranges.Add([start, end]);
            }
            result.Add(new Dictionary<string, object?>
            {
                ["sender_key_id"] = sender.Key,
                ["ranges"] = ranges,
            });
        }
        return result;
    }

    private static IReadOnlyList<ReceivedCounterRecord> ParseReceivedCounterRanges(JsonElement store)
    {
        if (!store.TryGetProperty("received_counter_ranges", out var senders) ||
            senders.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return Array.Empty<ReceivedCounterRecord>();
        if (senders.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("备份 received_counter_ranges 不是 array。");

        const int maximumRestoredCounters = 1_000_000;
        var result = new List<ReceivedCounterRecord>();
        foreach (var senderElement in senders.EnumerateArray())
        {
            if (senderElement.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("备份 replay sender 不是 object。");
            var senderKeyId = GetOptionalString(senderElement, "sender_key_id");
            if (senderKeyId.Length == 0 || !senderElement.TryGetProperty("ranges", out var ranges) ||
                ranges.ValueKind != JsonValueKind.Array)
                throw new InvalidDataException("备份 replay sender 字段不完整。");
            foreach (var range in ranges.EnumerateArray())
            {
                if (range.ValueKind != JsonValueKind.Array)
                    throw new InvalidDataException("备份 replay range 不是 array。");
                var bounds = range.EnumerateArray().ToArray();
                if (bounds.Length != 2 || !bounds[0].TryGetUInt64(out var start) ||
                    !bounds[1].TryGetUInt64(out var end) || start == 0 || end < start ||
                    end - start >= (ulong)(maximumRestoredCounters - result.Count))
                    throw new InvalidDataException("备份 replay range 无效或过大。");
                for (var value = start;; value++)
                {
                    result.Add(new ReceivedCounterRecord(senderKeyId, value));
                    if (value == end) break;
                }
            }
        }
        return result.DistinctBy(item => (item.SenderKeyId, item.MessageCounter)).ToArray();
    }

    private static ulong RestoredCounterHighWater(
        ulong currentNextCounter,
        ulong backupNextCounter,
        uint backupCounterNamespace,
        int backupCounterNamespaceBits,
        uint localCounterNamespace,
        bool namespaceRotated)
    {
        const ulong restoreReservation = 1_024;
        const ulong maximumSequence = ulong.MaxValue >> WindowsClientState.CounterNamespaceBits;
        var currentSequence = currentNextCounter == 0
            ? 0
            : WindowsClientState.CounterSequence(currentNextCounter);
        var backupUsesNamespacedLane = backupCounterNamespaceBits == WindowsClientState.CounterNamespaceBits &&
                                       backupCounterNamespace > 0 &&
                                       backupCounterNamespace <= WindowsClientState.CounterNamespaceMask &&
                                       backupNextCounter >= WindowsClientState.CounterStride &&
                                       (backupNextCounter & WindowsClientState.CounterNamespaceMask) == backupCounterNamespace;
        var legacyNamespacedLane = backupCounterNamespaceBits == 0 &&
                                   backupCounterNamespace == 0 &&
                                   backupNextCounter >= WindowsClientState.CounterStride;
        // Android can re-export a Windows high-water while dropping Windows'
        // namespace metadata. Such a value no longer fits as a 32-bit lane
        // sequence; infer its high/low layout and rotate to a fresh local lane.
        // Raw Android values below 2^32 remain ordinary monotonic sequences.
        var backupSequence = backupNextCounter == 0
            ? 0
            : backupUsesNamespacedLane || legacyNamespacedLane
                ? WindowsClientState.CounterSequence(backupNextCounter)
                : backupNextCounter;
        var highWater = Math.Max(currentSequence, backupSequence);
        if (highWater > maximumSequence - restoreReservation)
        {
            if (!namespaceRotated)
                throw new InvalidDataException("本机消息计数器 lane 已耗尽，必须轮换设备 namespace 后恢复。");
            // A fresh random namespace is disjoint from the exhausted/legacy
            // lane, so it is safe to restart its local sequence at one.
            return WindowsClientState.ComposeCounter(1, localCounterNamespace);
        }
        var nextSequence = highWater + restoreReservation;
        return WindowsClientState.ComposeCounter(Math.Max(1, nextSequence), localCounterNamespace);
    }

    private static uint InferLegacyNamespacedCounterNamespace(
        ulong backupNextCounter,
        uint backupCounterNamespace,
        int backupCounterNamespaceBits)
    {
        if (backupCounterNamespace != 0 || backupCounterNamespaceBits != 0 ||
            backupNextCounter < WindowsClientState.CounterStride)
            return 0;
        return (uint)(backupNextCounter & WindowsClientState.CounterNamespaceMask);
    }

    private static IEnumerable<JsonElement> ReadArray(JsonElement parent, string propertyName)
    {
        if (!parent.TryGetProperty(propertyName, out var value) || value.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException($"本地备份缺少 {propertyName} 数组。");
        return value.EnumerateArray().ToArray();
    }

    private static string GetOptionalString(JsonElement value, string propertyName) =>
        value.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()?.Trim() ?? string.Empty
            : string.Empty;

    private static int GetOptionalInt32(JsonElement value, string propertyName, int fallback) =>
        value.TryGetProperty(propertyName, out var property) && property.TryGetInt32(out var parsed)
            ? parsed
            : fallback;

    private static bool GetOptionalBoolean(JsonElement value, string propertyName, bool fallback)
    {
        if (!value.TryGetProperty(propertyName, out var property)) return fallback;
        if (property.ValueKind is JsonValueKind.True or JsonValueKind.False) return property.GetBoolean();
        if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var number)) return number != 0;
        return fallback;
    }

    private static string? NullIfEmpty(string value) => value.Length == 0 ? null : value;

    private void PruneLocalBackups(int retentionCount, string currentPath)
    {
        var keep = Math.Max(1, retentionCount);
        var current = Path.GetFullPath(currentPath);
        var files = Directory
            .EnumerateFiles(_paths.Backups, "envelope-local-backup-*.json", SearchOption.TopDirectoryOnly)
            .Select(Path.GetFullPath)
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .ThenByDescending(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        foreach (var path in files.Skip(keep))
        {
            if (string.Equals(path, current, StringComparison.OrdinalIgnoreCase)) continue;
            File.Delete(path);
        }
    }

    private sealed record LocalBackupDto(
        string Kind,
        int Version,
        string IdentityKeyId,
        string DisplayName,
        SecureStoreSettings Settings,
        IReadOnlyList<StoredContact> Contacts,
        IReadOnlyList<GroupRecord> Groups,
        IReadOnlyList<GroupMemberRecord> GroupMembers,
        IReadOnlyList<GroupEventRecord> GroupEvents,
        long CreatedAtUnixMs,
        ulong NextMessageCounter = 1,
        uint CounterNamespace = 0,
        int CounterNamespaceBits = 0,
        string? CounterDeviceId = null,
        IReadOnlyList<ReceivedCounterRecord>? RestoredReceivedCounters = null)
    {
        public IReadOnlyList<ReceivedCounterRecord> ReceivedCounters =>
            RestoredReceivedCounters ?? Array.Empty<ReceivedCounterRecord>();
    }
}
