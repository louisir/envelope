import 'package:flutter/widgets.dart';

class EnvelopeLocalizations {
  const EnvelopeLocalizations(this.locale);

  final Locale locale;

  static const LocalizationsDelegate<EnvelopeLocalizations> delegate =
      _EnvelopeLocalizationsDelegate();

  static const supportedLocales = <Locale>[Locale('en'), Locale('zh')];

  static EnvelopeLocalizations of(BuildContext context) {
    return Localizations.of<EnvelopeLocalizations>(
          context,
          EnvelopeLocalizations,
        ) ??
        const EnvelopeLocalizations(Locale('zh'));
  }

  bool get _zh => locale.languageCode.toLowerCase() == 'zh';

  String get appTitle => 'Envelope';
  String get contactsTab => _zh ? '联系人' : 'Contacts';
  String get chatTab => _zh ? '聊天' : 'Chats';
  String get unsealTab => _zh ? '拆封' : 'Open';
  String get settingsTab => _zh ? '设置' : 'Settings';
  String get contactsTitle => contactsTab;
  String contactsSummary(int contactCount, int groupCount) => _zh
      ? '$contactCount 位联系人 / $groupCount 个群组'
      : '$contactCount contacts / $groupCount groups';
  String get addContact => _zh ? '加好友' : 'Add contact';
  String get showQr => _zh ? '出示二维码' : 'Show QR';
  String get scanQr => _zh ? '扫描二维码' : 'Scan QR';
  String get paste => _zh ? '粘贴' : 'Paste';
  String get pasteContact => _zh ? '粘贴 contact' : 'Paste contact';
  String get allConversations => _zh ? '全部' : 'All';
  String get directChats => _zh ? '联系人' : 'Direct';
  String get groupChats => _zh ? '群聊' : 'Groups';
  String get noDirectChatsTitle => _zh ? '还没有点对点联系人' : 'No direct chats';
  String get noGroupChatsTitle => _zh ? '还没有群聊' : 'No group chats';
  String get createGroup => _zh ? '创建群组' : 'Create group';
  String get create => _zh ? '创建' : 'Create';
  String get groupName => _zh ? '群名称' : 'Group name';
  String get groupInviteesMinimumHint => _zh
      ? '至少选择 2 位联系人，群组总人数不能少于 3 人。'
      : 'Select at least 2 contacts; a group needs at least 3 people.';
  String get normalGroupShort => _zh ? '普通' : 'Normal';
  String get verifiedGroupShort => _zh ? '验证' : 'Verified';
  String get consensusGroupShort => _zh ? '共识' : 'Consensus';
  String get noContactsTitle => _zh ? '还没有联系人' : 'No contacts yet';
  String get noContactsMessage => _zh
      ? '出示二维码、扫描二维码，或粘贴 contact 添加好友。'
      : 'Show a QR code, scan one, or paste a contact to add someone.';
  String get groupCountLabel => _zh ? '群组' : 'Groups';
  String get memberCountLabel => _zh ? '成员' : 'members';
  String groupMembersSummary(int count, String policyLabel) =>
      _zh ? '$count 位成员 / $policyLabel' : '$count members / $policyLabel';
  String get normalGroup => _zh ? '普通群' : 'Normal group';
  String get verifiedGroup => _zh ? '验证群' : 'Verified group';
  String get consensusGroup => _zh ? '共识群' : 'Consensus group';
  String get unnamedGroup => _zh ? '未命名群组' : 'Untitled group';

