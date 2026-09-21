using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using Envelope.Windows;
using Envelope.Windows.Services;
using Envelope.Windows.ViewModels;

internal static partial class Program
{
    private static void VerifySidebarNavigation(MainWindow window, MainWindowViewModel model)
    {
        var sidebar = Descendants(window).OfType<ListBox>().Single(list =>
            ReferenceEquals(list.ItemsSource, model.PrimaryNavigationItems));
        void Select(NavigationSection section)
        {
            var item = model.PrimaryNavigationItems.Single(item => item.Section == section);
            // Exercise the actual bound selector rather than calling NavigateTo directly.
            var peer = new ListBoxItemAutomationPeer(item, new ListBoxAutomationPeer(sidebar));
            ((ISelectionItemProvider)peer.GetPattern(PatternInterface.SelectionItem)).Select();
            Pump();
        }
        foreach (var destination in new[] { NavigationSection.Chat, NavigationSection.Contacts, NavigationSection.Unseal })
        {
            foreach (var buttonResource in new[] { "Nav.Settings", "Nav.About", "Settings.IdentitySection" })
            {
                Select(destination);
                var previousPage = model.CurrentPage;
                var button = Descendants(window).OfType<Button>().Single(button =>
                    Equals(button.ToolTip, LocalizationService.Current.GetString(buttonResource)));
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Pump();
                Check(model.CurrentPage != previousPage,
                    $"sidebar {destination}: {buttonResource} button opens its page");
                Select(destination);
                Check(model.CurrentPage == previousPage,
                    $"sidebar {destination}: selecting the previous icon returns from {buttonResource}");
                Check(sidebar.SelectedItem == model.SelectedNavigation,
                    $"sidebar {destination}: selection matches the displayed page");
            }
        }
        model.NavigateTo(NavigationSection.Settings); Pump();
        Check(sidebar.SelectedItem is null, "settings clears primary sidebar selection");
        model.ApplySnapshot(new FakeWorkspace().Snapshot); Pump();
        Check(sidebar.SelectedItem is null && model.CurrentPage == model.Settings,
            "background refresh keeps settings and the sidebar selection consistent");
        Select(NavigationSection.Chat);
        Check(model.CurrentPage == model.Chat, "messages remains reachable after settings refresh");
    }
}
