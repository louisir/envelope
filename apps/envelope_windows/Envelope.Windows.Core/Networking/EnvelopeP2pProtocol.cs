using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Envelope.Windows.Core.Networking;

public sealed class EnvelopeP2pException : Exception
{
    public EnvelopeP2pException(string message)
        : base(message)
    {
    }

    public EnvelopeP2pException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed record EnvelopeP2pTicket(
    string DeviceId,
    IReadOnlyList<string> Addresses,
    int Port,
    long CreatedAtUnixMs,
    long ExpiresAtUnixMs)
{
    public const string Prefix = "envelope-p2p-tcp-v1.";
    public const string Protocol = "tcp.v1";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    public bool IsExpired => IsExpiredAt(DateTimeOffset.UtcNow);

    public bool IsExpiredAt(DateTimeOffset now) => ExpiresAtUnixMs <= now.ToUnixTimeMilliseconds();

    public TimeSpan RemainingAt(DateTimeOffset now)
    {
        var remainingMs = ExpiresAtUnixMs - now.ToUnixTimeMilliseconds();
        return remainingMs <= 0 ? TimeSpan.Zero : TimeSpan.FromMilliseconds(remainingMs);
    }

    public long RemainingSecondsAt(DateTimeOffset now)
    {
        var remainingMs = ExpiresAtUnixMs - now.ToUnixTimeMilliseconds();
        return remainingMs <= 0 ? 0 : (remainingMs + 999) / 1000;
    }

    public bool ShouldRefreshAt(DateTimeOffset now, TimeSpan refreshBefore) =>
        RemainingAt(now) <= refreshBefore;

    public string Encode()
    {
        var payload = new TicketPayloadDto(
            EnvelopeProtocol.Version,
            Protocol,
            DeviceId,
            Addresses,
            Port,
            CreatedAtUnixMs,
            ExpiresAtUnixMs);
        var json = JsonSerializer.Serialize(payload, JsonOptions);
        return Prefix + Base64UrlEncode(Encoding.UTF8.GetBytes(json));
    }

    public static EnvelopeP2pTicket Parse(string ticket)
    {
        if (ticket is null || !ticket.StartsWith(Prefix, StringComparison.Ordinal))
        {
            throw new EnvelopeP2pException("Unsupported P2P ticket format.");
        }

        TicketPayloadDto payload;
        try
        {
            var encoded = ticket[Prefix.Length..];
            var json = Encoding.UTF8.GetString(Base64UrlDecode(encoded));
            payload = JsonSerializer.Deserialize<TicketPayloadDto>(json, JsonOptions)
                ?? throw new JsonException("P2P ticket payload is null.");
        }
        catch (Exception error) when (error is FormatException or JsonException or DecoderFallbackException)
        {
            throw new EnvelopeP2pException("Invalid P2P ticket payload.", error);
        }

        if (payload.Version != EnvelopeProtocol.Version)
        {
            throw new EnvelopeP2pException($"Unsupported P2P ticket version: {payload.Version}.");
        }

        if (!string.Equals(payload.Protocol, Protocol, StringComparison.Ordinal))
        {
            throw new EnvelopeP2pException($"Unsupported P2P ticket protocol: {payload.Protocol}.");
        }

        var addresses = (payload.Addresses ?? Array.Empty<string?>())
            .Select(address => address?.Trim() ?? string.Empty)
            .Where(address => address.Length > 0)
            .ToArray();
        if (addresses.Length == 0)
        {
            throw new EnvelopeP2pException("P2P ticket has no usable address.");
        }

        if (payload.Port is <= 0 or > 65535)
        {
            throw new EnvelopeP2pException("P2P ticket port is invalid.");
        }

        return new EnvelopeP2pTicket(
            payload.DeviceId ?? string.Empty,
            addresses,
            payload.Port,
            payload.CreatedAtUnixMs,
            payload.ExpiresAtUnixMs);
    }

    public static bool TryParse(string? ticket, out EnvelopeP2pTicket? result)
    {
        result = null;
        if (string.IsNullOrWhiteSpace(ticket))
        {
            return false;
        }

        try
        {
            result = Parse(ticket.Trim());
            return true;
        }
        catch (EnvelopeP2pException)
        {
            return false;
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        var remainder = base64.Length % 4;
        if (remainder != 0)
        {
            base64 = base64.PadRight(base64.Length + 4 - remainder, '=');
        }

        return Convert.FromBase64String(base64);
    }

    private sealed record TicketPayloadDto(
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("protocol")] string Protocol,
        [property: JsonPropertyName("device_id")] string? DeviceId,
        [property: JsonPropertyName("addrs")] IReadOnlyList<string?> Addresses,
        [property: JsonPropertyName("port")] int Port,
        [property: JsonPropertyName("created_at_unix_ms")] long CreatedAtUnixMs,
        [property: JsonPropertyName("expires_at_unix_ms")] long ExpiresAtUnixMs);
}

public sealed record EnvelopeP2pStatus(
    bool Listening,
    string Ticket,
    IReadOnlyList<string> Addresses,
    int Port,
    long ExpiresAtUnixMs)
{
    public bool ShouldRefreshAt(DateTimeOffset now, TimeSpan refreshBefore) =>
        ExpiresAtUnixMs - now.ToUnixTimeMilliseconds() <= refreshBefore.TotalMilliseconds;

    public bool TicketExpiredAt(DateTimeOffset now) =>
        EnvelopeP2pTicket.TryParse(Ticket, out var parsed) && parsed!.IsExpiredAt(now);

    public long? TicketRemainingSecondsAt(DateTimeOffset now) =>
        EnvelopeP2pTicket.TryParse(Ticket, out var parsed)
            ? parsed!.RemainingSecondsAt(now)
            : null;
}

public sealed record EnvelopeP2pAck(string Status, string EnvelopeId, string Detail)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    [JsonIgnore]
    public bool IsOk => string.Equals(Status, EnvelopeProtocol.StatusOk, StringComparison.Ordinal);