  String get chatTitle => chatTab;
  String get chooseConversationTitle =>
      _zh ? '请选择联系人或群组' : 'Choose a contact or group';
  String get chooseConversationMessage => _zh
      ? '从联系人列表中选择一个联系人或群组开始会话。'
      : 'Select a contact or group to start a conversation.';
  String get messageContent => _zh ? '消息内容' : 'Message';
  String get messageHint =>
      _zh ? '输入要发送的端到端加密消息' : 'Type an end-to-end encrypted message';
  String get send => _zh ? '发送' : 'Send';
  String get addFile => _zh ? '添加文件' : 'Attach file';
  String get groupMembers => _zh ? '群组成员' : 'Group members';
  String get selectAll => _zh ? '全选' : 'Select all';
  String get selectAllMessages => _zh ? '全选消息' : 'Select all messages';
  String get delete => _zh ? '删除' : 'Delete';
  String get deleteContact => _zh ? '删除联系人' : 'Delete contact';
  String get deleteContactTitle => deleteContact;
  String deleteContactMessage(String name) => _zh
      ? '将删除联系人“$name”，并向对方发送自动删除通知。聊天记录不会删除。'
      : 'Delete "$name" from contacts and send an automatic delete notice to the peer. Chat history is kept.';
  String get deleteSelectedMessages =>
      _zh ? '删除选中聊天记录' : 'Delete selected messages';
  String get exitSelection => _zh ? '退出选择' : 'Exit selection';
  String selectedMessages(int count) => _zh ? '已选 $count 条' : '$count selected';
  String get identityReady => _zh ? '身份已就绪' : 'Identity ready';
  String get identityNotInitialized =>
      _zh ? '身份未初始化' : 'Identity not initialized';
  String get seal => _zh ? '密封' : 'Seal';
  String get noMessagesTitle => _zh ? '还没有消息' : 'No messages yet';
  String firstContactMessage(String name) =>
      _zh ? '给 $name 发送第一条消息。' : 'Send the first message to $name.';
  String firstGroupMessage(String name) =>
      _zh ? '给 $name 发送第一条群消息。' : 'Send the first group message to $name.';
  String get loadEarlier => _zh ? '加载更早消息' : 'Load earlier';
  String get loadingEarlier => _zh ? '正在加载...' : 'Loading...';
  String get openContacts => _zh ? '打开联系人' : 'Open contacts';
  String get groupInviteTitle => _zh ? '群邀请' : 'Group invitation';
  String groupInviteMessage(String name, String policyLabel) => _zh
      ? '邀请你加入 $name（$policyLabel）'
      : 'Invitation to join $name ($policyLabel)';
  String get acceptGroupInvite => _zh ? '接受' : 'Accept';
  String get declineGroupInvite => _zh ? '拒绝' : 'Decline';
  String get groupInviteBusy => _zh ? '正在处理群邀请...' : 'Processing invitation...';
  String get groupInviteExpired => _zh ? '群邀请已失效' : 'Invitation expired';
  String get groupInviteHandled => _zh ? '群邀请已处理' : 'Invitation handled';

  String get unsealTitle => unsealTab;
  String get unsealSubtitle => _zh
      ? '导入第三方收到的离线信封文件。'
      : 'Open offline envelope files received elsewhere.';
  String get importEnvelopeFile => _zh ? '从文件导入离线信封' : 'Import envelope file';
  String get importEnvelopeClipboard =>
      _zh ? '从剪贴板导入离线信封' : 'Import from clipboard';
  String get envelopeBase64 =>
      _zh ? '收到的离线信封 base64' : 'Received envelope base64';
  String get envelopeBase64Hint =>
      _zh ? '粘贴收到的离线信封 base64' : 'Paste received envelope base64';
  String get decryptImport => _zh ? '解密导入' : 'Decrypt and import';

