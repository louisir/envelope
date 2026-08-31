using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Services;

namespace Envelope.Windows.Tests;

internal static class IntroPayloadCodecVerification
{
    public static void Run()
    {
        const string bundle = "{\"version\":1,\"contact\":{\"key_id\":\"alice\"}}";
        var encoded = IntroPayloadCodec.Encode(bundle);
        Require(encoded.StartsWith(IntroPayloadCodec.Prefix, StringComparison.Ordinal),
            "intro payload prefix");
        Equal("alice", ContactKeyId(IntroPayloadCodec.Decode(encoded).BundleJson),
            "intro payload gzip/base64url roundtrip");

        var wrapperJson =
            "{\"version\":2,\"bundle\":" + bundle +
            ",\"intro_session_id\":\"session-1\",\"server_url\":\"https://node.example/\"}";
        var androidPayload = IntroPayloadCodec.Prefix + CompressBase64Url(wrapperJson);
        var decodedAndroid = IntroPayloadCodec.Decode(androidPayload);
        Equal("alice", ContactKeyId(decodedAndroid.BundleJson), "Android wrapper bundle");
        Equal("session-1", decodedAndroid.SessionId, "Android wrapper session");
        Equal("https://node.example/", decodedAndroid.ServerUrl, "Android wrapper server");

        var windowsMutualPayload = IntroPayloadCodec.Encode(
            bundle,
            "session-windows",
            "https://windows-node.example/");
        var decodedWindowsMutual = IntroPayloadCodec.Decode(windowsMutualPayload);
        Equal("alice", ContactKeyId(decodedWindowsMutual.BundleJson), "Windows mutual wrapper bundle");
        Equal("session-windows", decodedWindowsMutual.SessionId, "Windows mutual wrapper session");
        Equal("https://windows-node.example/", decodedWindowsMutual.ServerUrl, "Windows mutual wrapper server");

        var legacy = IntroPayloadCodec.Decode(IntroPayloadCodec.Prefix + bundle);
        Equal("alice", ContactKeyId(legacy.BundleJson), "early Windows raw JSON compatibility");
        Expect<InvalidDataException>(
            () => IntroPayloadCodec.Decode(IntroPayloadCodec.Prefix + "%%%"),
            "invalid intro base64url rejection");
        Console.WriteLine("[PASS] Android-compatible IntroBundle clipboard codec verification");
    }

    private static string ContactKeyId(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("contact").GetProperty("key_id").GetString()
               ?? string.Empty;
    }

    private static string CompressBase64Url(string json)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
            gzip.Write(Encoding.UTF8.GetBytes(json));
        return Convert.ToBase64String(output.ToArray())
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

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

        throw new InvalidOperationException(
            $"Verification failed: {label}; expected {typeof(T).Name}.");
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
