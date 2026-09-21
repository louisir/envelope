using System.IO;

namespace Envelope.Windows.Services;

public enum ExternalLaunchRequestKind
{
    None,
    OpenUnseal,
    ImportEnvelopeFile,
}

public sealed record ExternalLaunchRequest(
    ExternalLaunchRequestKind Kind,
    string? EnvelopePath = null)
{
    public static ExternalLaunchRequest None { get; } =
        new(ExternalLaunchRequestKind.None);
}

public static class ExternalLaunchRequestParser
{
    public const string OpenUri = "envelope://yourturn/open";

    public static ExternalLaunchRequest Parse(IEnumerable<string>? arguments)
    {
        var argument = arguments?
            .Select(item => item?.Trim())
            .FirstOrDefault(item => !string.IsNullOrWhiteSpace(item));
        if (string.IsNullOrWhiteSpace(argument))
            return ExternalLaunchRequest.None;

        if (Uri.TryCreate(argument, UriKind.Absolute, out var uri) &&
            uri.Scheme.Equals("envelope", StringComparison.OrdinalIgnoreCase))
        {
            return uri.Host.Equals("yourturn", StringComparison.OrdinalIgnoreCase) &&
                   uri.AbsolutePath.Equals("/open", StringComparison.Ordinal) &&
                   string.IsNullOrEmpty(uri.Query) &&
                   string.IsNullOrEmpty(uri.Fragment)
                ? new ExternalLaunchRequest(ExternalLaunchRequestKind.OpenUnseal)
                : ExternalLaunchRequest.None;
        }

        try
        {
            var path = Path.GetFullPath(argument);
            return Path.GetExtension(path).Equals(".envelope", StringComparison.OrdinalIgnoreCase) &&
                   File.Exists(path)
                ? new ExternalLaunchRequest(ExternalLaunchRequestKind.ImportEnvelopeFile, path)
                : ExternalLaunchRequest.None;
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return ExternalLaunchRequest.None;
        }
    }
}
