using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Models;

namespace Envelope.Windows.Services;

internal sealed record GroupDialogResult(string Name, GroupPolicy Policy, IReadOnlyList<string> ContactIds);
internal enum GroupManagementAction { Rename, UpdateAvatar, Invite, Remove, Endorse, SetLocalTrust }
internal sealed record GroupManagementResult(
    GroupManagementAction Action,
    string? MemberKeyId = null,
    bool? Trusted = null);

internal static class DialogService
{
    public static string? Prompt(string title, string message, string initial = "", bool multiline = false)
    {
        var window = BaseWindow(title, multiline ? 520 : 430, multiline ? 360 : 230);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var label = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        var box = new TextBox
        {
            Text = initial,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
            MinHeight = multiline ? 170 : 36,
        };
        Grid.SetRow(box, 1);
        var buttons = Buttons(window, () => window.DialogResult = true);
        Grid.SetRow(buttons, 2);
        panel.Children.Add(label); panel.Children.Add(box); panel.Children.Add(buttons);
        window.Content = panel;
        window.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return window.ShowDialog() == true ? box.Text : null;
    }

    public static void ShowProtectedText(string title, string message, string value)
    {
        var window = BaseWindow(title, 620, 360);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        var box = new TextBox { Text = value, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 15 };
        Grid.SetRow(box, 1); panel.Children.Add(box);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var copy = new Button { Content = "复制", MinWidth = 90, Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, _) =>
        {
            Clipboard.SetText(value);
        };
        var close = new Button { Content = "我已安全保存", MinWidth = 120, IsDefault = true };
        close.Click += (_, _) => window.Close();
        buttons.Children.Add(copy); buttons.Children.Add(close); Grid.SetRow(buttons, 2); panel.Children.Add(buttons);
        window.Content = panel;
        var autoClose = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        autoClose.Tick += (_, _) => window.Close();
        window.Loaded += (_, _) => autoClose.Start();
        window.Closed += (_, _) => autoClose.Stop();
        window.ShowDialog();
        autoClose.Stop();
        try
        {
            // TextBox Ctrl+C and its context-menu Copy bypass the custom button,
            // so clear by exact value instead of relying on a button flag.
            if (Clipboard.ContainsText() &&
                string.Equals(Clipboard.GetText(), value, StringComparison.Ordinal))
                Clipboard.Clear();
        }
        catch
        {
            // Clipboard ownership may change while the dialog is closing.
        }
    }

