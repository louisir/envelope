using System.Windows.Controls;
using System.Windows.Input;
using Envelope.Windows.ViewModels;

namespace Envelope.Windows.Views;

public partial class ChatPage : UserControl
{
    public ChatPage()
    {
        InitializeComponent();
    }

    private void Composer_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            return;
        }

        if (DataContext is ChatViewModel viewModel && viewModel.SendCommand.CanExecute(null))
        {
            e.Handled = true;
            viewModel.SendCommand.Execute(null);
        }
    }
}
