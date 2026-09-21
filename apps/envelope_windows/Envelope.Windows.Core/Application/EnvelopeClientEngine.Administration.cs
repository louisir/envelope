using System.Security.Cryptography;
using System.Text.Json;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Core.Application;

public sealed partial class EnvelopeClientEngine
{
    private const int MaximumManagedPlaintextTransitionFiles = 10_000;
    private const int MaximumManagedPlaintextManifestBytes = 4 * 1024 * 1024;

    private sealed record ManagedPlaintextQuarantineEntry(
        string OriginalPath,
        string StagedFileName);

    private sealed record ManagedPlaintextQuarantineManifest(
        int Version,
        string TransitionId,
        IReadOnlyList<ManagedPlaintextQuarantineEntry> Entries);

    private sealed record ManagedPlaintextQuarantine(
        string TransitionId,
        string DirectoryPath,
        IReadOnlyList<ManagedPlaintextQuarantineEntry> Entries);

    public async Task<int> MarkConversationReadAsync(
        string conversationId,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var changed = 0;
            for (var index = 0; index < _state.Messages.Count; index++)
            {
                var message = _state.Messages[index];
                if (message.ConversationId != conversationId ||
                    message.Direction != MessageDirection.Incoming ||
                    message.IsHidden ||
                    message.IsRead)
                    continue;
                _state.Messages[index] = message with { IsRead = true };
                changed++;
            }
            if (changed == 0) return 0;
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return changed;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<TResult> ReadStateAsync<TResult>(
        Func<WindowsClientState, TResult> reader,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(reader);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return reader(_state); }
        finally { _gate.Release(); }
    }

    public IntroBundleSummary CreateIntroBundle(ulong ttlSeconds = 600)
    {
        var identity = RequireIdentity();
        return _native.CreateIntroBundle(
            identity.IdentityJson,
            _state.DeviceId,
            _state.CurrentP2pTicket ?? string.Empty,
            ttlSeconds);
    }

    public async Task UpdateSettingsAsync(
        SecureStoreSettings settings,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            _state.Settings = settings.Normalize();
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
    }

