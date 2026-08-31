using System.Net;

namespace Envelope.Windows.Core.Networking;

public class EnvelopeServerException : Exception
{
    public EnvelopeServerException(string message)
        : base(message)
    {
    }

    public EnvelopeServerException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
public sealed class EnvelopeServerTransportException : EnvelopeServerException
{
    public EnvelopeServerTransportException(string message)
        : base(message)
    {
    }

    public EnvelopeServerTransportException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class EnvelopeServerHttpException : EnvelopeServerException
{
    public EnvelopeServerHttpException(
        Uri baseUri,
        HttpStatusCode statusCode,
        string reason,
        string? apiError,
        bool responseWasJson,
        string message)
        : base(message)
    {
        BaseUri = baseUri;
        StatusCode = statusCode;
        Reason = reason;
        ApiError = apiError;
        ResponseWasJson = responseWasJson;
    }

    public Uri BaseUri { get; }

    public HttpStatusCode StatusCode { get; }

    public string Reason { get; }

    public string? ApiError { get; }

    public bool ResponseWasJson { get; }

    public bool IsMissingRegisteredDeviceRoute
    {
        get
        {
            var detail = string.IsNullOrWhiteSpace(ApiError) ? Message : ApiError;
            return StatusCode == HttpStatusCode.NotFound
                && detail.Contains("identity has no registered", StringComparison.OrdinalIgnoreCase)
                && detail.Contains("device route", StringComparison.OrdinalIgnoreCase);
        }
    }
}
