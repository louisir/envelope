using System.Reflection;
using System.Text.RegularExpressions;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public sealed class AboutViewModel : PageViewModel
{
    private readonly IEnvelopeUiService _workspace;
    private string _signingFingerprint = string.Empty;

    public AboutViewModel(IEnvelopeUiService workspace) : base("About")
    {
        _workspace = workspace;
        var assembly = Assembly.GetExecutingAssembly();
        Version = assembly.GetName().Version?.ToString(3) ?? "0.1.0";
        FullVersion = assembly
                    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                    .InformationalVersion
                    .Split('+')[0]
                ?? Version;
        var buildTimestamp = Regex.Match(FullVersion, @"^v?\d+\.\d+\.\d+\.(\d{14}(?:\.\d{3})?)$", RegexOptions.IgnoreCase);
        Build = buildTimestamp.Success ? buildTimestamp.Groups[1].Value : "—";

        OpenManualCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.OpenUserManual));
        OpenSourceCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.OpenSourceRepository));
        OpenLicenseCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.OpenLicense));
    }

    public string Version { get; }

    public string FullVersion { get; }

    public string Build { get; }

    public string SigningFingerprint
    {
        get => _signingFingerprint;
        private set
        {
            if (SetProperty(ref _signingFingerprint, value))
            {
                OnPropertyChanged(nameof(HasSigningFingerprint));
            }
        }
    }

    public bool HasSigningFingerprint => !string.IsNullOrWhiteSpace(SigningFingerprint);

    public AsyncRelayCommand OpenManualCommand { get; }

    public AsyncRelayCommand OpenSourceCommand { get; }

    public AsyncRelayCommand OpenLicenseCommand { get; }

    public override void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        SigningFingerprint = snapshot.SigningFingerprint ?? string.Empty;
    }

    private async Task ExecuteAsync(UiAction action) =>
        await _workspace.ExecuteAsync(new UiOperationRequest(action));
}
