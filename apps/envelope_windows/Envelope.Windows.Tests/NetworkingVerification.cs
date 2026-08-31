using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Tests;

internal static class NetworkingVerification
{
    public static async Task RunAsync()
    {
        EnvelopeServerClient.ClearNodeCache();
        VerifyP2pTicketAndCooldown();
        VerifyWireDtoParsing();
        await VerifyP2pLoopbackAsync();
        await VerifyP2pConnectionLimitAsync();
        await VerifyServerRouteAsync();
        await VerifyBootstrapFailoverAsync();
        await VerifySignedNodeDiscoveryAsync();
        Console.WriteLine("[PASS] Networking protocol verification");
    }

    private static void VerifyP2pTicketAndCooldown()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(1_000_000);
        var ticket = new EnvelopeP2pTicket(
            "android-1234",
            ["192.168.1.22", "10.0.0.8"],
            39123,
            now.ToUnixTimeMilliseconds(),
            now.AddSeconds(65).ToUnixTimeMilliseconds());
        var encoded = ticket.Encode();
        var parsed = EnvelopeP2pTicket.Parse(encoded);

        Require(encoded.StartsWith(EnvelopeP2pTicket.Prefix, StringComparison.Ordinal), "P2P prefix");
        Equal("android-1234", parsed.DeviceId, "P2P device_id");
        SequenceEqual(["192.168.1.22", "10.0.0.8"], parsed.Addresses, "P2P addrs");
        Equal(39123, parsed.Port, "P2P port");
        Require(!parsed.IsExpiredAt(now), "P2P ticket freshness");
        Equal(65L, parsed.RemainingSecondsAt(now), "P2P remaining seconds");

        var tracker = new EnvelopeP2pCooldownTracker(TimeSpan.FromSeconds(30));
        tracker.RecordFailure("bob", "ticket-a", now);
        Require(!tracker.CanAttempt("bob", "ticket-a", now.AddSeconds(10)), "P2P cooldown blocks failed ticket");
        Equal(TimeSpan.FromSeconds(20), tracker.Remaining("bob", "ticket-a", now.AddSeconds(10)), "P2P cooldown remaining");
        Require(tracker.CanAttempt("bob", "ticket-b", now.AddSeconds(10)), "P2P cooldown is ticket-specific");
        Require(tracker.CanAttempt("alice", "ticket-a", now.AddSeconds(10)), "P2P cooldown is recipient-specific");
        tracker.RecordSuccess("bob", "ticket-a");
        Require(tracker.CanAttempt("bob", "ticket-a", now.AddSeconds(10)), "P2P success clears cooldown");
        tracker.RecordFailure("bob", "ticket-a", now);
        Require(tracker.CanAttempt("bob", "ticket-a", now.AddSeconds(31)), "P2P cooldown expires");

