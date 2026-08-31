namespace Envelope.Windows.Core.Files;

/// <summary>
/// Canonical user-visible and private paths used by the Windows client.
/// </summary>
public sealed class EnvelopePaths
{
    public EnvelopePaths(string? profileRoot = null, string? localAppDataRoot = null)
    {
        var profile = ResolveRoot(
            profileRoot,
            "ENVELOPE_PROFILE_ROOT",
            Environment.SpecialFolder.UserProfile);
        var localAppData = ResolveRoot(
            localAppDataRoot,
            "ENVELOPE_LOCAL_APPDATA_ROOT",
            Environment.SpecialFolder.LocalApplicationData);

        PublicRoot = Path.Combine(profile, "Downloads", "Envelope");
        Received = Path.Combine(PublicRoot, "received");
        Sealed = Path.Combine(PublicRoot, "sealed");
        Backups = Path.Combine(PublicRoot, "backups");
        DiagnosticsExport = Path.Combine(PublicRoot, "diagnostics");

        PrivateRoot = Path.Combine(localAppData, "Envelope");
        State = Path.Combine(PrivateRoot, "state");
        Cache = Path.Combine(PrivateRoot, "cache");
        Logs = Path.Combine(PrivateRoot, "logs");
    }

    public string PublicRoot { get; }
    public string Received { get; }
    public string Sealed { get; }
    public string Backups { get; }
    public string DiagnosticsExport { get; }
    public string PrivateRoot { get; }
    public string State { get; }
    public string Cache { get; }
    public string Logs { get; }

    public void EnsureCreated()
    {
        foreach (var path in new[]
                 {
                     Received, Sealed, Backups, DiagnosticsExport,
                     State, Cache, Logs,
                 })
        {
            Directory.CreateDirectory(path);
        }
    }

    private static string ResolveRoot(
        string? explicitRoot,
        string environmentVariable,
        Environment.SpecialFolder fallback)
    {
        var configured = explicitRoot;
        if (string.IsNullOrWhiteSpace(configured))
            configured = Environment.GetEnvironmentVariable(environmentVariable);
        if (string.IsNullOrWhiteSpace(configured))
            configured = Environment.GetFolderPath(fallback);
        if (!Path.IsPathFullyQualified(configured))
            throw new InvalidOperationException($"{environmentVariable} 必须是绝对路径。");
        return Path.GetFullPath(configured);
    }
}
