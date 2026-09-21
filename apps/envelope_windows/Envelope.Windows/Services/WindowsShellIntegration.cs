using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

namespace Envelope.Windows.Services;

public static class WindowsShellIntegration
{
    public const string EnvelopeMimeType = "application/vnd.westwardsoft.envelope";
    private const string ProgId = "WestwardSoft.Envelope.OfflineEnvelope";

    public static bool TryRegisterCurrentExecutable(out string? error)
    {
        error = null;
        try
        {
            var executablePath = Environment.ProcessPath ??
                Process.GetCurrentProcess().MainModule?.FileName;
            if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath))
                throw new InvalidOperationException("The Envelope executable path is unavailable.");

            var quotedExecutable = $"\"{executablePath}\"";
            using var classes = Registry.CurrentUser.CreateSubKey(@"Software\Classes", writable: true)
                ?? throw new InvalidOperationException("The current-user Classes registry key is unavailable.");

            using (var extension = classes.CreateSubKey(".envelope", writable: true))
            {
                extension?.SetValue(string.Empty, ProgId, RegistryValueKind.String);
                extension?.SetValue("Content Type", EnvelopeMimeType, RegistryValueKind.String);
                using var openWith = extension?.CreateSubKey("OpenWithProgids", writable: true);
                openWith?.SetValue(ProgId, Array.Empty<byte>(), RegistryValueKind.None);
            }

            using (var fileType = classes.CreateSubKey(ProgId, writable: true))
            {
                fileType?.SetValue(string.Empty, "Envelope offline envelope", RegistryValueKind.String);
                fileType?.SetValue("FriendlyTypeName", "Envelope offline envelope", RegistryValueKind.String);
                using var icon = fileType?.CreateSubKey("DefaultIcon", writable: true);
                icon?.SetValue(string.Empty, $"{quotedExecutable},0", RegistryValueKind.String);
                using var command = fileType?.CreateSubKey(@"shell\open\command", writable: true);
                command?.SetValue(string.Empty, $"{quotedExecutable} \"%1\"", RegistryValueKind.String);
            }

            using (var protocol = classes.CreateSubKey("envelope", writable: true))
            {
                protocol?.SetValue(string.Empty, "URL:Envelope Protocol", RegistryValueKind.String);
                protocol?.SetValue("URL Protocol", string.Empty, RegistryValueKind.String);
                using var icon = protocol?.CreateSubKey("DefaultIcon", writable: true);
                icon?.SetValue(string.Empty, $"{quotedExecutable},0", RegistryValueKind.String);
                using var command = protocol?.CreateSubKey(@"shell\open\command", writable: true);
                command?.SetValue(string.Empty, $"{quotedExecutable} \"%1\"", RegistryValueKind.String);
            }

            return true;
        }
        catch (Exception registrationError)
        {
            // Shell integration is a convenience boundary. A locked-down or
            // unusual registry profile must not prevent Envelope from opening.
            error = registrationError.Message;
            return false;
        }
    }
}
