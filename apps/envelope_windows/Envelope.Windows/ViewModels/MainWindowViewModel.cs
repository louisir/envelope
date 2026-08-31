using System.Collections.ObjectModel;
using System.Windows;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public sealed class MainWindowViewModel : ObservableObject
{
    private readonly IEnvelopeUiService _workspace;
    private readonly ILocalizationService _localization;
    private string _statusResourceKey = "Shell.ServiceConnecting";
    private string? _statusDetails;
    private bool _isBusy;
    private NavigationItemViewModel? _selectedNavigation;
    private PageViewModel? _currentPage;
    private int _refreshing;
    private int _refreshRequested;

    public MainWindowViewModel(
        IEnvelopeUiService workspace,
        ILocalizationService localization,
        IThemeService theme)
    {
        _workspace = workspace;
        _localization = localization;

        About = new AboutViewModel(workspace);
        Chat = new ChatViewModel(workspace, () => NavigateTo(NavigationSection.Contacts));
        Contacts = new ContactsViewModel(
            workspace,
            contactId =>
            {
                Chat.SelectConversation(contactId);
                NavigateTo(NavigationSection.Chat);
            });
        Unseal = new UnsealViewModel(workspace);
        Settings = new SettingsViewModel(workspace, localization, theme);

        NavigationItems = new ObservableCollection<NavigationItemViewModel>
        {
            new(NavigationSection.About, "\uE946", string.Empty),
            new(NavigationSection.Contacts, "\uE716", string.Empty),
            new(NavigationSection.Chat, "\uE8BD", string.Empty),
            new(NavigationSection.Unseal, "\uE785", string.Empty),
            new(NavigationSection.Settings, "\uE713", string.Empty),
        };
        RefreshLocalizedText();

        _selectedNavigation = NavigationItems.First(item => item.Section == NavigationSection.Contacts);
        _currentPage = Contacts;

        _localization.LanguageChanged += (_, _) => RefreshLocalizedText();
        _workspace.StatusChanged += (_, args) =>
        {
            _ = Application.Current.Dispatcher.InvokeAsync(async () =>
            {
                _statusDetails = null;
                _statusResourceKey = args.StatusResourceKey;
                OnPropertyChanged(nameof(StatusText));
                await RefreshSnapshotAsync();
            });
        };
    }

    public ObservableCollection<NavigationItemViewModel> NavigationItems { get; }

    public AboutViewModel About { get; }

    public ContactsViewModel Contacts { get; }

    public ChatViewModel Chat { get; }

    public UnsealViewModel Unseal { get; }

    public SettingsViewModel Settings { get; }

    public NavigationItemViewModel? SelectedNavigation
    {
        get => _selectedNavigation;
        set
        {
            if (SetProperty(ref _selectedNavigation, value) && value is not null)
            {
                if (value.Section != NavigationSection.Settings)
                    Settings.ClearSensitiveInput();
                CurrentPage = PageFor(value.Section);
            }
        }
    }

    public PageViewModel? CurrentPage
    {
        get => _currentPage;
        private set => SetProperty(ref _currentPage, value);
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set => SetProperty(ref _isBusy, value);
    }

    public string StatusText => string.IsNullOrWhiteSpace(_statusDetails)
        ? _localization.GetString(_statusResourceKey)
        : $"{_localization.GetString(_statusResourceKey)}: {_statusDetails}";

    public async Task InitializeAsync()
    {
        try
        {
            IsBusy = true;
            var snapshot = await _workspace.LoadAsync();
            ApplySnapshot(snapshot);
            _statusDetails = null;
            _statusResourceKey = snapshot.ServicesConnected
                ? "Shell.ServiceReady"
                : "Shell.ServiceError";
        }
        catch (Exception error)
        {
            _statusResourceKey = "Shell.ServiceError";
            _statusDetails = error.Message;
        }
        finally
        {
            IsBusy = false;
            OnPropertyChanged(nameof(StatusText));
        }
    }

    private async Task RefreshSnapshotAsync()
    {
        Interlocked.Exchange(ref _refreshRequested, 1);
        if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0)
        {
            return;
        }
        try
        {
            while (Interlocked.Exchange(ref _refreshRequested, 0) != 0)
            {
                var snapshot = await _workspace.LoadAsync();
                ApplySnapshot(snapshot);
            }
        }
        catch
        {
            // The operation already reports its actionable error to the user.
        }
        finally
        {
            Volatile.Write(ref _refreshing, 0);
            if (Volatile.Read(ref _refreshRequested) != 0)
                await RefreshSnapshotAsync();
        }
    }

    public void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        About.ApplySnapshot(snapshot);
        Contacts.ApplySnapshot(snapshot);
        Chat.ApplySnapshot(snapshot);
        Unseal.ApplySnapshot(snapshot);
        Settings.ApplySnapshot(snapshot);
    }

    public void NavigateTo(NavigationSection section)
    {
        SelectedNavigation = NavigationItems.First(item => item.Section == section);
    }

    private PageViewModel PageFor(NavigationSection section) => section switch
    {
        NavigationSection.About => About,
        NavigationSection.Contacts => Contacts,
        NavigationSection.Chat => Chat,
        NavigationSection.Unseal => Unseal,
        NavigationSection.Settings => Settings,
        _ => Contacts,
    };

    private void RefreshLocalizedText()
    {
        foreach (var item in NavigationItems)
        {
            item.Title = _localization.GetString(item.Section switch
            {
                NavigationSection.About => "Nav.About",
                NavigationSection.Contacts => "Nav.Contacts",
                NavigationSection.Chat => "Nav.Chat",
                NavigationSection.Unseal => "Nav.Unseal",
                NavigationSection.Settings => "Nav.Settings",
                _ => "App.Name",
            });
        }

        OnPropertyChanged(nameof(StatusText));
    }
}
