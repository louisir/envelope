using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Core.Native;

/// <summary>
/// Adapts the HTTP node-trust boundary to the authoritative Rust verifier.
/// </summary>
public sealed class NativeEnvelopeNodeTrustVerifier(
    IEnvelopeNativeClient nativeClient) : IEnvelopeNodeTrustVerifier
{
    private readonly IEnvelopeNativeClient _nativeClient =
        nativeClient ?? throw new ArgumentNullException(nameof(nativeClient));

    public NodeManifestTrustResult VerifyManifest(
        string manifestJson,
        string manifestSigningPublicKey,
        long nowUnixMs)
    {
        var result = _nativeClient.VerifyNodeSetManifest(
            manifestJson,
            manifestSigningPublicKey,
            ToUnsignedTimestamp(nowUnixMs, nameof(nowUnixMs)));
        return new NodeManifestTrustResult(result.ManifestId, checked((long)result.Epoch));
    }

    public NodeChallengeTrustResult VerifyChallenge(
        string requestJson,
        string responseJson,
        string nodePublicKey,
        long nowUnixMs,
        long maxClockSkewMs)
    {
        var result = _nativeClient.VerifyNodeChallenge(
            requestJson,
            responseJson,
            nodePublicKey,
            ToUnsignedTimestamp(nowUnixMs, nameof(nowUnixMs)),
            ToUnsignedTimestamp(maxClockSkewMs, nameof(maxClockSkewMs)));
        return new NodeChallengeTrustResult(result.NodeId, result.Valid);
    }

    private static ulong ToUnsignedTimestamp(long value, string parameterName)
    {
        if (value < 0)
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                "Timestamp and duration values cannot be negative.");
        }

        return checked((ulong)value);
    }
}
