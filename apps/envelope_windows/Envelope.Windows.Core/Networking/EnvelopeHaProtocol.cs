using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Native;

namespace Envelope.Windows.Core.Networking;

public sealed record HaBusinessNode(string NodeId, string PublicUrl, string SigningPublic, string NodeIncarnation);
public sealed record HaClusterConfig(int ProtocolVersion, string ClusterId, string ControlGeneration,
    string ConfigEpoch, IReadOnlyList<HaBusinessNode> BusinessNodes, IReadOnlyList<string> ControlNodeIds,
    string IssuedAt, string NotAfter, string Signature);
public sealed record HaClusterStatus(int ProtocolVersion, string ClusterId, string ControlGeneration,
    string ConfigEpoch, string NodeId, string NodeIncarnation, string Nonce, string Role, string Mode,
    string? LeaderNodeId, string LeaderTerm, string AppliedIndex, string CommitIndex, bool Ready,
    string ReasonCode, string IssuedAt, string ExpiresAt, IReadOnlyList<string> Capabilities, string NodeSignature);
public sealed record HaEnvelopeBinding(string OperationId, string SenderKeyId, string RecipientKeyId,
    string EnvelopeId, string EnvelopeSha256, string NotAfter);
public sealed record HaRecipientResult(int Version, string SenderKeyId, string RecipientKeyId,
    string EnvelopeId, string EnvelopeSha256, string Outcome, string ReasonCode, string ReceivedAt,
    string ResultId, string ResultSequence, string Signature);

/// <summary>Protocol parsing and cryptography remain in the shared Rust core.
/// Raw wire JSON is verified before managed DTO projection.</summary>
public sealed class EnvelopeHaProtocol(IEnvelopeNativeClient native)
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Json);
    public static T Deserialize<T>(string value) => JsonSerializer.Deserialize<T>(value, Json)
        ?? throw new InvalidDataException("HA 响应不能为 null。");
    public static JsonElement Element(string value)
    {
        using var document = JsonDocument.Parse(value);
        RejectDuplicateProperties(document.RootElement);
        return document.RootElement.Clone();
    }

    private static void RejectDuplicateProperties(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!seen.Add(property.Name)) throw new InvalidDataException("HA JSON 包含重复字段。");
                RejectDuplicateProperties(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var element in value.EnumerateArray()) RejectDuplicateProperties(element);
    }
    public static string Decimal(long value) => value.ToString(CultureInfo.InvariantCulture);

    public static DeviceEndpointUpdateDto? RouteEndpoint(string json, string ownerKeyId, string deviceId, long now)
    {
        var response = Element(json);
        if (!response.TryGetProperty("endpoint", out var value) || value.ValueKind == JsonValueKind.Null) return null;
        var endpoint = Deserialize<DeviceEndpointUpdateDto>(value.GetRawText());
        if (endpoint.Version != EnvelopeProtocol.Version || endpoint.OwnerIdentityKeyId != ownerKeyId || endpoint.DeviceId != deviceId)
            throw new InvalidDataException("路由响应身份或设备不匹配。");
        return endpoint.ExpiresAtUnixMs > now && !string.IsNullOrWhiteSpace(endpoint.P2pTicket) ? endpoint : null;
    }

    public HaClusterConfig VerifyConfig(string json, string adminPublic, long now)
    {
        native.HaV2(Serialize(new { op = "verify_config", config = Element(json), admin_public = adminPublic, now = Decimal(now) }));
        return Deserialize<HaClusterConfig>(json);
    }

    public HaClusterStatus VerifyStatus(string configJson, string json, string nonce, long now,
        HaClusterWatermark? watermark)
    {
        native.HaV2(Serialize(new { op = "verify_status", config = Element(configJson), status = Element(json), nonce,
            now = Decimal(now), watermark = watermark is null ? null : new {
                cluster_id = watermark.ClusterId, control_generation = watermark.ControlGeneration,
                config_epoch = watermark.ConfigEpoch, leader_term = watermark.LeaderTerm } }));
        return Deserialize<HaClusterStatus>(json);
    }

    public JsonElement VerifyReceipt(string configJson, string json, HaEnvelopeBinding binding, string? adminPublic = null)
    {
        native.HaV2(Serialize(new { op = "verify_receipt", config = Element(configJson), receipt = Element(json), binding, admin_public = adminPublic }));
        return Element(json);
    }

    public HaRecipientResult VerifyResult(string json, string contactJson, HaEnvelopeBinding binding)
    {
        native.HaV2(Serialize(new { op = "verify_result", result = Element(json), contact = Element(contactJson), binding }));
        return Deserialize<HaRecipientResult>(json);
    }

    public string SignResult(string identityJson, HaRecipientResult result) =>
        native.HaV2(Serialize(new { op = "sign_result", identity_json = identityJson, result })).GetRawText();

    public static HaEnvelopeBinding Binding(PendingEnvelopeRecord pending)
    {
        var ha = pending.Ha ?? throw new InvalidOperationException("待发项缺少 v2 固定身份。");
        return new(ha.OperationId, ha.SenderKeyId, pending.RecipientKeyId, pending.EnvelopeId,
            ha.EnvelopeSha256, Decimal(ha.NotAfterUnixMs));
    }
}
