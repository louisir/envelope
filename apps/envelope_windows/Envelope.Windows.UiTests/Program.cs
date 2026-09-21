using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Envelope.Windows;
using Envelope.Windows.Models;
using Envelope.Windows.Services;
using Envelope.Windows.ViewModels;

internal static partial class Program
{
    private static int _passed;
    [STAThread]
    private static int Main(string[] args)
    {
        // A rendering harness must never run the real App startup (vault, network and associations).
        var activationTest = args.FirstOrDefault() == "--tray-activation";
        Application app = activationTest ? new ActivationTestApp() : new Application();
        foreach (var resource in new[] { "Themes/Light.xaml", "Strings.zh-CN.xaml", "Styles.xaml" })
            app.Resources.MergedDictionaries.Add(new ResourceDictionary {
                Source = new Uri($"/Envelope.Windows;component/Resources/{resource}", UriKind.Relative) });
        app.Resources.Add("BooleanToVisibilityConverter", new BooleanToVisibilityConverter());
        foreach (var (viewModel, view) in new[] {
            (typeof(AboutViewModel), typeof(Envelope.Windows.Views.AboutPage)),
            (typeof(ChatViewModel), typeof(Envelope.Windows.Views.ChatPage)),
            (typeof(ContactsViewModel), typeof(Envelope.Windows.Views.ContactsPage)),
            (typeof(UnsealViewModel), typeof(Envelope.Windows.Views.UnsealPage)),
            (typeof(SettingsViewModel), typeof(Envelope.Windows.Views.SettingsPage)) })
            app.Resources.Add(new DataTemplateKey(viewModel), new DataTemplate(viewModel) { VisualTree = new FrameworkElementFactory(view) });
        app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (activationTest) return VerifyTrayActivation((App)app);
        try
        {
            var output = Path.GetFullPath(args.FirstOrDefault() ?? "target/ui-redesign-evidence");
            Directory.CreateDirectory(output);
            var bindingErrors = new BindingErrors();
            PresentationTraceSources.DataBindingSource.Listeners.Add(bindingErrors);
            PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
            LocalizationService.Current.ApplyCulture("zh-CN");
            ThemeService.Current.ApplyTheme(ThemePreference.Light);
            VerifySettingsDraft(output);
            var service = new FakeWorkspace();
            var model = new MainWindowViewModel(service, LocalizationService.Current, ThemeService.Current);
            model.ApplySnapshot(service.Snapshot);
            Check(model.CurrentPage == model.Chat, "start on conversations");
            Check(model.PrimaryNavigationItems.Select(item => item.Section).SequenceEqual(new[] { NavigationSection.Chat, NavigationSection.Contacts, NavigationSection.Unseal }), "three primary destinations");
            Check(service.Reads.Count == 0, "background snapshot never marks read");
            model.Chat.SelectConversation("lin");
            model.Chat.MessageText = "林晓的草稿";
            model.Chat.SelectConversation("chen");
            Check(model.Chat.MessageText == "", "draft does not leak into another conversation");
            model.Chat.MessageText = "陈宁的草稿";
            model.Chat.SelectConversation("lin");
            Check(model.Chat.MessageText == "林晓的草稿", "draft restored by conversation");
            model.ApplySnapshot(service.Snapshot);
            Check(model.Chat.MessageText == "林晓的草稿", "background refresh preserves draft");
            model.Chat.FilterGroups = true;
            Check(model.Chat.VisibleConversations.Cast<ConversationUiModel>().All(item => item.IsGroup), "group filter");
            model.Chat.FilterUnread = true;
            Check(model.Chat.VisibleConversations.Cast<ConversationUiModel>().Count() == 2, "unread filter");
            model.Chat.SearchText = "交付清单";
            Check(model.Chat.VisibleConversations.Cast<ConversationUiModel>().Single().Id == "chen", "search combines with filter");
            model.Chat.SelectConversation("lin");
            Check(model.Chat.FilterAll && model.Chat.SearchText == "", "notification target clears list filters");
            model.SetWindowReading(true);
            model.Chat.SelectConversation("chen");
            Check(service.Reads.Contains("chen"), "active visible conversation marks read");
            model.NavigateTo(NavigationSection.Settings);
            service.Reads.Clear();
            model.ApplySnapshot(service.Snapshot);
            Check(service.Reads.Count == 0, "another page must not consume unread messages");
            model.SetWindowReading(false);
            model.NavigateTo(NavigationSection.Chat);
            model.ApplySnapshot(service.Snapshot);
            Check(service.Reads.Count == 0, "tray-hidden refresh retains unread");

            var state = new TrayNotificationState();
            var now = DateTimeOffset.UtcNow;
            Check(state.Observe(service.Snapshot.Conversations, now) is null, "no startup backlog notification");
            var changed = service.Snapshot.Conversations.Select(c => c.Id == "chen" ? c with { UnreadCount = 2 } : c.Id == "group" ? c with { UnreadCount = 1 } : c).ToArray();
            Check(state.Observe(changed, now) == "chen", "notify arrival even when total unread is unchanged");
            Check(state.Observe(changed, now) is null, "no duplicate notification on unchanged snapshot");
            state.QuietUntil = now.AddHours(1);
            changed = changed.Select(c => c.Id == "chen" ? c with { UnreadCount = 3 } : c).ToArray();
            Check(state.Observe(changed, now) is null, "do not disturb suppresses notification");
            Check(state.Observe(changed, now.AddHours(2)) is null, "quiet arrivals do not replay after expiry");
            changed = changed.Select(c => c.Id == "chen" ? c with { UnreadCount = 4 } : c).ToArray();
            Check(state.Observe(changed, now.AddHours(2)) == "chen", "new arrival after quiet expiry notifies");

            var opened = false; var settingsOpened = false; var locked = false; var quit = false;
            using (var tray = new TrayService(_ => opened = true, () => settingsOpened = true, () => locked = true, () => quit = true))
            {
                // Exercise the real menu wiring against harmless callbacks; no authentication or peer traffic.
                typeof(TrayService).GetMethod("BuildMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(tray, null);
                var menu = (System.Windows.Forms.ContextMenuStrip)typeof(TrayService).GetField("_menu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(tray)!;
                var notify = (System.Windows.Forms.NotifyIcon)typeof(TrayService).GetField("_tray", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(tray)!;
                foreach (var theme in new[] { ThemePreference.Light, ThemePreference.Dark })
                {
                    ThemeService.Current.ApplyTheme(theme); Pump();
                    for (var attempt = 0; attempt < 2; attempt++)
                    {
                        typeof(System.Windows.Forms.NotifyIcon).GetMethod("OnMouseDown", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                            .Invoke(notify, new object[] { new System.Windows.Forms.MouseEventArgs(System.Windows.Forms.MouseButtons.Right, 1, 0, 0, 0) });
                        Check(tray.IsContextMenuInteraction && !opened, $"{theme}: right press guards activation before menu opens, attempt {attempt + 1}");
                        menu.Show(new System.Drawing.Point(40, 80)); Pump();
                        Check(menu.Visible && !opened, $"{theme}: first and subsequent right menus do not invoke open-window action");
                        Check(menu.Region is not null && !menu.Region.IsVisible(0, 0) && menu.Region.IsVisible(menu.Width / 2, 2), $"{theme}: menu has actual rounded corners");
                        var palette = ((SolidColorBrush)Application.Current.FindResource("Brush.SurfaceRaised")).Color;
                        Check(menu.BackColor.R == palette.R && menu.BackColor.G == palette.G && menu.BackColor.B == palette.B, $"{theme}: tray menu follows theme");
                        if (attempt == 0)
                        {
                            using var bitmap = new System.Drawing.Bitmap(menu.Width, menu.Height);
                            menu.DrawToBitmap(bitmap, new System.Drawing.Rectangle(0, 0, menu.Width, menu.Height));
                            bitmap.Save(Path.Combine(output, $"tray-menu-{theme.ToString().ToLowerInvariant()}.png"));
                            var quiet = menu.Items.OfType<System.Windows.Forms.ToolStripMenuItem>().Single(item => item.Text == LocalizationService.Current.GetString("Tray.Dnd"));
                            quiet.ShowDropDown(); Pump();
                            Check(quiet.DropDown.Visible && quiet.DropDown.Region is not null && !quiet.DropDown.Region.IsVisible(0, 0), $"{theme}: quiet submenu also uses rounded corners");
                            quiet.DropDown.Close();
                        }
                        menu.Close(); Pump();
                        Check(!tray.IsContextMenuInteraction, "closing the tray menu releases activation guard");
                    }
                }
                ThemeService.Current.ApplyTheme(ThemePreference.Light); Pump();
                foreach (var key in new[] { "Tray.Open", "Nav.Settings", "Tray.Lock", "Tray.Exit" })
                    menu.Items.Cast<System.Windows.Forms.ToolStripItem>().Single(item => item.Text == LocalizationService.Current.GetString(key)).PerformClick();
                Check(opened && settingsOpened && locked && quit, "native tray menu routes open/settings/lock/quit");
                tray.Update(service.Snapshot, null);
                tray.SetLocked(true);
                typeof(TrayService).GetMethod("BuildMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(tray, null);
                opened = false;
                var unlockItem = menu.Items.OfType<System.Windows.Forms.ToolStripMenuItem>().Single(item => item.Text == LocalizationService.Current.GetString("Tray.Unlock"));
                unlockItem.PerformClick();
                Check(unlockItem.Enabled && opened, "locked tray exposes unlock entry routed through guarded open callback");
                tray.SetLocked(false);
                typeof(TrayService).GetMethod("BuildMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(tray, null);
                Check(menu.Items.OfType<System.Windows.Forms.ToolStripMenuItem>().Any(item => item.Text == LocalizationService.Current.GetString("Tray.Open")), "unlocked tray restores normal open label");
            }

            model.Chat.SelectConversation("lin");
            model.Chat.MessageText = "";
            var window = new MainWindow { DataContext = model, ShowActivated = false, ShowInTaskbar = false,
                WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000, TrayAvailable = true };
            window.Show(); Pump();
            Render(window, Path.Combine(output, "windows-chat-light.png"));
            model.Chat.MessageText = "刷新时保留的草稿";
            model.ApplySnapshot(service.Snapshot); Pump();
            Check(model.Chat.SelectedConversation?.Id == "lin" && model.Chat.MessageText == "刷新时保留的草稿", "bound list refresh retains selected conversation and draft");
            var closed = false;
            window.Closed += (_, _) => closed = true;
            window.Close(); Pump();
            Check(!window.IsVisible && !closed, "close hides window without destroying process UI");
            Check(!model.Chat.IsReading, "hidden window does not mark messages read");
            window.Show(); Pump();
            Check(window.IsVisible && !closed, "same window can be restored");
            window.Width = 960; window.Height = 640; Pump();
            Render(window, Path.Combine(output, "windows-chat-compact.png"));
            Check(Find<TextBox>(window, box => box.Name == "Composer") is { ActualWidth: > 450, ActualHeight: > 75 }, "composer fits minimum window size");
            VerifyComposerToolbar(window);
            window.Width = 1200; window.Height = 800;
            Pump(); VerifyComposerToolbar(window);
            foreach (var section in new[] { NavigationSection.Contacts, NavigationSection.Unseal, NavigationSection.Settings, NavigationSection.About })
            {
                model.NavigateTo(section); Pump();
                Render(window, Path.Combine(output, $"windows-{section.ToString().ToLowerInvariant()}.png"));
            }
            ThemeService.Current.ApplyTheme(ThemePreference.Dark);
            model.NavigateTo(NavigationSection.Chat); Pump();
            Check(Find<TextBlock>(window, text => text.Name == "MessageText")?.Foreground is SolidColorBrush textBrush && textBrush.Color.R > 180, "dark theme message contrast");
            Render(window, Path.Combine(output, "windows-chat-dark.png"));
            VerifyDropDowns(window, model, output);
            VerifyInputAlignment(window, model, output);
            VerifyWindowAndScrolling(window, model, output);
            model.NavigateTo(NavigationSection.Chat); Pump();
            LocalizationService.Current.ApplyCulture("en-US"); Pump();
            Render(window, Path.Combine(output, "windows-chat-english.png"));
            Check(bindingErrors.Errors.Count == 0, "all pages load without WPF binding errors: " + string.Join(" | ", bindingErrors.Errors));
            window.ExitRequested = true; window.Close(); Pump();
            Check(closed, "explicit exit closes window");
            VerifyPasscodeDialogs(output);
            using (var child = Process.Start(new ProcessStartInfo("dotnet") {
                ArgumentList = { typeof(Program).Assembly.Location, "--tray-activation" },
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })!)
            {
                var result = child.StandardOutput.ReadToEnd();
                var error = child.StandardError.ReadToEnd();
                child.WaitForExit();
                Console.Write(result);
                Check(child.ExitCode == 0, "application tray activation regression: " + error);
            }
            Console.WriteLine($"UI verification: {_passed} passed");
            app.Shutdown();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); app.Shutdown(); return 1; }
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
        _passed++; Console.WriteLine("PASS " + message);
    }
    private static void VerifyComposerToolbar(MainWindow window)
    {
        var toolbar = Find<StackPanel>(window, panel => panel.Name == "ComposerToolbar")!;
        var composer = Find<TextBox>(window, box => box.Name == "Composer")!;
        foreach (var button in toolbar.Children.OfType<Button>())
        {
            var allocated = LayoutInformation.GetLayoutSlot(button);
            var bottom = button.TranslatePoint(new Point(0, button.ActualHeight), composer).Y;
            Check(allocated.Height >= button.ActualHeight + button.Margin.Top + button.Margin.Bottom && bottom <= -8,
                "composer toolbar button and its hover border fit entirely above the input with spacing");
        }
    }
    private static void VerifyPasscodeDialogs(string output)
    {
        var directory = Path.Combine(Path.GetTempPath(), "envelope-passcode-ui-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var vault = new Envelope.Windows.Core.Security.WindowsSecureStore(directory);
            var codes = new Envelope.Windows.Core.Security.AppPasscodeStore(vault);
            codes.InitializeAsync().GetAwaiter().GetResult();
            LocalizationService.Current.ApplyCulture("zh-CN");
            foreach (var theme in new[] { ThemePreference.Light, ThemePreference.Dark })
            {
                ThemeService.Current.ApplyTheme(theme);
                var dialog = new Envelope.Windows.Views.PasscodeDialog(codes, "输入程序解锁码以解锁本地内容");
                Exception? failure = null;
                dialog.Loaded += async (_, _) =>
                {
                    try
                    {
                        Render(dialog, Path.Combine(output, $"passcode-{theme.ToString().ToLowerInvariant()}.png"));
                        var box = (PasswordBox)dialog.FindName("CurrentCode");
                        var button = (Button)dialog.FindName("Submit");
                        box.Password = "000000";
                        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        await WaitForSubmit(button);
                        Check(dialog.IsVisible && ((TextBlock)dialog.FindName("ErrorText")).Text.Contains("错误"), "wrong app code keeps dialog locked");
                        box.Password = "123456";
                        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        await WaitForSubmit(button);
                    }
                    catch (Exception error) { failure = error; dialog.Close(); }
                };
                Check(dialog.ShowDialog() == true && failure is null, $"{theme}: program code unlocks without Windows credential APIs: {failure}");
            }
            var change = new Envelope.Windows.Views.PasscodeDialog(codes, "修改测试", true);
            change.Loaded += async (_, _) =>
            {
                ((PasswordBox)change.FindName("CurrentCode")).Password = "123456";
                ((PasswordBox)change.FindName("NewCode")).Password = "654321";
                ((PasswordBox)change.FindName("ConfirmCode")).Password = "654320";
                var button = (Button)change.FindName("Submit");
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(((TextBlock)change.FindName("ErrorText")).Text.Contains("不一致"), "mismatched new codes are rejected");
                ((PasswordBox)change.FindName("ConfirmCode")).Password = "654321";
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await WaitForSubmit(button);
            };
            Check(change.ShowDialog() == true && !codes.UsesInitialCode, "change-code dialog saves new code");
            var canceled = new Envelope.Windows.Views.PasscodeDialog(codes, "取消测试");
            canceled.Loaded += (_, _) => canceled.Close();
            Check(canceled.ShowDialog() != true, "canceling code prompt cannot unlock");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    private static async Task WaitForSubmit(Button button)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!button.IsEnabled && DateTime.UtcNow < deadline) await Task.Delay(20);
        if (!button.IsEnabled) throw new TimeoutException("Unlock code verification did not complete.");
    }
    private sealed class ActivationTestApp : App
    {
        // Exercise App.OnActivated without starting production services or identity storage.
        protected override void OnStartup(StartupEventArgs e) { }
    }

    private static int VerifyTrayActivation(App app)
    {
        const System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        try
        {
            var window = new MainWindow { ShowActivated = false, ShowInTaskbar = false, Left = -20000, Top = -20000, ExitRequested = true };
            using var tray = new TrayService(_ => throw new InvalidOperationException("Unexpected open"), () => { }, () => { }, () => { });
            typeof(App).GetField("_window", flags)!.SetValue(app, window);
            typeof(App).GetField("_tray", flags)!.SetValue(app, tray);
            var resume = typeof(App).GetField("_deactivatedAt", flags)!;
            var activate = typeof(App).GetMethod("OnActivated", flags)!;
            var marker = DateTimeOffset.UtcNow.AddMinutes(-1);
            resume.SetValue(app, marker);
            activate.Invoke(app, new object[] { EventArgs.Empty });
            Check(!window.IsVisible && Equals(resume.GetValue(app), marker), "hidden-window activation does not consume resume state or reveal window");
            window.Show(); Pump();
            var notify = (System.Windows.Forms.NotifyIcon)typeof(TrayService).GetField("_tray", flags)!.GetValue(tray)!;
            var mouseDown = typeof(System.Windows.Forms.NotifyIcon).GetMethod("OnMouseDown", flags)!;
            mouseDown.Invoke(notify, new object[] { new System.Windows.Forms.MouseEventArgs(System.Windows.Forms.MouseButtons.Right, 1, 0, 0, 0) });
            resume.SetValue(app, marker);
            activate.Invoke(app, new object[] { EventArgs.Empty });
            Check(Equals(resume.GetValue(app), marker), "right tray activation does not enter main-window resume/unlock path");
            mouseDown.Invoke(notify, new object[] { new System.Windows.Forms.MouseEventArgs(System.Windows.Forms.MouseButtons.Left, 1, 0, 0, 0) });
            activate.Invoke(app, new object[] { EventArgs.Empty });
            Check(resume.GetValue(app) is null, "normal visible-window activation still enters existing resume path");
            VerifyAppPasscodeLifecycle(app, window);
            window.Close();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
    private static void VerifyAppPasscodeLifecycle(App app, MainWindow window)
    {
        const System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var directory = Path.Combine(Path.GetTempPath(), "envelope-passcode-lifecycle-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var vault = new Envelope.Windows.Core.Security.WindowsSecureStore(directory);
            var codes = new Envelope.Windows.Core.Security.AppPasscodeStore(vault);
            codes.InitializeAsync().GetAwaiter().GetResult();
            var guard = new AppPasscodeGuard(codes);
            var model = new MainWindowViewModel(new FakeWorkspace(), LocalizationService.Current, ThemeService.Current);
            window.DataContext = model;
            foreach (var (name, value) in new (string, object)[] { ("_passcodes", codes), ("_passcodeGuard", guard),
                ("_unlockGuard", new LocalUnlockCoordinator(guard)), ("_viewModel", model) })
                typeof(App).GetField(name, flags)!.SetValue(app, value);
            typeof(App).GetMethod("LockToTray", flags)!.Invoke(app, null);
            Check(!window.IsVisible && codes.IsLocked, "real App lock hides main window and persists lock state");
            foreach (var cancel in new[] { true, false })
            {
                Application.Current.Dispatcher.BeginInvoke(new Action(() =>
                {
                    var prompt = Application.Current.Windows.OfType<Envelope.Windows.Views.PasscodeDialog>().Single();
                    if (cancel) prompt.Close();
                    else
                    {
                        ((PasswordBox)prompt.FindName("CurrentCode")).Password = "123456";
                        ((Button)prompt.FindName("Submit")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    }
                }));
                var opening = (Task<bool>)typeof(App).GetMethod("OpenFromTrayAsync", flags)!.Invoke(app, new object?[] { null, null })!;
                var deadline = DateTime.UtcNow.AddSeconds(10);
                while (!opening.IsCompleted && DateTime.UtcNow < deadline) { Pump(); Thread.Sleep(10); }
                Check(opening.IsCompletedSuccessfully && opening.Result == !cancel, "real tray-open path reports unlock/cancel correctly");
                Check(window.IsVisible == !cancel && codes.IsLocked == cancel, "real tray-open path reveals content only after app code verification");
            }
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    private static void VerifyWindowAndScrolling(MainWindow window, MainWindowViewModel model, string output)
    {
        model.NavigateTo(NavigationSection.Settings); Pump();
        var viewer = Find<ScrollViewer>(window, v => v.Content is Grid && v.ScrollableHeight > 0)!;
        foreach (var theme in new[] { ThemePreference.Light, ThemePreference.Dark })
        {
            ThemeService.Current.ApplyTheme(theme); Pump();
            viewer.ScrollToTop(); Pump();
            var bar = Descendants(viewer).OfType<ScrollBar>().First(b => b.Orientation == Orientation.Vertical && b.IsVisible);
            var track = (Track)bar.Template.FindName("PART_Track", bar);
            Check(bar.ActualWidth == 10 && track.Thumb.ActualHeight >= 24, $"{theme}: slim scrollbar with usable thumb (width={bar.ActualWidth}, thumb height={track.Thumb.ActualHeight})");
            Check(Descendants(bar).OfType<RepeatButton>().Count() == 2, $"{theme}: no arrow buttons");
            var grip = (Border)track.Thumb.Template.FindName("Grip", track.Thumb);
            Check(((SolidColorBrush)grip.Background).Color == ((SolidColorBrush)Application.Current.FindResource("Brush.TextSubtle")).Color,
                $"{theme}: scrollbar follows current palette");
            ScrollBar.PageDownCommand.Execute(null, bar); Pump();
            Check(viewer.VerticalOffset > 0, $"{theme}: track page-down scrolls content");
            viewer.ScrollToTop(); Pump();
            track.Thumb.RaiseEvent(new DragDeltaEventArgs(0, 30) { RoutedEvent = Thumb.DragDeltaEvent }); Pump();
            Check(viewer.VerticalOffset > 0, $"{theme}: thumb dragging scrolls content");
            viewer.ScrollToBottom(); Pump();
            Check(Math.Abs(viewer.VerticalOffset - viewer.ScrollableHeight) < 1, $"{theme}: bottom of settings remains reachable");
            Render(window, Path.Combine(output, $"windows-scrollbar-{theme.ToString().ToLowerInvariant()}.png"));
        }
        window.WindowState = WindowState.Maximized; Pump(); Pump();
        var frame = (Border)window.FindName("WindowFrame");
        var workspace = (Grid)window.FindName("Workspace");
        var workArea = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle).WorkingArea;
        var topLeft = frame.PointToScreen(new Point());
        var bottomRight = frame.PointToScreen(new Point(frame.ActualWidth, frame.ActualHeight));
        Check(topLeft.X >= workArea.Left - 1 && topLeft.Y >= workArea.Top - 1 &&
            bottomRight.X <= workArea.Right + 1 && bottomRight.Y <= workArea.Bottom + 1,
            $"maximized content fits monitor work area: {topLeft} to {bottomRight}, work area {workArea}");
        Check(workspace.Margin.Bottom == 8 && workspace.TranslatePoint(new Point(0, workspace.ActualHeight), frame).Y <= frame.ActualHeight - 8,
            "maximized workspace retains visible bottom spacing");
        Render(window, Path.Combine(output, "windows-settings-maximized.png"));
        window.WindowState = WindowState.Normal; Pump();
        Check(frame.Margin == new Thickness(), "restoring clears maximized frame compensation");
    }
    private static void VerifyDropDowns(MainWindow window, MainWindowViewModel model, string output)
    {
        model.NavigateTo(NavigationSection.Settings); Pump();
        var combos = Descendants(window).OfType<ComboBox>().ToArray();
        Check(combos.Length == 4, "verify all four settings dropdowns");
        foreach (var theme in new[] { ThemePreference.Dark, ThemePreference.Light })
        {
            ThemeService.Current.ApplyTheme(theme); Pump();
            for (var index = 0; index < combos.Length; index++)
            {
                var combo = combos[index];
                combo.BringIntoView(); Pump();
                combo.IsDropDownOpen = true; Pump();
                var surface = (Border)combo.Template.FindName("DropDownSurface", combo);
                Check(surface.ActualHeight > 20 && surface.Background is SolidColorBrush background &&
                    background.Color == ((SolidColorBrush)Application.Current.FindResource("Brush.SurfaceRaised")).Color,
                    $"{theme} dropdown {index}: opened popup uses theme surface");
                for (var itemIndex = 0; itemIndex < combo.Items.Count; itemIndex++)
                {
                    var item = (ComboBoxItem)combo.ItemContainerGenerator.ContainerFromIndex(itemIndex);
                    Check(Contrast(((SolidColorBrush)item.Foreground).Color, ((SolidColorBrush)item.Background).Color) >= 4.5,
                        $"{theme} dropdown {index} item {itemIndex}: readable {(item.IsSelected ? "selected" : "normal")} text");
                }
                var bitmap = new RenderTargetBitmap((int)Math.Ceiling(surface.ActualWidth), (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(surface);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var stream = File.Create(Path.Combine(output, $"dropdown-{theme.ToString().ToLowerInvariant()}-{index}.png"))) encoder.Save(stream);
                // An already-open popup must also update when the theme changes.
                if (index == 3 && theme == ThemePreference.Dark)
                {
                    ThemeService.Current.ApplyTheme(ThemePreference.Light); Pump();
                    Check(((SolidColorBrush)surface.Background).Color == ((SolidColorBrush)Application.Current.FindResource("Brush.SurfaceRaised")).Color,
                        "open dropdown reacts to theme changes");
                    ThemeService.Current.ApplyTheme(theme); Pump();
                }
                combo.IsDropDownOpen = false; Pump();
            }
        }
        ThemeService.Current.ApplyTheme(ThemePreference.Dark); Pump();
    }
    private static void VerifyInputAlignment(MainWindow window, MainWindowViewModel model, string output)
    {
        model.NavigateTo(NavigationSection.Settings); Pump();
        var input = Descendants(window).OfType<TextBox>().Single(box =>
            box.GetBindingExpression(TextBox.TextProperty)?.ParentBinding.Path.Path == "SyncEntry");
        input.BringIntoView(); Pump();
        input.SetCurrentValue(TextBox.TextProperty, string.Empty);
        input.CaretIndex = 0; Pump();
        VerifyTextOrigin(input, "empty relay input");
        var beforeFocus = input.GetRectFromCharacterIndex(0);
        input.Focus(); Pump();
        Check(input.GetRectFromCharacterIndex(0) == beforeFocus, "focusing relay input does not shift content");
        input.SelectedText = "relay.example.invalid"; Pump();
        Check(input.Text == "relay.example.invalid" && Math.Abs(input.GetRectFromCharacterIndex(0).X - beforeFocus.X) <= 1,
            "typing starts at the same origin as the empty caret");
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(input.ActualWidth), (int)Math.Ceiling(input.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
            context.DrawRectangle(new VisualBrush(input) { Stretch = Stretch.Fill }, null,
                new Rect(0, 0, input.ActualWidth, input.ActualHeight));
        bitmap.Render(drawing);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var stream = File.Create(Path.Combine(output, "relay-input-aligned.png"))) encoder.Save(stream);
        input.SelectAll(); input.SelectedText = string.Empty; Pump();
        VerifyTextOrigin(input, "cleared relay input");
        ThemeService.Current.ApplyTheme(ThemePreference.Light); Pump();
        VerifyTextOrigin(input, "light relay input");
        model.NavigateTo(NavigationSection.Chat); Pump();
        var search = Descendants(window).OfType<TextBox>().Single(box =>
            box.GetBindingExpression(TextBox.TextProperty)?.ParentBinding.Path.Path == "SearchText");
        search.SetCurrentValue(TextBox.TextProperty, string.Empty); Pump();
        VerifyTextOrigin(search, "search input with icon padding");
        var composer = Descendants(window).OfType<TextBox>().Single(box => box.Name == "Composer");
        composer.SetCurrentValue(TextBox.TextProperty, string.Empty); Pump();
        VerifyTextOrigin(composer, "top-aligned multiline composer");
        ThemeService.Current.ApplyTheme(ThemePreference.Dark); Pump();
    }
    private static void VerifyTextOrigin(TextBox input, string label)
    {
        var watermark = (TextBlock)input.Template.FindName("Watermark", input);
        var host = (ScrollViewer)input.Template.FindName("PART_ContentHost", input);
        var caret = input.GetRectFromCharacterIndex(0);
        var hintOrigin = watermark.TransformToAncestor(input).Transform(new Point());
        hintOrigin.X += watermark.Padding.Left;
        Console.WriteLine($"Input geometry: caret={caret}; hint={hintOrigin}; host margin={host.Margin}; host padding={host.Padding}");
        Check(Math.Abs(caret.X - hintOrigin.X) <= 1, label + " caret aligns with placeholder start");
        Check(Math.Abs(caret.Y + caret.Height / 2 - hintOrigin.Y - watermark.ActualHeight / 2) <= 2,
            label + " caret and placeholder share vertical alignment");
    }
    private static double Contrast(Color foreground, Color background)
    {
        static double Channel(byte value) { var x = value / 255.0; return x <= 0.04045 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4); }
        static double Luminance(Color c) => 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
        var a = Luminance(foreground); var b = Luminance(background);
        return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static void Pump() => Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
    private static void Render(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path); encoder.Save(stream);
    }
    private static T? Find<T>(DependencyObject parent, Func<T, bool> predicate) where T : DependencyObject
    {
        if (parent is T match && predicate(match)) return match;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            if (Find(VisualTreeHelper.GetChild(parent, i), predicate) is { } child) return child;
        return null;
    }
    private sealed class BindingErrors : TraceListener
    {
        public List<string> Errors { get; } = new();
        public override void Write(string? message) { }
        public override void WriteLine(string? message) { if (message is not null) Errors.Add(message); }
    }
    private sealed class FakeWorkspace : IEnvelopeUiService
    {
        public event EventHandler<UiServiceStatusChangedEventArgs>? StatusChanged { add { } remove { } }
        public List<string> Reads { get; } = new();
        public UiWorkspaceSnapshot Snapshot { get; } = CreateSnapshot();
        public Task<UiWorkspaceSnapshot> LoadAsync(CancellationToken cancellationToken = default) => Task.FromResult(Snapshot);
        public Task<UiOperationResult> ExecuteAsync(UiOperationRequest request, CancellationToken cancellationToken = default)
        {
            if (request.Action == UiAction.MarkConversationRead) Reads.Add(request.ContextId!);
            return Task.FromResult(new UiOperationResult(true, "Shell.ServiceReady"));
        }
        private static UiWorkspaceSnapshot CreateSnapshot()
        {
            var now = new DateTimeOffset(2026, 9, 21, 14, 32, 0, TimeSpan.FromHours(8));
            var messages = new MessageUiModel[] {
                new("m1", MessageDirection.Incoming, "新版 Windows 客户端，就按即时通信的方式来做吧。", now.AddMinutes(-6), MessageDeliveryState.Delivered),
                new("m2", MessageDirection.Outgoing, "可以，打开就是最近会话，关闭窗口后继续在托盘接收消息。", now.AddMinutes(-4), MessageDeliveryState.Delivered),
                new("m3", MessageDirection.Incoming, "文件已收到，我看一下。", now.AddMinutes(-2), MessageDeliveryState.Delivered),
                new("m4", MessageDirection.Incoming, "", now, MessageDeliveryState.Delivered, "界面设计说明.pdf", 2516582, "C:\\UI-fixture-only.pdf") };
            var conversations = new ConversationUiModel[] {
                new("lin", "林晓", "文件已收到，我看一下。", now, false, true, 0, messages),
                new("group", "产品讨论组", "陈宁：这版界面更清楚了", now.AddMinutes(-4), true, false, 2, []),
                new("chen", "陈宁", "[文件] 交付清单.pdf", now.AddMinutes(-42), false, false, 1, []),
                new("design", "设计交流", "周五一起确认", now.AddDays(-1), true, false, 0, []),
                new("zhou", "周宇", "好的，明天见。", now.AddDays(-1), false, false, 0, []) };
            var contacts = conversations.Select(c => new ContactUiModel(c.Id, c.DisplayName, c.Preview, "demo-key", "仅用于界面验证的示例指纹", "", c.IsGroup, c.IsVerified, c.IsGroup ? 4 : 0, c.UnreadCount)).ToArray();
            return UiWorkspaceSnapshot.Empty with { Identity = new IdentityUiModel("Louis", "demo-key", "示例指纹", true), Contacts = contacts, Conversations = conversations, ServicesConnected = true };
        }
    }
}
