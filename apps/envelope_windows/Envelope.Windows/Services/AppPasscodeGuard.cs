using System.Windows;
using Envelope.Windows.Core.Security;
using Envelope.Windows.Views;

namespace Envelope.Windows.Services;

public sealed class AppPasscodeGuard(AppPasscodeStore store) : ILocalUnlockGuard
{
    public bool IsPromptOpen { get; private set; }
    public async Task RequireUnlockAsync(bool localLockEnabled, string message, CancellationToken cancellationToken = default)
    {
        if (!localLockEnabled) return;
        cancellationToken.ThrowIfCancellationRequested();
        if (!await ShowAsync(message, false))
            throw new LocalUnlockDeniedException("已取消解锁。", LocalUnlockVerificationStatus.Canceled);
        cancellationToken.ThrowIfCancellationRequested();
    }
    public Task<bool> ChangeCodeAsync() => ShowAsync(LocalizationService.Current.GetString("Passcode.ChangeHelp"), true);
    private Task<bool> ShowAsync(string message, bool change)
    {
        bool Show()
        {
            if (IsPromptOpen) throw new InvalidOperationException("解锁码窗口已打开。");
            IsPromptOpen = true;
            try
            {
                var dialog = new PasscodeDialog(store, message, change);
                if (Application.Current.MainWindow is { IsVisible: true, Opacity: > 0, IsEnabled: true } owner)
                { dialog.Owner = owner; dialog.WindowStartupLocation = WindowStartupLocation.CenterOwner; }
                return dialog.ShowDialog() == true;
            }
            finally { IsPromptOpen = false; }
        }
        var dispatcher = Application.Current.Dispatcher;
        return dispatcher.CheckAccess() ? Task.FromResult(Show()) : dispatcher.InvokeAsync(Show).Task;
    }
}
