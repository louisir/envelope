using System.Windows;
using Envelope.Windows.Core.Security;
using Envelope.Windows.Services;

namespace Envelope.Windows.Views;

public partial class PasscodeDialog : Window
{
    private readonly AppPasscodeStore _store;
    private readonly bool _change;
    private bool _closed;
    public PasscodeDialog(AppPasscodeStore store, string message, bool change = false)
    {
        InitializeComponent();
        _store = store; _change = change;
        Title = Heading.Text = T(change ? "Passcode.Change" : "Passcode.Unlock");
        Description.Text = message;
        CurrentLabel.Text = T(change ? "Passcode.Current" : "Passcode.Enter");
        Submit.Content = T(change ? "Common.Save" : "Passcode.Unlock");
        InitialHint.Visibility = store.UsesInitialCode ? Visibility.Visible : Visibility.Collapsed;
        NewCodePanel.Visibility = change ? Visibility.Visible : Visibility.Collapsed;
        Loaded += (_, _) => CurrentCode.Focus();
        Closing += (_, e) => { if (!Submit.IsEnabled) e.Cancel = true; };
        Closed += (_, _) => { _closed = true; CurrentCode.Clear(); NewCode.Clear(); ConfirmCode.Clear(); };
    }
    private static string T(string key) => LocalizationService.Current.GetString(key);
    private async void Submit_Click(object sender, RoutedEventArgs e)
    {
        if (!Submit.IsEnabled) return;
        ErrorText.Text = string.Empty;
        if (_change && NewCode.Password != ConfirmCode.Password) { ErrorText.Text = T("Passcode.Mismatch"); return; }
        Submit.IsEnabled = false;
        var current = CurrentCode.Password;
        var next = NewCode.Password;
        CurrentCode.Clear();
        try
        {
            var result = await Task.Run(() => _change ? _store.ChangeAsync(current, next) : _store.VerifyAsync(current));
            if (_closed) return;
            if (result.Status == PasscodeStatus.Verified) { Submit.IsEnabled = true; DialogResult = true; return; }
            ErrorText.Text = result.Status switch {
                PasscodeStatus.InvalidFormat => T("Passcode.Format"),
                PasscodeStatus.CoolingDown => string.Format(T("Passcode.Cooldown"), result.RetryAfterSeconds),
                _ => T("Passcode.Incorrect") };
            CurrentCode.Focus();
        }
        catch (Exception) { if (!_closed) ErrorText.Text = T("Passcode.StorageError"); }
        finally { current = next = string.Empty; if (!_closed) Submit.IsEnabled = true; }
    }
}
