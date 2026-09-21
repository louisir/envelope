using System.Text.Json;
using System.Net;
using System.Reflection;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Networking;

namespace Envelope.Windows.Tests;

internal static class HaProtocolVerification
{
    public static async Task RunAsync()
    {
        var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ha-v2-vectors.json"))).RootElement;
        var vectors = fixtures.GetProperty("valid").EnumerateArray().ToDictionary(item => item.GetProperty("name").GetString()!);
        string Document(string name) => vectors[name].GetProperty("document").GetRawText();
        var native = new EnvelopeNativeClient();
        var protocol = new EnvelopeHaProtocol(native);
        var configJson = Document("cluster_config");
        var config = protocol.VerifyConfig(configJson, fixtures.GetProperty("administrator_public").GetString()!, 1790000000000);
        var statusJson = Document("cluster_status");
        var watermark = new HaClusterWatermark(config.ClusterId, "1", "1", "0");
        var status = protocol.VerifyStatus(configJson, statusJson, "client-nonce-0000000000000001", 1790000000000, watermark);
        Require(status.LeaderTerm == "9007199254740993", "term above JS safe integer retains all digits");
        var binding = EnvelopeHaProtocol.Deserialize<HaEnvelopeBinding>(fixtures.GetProperty("binding").GetRawText());
        var adminPublic = fixtures.GetProperty("administrator_public").GetString()!;
        protocol.VerifyReceipt(configJson, Document("commit_receipt"), binding, adminPublic);
        var expired = protocol.VerifyReceipt(configJson, Document("expired_commit_receipt"), binding, adminPublic);
        Require(expired.GetProperty("delivery_state").GetString() == "expired" &&
            expired.GetProperty("expiry_evidence").GetProperty("replica_evidence").GetArrayLength() == 2,
            "expiry uses independently verified two-replica evidence");
        var recipient = protocol.VerifyResult(Document("recipient_delivered"), fixtures.GetProperty("recipient_contact").GetRawText(), binding);
        Require(recipient.Outcome == "delivered", "shared Rust signature vector verifies through Windows ABI");
        ExpectFailure(() => protocol.VerifyStatus(configJson, statusJson, "different-challenge", 1790000000000, watermark), "nonce mismatch");
        ExpectFailure(() => protocol.VerifyStatus(configJson, statusJson, status.Nonce, 1790000010000, watermark), "stale leadership status");
        ExpectFailure(() => protocol.VerifyStatus(configJson, statusJson, status.Nonce, 1790000000000,
            watermark with { LeaderTerm = "9007199254740994" }), "leadership rollback");
        ExpectFailure(() => protocol.VerifyResult(Document("recipient_delivered"), fixtures.GetProperty("recipient_contact").GetRawText(),
            binding with { EnvelopeId = "substituted" }), "recipient proof bound to envelope");
        ExpectFailure(() => EnvelopeHaProtocol.Element(fixtures.GetProperty("duplicate_recipient_result_json").GetString()!), "duplicate JSON fields");
        ExpectFailure(() => HaSequence.Parse("18446744073709551616"), "u64 overflow");
        ExpectFailure(() => HaSequence.Parse("01"), "noncanonical decimal");
        var pending = new PendingEnvelopeRecord("id", "recipient", "AQID", 1000,
            Ha: HaOutboundState.Create("sender", "AQID", 1000));
        pending.Ha!.Validate(pending);
        var serialized = JsonSerializer.Serialize(pending);
        var restored = JsonSerializer.Deserialize<PendingEnvelopeRecord>(serialized)!;
        Require(restored.Ha!.OperationId == pending.Ha.OperationId && restored.Ha.NotAfterUnixMs == pending.Ha.NotAfterUnixMs,
            "restart preserves original operation and deadline");
        ExpectFailure(() => restored.Ha.Validate(restored with { EnvelopeBase64 = "AQIE" }), "immutable outbox payload");
        ExpectFailure(() => (restored.Ha with { StorageState = HaStorageState.Replicated }).Validate(restored), "no unproven replication upgrade");
        var legacy = new WindowsClientState { SchemaVersion = 1 };
        legacy.PendingEnvelopes.Add(new("old", "recipient", "", 10, DeliveryState: DeliveryState.Delivered));
        legacy.Validate();
        Require(legacy.SchemaVersion == 2 && legacy.PendingEnvelopes[0].Ha is null, "legacy status never gains v2 evidence");
        var polling = Enumerable.Range(0, 205).Select(index => pending with
        {
            EnvelopeId = $"poll-{index:D3}",
            Ha = pending.Ha! with { DeliveryState = index == 204 ? HaDeliveryState.Expired : HaDeliveryState.Pending },
        }).ToArray();
        var firstPage = HaDeliveryPolling.Select(polling, null);
        var secondPage = HaDeliveryPolling.Select(polling, firstPage[^1].EnvelopeId);
        var finalPage = HaDeliveryPolling.Select(polling, secondPage[^1].EnvelopeId);
        Require(firstPage.Length == 100 && secondPage.Length == 100 && finalPage.Length == 5 &&
            finalPage[^1].Ha!.DeliveryState == HaDeliveryState.Expired,
            "poll rotation reaches later and expired records for late signed results");
        Require(HaDeliveryPolling.Select(polling, finalPage[^1].EnvelopeId)[0].EnvelopeId == firstPage[0].EnvelopeId,
            "poll cursor wraps after last outstanding record");
        var endpoint = new DeviceEndpointUpdateDto(1, "recipient", "device", 1, "updated-ticket", "session", 100, 200, "relay-validated-signature");
        var route = EnvelopeHaProtocol.Serialize(new { endpoint, object_version = "2" });
        Require(EnvelopeHaProtocol.RouteEndpoint(route, "recipient", "device", 150)?.P2pTicket == "updated-ticket", "updated transport route is usable");
        Require(EnvelopeHaProtocol.RouteEndpoint(route, "recipient", "device", 200) is null, "expired route is not used");
        ExpectFailure(() => EnvelopeHaProtocol.RouteEndpoint(route, "other-recipient", "device", 150), "route cannot substitute recipient");
        ExpectFailure(() => EnvelopeHaProtocol.RouteEndpoint(route, "recipient", "other-device", 150), "route cannot substitute device");
        await VerifyConcurrentDiscoveryAsync();
        Console.WriteLine("[PASS] HA v2 shared signatures, binding, rollback and migration verification");
    }