  String get settingsTitle => settingsTab;
  String get identitySection => _zh ? '我的身份' : 'My identity';
  String get displayName => _zh ? '显示名' : 'Display name';
  String get defaultDisplayName => _zh ? 'Envelope User' : 'Envelope User';
  String get identityMissing => _zh ? '尚未保存本机身份' : 'No local identity saved';
  String get recoveryPhraseLabel =>
      _zh ? 'BIP39 24 词恢复词' : 'BIP39 24-word recovery phrase';
  String get recoveryPhraseHint => _zh
      ? '输入 24 个恢复词，或点击生成恢复词'
      : 'Enter 24 words, or generate a recovery phrase';
  String nativeCoreMissing(String? error) => _zh
      ? (error == null ? 'Rust native core 未加载' : 'Rust native core 未加载：$error')
      : (error == null
            ? 'Rust native core not loaded'
            : 'Rust native core not loaded: $error');
  String get createSaveIdentity => _zh ? '创建身份' : 'Create identity';
  String get saveRecoveredIdentity =>
      _zh ? '从恢复词恢复身份' : 'Recover identity from phrase';
  String get replaceIdentityFromRecoveryPhrase =>
      _zh ? '从恢复词替换本机身份' : 'Replace identity from recovery phrase';
  String get replaceIdentityTitle =>
      _zh ? '替换本机身份？' : 'Replace local identity?';
  String get replaceIdentityMessage => _zh
      ? '这会清除当前本机身份，以及本机联系人、消息、群组和密封历史。恢复词会先校验，校验成功后才开始替换。'
      : 'This clears the current local identity, contacts, messages, groups, and sealed history. The recovery phrase is checked before replacement starts.';
  String get replaceIdentityConfirm => _zh ? '确认替换' : 'Replace';
  String get identityAlreadySaved => _zh
      ? '本机已有身份。如需更换，请从恢复词替换或先清除当前身份。'
      : 'This device already has an identity. To change it, replace from a recovery phrase or clear the current identity first.';
  String get clearLocalIdentity => _zh ? '清除本机身份' : 'Clear local identity';
  String get clearIdentityTitle => _zh ? '清除本机身份？' : 'Clear local identity?';
  String get clearIdentityMessage => _zh
      ? '这会删除当前本机身份，以及本机联系人、消息、群组和密封历史。此操作不会删除对方设备上的消息。'
      : 'This deletes the current local identity, contacts, messages, groups, and sealed history. It does not delete messages on other devices.';
  String get clearIdentityConfirm => _zh ? '确认清除' : 'Clear';
  String get clear => _zh ? '清除' : 'Clear';
  String get securitySection => _zh ? '安全' : 'Security';
  String get localLockSettingTitle => _zh ? '打开 App 时验证身份' : 'Require unlock';
  String get localLockSettingSubtitle => _zh
      ? '启用后，打开 App 和高风险操作需要系统 PIN、密码或生物识别。'
      : 'When enabled, opening the app and sensitive actions require system PIN, password, or biometrics.';
  String get localLockUnavailable => _zh
      ? '请先在系统设置中配置锁屏 PIN、密码或生物识别。'
      : 'Set up a system PIN, password, or biometrics first.';
  String get localLockTitle => _zh ? 'Envelope 已锁定' : 'Envelope is locked';
  String get localLockDescription => _zh
      ? '使用系统 PIN、密码或生物识别解锁本机内容。'
      : 'Unlock local content with the system PIN, password, or biometrics.';
  String get localLockChecking =>
      _zh ? '正在读取本地锁屏状态...' : 'Checking app lock...';
  String get localLockUnlockReason => _zh
      ? '使用系统 PIN、密码或生物识别解锁 Envelope。'
      : 'Use system PIN, password, or biometrics to unlock Envelope.';
  String get unlock => _zh ? '解锁' : 'Unlock';
  String get messageSyncSection => _zh ? '消息同步' : 'Message sync';
  String get messageSyncNeedsIdentity =>
      _zh ? '创建身份后自动开启' : 'Create an identity to enable sync';
  String get messageSyncWaiting =>
      _zh ? '自动同步已开启，等待下一次同步' : 'Auto sync is on, waiting for the next sync';
  String messageSyncLastSuccess(String time) =>
      _zh ? '上次同步：$time' : 'Last sync: $time';
  String messageSyncLastError(String error) =>
      _zh ? '同步异常：$error' : 'Sync issue: $error';
  String get messageSyncAutoTitle => _zh ? '自动同步' : 'Auto sync';
  String get messageSyncAutoDescription => _zh
      ? '新消息、送达状态和当前可接收地址会在后台自动同步。'
      : 'New messages, delivery status, and your current receive route sync automatically.';
  String get messageSyncServiceTitle => _zh ? '同步服务' : 'Sync service';
  String get messageSyncServiceEntryTitle =>
      _zh ? '中继矩阵入口' : 'Relay matrix entry';
  String get messageSyncServiceHint => _zh
      ? '域名或 IP，例如 envelope.example.com'
      : 'Domain or IP, for example envelope.example.com';
  String get messageSyncServiceHelp => _zh
      ? '入口用于获取签名节点清单，并作为消息同步的初始中继。'
      : 'Used to fetch the signed node manifest and as the initial relay.';
  String get messageSyncServiceSave => _zh ? '保存同步服务入口' : 'Save sync entry';
  String get messageSyncServiceNotConfigured =>
      _zh ? '未配置，消息同步不会运行' : 'Not configured; sync will not run';
  String get messageSyncNow => _zh ? '立即同步' : 'Sync now';
  String get localBackupSection => _zh ? '本地备份' : 'Local backup';
  String get localBackupDescription => _zh
      ? '使用 24 词加密备份身份显示名、联系人、群组和同步入口；不包含聊天记录和文件缓存。'
      : 'Encrypts display name, contacts, groups, and sync entry with the 24-word phrase. Messages and cached files are not included.';
  String get exportLocalBackup => _zh ? '导出本地备份' : 'Export local backup';
  String get restoreLocalBackup => _zh ? '从本地备份恢复' : 'Restore local backup';
  String get diagnosticsSection => _zh ? '诊断' : 'Diagnostics';
  String get diagnosticsLogTitle => _zh ? '诊断日志' : 'Diagnostic logs';
  String get diagnosticsLogDescription => _zh
      ? '只记录操作状态、耗时、错误和网络路径，不记录消息内容、文件内容、密钥或恢复词。'
      : 'Records operation status, timing, errors, and network paths only. Message content, files, keys, and recovery phrases are not logged.';
  String get exportDiagnosticLogs => _zh ? '导出诊断日志' : 'Export diagnostic logs';
  String get clearDiagnosticLogs => _zh ? '清空诊断日志' : 'Clear diagnostic logs';
  String get pasteAddContact =>
      _zh ? '从剪贴板添加 contact' : 'Add contact from clipboard';
  String get add => _zh ? '添加' : 'Add';
  String get aboutSection => _zh ? '关于' : 'About';
  String get aboutProductName => _zh ? 'Envelope / 信封' : 'Envelope';
  String get aboutDescription =>
      _zh ? '版本、签名与使用帮助。' : 'Version, signing, and help.';
  String get helpSection => _zh ? '帮助' : 'Help';
  String get openUserManual => _zh ? '用户手册' : 'User manual';
  String get projectSection => _zh ? '项目' : 'Project';
  String get sourceCodeRepository => _zh ? '源代码' : 'Source code';
  String get license => _zh ? '许可证' : 'License';
  String get signingFingerprint =>
      _zh ? 'APK 签名 SHA-256' : 'APK signing SHA-256';

  String get close => _zh ? '关闭' : 'Close';
  String get cancel => _zh ? '取消' : 'Cancel';
  String get confirm => _zh ? '确认' : 'Confirm';
}

class _EnvelopeLocalizationsDelegate
    extends LocalizationsDelegate<EnvelopeLocalizations> {
  const _EnvelopeLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode.toLowerCase() == 'zh' ||
      locale.languageCode.toLowerCase() == 'en';

  @override
  Future<EnvelopeLocalizations> load(Locale locale) async {
    return EnvelopeLocalizations(
      locale.languageCode.toLowerCase() == 'zh'
          ? const Locale('zh')
          : const Locale('en'),
    );
  }

  @override
  bool shouldReload(
    covariant LocalizationsDelegate<EnvelopeLocalizations> old,
  ) => false;
}

extension EnvelopeLocalizationsX on BuildContext {
  EnvelopeLocalizations get l10n => EnvelopeLocalizations.of(this);
}
