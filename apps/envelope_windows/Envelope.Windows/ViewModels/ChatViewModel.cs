using System.Collections;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Data;
using Envelope.Windows.Models;
using Envelope.Windows.Services;

namespace Envelope.Windows.ViewModels;

public sealed class ChatViewModel : PageViewModel
{
    private readonly IEnvelopeUiService _workspace;
    private readonly Action _openContacts;
    private ConversationUiModel? _selectedConversation;
    private string _searchText = string.Empty;
    private string _messageText = string.Empty;
    private string? _pendingConversationId;
    private bool _isReading;
    private string _filter = "all";
    private readonly Dictionary<string, string> _drafts = new(StringComparer.Ordinal);
    private readonly HashSet<string> _markingRead = new(StringComparer.Ordinal);
    private string? _messageConversationId;

    public bool IsReading
    {
        get => _isReading;
        set
        {
            _isReading = value;
            if (value && SelectedConversation is { UnreadCount: > 0 } conversation)
                _ = MarkConversationReadAsync(conversation.Id);
        }
    }

    public bool FilterAll { get => _filter == "all"; set { if (value) SetFilter("all"); } }
    public bool FilterUnread { get => _filter == "unread"; set { if (value) SetFilter("unread"); } }
    public bool FilterGroups { get => _filter == "groups"; set { if (value) SetFilter("groups"); } }

    private void SetFilter(string filter)
    {
        _filter = filter;
        OnPropertyChanged(nameof(FilterAll));
        OnPropertyChanged(nameof(FilterUnread));
        OnPropertyChanged(nameof(FilterGroups));
        VisibleConversations.Refresh();
    }

