using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace Envelope.Windows.ViewModels;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool SetProperty<T>(
        ref T field,
        T value,
        [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class RelayCommand(Action<object?> execute, Predicate<object?>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => canExecute?.Invoke(parameter) ?? true;

    public void Execute(object? parameter) => execute(parameter);

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class AsyncRelayCommand : ObservableObject, ICommand
{
    private readonly Func<object?, Task> _execute;
    private readonly Predicate<object?>? _canExecute;
    private bool _isRunning;

    public AsyncRelayCommand(Func<object?, Task> execute, Predicate<object?>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsRunning
    {
        get => _isRunning;
        private set
        {
            if (SetProperty(ref _isRunning, value))
            {
                RaiseCanExecuteChanged();
            }
        }
    }

    public bool CanExecute(object? parameter) => !IsRunning && (_canExecute?.Invoke(parameter) ?? true);

    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter))
        {
            return;
        }

        try
        {
            IsRunning = true;
            await _execute(parameter);
        }
        finally
        {
            IsRunning = false;
        }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public abstract class PageViewModel : ObservableObject
{
    protected PageViewModel(string resourcePrefix)
    {
        ResourcePrefix = resourcePrefix;
    }

    public string ResourcePrefix { get; }

    public virtual void ApplySnapshot(Models.UiWorkspaceSnapshot snapshot)
    {
    }
}

public sealed class NavigationItemViewModel(
    NavigationSection section,
    string glyph,
    string title) : ObservableObject
{
    private string _title = title;

    public NavigationSection Section { get; } = section;

    public string Glyph { get; } = glyph;

    public string Title
    {
        get => _title;
        set => SetProperty(ref _title, value);
    }
}

public enum NavigationSection
{
    About,
    Contacts,
    Chat,
    Unseal,
    Settings,
}