        Expect<EnvelopeP2pException>(
            () => EnvelopeP2pAck.FromJsonBytes(
                "{\"version\":2,\"status\":\"ok\",\"envelope_id\":\"wrong\",\"detail\":\"stored\"}"u8),
            "P2P acknowledgement version rejection");
    }

    private static void VerifyWireDtoParsing()
    {
        var mailbox = JsonSerializer.Deserialize<MailboxPullResponseDto>(
            """
            {
              "version": 1,
              "recipient_key_id": "recipient",
              "envelopes": [{
                "envelope_id": "envelope-1",
                "sender_key_id": "sender",
                "recipient_key_id": "recipient",
                "envelope_b64": "AQID",
                "received_at_unix_ms": 1000,
                "expires_at_unix_ms": 2000
              }]
            }
            """)!;
        Equal("recipient", mailbox.RecipientKeyId, "mailbox recipient_key_id");
        Equal("sender", mailbox.Envelopes.Single().SenderKeyId, "mailbox sender_key_id");

        var receipts = JsonSerializer.Deserialize<DeliveryStatusResponseDto>(
            """
            {
              "version": 1,
              "sender_key_id": "sender",
              "items": [{
                "envelope_id": "envelope-1",
                "recipient_key_id": "recipient",
                "status": "delivered",
                "delivered_at_unix_ms": 1234
              }]
            }
            """)!;
        Require(receipts.Items.Single().IsDelivered, "delivery receipt status");
        Equal(1234L, receipts.Items.Single().DeliveredAtUnixMs, "delivery receipt timestamp");

        var intro = JsonSerializer.Deserialize<IntroSessionPollResponseDto>(
            """
            {
              "version": 1,
              "session_id": "session-1",
              "owner_key_id": "owner",
              "responder_bundle": {
                "version": 1,
                "contact": {
                  "version": 1,
                  "display_name": "Responder",
                  "signing_public": "signing",
                  "agreement_public": "agreement",
                  "key_id": "responder"
                },
                "device_id": "windows-1",
                "p2p_ticket": null,
                "capabilities": ["mailbox"],
                "created_at_unix_ms": 1000,
                "expires_at_unix_ms": 2000,
                "nonce": "nonce",
                "signature": "signature"
              },
              "updated_at_unix_ms": 1500
            }
            """)!;
        Require(intro.HasResponderBundle, "intro responder bundle");
        Equal("windows-1", intro.ResponderBundle!.DeviceId, "intro device_id");
    }

    private static async Task VerifyP2pLoopbackAsync()
    {
        await using var transport = new EnvelopeP2pTransport();
        var received = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var status = await transport.StartAsync(
            "windows-test",
            (payload, _) =>
            {
                received.TrySetResult(payload.ToArray());
                return Task.FromResult(EnvelopeP2pAck.Ok("envelope-1", "stored"));
            });
        var loopbackTicket = new EnvelopeP2pTicket(
            "windows-test",
            [IPAddress.Loopback.ToString()],
            status.Port,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            DateTimeOffset.UtcNow.AddMinutes(1).ToUnixTimeMilliseconds()).Encode();
        var envelope = new byte[] { 1, 3, 3, 7 };

        var acknowledgement = await transport.SendEnvelopeAsync(loopbackTicket, envelope, "envelope-1");

        Require(acknowledgement.IsOk, "P2P acknowledgement status");
        Equal("envelope-1", acknowledgement.EnvelopeId, "P2P acknowledgement envelope_id");
        SequenceEqual(envelope, await received.Task.WaitAsync(TimeSpan.FromSeconds(2)), "P2P frame payload");

        await ExpectAsync<EnvelopeP2pException>(
            () => transport.SendEnvelopeAsync(loopbackTicket, envelope, "different-envelope"),
            "P2P acknowledgement envelope_id mismatch");
    }

    private static async Task VerifyP2pConnectionLimitAsync()
    {
        await using var transport = new EnvelopeP2pTransport();
        var status = await transport.StartAsync(
            "windows-limit-test",
            (_, _) => Task.FromResult(EnvelopeP2pAck.Ok("unused", "stored")));
        var heldConnections = new List<TcpClient>();
        try
        {
            for (var index = 0; index < EnvelopeP2pTransport.MaximumConcurrentConnections; index++)
            {
                var client = new TcpClient();
                await client.ConnectAsync(IPAddress.Loopback, status.Port);
                heldConnections.Add(client);
            }

            await WaitUntilAsync(
                () => transport.ActiveConnectionCount == EnvelopeP2pTransport.MaximumConcurrentConnections,
                TimeSpan.FromSeconds(2));

            using var rejected = new TcpClient();
            await rejected.ConnectAsync(IPAddress.Loopback, status.Port);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var buffer = new byte[1];
            var closed = false;
            try
            {
                closed = await rejected.GetStream().ReadAsync(buffer, timeout.Token) == 0;
            }
            catch (IOException)
            {
                closed = true;
            }
            catch (SocketException)
            {
                closed = true;
            }

            Require(closed, "P2P listener rejects connections above the bounded concurrency limit");
        }
        finally
        {
            foreach (var client in heldConnections)
            {
                client.Dispose();
            }
        }
    }

    private static async Task VerifyServerRouteAsync()
    {
        HttpRequestMessage? capturedRequest = null;
        using var httpClient = new HttpClient(new StubHttpMessageHandler(request =>
        {
            capturedRequest = request;
            return Task.FromResult(JsonResponse(
                """
                {
                  "version": 1,
                  "owner_identity_key_id": "owner/one",
                  "device_id": "desktop 1",
                  "endpoint": {
                    "version": 1,
                    "owner_identity_key_id": "owner/one",
                    "device_id": "desktop 1",
                    "device_list_version": 4,
                    "p2p_ticket": "envelope-p2p-tcp-v1.test",
                    "session_id": "session-1",
                    "created_at_unix_ms": 1000,
                    "expires_at_unix_ms": 2000,
                    "signature": "sig"
                  }
                }
                """));
        }))
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        using var client = new EnvelopeServerClient("https://node.example", httpClient);

        var route = await client.LookupRouteAsync("owner/one", "desktop 1");

        Equal(HttpMethod.Get, capturedRequest!.Method, "route HTTP method");
        Equal("/v1/routes/owner%2Fone/desktop%201", capturedRequest.RequestUri!.AbsolutePath, "route URL encoding");
        Require(route.HasEndpoint, "route endpoint presence");
        Equal("envelope-p2p-tcp-v1.test", route.Endpoint!.P2pTicket, "route p2p_ticket");
        Equal(4L, route.Endpoint.DeviceListVersion, "route device_list_version");
    }

    private static async Task VerifySignedNodeDiscoveryAsync()
    {
        var paths = new List<string>();
        using var httpClient = new HttpClient(new StubHttpMessageHandler(async request =>
        {
            paths.Add(request.RequestUri!.AbsolutePath);
            if (request.RequestUri.AbsolutePath == "/v1/nodes/manifest")
            {
                return JsonResponse(
                    """
                    {
                      "version": 1,
                      "manifest_id": "manifest-1",
                      "epoch": 7,
                      "valid_from_unix_ms": 1,
                      "valid_until_unix_ms": 4102444800000,
                      "prev_manifest_hash": null,
                      "nodes": [{
                        "node_id": "node-1",
                        "base_url": "https://node.example/",
                        "public_key": "node-public",
                        "capabilities": ["mailbox", "route"],
                        "weight": 100,
                        "region": "test",
                        "valid_until_unix_ms": 4102444800000
                      }],
                      "revoked_node_ids": [],
                      "signature": "manifest-signature"
                    }
                    """);
            }

            if (request.RequestUri.AbsolutePath == "/v1/node/challenge")
            {
                using var requestDocument = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
                var challenge = requestDocument.RootElement;
                return JsonResponse(
                    JsonSerializer.Serialize(new
                    {
                        version = 1,
                        status = "ok",
                        node_id = challenge.GetProperty("node_id").GetString(),
                        challenge_b64 = challenge.GetProperty("challenge_b64").GetString(),
                        requested_at_unix_ms = challenge.GetProperty("requested_at_unix_ms").GetInt64(),
                        signed_at_unix_ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                        signature = "challenge-signature",
                    }));
            }

            return JsonResponse("{\"version\":1,\"status\":\"ok\"}");
        }))
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        var verifier = new AcceptingNodeTrustVerifier();
        using var client = new EnvelopeServerClient("https://node.example/", httpClient, verifier);

        var health = await client.HealthAsync();

        Equal("ok", health.Status, "health status");
        SequenceEqual(
            ["/v1/nodes/manifest", "/v1/node/challenge", "/health"],
            paths,
            "signed node discovery request order");
        Equal(1, verifier.ManifestVerificationCount, "manifest verification count");
        Equal(1, verifier.ChallengeVerificationCount, "challenge verification count");
    }

    private static async Task VerifyBootstrapFailoverAsync()
    {
        var hosts = new List<string>();
        using var httpClient = new HttpClient(new StubHttpMessageHandler(request =>
        {
            hosts.Add(request.RequestUri!.Host);
            if (request.RequestUri.Host == "primary.example")
            {
                throw new HttpRequestException("simulated primary failure");
            }

            return Task.FromResult(JsonResponse("{\"version\":1,\"status\":\"ok\"}"));
        }))
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        using var client = new EnvelopeServerClient(
            "https://primary.example/",
            httpClient,
            bootstrapUrls: ["https://backup.example/"]);

        var health = await client.HealthAsync();

        Equal("ok", health.Status, "failover health status");
        SequenceEqual(["primary.example", "backup.example"], hosts, "bootstrap failover order");
        Equal("backup.example", client.ActiveBaseUri.Host, "active failover node");
    }

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private static void Require(bool condition, string label)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"Verification failed: {label}.");
        }
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

    private static async Task ExpectAsync<T>(Func<Task> action, string label) where T : Exception
    {
        try
        {
            await action();
        }
        catch (T)
        {
            return;
        }

        throw new InvalidOperationException(
            $"Verification failed: {label}; expected {typeof(T).Name}.");
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (!condition())
        {
            if (DateTimeOffset.UtcNow >= deadline)
            {
                throw new TimeoutException("Timed out waiting for the P2P listener state.");
            }

            await Task.Delay(10);
        }
    }

    private static void Equal<T>(T expected, T actual, string label)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException(
                $"Verification failed: {label}; expected '{expected}', actual '{actual}'.");
        }
    }

    private static void SequenceEqual<T>(
        IEnumerable<T> expected,
        IEnumerable<T> actual,
        string label)
    {
        if (!expected.SequenceEqual(actual))
        {
            throw new InvalidOperationException($"Verification failed: {label}.");
        }
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, Task<HttpResponseMessage>> handler) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => handler(request);
    }

    private sealed class AcceptingNodeTrustVerifier : IEnvelopeNodeTrustVerifier
    {
        public int ManifestVerificationCount { get; private set; }
        public int ChallengeVerificationCount { get; private set; }

        public NodeManifestTrustResult VerifyManifest(
            string manifestJson,
            string manifestSigningPublicKey,
            long nowUnixMs)
        {
            ManifestVerificationCount++;
            using var document = JsonDocument.Parse(manifestJson);
            return new NodeManifestTrustResult(
                document.RootElement.GetProperty("manifest_id").GetString()!,
                document.RootElement.GetProperty("epoch").GetInt64());
        }

        public NodeChallengeTrustResult VerifyChallenge(
            string requestJson,
            string responseJson,
            string nodePublicKey,
            long nowUnixMs,
            long maxClockSkewMs)
        {
            ChallengeVerificationCount++;
            using var document = JsonDocument.Parse(responseJson);
            return new NodeChallengeTrustResult(
                document.RootElement.GetProperty("node_id").GetString()!,
                true);
        }
    }
}