    public ChatViewModel(IEnvelopeUiService workspace, Action openContacts) : base("Chat")
    {
        _workspace = workspace;
        _openContacts = openContacts;
        Conversations = new ObservableCollection<ConversationUiModel>();
        VisibleConversations = CollectionViewSource.GetDefaultView(Conversations);
        VisibleConversations.Filter = MatchesSearch;
        Messages = new ObservableCollection<MessageUiModel>();

        OpenContactsCommand = new RelayCommand(_ => _openContacts());
        SendCommand = new AsyncRelayCommand(_ => SendAsync(), _ => CanSend);
        AttachFileCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(UiAction.AttachFile),
            _ => HasSelection);
        SealCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(UiAction.SealOfflineEnvelope),
            _ => CanSeal);
        ManageGroupCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(UiAction.ManageGroupMembers),
            _ => SelectedConversation?.IsGroup == true);
        LeaveGroupCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(UiAction.LeaveGroup),
            _ => SelectedConversation?.IsGroup == true);
        AcceptInvitationCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(
                UiAction.AcceptGroupInvitation,
                SelectedConversation?.PendingGroupInvitationId),
            _ => SelectedConversation?.HasPendingGroupInvitation == true
                 && !string.IsNullOrWhiteSpace(SelectedConversation.PendingGroupInvitationId));
        DeclineInvitationCommand = new AsyncRelayCommand(
            _ => ExecuteConversationActionAsync(
                UiAction.DeclineGroupInvitation,
                SelectedConversation?.PendingGroupInvitationId),
            _ => SelectedConversation?.HasPendingGroupInvitation == true
                 && !string.IsNullOrWhiteSpace(SelectedConversation.PendingGroupInvitationId));
        OpenAttachmentCommand = new AsyncRelayCommand(
            parameter => OpenAttachmentAsync(parameter as MessageUiModel),
            parameter => parameter is MessageUiModel { HasAttachment: true });
        DeleteMessageCommand = new AsyncRelayCommand(
            parameter => DeleteMessageAsync(parameter as MessageUiModel),
            parameter => parameter is MessageUiModel);
        DeleteSelectedMessagesCommand = new AsyncRelayCommand(DeleteSelectedMessagesAsync);
        LoadEarlierMessagesCommand = new AsyncRelayCommand(
            _ => LoadEarlierMessagesAsync(),
            _ => SelectedConversation?.HasEarlierMessages == true);
    }

    public ObservableCollection<ConversationUiModel> Conversations { get; }

    public ICollectionView VisibleConversations { get; }

    public ObservableCollection<MessageUiModel> Messages { get; }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetProperty(ref _searchText, value))
            {
                VisibleConversations.Refresh();
            }
        }
    }

    public ConversationUiModel? SelectedConversation
    {
        get => _selectedConversation;
        set
        {
            var previousId = _selectedConversation?.Id;
            if (previousId is not null) _drafts[previousId] = MessageText;
            if (SetProperty(ref _selectedConversation, value))
            {
                if (value?.Id != previousId)
                    MessageText = value is null ? string.Empty : _drafts.GetValueOrDefault(value.Id, string.Empty);
                RefreshMessages();
                OnPropertyChanged(nameof(HasSelection));
                OnPropertyChanged(nameof(CanSeal));
                OnPropertyChanged(nameof(CanSend));
                OnPropertyChanged(nameof(HasEarlierMessages));
                SendCommand.RaiseCanExecuteChanged();
                AttachFileCommand.RaiseCanExecuteChanged();
                SealCommand.RaiseCanExecuteChanged();
                ManageGroupCommand.RaiseCanExecuteChanged();
                LeaveGroupCommand.RaiseCanExecuteChanged();
                AcceptInvitationCommand.RaiseCanExecuteChanged();
                DeclineInvitationCommand.RaiseCanExecuteChanged();
                LoadEarlierMessagesCommand.RaiseCanExecuteChanged();
                if (IsReading && value is { UnreadCount: > 0 })
                    _ = MarkConversationReadAsync(value.Id);
            }
        }
    }

    public string MessageText
    {
        get => _messageText;
        set
        {
            if (SetProperty(ref _messageText, value))
            {
                OnPropertyChanged(nameof(CanSend));
                SendCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool HasConversations => Conversations.Count > 0;

    public bool HasSelection => SelectedConversation is not null;

    public bool CanSeal => HasSelection;

    public bool CanSend => HasSelection && !string.IsNullOrWhiteSpace(MessageText);

    public bool HasEarlierMessages => SelectedConversation?.HasEarlierMessages == true;

    public RelayCommand OpenContactsCommand { get; }

    public AsyncRelayCommand SendCommand { get; }

    public AsyncRelayCommand AttachFileCommand { get; }

    public AsyncRelayCommand SealCommand { get; }

    public AsyncRelayCommand ManageGroupCommand { get; }

    public AsyncRelayCommand LeaveGroupCommand { get; }

    public AsyncRelayCommand AcceptInvitationCommand { get; }

    public AsyncRelayCommand DeclineInvitationCommand { get; }

    public AsyncRelayCommand OpenAttachmentCommand { get; }

    public AsyncRelayCommand DeleteMessageCommand { get; }

    public AsyncRelayCommand DeleteSelectedMessagesCommand { get; }

    public AsyncRelayCommand LoadEarlierMessagesCommand { get; }

    public override void ApplySnapshot(UiWorkspaceSnapshot snapshot)
    {
        var selectedId = _pendingConversationId ?? SelectedConversation?.Id ?? snapshot.Conversations.FirstOrDefault()?.Id;
        Conversations.Clear();
        foreach (var item in snapshot.Conversations.OrderByDescending(item => item.LastActivity))
        {
            Conversations.Add(item);
        }

        SelectedConversation = selectedId is null
            ? null
            : Conversations.FirstOrDefault(item => item.Id == selectedId);
        _pendingConversationId = SelectedConversation is null ? selectedId : null;
        OnPropertyChanged(nameof(HasConversations));
        VisibleConversations.Refresh();
    }

    public void SelectConversation(string conversationId)
    {
        SetFilter("all");
        SearchText = string.Empty;
        var match = Conversations.FirstOrDefault(item => item.Id == conversationId);
        if (match is not null)
        {
            SelectedConversation = match;
            _pendingConversationId = null;
        }
        else
        {
            _pendingConversationId = conversationId;
        }
    }

    private bool MatchesSearch(object value)
    {
        if (value is not ConversationUiModel item)
        {
            return false;
        }

        if (_filter == "unread" && item.UnreadCount == 0) return false;
        if (_filter == "groups" && !item.IsGroup) return false;

        if (string.IsNullOrWhiteSpace(SearchText))
        {
            return true;
        }

        var term = SearchText.Trim();
        return item.DisplayName.Contains(term, StringComparison.CurrentCultureIgnoreCase)
               || item.Preview.Contains(term, StringComparison.CurrentCultureIgnoreCase);
    }

    private void RefreshMessages()
    {
        if (_messageConversationId != SelectedConversation?.Id)
        {
            Messages.Clear();
            _messageConversationId = SelectedConversation?.Id;
        }
        if (SelectedConversation is null)
        {
            return;
        }

        var ordered = SelectedConversation.Messages.OrderBy(item => item.Timestamp).ToArray();
        for (var index = 0; index < ordered.Length; index++)
        {
            if (index >= Messages.Count) Messages.Add(ordered[index]);
            else if (Messages[index] != ordered[index]) Messages[index] = ordered[index];
        }
        while (Messages.Count > ordered.Length) Messages.RemoveAt(Messages.Count - 1);
    }

    private async Task MarkConversationReadAsync(string conversationId)
    {
        if (!_markingRead.Add(conversationId)) return;
        try
        {
            await _workspace.ExecuteAsync(new UiOperationRequest(UiAction.MarkConversationRead, conversationId));
        }
        finally { _markingRead.Remove(conversationId); }
    }

    private async Task SendAsync()
    {
        var conversation = SelectedConversation;
        var text = MessageText.Trim();
        if (conversation is null || text.Length == 0)
        {
            return;
        }

        var result = await _workspace.ExecuteAsync(
            new UiOperationRequest(UiAction.SendMessage, conversation.Id, text));
        if (result.Succeeded)
        {
            _drafts[conversation.Id] = string.Empty;
            if (SelectedConversation?.Id == conversation.Id && MessageText.Trim() == text)
                MessageText = string.Empty;
        }
    }

    private async Task ExecuteConversationActionAsync(UiAction action, string? contextId = null)
    {
        if (SelectedConversation is null)
        {
            return;
        }

        await _workspace.ExecuteAsync(
            new UiOperationRequest(action, contextId ?? SelectedConversation.Id));
    }

    private async Task OpenAttachmentAsync(MessageUiModel? message)
    {
        if (message is null || !message.HasAttachment)
        {
            return;
        }

        await _workspace.ExecuteAsync(
            new UiOperationRequest(
                UiAction.OpenAttachment,
                message.Id,
                message.AttachmentPath));
    }

    private async Task DeleteMessageAsync(MessageUiModel? message)
    {
        if (message is null) return;
        await _workspace.ExecuteAsync(
            new UiOperationRequest(UiAction.DeleteLocalMessage, message.Id));
    }

    private async Task DeleteSelectedMessagesAsync(object? parameter)
    {
        if (parameter is not IList selectedItems) return;
        var ids = selectedItems.OfType<MessageUiModel>()
            .Select(message => message.Id)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (ids.Length == 0) return;
        await _workspace.ExecuteAsync(new UiOperationRequest(
            UiAction.DeleteSelectedMessages,
            SelectedConversation?.Id,
            string.Join('\n', ids)));
    }

    private async Task LoadEarlierMessagesAsync()
    {
        if (SelectedConversation is null) return;
        await _workspace.ExecuteAsync(new UiOperationRequest(
            UiAction.LoadEarlierMessages,
            SelectedConversation.Id));
    }
}