    private static async Task VerifyConcurrentDiscoveryAsync()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var config = new HaClusterConfig(2, "test-cluster", "1", "1",
            [new("S1", "https://primary.test/", "key1", "disk1"), new("S2", "https://backup.test/", "key2", "disk2")],
            ["Q", "S1", "S2"], (now - 1000).ToString(), (now + 60000).ToString(), "mock-verified-config");
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var configRequests = 0; var statusRequests = 0; var persisted = 0;
        var fake = DispatchProxy.Create<IEnvelopeNativeClient, HaNativeProxy>();
        ((HaNativeProxy)(object)fake).Dispatch = input =>
        {
            var command = EnvelopeHaProtocol.Element(input);
            if (command.GetProperty("op").GetString() == "verify_config") return command.GetProperty("config");
            var status = command.GetProperty("status");
            Require(status.GetProperty("nonce").GetString() == command.GetProperty("nonce").GetString(), "challenge bound in verifier contract");
            return status;
        };
        using var http = new HttpClient(new TestHandler(async (request, token) =>
        {
            string body;
            if (request.RequestUri!.AbsolutePath.EndsWith("config"))
            {
                Interlocked.Increment(ref configRequests);
                await gate.Task.WaitAsync(token);
                body = EnvelopeHaProtocol.Serialize(config);
            }
            else
            {
                Interlocked.Increment(ref statusRequests);
                var leader = request.RequestUri.Host == "backup.test";
                var nonce = Uri.UnescapeDataString(request.RequestUri.Query[7..]);
                body = EnvelopeHaProtocol.Serialize(new HaClusterStatus(2, "test-cluster", "1", "1", leader ? "S2" : "S1",
                    leader ? "disk2" : "disk1", nonce, leader ? "leader" : "follower", leader ? "degraded" : "unavailable",
                    "S2", "10", "42", "42", leader, "", now.ToString(), (now + 5000).ToString(), ["ha-v2"], "mock-verified-status"));
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) };
        }));
        using var client = new EnvelopeHaServerClient(fake, new("test-admin", ["https://primary.test/"]), null, null,
            (_, watermark, _) => { persisted++; Require(watermark.LeaderTerm == "10", "durable verified watermark"); return Task.CompletedTask; }, http);
        using var cancelled = new CancellationTokenSource();
        var first = client.DiscoverAsync(cancellationToken: cancelled.Token);
        var second = client.DiscoverAsync();
        cancelled.Cancel();
        try { await first; throw new InvalidOperationException("one caller should cancel"); }
        catch (OperationCanceledException) { }
        gate.SetResult();
        var result = await second;
        Require(result.NodeId == "S2" && client.ActiveBaseUri!.Host == "backup.test", "only verified ready leader selected");
        Require(configRequests == 1 && statusRequests == 2 && persisted == 2, "concurrent callers share discovery and persist before activation");
        using var failureClient = new EnvelopeHaServerClient(fake, new("test-admin", ["https://primary.test/"]), null, null,
            (_, _, _) => throw new IOException("simulated encrypted slot failure"), http);
        try { await failureClient.DiscoverAsync(); throw new InvalidOperationException("failed persistence cannot activate leader"); }
        catch (IOException) { Require(failureClient.ActiveBaseUri is null, "failed watermark save leaves no active endpoint"); }
    }

    public class HaNativeProxy : DispatchProxy
    {
        public Func<string, JsonElement> Dispatch { get; set; } = null!;
        protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) =>
            targetMethod?.Name == nameof(IEnvelopeNativeClient.HaV2) ? Dispatch((string)args![0]!) : throw new NotSupportedException();
    }

    private sealed class TestHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken); }

    private static void Require(bool value, string detail)
    { if (!value) throw new InvalidOperationException(detail); }
    private static void ExpectFailure(Action action, string detail)
    {
        try { action(); }
        catch (Exception error) when (error is InvalidDataException or EnvelopeNativeException) { return; }
        throw new InvalidOperationException("Expected rejection: " + detail);
    }
}
