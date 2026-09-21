using System.Windows;
using System.Windows.Controls;
using Envelope.Windows.Models;
using Envelope.Windows.Services;
using Envelope.Windows.ViewModels;
using Envelope.Windows.Views;

internal static partial class Program
{
    private static void VerifySettingsDraft(string output)
    {
        var service = new SettingsWorkspace();
        var model = new MainWindowViewModel(service, LocalizationService.Current, ThemeService.Current);
        model.ApplySnapshot(service.Snapshot);
        var settings = model.Settings;
        var page = new SettingsPage { DataContext = settings };
        var window = new Window { Content = page, Width = 1100, Height = 800,
            ShowActivated = false, ShowInTaskbar = false, Left = -20000, Top = -20000,
            WindowStartupLocation = WindowStartupLocation.Manual };
        try
        {
            window.Show(); Pump();
            var input = Descendants(page).OfType<TextBox>().Single(box =>
                box.GetBindingExpression(TextBox.TextProperty)?.ParentBinding.Path.Path == "SyncEntry");
            input.BringIntoView(); input.Focus(); Pump();
            input.SelectAll(); input.SelectedText = "envelo"; Pump();
            input.Select(2, 3);
            for (var i = 0; i < 8; i++) { model.ApplySnapshot(service.Snapshot); Pump(); }
            Check(input.Text == "envelo" && settings.SyncEntry == "envelo",
                "background snapshots preserve a partially typed relay address");
            Check(input.SelectionStart == 2 && input.SelectionLength == 3,
                "background snapshots preserve relay caret and selection");
            input.SelectAll(); input.SelectedText = string.Empty; Pump();
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(input.Text == string.Empty, "cleared relay draft stays empty during refresh");
            input.SelectedText = "envelope.iamlouis.online"; Pump();
            settings.AutoSyncEnabled = false;
            settings.AutoBackupEnabled = true;
            settings.BackupInterval = "12h";
            settings.BackupRetention = "14";
            settings.LocalLockEnabled = true;
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(!settings.AutoSyncEnabled && settings.AutoBackupEnabled && settings.LocalLockEnabled &&
                  settings.BackupInterval == "12h" && settings.BackupRetention == "14",
                "background snapshots preserve other unsaved settings");
            model.NavigateTo(NavigationSection.Chat);
            model.ApplySnapshot(service.Snapshot);
            model.NavigateTo(NavigationSection.Settings);
            Check(settings.SyncEntry == "envelope.iamlouis.online", "navigation retains the settings draft");

            service.SaveResult = false;
            settings.SaveSyncEntryCommand.Execute(null); Pump();
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(input.Text == "envelope.iamlouis.online", "failed save retains the relay draft for correction");
            service.SaveResult = true;
            settings.SaveSyncEntryCommand.Execute(null); Pump();
            Check(service.LastRequest?.Text == "envelope.iamlouis.online" &&
                  service.LastRequest.Options?["backup_interval"] == "12h",
                "save submits the current draft and settings");
            Check(input.Text == "https://envelope.iamlouis.online/",
                "successful save displays the persisted normalized relay address");
            service.Snapshot = service.Snapshot with { Settings = service.Snapshot.Settings with {
                SyncEntry = "https://restored.example.invalid/" } };
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(input.Text == "https://restored.example.invalid/", "clean settings accept authoritative refreshes");

            input.SelectAll(); input.SelectedText = "envelope.iamlouis.online"; Pump();
            service.PendingSave = new TaskCompletionSource<bool>();
            settings.SaveSyncEntryCommand.Execute(null); Pump();
            // Reverting to the previous persisted value is also a new user edit.
            input.SelectAll(); input.SelectedText = "https://restored.example.invalid/"; Pump();
            service.PendingSave.SetResult(true); Pump();
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(input.Text == "https://restored.example.invalid/",
                "save completion does not overwrite edits made while saving");
            service.PendingSave = null;
            input.SelectAll(); input.SelectedText = "envelope.iamlouis.online"; Pump();
            settings.SaveSyncEntryCommand.Execute(null); Pump();
            Check(input.Text == "https://envelope.iamlouis.online/", "a later save commits the newer draft");
            input.SelectAll(); input.SelectedText = "readback.example.invalid"; Pump();
            service.FailLoad = true;
            settings.SaveSyncEntryCommand.Execute(null); Pump();
            Check(!settings.SaveSyncEntryCommand.IsRunning && input.Text == "readback.example.invalid",
                "failed post-save readback keeps the draft without crashing the command");
            service.FailLoad = false;
            service.Snapshot = service.Snapshot with { Settings = service.Snapshot.Settings with {
                SyncEntry = "https://backup.example.invalid/" } };
            settings.RecoveryPhrase = string.Join(" ", Enumerable.Repeat("test", 24));
            settings.RestoreBackupCommand.Execute(null); Pump();
            Check(input.Text == "https://backup.example.invalid/",
                "explicit same-identity backup restore replaces the old settings draft");
            input.SelectAll(); input.SelectedText = "unfinished"; Pump();
            service.Snapshot = service.Snapshot with { Identity = service.Snapshot.Identity! with { KeyId = "other-test-identity" },
                Settings = service.Snapshot.Settings with { SyncEntry = "https://other.example.invalid/" } };
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(input.Text == "https://other.example.invalid/", "identity changes discard the previous identity's settings draft");
            input.SelectAll(); input.SelectedText = "envelope.iamlouis.online"; Pump();
            for (var i = 0; i < 8; i++) { model.ApplySnapshot(service.Snapshot); Pump(); }
            input.BringIntoView(); Pump();
            Render(window, Path.Combine(output, "settings-draft-after-refresh.png"));
        }
        finally { window.Close(); Pump(); }
    }

