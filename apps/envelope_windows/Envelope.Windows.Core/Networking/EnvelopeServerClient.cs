using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Envelope.Windows.Core.Networking;

/// <summary>
/// HTTP client for the public Envelope Server v1 API, including signed node
/// discovery, challenge verification, failover, routes, mailbox receipts, and
/// introduction sessions.
/// </summary>
public sealed class EnvelopeServerClient : IDisposable
{
    public const string NodeManifestSigningPublicKey =
        "RHma4xYC6bw759wgFj6szZlZPySZkzOWYey8QdZ3LlU";

    public static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(12);
    public static readonly TimeSpan DefaultConnectionTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan NodeManifestRefreshWindow = TimeSpan.FromMinutes(5);
    public const long NodeChallengeMaxClockSkewMs = 5 * 60 * 1000;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    private static readonly SemaphoreSlim ManifestGate = new(1, 1);
    private static readonly ConcurrentDictionary<string, long> VerifiedNodeEpochByUri = new();
    private static NodeSetManifestDto? _cachedManifest;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;
    private readonly IReadOnlyList<Uri> _bootstrapUris;
    private readonly IEnvelopeNodeTrustVerifier? _nodeTrustVerifier;
    private readonly TimeSpan _requestTimeout;

    private Uri? _lastUsedBaseUri;
    private bool _disposed;

    public EnvelopeServerClient(
        string baseUrl,
        HttpClient? httpClient = null,
        IEnvelopeNodeTrustVerifier? nodeTrustVerifier = null,
        IEnumerable<string>? bootstrapUrls = null,
        TimeSpan? requestTimeout = null)
    {
        BaseUri = ParseBaseUri(baseUrl);
        _httpClient = httpClient ?? CreateDefaultHttpClient();
        _ownsHttpClient = httpClient is null;
        _nodeTrustVerifier = nodeTrustVerifier;
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
        if (_requestTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(requestTimeout), "Request timeout must be positive.");
        }

