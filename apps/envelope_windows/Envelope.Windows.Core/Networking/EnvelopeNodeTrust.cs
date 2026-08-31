namespace Envelope.Windows.Core.Networking;

/// <summary>
/// Bridges node-manifest and node-challenge verification to the native Envelope
/// cryptographic core. The HTTP client never learns nodes from an unsigned manifest.
/// </summary>
public interface IEnvelopeNodeTrustVerifier
{
    NodeManifestTrustResult VerifyManifest(
        string manifestJson,
        string manifestSigningPublicKey,
        long nowUnixMs);

    NodeChallengeTrustResult VerifyChallenge(
        string requestJson,
        string responseJson,
        string nodePublicKey,
        long nowUnixMs,
        long maxClockSkewMs);
}

public sealed record NodeManifestTrustResult(string ManifestId, long Epoch);

public sealed record NodeChallengeTrustResult(string NodeId, bool Valid);