    private sealed class SettingsWorkspace : IEnvelopeUiService
    {
        public event EventHandler<UiServiceStatusChangedEventArgs>? StatusChanged { add { } remove { } }
        public UiWorkspaceSnapshot Snapshot { get; set; } = UiWorkspaceSnapshot.Empty with {
            Identity = new IdentityUiModel("Test", "test-identity", "test-fingerprint", true),
            Settings = UiWorkspaceSnapshot.Empty.Settings with { SyncEntry = "https://envelope.npvwxzkfdqkck.work/" } };
        public bool SaveResult { get; set; } = true;
        public bool FailLoad { get; set; }
        public TaskCompletionSource<bool>? PendingSave { get; set; }
        public UiOperationRequest? LastRequest { get; private set; }
        public Task<UiWorkspaceSnapshot> LoadAsync(CancellationToken cancellationToken = default) => FailLoad
            ? Task.FromException<UiWorkspaceSnapshot>(new IOException("Simulated readback failure")) : Task.FromResult(Snapshot);
        public async Task<UiOperationResult> ExecuteAsync(UiOperationRequest request, CancellationToken cancellationToken = default)
        {
            LastRequest = request;
            if (request.Action == UiAction.SaveSyncEntry)
            {
                if (PendingSave is { } pending) await pending.Task;
                if (!SaveResult) return new(false, "Shell.ServiceError");
                var text = request.Text!;
                var options = request.Options!;
                Snapshot = Snapshot with { Settings = Snapshot.Settings with {
                    SyncEntry = new Uri(text.Contains("://") ? text : "https://" + text).AbsoluteUri,
                    AutoSyncEnabled = bool.Parse(options["auto_sync"]),
                    AutoBackupEnabled = bool.Parse(options["auto_backup"]),
                    LocalLockEnabled = bool.Parse(options["local_lock"]),
                    BackupInterval = options["backup_interval"], BackupRetention = options["backup_retention"] } };
            }
            return new(true, "Shell.ServiceReady");
        }
    }
}