    public static EnvelopeP2pAck Ok(string envelopeId, string detail) =>
        new(EnvelopeProtocol.StatusOk, envelopeId, detail);

    public static EnvelopeP2pAck Error(string envelopeId, string detail) =>
        new("error", envelopeId, detail);

    public byte[] ToJsonBytes() => Encoding.UTF8.GetBytes(
        JsonSerializer.Serialize(
            new AckPayloadDto(EnvelopeProtocol.Version, Status, EnvelopeId, Detail),
            JsonOptions));

    public static EnvelopeP2pAck FromJsonBytes(ReadOnlySpan<byte> bytes)
    {
        try
        {
            var payload = JsonSerializer.Deserialize<AckPayloadDto>(bytes, JsonOptions)
                ?? throw new JsonException("P2P acknowledgement payload is null.");
            if (payload.Version != EnvelopeProtocol.Version)
                throw new JsonException($"Unsupported P2P acknowledgement version: {payload.Version}.");
            return new EnvelopeP2pAck(
                payload.Status ?? "error",
                payload.EnvelopeId ?? string.Empty,
                payload.Detail ?? string.Empty);
        }
        catch (JsonException error)
        {
            throw new EnvelopeP2pException("Invalid P2P acknowledgement payload.", error);
        }
    }

    private sealed record AckPayloadDto(
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("status")] string? Status,
        [property: JsonPropertyName("envelope_id")] string? EnvelopeId,
        [property: JsonPropertyName("detail")] string? Detail);
}

public sealed class EnvelopeP2pCooldownTracker
{
    public static readonly TimeSpan DefaultCooldown = TimeSpan.FromSeconds(30);

    private readonly ConcurrentDictionary<string, DateTimeOffset> _blockedUntilByKey = new();

    public EnvelopeP2pCooldownTracker(TimeSpan? cooldown = null)
    {
        Cooldown = cooldown ?? DefaultCooldown;
        if (Cooldown < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(cooldown), "Cooldown cannot be negative.");
        }
    }

    public TimeSpan Cooldown { get; }

    public bool CanAttempt(
        string recipientKeyId,
        string ticket,
        DateTimeOffset? now = null)
    {
        var key = Key(recipientKeyId, ticket);
        if (key is null)
        {
            return true;
        }

        var current = now ?? DateTimeOffset.UtcNow;
        if (!_blockedUntilByKey.TryGetValue(key, out var blockedUntil))
        {
            return true;
        }

        if (current < blockedUntil)
        {
            return false;
        }

        _blockedUntilByKey.TryRemove(key, out _);
        return true;
    }

    public TimeSpan? Remaining(
        string recipientKeyId,
        string ticket,
        DateTimeOffset? now = null)
    {
        var key = Key(recipientKeyId, ticket);
        if (key is null)
        {
            return null;
        }

        var current = now ?? DateTimeOffset.UtcNow;
        if (!_blockedUntilByKey.TryGetValue(key, out var blockedUntil))
        {
            return null;
        }

        if (current >= blockedUntil)
        {
            _blockedUntilByKey.TryRemove(key, out _);
            return null;
        }

        return blockedUntil - current;
    }

    public void RecordFailure(
        string recipientKeyId,
        string ticket,
        DateTimeOffset? now = null)
    {
        var key = Key(recipientKeyId, ticket);
        if (key is not null)
        {
            _blockedUntilByKey[key] = (now ?? DateTimeOffset.UtcNow) + Cooldown;
        }
    }

    public void RecordSuccess(string recipientKeyId, string ticket)
    {
        var key = Key(recipientKeyId, ticket);
        if (key is not null)
        {
            _blockedUntilByKey.TryRemove(key, out _);
        }
    }

    private static string? Key(string recipientKeyId, string ticket)
    {
        var recipient = recipientKeyId?.Trim() ?? string.Empty;
        var normalizedTicket = ticket?.Trim() ?? string.Empty;
        return recipient.Length == 0 || normalizedTicket.Length == 0
            ? null
            : $"{recipient}\n{normalizedTicket}";
    }
}
