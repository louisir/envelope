using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public sealed class SettingsViewModel : PageViewModel
{
    private readonly IEnvelopeUiService _workspace;
    private readonly ILocalizationService _localization;
    private readonly IThemeService _theme;
    private bool _isIdentityReady;
    private string _displayName = "Envelope User";
    private string _identityKeyId = string.Empty;
    private string _identityFingerprint = string.Empty;
    private string _recoveryPhrase = string.Empty;
    private bool _localLockEnabled;
    private bool _autoBackupEnabled;
    private bool _autoSyncEnabled = true;
    private string _backupInterval = "24h";
    private string _backupRetention = "7";
    private string _syncEntry = string.Empty;
    private string _selectedLanguageCode;
    private ThemePreference _selectedTheme;
    private readonly DispatcherTimer _recoveryPhraseClearTimer;
    private bool _hasSnapshot;
    private bool _applyingSettingsSnapshot;
    private bool _settingsDirty;
    private long _settingsEditVersion;

    public SettingsViewModel(
        IEnvelopeUiService workspace,
        ILocalizationService localization,
        IThemeService theme) : base("Settings")
    {
        _workspace = workspace;
        _localization = localization;
        _theme = theme;
        _selectedLanguageCode = localization.CurrentCulture;
        _selectedTheme = theme.CurrentPreference;
        _recoveryPhraseClearTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMinutes(2),
        };
        _recoveryPhraseClearTimer.Tick += (_, _) => ClearSensitiveInput();

        BackupIntervals = new ObservableCollection<string> { "Off", "6h", "12h", "24h", "72h" };
        BackupRetentions = new ObservableCollection<string> { "3", "7", "14", "30" };

        CreateIdentityCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.CreateIdentity, text: DisplayName),
            _ => !IsIdentityReady && !string.IsNullOrWhiteSpace(DisplayName));
        RecoverIdentityCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.RecoverIdentity, text: RecoveryPhrase),
            _ => HasCompleteRecoveryPhrase());
        ClearPhraseCommand = new RelayCommand(_ => ClearSensitiveInput(), _ => RecoveryPhrase.Length > 0);
        ClearIdentityCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.ClearIdentity),
            _ => IsIdentityReady);
        CopyKeyIdCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.CopyKeyId, text: IdentityKeyId),
            _ => !string.IsNullOrWhiteSpace(IdentityKeyId));
        ExportBackupCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.ExportBackup),
            _ => IsIdentityReady);
        RestoreBackupCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.RestoreBackup, text: RecoveryPhrase),
            _ => HasCompleteRecoveryPhrase());
        SaveSyncEntryCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.SaveSyncEntry, text: SyncEntry));
        SyncNowCommand = new AsyncRelayCommand(
            _ => ExecuteAsync(UiAction.SyncNow),
            _ => IsIdentityReady && !string.IsNullOrWhiteSpace(SyncEntry));
        ClearFileCacheCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ClearFileCache));
        ExportDiagnosticsCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ExportDiagnostics));
        ClearDiagnosticsCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ClearDiagnostics));
        ChangeUnlockCodeCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ChangeUnlockCode));
    }

    public ObservableCollection<string> BackupIntervals { get; }
    public AsyncRelayCommand ChangeUnlockCodeCommand { get; }

    public ObservableCollection<string> BackupRetentions { get; }

    public bool IsIdentityReady
    {
        get => _isIdentityReady;
        private set
        {
            if (SetProperty(ref _isIdentityReady, value))
            {
                CreateIdentityCommand.RaiseCanExecuteChanged();
                ClearIdentityCommand.RaiseCanExecuteChanged();
                ExportBackupCommand.RaiseCanExecuteChanged();
                SyncNowCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string DisplayName
    {
        get => _displayName;
        set
        {
            if (SetProperty(ref _displayName, value))
            {
                CreateIdentityCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string IdentityKeyId
    {
        get => _identityKeyId;
        private set
        {
            if (SetProperty(ref _identityKeyId, value))
            {
                CopyKeyIdCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string IdentityFingerprint
    {
        get => _identityFingerprint;
        private set => SetProperty(ref _identityFingerprint, value);
    }

    public string RecoveryPhrase
    {
        get => _recoveryPhrase;
        set
        {
            if (SetProperty(ref _recoveryPhrase, value))
            {
                _recoveryPhraseClearTimer.Stop();
                if (!string.IsNullOrWhiteSpace(value)) _recoveryPhraseClearTimer.Start();
                RecoverIdentityCommand.RaiseCanExecuteChanged();
                RestoreBackupCommand.RaiseCanExecuteChanged();
                ClearPhraseCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool LocalLockEnabled
    {
        get => _localLockEnabled;
        set => SetSettingsProperty(ref _localLockEnabled, value);
    }

    public bool AutoBackupEnabled
    {
        get => _autoBackupEnabled;
        set => SetSettingsProperty(ref _autoBackupEnabled, value);
    }

    public bool AutoSyncEnabled
    {
        get => _autoSyncEnabled;
        set => SetSettingsProperty(ref _autoSyncEnabled, value);
    }

    public string BackupInterval
    {
        get => _backupInterval;
        set => SetSettingsProperty(ref _backupInterval, value);
    }

    public string BackupRetention
    {
        get => _backupRetention;
        set => SetSettingsProperty(ref _backupRetention, value);
    }

    public string SyncEntry
    {
        get => _syncEntry;
        set
        {
            if (SetSettingsProperty(ref _syncEntry, value))
            {
                SyncNowCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SelectedLanguageCode
    {
        get => _selectedLanguageCode;
        set
        {
            if (SetProperty(ref _selectedLanguageCode, value))
            {
                _localization.ApplyCulture(value);
            }
        }
    }

    public ThemePreference SelectedTheme
    {
        get => _selectedTheme;
        set
        {
            if (SetProperty(ref _selectedTheme, value))
            {
                _theme.ApplyTheme(value);
            }
        }
    }

    public AsyncRelayCommand CreateIdentityCommand { get; }

    public AsyncRelayCommand RecoverIdentityCommand { get; }

    public RelayCommand ClearPhraseCommand { get; }

    public AsyncRelayCommand ClearIdentityCommand { get; }

    public AsyncRelayCommand CopyKeyIdCommand { get; }

    public AsyncRelayCommand ExportBackupCommand { get; }

    public AsyncRelayCommand RestoreBackupCommand { get; }

    public AsyncRelayCommand SaveSyncEntryCommand { get; }

    public AsyncRelayCommand SyncNowCommand { get; }

    public AsyncRelayCommand ClearFileCacheCommand { get; }

    public AsyncRelayCommand ExportDiagnosticsCommand { get; }

    public AsyncRelayCommand ClearDiagnosticsCommand { get; }

    public override void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        if (_hasSnapshot && IdentityKeyId != (snapshot.Identity?.KeyId ?? string.Empty))
        {
            // A deliberate identity switch must not carry the previous identity's draft.
            _settingsDirty = false;
            _settingsEditVersion++;
        }
        _hasSnapshot = true;
        IsIdentityReady = snapshot.Identity?.IsReady == true;
        DisplayName = snapshot.Identity?.DisplayName ?? "Envelope User";
        IdentityKeyId = snapshot.Identity?.KeyId ?? string.Empty;
        IdentityFingerprint = snapshot.Identity?.Fingerprint ?? string.Empty;
        // Network/status refreshes are not an instruction to discard the user's form.
        // All six fields are saved together by SaveSyncEntry.
        if (!_settingsDirty)
        {
            _applyingSettingsSnapshot = true;
            try
            {
                LocalLockEnabled = snapshot.Settings.LocalLockEnabled;
                AutoBackupEnabled = snapshot.Settings.AutoBackupEnabled;
                AutoSyncEnabled = snapshot.Settings.AutoSyncEnabled;
                BackupInterval = snapshot.Settings.BackupInterval;
                BackupRetention = snapshot.Settings.BackupRetention;
                SyncEntry = snapshot.Settings.SyncEntry;
            }
            finally { _applyingSettingsSnapshot = false; }
        }
    }

    private bool SetSettingsProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        if (!_applyingSettingsSnapshot)
        {
            _settingsDirty = true;
            _settingsEditVersion++;
        }
        return SetProperty(ref field, value, propertyName);
    }

    public void ClearSensitiveInput()
    {
        _recoveryPhraseClearTimer.Stop();
        RecoveryPhrase = string.Empty;
    }

    private async Task ExecuteAsync(UiAction action, string? text = null)
    {
        var submittedEditVersion = _settingsEditVersion;
        var options = new Dictionary<string, string>
        {
            ["display_name"] = DisplayName,
            ["auto_backup"] = AutoBackupEnabled.ToString(),
            ["backup_interval"] = BackupInterval,
            ["backup_retention"] = BackupRetention,
            ["local_lock"] = LocalLockEnabled.ToString(),
            ["auto_sync"] = AutoSyncEnabled.ToString(),
        };
        try
        {
            var result = await _workspace.ExecuteAsync(new UiOperationRequest(action, Text: text, Options: options));
            if (action is UiAction.SaveSyncEntry or UiAction.RestoreBackup && result.Succeeded)
            {
                // Read back normalization only after persistence succeeds. An edit made
                // during either await is a newer draft, even if it reverts to the old value.
                UiWorkspaceSnapshot savedSnapshot;
                try { savedSnapshot = await _workspace.LoadAsync(); }
                catch
                {
                    // Persistence already succeeded. A failed UI readback must not
                    // crash the async command or discard an unconfirmed draft.
                    return;
                }
                if (_settingsEditVersion == submittedEditVersion)
                {
                    _settingsDirty = false;
                    ApplySnapshot(savedSnapshot);
                }
            }
        }
        finally
        {
            if (action is UiAction.RecoverIdentity or UiAction.RestoreBackup)
                RecoveryPhrase = string.Empty;
        }
    }

    private bool HasCompleteRecoveryPhrase() =>
        RecoveryPhrase.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length == 24;
}