    public async Task ClearIdentityAsync(CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        await _p2p.StopAsync().ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var previousState = CloneClientStateCore(_state);
            ManagedPlaintextQuarantine? quarantine = null;
            try
            {
                quarantine = StageManagedIdentityPlaintextCore(cancellationToken);
                var preservedSettings = _state.Settings.Normalize() with { AutoBackupLastAtUnixMs = null };
                var preservedDeviceId = _state.DeviceId;
                ArchiveCurrentReceivedCountersCore();
                var preservedReplayArchive = _state.ReceivedCounterArchive.ToArray();
                var retiredCounterNamespaces = _state.RetiredCounterNamespaces
                    .Append(_state.CounterNamespace)
                    .Where(value => value != 0)
                    .Distinct()
                    .ToArray();
                var clearedState = new WindowsClientState
                {
                    DeviceId = preservedDeviceId,
                    CounterNamespace = WindowsClientState.CreateCounterNamespace(
                        retiredCounterNamespaces.ToHashSet()),
                    NextMessageCounter = 1,
                    Settings = preservedSettings,
                    ManagedPlaintextCleanupId = quarantine?.TransitionId,
                };
                clearedState.Validate();
                clearedState.ReceivedCounterArchive.AddRange(preservedReplayArchive);
                clearedState.RetiredCounterNamespaces.AddRange(retiredCounterNamespaces);
                _state = clearedState;
                // One authenticated-slot replacement avoids a crash window in
                // which DeleteState succeeded but the replay archive/settings
                // had not yet been saved.
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
                            "清除身份状态提交失败，且托管明文 rollback 未能完整恢复。",
                            new AggregateException(error, rollbackError));
                    }
                }
                throw;
            }
            await CommitManagedPlaintextTransitionCoreAsync(quarantine, CancellationToken.None)
                .ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        RaiseStateChanged();
    }

    public async Task<int> RetryPendingAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var delivered = 0;
        try
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var pending in _state.PendingEnvelopes.ToArray())
            {
                if (pending.Ha?.DeliveryState is HaDeliveryState.Delivered or HaDeliveryState.Rejected or HaDeliveryState.Expired) continue;
                if (pending.DeliveryState is not (DeliveryState.Pending or DeliveryState.Failed)) continue;
                if (pending.NextAttemptAtUnixMs is > 0 && pending.NextAttemptAtUnixMs > now) continue;
                var contact = ResolvePendingRecipient(pending);
                if (contact is null)
                {
                    var index = _state.PendingEnvelopes.FindIndex(item => item.EnvelopeId == pending.EnvelopeId);
                    if (index >= 0)
                    {
                        _state.PendingEnvelopes[index] = pending with
                        {
                            LastError = "找不到经过 key_id 校验的收件人 contact；outbox 已保留。",
                            NextAttemptAtUnixMs = DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeMilliseconds(),
                        };
                    }
                    continue;
                }
                var result = await DeliverEnvelopeCoreAsync(
                    contact,
                    pending.EnvelopeId,
                    pending.EnvelopeBase64,
                    cancellationToken,
                    pending.LogicalMessageId,
                    pending.ChildIndex,
                    pending.ChildCount).ConfigureAwait(false);
                if (result.State is DeliveryState.Sent or DeliveryState.ServerMailbox or DeliveryState.Delivered)
                {
                    delivered++;
                }
            }
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        if (delivered > 0) RaiseStateChanged();
        return delivered;
    }

    private StoredContact? ResolvePendingRecipient(PendingEnvelopeRecord pending)
    {
        var current = KnownSenderCandidates(pending.RecipientKeyId).FirstOrDefault();
        if (current is not null) return current;
        if (string.IsNullOrWhiteSpace(pending.RecipientContactJson)) return null;
        try
        {
            var parsed = _native.ParseContact(pending.RecipientContactJson);
            if (parsed.KeyId != pending.RecipientKeyId) return null;
            return new StoredContact(parsed.KeyId, parsed.DisplayName, parsed.ContactJson);
        }
        catch (EnvelopeNativeException)
        {
            return null;
        }
    }

    public async Task<int> ClearFileCacheAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var removed = 0;
            foreach (var directory in new[] { _paths.Received, _paths.Sealed })
            {
                if (!Directory.Exists(directory) ||
                    (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) continue;
                var safeDirectory = Path.GetFullPath(directory);
                foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.TopDirectoryOnly))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var fullFile = Path.GetFullPath(file);
                    if (!IsPathInsideRoot(fullFile, safeDirectory)) continue;
                    try
                    {
                        if ((File.GetAttributes(fullFile) & FileAttributes.ReparsePoint) != 0) continue;
                        File.Delete(fullFile);
                        removed++;
                    }
                    catch { }
                }
            }

            var transferRoot = Path.GetFullPath(Path.Combine(_paths.Cache, "transfers"));
            if (Directory.Exists(transferRoot) &&
                (File.GetAttributes(transferRoot) & FileAttributes.ReparsePoint) == 0)
            {
                foreach (var directory in Directory.EnumerateDirectories(
                             transferRoot,
                             "*",
                             SearchOption.TopDirectoryOnly))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var fullDirectory = Path.GetFullPath(directory);
                    if (!IsPathInsideRoot(fullDirectory, transferRoot) ||
                        (File.GetAttributes(fullDirectory) & FileAttributes.ReparsePoint) != 0)
                        continue;
                    foreach (var file in Directory.EnumerateFiles(fullDirectory, "*", SearchOption.TopDirectoryOnly)
                                 .Where(path => IsManagedTransferPartFileNameCore(Path.GetFileName(path))))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var fullFile = Path.GetFullPath(file);
                        if (!IsPathInsideRoot(fullFile, transferRoot)) continue;
                        try
                        {
                            if ((File.GetAttributes(fullFile) & FileAttributes.ReparsePoint) != 0) continue;
                            File.Delete(fullFile);
                            removed++;
                        }
                        catch { }
                    }
                    try
                    {
                        if (!Directory.EnumerateFileSystemEntries(fullDirectory).Any()) Directory.Delete(fullDirectory);
                    }
                    catch { }
                }
                foreach (var file in Directory.EnumerateFiles(transferRoot, "complete-*.tmp", SearchOption.TopDirectoryOnly))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var fullFile = Path.GetFullPath(file);
                    if (!IsPathInsideRoot(fullFile, transferRoot)) continue;
                    try
                    {
                        if ((File.GetAttributes(fullFile) & FileAttributes.ReparsePoint) != 0) continue;
                        File.Delete(fullFile);
                        removed++;
                    }
                    catch { }
                }
            }
            for (var index = 0; index < _state.Messages.Count; index++)
            {
                if (_state.Messages[index].AttachmentPath is { } path && !File.Exists(path))
                    _state.Messages[index] = _state.Messages[index] with { AttachmentPath = null };
            }
            for (var index = 0; index < _state.SealedEnvelopes.Count; index++)
            {
                if (!File.Exists(_state.SealedEnvelopes[index].Path))
                    _state.SealedEnvelopes[index] = _state.SealedEnvelopes[index] with { FileExists = false };
            }
            _state.InboundFileChunks.RemoveAll(item => !File.Exists(item.CachePath));
            _state.InboundFileTransfers.RemoveAll(transfer =>
                transfer.CompletedPath is not null && !File.Exists(transfer.CompletedPath));
            _state.InboundFileTransfers.RemoveAll(transfer =>
                transfer.CompletedPath is null && !_state.InboundFileChunks.Any(chunk =>
                    chunk.TransferId == transfer.TransferId && chunk.SenderKeyId == transfer.SenderKeyId &&
                    chunk.ConversationId == transfer.ConversationId));
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            RaiseStateChanged();
            return removed;
        }
        finally { _gate.Release(); }
    }

    private static bool IsPathInsideRoot(string path, string root)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        var normalizedPath = Path.GetFullPath(path);
        return normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private ManagedPlaintextQuarantine? StageManagedIdentityPlaintextCore(
        CancellationToken cancellationToken)
    {
        var sourceFiles = EnumerateManagedIdentityPlaintextCore(cancellationToken)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (sourceFiles.Length == 0) return null;
        if (sourceFiles.Length > MaximumManagedPlaintextTransitionFiles)
            throw new IOException(
                $"托管明文文件超过 {MaximumManagedPlaintextTransitionFiles} 项，拒绝身份切换。");

        var transitionRoot = ManagedPlaintextTransitionRootCore();
        Directory.CreateDirectory(transitionRoot);
        ValidateSafeDirectoryCore(transitionRoot, Path.GetFullPath(_paths.Cache));
        var transitionId = Guid.NewGuid().ToString("N");
        var transitionDirectory = Path.GetFullPath(Path.Combine(transitionRoot, transitionId));
        if (!IsPathInsideRoot(transitionDirectory, transitionRoot))
            throw new IOException("托管明文 rollback 目录越界。");
        Directory.CreateDirectory(transitionDirectory);
        var entries = sourceFiles.Select((path, index) => new ManagedPlaintextQuarantineEntry(
                path,
                $"{index:D8}.rollback"))
            .ToArray();
        var quarantine = new ManagedPlaintextQuarantine(
            transitionId,
            transitionDirectory,
            entries);
        WriteManagedPlaintextManifestCore(quarantine);

        try
        {
            foreach (var entry in entries)
            {
                cancellationToken.ThrowIfCancellationRequested();
                ValidateManagedIdentityPlaintextPathCore(entry.OriginalPath);
                var stagedPath = ManagedPlaintextStagedPathCore(quarantine, entry);
                CopyFileDurablyCore(entry.OriginalPath, stagedPath);
                if (!FilesEqualCore(entry.OriginalPath, stagedPath))
                    throw new IOException($"托管明文 rollback 副本校验失败：{entry.OriginalPath}");
                DeleteManagedFileOrThrow(entry.OriginalPath, Path.GetDirectoryName(entry.OriginalPath)!);
            }
            return quarantine;
        }
        catch (Exception error)
        {
            try
            {
                RollbackManagedPlaintextCore(quarantine, CancellationToken.None);
            }
            catch (Exception rollbackError)
            {
                throw new IOException(
                    "托管明文暂存失败，且 rollback 未能完整恢复。",
                    new AggregateException(error, rollbackError));
            }
            throw;
        }
    }

    private IReadOnlyList<string> EnumerateManagedIdentityPlaintextCore(
        CancellationToken cancellationToken)
    {
        var files = new List<string>();
        foreach (var directory in new[] { _paths.Received, _paths.Sealed })
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Directory.Exists(directory)) continue;
            var root = Path.GetFullPath(directory);
            ValidateSafeDirectoryCore(root, root);
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var fullPath = Path.GetFullPath(file);
                ValidateManagedIdentityPlaintextPathCore(fullPath);
                files.Add(fullPath);
            }
        }

        var cacheRoot = Path.GetFullPath(_paths.Cache);
        if (Directory.Exists(cacheRoot)) ValidateSafeDirectoryCore(cacheRoot, cacheRoot);
        var transferRoot = Path.GetFullPath(Path.Combine(cacheRoot, "transfers"));
        if (!Directory.Exists(transferRoot)) return files;
        ValidateSafeDirectoryCore(transferRoot, cacheRoot);
        foreach (var file in Directory.EnumerateFiles(
                     transferRoot,
                     "complete-*.tmp",
                     SearchOption.TopDirectoryOnly))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var fullPath = Path.GetFullPath(file);
            ValidateManagedIdentityPlaintextPathCore(fullPath);
            files.Add(fullPath);
        }
        foreach (var directory in Directory.EnumerateDirectories(
                     transferRoot,
                     "*",
                     SearchOption.TopDirectoryOnly))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var scopedRoot = Path.GetFullPath(directory);
            ValidateSafeDirectoryCore(scopedRoot, transferRoot);
            foreach (var file in Directory.EnumerateFiles(scopedRoot, "*", SearchOption.TopDirectoryOnly)
                         .Where(path => IsManagedTransferPartFileNameCore(Path.GetFileName(path))))
            {
                var fullPath = Path.GetFullPath(file);
                ValidateManagedIdentityPlaintextPathCore(fullPath);
                files.Add(fullPath);
            }
        }
        return files;
    }

    private string ManagedPlaintextTransitionRootCore() =>
        Path.GetFullPath(Path.Combine(_paths.Cache, "identity-transitions"));

    private static void ValidateSafeDirectoryCore(string directory, string root)
    {
        var fullDirectory = Path.GetFullPath(directory);
        var fullRoot = Path.GetFullPath(root);
        if (fullDirectory != fullRoot && !IsPathInsideRoot(fullDirectory, fullRoot))
            throw new IOException($"托管目录越界：{fullDirectory}");
        if ((File.GetAttributes(fullDirectory) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"托管目录是 reparse point：{fullDirectory}");
    }

    private void ValidateManagedIdentityPlaintextPathCore(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath)) throw new FileNotFoundException("托管明文文件不存在。", fullPath);
        if ((File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"托管明文文件是 reparse point：{fullPath}");

        ValidateManagedIdentityPlaintextRestorePathCore(fullPath);
    }

    private void ValidateManagedIdentityPlaintextRestorePathCore(string path)
    {
        var fullPath = Path.GetFullPath(path);

        var parent = Path.GetFullPath(Path.GetDirectoryName(fullPath)
                                      ?? throw new IOException("托管明文文件缺少父目录。"));
        var received = Path.GetFullPath(_paths.Received);
        var sealedRoot = Path.GetFullPath(_paths.Sealed);
        if (parent.Equals(received, StringComparison.OrdinalIgnoreCase) ||
            parent.Equals(sealedRoot, StringComparison.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(parent))
                throw new IOException($"托管明文根目录不存在：{parent}");
            ValidateSafeDirectoryCore(parent, parent);
            return;
        }

        var transferRoot = Path.GetFullPath(Path.Combine(_paths.Cache, "transfers"));
        if (parent.Equals(transferRoot, StringComparison.OrdinalIgnoreCase) &&
            Path.GetFileName(fullPath).StartsWith("complete-", StringComparison.Ordinal) &&
            Path.GetExtension(fullPath).Equals(".tmp", StringComparison.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(parent))
                throw new IOException("文件传输缓存根目录不存在。");
            ValidateSafeDirectoryCore(parent, Path.GetFullPath(_paths.Cache));
            return;
        }
        var parentOfParent = Path.GetDirectoryName(parent);
        if (parentOfParent is not null &&
            Path.GetFullPath(parentOfParent).Equals(transferRoot, StringComparison.OrdinalIgnoreCase) &&
            IsManagedTransferPartFileNameCore(Path.GetFileName(fullPath)))
        {
            if (!Directory.Exists(transferRoot))
                throw new IOException("文件传输缓存根目录不存在。");
            ValidateSafeDirectoryCore(transferRoot, Path.GetFullPath(_paths.Cache));
            if (Directory.Exists(parent)) ValidateSafeDirectoryCore(parent, transferRoot);
            return;
        }
        throw new IOException($"文件不属于托管身份明文范围：{fullPath}");
    }

    private static bool IsManagedTransferPartFileNameCore(string fileName) =>
        fileName.EndsWith(".part", StringComparison.OrdinalIgnoreCase) ||
        fileName.Contains(".part.partial-", StringComparison.OrdinalIgnoreCase);

    private void WriteManagedPlaintextManifestCore(ManagedPlaintextQuarantine quarantine)
    {
        var manifest = new ManagedPlaintextQuarantineManifest(
            1,
            quarantine.TransitionId,
            quarantine.Entries);
        var json = JsonSerializer.Serialize(manifest, Json);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > MaximumManagedPlaintextManifestBytes)
            throw new IOException("托管明文 rollback manifest 超出大小上限。");
        var manifestPath = Path.Combine(quarantine.DirectoryPath, "manifest.json");
        var temporaryPath = Path.Combine(quarantine.DirectoryPath, "manifest.tmp");
        File.WriteAllText(temporaryPath, json, new System.Text.UTF8Encoding(false));
        File.Move(temporaryPath, manifestPath);
    }

    private static string ManagedPlaintextStagedPathCore(
        ManagedPlaintextQuarantine quarantine,
        ManagedPlaintextQuarantineEntry entry)
    {
        var path = Path.GetFullPath(Path.Combine(quarantine.DirectoryPath, entry.StagedFileName));
        if (!IsPathInsideRoot(path, quarantine.DirectoryPath) ||
            !Path.GetFullPath(Path.GetDirectoryName(path)!).Equals(
                Path.GetFullPath(quarantine.DirectoryPath),
                StringComparison.OrdinalIgnoreCase))
            throw new IOException("托管明文 rollback 文件路径越界。");
        return path;
    }

    private static void CopyFileDurablyCore(string sourcePath, string destinationPath)
    {
        using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.SequentialScan);
        using var destination = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            128 * 1024,
            FileOptions.WriteThrough | FileOptions.SequentialScan);
        source.CopyTo(destination, 128 * 1024);
        destination.Flush(flushToDisk: true);
    }

    private static bool FilesEqualCore(string leftPath, string rightPath)
    {
        var left = new FileInfo(leftPath);
        var right = new FileInfo(rightPath);
        if (left.Length != right.Length) return false;
        using var leftStream = File.OpenRead(leftPath);
        using var rightStream = File.OpenRead(rightPath);
        return CryptographicOperations.FixedTimeEquals(
            SHA256.HashData(leftStream),
            SHA256.HashData(rightStream));
    }

    private void RollbackManagedPlaintextCore(
        ManagedPlaintextQuarantine quarantine,
        CancellationToken cancellationToken)
    {
        foreach (var entry in quarantine.Entries.Reverse())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var stagedPath = ManagedPlaintextStagedPathCore(quarantine, entry);
            if (!File.Exists(stagedPath)) continue;
            if ((File.GetAttributes(stagedPath) & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"rollback 文件是 reparse point：{stagedPath}");

            var originalPath = Path.GetFullPath(entry.OriginalPath);
            ValidateManagedIdentityPlaintextRestorePathCore(originalPath);
            var originalDirectory = Path.GetDirectoryName(originalPath)
                                    ?? throw new IOException("rollback 原路径缺少父目录。");
            if (!Directory.Exists(originalDirectory)) Directory.CreateDirectory(originalDirectory);
            if (File.Exists(originalPath))
            {
                ValidateManagedIdentityPlaintextPathCore(originalPath);
                if (!FilesEqualCore(originalPath, stagedPath))
                    throw new IOException($"rollback 原文件与暂存副本冲突：{originalPath}");
                DeleteManagedFileOrThrow(stagedPath, quarantine.DirectoryPath);
                continue;
            }

            ValidateSafeDirectoryCore(originalDirectory, originalDirectory);
            var temporaryPath = originalPath + $".restore-{Guid.NewGuid():N}.tmp";
            try
            {
                CopyFileDurablyCore(stagedPath, temporaryPath);
                if (!FilesEqualCore(stagedPath, temporaryPath))
                    throw new IOException($"rollback 恢复副本校验失败：{originalPath}");
                File.Move(temporaryPath, originalPath);
                DeleteManagedFileOrThrow(stagedPath, quarantine.DirectoryPath);
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }
        DeleteManagedPlaintextQuarantineCore(quarantine);
    }

    private static void DeleteManagedPlaintextQuarantineCore(ManagedPlaintextQuarantine quarantine)
    {
        var directory = Path.GetFullPath(quarantine.DirectoryPath);
        if (!Directory.Exists(directory)) return;
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"rollback 目录是 reparse point：{directory}");
        foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.TopDirectoryOnly))
            DeleteManagedFileOrThrow(file, directory);
        if (Directory.EnumerateFileSystemEntries(directory).Any())
            throw new IOException($"rollback 目录包含未知子项：{directory}");
        Directory.Delete(directory);
    }

    private int RecoverManagedPlaintextTransitionsCore(CancellationToken cancellationToken)
    {
        var transitionRoot = ManagedPlaintextTransitionRootCore();
        var changed = 0;
        if (Directory.Exists(transitionRoot))
        {
            ValidateSafeDirectoryCore(transitionRoot, Path.GetFullPath(_paths.Cache));
            foreach (var directory in Directory.EnumerateDirectories(
                         transitionRoot,
                         "*",
                         SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var fullDirectory = Path.GetFullPath(directory);
                ValidateSafeDirectoryCore(fullDirectory, transitionRoot);
                var manifestPath = Path.Combine(fullDirectory, "manifest.json");
                if (!File.Exists(manifestPath))
                {
                    var entries = Directory.EnumerateFileSystemEntries(fullDirectory).ToArray();
                    if (entries.All(path => Path.GetFileName(path) == "manifest.tmp"))
                    {
                        foreach (var path in entries) File.Delete(path);
                        Directory.Delete(fullDirectory);
                        changed++;
                        continue;
                    }
                    throw new IOException($"rollback 目录缺少 manifest：{fullDirectory}");
                }
                if (new FileInfo(manifestPath).Length > MaximumManagedPlaintextManifestBytes)
                    throw new IOException("rollback manifest 超出大小上限。");
                var manifest = JsonSerializer.Deserialize<ManagedPlaintextQuarantineManifest>(
                                   File.ReadAllText(manifestPath),
                                   Json)
                               ?? throw new InvalidDataException("rollback manifest 为空。");
                if (manifest.Version != 1 ||
                    manifest.TransitionId != Path.GetFileName(fullDirectory) ||
                    manifest.Entries is null ||
                    manifest.Entries.Count > MaximumManagedPlaintextTransitionFiles ||
                    manifest.Entries.Any(entry =>
                        string.IsNullOrWhiteSpace(entry.OriginalPath) ||
                        string.IsNullOrWhiteSpace(entry.StagedFileName) ||
                        Path.GetFileName(entry.StagedFileName) != entry.StagedFileName ||
                        !entry.StagedFileName.EndsWith(".rollback", StringComparison.Ordinal)) ||
                    manifest.Entries.Select(entry => entry.OriginalPath)
                        .Distinct(StringComparer.OrdinalIgnoreCase).Count() != manifest.Entries.Count ||
                    manifest.Entries.Select(entry => entry.StagedFileName)
                        .Distinct(StringComparer.OrdinalIgnoreCase).Count() != manifest.Entries.Count)
                    throw new InvalidDataException("rollback manifest 字段无效。");
                var quarantine = new ManagedPlaintextQuarantine(
                    manifest.TransitionId,
                    fullDirectory,
                    manifest.Entries);
                if (_state.ManagedPlaintextCleanupId == quarantine.TransitionId)
                    DeleteManagedPlaintextQuarantineCore(quarantine);
                else
                    RollbackManagedPlaintextCore(quarantine, cancellationToken);
                changed++;
            }
        }
        if (!string.IsNullOrWhiteSpace(_state.ManagedPlaintextCleanupId))
        {
            _state.ManagedPlaintextCleanupId = null;
            changed++;
        }
        return changed;
    }

    private static WindowsClientState CloneClientStateCore(WindowsClientState state) =>
        JsonSerializer.Deserialize<WindowsClientState>(
            JsonSerializer.Serialize(state, Json),
            Json)
        ?? throw new InvalidDataException("无法克隆 Windows 客户端状态。");

    private async Task CommitManagedPlaintextTransitionCoreAsync(
        ManagedPlaintextQuarantine? quarantine,
        CancellationToken cancellationToken)
    {
        if (quarantine is null) return;
        try
        {
            DeleteManagedPlaintextQuarantineCore(quarantine);
            _state.ManagedPlaintextCleanupId = null;
            await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // The newly committed identity state already references no old
            // plaintext. Keep the durable marker so startup can finish deleting
            // the private rollback copy without restoring it.
            _state.ManagedPlaintextCleanupId = quarantine.TransitionId;
        }
    }

    private static void DeleteManagedFileOrThrow(string path, string root)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathInsideRoot(fullPath, root) ||
            (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
            throw new IOException($"托管文件路径不安全，拒绝删除：{fullPath}");
        File.Delete(fullPath);
        if (File.Exists(fullPath)) throw new IOException($"托管文件删除失败：{fullPath}");
    }

    public async Task<int> DeleteLocalMessagesAsync(
        IReadOnlyCollection<string> envelopeIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(envelopeIds);
        var ids = envelopeIds.Where(id => !string.IsNullOrWhiteSpace(id))
            .ToHashSet(StringComparer.Ordinal);
        if (ids.Count == 0) return 0;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var removed = _state.Messages.RemoveAll(message => ids.Contains(message.EnvelopeId));
            if (removed > 0) await PersistCoreAsync(cancellationToken).ConfigureAwait(false);
            if (removed > 0) RaiseStateChanged();
            return removed;
        }
        finally { _gate.Release(); }
    }
}
