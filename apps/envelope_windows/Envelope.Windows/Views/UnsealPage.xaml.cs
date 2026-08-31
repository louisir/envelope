using System.Windows;
using System.Windows.Controls;
using Envelope.Windows.ViewModels;

namespace Envelope.Windows.Views;

public partial class UnsealPage : UserControl
{
    public UnsealPage()
    {
        InitializeComponent();
    }

    private void OnDragEnter(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (DataContext is not UnsealViewModel viewModel
            || e.Data.GetData(DataFormats.FileDrop) is not string[] files
            || files.Length == 0
            || !viewModel.ImportPathCommand.CanExecute(files[0]))
        {
            return;
        }

        viewModel.ImportPathCommand.Execute(files[0]);
        e.Handled = true;
    }
}
