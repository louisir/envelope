using System.Globalization;
using System.IO;
using System.Windows;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Native;
using Envelope.Windows.Core.Security;
using Envelope.Windows.Services;
using Envelope.Windows.ViewModels;

namespace Envelope.Windows;

public partial class App : Application
{
    private EnvelopeUiService? _workspace;
    private WindowsSecureStore? _secureStore;
    private EnvelopeClientEngine? _engine;
    private LocalUnlockCoordinator? _unlockGuard;
    private MainWindow? _window;
    private MainWindowViewModel? _viewModel;
    private FileStream? _instanceLock;
    private DateTimeOffset? _deactivatedAt;
    private int _resumeUnlocking;
    private volatile bool _localLockEnabled;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var localization = LocalizationService.Current;
        var theme = ThemeService.Current;
        localization.ApplyCulture(
            CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
                ? "zh-CN"
                : "en-US");
        theme.ApplyTheme(ThemePreference.System);

        var paths = new EnvelopePaths();
        paths.EnsureCreated();
        try
        {
            _instanceLock = new FileStream(
                Path.Combine(paths.PrivateRoot, "client.lock"),
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(
                "Envelope 已在当前 Windows 账户中运行，或本机状态目录无法取得独占锁。\n\n" +
                error.Message,
                "Envelope",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown(1);
            return;
        }
        var native = new EnvelopeNativeClient();
        // Keep the encrypted vault in the same resolved profile root as all
        // other private client data. Besides avoiding split profiles in
        // production, this makes ENVELOPE_LOCAL_APPDATA_ROOT a complete,
        // safe isolation boundary for smoke tests and portable diagnostics.
        _secureStore = new WindowsSecureStore(
            Path.Combine(paths.PrivateRoot, "Windows", "SecureStore"));
        var stateStore = new SecureClientStateStore(_secureStore);
        var diagnostics = new DiagnosticLogService(paths.Logs);
        _engine = new EnvelopeClientEngine(native, stateStore, paths, diagnostics);
        _unlockGuard = new LocalUnlockCoordinator(
            new LocalUnlockGuard(new WindowsHelloLocalUnlockService()));
        try
        {
            _engine.InitializeAsync().GetAwaiter().GetResult();
            _localLockEnabled = _engine.ReadStateAsync(
                state => state.Settings.LocalLockEnabled).GetAwaiter().GetResult();
            _unlockGuard.RequireUnlockAsync(
                _localLockEnabled,
                "解锁 Envelope 本地内容").GetAwaiter().GetResult();
        }
        catch (Exception error)
        {
            MessageBox.Show(
                $"无法解锁 Envelope，本地内容保持锁定。\n\n{error.Message}",
                "Envelope",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(2);
            return;
        }

        _workspace = new EnvelopeUiService(_engine, paths, diagnostics, _unlockGuard);
        var viewModel = new MainWindowViewModel(_workspace, localization, theme);
        _viewModel = viewModel;
        _window = new MainWindow
        {
            DataContext = viewModel,
        };
        _engine.StateChanged += OnEngineStateChanged;

        MainWindow = _window;
        _window.Show();
        _ = viewModel.InitializeAsync();
    }

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        _viewModel?.Settings.ClearSensitiveInput();
        _deactivatedAt = DateTimeOffset.UtcNow;

        if (!_localLockEnabled || _window is null) return;

        // Application-level activation is required here: switching from the
        // main window to an owned dialog must not look like leaving Envelope,
        // while Alt-Tab away from an owned sensitive dialog must still lock it.
        // Close every owned window so recovery phrases and sealed plaintext do
        // not remain visible behind a stale modal dialog on resume.
        foreach (Window child in Windows.Cast<Window>().Where(item => item != _window).ToArray())
        {
            try { child.Close(); }
            catch { }
        }
        _window.Opacity = 0;
    }

    protected override async void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        var deactivatedAt = _deactivatedAt;
        _deactivatedAt = null;
        if (deactivatedAt is null || _engine is null || _unlockGuard is null || _window is null)
            return;

        var ownsResumeUnlock = false;
        try
        {
            var enabled = await _engine.ReadStateAsync(state => state.Settings.LocalLockEnabled);
            _localLockEnabled = enabled;
            if (!enabled)
            {
                RevealMainWindow();
                return;
            }
            _window.Opacity = 0;
            _window.IsEnabled = false;
            if (Volatile.Read(ref _resumeUnlocking) != 0) return;
            if (_unlockGuard.IsUnlockInProgress)
            {
                // A sensitive operation may already own the Windows Hello
                // prompt that temporarily deactivated the application. Never
                // reveal content while that prompt is pending, and propagate a
                // canceled/failed result instead of treating it as an unlock.
                await _unlockGuard.WaitForCurrentUnlockAsync();
                RevealMainWindow();
                return;
            }
            if (DateTimeOffset.UtcNow - deactivatedAt.Value < TimeSpan.FromSeconds(30) ||
                _unlockGuard.WasSuccessfullyUnlockedWithin(TimeSpan.FromSeconds(5)))
            {
                RevealMainWindow();
                return;
            }
            if (Interlocked.Exchange(ref _resumeUnlocking, 1) != 0) return;
            ownsResumeUnlock = true;
            await _unlockGuard.RequireUnlockAsync(true, "重新解锁 Envelope 本地内容");
            RevealMainWindow();
        }
        catch (Exception error)
        {
            MessageBox.Show(
                $"本地解锁未通过，Envelope 将关闭。\n\n{error.Message}",
                "Envelope",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            Shutdown(3);
        }
        finally
        {
            if (ownsResumeUnlock) Volatile.Write(ref _resumeUnlocking, 0);
        }
    }

    private void RevealMainWindow()
    {
        if (_window is null) return;
        _window.Opacity = 1;
        _window.IsEnabled = true;
        _window.Activate();
    }

    private async void OnEngineStateChanged(object? sender, EventArgs e)
    {
        if (_engine is null) return;
        try
        {
            _localLockEnabled = await _engine.ReadStateAsync(
                state => state.Settings.LocalLockEnabled);
        }
        catch
        {
            // Fail closed with the last successfully observed setting.
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_engine is not null)
            _engine.StateChanged -= OnEngineStateChanged;
        if (_workspace is not null)
        {
            try { _workspace.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch { }
        }
        else if (_engine is not null)
        {
            try { _engine.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch { }
        }
        _secureStore?.Dispose();
        _instanceLock?.Dispose();
        base.OnExit(e);
    }
}
