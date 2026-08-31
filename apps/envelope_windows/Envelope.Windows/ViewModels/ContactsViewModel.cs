using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Data;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public enum ContactFilter
{
    All,
    Direct,
    Groups,
}

public sealed class ContactsViewModel : PageViewModel
{
    private readonly IEnvelopeUiService _workspace;
    private readonly Action<string> _openChat;
    private string _searchText = string.Empty;
    private ContactFilter _filter = ContactFilter.All;
    private ContactUiModel? _selectedItem;

    public ContactsViewModel(IEnvelopeUiService workspace, Action<string> openChat) : base("Contacts")
    {
        _workspace = workspace;
        _openChat = openChat;
        Items = new ObservableCollection<ContactUiModel>();
        FilteredItems = CollectionViewSource.GetDefaultView(Items);
        FilteredItems.Filter = MatchesFilter;

        SetFilterCommand = new RelayCommand(parameter =>
        {
            if (Enum.TryParse<ContactFilter>(parameter?.ToString(), true, out var filter))
            {
                Filter = filter;
            }
        });
        ShowQrCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ShowContactQr));
        ScanQrCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.ScanContactQr));
        PasteContactCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.PasteContact));
        CreateGroupCommand = new AsyncRelayCommand(_ => ExecuteAsync(UiAction.CreateGroup));
        ManageGroupCommand = new AsyncRelayCommand(
            parameter => ExecuteAsync(UiAction.ManageGroupMembers, ResolveItem(parameter)?.Id),
            parameter => ResolveItem(parameter)?.IsGroup == true);
        LeaveGroupCommand = new AsyncRelayCommand(
            parameter => ExecuteAsync(UiAction.LeaveGroup, ResolveItem(parameter)?.Id),
            parameter => ResolveItem(parameter)?.IsGroup == true);
        OpenChatCommand = new RelayCommand(
            parameter =>
            {
                var item = parameter as ContactUiModel ?? SelectedItem;
                if (item is not null)
                {
                    _openChat(item.Id);
                }
            },
            parameter => parameter is ContactUiModel || SelectedItem is not null);
        EditCommand = new AsyncRelayCommand(
            parameter => ExecuteAsync(UiAction.EditContact, ResolveItem(parameter)?.Id),
            parameter => ResolveItem(parameter)?.IsGroup == false);
        DeleteCommand = new AsyncRelayCommand(
            parameter => ExecuteAsync(UiAction.DeleteContact, ResolveItem(parameter)?.Id),
            parameter => ResolveItem(parameter)?.IsGroup == false);
    }

    public ObservableCollection<ContactUiModel> Items { get; }

    public ICollectionView FilteredItems { get; }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetProperty(ref _searchText, value))
            {
                FilteredItems.Refresh();
            }
        }
    }

    public ContactFilter Filter
    {
        get => _filter;
        private set
        {
            if (SetProperty(ref _filter, value))
            {
                OnPropertyChanged(nameof(IsAllFilter));
                OnPropertyChanged(nameof(IsDirectFilter));
                OnPropertyChanged(nameof(IsGroupsFilter));
                FilteredItems.Refresh();
            }
        }
    }

    public bool IsAllFilter => Filter == ContactFilter.All;

    public bool IsDirectFilter => Filter == ContactFilter.Direct;

    public bool IsGroupsFilter => Filter == ContactFilter.Groups;

    public ContactUiModel? SelectedItem
    {
        get => _selectedItem;
        set
        {
            if (SetProperty(ref _selectedItem, value))
            {
                OnPropertyChanged(nameof(HasSelection));
                OpenChatCommand.RaiseCanExecuteChanged();
                EditCommand.RaiseCanExecuteChanged();
                DeleteCommand.RaiseCanExecuteChanged();
                ManageGroupCommand.RaiseCanExecuteChanged();
                LeaveGroupCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool HasItems => Items.Count > 0;

    public bool HasSelection => SelectedItem is not null;

    public int ContactCount => Items.Count(item => !item.IsGroup);

    public int GroupCount => Items.Count(item => item.IsGroup);

    public RelayCommand SetFilterCommand { get; }

    public AsyncRelayCommand ShowQrCommand { get; }

    public AsyncRelayCommand ScanQrCommand { get; }

    public AsyncRelayCommand PasteContactCommand { get; }

    public AsyncRelayCommand CreateGroupCommand { get; }

    public AsyncRelayCommand ManageGroupCommand { get; }

    public AsyncRelayCommand LeaveGroupCommand { get; }

    public RelayCommand OpenChatCommand { get; }

    public AsyncRelayCommand EditCommand { get; }

    public AsyncRelayCommand DeleteCommand { get; }

    public override void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        var selectedId = SelectedItem?.Id;
        Items.Clear();
        foreach (var item in snapshot.Contacts)
        {
            Items.Add(item);
        }

        SelectedItem = selectedId is null ? null : Items.FirstOrDefault(item => item.Id == selectedId);
        OnPropertyChanged(nameof(HasItems));
        OnPropertyChanged(nameof(ContactCount));
        OnPropertyChanged(nameof(GroupCount));
        FilteredItems.Refresh();
    }

    private bool MatchesFilter(object value)
    {
        if (value is not ContactUiModel item)
        {
            return false;
        }

        if (Filter == ContactFilter.Direct && item.IsGroup)
        {
            return false;
        }

        if (Filter == ContactFilter.Groups && !item.IsGroup)
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(SearchText))
        {
            return true;
        }

        var term = SearchText.Trim();
        return item.DisplayName.Contains(term, StringComparison.CurrentCultureIgnoreCase)
               || item.Subtitle.Contains(term, StringComparison.CurrentCultureIgnoreCase)
               || item.Remark.Contains(term, StringComparison.CurrentCultureIgnoreCase)
               || item.KeyId.Contains(term, StringComparison.OrdinalIgnoreCase);
    }

    private async Task ExecuteAsync(UiAction action, string? contextId = null)
    {
        await _workspace.ExecuteAsync(new UiOperationRequest(action, contextId));
    }

    private ContactUiModel? ResolveItem(object? parameter) =>
        parameter as ContactUiModel ?? SelectedItem;
}
