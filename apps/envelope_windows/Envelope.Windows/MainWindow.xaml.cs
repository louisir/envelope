using System.Windows;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Shell;
using System.Windows.Threading;
using Envelope.Windows.ViewModels;
using Envelope.Windows.Services;

namespace Envelope.Windows;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Activated += (_, _) => UpdateReadVisibility();
        Deactivated += (_, _) => UpdateReadVisibility();
        IsVisibleChanged += (_, _) => UpdateReadVisibility();
        StateChanged += (_, _) => { UpdateReadVisibility(); QueueFrameUpdate(); };
        SourceInitialized += (_, _) =>
        {
            HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(WindowMessage);
            QueueFrameUpdate();
        };
    }

    private bool _frameUpdatePending;

    private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        // Recalculate after moving between monitors, changing DPI or moving the taskbar.
        if (message is 0x0047 or 0x02E0 or 0x001A) QueueFrameUpdate();
        return IntPtr.Zero;
    }

    private void QueueFrameUpdate()
    {
        if (_frameUpdatePending) return;
        _frameUpdatePending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            _frameUpdatePending = false;
            var inset = new Thickness();
            var hwnd = new WindowInteropHelper(this).Handle;
            if (WindowState == WindowState.Maximized && hwnd != IntPtr.Zero)
            {
                var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
                var origin = new NativePoint();
                if (GetMonitorInfo(MonitorFromWindow(hwnd, 2), ref monitor) &&
                    GetClientRect(hwnd, out var client) && ClientToScreen(hwnd, ref origin))
                {
                    // Windows maximizes the resize frame beyond the work area. Keep WPF
                    // content inside it, converting physical pixels to this monitor's DIPs.
                    var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(this);
                    inset = new Thickness(
                        Math.Max(0, monitor.Work.Left - origin.X) / dpi.DpiScaleX,
                        Math.Max(0, monitor.Work.Top - origin.Y) / dpi.DpiScaleY,
                        Math.Max(0, origin.X + client.Right - monitor.Work.Right) / dpi.DpiScaleX,
                        Math.Max(0, origin.Y + client.Bottom - monitor.Work.Bottom) / dpi.DpiScaleY);
                }
            }
            WindowFrame.Margin = inset;
            WindowChrome.GetWindowChrome(this).CaptionHeight = 36 + inset.Top;
        }));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ClientToScreen(IntPtr hwnd, ref NativePoint point);

    public bool ExitRequested { get; set; }
    public bool TrayAvailable { get; set; }
    public event EventHandler? LockRequested;

    public void UpdateReadVisibility()
    {
        if (DataContext is MainWindowViewModel model)
            model.SetWindowReading(IsVisible && IsActive && IsEnabled && Opacity > 0 && WindowState != WindowState.Minimized);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!ExitRequested && TrayAvailable)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    private void Profile_Click(object sender, RoutedEventArgs e) => Navigate(NavigationSection.Settings);
    private void Settings_Click(object sender, RoutedEventArgs e) => Navigate(NavigationSection.Settings);
    private void About_Click(object sender, RoutedEventArgs e) => Navigate(NavigationSection.About);
    private void Lock_Click(object sender, RoutedEventArgs e) => LockRequested?.Invoke(this, EventArgs.Empty);
    private void Navigate(NavigationSection section)
    {
        if (DataContext is MainWindowViewModel model) model.NavigateTo(section);
    }

    private void Minimize_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void MaximizeRestore_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
