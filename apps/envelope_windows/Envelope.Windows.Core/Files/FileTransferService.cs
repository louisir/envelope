using System.Buffers;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace Envelope.Windows.Core.Files;

public sealed record FileChunkDescriptor(
    [property: JsonPropertyName("index")] int Index,
    [property: JsonPropertyName("size")] int Size,
    [property: JsonPropertyName("sha256")] string Sha256);

public sealed record FileTransferManifest(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("transfer_id")] string TransferId,
    [property: JsonPropertyName("filename")] string FileName,
    [property: JsonPropertyName("mime")] string Mime,
    [property: JsonPropertyName("total_size")] long TotalSize,
    [property: JsonPropertyName("chunk_size")] int ChunkSize,
    [property: JsonPropertyName("file_sha256")] string FileSha256,
    [property: JsonPropertyName("chunks")] IReadOnlyList<FileChunkDescriptor> Chunks);

public sealed class FileTransferService
{
    public const long MaximumOnlineFileBytes = 64L * 1024 * 1024;
    public const int DefaultChunkBytes = 4 * 1024 * 1024;

    public async Task<FileTransferManifest> ScanAsync(
        string path,
        string mime = "application/octet-stream",
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var file = new FileInfo(path);
        if (!file.Exists)
        {
            throw new FileNotFoundException("待发送文件不存在。", path);
        }

        if (file.Length > MaximumOnlineFileBytes)
        {
            throw new InvalidOperationException("在线文件不能超过 64 MiB；请改用离线密封。 ");
        }

        var chunks = new List<FileChunkDescriptor>();
        using var wholeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await using var input = file.Open(FileMode.Open, FileAccess.Read, FileShare.Read);
        var buffer = ArrayPool<byte>.Shared.Rent(DefaultChunkBytes);
        try
        {
            var index = 0;
            while (true)
            {
                var read = await ReadChunkAsync(input, buffer, cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }

                wholeHash.AppendData(buffer, 0, read);
                var chunkHash = SHA256.HashData(buffer.AsSpan(0, read));
                chunks.Add(new FileChunkDescriptor(index++, read, Base64Url(chunkHash)));
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
            ArrayPool<byte>.Shared.Return(buffer);
        }

        // Android represents an empty file as one authenticated empty chunk.
        // Keeping that invariant makes chunk_count positive on both clients.
        if (chunks.Count == 0)
        {
            chunks.Add(new FileChunkDescriptor(0, 0, Base64Url(SHA256.HashData(ReadOnlySpan<byte>.Empty))));
        }

        return new FileTransferManifest(
            1,
            Guid.NewGuid().ToString("N"),
            file.Name,
            string.IsNullOrWhiteSpace(mime) ? "application/octet-stream" : mime,
            file.Length,
            DefaultChunkBytes,
            Base64Url(wholeHash.GetHashAndReset()),
            chunks);
    }

    public async IAsyncEnumerable<(int Index, byte[] Bytes)> ReadChunksAsync(
        string path,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var input = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var index = 0;
        if (input.Length == 0)
        {
            yield return (0, Array.Empty<byte>());
            yield break;
        }

        while (true)
        {
            var buffer = new byte[DefaultChunkBytes];
            var read = await ReadChunkAsync(input, buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                yield break;
            }

            if (read != buffer.Length)
            {
                Array.Resize(ref buffer, read);
            }

            yield return (index++, buffer);
        }
    }

    public async Task<IReadOnlyList<(int Index, byte[] Bytes)>> ReadVerifiedChunksAsync(
        string path,
        FileTransferManifest manifest,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var chunks = new List<(int Index, byte[] Bytes)>(manifest.Chunks.Count);
        using var wholeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long totalSize = 0;
        await foreach (var chunk in ReadChunksAsync(path, cancellationToken))
        {
            if (chunk.Index < 0 || chunk.Index >= manifest.Chunks.Count)
                throw new InvalidDataException("发送源文件在扫描后增长，分片数量已改变。");
            VerifyChunk(manifest.Chunks[chunk.Index], chunk.Bytes);
            wholeHash.AppendData(chunk.Bytes);
            totalSize = checked(totalSize + chunk.Bytes.LongLength);
            chunks.Add(chunk);
        }

        var actualHash = Base64Url(wholeHash.GetHashAndReset());
        if (chunks.Count != manifest.Chunks.Count || totalSize != manifest.TotalSize ||
            !CryptographicOperations.FixedTimeEquals(
                System.Text.Encoding.ASCII.GetBytes(actualHash),
                System.Text.Encoding.ASCII.GetBytes(manifest.FileSha256)))
            throw new InvalidDataException("发送源文件在扫描后发生变化，拒绝创建不完整 outbox batch。");
        return chunks;
    }

    public static void VerifyChunk(FileChunkDescriptor descriptor, ReadOnlySpan<byte> bytes)
    {
        if (descriptor.Size != bytes.Length ||
            !CryptographicOperations.FixedTimeEquals(
                System.Text.Encoding.ASCII.GetBytes(descriptor.Sha256),
                System.Text.Encoding.ASCII.GetBytes(Base64Url(SHA256.HashData(bytes)))))
        {
            throw new CryptographicException($"文件分片 {descriptor.Index} 哈希校验失败。");
        }
    }

    private static async Task<int> ReadChunkAsync(Stream input, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await input.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }
            offset += read;
        }
        return offset;
    }

    private static string Base64Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
