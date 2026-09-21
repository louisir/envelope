using Envelope.Windows.Services;

namespace Envelope.Windows.Tests;

internal static class ExternalLaunchRequestVerification
{
    public static async Task RunAsync()
    {
        var deepLink = ExternalLaunchRequestParser.Parse([ExternalLaunchRequestParser.OpenUri]);
        Require(deepLink.Kind == ExternalLaunchRequestKind.OpenUnseal, "YourTurn deep link was not accepted");

        foreach (var invalid in new[]
                 {
                     "envelope://yourturn/open?token=secret",
                     "envelope://yourturn/open#fragment",
                     "envelope://other/open",
                     "https://example.com/file.envelope",
                 })
        {
            Require(
                ExternalLaunchRequestParser.Parse([invalid]).Kind == ExternalLaunchRequestKind.None,
                $"unsafe or unrelated launch URI was accepted: {invalid}");
        }

        var root = Path.Combine(Path.GetTempPath(), $"envelope-launch-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var envelopePath = Path.Combine(root, "yourturn.envelope");
            await File.WriteAllBytesAsync(envelopePath, [0x59, 0x54, 0x4D, 0x00]);
            var file = ExternalLaunchRequestParser.Parse([envelopePath]);
            Require(file.Kind == ExternalLaunchRequestKind.ImportEnvelopeFile, "existing .envelope file was not accepted");
            Require(file.EnvelopePath == Path.GetFullPath(envelopePath), "envelope path was not normalized");

            Require(
                ExternalLaunchRequestParser.Parse([Path.Combine(root, "missing.envelope")]).Kind ==
                ExternalLaunchRequestKind.None,
                "missing envelope file was accepted");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
