using System.Security.Cryptography;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Core.Application;

public sealed record OwnedIntroSession(
    string SessionId,
    string ServerUrl,
    IntroBundleSummary OwnerBundle,
    long ExpiresAtUnixMs);

public sealed record IntroSessionResponse(
    string SessionId,
    IntroBundleSummary ResponderBundle);

public sealed partial class EnvelopeClientEngine
{
    /// <summary>
    /// Publishes an Android-compatible temporary mutual-contact session. The
    /// returned server URL is the node that accepted the session and must be
    /// included in the version-2 QR/clipboard wrapper.
    /// </summary>
    public async Task<OwnedIntroSession> PublishIntroSessionAsync(
        ulong ttlSeconds = 600,
        CancellationToken cancellationToken = default)
    {
        EnsureInitialized();
        await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        if (_haTrust is not null)
            return await PublishHaIntroAsync(ttlSeconds, cancellationToken).ConfigureAwait(false);

        IntroBundleSummary ownerBundle;
        string configuredUrl;
        string ownerKeyId;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            ownerKeyId = identity.KeyId;
            configuredUrl = RequireIntroServerUrl(_state.Settings.SyncServiceUrl);
            ownerBundle = _native.CreateIntroBundle(
                identity.IdentityJson,
                _state.DeviceId,
                _state.CurrentP2pTicket ?? string.Empty,
                ttlSeconds);
        }
        finally
        {
            _gate.Release();
        }

        var sessionId = "session-" + Base64UrlNoPadding(RandomNumberGenerator.GetBytes(24));
        using var server = CreateIntroServerClient(configuredUrl);
        var response = await server.PublishIntroSessionAsync(
            sessionId,
            ownerBundle.BundleJson,
            cancellationToken).ConfigureAwait(false);
        if (response.Version != EnvelopeProtocol.Version ||
            !string.Equals(response.Status, "ok", StringComparison.Ordinal) ||
            !string.Equals(response.SessionId, sessionId, StringComparison.Ordinal) ||
            !string.Equals(response.OwnerKeyId, ownerKeyId, StringComparison.Ordinal))
        {
            throw new EnvelopeServerException("临时互加会话发布响应与本机请求不匹配。");
        }

        return new OwnedIntroSession(
            sessionId,
            server.ActiveBaseUri.ToString(),
            ownerBundle,
            response.ExpiresAtUnixMs);
    }

    /// <summary>
    /// Responds to the owner session embedded by Android/Windows after the user
    /// has verified the owner's fingerprint and chosen to save it.
    /// </summary>
    public async Task<IntroBundleSummary> RespondIntroSessionAsync(
        string sessionId,
        string serverUrl,
        ulong ttlSeconds = 600,
        CancellationToken cancellationToken = default)
    {
        ValidateIntroSessionId(sessionId);
        var normalizedServerUrl = RequireIntroServerUrl(serverUrl);
        EnsureInitialized();
        await EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
        if (_haTrust is not null)
            return await RespondHaIntroAsync(sessionId, normalizedServerUrl, ttlSeconds, cancellationToken).ConfigureAwait(false);

        IntroBundleSummary responderBundle;
        string responderKeyId;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var identity = RequireIdentity();
            responderKeyId = identity.KeyId;
            responderBundle = _native.CreateIntroBundle(
                identity.IdentityJson,
                _state.DeviceId,
                _state.CurrentP2pTicket ?? string.Empty,
                ttlSeconds);
        }
        finally
        {
            _gate.Release();
        }

        using var server = CreateIntroServerClient(normalizedServerUrl);
        var response = await server.RespondToIntroSessionAsync(
            sessionId,
            responderBundle.BundleJson,
            cancellationToken).ConfigureAwait(false);
        if (response.Version != EnvelopeProtocol.Version ||
            !string.Equals(response.Status, "ok", StringComparison.Ordinal) ||
            !string.Equals(response.SessionId, sessionId, StringComparison.Ordinal) ||
            !string.Equals(response.ResponderKeyId, responderKeyId, StringComparison.Ordinal))
        {
            throw new EnvelopeServerException("临时互加响应与本机身份或会话不匹配。");
        }

        return responderBundle;
    }

    /// <summary>
    /// Polls an owned session without persisting the responder. The returned
    /// bundle has already passed the Rust signature, TTL, and contact checks;
    /// the UI must still ask the user to verify its human fingerprint.
    /// </summary>
    public async Task<IntroSessionResponse?> PollIntroSessionAsync(
        string sessionId,
        string serverUrl,
        CancellationToken cancellationToken = default)
    {
        ValidateIntroSessionId(sessionId);
        var normalizedServerUrl = RequireIntroServerUrl(serverUrl);
        EnsureInitialized();
        if (_haTrust is not null)
            return await PollHaIntroAsync(sessionId, normalizedServerUrl, cancellationToken).ConfigureAwait(false);
        var ownerKeyId = await ReadStateAsync(
            state => state.Identity?.KeyId ?? throw new InvalidOperationException("尚未创建或恢复身份。"),
            cancellationToken).ConfigureAwait(false);

        using var server = CreateIntroServerClient(normalizedServerUrl);
        var response = await server.PollIntroSessionResponseAsync(
            sessionId,
            cancellationToken).ConfigureAwait(false);
        if (response.Version != EnvelopeProtocol.Version ||
            !string.Equals(response.SessionId, sessionId, StringComparison.Ordinal) ||
            !string.Equals(response.OwnerKeyId, ownerKeyId, StringComparison.Ordinal))
        {
            throw new EnvelopeServerException("临时互加轮询响应与已发布会话不匹配。");
        }
        if (string.IsNullOrWhiteSpace(response.ResponderBundleJson)) return null;

        var responder = _native.VerifyIntroBundle(response.ResponderBundleJson);
        if (string.Equals(responder.KeyId, ownerKeyId, StringComparison.Ordinal))
            throw new EnvelopeServerException("临时互加响应不能来自当前身份。");
        return new IntroSessionResponse(sessionId, responder);
    }

    private EnvelopeServerClient CreateIntroServerClient(string serverUrl) =>
        new(serverUrl, nodeTrustVerifier: new NativeEnvelopeNodeTrustVerifier(_native));

    private static string RequireIntroServerUrl(string? value)
    {
        var text = value?.Trim() ?? string.Empty;
        if (text.Length == 0)
            throw new InvalidOperationException("请先配置消息同步服务入口，才能使用双向临时互加。");
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https") ||
            string.IsNullOrWhiteSpace(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new EnvelopeServerException("临时互加服务地址必须是无凭据、query 或 fragment 的 HTTP/HTTPS URL。");
        }
        return uri.ToString();
    }

    private static void ValidateIntroSessionId(string sessionId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        if (sessionId.Length > 128 || sessionId.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.')))
        {
            throw new ArgumentException("临时互加 session id 无效。", nameof(sessionId));
        }
    }

    private static string Base64UrlNoPadding(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