    public static IntroBundleSummary? ShowIntroExchange(
        string payload,
        IntroBundleSummary owner,
        Func<CancellationToken, Task<IntroSessionResponse?>>? pollResponse,
        string? warning = null)
    {
        var window = BaseWindow("临时互加联系人", 720, 820);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(340) });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(110) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        panel.Children.Add(new TextBlock
        {
            Text =
                $"联系人：{owner.DisplayName}\nFingerprint：{FormatFingerprint(owner.KeyId)}\n" +
                $"有效期：{DateTimeOffset.FromUnixTimeMilliseconds(checked((long)owner.ExpiresAtUnixMs)).ToLocalTime():g}\n\n" +
                "让对方扫描下方 Android 兼容二维码，并通过可信通道核对 fingerprint。" +
                (string.IsNullOrWhiteSpace(warning) ? string.Empty : $"\n\n{warning}"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var qrImage = new Image
        {
            Source = QrCodeService.Encode(payload),
            Width = 320,
            Height = 320,
            Stretch = System.Windows.Media.Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            SnapsToDevicePixels = true,
        };
        System.Windows.Media.RenderOptions.SetBitmapScalingMode(
            qrImage,
            System.Windows.Media.BitmapScalingMode.NearestNeighbor);
        Grid.SetRow(qrImage, 1);
        panel.Children.Add(qrImage);
        var payloadBox = new TextBox
        {
            Text = payload,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            FontSize = 13,
            Margin = new Thickness(0, 8, 0, 0),
        };
        Grid.SetRow(payloadBox, 2);
        panel.Children.Add(payloadBox);

        var status = new TextBlock
        {
            Text = pollResponse is null
                ? "双向互加通道不可用；对方保存后，请反向交换一次载荷。"
                : "正在等待对方扫描并发送互加请求……",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 0),
        };
        Grid.SetRow(status, 3);
        panel.Children.Add(status);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0),
        };
        var copy = new Button { Content = "复制载荷", MinWidth = 96, Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, _) => Clipboard.SetText(payload);
        var check = new Button
        {
            Content = "检查互加请求",
            MinWidth = 116,
            Margin = new Thickness(0, 0, 8, 0),
            IsEnabled = pollResponse is not null,
        };
        var confirm = new Button
        {
            Content = "核对并添加对方",
            MinWidth = 130,
            Margin = new Thickness(0, 0, 8, 0),
            Visibility = Visibility.Collapsed,
        };
        var close = new Button { Content = "完成", MinWidth = 88, IsCancel = true };
        close.Click += (_, _) => window.DialogResult = false;
        buttons.Children.Add(copy);
        buttons.Children.Add(check);
        buttons.Children.Add(confirm);
        buttons.Children.Add(close);
        Grid.SetRow(buttons, 4);
        panel.Children.Add(buttons);
        window.Content = panel;

        using var lifetime = new CancellationTokenSource();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        IntroBundleSummary? pendingResponder = null;
        var pollInFlight = false;
        async Task PollOnceAsync()
        {
            if (pollResponse is null || pollInFlight || pendingResponder is not null || lifetime.IsCancellationRequested)
                return;
            pollInFlight = true;
            check.IsEnabled = false;
            try
            {
                var response = await pollResponse(lifetime.Token);
                if (response is null)
                {
                    status.Text = "尚未收到互加请求；窗口保持打开时会继续检查。";
                    return;
                }
                pendingResponder = response.ResponderBundle;
                status.Text =
                    $"收到对方请求：{pendingResponder.DisplayName}\n" +
                    $"Fingerprint：{FormatFingerprint(pendingResponder.KeyId)}\n" +
                    "签名和有效期已通过验证；仍须通过可信通道人工核对 fingerprint。";
                confirm.Visibility = Visibility.Visible;
                timer.Stop();
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
            {
            }
            catch (Exception error)
            {
                status.Text = $"检查失败，将继续重试：{error.Message}";
            }
            finally
            {
                pollInFlight = false;
                check.IsEnabled = pollResponse is not null && pendingResponder is null && !lifetime.IsCancellationRequested;
            }
        }

        check.Click += async (_, _) => await PollOnceAsync();
        confirm.Click += (_, _) =>
        {
            var responder = pendingResponder;
            if (responder is null) return;
            var accepted = MessageBox.Show(
                window,
                $"载荷签名有效，但签名不能证明现实身份。\n\n" +
                $"联系人：{responder.DisplayName}\nFingerprint：{FormatFingerprint(responder.KeyId)}\n\n" +
                "你是否已经通过可信通道核对该 fingerprint，并确认保存？",
                "核对 fingerprint 后保存",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning) == MessageBoxResult.Yes;
            if (accepted) window.DialogResult = true;
        };
        timer.Tick += async (_, _) => await PollOnceAsync();
        window.Loaded += async (_, _) =>
        {
            if (pollResponse is null) return;
            timer.Start();
            await PollOnceAsync();
        };
        window.Closed += (_, _) =>
        {
            timer.Stop();
            lifetime.Cancel();
        };

        IntroBundleSummary? result = null;
        try
        {
            if (window.ShowDialog() == true) result = pendingResponder;
        }
        finally
        {
            timer.Stop();
            lifetime.Cancel();
            try
            {
                if (Clipboard.ContainsText() &&
                    string.Equals(Clipboard.GetText(), payload, StringComparison.Ordinal))
                    Clipboard.Clear();
            }
            catch
            {
            }
        }
        return result;
    }

    public static GroupDialogResult? CreateGroup(IReadOnlyList<ContactUiModel> contacts)
    {
        var available = contacts.Where(item => !item.IsGroup).ToArray();
        var window = BaseWindow("创建群组", 520, 590);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var name = new TextBox { Text = "新群组", Margin = new Thickness(0, 0, 0, 12), MinHeight = 36 };
        panel.Children.Add(name);
        var policy = new ComboBox { ItemsSource = Enum.GetValues<GroupPolicy>(), SelectedItem = GroupPolicy.Normal, Margin = new Thickness(0, 0, 0, 12), MinHeight = 36 };
        Grid.SetRow(policy, 1); panel.Children.Add(policy);
        var list = new ListBox { BorderThickness = new Thickness(1) };
        foreach (var contact in available)
            list.Items.Add(new CheckBox { Content = $"{contact.DisplayName}  ·  {contact.Fingerprint}", Tag = contact.Id, Margin = new Thickness(8), IsChecked = false });
        Grid.SetRow(list, 2); panel.Children.Add(list);
        var buttons = Buttons(window, () =>
        {
            var count = list.Items.OfType<CheckBox>().Count(item => item.IsChecked == true);
            if (count < 2) { MessageBox.Show(window, "至少选择 2 位联系人。", "Envelope", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            window.DialogResult = true;
        });
        Grid.SetRow(buttons, 3); panel.Children.Add(buttons);
        window.Content = panel;
        if (window.ShowDialog() != true) return null;
        return new GroupDialogResult(
            string.IsNullOrWhiteSpace(name.Text) ? "未命名群组" : name.Text.Trim(),
            policy.SelectedItem is GroupPolicy selected ? selected : GroupPolicy.Normal,
            list.Items.OfType<CheckBox>().Where(item => item.IsChecked == true).Select(item => item.Tag?.ToString() ?? string.Empty).Where(item => item.Length > 0).ToArray());
    }

    public static GroupManagementResult? ManageGroup(
        GroupRecord group,
        IReadOnlyList<GroupMemberRecord> members,
        string selfKeyId)
    {
        var self = members.FirstOrDefault(member => member.KeyId == selfKeyId);
        var isOwner = group.IsActive && group.OwnerKeyId == selfKeyId && self?.Status == GroupMemberStatus.Active;
        var canEndorse = group.IsActive && group.Policy == GroupPolicy.Consensus && self?.Status == GroupMemberStatus.Active;
        var window = BaseWindow($"管理群组 · {group.Name}", 720, 560);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        panel.Children.Add(new TextBlock
        {
            Text = $"{group.Policy} · epoch {group.Epoch} · {(group.IsActive ? "活动" : "已解散")}\n" +
                   "选择成员后可移除或为共识群候选成员背书。",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var list = new ListBox { BorderThickness = new Thickness(1), MinHeight = 280 };
        foreach (var member in members.OrderBy(item => item.Role).ThenBy(item => item.DisplayName, StringComparer.CurrentCultureIgnoreCase))
        {
            list.Items.Add(new ListBoxItem
            {
                Content = $"{member.DisplayName}  ·  {member.Role} / {member.Status} / {member.TrustState}\n{member.KeyId}",
                Tag = member,
                Padding = new Thickness(9),
            });
        }
        Grid.SetRow(list, 1);
        panel.Children.Add(list);

        GroupManagementResult? result = null;
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 14, 0, 0),
        };
        var rename = ActionButton("改群名", isOwner, () => result = new(GroupManagementAction.Rename));
        var avatar = ActionButton("更新头像 seed", isOwner, () => result = new(GroupManagementAction.UpdateAvatar));
        var invite = ActionButton("邀请成员", isOwner, () => result = new(GroupManagementAction.Invite));
        var remove = ActionButton("移除成员", false, () =>
        {
            if ((list.SelectedItem as ListBoxItem)?.Tag is GroupMemberRecord member)
                result = new(GroupManagementAction.Remove, member.KeyId);
        });
        var endorse = ActionButton("共识背书", false, () =>
        {
            if ((list.SelectedItem as ListBoxItem)?.Tag is GroupMemberRecord member)
                result = new(GroupManagementAction.Endorse, member.KeyId);
        });
        var localTrust = ActionButton("信任 fingerprint", false, () =>
        {
            if ((list.SelectedItem as ListBoxItem)?.Tag is GroupMemberRecord member)
            {
                var currentlyTrusted = member.TrustState is
                    GroupTrustState.Verified or GroupTrustState.Inviter;
                result = new(GroupManagementAction.SetLocalTrust, member.KeyId, !currentlyTrusted);
            }
        });
        foreach (var button in new[] { rename, avatar, invite, remove, endorse, localTrust }) actions.Children.Add(button);
        list.SelectionChanged += (_, _) =>
        {
            var selected = (list.SelectedItem as ListBoxItem)?.Tag as GroupMemberRecord;
            remove.IsEnabled = isOwner && selected is not null && selected.KeyId != selfKeyId &&
                               selected.Status is not (GroupMemberStatus.Left or GroupMemberStatus.Removed);
            endorse.IsEnabled = canEndorse && selected is not null && selected.KeyId != selfKeyId &&
                                selected.Status == GroupMemberStatus.Accepted;
            var currentlyTrusted = selected?.TrustState is
                GroupTrustState.Verified or GroupTrustState.Inviter;
            localTrust.Content = currentlyTrusted ? "取消本机信任" : "信任 fingerprint";
            localTrust.IsEnabled = group.IsActive && group.Policy == GroupPolicy.Verified &&
                                   selected is not null && selected.KeyId != selfKeyId &&
                                   selected.Status is not (GroupMemberStatus.Left or GroupMemberStatus.Removed);
        };
        Grid.SetRow(actions, 2);
        panel.Children.Add(actions);

        var close = new Button
        {
            Content = "关闭",
            MinWidth = 90,
            IsCancel = true,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0),
        };
        close.Click += (_, _) => window.DialogResult = false;
        Grid.SetRow(close, 3);
        panel.Children.Add(close);
        window.Content = panel;

        foreach (var button in new[] { rename, avatar, invite, remove, endorse, localTrust })
        {
            button.Click += (_, _) =>
            {
                if (result is not null) window.DialogResult = true;
            };
        }
        return window.ShowDialog() == true ? result : null;
    }

    public static IReadOnlyList<string>? SelectGroupInvitees(
        IReadOnlyList<ContactUiModel> contacts,
        IReadOnlySet<string> excludedKeyIds)
    {
        var available = contacts
            .Where(item => !item.IsGroup && !excludedKeyIds.Contains(item.Id))
            .OrderBy(item => item.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
        if (available.Length == 0)
        {
            MessageBox.Show("没有可邀请的新联系人。", "Envelope", MessageBoxButton.OK, MessageBoxImage.Information);
            return null;
        }

        var window = BaseWindow("邀请群成员", 540, 520);
        var panel = new Grid { Margin = new Thickness(22) };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Children.Add(new TextBlock { Text = "选择一位或多位已核对 fingerprint 的联系人。", Margin = new Thickness(0, 0, 0, 12) });
        var list = new ListBox { BorderThickness = new Thickness(1) };
        foreach (var contact in available)
            list.Items.Add(new CheckBox { Content = $"{contact.DisplayName}  ·  {contact.Fingerprint}", Tag = contact.Id, Margin = new Thickness(8) });
        Grid.SetRow(list, 1);
        panel.Children.Add(list);
        var buttons = Buttons(window, () =>
        {
            if (!list.Items.OfType<CheckBox>().Any(item => item.IsChecked == true))
            {
                MessageBox.Show(window, "至少选择 1 位联系人。", "Envelope", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            window.DialogResult = true;
        });
        Grid.SetRow(buttons, 2);
        panel.Children.Add(buttons);
        window.Content = panel;
        if (window.ShowDialog() != true) return null;
        return list.Items.OfType<CheckBox>()
            .Where(item => item.IsChecked == true)
            .Select(item => item.Tag?.ToString() ?? string.Empty)
            .Where(item => item.Length > 0)
            .ToArray();
    }

    private static Window BaseWindow(string title, double width, double height) => new()
    {
        Title = title,
        Width = width,
        Height = height,
        WindowStartupLocation = WindowStartupLocation.CenterOwner,
        Owner = Application.Current?.MainWindow,
        ResizeMode = ResizeMode.NoResize,
        ShowInTaskbar = false,
        Background = System.Windows.Media.Brushes.White,
    };

    private static StackPanel Buttons(Window window, Action accept)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new Button { Content = "取消", MinWidth = 88, IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => window.DialogResult = false;
        var ok = new Button { Content = "确定", MinWidth = 88, IsDefault = true };
        ok.Click += (_, _) => accept();
        panel.Children.Add(cancel); panel.Children.Add(ok);
        return panel;
    }

    private static Button ActionButton(string text, bool enabled, Action select)
    {
        var button = new Button
        {
            Content = text,
            IsEnabled = enabled,
            MinWidth = 92,
            Margin = new Thickness(0, 0, 8, 0),
        };
        button.Click += (_, _) => select();
        return button;
    }

    private static string FormatFingerprint(string keyId) => string.Join(
        ' ',
        Enumerable.Range(0, (keyId.Length + 3) / 4)
            .Select(index => keyId.Substring(index * 4, Math.Min(4, keyId.Length - index * 4))));
}
