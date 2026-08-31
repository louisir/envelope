using System.Collections.ObjectModel;
using System.IO;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public sealed class UnsealViewModel : PageViewModel
{
    private readonly IEnvelopeUiService _workspace;
    private string _envelopeBase64 = string.Empty;
    private string _selectedFileName = string.Empty;
    private bool _identityReady;

    public UnsealViewModel(IEnvelopeUiService workspace) : base("Unseal")
    {
        _workspace = workspace;
        RecentEnvelopes = new ObservableCollection<RecentEnvelopeUiModel>();
        ChooseFileCommand = new AsyncRelayCommand(_ => ChooseFileAsync());
        ImportPathCommand = new AsyncRelayCommand(
            parameter => ImportPathAsync(parameter?.ToString()),
            parameter => !string.IsNullOrWhiteSpace(parameter?.ToString()));
        PasteCommand = new AsyncRelayCommand(_ => PasteAsync());
        OpenTextCommand = new AsyncRelayCommand(
            _ => OpenTextAsync(),
            _ => IdentityReady && !string.IsNullOrWhiteSpace(EnvelopeBase64));
    }

    public ObservableCollection<RecentEnvelopeUiModel> RecentEnvelopes { get; }

    public string EnvelopeBase64
    {
        get => _envelopeBase64;
        set
        {
            if (SetProperty(ref _envelopeBase64, value))
            {
                OpenTextCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SelectedFileName
    {
        get => _selectedFileName;
        private set => SetProperty(ref _selectedFileName, value);
    }

    public bool IdentityReady
    {
        get => _identityReady;
        private set
        {
            if (SetProperty(ref _identityReady, value))
            {
                OpenTextCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool HasRecentEnvelopes => RecentEnvelopes.Count > 0;

    public AsyncRelayCommand ChooseFileCommand { get; }

    public AsyncRelayCommand ImportPathCommand { get; }

    public AsyncRelayCommand PasteCommand { get; }

    public AsyncRelayCommand OpenTextCommand { get; }

    public override void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        IdentityReady = snapshot.Identity?.IsReady == true;
        RecentEnvelopes.Clear();
        foreach (var item in snapshot.RecentEnvelopes.OrderByDescending(item => item.OpenedAt))
        {
            RecentEnvelopes.Add(item);
        }

        OnPropertyChanged(nameof(HasRecentEnvelopes));
    }

    private async Task ChooseFileAsync()
    {
        var result = await _workspace.ExecuteAsync(new UiOperationRequest(UiAction.ImportEnvelopeFile));
        if (result.Data is string path && !string.IsNullOrWhiteSpace(path))
        {
            SelectedFileName = Path.GetFileName(path);
            await ImportPathAsync(path);
        }
    }

    private async Task ImportPathAsync(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        SelectedFileName = Path.GetFileName(path);
        await _workspace.ExecuteAsync(new UiOperationRequest(UiAction.ImportEnvelopePath, Text: path));
    }

    private async Task PasteAsync()
    {
        var result = await _workspace.ExecuteAsync(new UiOperationRequest(UiAction.PasteEnvelope));
        if (result.Data is string text)
        {
            EnvelopeBase64 = text.Trim();
        }
    }

    private async Task OpenTextAsync()
    {
        var text = EnvelopeBase64.Trim();
        if (text.Length == 0)
        {
            return;
        }

        var result = await _workspace.ExecuteAsync(
            new UiOperationRequest(UiAction.UnsealEnvelopeText, Text: text));
        if (result.Succeeded)
        {
            EnvelopeBase64 = string.Empty;
        }
    }
}
