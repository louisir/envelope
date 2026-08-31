using System.Windows;
using System.Windows.Controls;

namespace Envelope.Windows.Views;

public partial class ContactsPage : UserControl
{
    public ContactsPage()
    {
        InitializeComponent();
    }

    private void OpenContactMenu_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { ContextMenu: { } menu } button)
        {
            return;
        }

        menu.PlacementTarget = button;
        menu.IsOpen = true;
    }
}
