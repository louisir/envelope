using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace Envelope.Windows.Services;

public sealed record DecodedIntroPayload(
    string BundleJson,
    string? SessionId = null,
    string? ServerUrl = null);

/// <summary>
/// Android-compatible clipboard representation for the temporary contact QR.
/// Android encodes either an IntroBundle object or a version-2 wrapper as
/// gzip-compressed UTF-8 JSON behind the envelope-intro-v1 prefix.
/// </summary>
public static class IntroPayloadCodec
{
    public const string Prefix = "envelope-intro-v1:";
    private const int MaximumDecodedBytes = 1024 * 1024;

    public static string Encode(string bundleJson)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(bundleJson);
        using var document = JsonDocument.Parse(bundleJson);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("IntroBundle 必须是 JSON object。");

        return EncodeJson(document.RootElement.GetRawText());
    }

    public static string Encode(
        string bundleJson,
        string sessionId,
        string serverUrl)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(bundleJson);
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(serverUrl);
        using var document = JsonDocument.Parse(bundleJson);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("IntroBundle 必须是 JSON object。");
        var wrapper = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["version"] = 2,
            ["bundle"] = document.RootElement.Clone(),
            ["intro_session_id"] = sessionId.Trim(),
            ["server_url"] = serverUrl.Trim(),
        });
        return EncodeJson(wrapper);
    }

    private static string EncodeJson(string json)
    {
        var plaintext = Encoding.UTF8.GetBytes(json);
        using var compressed = new MemoryStream();
        using (var gzip = new GZipStream(compressed, CompressionLevel.SmallestSize, leaveOpen: true))
            gzip.Write(plaintext);
        return Prefix + Base64UrlEncode(compressed.ToArray());
    }

    public static DecodedIntroPayload Decode(string contactOrPayload)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(contactOrPayload);
        var text = contactOrPayload.Trim();
        if (text.StartsWith(Prefix, StringComparison.Ordinal))
        {
            var encoded = text[Prefix.Length..].Trim();
            if (encoded.Length == 0) throw new InvalidDataException("临时加好友载荷为空。");

            // Compatibility with early Windows builds that incorrectly placed
            // uncompressed JSON after the Android prefix.
            text = encoded.StartsWith('{')
                ? encoded
                : DecompressUtf8(Base64UrlDecode(encoded));
        }

        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Contact / IntroBundle 必须是 JSON object。");

        if (root.TryGetProperty("bundle", out var bundle))
        {
            if (bundle.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("临时加好友 wrapper.bundle 无效。");
            return new DecodedIntroPayload(
                bundle.GetRawText(),
                OptionalString(root, "intro_session_id"),
                OptionalString(root, "server_url"));
        }

        return new DecodedIntroPayload(root.GetRawText());
    }

    private static string DecompressUtf8(byte[] compressed)
    {
        try
        {
            using var input = new MemoryStream(compressed, writable: false);
            using var gzip = new GZipStream(input, CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[16 * 1024];
            while (true)
            {
                var read = gzip.Read(buffer, 0, buffer.Length);
                if (read == 0) break;
                if (output.Length + read > MaximumDecodedBytes)
                    throw new InvalidDataException("临时加好友载荷解压后过大。");
                output.Write(buffer, 0, read);
            }
            return new UTF8Encoding(false, true).GetString(output.ToArray());
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception error) when (error is FormatException or DecoderFallbackException)
        {
            throw new InvalidDataException("临时加好友载荷无法解码。", error);
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        try
        {
            var base64 = value.Replace('-', '+').Replace('_', '/');
            if (base64.Length % 4 is var remainder and not 0)
                base64 = base64.PadRight(base64.Length + 4 - remainder, '=');
            return Convert.FromBase64String(base64);
        }
        catch (FormatException error)
        {
            throw new InvalidDataException("临时加好友载荷不是有效的 base64url。", error);
        }
    }

    private static string? OptionalString(JsonElement value, string name) =>
        value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String
            ? string.IsNullOrWhiteSpace(property.GetString()) ? null : property.GetString()!.Trim()
            : null;
}
