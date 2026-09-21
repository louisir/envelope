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
    private AppPasscodeStore? _passcodes;
    private AppPasscodeGuard? _passcodeGuard;
    private MainWindow? _window;
    private MainWindowViewModel? _viewModel;
    private FileStream? _instanceLock;
    private SingleInstanceRelay? _instanceRelay;
    private DateTimeOffset? _deactivatedAt;
    private int _resumeUnlocking;
    private volatile bool _localLockEnabled;
    private TrayService? _tray;
    private bool _manuallyLocked;
    private int _openingFromTray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        var localization = LocalizationService.Current;
        var theme = ThemeService.Current;
        localization.ApplyCulture(
            CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
                ? "zh-CN"
                : "en-US");
        theme.ApplyTheme(ThemePreference.Light);

        var paths = new EnvelopePaths();
        paths.EnsureCreated();
        var instancePipeName = SingleInstanceRelay.PipeNameFor(paths.PrivateRoot);
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
            if (SingleInstanceRelay.TrySendAsync(
                    instancePipeName,
                    e.Args,
                    TimeSpan.FromSeconds(2)).GetAwaiter().GetResult())
            {
                Shutdown(0);
                return;
            }
            MessageBox.Show(
                "Envelope 已在当前 Windows 账户中运行，或本机状态目录无法取得独占锁。\n\n" +
                error.Message,
                "Envelope",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown(1);
            return;
        }
        if (Environment.GetEnvironmentVariable("ENVELOPE_SKIP_SHELL_REGISTRATION") != "1")
            WindowsShellIntegration.TryRegisterCurrentExecutable(out _);
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
        _passcodes = new AppPasscodeStore(_secureStore);
        _passcodeGuard = new AppPasscodeGuard(_passcodes);
        _unlockGuard = new LocalUnlockCoordinator(_passcodeGuard);
        try
        {
            _passcodes.InitializeAsync().GetAwaiter().GetResult();
            _manuallyLocked = _passcodes.IsLocked;
            _engine.InitializeAsync().GetAwaiter().GetResult();
            _localLockEnabled = _engine.ReadStateAsync(
                state => state.Settings.LocalLockEnabled).GetAwaiter().GetResult();
            _unlockGuard.RequireUnlockAsync(
                _localLockEnabled || _manuallyLocked,
                "解锁 Envelope 本地内容").GetAwaiter().GetResult();
            _passcodes.SetLockedAsync(false).GetAwaiter().GetResult();
            _manuallyLocked = false;
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

        _workspace = new EnvelopeUiService(_engine, paths, diagnostics, _unlockGuard, _passcodeGuard);
        var viewModel = new MainWindowViewModel(_workspace, localization, theme);
        _viewModel = viewModel;
        _window = new MainWindow
        {
            DataContext = viewModel,
        };
        _engine.StateChanged += OnEngineStateChanged;

        MainWindow = _window;
        _window.LockRequested += (_, _) => LockToTray();
        try
        {
            _tray = new TrayService(
                id => Dispatcher.InvokeAsync(() => OpenFromTrayAsync(id)),
                () => Dispatcher.InvokeAsync(() => OpenFromTrayAsync(null, NavigationSection.Settings)),
                () => Dispatcher.InvokeAsync(LockToTray),
                () => Dispatcher.InvokeAsync(Quit));
            _window.TrayAvailable = true;
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            viewModel.SnapshotApplied += (_, snapshot) => _tray.Update(snapshot,
                viewModel.Chat.IsReading ? viewModel.Chat.SelectedConversation?.Id : null);
        }
        catch
        {
            // If Explorer/tray integration is unavailable, preserve a usable normal window.
            _tray?.Dispose(); _tray = null;
            ShutdownMode = ShutdownMode.OnMainWindowClose;
        }
        _window.Show();
        _instanceRelay = new SingleInstanceRelay(
            instancePipeName,
            arguments => Dispatcher.InvokeAsync(
                () => HandleExternalLaunchAsync(arguments)).Task.Unwrap());
        _instanceRelay.Start();
        _ = InitializeAndHandleLaunchAsync(viewModel, e.Args);
    }

    private async Task InitializeAndHandleLaunchAsync(
        MainWindowViewModel viewModel,
        IReadOnlyList<string> arguments)
    {
        await viewModel.InitializeAsync();
        await HandleExternalLaunchAsync(arguments);
    }

    private async Task HandleExternalLaunchAsync(IReadOnlyList<string> arguments)
    {
        var request = ExternalLaunchRequestParser.Parse(arguments);
        if (_viewModel is null ||
            _window is null ||
            _unlockGuard is null)
        {
            return;
        }

        if (request.Kind == ExternalLaunchRequestKind.None)
        {
            if (!_window.IsVisible || _window.WindowState == WindowState.Minimized)
                await OpenFromTrayAsync();
            else _window.Activate();
            return;
        }

        if (!await OpenFromTrayAsync(null, NavigationSection.Unseal)) return;

        if (request.Kind == ExternalLaunchRequestKind.ImportEnvelopeFile &&
            request.EnvelopePath is not null)
        {
            await _viewModel.Unseal.HandleExternalPathAsync(request.EnvelopePath);
        }
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
        // A native tray menu also activates the application. Only resuming the
        // visible main window should reveal content or request the app unlock code.
        if (_passcodeGuard?.IsPromptOpen == true || _tray?.IsContextMenuInteraction == true || _window is null ||
            !_window.IsVisible || _window.WindowState == WindowState.Minimized) return;
        if (Volatile.Read(ref _openingFromTray) != 0) return;
        if (_manuallyLocked) { _window?.Hide(); return; }
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
                // A sensitive operation may already own the app unlock-code
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
        _window.Show();
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        _window.Activate();
        _window.UpdateReadVisibility();
    }

    private async Task<bool> OpenFromTrayAsync(string? conversationId = null, NavigationSection? section = null)
    {
        if (_window is null || _viewModel is null || _unlockGuard is null) return false;
        if (Interlocked.Exchange(ref _openingFromTray, 1) != 0) return false;
        try
        {
            _window.Opacity = 0;
            _window.IsEnabled = false;
            _viewModel.SetWindowReading(false);
            await _unlockGuard.RequireUnlockAsync(_manuallyLocked || _localLockEnabled, "解锁 Envelope 本地内容");
            if (_passcodes is not null) await _passcodes.SetLockedAsync(false);
            _manuallyLocked = false;
            _tray?.SetLocked(false);
            _deactivatedAt = null;
            if (conversationId is not null)
            {
                _viewModel.Chat.SelectConversation(conversationId);
                _viewModel.NavigateTo(NavigationSection.Chat);
            }
            else if (section is { } target) _viewModel.NavigateTo(target);
            RevealMainWindow();
            return true;
        }
        catch (Exception error)
        {
            LockToTray();
            if (error is OperationCanceledException or LocalUnlockDeniedException { VerificationStatus: LocalUnlockVerificationStatus.Canceled }) return false;
            var detail = error is LocalUnlockDeniedException { NativeHResult: { } code }
                ? $"{error.Message}\n错误码：0x{code:X8}" : error.Message;
            MessageBox.Show(LocalizationService.Current.GetString("Tray.UnlockFailed") + "\n\n" + detail,
                "Envelope", MessageBoxButton.OK, MessageBoxImage.Information);
            return false;
        }
        finally { Volatile.Write(ref _openingFromTray, 0); }
    }

    private void LockToTray()
    {
        if (_window is null) return;
        _manuallyLocked = true;
        _viewModel?.Settings.ClearSensitiveInput();
        _viewModel?.SetWindowReading(false);
        foreach (Window child in Windows.Cast<Window>().Where(item => item != _window).ToArray())
            child.Close();
        _window.Opacity = 0;
        _window.IsEnabled = false;
        _window.Hide();
        try { _passcodes?.SetLockedAsync(true).GetAwaiter().GetResult(); }
        catch (Exception error) { MessageBox.Show("当前窗口已锁定，但无法保存重启后的锁定状态：\n" + error.Message, "Envelope", MessageBoxButton.OK, MessageBoxImage.Warning); }
        _tray?.SetLocked(true);
        // Without a tray, immediately offer the system unlock so the app stays reachable.
        if (_tray is null && Volatile.Read(ref _openingFromTray) == 0) _ = OpenFromTrayAsync();
    }

    private void Quit()
    {
        if (_window is not null) _window.ExitRequested = true;
        Shutdown();
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        if (_window is not null) _window.ExitRequested = true;
        base.OnSessionEnding(e);
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
        _tray?.Dispose();
        if (_engine is not null)
            _engine.StateChanged -= OnEngineStateChanged;
        if (_instanceRelay is not null)
        {
            try { _instanceRelay.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
            catch { }
        }
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
