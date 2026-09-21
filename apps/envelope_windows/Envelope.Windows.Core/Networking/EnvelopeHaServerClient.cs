using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Core.Networking;

public enum HaConnectionState { Discovering, ReadyNormal, ReadyDegraded, Suspect, NoQuorum, Recovering, UpgradeRequired }
public sealed record HaDeploymentTrust(string AdminPublic, IReadOnlyList<string> BootstrapUrls, string? ClusterId = null)
{
    public static HaDeploymentTrust? LoadBundled(string? directory = null)
    {
        var path = Path.Combine(directory ?? AppContext.BaseDirectory, "envelope-ha.json");
        return File.Exists(path) ? EnvelopeHaProtocol.Deserialize<HaDeploymentTrust>(File.ReadAllText(path)) : null;
    }
}

public sealed class EnvelopeHaServerException(string code, HttpStatusCode status, TimeSpan? retryAfter = null, string? reason = null)
    : IOException($"HA 服务返回 {code} ({(int)status})。")
{
    public string Code { get; } = code;
    public HttpStatusCode StatusCode { get; } = status;
    public TimeSpan? RetryAfter { get; } = retryAfter;
    public string? Reason { get; } = reason;
    public bool CanRediscover => Code is "NOT_LEADER" or "NOT_READY" or "NO_QUORUM" or "REPLICA_UNAVAILABLE" or "PAYLOAD_UNAVAILABLE";
}

/// <summary>One shared discovery task, signed-config endpoint allowlist, fresh
/// nonce-bound leader status and durable anti-rollback watermarks. No HTTP redirect.</summary>
public sealed class EnvelopeHaServerClient : IDisposable
{
    private readonly IEnvelopeNativeClient _native;
    private readonly EnvelopeHaProtocol _protocol;
    private readonly HaDeploymentTrust _trust;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly Func<string, HaClusterWatermark, CancellationToken, Task> _persist;
    private readonly object _discoveryGate = new();
    private readonly CancellationTokenSource _lifetime = new();
    private Task<HaClusterStatus>? _discovery;
    private string? _configJson;
    private string? _persistedConfigJson;
    private HaClusterConfig? _config;
    private HaClusterWatermark? _watermark;
    private HaClusterStatus? _status;
    public HaConnectionState State { get; private set; } = HaConnectionState.Discovering;
    public Uri? ActiveBaseUri { get; private set; }
    public string? ConfigJson => _configJson;

