using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using Envelope.Windows.Core.Application;
using Envelope.Windows.Core.Diagnostics;
using Envelope.Windows.Core.Domain;
using Envelope.Windows.Core.Files;
using Envelope.Windows.Core.Models;
using Envelope.Windows.Core.Networking;
using Envelope.Windows.Core.Security;
using Envelope.Windows.Models;
using Microsoft.Win32;
using CoreDirection = Envelope.Windows.Core.Domain.MessageDirection;
using CoreDelivery = Envelope.Windows.Core.Domain.DeliveryState;

namespace Envelope.Windows.Services;

public sealed class EnvelopeUiService(
    EnvelopeClientEngine engine,
    EnvelopePaths paths,
    DiagnosticLogService diagnostics,
    ILocalUnlockGuard unlockGuard) : IEnvelopeUiService, IAsyncDisposable
{
    private const string RepositoryUrl = "https://github.com/louisir/envelope";
    private const string LicenseUrl = "https://www.gnu.org/licenses/agpl-3.0.html";
    private const int MessagePageSize = 100;
    private static readonly Lazy<string?> ExecutableFingerprintValue = new(ComputeExecutableFingerprint);
    private DateTimeOffset? _lastSyncAt;
    private IReadOnlyList<ContactUiModel> _lastContacts = [];
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _automationTask;
    private int _automationStarted;
    private int _engineSubscribed;
    private readonly ConcurrentDictionary<string, int> _messageWindowByConversation = new(StringComparer.Ordinal);

    public event EventHandler<UiServiceStatusChangedEventArgs>? StatusChanged;

    public async Task<UiWorkspaceSnapshot> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _engineSubscribed, 1) == 0)
            engine.StateChanged += OnEngineStateChanged;
        await engine.InitializeAsync(cancellationToken).ConfigureAwait(false);
        EnsureAutomationStarted();
        return await engine.ReadStateAsync(Snapshot, cancellationToken).ConfigureAwait(false);
    }

    public async Task<UiOperationResult> ExecuteAsync(UiOperationRequest request, CancellationToken cancellationToken = default)
    {
        try
        {
            if (RequiresSensitiveUnlock(request.Action))
            {
                var localLockEnabled = await engine.ReadStateAsync(
                    state => state.Settings.LocalLockEnabled,
                    cancellationToken).ConfigureAwait(false);
                await unlockGuard.RequireUnlockAsync(
                    localLockEnabled,
                    "验证当前 Windows 用户以继续 Envelope 敏感操作",
                    cancellationToken).ConfigureAwait(false);
            }

            object? data = null;
            switch (request.Action)
            {
                case UiAction.ShowContactQr:
                    OwnedIntroSession? ownedIntroSession = null;
                    IntroBundleSummary intro;
                    string introPayload;
                    string? introWarning = null;
                    try
                    {
                        ownedIntroSession = await engine.PublishIntroSessionAsync(
                            cancellationToken: cancellationToken).ConfigureAwait(false);
                        intro = ownedIntroSession.OwnerBundle;
                        introPayload = IntroPayloadCodec.Encode(
                            intro.BundleJson,
                            ownedIntroSession.SessionId,
                            ownedIntroSession.ServerUrl);
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    {
                        await engine.EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
                        intro = engine.CreateIntroBundle();
                        introPayload = IntroPayloadCodec.Encode(intro.BundleJson);
                        introWarning = $"双向互加通道暂不可用：{error.Message}\n该载荷仍可供对方单向添加。";
                    }
                    var acceptedResponder = Application.Current.Dispatcher.Invoke(() =>
                        DialogService.ShowIntroExchange(
                            introPayload,
                            intro,
                            ownedIntroSession is null
                                ? null
                                : token => engine.PollIntroSessionAsync(
                                    ownedIntroSession.SessionId,
                                    ownedIntroSession.ServerUrl,
                                    token),
                            introWarning));
                    if (acceptedResponder is not null)
                    {
                        var savedResponder = await engine.ImportHumanVerifiedContactAsync(
                            acceptedResponder.BundleJson,
                            cancellationToken: cancellationToken).ConfigureAwait(false);
                        Inform(
                            "已确认互加",
                            $"已保存 {savedResponder.DisplayLabel}\nFingerprint: {FormatFingerprint(savedResponder.KeyId)}");
                    }
                    break;
                case UiAction.ScanContactQr:
                case UiAction.PasteContact:
                    string contactText;
                    if (request.Action == UiAction.ScanContactQr)
                    {
                        var qrImagePath = PickFile(
                            "二维码图片 (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files (*.*)|*.*");
                        if (qrImagePath is null) return Cancelled();
                        contactText = await Task.Run(
                            () => QrCodeService.DecodeFile(qrImagePath),
                            cancellationToken).ConfigureAwait(false);
                    }
                    else
                    {
                        contactText = Application.Current.Dispatcher.Invoke(() =>
                            Clipboard.ContainsText() ? Clipboard.GetText().Trim() : string.Empty);
                        if (contactText.Length == 0)
                            throw new InvalidOperationException("剪贴板没有 Contact 或 IntroBundle 载荷。");
                    }
                    var decodedIntro = IntroPayloadCodec.Decode(contactText);
                    var preview = engine.PreviewContactImport(decodedIntro.BundleJson);
                    var mutualSessionNotice = decodedIntro.SessionId is { Length: > 0 }
                        ? $"\n互加服务：{decodedIntro.ServerUrl ?? "载荷未提供服务地址"}\n确认后将向该服务发送你的短期公开 IntroBundle。"
                        : string.Empty;
                    var fingerprintConfirmed = Application.Current.Dispatcher.Invoke(() => MessageBox.Show(
                        $"载荷签名有效，但签名不能证明现实身份。\n\n联系人：{preview.DisplayName}\nFingerprint：{FormatFingerprint(preview.KeyId)}" +
                        mutualSessionNotice +
                        "\n\n你是否已经通过可信通道核对该 fingerprint，并确认保存？",
                        "核对 fingerprint 后保存",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Warning)) == MessageBoxResult.Yes;
                    if (!fingerprintConfirmed) return Cancelled();
                    var contact = await engine.ImportHumanVerifiedContactAsync(
                        decodedIntro.BundleJson,
                        cancellationToken: cancellationToken).ConfigureAwait(false);
                    var mutualResult = string.Empty;
                    if (decodedIntro.SessionId is { Length: > 0 } sessionId)
                    {
                        if (decodedIntro.ServerUrl is not { Length: > 0 } introServerUrl)
                        {
                            mutualResult = "\n载荷缺少互加服务地址，未能向对方回传本机联系人。";
                        }
                        else
                        {
                            try
                            {
                                await engine.RespondIntroSessionAsync(
                                    sessionId,
                                    introServerUrl,
                                    cancellationToken: cancellationToken).ConfigureAwait(false);
                                mutualResult = "\n已向对方发送互加请求；对方核对后会保存你。";
                            }
                            catch (Exception error) when (error is not OperationCanceledException)
                            {
                                mutualResult = $"\n联系人已保存，但互加请求发送失败：{error.Message}";
                            }
                        }
                    }
                    Inform("联系人已保存", $"已人工确认 {contact.DisplayLabel}\nFingerprint: {FormatFingerprint(contact.KeyId)}{mutualResult}");
                    break;
                case UiAction.CreateGroup:
                    var groupInput = Application.Current.Dispatcher.Invoke(() => DialogService.CreateGroup(_lastContacts));
                    if (groupInput is null) return Cancelled();
                    await engine.CreateGroupAsync(groupInput.Name, groupInput.Policy, groupInput.ContactIds, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.ManageGroupMembers:
                    await ManageGroupAsync(request.ContextId ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.LeaveGroup:
                    if (!Confirm("退出群组", "退出后将向其他成员发送端到端群组控制事件。是否继续？")) return Cancelled();
                    await engine.LeaveOrDeclineGroupAsync(request.ContextId ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.AcceptGroupInvitation:
                    await engine.AcceptGroupInviteAsync(request.ContextId ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.DeclineGroupInvitation:
                    if (!Confirm("拒绝群邀请", "拒绝后会通知邀请者和群成员。是否继续？")) return Cancelled();
                    await engine.LeaveOrDeclineGroupAsync(request.ContextId ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.EditContact:
                    var current = await engine.ReadStateAsync(
                        state => state.RequireContact(request.ContextId ?? string.Empty),
                        cancellationToken).ConfigureAwait(false);
                    var remark = Application.Current.Dispatcher.Invoke(() => DialogService.Prompt("联系人备注", "输入备注：", current.Remark ?? string.Empty));
                    if (remark is null) return Cancelled();
                    await engine.UpdateContactRemarkAsync(current.KeyId, remark, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.DeleteContact:
                    if (!Confirm("删除联系人", "将删除联系人，并尽力发送端到端删除通知。是否继续？")) return Cancelled();
                    await engine.DeleteContactAsync(request.ContextId ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.SendMessage:
                    var sendToGroup = await engine.ReadStateAsync(
                        state => state.Groups.Any(item => item.GroupId == request.ContextId),
                        cancellationToken).ConfigureAwait(false);
                    if (sendToGroup)
                        data = await engine.SendGroupTextAsync(request.ContextId!, request.Text ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    else
                        data = await engine.SendTextAsync(request.ContextId ?? string.Empty, request.Text ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.AttachFile:
                    var attachment = PickFile("All files (*.*)|*.*");
                    if (attachment is null) return Cancelled();
                    var attachToGroup = await engine.ReadStateAsync(
                        state => state.Groups.Any(item => item.GroupId == request.ContextId),
                        cancellationToken).ConfigureAwait(false);
                    if (attachToGroup)
                        data = await engine.SendGroupFileAsync(request.ContextId!, attachment, cancellationToken: cancellationToken).ConfigureAwait(false);
                    else
                        data = await engine.SendFileAsync(request.ContextId ?? string.Empty, attachment, cancellationToken: cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.OpenAttachment:
                    OpenAttachment(request.Text);
                    break;
                case UiAction.DeleteLocalMessage:
                    if (!Confirm("删除本机消息", "只从这台电脑删除该聊天条目；不会删除对方设备上的内容。是否继续？")) return Cancelled();
                    data = await engine.DeleteLocalMessagesAsync(
                        [request.ContextId ?? string.Empty],
                        cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.DeleteSelectedMessages:
                    var selectedMessageIds = (request.Text ?? string.Empty)
                        .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Distinct(StringComparer.Ordinal)
                        .ToArray();
                    if (selectedMessageIds.Length == 0) return Cancelled();
                    if (!Confirm("批量删除本机消息", $"只从这台电脑删除所选 {selectedMessageIds.Length} 条聊天记录；不会删除对方设备上的内容。是否继续？")) return Cancelled();
                    data = await engine.DeleteLocalMessagesAsync(
                        selectedMessageIds,
                        cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.LoadEarlierMessages:
                    if (string.IsNullOrWhiteSpace(request.ContextId)) return Cancelled();
                    data = _messageWindowByConversation.AddOrUpdate(
                        request.ContextId,
                        MessagePageSize * 2,
                        (_, current) => checked(current + MessagePageSize));
                    break;
                case UiAction.MarkConversationRead:
                    if (string.IsNullOrWhiteSpace(request.ContextId)) return Cancelled();
                    data = await engine.MarkConversationReadAsync(
                        request.ContextId,
                        cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.SealOfflineEnvelope:
                    var sealForGroup = await engine.ReadStateAsync(
                        state => state.Groups.Any(item => item.GroupId == request.ContextId),
                        cancellationToken).ConfigureAwait(false);
                    var choice = Application.Current.Dispatcher.Invoke(() => MessageBox.Show("选择“是”密封文本，选择“否”密封文件。", "离线密封", MessageBoxButton.YesNoCancel, MessageBoxImage.Question));
                    if (choice == MessageBoxResult.Cancel) return Cancelled();
                    if (choice == MessageBoxResult.Yes)
                    {
                        var sealText = Application.Current.Dispatcher.Invoke(() => DialogService.Prompt(
                            "密封文本",
                            sealForGroup
                                ? "输入群组离线文本；文件会为每位当前可投递成员分别加密："
                                : "输入只供该联系人解密的文本：",
                            multiline: true));
                        if (sealText is null) return Cancelled();
                        data = sealForGroup
                            ? await engine.SealGroupTextAsync(request.ContextId!, sealText, cancellationToken).ConfigureAwait(false)
                            : await engine.SealTextAsync(request.ContextId ?? string.Empty, sealText, cancellationToken).ConfigureAwait(false);
                    }
                    else
                    {
                        var sealFile = PickFile("All files (*.*)|*.*");
                        if (sealFile is null) return Cancelled();
                        data = sealForGroup
                            ? await engine.SealGroupFileAsync(request.ContextId!, sealFile, cancellationToken: cancellationToken).ConfigureAwait(false)
                            : await engine.SealFileAsync(request.ContextId ?? string.Empty, sealFile, cancellationToken: cancellationToken).ConfigureAwait(false);
                    }
                    Inform("离线密封完成", $"密封文件已写入：\n{data}");
                    break;
                case UiAction.ImportEnvelopeFile:
                    data = PickFile("Envelope files (*.envelope;*.json)|*.envelope;*.json|All files (*.*)|*.*");
                    return new UiOperationResult(data is not null, "Shell.ServiceReady", data);
                case UiAction.ImportEnvelopePath:
                    data = await engine.OpenOfflineEnvelopeFileAsync(request.Text ?? string.Empty, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.PasteEnvelope:
                    data = Application.Current.Dispatcher.Invoke(() => Clipboard.ContainsText() ? Clipboard.GetText() : string.Empty);
                    return new UiOperationResult(true, "Shell.ServiceReady", data);
                case UiAction.UnsealEnvelopeText:
                    data = await engine.ImportEnvelopeAsync(request.Text ?? string.Empty, cancellationToken: cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.CreateIdentity:
                    var created = await engine.CreateIdentityAsync(request.Text ?? "Envelope User", cancellationToken).ConfigureAwait(false);
                    Application.Current.Dispatcher.Invoke(() => DialogService.ShowProtectedText(
                        "24 词恢复词", "这是恢复身份的唯一凭据。请离线抄写；窗口会在 2 分钟后自动关闭，关闭时会清空仍由它写入的剪贴板内容。", created.RecoveryPhrase.Value));
                    data = created;
                    break;
                case UiAction.RecoverIdentity:
                    if (!Confirm("恢复身份", "这会替换当前身份、联系人、群组、消息和缓存。是否继续？")) return Cancelled();
                    var currentDisplayName = await engine.ReadStateAsync(
                        state => state.Identity?.DisplayName,
                        cancellationToken).ConfigureAwait(false);
                    var displayName = request.Options?.GetValueOrDefault("display_name") ?? currentDisplayName ?? "Envelope User";
                    data = await engine.RestoreIdentityAsync(displayName, request.Text ?? string.Empty, true, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.ClearIdentity:
                    if (!Confirm("清空本机身份", "该操作不可撤销。请确认已安全保存恢复词和备份。")) return Cancelled();
                    await engine.ClearIdentityAsync(cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.CopyKeyId:
                    if (!string.IsNullOrWhiteSpace(request.Text)) Application.Current.Dispatcher.Invoke(() => Clipboard.SetText(request.Text));
                    break;
                case UiAction.ExportBackup:
                    data = await engine.ExportLocalBackupAsync(cancellationToken).ConfigureAwait(false);
                    Inform("本地备份完成", $"身份自加密备份已写入：\n{data}");
                    break;
                case UiAction.RestoreBackup:
                    var backupFile = PickFile("Envelope backup (*.json)|*.json|All files (*.*)|*.*");
                    if (backupFile is null) return Cancelled();
                    if (!Confirm(
                            "恢复本地备份",
                            $"这会替换当前身份、联系人、群组、消息和受管文件缓存。\n\n备份：{backupFile}\n\n是否继续？"))
                        return Cancelled();
                    await engine.RestoreLocalBackupAsync(request.Text ?? string.Empty, backupFile, cancellationToken).ConfigureAwait(false);
                    Inform("本地备份已恢复", "身份、联系人、群组和本机设置已恢复；聊天记录和文件缓存未从备份导入。");
                    break;
                case UiAction.SaveSyncEntry:
                    var currentSettings = await engine.ReadStateAsync(
                        state => state.Settings,
                        cancellationToken).ConfigureAwait(false);
                    var settings = BuildSettings(request, currentSettings);
                    if (settings.LocalLockEnabled != currentSettings.LocalLockEnabled)
                    {
                        await unlockGuard.RequireUnlockAsync(
                            true,
                            settings.LocalLockEnabled
                                ? "验证 Windows Hello 后启用 Envelope 本地锁"
                                : "验证 Windows Hello 后关闭 Envelope 本地锁",
                            cancellationToken).ConfigureAwait(false);
                    }
                    await engine.UpdateSettingsAsync(settings, cancellationToken).ConfigureAwait(false);
                    break;
                case UiAction.SyncNow:
                    try
                    {
                        data = await engine.SynchronizeAsync(cancellationToken).ConfigureAwait(false);
                    }
                    catch (Exception syncError) when (syncError is not OperationCanceledException)
                    {
                        var retriedWithoutSync = await engine.RetryPendingAsync(cancellationToken)
                            .ConfigureAwait(false);
                        throw new InvalidOperationException(
                            $"同步服务操作失败；仍已独立重试 {retriedWithoutSync} 个本机 pending 信封。{syncError.Message}",
                            syncError);
                    }
                    var retried = await engine.RetryPendingAsync(cancellationToken).ConfigureAwait(false);
                    _lastSyncAt = DateTimeOffset.Now;
                    if (data is MailboxSyncResult sync)
                        Inform("消息同步完成", $"拉取 {sync.Pulled}，导入 {sync.Imported}，重复 {sync.Duplicates}，隔离 {sync.Quarantined}，ACK {sync.Acknowledged}，送达更新 {sync.DeliveredUpdated}，pending 重试成功 {retried}。");
                    break;
                case UiAction.ClearFileCache:
                    data = await engine.ClearFileCacheAsync(cancellationToken).ConfigureAwait(false);
                    Inform("文件缓存已清理", $"已删除 {data} 个 received / sealed / transfer 缓存文件。");
                    break;
                case UiAction.ExportDiagnostics:
                    data = diagnostics.ExportTo(paths.DiagnosticsExport);
                    Inform("诊断日志已导出", $"导出目录：\n{data}");
                    break;
                case UiAction.ClearDiagnostics:
                    diagnostics.Clear();
                    break;
                case UiAction.OpenUserManual:
                    OpenManual();
                    break;
                case UiAction.OpenSourceRepository:
                    OpenUrl(RepositoryUrl);
                    break;
                case UiAction.OpenLicense:
                    OpenUrl(LicenseUrl);
                    break;
            }
            StatusChanged?.Invoke(this, new UiServiceStatusChangedEventArgs("Shell.ServiceReady"));
            return new UiOperationResult(true, "Shell.ServiceReady", data);
        }
        catch (Exception error)
        {
            Application.Current.Dispatcher.Invoke(() => MessageBox.Show(error.Message, "Envelope", MessageBoxButton.OK, MessageBoxImage.Error));
            StatusChanged?.Invoke(this, new UiServiceStatusChangedEventArgs("Shell.ServiceReady"));
            return new UiOperationResult(false, "Shell.ServiceReady", error);
        }
    }

    private UiWorkspaceSnapshot Snapshot(WindowsClientState state)
    {
        var identity = state.Identity is null ? null : new IdentityUiModel(
            state.Identity.DisplayName, state.Identity.KeyId, FormatFingerprint(state.Identity.KeyId), true);
        var unreadByConversation = state.Messages
            .Where(message =>
                message.Direction == CoreDirection.Incoming &&
                !message.IsHidden &&
                !message.IsRead)
            .GroupBy(message => message.ConversationId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var contacts = state.Contacts.Select(item => new ContactUiModel(
            item.KeyId, item.DisplayLabel, item.DisplayName, item.KeyId, FormatFingerprint(item.KeyId), item.Remark ?? string.Empty,
            false, item.HumanVerified, 0,
            unreadByConversation.GetValueOrDefault(item.KeyId))).ToList();
        contacts.AddRange(state.Groups.Where(item => item.IsActive).Select(group => new ContactUiModel(
            group.GroupId, group.Name, group.Policy.ToString(), group.GroupId, group.GroupId, string.Empty,
            true, group.Policy != GroupPolicy.Normal,
            state.GroupMembers.Count(item => item.GroupId == group.GroupId && item.Status == GroupMemberStatus.Active),
            unreadByConversation.GetValueOrDefault(group.GroupId))));
        _lastContacts = contacts;

        var pendingInvitations = state.Groups
            .Where(group => group.IsActive)
            .Select(group => new
            {
                Group = group,
                Self = state.GroupMembers.FirstOrDefault(member =>
                    member.GroupId == group.GroupId && member.KeyId == state.Identity?.KeyId),
            })
            .Where(item => item.Self?.Status == GroupMemberStatus.Pending &&
                           !string.IsNullOrWhiteSpace(item.Self.InvitedByKeyId))
            .ToDictionary(
                item => item.Group.GroupId,
                item => item.Group,
                StringComparer.Ordinal);

        var conversations = contacts.Select(item =>
        {
            var allMessages = state.Messages
                .Where(message => message.ConversationId == item.Id && !message.IsHidden)
                .OrderBy(message => message.CreatedAtUnixMs)
                .ToArray();
            var messageWindow = Math.Max(
                MessagePageSize,
                _messageWindowByConversation.GetOrAdd(item.Id, MessagePageSize));
            var messages = allMessages
                .Skip(Math.Max(0, allMessages.Length - messageWindow))
                .Select(ToUiMessage)
                .ToArray();
            var last = messages.LastOrDefault();
            pendingInvitations.TryGetValue(item.Id, out var pendingGroup);
            return new ConversationUiModel(item.Id, item.DisplayName, last?.Text ?? item.Subtitle,
                last?.Timestamp, item.IsGroup, item.IsVerified, item.UnreadCount, messages,
                pendingGroup is not null, pendingGroup?.GroupId, pendingGroup?.Name,
                allMessages.Length > messages.Length, allMessages.Length);
        }).OrderByDescending(item => item.LastActivity).ToArray();
        var recent = state.Messages.Where(item => item.Direction == CoreDirection.Incoming && !item.IsHidden)
            .OrderByDescending(item => item.CreatedAtUnixMs).Take(20)
            .Select(item => new RecentEnvelopeUiModel(item.EnvelopeId, item.PeerDisplayName, item.Text, item.CreatedAt, true)).ToArray();
        var settings = state.Settings;
        return new UiWorkspaceSnapshot(identity, contacts, conversations, recent,
            new SettingsUiModel(settings.LocalLockEnabled, settings.AutoBackupIntervalHours > 0,
                settings.AutoSyncEnabled,
                settings.AutoBackupIntervalHours > 0 ? $"{settings.AutoBackupIntervalHours}h" : "Off",
                settings.AutoBackupRetentionCount.ToString(), settings.SyncServiceUrl,
                _lastSyncAt, settings.AutoBackupLastAtUnixMs is > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(settings.AutoBackupLastAtUnixMs.Value) : null),
            ExecutableFingerprint(), true);
    }

    private static MessageUiModel ToUiMessage(ChatMessageRecord item) => new(
        item.EnvelopeId,
        item.Direction == CoreDirection.Outgoing ? Models.MessageDirection.Outgoing : Models.MessageDirection.Incoming,
        item.Text,
        item.CreatedAt,
        item.DeliveryState switch
        {
            CoreDelivery.Delivered => MessageDeliveryState.Delivered,
            CoreDelivery.Sent or CoreDelivery.ServerMailbox or CoreDelivery.Received => MessageDeliveryState.Sent,
            CoreDelivery.Failed => MessageDeliveryState.Failed,
            _ => MessageDeliveryState.Pending,
        },
        item.AttachmentFileName,
        item.AttachmentPath is { Length: > 0 } path && File.Exists(path) ? new FileInfo(path).Length : null,
        item.AttachmentPath);

    private static SecureStoreSettings BuildSettings(
        UiOperationRequest request,
        SecureStoreSettings currentSettings)
    {
        var options = request.Options ?? new Dictionary<string, string>();
        var hoursText = options.GetValueOrDefault("backup_interval") ?? "24";
        var retentionText = options.GetValueOrDefault("backup_retention") ?? "7";
        var hours = int.TryParse(new string(hoursText.Where(char.IsDigit).ToArray()), out var parsedHours) ? parsedHours : 24;
        var retention = int.TryParse(new string(retentionText.Where(char.IsDigit).ToArray()), out var parsedRetention) ? parsedRetention : 7;
        var enabled = bool.TryParse(options.GetValueOrDefault("auto_backup"), out var auto) && auto;
        return currentSettings with
        {
            SyncServiceUrl = NormalizeServerUrl(request.Text ?? string.Empty),
            AutoBackupIntervalHours = enabled ? Math.Max(1, hours) : 0,
            AutoBackupRetentionCount = Math.Max(1, retention),
            LocalLockEnabled = bool.TryParse(options.GetValueOrDefault("local_lock"), out var locked) && locked,
            AutoSyncEnabled = !bool.TryParse(options.GetValueOrDefault("auto_sync"), out var autoSync) || autoSync,
        };
    }

    private async Task ManageGroupAsync(string groupId, CancellationToken cancellationToken)
    {
        while (true)
        {
            var view = await engine.ReadStateAsync(state =>
            {
                var group = state.RequireGroup(groupId);
                var members = state.GroupMembers.Where(item => item.GroupId == groupId).ToArray();
                var contacts = state.Contacts.Select(item => new ContactUiModel(
                    item.KeyId,
                    item.DisplayLabel,
                    item.DisplayName,
                    item.KeyId,
                    FormatFingerprint(item.KeyId),
                    item.Remark ?? string.Empty,
                    false,
                    item.HumanVerified,
                    0,
                    0)).ToArray();
                return (Group: group, Members: members, Contacts: contacts, SelfKeyId: state.Identity?.KeyId ?? string.Empty);
            }, cancellationToken).ConfigureAwait(false);

            var action = Application.Current.Dispatcher.Invoke(() =>
                DialogService.ManageGroup(view.Group, view.Members, view.SelfKeyId));
            if (action is null) return;

            switch (action.Action)
            {
                case GroupManagementAction.Rename:
                    var name = Application.Current.Dispatcher.Invoke(() =>
                        DialogService.Prompt("修改群名称", "输入新的群名称：", view.Group.Name));
                    if (name is not null)
                        await engine.RenameGroupAsync(groupId, name, cancellationToken).ConfigureAwait(false);
                    break;
                case GroupManagementAction.UpdateAvatar:
                    var seed = Application.Current.Dispatcher.Invoke(() =>
                        DialogService.Prompt("更新群头像 seed", "输入新的头像 seed：", view.Group.AvatarSeed));
                    if (seed is not null)
                        await engine.UpdateGroupAvatarAsync(groupId, seed, cancellationToken).ConfigureAwait(false);
                    break;
                case GroupManagementAction.Invite:
                    var existingKeys = view.Members.Select(item => item.KeyId).ToHashSet(StringComparer.Ordinal);
                    var invitees = Application.Current.Dispatcher.Invoke(() =>
                        DialogService.SelectGroupInvitees(view.Contacts, existingKeys));
                    if (invitees is not null)
                        await engine.InviteGroupMembersAsync(groupId, invitees, cancellationToken).ConfigureAwait(false);
                    break;
                case GroupManagementAction.Remove:
                    if (string.IsNullOrWhiteSpace(action.MemberKeyId)) break;
                    if (Confirm("移除群成员", $"将成员 {FormatFingerprint(action.MemberKeyId)} 移出群组。是否继续？"))
                        await engine.RemoveGroupMemberAsync(groupId, action.MemberKeyId, cancellationToken).ConfigureAwait(false);
                    break;
                case GroupManagementAction.Endorse:
                    if (string.IsNullOrWhiteSpace(action.MemberKeyId)) break;
                    if (Confirm("共识背书", $"请先核对 fingerprint：\n{FormatFingerprint(action.MemberKeyId)}\n\n确认背书该候选成员？"))
                        await engine.EndorseGroupMemberAsync(groupId, action.MemberKeyId, cancellationToken).ConfigureAwait(false);
                    break;
                case GroupManagementAction.SetLocalTrust:
                    if (string.IsNullOrWhiteSpace(action.MemberKeyId) || action.Trusted is null) break;
                    var trustAction = action.Trusted.Value ? "信任" : "取消信任";
                    if (Confirm(
                            $"{trustAction}群成员 fingerprint",
                            $"Fingerprint：\n{FormatFingerprint(action.MemberKeyId)}\n\n" +
                            $"确认只在这台电脑上{trustAction}该成员？此设置不会由远端成员替你更改。"))
                    {
                        await engine.SetGroupMemberLocalTrustAsync(
                            groupId,
                            action.MemberKeyId,
                            action.Trusted.Value,
                            cancellationToken).ConfigureAwait(false);
                    }
                    break;
            }
        }
    }

    private void EnsureAutomationStarted()
    {
        if (Interlocked.Exchange(ref _automationStarted, 1) != 0) return;
        _automationTask = Task.Run(() => AutomationLoopAsync(_lifetime.Token));
    }

    private void OnEngineStateChanged(object? sender, EventArgs e) =>
        StatusChanged?.Invoke(this, new UiServiceStatusChangedEventArgs("Shell.ServiceReady"));

    private async Task AutomationLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await RunAutomationCycleAsync(cancellationToken).ConfigureAwait(false);
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    await WriteAutomationWarningAsync(
                        "windows_automation_cycle_failed",
                        error,
                        cancellationToken).ConfigureAwait(false);
                }
                await Task.Delay(TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task RunAutomationCycleAsync(CancellationToken cancellationToken)
    {
        var initial = await engine.ReadStateAsync(
            state => (HasIdentity: state.Identity is not null, Settings: state.Settings),
            cancellationToken).ConfigureAwait(false);
        if (!initial.HasIdentity) return;
        var settings = initial.Settings;
        var changed = false;

        var p2pStatus = engine.P2pStatus;
        if (p2pStatus is null || p2pStatus.ShouldRefreshAt(
                DateTimeOffset.UtcNow,
                EnvelopeP2pTransport.DefaultTicketRefreshBefore))
        {
            await engine.EnsureP2pListeningAsync(cancellationToken).ConfigureAwait(false);
            changed = true;
        }

        if (settings.AutoBackupIntervalHours > 0)
        {
            var lastBackup = settings.AutoBackupLastAtUnixMs is > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds(settings.AutoBackupLastAtUnixMs.Value)
                : (DateTimeOffset?)null;
            if (lastBackup is null || DateTimeOffset.UtcNow - lastBackup.Value >=
                TimeSpan.FromHours(settings.AutoBackupIntervalHours))
            {
                try
                {
                    await engine.ExportLocalBackupAsync(cancellationToken).ConfigureAwait(false);
                    changed = true;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    await WriteAutomationWarningAsync(
                        "windows_auto_backup_failed",
                        error,
                        cancellationToken).ConfigureAwait(false);
                }
            }
        }

        settings = await engine.ReadStateAsync(
            state => state.Settings,
            cancellationToken).ConfigureAwait(false);
        try
        {
            var retried = await engine.RetryPendingAsync(cancellationToken).ConfigureAwait(false);
            changed |= retried > 0;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            await WriteAutomationWarningAsync(
                "windows_pending_retry_failed",
                error,
                cancellationToken).ConfigureAwait(false);
        }
        if (settings.AutoSyncEnabled && !string.IsNullOrWhiteSpace(settings.SyncServiceUrl))
        {
            try
            {
                await engine.SynchronizeAsync(cancellationToken).ConfigureAwait(false);
                _lastSyncAt = DateTimeOffset.Now;
                changed = true;
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                await WriteAutomationWarningAsync(
                    "windows_auto_sync_failed",
                    error,
                    cancellationToken).ConfigureAwait(false);
            }
        }

        if (changed)
            StatusChanged?.Invoke(this, new UiServiceStatusChangedEventArgs("Shell.ServiceReady"));
    }

    private async Task WriteAutomationWarningAsync(
        string eventName,
        Exception error,
        CancellationToken cancellationToken)
    {
        try
        {
            await diagnostics.WriteAsync(
                "warn",
                eventName,
                new Dictionary<string, object?> { ["error"] = error.Message },
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // A read-only or full diagnostics volume must not permanently stop
            // automatic backup and synchronization attempts.
        }
    }

    private static bool RequiresSensitiveUnlock(UiAction action) => action is
        UiAction.RecoverIdentity or
        UiAction.ClearIdentity or
        UiAction.ExportBackup or
        UiAction.RestoreBackup or
        UiAction.ClearFileCache or
        UiAction.ClearDiagnostics;

    private static string NormalizeServerUrl(string value)
    {
        var text = value.Trim();
        if (text.Length == 0) return string.Empty;
        if (!text.Contains("://", StringComparison.Ordinal)) text = "https://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            throw new FormatException("同步服务入口必须是 HTTP/HTTPS 域名或 IP。");
        return uri.ToString().TrimEnd('/') + "/";
    }

    private static string? PickFile(string filter) => Application.Current.Dispatcher.Invoke(() =>
    {
        var dialog = new OpenFileDialog { Filter = filter, CheckFileExists = true, Multiselect = false };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    });

    private static bool Confirm(string title, string text) => Application.Current.Dispatcher.Invoke(() =>
        MessageBox.Show(text, title, MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes);

    private static void Inform(string title, string text) => Application.Current.Dispatcher.Invoke(() =>
        MessageBox.Show(text, title, MessageBoxButton.OK, MessageBoxImage.Information));

    private static void OpenAttachment(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            throw new FileNotFoundException("附件文件不存在或已从缓存中清除。", path);
        Process.Start(new ProcessStartInfo(Path.GetFullPath(path)) { UseShellExecute = true });
    }

    private static UiOperationResult Cancelled() => new(false, "Shell.ServiceReady");
    private static string FormatFingerprint(string keyId) => string.Join(' ', Enumerable.Range(0, (keyId.Length + 3) / 4).Select(index => keyId.Substring(index * 4, Math.Min(4, keyId.Length - index * 4))));
    private static string? ExecutableFingerprint() => ExecutableFingerprintValue.Value;

    private static string? ComputeExecutableFingerprint()
    {
        var path = Environment.ProcessPath ?? Assembly.GetEntryAssembly()?.Location;
        return path is { Length: > 0 } && File.Exists(path) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant() : null;
    }
    private static void OpenManual()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "windows-user-manual.html"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "docs", "windows-user-manual.html")),
        };
        var path = candidates.FirstOrDefault(File.Exists);
        if (path is not null) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        else OpenUrl(RepositoryUrl + "/blob/master/docs/windows-user-manual.html");
    }
    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _engineSubscribed, 0) != 0)
            engine.StateChanged -= OnEngineStateChanged;
        _lifetime.Cancel();
        if (_automationTask is not null)
        {
            try { await _automationTask.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _lifetime.Dispose();
        await engine.DisposeAsync().ConfigureAwait(false);
    }
}