        _bootstrapUris = UniqueUris(
            new[] { BaseUri }.Concat((bootstrapUrls ?? Array.Empty<string>()).Select(ParseBaseUri)));
    }

    public Uri BaseUri { get; }

    public Uri ActiveBaseUri => _lastUsedBaseUri ?? BaseUri;

    public NodeSetManifestDto? CachedNodeManifest => _cachedManifest;

    public Task<HealthResponseDto> HealthAsync(CancellationToken cancellationToken = default) =>
        RequestAsync<HealthResponseDto>(HttpMethod.Get, "health", null, cancellationToken);

    public Task<DeviceRegistrationResponseDto> RegisterDeviceAsync(
        DeviceRegistrationRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<DeviceRegistrationResponseDto>(
            HttpMethod.Put,
            "v1/devices/register",
            request,
            cancellationToken);

    public Task<DeviceRegistrationResponseDto> RegisterDeviceAsync(
        string ownerContactJson,
        string endpointJson,
        CancellationToken cancellationToken = default) =>
        RegisterDeviceAsync(
            new DeviceRegistrationRequestDto(
                DeserializeWireObject<ContactDto>(ownerContactJson, nameof(ownerContactJson)),
                DeserializeWireObject<DeviceEndpointUpdateDto>(endpointJson, nameof(endpointJson))),
            cancellationToken);

    public Task<RouteLookupResponseDto> LookupRouteAsync(
        string ownerKeyId,
        string deviceId,
        CancellationToken cancellationToken = default) =>
        RequestAsync<RouteLookupResponseDto>(
            HttpMethod.Get,
            $"v1/routes/{EscapePathSegment(ownerKeyId)}/{EscapePathSegment(deviceId)}",
            null,
            cancellationToken);

    public Task<EnvelopeSubmitResponseDto> SubmitEnvelopeAsync(
        EnvelopeSubmitRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<EnvelopeSubmitResponseDto>(
            HttpMethod.Post,
            "v1/envelopes",
            request,
            cancellationToken);

    public Task<EnvelopeSubmitResponseDto> SubmitEnvelopeAsync(
        string submitRequestJson,
        CancellationToken cancellationToken = default) =>
        SubmitEnvelopeAsync(
            DeserializeWireObject<EnvelopeSubmitRequestDto>(
                submitRequestJson,
                nameof(submitRequestJson)),
            cancellationToken);

    public Task<MailboxPullResponseDto> PullMailboxAsync(
        string recipientKeyId,
        MailboxPullRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<MailboxPullResponseDto>(
            HttpMethod.Post,
            $"v1/mailbox/{EscapePathSegment(recipientKeyId)}/pull",
            request,
            cancellationToken);

    public Task<MailboxPullResponseDto> PullMailboxAsync(
        string recipientKeyId,
        string pullRequestJson,
        CancellationToken cancellationToken = default) =>
        PullMailboxAsync(
            recipientKeyId,
            DeserializeWireObject<MailboxPullRequestDto>(pullRequestJson, nameof(pullRequestJson)),
            cancellationToken);

    public Task<MailboxAckResponseDto> AcknowledgeMailboxAsync(
        string recipientKeyId,
        MailboxAckRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<MailboxAckResponseDto>(
            HttpMethod.Post,
            $"v1/mailbox/{EscapePathSegment(recipientKeyId)}/ack",
            request,
            cancellationToken);

    public Task<MailboxAckResponseDto> AcknowledgeMailboxAsync(
        string recipientKeyId,
        string acknowledgeRequestJson,
        CancellationToken cancellationToken = default) =>
        AcknowledgeMailboxAsync(
            recipientKeyId,
            DeserializeWireObject<MailboxAckRequestDto>(
                acknowledgeRequestJson,
                nameof(acknowledgeRequestJson)),
            cancellationToken);

    public Task<DeliveryStatusResponseDto> GetDeliveryStatusAsync(
        string senderKeyId,
        DeliveryStatusRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<DeliveryStatusResponseDto>(
            HttpMethod.Post,
            $"v1/delivery/{EscapePathSegment(senderKeyId)}/status",
            request,
            cancellationToken);

    public Task<DeliveryStatusResponseDto> GetDeliveryStatusAsync(
        string senderKeyId,
        string statusRequestJson,
        CancellationToken cancellationToken = default) =>
        GetDeliveryStatusAsync(
            senderKeyId,
            DeserializeWireObject<DeliveryStatusRequestDto>(
                statusRequestJson,
                nameof(statusRequestJson)),
            cancellationToken);

    public Task<IntroSessionPublishResponseDto> PublishIntroSessionAsync(
        string sessionId,
        IntroSessionPublishRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<IntroSessionPublishResponseDto>(
            HttpMethod.Put,
            $"v1/intro-sessions/{EscapePathSegment(sessionId)}",
            request,
            cancellationToken);

    public Task<IntroSessionPublishResponseDto> PublishIntroSessionAsync(
        string sessionId,
        string ownerBundleJson,
        CancellationToken cancellationToken = default) =>
        PublishIntroSessionAsync(
            sessionId,
            new IntroSessionPublishRequestDto(
                DeserializeWireObject<EnvelopeIntroBundleDto>(ownerBundleJson, nameof(ownerBundleJson))),
            cancellationToken);

    public Task<IntroSessionRespondResponseDto> RespondToIntroSessionAsync(
        string sessionId,
        IntroSessionRespondRequestDto request,
        CancellationToken cancellationToken = default) =>
        RequestAsync<IntroSessionRespondResponseDto>(
            HttpMethod.Post,
            $"v1/intro-sessions/{EscapePathSegment(sessionId)}/response",
            request,
            cancellationToken);

    public Task<IntroSessionRespondResponseDto> RespondToIntroSessionAsync(
        string sessionId,
        string responderBundleJson,
        CancellationToken cancellationToken = default) =>
        RespondToIntroSessionAsync(
            sessionId,
            new IntroSessionRespondRequestDto(
                DeserializeWireObject<EnvelopeIntroBundleDto>(
                    responderBundleJson,
                    nameof(responderBundleJson))),
            cancellationToken);

    public Task<IntroSessionPollResponseDto> PollIntroSessionResponseAsync(
        string sessionId,
        CancellationToken cancellationToken = default) =>
        RequestAsync<IntroSessionPollResponseDto>(
            HttpMethod.Get,
            $"v1/intro-sessions/{EscapePathSegment(sessionId)}/response",
            null,
            cancellationToken);

    public static void ClearNodeCache()
    {
        _cachedManifest = null;
        VerifiedNodeEpochByUri.Clear();
    }

    public async Task<NodeSetManifestDto?> RefreshNodeManifestAsync(
        bool force = false,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (_nodeTrustVerifier is null)
        {
            return _cachedManifest;
        }

        await ManifestGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var cached = _cachedManifest;
            if (!force
                && cached is not null
                && cached.ValidUntilUnixMs > now + (long)NodeManifestRefreshWindow.TotalMilliseconds)
            {
                return cached;
            }

            var candidates = UniqueUris(
                new[] { ActiveBaseUri, BaseUri }
                    .Concat(cached is null ? Array.Empty<Uri>() : SortedNodeUris(cached))
                    .Concat(_bootstrapUris));
            var accepted = cached;

            foreach (var candidate in candidates)
            {
                try
                {
                    var manifest = await RequestAtAsync<NodeSetManifestDto>(
                        candidate,
                        HttpMethod.Get,
                        "v1/nodes/manifest",
                        null,
                        cancellationToken).ConfigureAwait(false);

                    var verification = _nodeTrustVerifier.VerifyManifest(
                        Serialize(manifest),
                        NodeManifestSigningPublicKey,
                        now);
                    if (!string.Equals(verification.ManifestId, manifest.ManifestId, StringComparison.Ordinal)
                        || verification.Epoch != manifest.Epoch)
                    {
                        throw new EnvelopeServerException("Node manifest verification summary mismatch.");
                    }

                    await VerifyNodeChallengeAsync(candidate, manifest, strict: true, cancellationToken)
                        .ConfigureAwait(false);

                    if (accepted is null || manifest.Epoch >= accepted.Epoch)
                    {
                        accepted = manifest;
                        _cachedManifest = manifest;
                    }

                    _lastUsedBaseUri = candidate;
                    return accepted;
                }
                catch (Exception error) when (
                    !cancellationToken.IsCancellationRequested && ShouldTryNextNode(error))
                {
                    // Try the next signed/bootstrap node for transport and transient HTTP failures.
                }
            }

            return accepted;
        }
        finally
        {
            ManifestGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }

    }

    private async Task<TResponse> RequestAsync<TResponse>(
        HttpMethod method,
        string path,
        object? body,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var candidates = await RequestCandidateUrisAsync(path, cancellationToken).ConfigureAwait(false);
        var errors = new List<string>(candidates.Count);

        foreach (var candidate in candidates)
        {
            try
            {
                await VerifyManifestNodeForRequestAsync(candidate, path, cancellationToken)
                    .ConfigureAwait(false);
                var response = await RequestAtAsync<TResponse>(
                    candidate,
                    method,
                    path,
                    body,
                    cancellationToken).ConfigureAwait(false);
                _lastUsedBaseUri = candidate;
                return response;
            }
            catch (Exception error) when (
                !cancellationToken.IsCancellationRequested && ShouldTryNextNode(error))
            {
                errors.Add($"{DisplayUri(candidate)}: {error.Message}");
            }
            catch (EnvelopeServerHttpException error)
            {
                _lastUsedBaseUri = error.BaseUri;
                throw;
            }
        }

        throw new EnvelopeServerException(
            $"Envelope Server unavailable across {candidates.Count} node(s): {string.Join(" | ", errors)}");
    }

    private async Task<IReadOnlyList<Uri>> RequestCandidateUrisAsync(
        string path,
        CancellationToken cancellationToken)
    {
        if (!IsNodeDiscoveryPath(path))
        {
            await RefreshNodeManifestAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        }

        var manifest = _cachedManifest;
        return UniqueUris(
            new[] { ActiveBaseUri, BaseUri }
                .Concat(manifest is null ? Array.Empty<Uri>() : SortedNodeUris(manifest))
                .Concat(_bootstrapUris));
    }

    private async Task VerifyManifestNodeForRequestAsync(
        Uri uri,
        string path,
        CancellationToken cancellationToken)
    {
        if (IsNodeDiscoveryPath(path) || _nodeTrustVerifier is null || _cachedManifest is null)
        {
            return;
        }

        var node = NodeForUri(_cachedManifest, uri);
        if (node is null)
        {
            return;
        }

        var key = $"{UriKey(uri)}@{_cachedManifest.Epoch}";
        if (VerifiedNodeEpochByUri.TryGetValue(key, out var epoch) && epoch == _cachedManifest.Epoch)
        {
            return;
        }

        await VerifyNodeChallengeAsync(uri, _cachedManifest, strict: false, cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task VerifyNodeChallengeAsync(
        Uri uri,
        NodeSetManifestDto manifest,
        bool strict,
        CancellationToken cancellationToken)
    {
        if (_nodeTrustVerifier is null)
        {
            return;
        }

        var node = NodeForUri(manifest, uri);
        if (node is null)
        {
            if (strict)
            {
                throw new EnvelopeServerException(
                    $"Node manifest does not contain {DisplayUri(uri)}.");
            }

            return;
        }

        var request = new NodeChallengeRequestDto(
            EnvelopeProtocol.Version,
            node.NodeId,
            Base64UrlEncodeNoPadding(RandomNumberGenerator.GetBytes(32)),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        var response = await RequestAtAsync<NodeChallengeResponseDto>(
            uri,
            HttpMethod.Post,
            "v1/node/challenge",
            request,
            cancellationToken).ConfigureAwait(false);
        var verification = _nodeTrustVerifier.VerifyChallenge(
            Serialize(request),
            Serialize(response),
            node.PublicKey,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            NodeChallengeMaxClockSkewMs);
        if (!verification.Valid
            || !string.Equals(verification.NodeId, node.NodeId, StringComparison.Ordinal))
        {
            throw new EnvelopeServerException(
                $"Node challenge verification failed for {node.NodeId}.");
        }

        VerifiedNodeEpochByUri[$"{UriKey(uri)}@{manifest.Epoch}"] = manifest.Epoch;
    }

    private async Task<TResponse> RequestAtAsync<TResponse>(
        Uri baseUri,
        HttpMethod method,
        string path,
        object? body,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout);
        using var request = new HttpRequestMessage(method, new Uri(baseUri, path));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body is not null)
        {
            request.Content = new StringContent(Serialize(body), Encoding.UTF8, "application/json");
        }

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new EnvelopeServerTransportException(
                $"Request to {DisplayUri(baseUri)} timed out after {_requestTimeout.TotalSeconds:0.###} seconds.",
                error);
        }
        catch (HttpRequestException error)
        {
            throw new EnvelopeServerTransportException(
                $"Request to {DisplayUri(baseUri)} failed: {error.Message}",
                error);
        }

        using (response)
        {
            string responseBody;
            try
            {
                responseBody = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException error) when (!cancellationToken.IsCancellationRequested)
            {
                throw new EnvelopeServerTransportException(
                    $"Reading response from {DisplayUri(baseUri)} timed out.",
                    error);
            }
            catch (Exception error) when (error is IOException or HttpRequestException)
            {
                throw new EnvelopeServerTransportException(
                    $"Reading response from {DisplayUri(baseUri)} failed: {error.Message}",
                    error);
            }

            var (responseWasJson, apiError) = ReadApiError(responseBody);
            if (!response.IsSuccessStatusCode)
            {
                var reason = response.ReasonPhrase ?? string.Empty;
                var detail = string.IsNullOrWhiteSpace(apiError) ? reason : apiError;
                throw new EnvelopeServerHttpException(
                    baseUri,
                    response.StatusCode,
                    reason,
                    apiError,
                    responseWasJson,
                    $"HTTP {(int)response.StatusCode} {detail}".TrimEnd());
            }

            if (string.IsNullOrWhiteSpace(responseBody))
            {
                throw new EnvelopeServerTransportException(
                    $"Empty JSON response from {DisplayUri(baseUri)}.");
            }

            try
            {
                return JsonSerializer.Deserialize<TResponse>(responseBody, JsonOptions)
                    ?? throw new JsonException("JSON response deserialized to null.");
            }
            catch (JsonException error)
            {
                throw new EnvelopeServerTransportException(
                    $"Invalid JSON response from {DisplayUri(baseUri)}: {error.Message}",
                    error);
            }
        }
    }

    private static HttpClient CreateDefaultHttpClient()
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = DefaultConnectionTimeout,
        };
        return new HttpClient(handler, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    private static string Serialize<T>(T value) => JsonSerializer.Serialize(value, JsonOptions);

    private static T DeserializeWireObject<T>(string json, string label)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new FormatException($"{label} must be a JSON object.");
            }

            return document.RootElement.Deserialize<T>(JsonOptions)
                ?? throw new FormatException($"{label} deserialized to null.");
        }
        catch (JsonException error)
        {
            throw new FormatException($"{label} is not valid Envelope protocol JSON.", error);
        }
    }

    private static (bool ResponseWasJson, string? ApiError) ReadApiError(string responseBody)
    {
        if (string.IsNullOrWhiteSpace(responseBody))
        {
            return (false, null);
        }

        try
        {
            using var document = JsonDocument.Parse(responseBody);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return (false, null);
            }

            if (document.RootElement.TryGetProperty("error", out var error))
            {
                return (true, error.ValueKind == JsonValueKind.String ? error.GetString() : error.ToString());
            }

            return (true, null);
        }
        catch (JsonException)
        {
            return (false, null);
        }
    }

    private static bool IsNodeDiscoveryPath(string path) =>
        string.Equals(path, "v1/nodes/manifest", StringComparison.Ordinal)
        || string.Equals(path, "v1/node/challenge", StringComparison.Ordinal);

    private static bool ShouldTryNextNode(Exception error)
    {
        if (error is EnvelopeServerTransportException
            or HttpRequestException
            or IOException
            or JsonException
            or TimeoutException)
        {
            return true;
        }

        if (error is EnvelopeServerHttpException httpError)
        {
            if (!httpError.ResponseWasJson)
            {
                return true;
            }

            var code = (int)httpError.StatusCode;
            return httpError.StatusCode is HttpStatusCode.RequestTimeout
                or HttpStatusCode.TooManyRequests
                || code >= 500;
        }

        return false;
    }

    private static IReadOnlyList<Uri> SortedNodeUris(NodeSetManifestDto manifest) =>
        manifest.Nodes
            .OrderByDescending(node => node.Weight)
            .ThenBy(node => node.NodeId, StringComparer.Ordinal)
            .Select(node => ParseBaseUri(node.BaseUrl))
            .ToArray();

    private static NodeDescriptorDto? NodeForUri(NodeSetManifestDto manifest, Uri uri)
    {
        var key = UriKey(uri);
        foreach (var node in manifest.Nodes)
        {
            if (string.Equals(UriKey(ParseBaseUri(node.BaseUrl)), key, StringComparison.Ordinal))
            {
                return node;
            }
        }

        return null;
    }

    private static IReadOnlyList<Uri> UniqueUris(IEnumerable<Uri> uris)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<Uri>();
        foreach (var uri in uris)
        {
            if (seen.Add(UriKey(uri)))
            {
                result.Add(uri);
            }
        }

        return result;
    }

    private static Uri ParseBaseUri(string baseUrl)
    {
        var value = baseUrl?.Trim() ?? string.Empty;
        if (value.Length == 0)
        {
            throw new EnvelopeServerException("Envelope Server URL is empty.");
        }

        if (!value.EndsWith("/", StringComparison.Ordinal))
        {
            value += "/";
        }

        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrWhiteSpace(uri.Host))
        {
            throw new EnvelopeServerException($"Invalid Envelope Server URL: {baseUrl}");
        }

        if (uri.Scheme is not ("http" or "https"))
        {
            throw new EnvelopeServerException($"Unsupported Envelope Server URL scheme: {uri.Scheme}");
        }

        return uri;
    }

    private static string UriKey(Uri uri)
    {
        var builder = new UriBuilder(uri.Scheme.ToLowerInvariant(), uri.Host.ToLowerInvariant())
        {
            Port = uri.IsDefaultPort ? -1 : uri.Port,
            Path = "/",
            Query = string.Empty,
            Fragment = string.Empty,
        };
        return builder.Uri.AbsoluteUri;
    }

    private static string DisplayUri(Uri uri) => UriKey(uri).TrimEnd('/');

    private static string EscapePathSegment(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        return Uri.EscapeDataString(value);
    }

    private static string Base64UrlEncodeNoPadding(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
}
