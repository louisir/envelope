using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using Envelope.Windows.Models;
using Forms = System.Windows.Forms;

namespace Envelope.Windows.Services;

public sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon _tray;
    private readonly Forms.ContextMenuStrip _menu = new TrayContextMenu();
    private readonly Icon _normal;
    private readonly Icon _unread;
    private readonly Action<string?> _open;
    private readonly Action _settings;
    private readonly Action _lock;
    private readonly Action _exit;
    private readonly TrayNotificationState _state = new();
    private string? _notificationTarget;
    private int _count;
    private bool _locked;
    public bool IsContextMenuInteraction { get; private set; }

    public TrayService(Action<string?> open, Action settings, Action lockApp, Action exit)
    {
        _open = open; _settings = settings; _lock = lockApp; _exit = exit;
        using var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Envelope.Windows;component/Resources/AppIcon.ico"))!.Stream;
        _normal = new Icon(stream, 32, 32);
        using var bitmap = _normal.ToBitmap();
        using (var graphics = Graphics.FromImage(bitmap))
        {
            using var badge = new SolidBrush(Color.FromArgb(239, 68, 68));
            graphics.FillEllipse(Brushes.White, 20, 0, 12, 12);
            graphics.FillEllipse(badge, 21, 1, 10, 10);
        }
        var handle = bitmap.GetHicon();
        try { using var temporary = Icon.FromHandle(handle); _unread = (Icon)temporary.Clone(); }
        finally { DestroyIcon(handle); }
        _tray = new Forms.NotifyIcon { Icon = _normal, Text = "Envelope", ContextMenuStrip = _menu, Visible = true };
        // NotifyIcon foregrounds its native window before opening the menu. Mark
        // the gesture on mouse-down, before WPF receives application activation.
        _tray.MouseDown += (_, e) => IsContextMenuInteraction = e.Button == Forms.MouseButtons.Right;
        _tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) _open(null); };
        _tray.BalloonTipClicked += (_, _) => _open(_notificationTarget);
        _menu.Opening += (_, _) => { IsContextMenuInteraction = true; BuildMenu(); };
        _menu.Closed += (_, _) => Application.Current.Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.ContextIdle,
            new Action(() => { if (!_menu.Visible) IsContextMenuInteraction = false; }));
    }

    private static string T(string key) => LocalizationService.Current.GetString(key);

    private void BuildMenu()
    {
        while (_menu.Items.Count > 0) _menu.Items[0].Dispose();
        _menu.Items.Add(new Forms.ToolStripMenuItem("Envelope · " + T(_locked ? "Tray.Locked" : "Tray.Running")) { Enabled = false });
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add(T(_locked ? "Tray.Unlock" : "Tray.Open"), null, (_, _) => _open(null));
        var quiet = new Forms.ToolStripMenuItem(T("Tray.Dnd")) { Checked = _state.IsQuiet(DateTimeOffset.UtcNow) };
        quiet.DropDown = new TrayContextMenu();
        quiet.DropDownItems.Add(T("Tray.DndOff"), null, (_, _) => _state.QuietUntil = null);
        quiet.DropDownItems.Add(T("Tray.DndHour"), null, (_, _) => _state.QuietUntil = DateTimeOffset.UtcNow.AddHours(1));
        quiet.DropDownItems.Add(T("Tray.DndSession"), null, (_, _) => _state.QuietUntil = DateTimeOffset.MaxValue);
        _menu.Items.Add(quiet);
        _menu.Items.Add(T("Tray.Lock"), null, (_, _) => _lock());
        _menu.Items.Add(T("Nav.Settings"), null, (_, _) => _settings());
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add(T("Tray.Exit"), null, (_, _) => _exit());
    }

    public void SetLocked(bool locked) { _locked = locked; UpdateTooltip(); }

    public void Update(UiWorkspaceSnapshot snapshot, string? readingConversationId)
    {
        _count = snapshot.Conversations.Sum(item => item.UnreadCount);
        _tray.Icon = _count > 0 ? _unread : _normal;
        UpdateTooltip();
        var target = _state.Observe(snapshot.Conversations, DateTimeOffset.UtcNow);
        if (target is null || target == readingConversationId) return;
        _notificationTarget = target;
        _tray.ShowBalloonTip(5000, "Envelope", string.Format(T("Tray.NewMessages"), _count) + "\n" + T("Tray.OpenConversation"), Forms.ToolTipIcon.None);
    }

    private void UpdateTooltip()
    {
        var text = "Envelope · " + (_locked ? T("Tray.Locked") : _count > 0 ? string.Format(T("Tray.NewMessages"), _count) : T("Tray.Running"));
        _tray.Text = text.Length > 63 ? text[..63] : text;
    }

    public void Dispose()
    {
        _tray.Visible = false;
        _tray.Dispose(); _menu.Dispose(); _normal.Dispose(); _unread.Dispose();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
