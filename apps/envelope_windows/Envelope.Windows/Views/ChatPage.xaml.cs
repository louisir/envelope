using System.Windows.Controls;
using System.Windows.Input;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using Envelope.Windows.ViewModels;

namespace Envelope.Windows.Views;

public partial class ChatPage : UserControl
{
    private ChatViewModel? _model;
    private string? _conversationId;
    public ChatPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Subscribe();
        Unloaded += (_, _) => Unsubscribe();
    }

    private void Subscribe()
    {
        Unsubscribe();
        _model = DataContext as ChatViewModel;
        if (_model is null) return;
        _model.Messages.CollectionChanged += MessagesChanged;
        _model.PropertyChanged += ModelChanged;
        _conversationId = _model.SelectedConversation?.Id;
        ScrollToLatest();
    }

    private void Unsubscribe()
    {
        if (_model is null) return;
        _model.Messages.CollectionChanged -= MessagesChanged;
        _model.PropertyChanged -= ModelChanged;
        _model = null;
    }

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(ChatViewModel.SelectedConversation)) return;
        var id = _model?.SelectedConversation?.Id;
        if (id != _conversationId) { _conversationId = id; ScrollToLatest(); }
    }

    private void MessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        var scroll = FindScrollViewer(MessageList);
        if (scroll is null || scroll.ScrollableHeight - scroll.VerticalOffset < 40)
            ScrollToLatest();
    }

    private void ScrollToLatest() => Dispatcher.BeginInvoke(() =>
    {
        if (_model?.Messages.LastOrDefault() is { } last) MessageList.ScrollIntoView(last);
    }, DispatcherPriority.Loaded);

    private static ScrollViewer? FindScrollViewer(DependencyObject node)
    {
        if (node is ScrollViewer viewer) return viewer;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
            if (FindScrollViewer(VisualTreeHelper.GetChild(node, index)) is { } child) return child;
        return null;
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