    public EnvelopeHaServerClient(IEnvelopeNativeClient native, HaDeploymentTrust trust,
        string? cachedConfig, HaClusterWatermark? watermark,
        Func<string, HaClusterWatermark, CancellationToken, Task> persist, HttpClient? http = null)
    {
        _native = native; _protocol = new(native); _trust = trust; _persist = persist;
        if (string.IsNullOrWhiteSpace(trust.AdminPublic) || trust.BootstrapUrls.Count == 0)
            throw new InvalidDataException("HA 部署缺少固定管理员公钥或入口。");
        foreach (var url in trust.BootstrapUrls) _ = Endpoint(url);
        _http = http ?? new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(3) })
            { Timeout = Timeout.InfiniteTimeSpan };
        _ownsHttp = http is null;
        _configJson = cachedConfig;
        _persistedConfigJson = cachedConfig;
        _watermark = watermark;
    }

    public async Task<HaClusterStatus> DiscoverAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        Task<HaClusterStatus> shared;
        lock (_discoveryGate)
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (!force && _status is not null && HaSequence.Parse(_status.ExpiresAt) > now)
                return _status;
            if (_discovery is null || _discovery.IsCompleted)
                _discovery = DiscoverCoreAsync(_lifetime.Token);
            shared = _discovery;
        }
        // One caller cancellation cannot cancel another caller's leader lookup.
        return await shared.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<HaClusterStatus> DiscoverCoreAsync(CancellationToken cancellationToken)
    {
        State = HaConnectionState.Discovering;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (_configJson is not null)
        {
            try { _config = _protocol.VerifyConfig(_configJson, _trust.AdminPublic, now); }
            catch { _config = null; }
        }
        var candidates = (_config?.BusinessNodes.Select(node => node.PublicUrl) ?? [])
            .Concat(_trust.BootstrapUrls).Distinct(StringComparer.Ordinal).ToArray();
        Exception? lastError = null;
        foreach (var url in candidates)
        {
            try
            {
                var json = await RequestAtAsync(Endpoint(url), "v2/cluster/config", null, cancellationToken).ConfigureAwait(false);
                var config = _protocol.VerifyConfig(json, _trust.AdminPublic, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                RejectConfigRollback(config);
                _config = config; _configJson = json;
                break;
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            { lastError = error; }
        }
        if (_config is null || _configJson is null) throw new IOException("没有可验证的 HA 集群配置。", lastError);
        RejectConfigRollback(_config);
        foreach (var node in _config.BusinessNodes.OrderByDescending(node => ActiveBaseUri?.AbsoluteUri == Endpoint(node.PublicUrl).AbsoluteUri))
        {
            try
            {
                var nonce = Encode(RandomNumberGenerator.GetBytes(32));
                var uri = Endpoint(node.PublicUrl);
                var json = await RequestAtAsync(uri, $"v2/cluster/status?nonce={Uri.EscapeDataString(nonce)}", null, cancellationToken).ConfigureAwait(false);
                var status = _protocol.VerifyStatus(_configJson, json, nonce, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    _watermark ?? new(_config.ClusterId, _config.ControlGeneration, _config.ConfigEpoch, "0"));
                if (status.NodeId != node.NodeId) throw new InvalidDataException("状态响应节点与访问地址不一致。");
                var next = new HaClusterWatermark(status.ClusterId, status.ControlGeneration, status.ConfigEpoch,
                    status.LeaderTerm, status.Role == "leader" && status.Ready ? uri.AbsoluteUri : _watermark?.ActiveBaseUri);
                if (_watermark != next || _persistedConfigJson != _configJson)
                {
                    await _persist(_configJson, next, cancellationToken).ConfigureAwait(false);
                    _persistedConfigJson = _configJson;
                }
                _watermark = next;
                if (HaSequence.Parse(status.ExpiresAt) <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
                    throw new InvalidDataException("状态保存完成时主节点证明已经过期，需重新探测。");
                if (status.Role != "leader" || !status.Ready || status.Mode == "unavailable")
                {
                    State = status.Role == "recovering" ? HaConnectionState.Recovering : HaConnectionState.NoQuorum;
                    continue;
                }
                ActiveBaseUri = uri; _status = status;
                State = status.Mode == "normal" ? HaConnectionState.ReadyNormal : HaConnectionState.ReadyDegraded;
                return status;
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            { lastError = error; }
        }
        _status = null; ActiveBaseUri = null;
        State = HaConnectionState.NoQuorum;
        throw new IOException("没有具备最新提交数据和多数派资格的主节点。", lastError);
    }

    private void RejectConfigRollback(HaClusterConfig config)
    {
        if (_trust.ClusterId is not null && config.ClusterId != _trust.ClusterId)
            throw new InvalidDataException("签名配置不属于发行包固定的集群。");
        foreach (var node in config.BusinessNodes) _ = Endpoint(node.PublicUrl);
        if (_watermark is not { } watermark) return;
        if (config.ClusterId != watermark.ClusterId || HaSequence.Parse(config.ControlGeneration) < HaSequence.Parse(watermark.ControlGeneration) ||
            HaSequence.Parse(config.ConfigEpoch) < HaSequence.Parse(watermark.ConfigEpoch))
            throw new InvalidDataException("拒绝集群配置回退或切换到不同集群。");
    }

    public async Task<string> SendAsync(string path, string kind, object body, string identityJson,
        string actorId, string operationId, CancellationToken cancellationToken = default)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            await DiscoverAsync(force: attempt > 0, cancellationToken).ConfigureAwait(false);
            var config = _config!;
            var bodyBytes = Encoding.UTF8.GetBytes(EnvelopeHaProtocol.Serialize(body));
            var auth = new
            {
                protocol_version = 2, cluster_id = config.ClusterId, control_generation = config.ControlGeneration,
                config_epoch = config.ConfigEpoch, actor_id = actorId, operation_id = operationId,
                nonce = Encode(RandomNumberGenerator.GetBytes(32)), requested_at = EnvelopeHaProtocol.Decimal(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
                request_kind = kind, body_sha256 = Encode(SHA256.HashData(bodyBytes)), signature = "",
            };
            var request = _native.HaV2(EnvelopeHaProtocol.Serialize(new { op = "sign_request", identity_json = identityJson, auth, body_b64 = Encode(bodyBytes) })).GetRawText();
            try { return await RequestAtAsync(ActiveBaseUri!, path, request, cancellationToken).ConfigureAwait(false); }
            catch (EnvelopeHaServerException error) when (error.CanRediscover && attempt == 0)
            { _status = null; State = HaConnectionState.Suspect; }
            catch (HttpRequestException) when (attempt == 0)
            { _status = null; State = HaConnectionState.Suspect; }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && attempt == 0)
            { _status = null; State = HaConnectionState.Suspect; }
        }
        throw new IOException("HA 请求在重新发现后仍不可用。");
    }

    private async Task<string> RequestAtAsync(Uri uri, string path, string? body, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        var largeTransfer = body?.Length > 256 * 1024 || path.EndsWith("/pull", StringComparison.Ordinal);
        timeout.CancelAfter(TimeSpan.FromSeconds(largeTransfer ? 60 : 8));
        using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, new Uri(uri, path));
        if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        if (response.Content.Headers.ContentLength is > 16 * 1024 * 1024) throw new InvalidDataException("HA 响应超过容量上限。");
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var data = new MemoryStream();
        var buffer = new byte[65536];
        int read;
        while ((read = await stream.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) > 0)
        {
            if (data.Length + read > 16 * 1024 * 1024) throw new InvalidDataException("HA 响应超过容量上限。");
            data.Write(buffer, 0, read);
        }
        var json = Encoding.UTF8.GetString(data.ToArray());
        if (!response.IsSuccessStatusCode)
        {
            var code = response.StatusCode == HttpStatusCode.UpgradeRequired ? "UPGRADE_REQUIRED" : "HTTP_ERROR";
            string? reason = null;
            try
            {
                var error = EnvelopeHaProtocol.Element(json);
                if (error.TryGetProperty("code", out var value)) code = value.GetString() ?? code;
                if (error.TryGetProperty("reason", out var detail)) reason = detail.GetString();
            }
            catch (JsonException) { }
            if (code == "UPGRADE_REQUIRED") State = HaConnectionState.UpgradeRequired;
            throw new EnvelopeHaServerException(code, response.StatusCode, response.Headers.RetryAfter?.Delta, reason);
        }
        _ = EnvelopeHaProtocol.Element(json);
        return json;
    }

    private static Uri Endpoint(string url)
    {
        if (!Uri.TryCreate(url.EndsWith('/') ? url : url + "/", UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new InvalidDataException("HA 入口必须使用无用户信息、query 或 fragment 的 HTTPS URL。");
        return uri;
    }
    private static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public void Dispose() { _lifetime.Cancel(); _lifetime.Dispose(); if (_ownsHttp) _http.Dispose(); }
}
