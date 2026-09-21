import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_localizations.dart';
import 'android_chat_store.dart';
import 'android_db_store.dart';
import 'android_mailbox_reliability.dart';
import 'android_p2p.dart';
import 'android_relay_ha_adapter.dart';
import 'android_relay_ha_client.dart';
import 'android_server.dart';
import 'android_secure_store.dart';
import 'diagnostic_log.dart';
import 'envelope_native.dart';

const String _defaultDisplayName = 'Envelope User';
const String _defaultDesktopMessageHint = '你好，这是一条来自 Envelope UI 的消息。';
const String _defaultEnvelopeServerUrl = 'https://envelope.iamlouis.online';
const String _androidUserManualAsset = 'assets/manual/android-user-manual.html';
const String _sourceRepositoryUrl = 'https://github.com/louisir/envelope';
const String _appLicense = 'AGPL-3.0-or-later';
const String _appDisplayVersion = String.fromEnvironment(
  'ENVELOPE_APP_VERSION',
  defaultValue: 'v1.0.1.dev',
);
const bool _adbBridgeEnabled = bool.fromEnvironment(
  'ENVELOPE_ADB_BRIDGE',
  defaultValue: kDebugMode,
);
const String _androidIntroQrPrefix = 'envelope-intro-v1:';
const int _androidIntroQrTtlSeconds = 600;
const int _androidOnlineFileMaxBytes = 64 * 1024 * 1024;
const int _androidOnlineFileChunkBytes = 4 * 1024 * 1024;
const int _androidOfflineFileChunkBytes = 4 * 1024 * 1024;
const int _androidOfflineStreamReadBytes = 1024 * 1024;
const int _androidLegacyOfflineEnvelopeMaxBytes = 32 * 1024 * 1024;
const int _androidMaximumOfflineGroupRecipients = 1024;
const int _androidMaximumOfflineGroupChunks = 100000;
const int _androidMaximumOfflineGroupEnvelopeLines = 1000000;
const int _androidMaximumOfflineEnvelopeLineCharacters = 12 * 1024 * 1024;
const int _androidMaximumStagedOutboundEnvelopeBytes = 256 * 1024 * 1024;
const String _androidOfflineStreamMagic = 'ENVELOPE_STREAM_V1';
const String _androidOfflineGroupStreamMagic = 'ENVELOPE_GROUP_STREAM_V1';
const String _androidEnvelopeFileMime = 'application/vnd.westwardsoft.envelope';
const String _androidFileManifestMime =
    'application/vnd.westwardsoft.envelope.file-manifest+json';
const String _androidFileChunkMime =
    'application/vnd.westwardsoft.envelope.file-chunk+json';
const String _androidGroupControlMime =
    'application/vnd.westwardsoft.envelope.group-control+json';
const String _androidContactControlMime =
    'application/vnd.westwardsoft.envelope.contact-control+json';
const String _androidGroupConsensusEndorsementContext =
    'envelope/v1/group/consensus-endorsement';
const String _androidGroupEventSignatureContext = 'envelope/v1/group/event';
const Set<String> _androidSupportedPortableGroupEventTypes = {
  'group_invite',
  'group_message',
  'member_accepted',
  'member_endorsed',
  'group_renamed',
  'group_avatar_updated',
  'member_removed',
  'member_left',
};
const String _androidOfflineFileManifestMime =
    'application/vnd.westwardsoft.envelope.offline-file-manifest+json';
const String _androidOfflineFileChunkMime =
    'application/vnd.westwardsoft.envelope.offline-file-chunk';
const String _androidLocalBackupKind = 'envelope.android.local-backup';
const String _androidLocalBackupFileKind = 'envelope.android.local-backup-file';
const String _androidLocalBackupOpaqueScheme =
    'identity-self-opaque-envelope.local-backup.v2';
const String _androidLocalBackupMime =
    'application/vnd.envelope.local-backup+json';
const String _androidLocalBackupPayloadMime =
    'application/vnd.envelope.local-backup.payload+json';
const String _androidLocalBackupPayloadName = 'envelope-local-backup.json';
const String _androidLocalBackupFilePrefix = 'envelope-local-backup-';

enum _AndroidHomeTab { about, contacts, chat, unseal, settings }

enum _AndroidConversationFilter { all, contacts, groups }

class _AndroidLocalBackupWriteResult {
  const _AndroidLocalBackupWriteResult({
    required this.file,
    required this.store,
    required this.prunedCount,
  });

  final AndroidSavedFile file;
  final AndroidChatStore store;
  final int prunedCount;
}

class _AndroidLocalBackupForRestore {
  const _AndroidLocalBackupForRestore({
    required this.recovered,
    required this.store,
    required this.syncServiceUrl,
    required this.autoBackupIntervalHours,
    required this.autoBackupRetentionCount,
  });

  final NativeIdentitySummary recovered;
  final AndroidChatStore store;
  final String syncServiceUrl;
  final int? autoBackupIntervalHours;
  final int? autoBackupRetentionCount;
}

class _AndroidGroupControlMessageRef {
  const _AndroidGroupControlMessageRef({
    required this.type,
    required this.groupId,
  });

  final String type;
  final String groupId;
}

class _AndroidMemberDeliveryResult {
  const _AndroidMemberDeliveryResult({
    required this.detail,
    this.failed = false,
    this.envelopeId,
  });

  final String detail;
  final bool failed;
  final String? envelopeId;
}

class _AndroidStagedEnvelopeDraft {
  const _AndroidStagedEnvelopeDraft({
    required this.contact,
    required this.recipientDisplayName,
    required this.envelopeId,
    required this.envelopeBase64,
    required this.childIndex,
  });

  final AndroidContactRecord contact;
  final String recipientDisplayName;
  final String envelopeId;
  final String envelopeBase64;
  final int childIndex;
}

class _AndroidDeferredMailboxRetryResult {
  const _AndroidDeferredMailboxRetryResult({
    required this.imported,
    required this.duplicates,
    required this.quarantined,
    required this.items,
  });

  final int imported;
  final int duplicates;
  final int quarantined;
  final List<Map<String, Object?>> items;
}

void main() {
  runApp(const EnvelopeApp());
}

class EnvelopeApp extends StatelessWidget {
  const EnvelopeApp({super.key, this.autoRefresh = true});

  final bool autoRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xfff97316),
      brightness: Brightness.light,
    );

    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      supportedLocales: EnvelopeLocalizations.supportedLocales,
      localizationsDelegates: const [
        EnvelopeLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xfffff7ed),
        useMaterial3: true,
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          bodyMedium: TextStyle(fontSize: 14),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffcfd8d4)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xffcfd8d4)),
          ),
        ),
      ),
      home: EnvelopeHomePage(autoRefresh: autoRefresh),
    );
  }
}

class EnvelopeHomePage extends StatefulWidget {
  const EnvelopeHomePage({super.key, required this.autoRefresh});

  final bool autoRefresh;

  @override
  State<EnvelopeHomePage> createState() => _EnvelopeHomePageState();
}

class _EnvelopeHomePageState extends State<EnvelopeHomePage>
    with WidgetsBindingObserver {
  static const MethodChannel _adbBridgeChannel = MethodChannel(
    'com.iamlouis.envelope/adb_bridge',
  );
  static const MethodChannel _externalOpenChannel = MethodChannel(
    'com.iamlouis.envelope/external_open',
  );
  static const int _androidMessagesPageSize = 50;
  static const Duration _androidMailboxForegroundPullInterval = Duration(
    seconds: 5,
  );
  static const Duration _androidLocalLockResumeGrace = Duration(seconds: 30);
  static const Duration _recoveryPhraseVisibleTimeout = Duration(minutes: 2);
  static const int _androidGroupDeliveryConcurrency = 3;
  static const int _androidGroupFileDeliveryConcurrency = 2;

  late final EnvelopeCli _cli;
  late final TextEditingController _storeDirController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _exportPathController;
  late final TextEditingController _contactPathController;
  late final TextEditingController _importPathController;
  late final TextEditingController _sendRecipientController;
  late final TextEditingController _sendTextController;
  late final TextEditingController _sendOutputPathController;
  late final TextEditingController _myP2pTicketController;
  late final TextEditingController _peerP2pTicketController;
  late final TextEditingController _recoveryPhraseController;
  late final TextEditingController _androidEnvelopeBase64Controller;
  late final TextEditingController _androidMessageController;
  late final TextEditingController _envelopeServerUrlController;
  late final String _defaultStoreDirPath;
  late final String _defaultExportPath;
  late final String _defaultContactPath;
  late final String _defaultImportPath;
  late final String _defaultSendOutputPath;
  late final AndroidSecureIdentityStore _secureStore;
  late final AndroidP2pTransport _androidP2p;
  Future<AndroidRelayHaClient>? _androidRelayClient;
  bool _androidRelaySyncInFlight = false;
  DateTime? _androidRelayRetryAfter;
  int _androidRelayOutboxOffset = 0;

  DiagnosticLogService? _diagnosticLog;
  bool _busy = false;
  bool _storeReady = false;
  bool _p2pListening = false;
  bool _secureIdentityReady = false;
  String _status = '未打开 store';
  String _details = '';
  String? _secureIdentityLabel;
  bool _androidP2pListening = false;
  bool _androidLocalLockChecked = false;
  bool _androidLocalLockEnabled = false;
  bool _androidLocalLockAvailable = false;
  bool _androidLocalLockUnlocked = true;
  bool _androidLocalLockBusy = false;
  DateTime? _androidLocalLockBackgroundedAt;
  String _androidSigningFingerprint = '';
  String? _androidP2pTicket;
  List<String> _androidP2pAddrs = const [];
  int? _androidP2pPort;
  final Map<String, String> _androidServerRegistrationTicketByUri =
      <String, String>{};
  final AndroidP2pCooldownTracker _androidP2pCooldown =
      AndroidP2pCooldownTracker();
  bool _androidEndpointPublishInFlight = false;
  bool _androidMailboxPullInFlight = false;
  bool _androidDeliveryReceiptSyncInFlight = false;
  bool _androidLocalBackupInFlight = false;
  int _androidAutoBackupIntervalHours =
      AndroidAutoBackupSettings.defaults.intervalHours;
  int _androidAutoBackupRetentionCount =
      AndroidAutoBackupSettings.defaults.retentionCount;
  DateTime? _androidLastMessageSyncAt;
  DateTime? _androidLastLocalBackupAt;
  String? _androidLastMessageSyncError;
  String? _androidLastLocalBackupError;
  SecureIdentityRecord? _secureIdentity;
  AndroidChatStore _androidChatStore = AndroidChatStore.empty();
  List<AndroidSealedEnvelopeRecord> _androidSealHistory = const [];
  final Map<String, int> _androidMessageLimitsByContact = <String, int>{};
  final Map<String, int> _androidMessageLimitsByGroup = <String, int>{};
  final Map<String, Future<AndroidSavedFilePreview?>>
  _androidSavedFilePreviewCache = <String, Future<AndroidSavedFilePreview?>>{};
  Map<String, int> _androidIncomingMessageCounts = const <String, int>{};
  Map<String, int> _androidIncomingConversationCounts = const <String, int>{};
  int _androidMessageCount = 0;
  int _androidPendingCount = 0;
  String? _selectedAndroidContactKeyId;
  String? _selectedAndroidGroupId;
  bool _androidMessageSelectionMode = false;
  bool _androidLoadingEarlierMessages = false;
  _AndroidHomeTab _androidHomeTab = _AndroidHomeTab.contacts;
  _AndroidConversationFilter _androidConversationFilter =
      _AndroidConversationFilter.all;
  final Set<String> _selectedAndroidMessageIds = <String>{};
  List<ContactRow> _contacts = const [];
  List<MessageRow> _messages = const [];
  EnvelopeNative? _native;
  String? _nativeError;
  Process? _p2pProcess;
  Timer? _androidMailboxPullTimer;
  Timer? _androidAutoBackupTimer;
  AndroidPickedFile? _pendingExternalEnvelopeFile;
  Timer? _recoveryPhraseClearTimer;
  StreamSubscription<String>? _p2pStdoutSubscription;
  StreamSubscription<String>? _p2pStderrSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final repoRoot = findRepoRoot();
    _cli = EnvelopeCli(repoRoot);
    try {
      _native = EnvelopeNative.load(repoRoot);
    } catch (error) {
      _nativeError = error.toString();
    }
    _secureStore = AndroidSecureIdentityStore();
    _defaultStoreDirPath = p.join(repoRoot.path, 'target', 'envelope-ui-store');
    _defaultExportPath = p.join(
      repoRoot.path,
      'target',
      'envelope-ui-store',
      'my.contact.json',
    );
    _defaultContactPath = p.join(
      repoRoot.path,
      'target',
      'envelope-demo',
      'alice.contact.json',
    );
    _defaultImportPath = p.join(
      repoRoot.path,
      'target',
      'envelope-demo',
      'message',
    );
    _defaultSendOutputPath = p.join(
      repoRoot.path,
      'target',
      'envelope-ui-out',
      'message',
    );
    _storeDirController = TextEditingController();
    _displayNameController = TextEditingController();
    _exportPathController = TextEditingController();
    _contactPathController = TextEditingController();
    _importPathController = TextEditingController();
    _sendRecipientController = TextEditingController();
    _sendTextController = TextEditingController();
    _sendOutputPathController = TextEditingController();
    _myP2pTicketController = TextEditingController();
    _peerP2pTicketController = TextEditingController();
    _recoveryPhraseController = TextEditingController();
    _recoveryPhraseController.addListener(_scheduleRecoveryPhraseClear);
    _androidEnvelopeBase64Controller = TextEditingController();
    _androidMessageController = TextEditingController();
    _envelopeServerUrlController = TextEditingController();
    _androidP2p = AndroidP2pTransport();
    unawaited(_initializeDiagnosticLog(repoRoot));
    if (Platform.isAndroid && _adbBridgeEnabled) {
      _adbBridgeChannel.setMethodCallHandler(_handleAdbBridgeCall);
    }
    if (Platform.isAndroid) {
      _externalOpenChannel.setMethodCallHandler(_handleExternalOpenCall);
      unawaited(_consumeInitialExternalOpen());
    }
    unawaited(_initializeAndroidLocalLock());
    unawaited(_loadAndroidRuntimeSecurityInfo());
    unawaited(_refreshSecureIdentity());
    unawaited(_refreshAndroidChatStore());
    if (Platform.isAndroid) {
      unawaited(_loadAndroidAutoBackupSettings());
      unawaited(
        _loadAndroidSyncServiceUrl().whenComplete(() {
          if (mounted) _startAndroidMailboxAutoPull();
        }),
      );
    }
    if (widget.autoRefresh) {
      unawaited(_refreshStore());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storeDirController.dispose();
    _displayNameController.dispose();
    _exportPathController.dispose();
    _contactPathController.dispose();
    _importPathController.dispose();
    _sendRecipientController.dispose();
    _sendTextController.dispose();
    _sendOutputPathController.dispose();
    _myP2pTicketController.dispose();
    _peerP2pTicketController.dispose();
    _recoveryPhraseClearTimer?.cancel();
    _recoveryPhraseController.removeListener(_scheduleRecoveryPhraseClear);
    _recoveryPhraseController.dispose();
    _androidEnvelopeBase64Controller.dispose();
    _androidMessageController.dispose();
    _envelopeServerUrlController.dispose();
    if (Platform.isAndroid && _adbBridgeEnabled) {
      _adbBridgeChannel.setMethodCallHandler(null);
    }
    if (Platform.isAndroid) {
      _externalOpenChannel.setMethodCallHandler(null);
    }
    unawaited(_p2pStdoutSubscription?.cancel());
    unawaited(_p2pStderrSubscription?.cancel());
    _p2pProcess?.kill();
    _androidMailboxPullTimer?.cancel();
    _androidAutoBackupTimer?.cancel();
    final relay = _androidRelayClient;
    if (relay != null) {
      unawaited(relay.then((client) => client.close(), onError: (Object _) {}));
    }
    unawaited(_androidP2p.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _clearRecoveryPhrase(refresh: false);
      _androidMailboxPullTimer?.cancel();
      _androidMailboxPullTimer = null;
      _androidAutoBackupTimer?.cancel();
      _androidAutoBackupTimer = null;
      if (_androidLocalLockEnabled) {
        _androidLocalLockBackgroundedAt = DateTime.now();
      }
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    _startAndroidMailboxAutoPull();
    _scheduleAndroidAutoBackupTimer();
    unawaited(_maybeRunAndroidAutoBackup(reason: 'app_resumed'));
    if (!_androidLocalLockEnabled) return;
    final backgroundedAt = _androidLocalLockBackgroundedAt;
    _androidLocalLockBackgroundedAt = null;
    if (backgroundedAt == null) return;
    final elapsed = DateTime.now().difference(backgroundedAt);
    if (elapsed >= _androidLocalLockResumeGrace && mounted) {
      setState(() => _androidLocalLockUnlocked = false);
    }
  }

  String _textOrDefault(TextEditingController controller, String fallback) {
    final text = controller.text.trim();
    return text.isEmpty ? fallback : text;
  }

  String get _configuredEnvelopeServerUrl => _textOrDefault(
    _envelopeServerUrlController,
    _defaultEnvelopeServerUrl,
  ).trim();

  String _serverUrlForDisplay(EnvelopeLocalizations l10n) {
    final value = _configuredEnvelopeServerUrl;
    return value.isEmpty ? l10n.messageSyncServiceNotConfigured : value;
  }

  String _normalizeEnvelopeServerUrlInput(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw const SecureStoreException('请先填写同步服务入口。');
    }
    final candidate = raw.contains('://') ? raw : 'https://$raw';
    late final Uri uri;
    try {
      uri = Uri.parse(candidate.endsWith('/') ? candidate : '$candidate/');
    } catch (_) {
      throw const SecureStoreException('同步服务入口格式无效。');
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const SecureStoreException('同步服务入口必须是域名或 IP。');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const SecureStoreException('同步服务入口只支持 http 或 https。');
    }
    return uri.toString();
  }

  Future<void> _loadAndroidSyncServiceUrl() async {
    if (!Platform.isAndroid || !_secureStore.isSupported) return;
    try {
      final saved = await _secureStore.readSyncServiceUrl();
      if (!mounted || saved == null || saved.trim().isEmpty) return;
      final normalized = _normalizeEnvelopeServerUrlInput(saved);
      setState(() => _envelopeServerUrlController.text = normalized);
    } catch (error) {
      debugPrint('Envelope sync service URL load failed: $error');
    }
  }

  Future<void> _loadAndroidAutoBackupSettings() async {
    if (!Platform.isAndroid || !_secureStore.isSupported) return;
    try {
      final settings = await _secureStore.readAutoBackupSettings();
      if (!mounted) return;
      setState(() {
        _androidAutoBackupIntervalHours = settings.intervalHours;
        _androidAutoBackupRetentionCount = settings.retentionCount;
        _androidLastLocalBackupAt = settings.lastBackupAtUnixMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(settings.lastBackupAtUnixMs!);
      });
      _scheduleAndroidAutoBackupTimer();
      unawaited(_maybeRunAndroidAutoBackup(reason: 'settings_loaded'));
    } catch (error) {
      if (mounted) {
        setState(() => _androidLastLocalBackupError = error.toString());
      }
      debugPrint('Envelope auto backup settings load failed: $error');
    }
  }

  Future<void> _setAndroidAutoBackupIntervalHours(int intervalHours) async {
    final normalized = intervalHours < 0 ? 0 : intervalHours;
    if (mounted) {
      setState(() {
        _androidAutoBackupIntervalHours = normalized;
        _androidLastLocalBackupError = null;
      });
    }
    await _secureStore.writeAutoBackupSettings(
      intervalHours: normalized,
      retentionCount: _androidAutoBackupRetentionCount,
    );
    _scheduleAndroidAutoBackupTimer();
    if (normalized > 0) {
      unawaited(_maybeRunAndroidAutoBackup(reason: 'setting_changed'));
    }
  }

  Future<void> _setAndroidAutoBackupRetentionCount(int retentionCount) async {
    final normalized = retentionCount <= 0
        ? AndroidAutoBackupSettings.defaults.retentionCount
        : retentionCount;
    if (mounted) {
      setState(() {
        _androidAutoBackupRetentionCount = normalized;
        _androidLastLocalBackupError = null;
      });
    }
    await _secureStore.writeAutoBackupSettings(
      intervalHours: _androidAutoBackupIntervalHours,
      retentionCount: normalized,
    );
    try {
      await _pruneAndroidLocalBackups();
    } catch (error) {
      if (mounted) {
        setState(() => _androidLastLocalBackupError = error.toString());
      }
    }
  }

  bool get _androidAutoBackupEnabled => _androidAutoBackupIntervalHours > 0;

  Duration get _androidAutoBackupInterval =>
      Duration(hours: _androidAutoBackupIntervalHours);

  void _scheduleAndroidAutoBackupTimer() {
    _androidAutoBackupTimer?.cancel();
    _androidAutoBackupTimer = null;
    if (!Platform.isAndroid || !_androidAutoBackupEnabled) return;
    final delay = _nextAndroidAutoBackupDelay();
    _androidAutoBackupTimer = Timer(delay, () {
      unawaited(
        _maybeRunAndroidAutoBackup(
          reason: 'timer',
        ).whenComplete(_scheduleAndroidAutoBackupTimer),
      );
    });
  }

  Duration _nextAndroidAutoBackupDelay() {
    final lastBackupAt = _androidLastLocalBackupAt;
    if (lastBackupAt == null) {
      return const Duration(seconds: 30);
    }
    final remaining = lastBackupAt
        .add(_androidAutoBackupInterval)
        .difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return const Duration(seconds: 10);
    }
    return remaining;
  }

  Future<void> _saveAndroidSyncServiceUrl() => _run('保存同步服务入口', () async {
    final normalized = _normalizeEnvelopeServerUrlInput(
      _envelopeServerUrlController.text,
    );
    if (Uri.parse(normalized).scheme != 'https') {
      throw const EnvelopeServerException('主备中继入口必须使用 HTTPS。');
    }
    if (_secureStore.isSupported) {
      await _secureStore.writeSyncServiceUrl(normalized);
    }
    EnvelopeServerClient.clearNodeCache();
    final priorRelay = _androidRelayClient;
    _androidRelayClient = null;
    if (priorRelay != null) {
      unawaited(
        priorRelay.then((client) => client.close(), onError: (Object _) {}),
      );
    }
    _androidServerRegistrationTicketByUri.clear();
    if (!mounted) return;
    setState(() {
      _envelopeServerUrlController.text = normalized;
      _androidLastMessageSyncError = null;
      _details = ['同步服务入口已保存。', 'server: $normalized'].join('\n');
    });
    if (Platform.isAndroid) _startAndroidMailboxAutoPull();
  });

  String get _storeDirPath =>
      _textOrDefault(_storeDirController, _defaultStoreDirPath);

  String get _exportPath =>
      _textOrDefault(_exportPathController, _defaultExportPath);

  String get _contactPath =>
      _textOrDefault(_contactPathController, _defaultContactPath);

  String get _importPath =>
      _textOrDefault(_importPathController, _defaultImportPath);

  String get _sendOutputPath =>
      _textOrDefault(_sendOutputPathController, _defaultSendOutputPath);

  Directory get _storeDir => Directory(_storeDirPath);

  EnvelopeNative get _nativeCore {
    final native = _native;
    if (native == null) {
      throw CliException(
        'Rust native core 未加载。请先运行 cargo build -p envelope-ffi。'
        '${_nativeError == null ? '' : '\n$_nativeError'}',
      );
    }
    return native;
  }

  Future<void> _initializeDiagnosticLog(Directory repoRoot) async {
    try {
      final directory = Platform.isAndroid && _secureStore.isSupported
          ? Directory(await _secureStore.getDiagnosticLogDirectory())
          : Directory(
              p.join(repoRoot.path, 'target', 'envelope-diagnostic-logs'),
            );
      final service = DiagnosticLogService(
        directory: directory,
        baseFields: {
          'app_version': _appDisplayVersion,
          'platform': Platform.operatingSystem,
        },
      );
      await service.initialize();
      _diagnosticLog = service;
      await service.info('app_start', {
        'native_loaded': _native != null,
        if (_nativeError != null) 'native_error': _nativeError,
      });
    } catch (error) {
      debugPrint('Envelope diagnostic log initialization failed: $error');
    }
  }

  void _logDiagnostic(
    String level,
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    final log = _diagnosticLog;
    if (log == null) return;
    switch (level) {
      case 'warn':
        unawaited(log.warn(event, fields));
        return;
      case 'error':
        unawaited(log.error(event, fields));
        return;
      default:
        unawaited(log.info(event, fields));
    }
  }

  void _startAndroidMailboxAutoPull() {
    if (!Platform.isAndroid) return;
    _androidMailboxPullTimer?.cancel();
    unawaited(_pullAndroidServerMailboxSilently());
    _androidMailboxPullTimer = Timer.periodic(
      _androidMailboxForegroundPullInterval,
      (_) => unawaited(_pullAndroidServerMailboxSilently()),
    );
  }

  Future<void> _pullAndroidServerMailboxSilently() async {
    if (!mounted || !Platform.isAndroid || !_secureStore.isSupported) return;
    if (_configuredEnvelopeServerUrl.isEmpty) return;
    if (_androidMailboxPullInFlight || _androidRelaySyncInFlight) return;
    final retryAfter = _androidRelayRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    _androidRelaySyncInFlight = true;
    final startedAt = DateTime.now();
    try {
      await _refreshSecureIdentity(startP2p: false);
      if (!mounted || _secureIdentity == null) return;
      await _reconcileAndroidRelayOutbox();
      final pull = await _pullAndroidServerMailbox(
        updateDetails: false,
        refreshIdentity: false,
      );
      final receipts = await _syncAndroidDeliveryReceiptsSilently();
      _markAndroidMessageSyncSucceeded();
      _logDiagnostic('info', 'mailbox_auto_sync_success', {
        'pulled': pull['pulled'],
        'imported': pull['imported'],
        'duplicates': pull['duplicates'],
        'quarantined': pull['quarantined'],
        'deferred_remaining': pull['deferred_remaining'],
        'acked': pull['acked'],
        'delivery_checked': receipts?['checked'],
        'delivery_delivered': receipts?['delivered'],
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
    } catch (error) {
      if (error is RelayHaException && error.code == 'RATE_LIMITED') {
        _androidRelayRetryAfter = DateTime.now().add(
          error.retryAfter ?? const Duration(seconds: 30),
        );
      }
      _markAndroidMessageSyncFailed(error);
      _logDiagnostic('warn', 'mailbox_auto_sync_failure', {
        'error': error.toString(),
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      debugPrint('Envelope mailbox auto-pull failed: $error');
    } finally {
      _androidRelaySyncInFlight = false;
    }
  }

  Future<void> _reconcileAndroidRelayOutbox() async {
    final db = await _ensureAndroidDbStore();
    final identity = _requireAndroidIdentity();
    final adapter = _createEnvelopeServerClient() as AndroidRelayHaAdapter;
    try {
      await adapter.health();
      await _ensureAndroidServerEndpointRegisteredForClient(adapter);
      final allPending = (await db.relayHa.pendingOutgoing(
        includeBodies: false,
        includeExpired: true,
      )).where((row) => row['sender_key_id'] == identity.keyId).toList();
      if (_androidRelayOutboxOffset >= allPending.length) {
        _androidRelayOutboxOffset = 0;
      }
      final pending = allPending
          .skip(_androidRelayOutboxOffset)
          .take(100)
          .toList();
      _androidRelayOutboxOffset += pending.length;
      if (pending.isNotEmpty) {
        await _withAndroidServerRegistrationRetry(
          client: adapter,
          request: () => adapter.deliveryStatus(
            senderKeyId: identity.keyId,
            statusRequestJson: jsonEncode({
              'envelope_ids': pending.map((row) => row['envelope_id']).toList(),
            }),
          ),
        );
      }
      var submitted = 0;
      for (final prior in pending) {
        final row = await db.relayHa.outgoing(
          senderKeyId: identity.keyId,
          recipientKeyId: prior['recipient_key_id'] as String,
          envelopeId: prior['envelope_id'] as String,
        );
        if (row == null ||
            row['delivery_state'] == 'delivered' ||
            row['delivery_state'] == 'rejected' ||
            row['delivery_state'] == 'expired' ||
            row['storage_state'] == 'replicated' ||
            (row['not_after'] as int) <=
                DateTime.now().millisecondsSinceEpoch) {
          continue;
        }
        if (submitted >= 4) break;
        final retry = await db.relayHa.outgoingRetry(row);
        if (retry?['blocked'] == true ||
            ((retry?['next_attempt_at'] as int?) ?? 0) >
                DateTime.now().millisecondsSinceEpoch) {
          continue;
        }
        try {
          await _withAndroidServerRegistrationRetry(
            client: adapter,
            request: () => adapter.submitEnvelope(
              submitRequestJson: jsonEncode({
                'recipient_key_id': row['recipient_key_id'],
                'envelope_id': row['envelope_id'],
                'envelope_b64': row['envelope_b64'],
              }),
            ),
          );
        } on RelayHaException catch (error) {
          _logDiagnostic('warn', 'relay_outbox_retry', {
            'envelope_id': row['envelope_id'],
            'code': error.code,
          });
        }
        submitted++;
      }
      await _withAndroidServerRegistrationRetry(
        client: adapter,
        request: () => adapter.ackMailbox(
          recipientKeyId: identity.keyId,
          ackRequestJson: jsonEncode({'envelope_ids': <String>[]}),
        ),
      );
      for (final logicalId
          in pending
              .map((row) => row['logical_message_id'] as String)
              .toSet()) {
        final rows = await db.relayHa.outgoingForLogicalMessage(logicalId);
        if (rows.isEmpty) continue;
        final fanout = await db.getOutboundEnvelopeBatch(logicalId);
        final transfer = await db.getFileTransferByMessageEnvelopeId(logicalId);
        final expected = fanout.isNotEmpty
            ? fanout.length
            : transfer != null
            ? ((transfer['chunk_count'] as num).toInt() + 1)
            : 1;
        final completeSet = rows.length == expected;
        final allDelivered =
            completeSet &&
            rows.every((row) => row['delivery_state'] == 'delivered');
        final allReplicated =
            completeSet &&
            rows.every((row) => row['storage_state'] == 'replicated');
        final anyRejected = rows.any(
          (row) => row['delivery_state'] == 'rejected',
        );
        final anyExpired = rows.any(
          (row) => row['delivery_state'] == 'expired',
        );
        final allTerminal =
            completeSet &&
            rows.every(
              (row) => const [
                'delivered',
                'rejected',
                'expired',
              ].contains(row['delivery_state']),
            );
        await db.updateMessageDelivery(
          envelopeId: logicalId,
          deliveryStatus: allDelivered
              ? AndroidDeliveryStatus.sent
              : allTerminal && anyRejected
              ? AndroidDeliveryStatus.rejected
              : allTerminal && anyExpired
              ? AndroidDeliveryStatus.expired
              : AndroidDeliveryStatus.serverMailbox,
          deliveryDetail: allDelivered
              ? '收件方已验证并持久接收。'
              : anyRejected
              ? '部分收件方已拒绝，未全部送达。'
              : anyExpired
              ? '服务端已可靠记录过期，未全部送达。'
              : allReplicated
              ? '已可靠保存，等待收件方接收。'
              : '等待主备可靠保存；本机保留重试副本。',
        );
      }
    } finally {
      adapter.close();
    }
  }

  void _markAndroidMessageSyncSucceeded() {
    if (!mounted) return;
    setState(() {
      _androidLastMessageSyncAt = DateTime.now();
      _androidLastMessageSyncError = null;
    });
  }

  void _markAndroidMessageSyncFailed(Object error) {
    if (!mounted) return;
    setState(() {
      _androidLastMessageSyncError = error.toString();
    });
  }

  String _formatAndroidMessageSyncTime(DateTime timestamp) {
    final local = timestamp.toLocal();
    return '${_twoAndroidDigits(local.hour)}:${_twoAndroidDigits(local.minute)}:'
        '${_twoAndroidDigits(local.second)}';
  }

  String _androidMessageSyncStatus(EnvelopeLocalizations l10n) {
    if (_configuredEnvelopeServerUrl.isEmpty) {
      return l10n.messageSyncServiceNotConfigured;
    }
    if (!_secureIdentityReady) {
      return l10n.messageSyncNeedsIdentity;
    }
    final error = _androidLastMessageSyncError;
    if (error != null && error.trim().isNotEmpty) {
      return l10n.messageSyncLastError(error);
    }
    final lastSyncAt = _androidLastMessageSyncAt;
    if (lastSyncAt == null) {
      return l10n.messageSyncWaiting;
    }
    return l10n.messageSyncLastSuccess(
      _formatAndroidMessageSyncTime(lastSyncAt),
    );
  }

  String _androidAutoBackupStatus(EnvelopeLocalizations l10n) {
    if (!_androidAutoBackupEnabled) {
      return l10n.autoBackupOff;
    }
    final error = _androidLastLocalBackupError;
    if (error != null && error.trim().isNotEmpty) {
      return l10n.autoBackupLastError(error);
    }
    final lastBackupAt = _androidLastLocalBackupAt;
    if (lastBackupAt == null) {
      return l10n.autoBackupNeverRun;
    }
    return l10n.autoBackupLastSuccess(
      _formatAndroidMessageSyncTime(lastBackupAt),
    );
  }

  String _androidAutoBackupIntervalLabel(
    EnvelopeLocalizations l10n,
    int hours,
  ) {
    if (hours <= 0) {
      return l10n.autoBackupOff;
    }
    return l10n.autoBackupEveryHours(hours);
  }

  Future<dynamic> _handleExternalOpenCall(MethodCall call) async {
    if (call.method != 'externalOpen') return null;
    await _handleExternalOpenPayload(call.arguments);
    return null;
  }

  Future<void> _consumeInitialExternalOpen() async {
    try {
      final payload = await _externalOpenChannel.invokeMethod<Object?>(
        'consumeInitialOpen',
      );
      await _handleExternalOpenPayload(payload);
    } on MissingPluginException {
      // Non-Android development targets do not provide the external-open channel.
    } on PlatformException catch (error) {
      debugPrint('Envelope initial external-open request failed: $error');
    }
  }

  Future<void> _handleExternalOpenPayload(Object? value) async {
    if (!mounted || value is! Map) return;
    final payload = value.cast<Object?, Object?>();
    final kind = payload['kind']?.toString();
    if (kind != 'open' && kind != 'file') return;

    setState(() {
      _androidHomeTab = _AndroidHomeTab.unseal;
      _androidMessageSelectionMode = false;
      _selectedAndroidMessageIds.clear();
    });
    if (kind == 'open') return;

    try {
      _pendingExternalEnvelopeFile = AndroidPickedFile.fromMap(payload);
      if (!_secureIdentityReady) {
        setState(() {
          _status = '已接收离线信封';
          _details = [
            '文件：${_pendingExternalEnvelopeFile!.name}',
            '请先在设置中恢复收件身份；恢复完成后将自动继续拆封。',
          ].join('\n');
        });
      }
      _schedulePendingExternalEnvelopeImport();
    } on SecureStoreException catch (error) {
      setState(() {
        _status = '打开离线信封失败';
        _details = error.message;
      });
    }
  }

  void _schedulePendingExternalEnvelopeImport() {
    if (!mounted || _busy || !_secureIdentityReady) return;
    final file = _pendingExternalEnvelopeFile;
    if (file == null) return;
    _pendingExternalEnvelopeFile = null;
    unawaited(_importAndroidOfflineEnvelopeFile(file));
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;
    final startedAt = DateTime.now();
    _logDiagnostic('info', 'operation_start', {'label': label});
    setState(() {
      _busy = true;
      _status = label;
      _details = '';
    });

    try {
      await action();
      _logDiagnostic('info', 'operation_success', {
        'label': label,
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      if (mounted) {
        setState(() => _status = '$label 完成');
      }
    } catch (error) {
      _logDiagnostic('error', 'operation_failure', {
        'label': label,
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
        'error': error.toString(),
      });
      if (mounted) {
        final message = error.toString();
        setState(() {
          _status = '$label 失败';
          _details = message;
        });
        _showRunErrorSnackBar(message);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _schedulePendingExternalEnvelopeImport();
      }
    }
  }

  void _showRunErrorSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _scheduleRecoveryPhraseClear() {
    _recoveryPhraseClearTimer?.cancel();
    _recoveryPhraseClearTimer = null;
    if (_recoveryPhraseController.text.trim().isEmpty) {
      return;
    }
    _recoveryPhraseClearTimer = Timer(
      _recoveryPhraseVisibleTimeout,
      _clearRecoveryPhrase,
    );
  }

  void _clearRecoveryPhrase({bool refresh = true}) {
    _recoveryPhraseClearTimer?.cancel();
    _recoveryPhraseClearTimer = null;
    if (_recoveryPhraseController.text.isEmpty) {
      return;
    }
    _recoveryPhraseController.clear();
    if (refresh && mounted) {
      setState(() {});
    }
  }

  Future<void> _initializeAndroidLocalLock() async {
    if (!Platform.isAndroid || !_secureStore.isSupported) {
      if (!mounted) return;
      setState(() {
        _androidLocalLockChecked = true;
        _androidLocalLockAvailable = false;
        _androidLocalLockEnabled = false;
        _androidLocalLockUnlocked = true;
      });
      return;
    }

    try {
      final available = await _secureStore.isLocalAuthenticationAvailable();
      final enabled = await _secureStore.readLocalLockEnabled();
      if (!mounted) return;
      setState(() {
        _androidLocalLockChecked = true;
        _androidLocalLockAvailable = available;
        _androidLocalLockEnabled = enabled && available;
        _androidLocalLockUnlocked = !enabled || !available;
        if (enabled && !available) {
          _details = '本机未配置系统锁屏 / 生物识别，本地锁屏已暂时停用。';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _androidLocalLockChecked = true;
        _androidLocalLockAvailable = false;
        _androidLocalLockEnabled = false;
        _androidLocalLockUnlocked = true;
        _details = '本地锁屏状态读取失败：$error';
      });
    }
  }

  Future<void> _loadAndroidRuntimeSecurityInfo() async {
    if (!Platform.isAndroid || !_secureStore.isSupported) return;
    try {
      final fingerprint = await _secureStore.getAppSigningCertificateSha256();
      if (!mounted) return;
      setState(() => _androidSigningFingerprint = fingerprint);
    } catch (_) {
      if (!mounted) return;
      setState(() => _androidSigningFingerprint = '');
    }
  }

  Future<bool> _unlockAndroidLocalLock({
    String? reason,
    bool force = false,
  }) async {
    if (!Platform.isAndroid || !_secureStore.isSupported) return true;
    if (!_androidLocalLockEnabled && !force) return true;
    if (_androidLocalLockUnlocked && !force) return true;
    if (_androidLocalLockBusy) return false;
    if (!_androidLocalLockAvailable) {
      _showRunErrorSnackBar('本机未配置系统锁屏 / 生物识别。');
      return false;
    }

    setState(() => _androidLocalLockBusy = true);
    try {
      final ok = await _secureStore.authenticateLocalUser(
        title: '解锁 Envelope',
        subtitle: reason ?? '使用系统 PIN、密码或生物识别继续。',
      );
      if (!mounted) return ok;
      setState(() {
        _androidLocalLockUnlocked = ok;
        if (!ok) {
          _details = '本地锁屏认证未通过。';
        }
      });
      return ok;
    } catch (error) {
      if (mounted) {
        setState(() => _details = '本地锁屏认证失败：$error');
        _showRunErrorSnackBar(error.toString());
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _androidLocalLockBusy = false);
      }
    }
  }

  Future<bool> _requireAndroidLocalUnlockForHighRisk(String reason) {
    return _unlockAndroidLocalLock(
      reason: reason,
      force: _androidLocalLockEnabled,
    );
  }

  Future<void> _setAndroidLocalLockEnabled(bool enabled) =>
      _run(enabled ? '启用本地锁屏' : '关闭本地锁屏', () async {
        if (enabled) {
          final available = await _secureStore.isLocalAuthenticationAvailable();
          if (!available) {
            throw const SecureStoreException('请先在系统设置中配置锁屏 PIN、密码或生物识别。');
          }
          if (!await _unlockAndroidLocalLock(
            reason: '启用后，打开 App 和高风险操作需要先通过系统认证。',
            force: true,
          )) {
            throw const SecureStoreException('本地锁屏认证未通过。');
          }
          await _secureStore.writeLocalLockEnabled(true);
          if (!mounted) return;
          setState(() {
            _androidLocalLockChecked = true;
            _androidLocalLockAvailable = true;
            _androidLocalLockEnabled = true;
            _androidLocalLockUnlocked = true;
            _details = '本地锁屏已启用。';
          });
          return;
        }

        if (!await _requireAndroidLocalUnlockForHighRisk('关闭本地锁屏需要先确认身份。')) {
          throw const SecureStoreException('本地锁屏认证未通过。');
        }
        await _secureStore.writeLocalLockEnabled(false);
        if (!mounted) return;
        setState(() {
          _androidLocalLockEnabled = false;
          _androidLocalLockUnlocked = true;
          _details = '本地锁屏已关闭。';
        });
      });

  Future<void> _refreshStore() async {
    if (_storeDirPath.isEmpty) return;
    try {
      final contacts = await _cli.listContacts(_storeDir);
      final messages = await _cli.listMessages(_storeDir);
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _messages = messages;
        _storeReady = true;
        _status = _p2pListening ? 'P2P 监听中' : 'store 已打开';
        _details = '';
        if (_sendRecipientController.text.trim().isEmpty &&
            contacts.isNotEmpty) {
          _sendRecipientController.text = contacts.first.keyId;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _contacts = const [];
        _messages = const [];
        _storeReady = false;
      });
    }
  }

  Future<void> _initStore() => _run('初始化 store', () async {
    await _cli.initStore(
      _storeDir,
      _displayNameController.text.trim().isEmpty
          ? _defaultDisplayName
          : _displayNameController.text.trim(),
    );
    await _refreshStore();
  });

  Future<void> _resetStore() => _run('重新生成用户', () async {
    if (_p2pListening) {
      await _stopP2pServe();
    }
    final backup = await _cli.backupStoreIfExists(_storeDir);
    await _cli.initStore(
      _storeDir,
      _displayNameController.text.trim().isEmpty
          ? _defaultDisplayName
          : _displayNameController.text.trim(),
    );
    await _refreshStore();
    if (mounted && backup != null) {
      setState(() => _details = '旧 store 已备份到：${backup.path}');
    }
  });

  Future<void> _generateRecoveryPhrase() => _run('生成恢复词', () async {
    final phrase = _nativeCore.generateRecoveryPhrase();
    if (!mounted) return;
    setState(() {
      _recoveryPhraseController.text = phrase;
      _details = '已由 Rust native core 生成 BIP39 24 词。\n请离线保存，泄露即等同身份可被恢复。';
    });
  });

  Future<void> _previewRecoveredIdentity() => _run('恢复词预览', () async {
    final phrase = _requiredRecoveryPhrase('请先填写 BIP39 24 词恢复词。');
    try {
      final summary = _nativeCore.recoverIdentity(
        displayName: _currentDisplayName,
        recoveryPhrase: phrase,
      );
      if (!mounted) return;
      setState(() {
        _details = [
          'Rust native core 恢复身份成功',
          'display name: ${summary.displayName}',
          'key id: ${summary.keyId}',
          'contact:',
          summary.contactJson,
        ].join('\n');
      });
    } finally {
      _clearRecoveryPhrase();
    }
  });

  String get _currentDisplayName => _displayNameController.text.trim().isEmpty
      ? _defaultDisplayName
      : _displayNameController.text.trim();

  void _resetAndroidIdentityRuntimeState({
    String? details,
    SecureIdentityRecord? identity,
  }) {
    _secureIdentityReady = identity != null;
    _secureIdentity = identity;
    _secureIdentityLabel = identity?.label;
    _androidP2pListening = false;
    _androidP2pTicket = null;
    _androidP2pAddrs = const [];
    _androidP2pPort = null;
    _androidServerRegistrationTicketByUri.clear();
    _androidLastMessageSyncAt = null;
    final relay = _androidRelayClient;
    _androidRelayClient = null;
    if (relay != null) {
      unawaited(relay.then((client) => client.close(), onError: (Object _) {}));
    }
    _androidLastMessageSyncError = null;
    _androidLastLocalBackupAt = null;
    _androidLastLocalBackupError = null;
    _androidChatStore = AndroidChatStore.empty();
    _androidSealHistory = const [];
    _androidMessageLimitsByContact.clear();
    _androidMessageLimitsByGroup.clear();
    _androidIncomingMessageCounts = const <String, int>{};
    _androidIncomingConversationCounts = const <String, int>{};
    _androidMessageCount = 0;
    _androidPendingCount = 0;
    _selectedAndroidContactKeyId = null;
    _selectedAndroidGroupId = null;
    _androidMessageSelectionMode = false;
    _selectedAndroidMessageIds.clear();
    if (details != null) {
      _details = details;
    }
  }

  Future<void> _clearAndroidIdentityAndChatStorageForReplacement() async {
    await _androidP2p.stop();
    final existingIdentity =
        _secureIdentity ??
        (_secureStore.isSupported ? await _secureStore.readIdentity() : null);
    final existingIdentityKeyId = existingIdentity?.keyId.trim() ?? '';
    if (existingIdentityKeyId.isNotEmpty && AndroidDbStore.instance.isOpen) {
      await AndroidDbStore.instance.bindLegacyReceivedCountersToIdentity(
        existingIdentityKeyId,
      );
    }
    await _clearAndroidChatStorage(refresh: false);
    if (AndroidDbStore.instance.isOpen) {
      await AndroidDbStore.instance.close();
    }
    await _secureStore.clearIdentity();
    await _secureStore.writeAutoBackupLastAtUnixMs(null);
  }

  Future<bool> _confirmAndroidIdentityReplacement() async {
    if (!_secureIdentityReady) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.replaceIdentityTitle),
            content: Text(context.l10n.replaceIdentityMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.restore_outlined),
                label: Text(context.l10n.replaceIdentityConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmAndroidIdentityClear() async {
    if (!_secureIdentityReady) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.clearIdentityTitle),
            content: Text(context.l10n.clearIdentityMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: Text(context.l10n.clearIdentityConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _refreshSecureIdentity({bool startP2p = true}) async {
    if (!_secureStore.isSupported) {
      if (!mounted) return;
      setState(() {
        _secureIdentityReady = false;
        _secureIdentity = null;
        _secureIdentityLabel = null;
      });
      return;
    }

    try {
      final record = await _secureStore.readIdentity();
      if (!mounted) return;
      setState(() {
        _secureIdentityReady = record != null;
        _secureIdentity = record;
        _secureIdentityLabel = record?.label;
      });
      if (record != null && Platform.isAndroid) {
        final db = await _ensureAndroidDbStore();
        final oldStoreJson = await _secureStore.readChatStore();
        if (oldStoreJson != null && oldStoreJson.trim().isNotEmpty) {
          await db.migrateFromOldStore(oldStoreJson);
          await _secureStore.clearChatStore();
          await _refreshAndroidChatStore();
        }
        if (startP2p) {
          unawaited(_ensureAndroidP2pListening());
        }
      }
      _schedulePendingExternalEnvelopeImport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _secureIdentityReady = false;
        _secureIdentity = null;
        _secureIdentityLabel = '读取失败：$error';
      });
    }
  }

  Future<void> _createAndSaveAndroidIdentity() =>
      _run('创建 Android 身份', () async {
        final identityAlreadySavedMessage = context.l10n.identityAlreadySaved;
        if (_secureIdentityReady || await _secureStore.hasIdentity()) {
          throw SecureStoreException(identityAlreadySavedMessage);
        }
        if (!await _requireAndroidLocalUnlockForHighRisk('创建新身份会清空当前本机聊天数据。')) {
          throw const SecureStoreException('本地锁屏认证未通过。');
        }
        final phrase = _nativeCore.generateRecoveryPhrase();
        final summary = _nativeCore.recoverIdentity(
          displayName: _currentDisplayName,
          recoveryPhrase: phrase,
        );
        final record = await _secureStore.writeIdentity(summary.identityJson);
        await _clearAndroidChatStorage(refresh: false);

        final p2pStatus = await _androidP2p.start(
          deviceId: _androidDeviceIdFor(record),
          onEnvelope: _handleAndroidP2pEnvelope,
        );
        if (!mounted) return;
        setState(() {
          _recoveryPhraseController.text = phrase;
          _resetAndroidIdentityRuntimeState(identity: record);
          _androidP2pListening = p2pStatus.listening;
          _androidP2pTicket = p2pStatus.ticket;
          _androidP2pAddrs = p2pStatus.addrs;
          _androidP2pPort = p2pStatus.port;
          _details = [
            'Android 身份已写入本机加密存储',
            'display name: ${record.displayName}',
            'key id: ${record.keyId}',
            '恢复词已经显示在输入框中，请离线保存。恢复词泄露即等同身份可被恢复。',
          ].join('\n');
        });
      });

  Future<void> _saveRecoveredAndroidIdentity() async {
    if (!await _confirmAndroidIdentityReplacement() || !mounted) {
      _clearRecoveryPhrase();
      return;
    }
    await _run('保存恢复身份', () async {
      final replacingExistingIdentity = _secureIdentityReady;
      final phrase = _requiredRecoveryPhrase('请先填写 BIP39 24 词恢复词。');
      try {
        final summary = _nativeCore.recoverIdentity(
          displayName: _currentDisplayName,
          recoveryPhrase: phrase,
        );
        if (_secureIdentityReady &&
            !await _requireAndroidLocalUnlockForHighRisk(
              '恢复身份会替换当前本机身份和聊天数据。',
            )) {
          throw const SecureStoreException('本地锁屏认证未通过。');
        }

        await _clearAndroidIdentityAndChatStorageForReplacement();
        final record = await _secureStore.writeIdentity(summary.identityJson);
        final p2pStatus = await _androidP2p.start(
          deviceId: _androidDeviceIdFor(record),
          onEnvelope: _handleAndroidP2pEnvelope,
        );
        if (!mounted) return;
        setState(() {
          _resetAndroidIdentityRuntimeState(identity: record);
          _androidP2pListening = p2pStatus.listening;
          _androidP2pTicket = p2pStatus.ticket;
          _androidP2pAddrs = p2pStatus.addrs;
          _androidP2pPort = p2pStatus.port;
          _details = [
            replacingExistingIdentity ? '本机身份已替换' : '恢复身份已写入 Android 本机加密存储',
            'display name: ${record.displayName}',
            'key id: ${record.keyId}',
          ].join('\n');
        });
      } finally {
        _clearRecoveryPhrase();
      }
    });
  }

  String _requiredRecoveryPhrase(String message) {
    final phrase = _recoveryPhraseController.text.trim();
    if (phrase.isEmpty) {
      throw SecureStoreException(message);
    }
    return phrase;
  }

  String _requiredRecoveryPhraseForLocalBackup() =>
      _requiredRecoveryPhrase('请先填写 BIP39 24 词恢复词，再选择本地备份文件。');

  String _androidLocalBackupFileName() {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
    return '$_androidLocalBackupFilePrefix$stamp.json';
  }

  int _newAndroidCounterNamespace(Set<int> excluded) {
    final random = Random.secure();
    int value;
    do {
      value = (random.nextInt(1 << 16) << 16) | random.nextInt(1 << 16);
    } while (value == 0 || excluded.contains(value));
    return value;
  }

  String _newAndroidCounterDeviceId() {
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'android-$suffix';
  }

  Map<String, Object?> _androidLocalBackupContents() => const {
    'contacts': true,
    'groups': true,
    'settings': true,
    'messages': false,
    'file_cache': false,
  };

  AndroidChatStore _validateAndroidPortableGroupEvents(AndroidChatStore store) {
    final groupsById = <String, AndroidGroupRecord>{};
    for (final group in store.groups) {
      if (groupsById.containsKey(group.groupId)) {
        throw SecureStoreException('本地备份包含重复 group_id：${group.groupId}。');
      }
      groupsById[group.groupId] = group;
    }
    final currentMemberKeys = <String, Set<String>>{};
    for (final member in store.groupMembers) {
      currentMemberKeys
          .putIfAbsent(member.groupId, () => <String>{})
          .add(member.keyId);
    }

    final verifiedEvents = <AndroidGroupEventRecord>[];
    for (final event in androidNormalizePortableGroupEvents(
      store.groupEvents,
    )) {
      try {
        final currentGroup = groupsById[event.groupId];
        if (!_androidSupportedPortableGroupEventTypes.contains(event.type) ||
            currentGroup == null ||
            event.epoch > currentGroup.epoch ||
            !(currentMemberKeys[event.groupId]?.contains(event.actorKeyId) ??
                false)) {
          throw const FormatException('group event metadata is invalid');
        }
        final decoded = jsonDecode(event.payloadJson);
        if (decoded is! Map) {
          throw const FormatException('group event payload is not an object');
        }
        final payload = decoded.cast<String, Object?>();
        final version = payload['version'];
        final createdAt = payload['created_at_unix_ms'];
        final groupValue = payload['group'];
        final membersValue = payload['members'];
        if (version is! num ||
            version.toInt() != version ||
            version.toInt() != 1 ||
            payload['event_id']?.toString() != event.eventId ||
            payload['type']?.toString() != event.type ||
            payload['actor_key_id']?.toString() != event.actorKeyId ||
            createdAt is! num ||
            createdAt.toInt() != createdAt ||
            createdAt.toInt() != event.createdAtUnixMs ||
            groupValue is! Map ||
            membersValue is! List) {
          throw const FormatException(
            'group event payload does not match metadata',
          );
        }
        final eventGroup = AndroidGroupRecord.fromJson(groupValue);
        final payloadGroupEpoch = groupValue['epoch'];
        if (eventGroup.groupId != event.groupId ||
            payloadGroupEpoch is! num ||
            payloadGroupEpoch.toInt() != payloadGroupEpoch ||
            eventGroup.epoch != event.epoch) {
          throw const FormatException(
            'group event payload group does not match metadata',
          );
        }
        AndroidGroupMemberRecord? historicalActor;
        for (final memberValue in membersValue) {
          if (memberValue is! Map) {
            throw const FormatException('group event member is not an object');
          }
          final member = AndroidGroupMemberRecord.fromJson(memberValue);
          if (member.groupId == event.groupId &&
              member.keyId == event.actorKeyId) {
            historicalActor ??= member;
          }
        }
        if (historicalActor == null ||
            historicalActor.contactJson.trim().isEmpty) {
          throw const FormatException(
            'group event payload has no actor contact',
          );
        }
        final parsedActor = _nativeCore.parseContact(
          historicalActor.contactJson,
        );
        if (parsedActor.keyId != event.actorKeyId) {
          throw const FormatException(
            'group event actor contact is mismatched',
          );
        }
        _validateAndroidGroupControlSignature(
          payload,
          AndroidContactRecord(
            keyId: parsedActor.keyId,
            displayName: parsedActor.displayName,
            contactJson: parsedActor.contactJson,
          ),
        );
        verifiedEvents.add(
          AndroidGroupEventRecord(
            eventId: event.eventId,
            groupId: event.groupId,
            epoch: event.epoch,
            type: event.type,
            actorKeyId: event.actorKeyId,
            createdAtUnixMs: event.createdAtUnixMs,
            payloadJson: event.payloadJson,
            signature: payload['signature']?.toString() ?? '',
          ),
        );
      } catch (error) {
        throw SecureStoreException(
          '本地备份 group_event 校验失败：${event.eventId}。$error',
        );
      }
    }
    return store.copyWith(groupEvents: verifiedEvents).normalized();
  }

  String _androidLocalBackupPayloadJson({
    required SecureIdentityRecord identity,
    required AndroidChatStore store,
  }) {
    final syncServiceUrl = _configuredEnvelopeServerUrl;
    final payload = <String, Object?>{
      'version': 1,
      'kind': _androidLocalBackupKind,
      'created_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      'identity': {
        'key_id': identity.keyId,
        'display_name': identity.displayName,
      },
      'settings': {
        'sync_service_url': syncServiceUrl.isEmpty ? null : syncServiceUrl,
        'auto_backup_interval_hours': _androidAutoBackupIntervalHours,
        'auto_backup_retention_count': _androidAutoBackupRetentionCount,
      },
      'contents': _androidLocalBackupContents(),
      'store': store.copyWith(messages: const []).toJson(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<_AndroidLocalBackupWriteResult> _createAndroidLocalBackupFile({
    required SecureIdentityRecord identity,
  }) async {
    final db = await _ensureAndroidDbStore();
    var store = await db.exportLocalBackupStore(
      recipientIdentityKeyId: identity.keyId,
    );
    store = _validateAndroidPortableGroupEvents(store);
    final backupEnvelopeCounter = store.nextMessageCounter;
    final nextCounter = androidAdvanceMessageCounter(backupEnvelopeCounter);
    await db.setNextMessageCounter(nextCounter);
    store = store.copyWith(nextMessageCounter: nextCounter);
    final plaintext = _androidLocalBackupPayloadJson(
      identity: identity,
      store: store,
    );
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
    final ownContactJson = _nativeCore.contactFromIdentityJson(
      identity.identityJson,
    );
    final opaque = _nativeCore.encryptOpaqueFile(
      identityJson: identity.identityJson,
      recipientContactJson: ownContactJson,
      filename: _androidLocalBackupPayloadName,
      mime: _androidLocalBackupPayloadMime,
      payloadBytes: plaintextBytes,
      messageCounter: backupEnvelopeCounter,
    );
    final wrapper = <String, Object?>{
      'version': 2,
      'kind': _androidLocalBackupFileKind,
      'scheme': _androidLocalBackupOpaqueScheme,
      'created_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      'identity': {
        'key_id': identity.keyId,
        'display_name': identity.displayName,
      },
      'contents': _androidLocalBackupContents(),
      'payload_filename': _androidLocalBackupPayloadName,
      'payload_mime': _androidLocalBackupPayloadMime,
      'payload_sha256': crypto.sha256.convert(plaintextBytes).toString(),
      'envelope_b64': opaque.envelopeBase64,
      'envelope_len': opaque.envelopeLength,
    };
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(wrapper)),
    );
    final file = await _secureStore.createSavedFile(
      name: _androidLocalBackupFileName(),
      mime: _androidLocalBackupMime,
      childDir: 'backups',
    );
    await _secureStore.appendSavedFileBytes(uri: file.uri, bytes: bytes);
    final finished = await _secureStore.finishSavedFile(
      file: file,
      bytes: bytes.length,
    );
    final prunedCount = await _pruneAndroidLocalBackups();
    return _AndroidLocalBackupWriteResult(
      file: finished,
      store: store,
      prunedCount: prunedCount,
    );
  }

  Future<int> _pruneAndroidLocalBackups() {
    return _secureStore.pruneSavedFiles(
      childDir: 'backups',
      prefix: _androidLocalBackupFilePrefix,
      keep: _androidAutoBackupRetentionCount,
    );
  }

  Future<void> _markAndroidLocalBackupSucceeded(DateTime timestamp) async {
    await _secureStore.writeAutoBackupLastAtUnixMs(
      timestamp.millisecondsSinceEpoch,
    );
    if (mounted) {
      setState(() {
        _androidLastLocalBackupAt = timestamp;
        _androidLastLocalBackupError = null;
      });
    }
    _scheduleAndroidAutoBackupTimer();
  }

  Future<void> _exportAndroidLocalBackup() => _run('导出本地备份', () async {
    final identity = _secureIdentity;
    if (identity == null) {
      throw const SecureStoreException('请先创建或恢复 Android 本机身份。');
    }
    if (_androidLocalBackupInFlight) {
      throw const SecureStoreException('本地备份正在运行，请稍后再试。');
    }
    try {
      if (!await _requireAndroidLocalUnlockForHighRisk(
        '导出本地备份会包含联系人、群组和本机设置。',
      )) {
        throw const SecureStoreException('本地锁屏认证未通过。');
      }
      if (mounted) {
        setState(() => _androidLocalBackupInFlight = true);
      }
      final result = await _createAndroidLocalBackupFile(identity: identity);
      final completedAt = DateTime.now();
      await _markAndroidLocalBackupSucceeded(completedAt);
      if (!mounted) return;
      setState(() {
        _details = [
          '本地备份已导出。',
          '文件: ${result.file.displayPath}',
          '格式: v2 本机身份自加密',
          '联系人: ${result.store.contacts.length}',
          '群组: ${result.store.groups.length}',
          '群成员记录: ${result.store.groupMembers.length}',
          '聊天记录: 未包含',
          if (result.prunedCount > 0) '已清理旧备份: ${result.prunedCount}',
        ].join('\n');
      });
    } finally {
      if (mounted) {
        setState(() => _androidLocalBackupInFlight = false);
      }
      _clearRecoveryPhrase();
    }
  });

  Future<void> _maybeRunAndroidAutoBackup({required String reason}) async {
    if (!mounted ||
        !Platform.isAndroid ||
        !_secureStore.isSupported ||
        !_androidAutoBackupEnabled ||
        _busy ||
        _androidLocalBackupInFlight) {
      return;
    }
    if (_androidLocalLockEnabled && !_androidLocalLockUnlocked) {
      return;
    }
    final identity = _secureIdentity;
    if (identity == null) {
      return;
    }
    final lastBackupAt = _androidLastLocalBackupAt;
    if (lastBackupAt != null &&
        DateTime.now().difference(lastBackupAt) < _androidAutoBackupInterval) {
      return;
    }
    await _runAndroidAutoBackup(identity: identity, reason: reason);
  }

  Future<void> _runAndroidAutoBackup({
    required SecureIdentityRecord identity,
    required String reason,
  }) async {
    if (mounted) {
      setState(() => _androidLocalBackupInFlight = true);
    }
    final startedAt = DateTime.now();
    try {
      final result = await _createAndroidLocalBackupFile(identity: identity);
      final completedAt = DateTime.now();
      await _markAndroidLocalBackupSucceeded(completedAt);
      _logDiagnostic('info', 'local_auto_backup_success', {
        'reason': reason,
        'contacts': result.store.contacts.length,
        'groups': result.store.groups.length,
        'pruned': result.prunedCount,
        'elapsed_ms': completedAt.difference(startedAt).inMilliseconds,
      });
    } catch (error) {
      if (mounted) {
        setState(() => _androidLastLocalBackupError = error.toString());
      }
      _logDiagnostic('warn', 'local_auto_backup_failure', {
        'reason': reason,
        'error': error.toString(),
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      debugPrint('Envelope local auto backup failed: $error');
    } finally {
      if (mounted) {
        setState(() => _androidLocalBackupInFlight = false);
      }
      _scheduleAndroidAutoBackupTimer();
    }
  }

  _AndroidLocalBackupForRestore _decodeAndroidLocalBackupForRestore({
    required String recoveryPhrase,
    required String backupJson,
  }) {
    final trimmed = backupJson.trim();
    Object? decodedFile;
    try {
      decodedFile = jsonDecode(trimmed);
    } catch (_) {
      decodedFile = null;
    }

    if (decodedFile is Map &&
        decodedFile['version'] == 2 &&
        decodedFile['kind'] == _androidLocalBackupFileKind) {
      final wrapper = decodedFile.cast<Object?, Object?>();
      if (wrapper['scheme'] != _androidLocalBackupOpaqueScheme) {
        throw const SecureStoreException('不支持的本地备份加密格式。');
      }
      final identityJson = wrapper['identity'];
      if (identityJson is! Map) {
        throw const SecureStoreException('本地备份缺少身份信息。');
      }
      final identity = identityJson.cast<Object?, Object?>();
      final displayName = (identity['display_name']?.toString() ?? '').trim();
      final backupKeyId = (identity['key_id']?.toString() ?? '').trim();
      final recovered = _nativeCore.recoverIdentity(
        displayName: displayName.isEmpty ? _defaultDisplayName : displayName,
        recoveryPhrase: recoveryPhrase,
      );
      if (backupKeyId.isNotEmpty && recovered.keyId != backupKeyId) {
        throw const SecureStoreException('恢复词与备份身份不匹配，拒绝导入。');
      }
      final envelopeBase64 = (wrapper['envelope_b64']?.toString() ?? '').trim();
      if (envelopeBase64.isEmpty) {
        throw const SecureStoreException('本地备份缺少加密数据。');
      }
      final ownContactJson = _nativeCore.contactFromIdentityJson(
        recovered.identityJson,
      );
      final payload = _nativeCore.decryptOpaquePayload(
        identityJson: recovered.identityJson,
        senderContactJson: ownContactJson,
        envelopeBase64: envelopeBase64,
      );
      if (payload.payloadKind != 'file' ||
          payload.mime != _androidLocalBackupPayloadMime) {
        throw const SecureStoreException('本地备份载荷格式无效。');
      }
      if (payload.senderKeyId != recovered.keyId ||
          payload.recipientKeyId != recovered.keyId) {
        throw const SecureStoreException('本地备份身份校验失败。');
      }
      final payloadBytes = payload.payloadBytes;
      final expectedHash = (wrapper['payload_sha256']?.toString() ?? '')
          .trim()
          .toLowerCase();
      if (expectedHash.isNotEmpty) {
        final actualHash = crypto.sha256.convert(payloadBytes).toString();
        if (actualHash != expectedHash) {
          throw const SecureStoreException('本地备份内容校验失败。');
        }
      }
      return _parseAndroidLocalBackupPayload(
        recoveryPhrase: recoveryPhrase,
        plaintext: utf8.decode(payloadBytes),
        recovered: recovered,
      );
    }

    final plaintext = _nativeCore.decryptLocalBackup(
      recoveryPhrase: recoveryPhrase,
      backupJson: backupJson,
    );
    return _parseAndroidLocalBackupPayload(
      recoveryPhrase: recoveryPhrase,
      plaintext: plaintext,
    );
  }

  _AndroidLocalBackupForRestore _parseAndroidLocalBackupPayload({
    required String recoveryPhrase,
    required String plaintext,
    NativeIdentitySummary? recovered,
  }) {
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map) {
      throw const SecureStoreException('本地备份格式无效。');
    }
    if (decoded['version'] != 1 || decoded['kind'] != _androidLocalBackupKind) {
      throw const SecureStoreException('不支持的本地备份格式。');
    }
    final identityJson = decoded['identity'];
    if (identityJson is! Map) {
      throw const SecureStoreException('本地备份缺少身份信息。');
    }
    final identity = identityJson.cast<Object?, Object?>();
    final displayName = (identity['display_name']?.toString() ?? '').trim();
    final backupKeyId = (identity['key_id']?.toString() ?? '').trim();
    final effectiveRecovered =
        recovered ??
        _nativeCore.recoverIdentity(
          displayName: displayName.isEmpty ? _defaultDisplayName : displayName,
          recoveryPhrase: recoveryPhrase,
        );
    if (backupKeyId.isNotEmpty && effectiveRecovered.keyId != backupKeyId) {
      throw const SecureStoreException('恢复词与备份身份不匹配，拒绝导入。');
    }
    final storeJson = decoded['store'];
    if (storeJson is! Map) {
      throw const SecureStoreException('本地备份缺少联系人和群组数据。');
    }
    var store = AndroidChatStore.fromJson(
      storeJson.cast<String, Object?>(),
    ).copyWith(messages: const []);
    final replayRecipient = store.receivedCounterRecipientKeyId?.trim() ?? '';
    if (replayRecipient.isNotEmpty &&
        replayRecipient != effectiveRecovered.keyId) {
      throw const SecureStoreException('本地备份的防重放状态属于另一个身份。');
    }
    store = store.copyWith(
      receivedCounterRecipientKeyId: effectiveRecovered.keyId,
    );
    store = _validateAndroidPortableGroupEvents(store);
    final settingsJson = decoded['settings'];
    final settings = settingsJson is Map
        ? settingsJson.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final syncServiceValue =
        settings['sync_service_url']?.toString().trim() ?? '';
    final syncServiceUrl = syncServiceValue.isEmpty
        ? ''
        : _normalizeEnvelopeServerUrlInput(syncServiceValue);
    final autoBackupIntervalHours =
        (settings['auto_backup_interval_hours'] as num?)?.toInt();
    final autoBackupRetentionCount =
        (settings['auto_backup_retention_count'] as num?)?.toInt();
    return _AndroidLocalBackupForRestore(
      recovered: effectiveRecovered,
      store: store,
      syncServiceUrl: syncServiceUrl,
      autoBackupIntervalHours: autoBackupIntervalHours,
      autoBackupRetentionCount: autoBackupRetentionCount,
    );
  }

  Future<bool> _confirmAndroidLocalBackupRestore() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('从本地备份恢复'),
            content: const Text(
              '这会用备份中的身份显示名、联系人、群组和本机设置替换当前本机现场。'
              '聊天记录和文件缓存不会从该备份恢复。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.restore_outlined),
                label: const Text('恢复'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _importAndroidLocalBackup() async {
    if (!await _confirmAndroidLocalBackupRestore() || !mounted) {
      _clearRecoveryPhrase();
      return;
    }
    await _run('从本地备份恢复', () async {
      final phrase = _requiredRecoveryPhraseForLocalBackup();
      try {
        if (!await _requireAndroidLocalUnlockForHighRisk(
          '从本地备份恢复会替换当前本机身份和使用现场。',
        )) {
          throw const SecureStoreException('本地锁屏认证未通过。');
        }
        final pickedFile = await _secureStore.pickLocalBackupFile();
        if (pickedFile == null) {
          throw const SecureStoreException('未选择本地备份文件。');
        }
        final encryptedBytes = await _readAndroidPickedFileBytes(pickedFile);
        final encryptedJson = utf8.decode(encryptedBytes);
        final backup = _decodeAndroidLocalBackupForRestore(
          recoveryPhrase: phrase,
          backupJson: encryptedJson,
        );

        final currentDb = await _ensureAndroidDbStore();
        var currentCounterState = await currentDb.getCounterLaneState();
        final currentIdentity =
            _secureIdentity ?? await _secureStore.readIdentity();
        final currentIdentityKeyId = currentIdentity?.keyId.trim() ?? '';
        if (currentIdentityKeyId.isNotEmpty) {
          await currentDb.bindLegacyReceivedCountersToIdentity(
            currentIdentityKeyId,
          );
          currentCounterState = currentCounterState.copyWith(
            receivedCounterRecipientKeyId: currentIdentityKeyId,
            receivedCounterRanges: await currentDb.getReceivedCounterRanges(
              currentIdentityKeyId,
            ),
          );
        }
        final excludedCounterNamespaces = androidCounterNamespacesToExclude([
          currentCounterState,
          backup.store,
        ]);
        final restoredStore = androidPreparePortableBackupRestore(
          backupStore: backup.store,
          currentCounterState: currentCounterState,
          recipientIdentityKeyId: backup.recovered.keyId,
          newCounterNamespace: _newAndroidCounterNamespace(
            excludedCounterNamespaces,
          ),
          newCounterDeviceId: _newAndroidCounterDeviceId(),
        );

        await _clearAndroidIdentityAndChatStorageForReplacement();
        final record = await _secureStore.writeIdentity(
          backup.recovered.identityJson,
        );
        final db = await _ensureAndroidDbStore();
        await db.importLocalBackupStore(
          restoredStore,
          recipientIdentityKeyId: backup.recovered.keyId,
        );
        if (backup.syncServiceUrl.isEmpty) {
          await _secureStore.writeSyncServiceUrl('');
          _envelopeServerUrlController.clear();
        } else {
          await _secureStore.writeSyncServiceUrl(backup.syncServiceUrl);
          _envelopeServerUrlController.text = backup.syncServiceUrl;
        }
        final restoredIntervalHours =
            backup.autoBackupIntervalHours ??
            AndroidAutoBackupSettings.defaults.intervalHours;
        final restoredRetentionCount =
            backup.autoBackupRetentionCount ??
            AndroidAutoBackupSettings.defaults.retentionCount;
        await _secureStore.writeAutoBackupSettings(
          intervalHours: restoredIntervalHours,
          retentionCount: restoredRetentionCount,
        );
        await _secureStore.writeAutoBackupLastAtUnixMs(null);
        EnvelopeServerClient.clearNodeCache();
        final p2pStatus = await _androidP2p.start(
          deviceId: _androidDeviceIdFor(record),
          onEnvelope: _handleAndroidP2pEnvelope,
        );
        if (!mounted) return;
        setState(() {
          _resetAndroidIdentityRuntimeState(identity: record);
          _androidP2pListening = p2pStatus.listening;
          _androidP2pTicket = p2pStatus.ticket;
          _androidP2pAddrs = p2pStatus.addrs;
          _androidP2pPort = p2pStatus.port;
          _envelopeServerUrlController.text = backup.syncServiceUrl;
          _androidAutoBackupIntervalHours = restoredIntervalHours;
          _androidAutoBackupRetentionCount = restoredRetentionCount;
          _androidLastLocalBackupAt = null;
          _androidLastLocalBackupError = null;
          _details = [
            '本地备份已恢复。',
            'display name: ${record.displayName}',
            'key id: ${record.keyId}',
            '联系人: ${backup.store.contacts.length}',
            '群组: ${backup.store.groups.length}',
            '聊天记录: 未恢复',
          ].join('\n');
        });
        await _refreshAndroidChatStore();
        if (Platform.isAndroid) _startAndroidMailboxAutoPull();
        _scheduleAndroidAutoBackupTimer();
      } finally {
        _clearRecoveryPhrase();
      }
    });
  }

  Future<void> _loadAndroidIdentity() => _run('读取 Android 身份', () async {
    final record = await _secureStore.readIdentity();
    if (!mounted) return;
    setState(() {
      _secureIdentityReady = record != null;
      _secureIdentity = record;
      _secureIdentityLabel = record?.label;
      _details = record == null
          ? 'Android 本机加密存储里还没有身份。'
          : [
              'Android 本机加密存储读取成功',
              'display name: ${record.displayName}',
              'key id: ${record.keyId}',
            ].join('\n');
    });
  });

  Future<void> _clearAndroidIdentity() async {
    if (!await _confirmAndroidIdentityClear() || !mounted) return;
    await _run('清除 Android 身份', () async {
      if (!await _requireAndroidLocalUnlockForHighRisk(
        '清除身份会删除本机联系人、消息、群组和密封历史。',
      )) {
        throw const SecureStoreException('本地锁屏认证未通过。');
      }
      await _clearAndroidIdentityAndChatStorageForReplacement();
      if (!mounted) return;
      setState(() {
        _resetAndroidIdentityRuntimeState(
          details: 'Android 本机身份记录已清除；Keystore key 仍由系统管理。',
        );
      });
    });
  }

  Future<void> _refreshAndroidChatStore() async {
    if (!_secureStore.isSupported) return;
    try {
      final db = await _ensureAndroidDbStore();
      final identityKeyId = _secureIdentity?.keyId.trim() ?? '';
      if (identityKeyId.isNotEmpty) {
        await db.bindLegacyReceivedCountersToIdentity(identityKeyId);
      }
      final contacts = await db.getContacts();
      var groups = await db.getGroups();
      final groupMembers = await db.getGroupMembers();
      final locallyDissolvedGroupIds = _androidGroupIdsToDissolveOnRefresh(
        groups: groups,
        groupMembers: groupMembers,
      );
      if (locallyDissolvedGroupIds.isNotEmpty) {
        for (final groupId in locallyDissolvedGroupIds) {
          await db.deactivateGroup(groupId);
        }
        groups = [
          for (final group in groups)
            locallyDissolvedGroupIds.contains(group.groupId)
                ? group.copyWith(isActive: false)
                : group,
        ];
      }
      final visibleGroupIds = _visibleAndroidGroupIdsForLocalIdentity(
        groups: groups,
        groupMembers: groupMembers,
      );
      var selectedKeyId = _selectedAndroidContactKeyId;
      var selectedGroupId = _selectedAndroidGroupId;
      if (selectedKeyId != null &&
          !contacts.any((contact) => contact.keyId == selectedKeyId)) {
        selectedKeyId = null;
      }
      if (selectedGroupId != null &&
          !visibleGroupIds.contains(selectedGroupId)) {
        selectedGroupId = null;
      }
      if (selectedGroupId != null) {
        selectedKeyId = null;
      }
      if (selectedKeyId == null && selectedGroupId == null) {
        if (contacts.isNotEmpty) {
          selectedKeyId = contacts.first.keyId;
        } else {
          final activeGroups = groups
              .where((group) => visibleGroupIds.contains(group.groupId))
              .toList();
          selectedGroupId = activeGroups.isEmpty
              ? null
              : activeGroups.first.groupId;
        }
      }
      final messageLimit = selectedGroupId != null
          ? _androidMessageLimitForGroup(selectedGroupId)
          : selectedKeyId == null
          ? 0
          : _androidMessageLimitForContact(selectedKeyId);
      final messages = selectedGroupId != null
          ? await db.getMessages(
              conversationId: selectedGroupId,
              limit: messageLimit,
            )
          : selectedKeyId == null
          ? const <AndroidMessageRecord>[]
          : await db.getMessages(
              peerKeyId: selectedKeyId,
              excludeGroupConversations: true,
              limit: messageLimit,
            );
      final messageCount = selectedGroupId != null
          ? await db.getMessageCount(conversationId: selectedGroupId)
          : selectedKeyId == null
          ? 0
          : await db.getMessageCount(
              peerKeyId: selectedKeyId,
              excludeGroupConversations: true,
            );
      final pendingCount =
          await db.getPendingMessageCount() +
          await db.getPendingGroupControlCount();
      final nextCounter = await db.getNextMessageCounter();
      final incomingCounts = await db.getIncomingMessageCountsByPeer();
      final incomingConversationCounts = await db
          .getIncomingMessageCountsByConversation();
      final sealHistory = await db.getSealedEnvelopes();

      final store = AndroidChatStore(
        contacts: contacts,
        messages: messages,
        nextMessageCounter: nextCounter,
        groups: groups,
        groupMembers: groupMembers,
      );

      if (!mounted) return;
      setState(() {
        _androidChatStore = store;
        _androidSealHistory = sealHistory;
        _androidMessageCount = messageCount;
        _androidPendingCount = pendingCount;
        _androidIncomingMessageCounts = incomingCounts;
        _androidIncomingConversationCounts = incomingConversationCounts;
        _androidMessageLimitsByContact.removeWhere(
          (keyId, _) => store.findContact(keyId) == null,
        );
        _androidMessageLimitsByGroup.removeWhere(
          (groupId, _) => !visibleGroupIds.contains(groupId),
        );
        for (final contact in store.contacts) {
          _androidMessageLimitsByContact.putIfAbsent(
            contact.keyId,
            () => _androidMessagesPageSize,
          );
        }
        for (final group in store.groups.where(
          (group) => visibleGroupIds.contains(group.groupId),
        )) {
          _androidMessageLimitsByGroup.putIfAbsent(
            group.groupId,
            () => _androidMessagesPageSize,
          );
        }
        final visibleMessageIds = store.messages
            .map((message) => message.envelopeId)
            .toSet();
        _selectedAndroidMessageIds.removeWhere(
          (id) => !visibleMessageIds.contains(id),
        );
        if (_selectedAndroidMessageIds.isEmpty) {
          _androidMessageSelectionMode = false;
        }
        _selectedAndroidContactKeyId = selectedKeyId;
        _selectedAndroidGroupId = selectedGroupId;
        if (_androidHomeTab == _AndroidHomeTab.chat &&
            selectedGroupId != null) {
          _markAndroidGroupMessagesSeen(selectedGroupId);
        } else if (_androidHomeTab == _AndroidHomeTab.chat &&
            selectedKeyId != null) {
          _markAndroidContactMessagesSeen(selectedKeyId);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _details = 'Android 聊天 store 读取失败：$error');
    }
  }

  Future<AndroidDbStore> _ensureAndroidDbStore() async {
    if (!_secureStore.isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    if (!AndroidDbStore.instance.isOpen) {
      final password = await _secureStore.getDatabasePassword();
      await AndroidDbStore.instance.init(password);
    }
    return AndroidDbStore.instance;
  }

  Future<void> _clearAndroidChatStorage({bool refresh = true}) async {
    await _secureStore.clearChatStore();
    if (_secureStore.isSupported) {
      final db = await _ensureAndroidDbStore();
      await db.clearAll();
    }
    if (mounted) {
      setState(() {
        _androidChatStore = AndroidChatStore.empty();
        _androidSealHistory = const [];
        _androidMessageLimitsByContact.clear();
        _androidMessageLimitsByGroup.clear();
        _androidSavedFilePreviewCache.clear();
        _androidIncomingMessageCounts = const <String, int>{};
        _androidIncomingConversationCounts = const <String, int>{};
        _androidMessageCount = 0;
        _androidPendingCount = 0;
        _selectedAndroidContactKeyId = null;
        _selectedAndroidGroupId = null;
        _androidMessageSelectionMode = false;
        _selectedAndroidMessageIds.clear();
      });
    }
    if (refresh) {
      await _refreshAndroidChatStore();
    }
  }

  SecureIdentityRecord _requireAndroidIdentity() {
    final identity = _secureIdentity;
    if (identity == null || identity.identityJson.trim().isEmpty) {
      throw const SecureStoreException('请先创建或恢复 Android 本机身份。');
    }
    return identity;
  }

  AndroidContactRecord _requireSelectedAndroidContact() {
    final keyId = _selectedAndroidContactKeyId;
    if (keyId == null) {
      throw const SecureStoreException('请先添加并选择联系人。');
    }
    final contact = _androidChatStore.findContact(keyId);
    if (contact == null) {
      throw const SecureStoreException('当前联系人不存在，请重新选择。');
    }
    return contact;
  }

  String _androidDeviceIdFor(SecureIdentityRecord identity) =>
      'android-${identity.keyId.substring(0, 8)}';

  String _serverUrl([String? serverUrl]) {
    final value = (serverUrl == null || serverUrl.trim().isEmpty)
        ? _configuredEnvelopeServerUrl
        : serverUrl.trim();
    if (value.isEmpty) {
      throw const EnvelopeServerException('请先在设置中填写同步服务入口。');
    }
    return _normalizeEnvelopeServerUrlInput(value);
  }

  Future<AndroidRelayHaClient> _getAndroidRelayClient() {
    return _androidRelayClient ??= () async {
      final bootstrap =
          (jsonDecode(
                    await rootBundle.loadString(
                      'assets/relay/ha-bootstrap.json',
                    ),
                  )
                  as Map)
              .cast<String, Object?>();
      final db = await _ensureAndroidDbStore();
      return AndroidRelayHaClient(
        adminPublic: bootstrap['admin_public'] as String,
        clusterId: bootstrap['cluster_id'] as String,
        bootstrapUrls: [
          _serverUrl(),
          ...(bootstrap['bootstrap_urls'] as List).cast<String>(),
        ].map((url) => url.endsWith('/') ? url : '$url/').toList(),
        native: _nativeCore.haV2,
        store: db.relayHa,
      );
    }();
  }

  EnvelopeServerClient _createEnvelopeServerClient([String? serverUrl]) {
    final identity = _requireAndroidIdentity();
    return AndroidRelayHaAdapter(
      _serverUrl(serverUrl),
      client: _getAndroidRelayClient,
      database: _ensureAndroidDbStore,
      identityJson: identity.identityJson,
      contactJson: _nativeCore.contactFromIdentityJson(identity.identityJson),
      actorId: identity.keyId,
      native: _nativeCore,
    );
  }

  String _androidServerRouteKeyForUrl(String serverUrl) {
    final value = serverUrl.trim();
    return _androidServerRouteKey(
      Uri.parse(value.endsWith('/') ? value : '$value/'),
    );
  }

  String _androidServerRouteKey(Uri uri) {
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo,
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: '/',
    ).toString();
  }

  void _recordAndroidServerEndpointRegistration(Uri baseUri, String ticket) {
    _androidServerRegistrationTicketByUri[_androidServerRouteKey(baseUri)] =
        ticket;
  }

  String _newServerSessionId() => 'session-${_randomOpaqueEnvelopeFileName()}';

  Future<DeviceRegistrationResponse> _registerAndroidServerEndpoint({
    String? serverUrl,
    bool updateDetails = false,
  }) async {
    await _refreshSecureIdentity(startP2p: false);
    final p2pStatus = await _ensureAndroidP2pListening(
      syncServerEndpoint: false,
    );
    return _publishAndroidServerEndpoint(
      p2pStatus: p2pStatus,
      serverUrl: serverUrl,
      updateDetails: updateDetails,
      force: true,
    );
  }

  Future<DeviceRegistrationResponse> _publishAndroidServerEndpoint({
    required AndroidP2pStatus p2pStatus,
    String? serverUrl,
    bool updateDetails = false,
    bool force = false,
  }) async {
    final client = _createEnvelopeServerClient(serverUrl);
    final requestedRouteKey = _androidServerRouteKey(client.baseUri);
    if (!force &&
        _androidServerRegistrationTicketByUri[requestedRouteKey] ==
            p2pStatus.ticket) {
      client.close();
      throw const EnvelopeServerException('当前直连状态已经同步到服务器。');
    }
    try {
      return await _publishAndroidServerEndpointWithClient(
        client: client,
        p2pStatus: p2pStatus,
        updateDetails: updateDetails,
      );
    } finally {
      client.close();
    }
  }

  NativeDeviceEndpointUpdate _createAndroidDeviceEndpointUpdate(
    AndroidP2pStatus p2pStatus,
  ) {
    final identity = _requireAndroidIdentity();
    return _nativeCore.createDeviceEndpointUpdate(
      identityJson: identity.identityJson,
      deviceId: _androidDeviceIdFor(identity),
      p2pTicket: p2pStatus.ticket,
      sessionId: _newServerSessionId(),
      ttlSeconds: 1800,
    );
  }

  Future<DeviceRegistrationResponse> _publishAndroidServerEndpointWithClient({
    required EnvelopeServerClient client,
    required AndroidP2pStatus p2pStatus,
    bool updateDetails = false,
  }) async {
    final endpoint = _createAndroidDeviceEndpointUpdate(p2pStatus);
    final response = await client.registerDevice(
      ownerContactJson: endpoint.ownerContactJson,
      endpointJson: endpoint.endpointJson,
    );
    _recordAndroidServerEndpointRegistration(
      client.activeBaseUri,
      p2pStatus.ticket,
    );
    if (mounted && updateDetails) {
      setState(() {
        _details = [
          '送达服务已同步。',
          'server: ${client.activeBaseUri}',
          'device: ${response.deviceId}',
        ].join('\n');
      });
    }
    return response;
  }

  Future<void> _ensureAndroidServerEndpointRegisteredForClient(
    EnvelopeServerClient client, {
    bool force = false,
  }) async {
    await _refreshSecureIdentity(startP2p: false);
    final p2pStatus = await _ensureAndroidP2pListening(
      syncServerEndpoint: false,
    );
    final routeKey = _androidServerRouteKey(client.activeBaseUri);
    if (!force &&
        _androidServerRegistrationTicketByUri[routeKey] == p2pStatus.ticket) {
      return;
    }
    await _publishAndroidServerEndpointWithClient(
      client: client,
      p2pStatus: p2pStatus,
    );
  }

  Future<T> _withAndroidServerRegistrationRetry<T>({
    required EnvelopeServerClient client,
    required Future<T> Function() request,
  }) async {
    try {
      return await request();
    } catch (error) {
      final missingRegistration =
          error is EnvelopeServerHttpException &&
              error.isMissingRegisteredDeviceRoute ||
          error is RelayHaException &&
              (error.reasonCode == 'NOT_REGISTERED' ||
                  error.code == 'NOT_REGISTERED');
      if (!missingRegistration) {
        rethrow;
      }
      await _ensureAndroidServerEndpointRegisteredForClient(
        client,
        force: true,
      );
      return request();
    }
  }

  Future<void> _syncAndroidServerEndpointIfNeeded(
    AndroidP2pStatus p2pStatus,
  ) async {
    final routeKey = _androidServerRouteKeyForUrl(_serverUrl());
    if (_androidServerRegistrationTicketByUri[routeKey] == p2pStatus.ticket ||
        _androidEndpointPublishInFlight) {
      return;
    }
    _androidEndpointPublishInFlight = true;
    try {
      await _publishAndroidServerEndpoint(p2pStatus: p2pStatus);
    } catch (error) {
      _appendDetails('送达服务自动同步失败：$error');
    } finally {
      _androidEndpointPublishInFlight = false;
    }
  }

  Future<void> _syncAndroidMessagesFromUi() => _run('立即同步消息', () async {
    try {
      await _registerAndroidServerEndpoint(updateDetails: false);
      await _pullAndroidServerMailbox(updateDetails: false);
      await _syncAndroidDeliveryReceipts();
      _markAndroidMessageSyncSucceeded();
      if (!mounted) return;
      setState(() {
        _details = ['消息同步完成。', 'server: ${_serverUrl()}'].join('\n');
      });
    } catch (error) {
      _markAndroidMessageSyncFailed(error);
      rethrow;
    }
  });

  String _contactTitle(AndroidContactRecord contact) => contact.displayLabel;

  String _contactSubtitle(AndroidContactRecord contact) {
    final parts = <String>[];
    if (contact.hasRemark && contact.displayName.trim().isNotEmpty) {
      parts.add('原名 ${contact.displayName}');
    }
    return parts.join(' / ');
  }

  AndroidContactRecord? get _selectedAndroidContact {
    final keyId = _selectedAndroidContactKeyId;
    if (keyId == null) return null;
    return _androidChatStore.findContact(keyId);
  }

  AndroidGroupRecord? get _selectedAndroidGroup {
    final groupId = _selectedAndroidGroupId;
    if (groupId == null) return null;
    return _androidChatStore.findGroup(groupId);
  }

  bool get _hasSelectedAndroidConversation =>
      _selectedAndroidContact != null || _selectedAndroidGroup != null;

  List<AndroidMessageRecord> _androidMessagesForSelectedContact() {
    final keyId = _selectedAndroidContactKeyId;
    if (keyId == null) return const <AndroidMessageRecord>[];
    return _androidChatStore.messages
        .where(
          (message) =>
              message.peerKeyId == keyId &&
              _androidChatStore.findGroup(message.conversationId) == null,
        )
        .toList(growable: false);
  }

  List<AndroidMessageRecord> _androidMessagesForSelectedConversation() {
    final groupId = _selectedAndroidGroupId;
    if (groupId != null) {
      return _androidChatStore.messages
          .where((message) => message.conversationId == groupId)
          .toList(growable: false);
    }
    return _androidMessagesForSelectedContact();
  }

  AndroidGroupMemberRecord? _pendingAndroidGroupInviteForLocalIdentity(
    AndroidGroupRecord group,
  ) {
    if (!group.isActive) return null;
    final identityKeyId = _secureIdentity?.keyId ?? '';
    if (identityKeyId.isEmpty) return null;
    final members = _androidChatStore.membersForGroup(group.groupId);
    if (androidGroupShouldAutoDissolveForMembers(members)) return null;
    final self = _androidChatStore.findGroupMember(
      group.groupId,
      identityKeyId,
    );
    if (self == null || !self.isPending) return null;
    return self;
  }

  String _androidGroupControlMessageDetail({
    required String type,
    required String groupId,
  }) => 'group-control:$type:$groupId';

  _AndroidGroupControlMessageRef? _androidGroupControlMessageRefFor(
    AndroidMessageRecord message,
  ) {
    final detail = message.deliveryDetail?.trim() ?? '';
    if (!detail.startsWith('group-control:')) return null;
    final parts = detail.split(':');
    if (parts.length != 3) return null;
    final type = parts[1].trim();
    final groupId = parts[2].trim();
    if (type.isEmpty || groupId.isEmpty) return null;
    return _AndroidGroupControlMessageRef(type: type, groupId: groupId);
  }

  List<AndroidGroupRecord> _pendingAndroidGroupInvitesFromContact(
    AndroidContactRecord contact,
    Iterable<AndroidMessageRecord> visibleMessages,
  ) {
    final messageInviteGroupIds = <String>{};
    for (final message in visibleMessages) {
      final ref = _androidGroupControlMessageRefFor(message);
      if (ref != null && ref.type == 'group_invite') {
        messageInviteGroupIds.add(ref.groupId);
      }
    }
    final identityKeyId = _secureIdentity?.keyId ?? '';
    if (identityKeyId.isEmpty) return const <AndroidGroupRecord>[];
    final invites = <AndroidGroupRecord>[];
    for (final group in _androidChatStore.groups) {
      if (messageInviteGroupIds.contains(group.groupId)) continue;
      final self = _androidChatStore.findGroupMember(
        group.groupId,
        identityKeyId,
      );
      if (self == null || !self.isPending) continue;
      final inviterKeyId = (self.invitedByKeyId?.trim().isNotEmpty ?? false)
          ? self.invitedByKeyId!.trim()
          : group.ownerKeyId;
      if (inviterKeyId != contact.keyId) continue;
      if (_pendingAndroidGroupInviteForLocalIdentity(group) == null) continue;
      invites.add(group);
    }
    invites.sort((a, b) => b.updatedAtUnixMs.compareTo(a.updatedAtUnixMs));
    return invites;
  }

  int _androidMessageLimitForContact(String keyId) =>
      _androidMessageLimitsByContact[keyId] ?? _androidMessagesPageSize;

  int _androidMessageLimitForGroup(String groupId) =>
      _androidMessageLimitsByGroup[groupId] ?? _androidMessagesPageSize;

  int _incomingMessageCountFor(String keyId) {
    return _androidIncomingMessageCounts[keyId] ?? 0;
  }

  int _incomingConversationCountFor(String conversationId) {
    return _androidIncomingConversationCounts[conversationId] ?? 0;
  }

  int _newIncomingMessageCountFor(AndroidContactRecord contact) {
    return _incomingMessageCountFor(contact.keyId);
  }

  int _newIncomingGroupMessageCountFor(AndroidGroupRecord group) {
    return _incomingConversationCountFor(group.groupId);
  }

  void _markAndroidContactMessagesSeen(String keyId) {
    _androidIncomingMessageCounts = {
      ..._androidIncomingMessageCounts,
      keyId: 0,
    };
    if (AndroidDbStore.instance.isOpen) {
      unawaited(
        AndroidDbStore.instance.markIncomingMessagesRead(peerKeyId: keyId),
      );
    }
  }

  void _markAndroidGroupMessagesSeen(String groupId) {
    _androidIncomingConversationCounts = {
      ..._androidIncomingConversationCounts,
      groupId: 0,
    };
    if (AndroidDbStore.instance.isOpen) {
      unawaited(
        AndroidDbStore.instance.markIncomingMessagesRead(
          conversationId: groupId,
        ),
      );
    }
  }

  String _androidAvatarSeedFor(AndroidContactRecord contact) {
    return contact.keyId.isEmpty ? _contactTitle(contact) : contact.keyId;
  }

  List<AndroidContactRecord> _androidKnownContactCandidates() {
    final seen = <String>{};
    final candidates = <AndroidContactRecord>[];
    for (final contact in _androidChatStore.contacts) {
      if (seen.add(contact.keyId)) {
        candidates.add(contact);
      }
    }
    for (final member in _androidChatStore.groupMembers) {
      if (member.contactJson.trim().isEmpty) continue;
      if (seen.add(member.keyId)) {
        candidates.add(member.toContactRecord());
      }
    }
    return candidates;
  }

  String _androidGroupTitle(AndroidGroupRecord group) => group.displayName;

  String _androidGroupPolicyLabel(BuildContext context, String policy) {
    final l10n = context.l10n;
    return switch (AndroidGroupPolicy.normalize(policy)) {
      AndroidGroupPolicy.verified => l10n.verifiedGroup,
      AndroidGroupPolicy.consensus => l10n.consensusGroup,
      _ => l10n.normalGroup,
    };
  }

  String _androidGroupSubtitle(BuildContext context, AndroidGroupRecord group) {
    final members = _androidChatStore.membersForGroup(group.groupId);
    return context.l10n.groupMembersSummary(
      androidGroupRemainingMemberCount(members),
      _androidGroupPolicyLabel(context, group.policy),
    );
  }

  List<String> _androidGroupDissolutionReasonsFromPayload(
    Map<String, Object?> payload,
    Iterable<AndroidGroupMemberRecord> members,
  ) {
    final rawReasons = payload['dissolution_reasons'];
    final reasons = <String>[];
    if (rawReasons is List) {
      for (final item in rawReasons) {
        final normalized = AndroidGroupDissolutionReason.normalize(
          item.toString(),
        );
        if (normalized != null && !reasons.contains(normalized)) {
          reasons.add(normalized);
        }
      }
    }
    final rawReason = payload['dissolution_reason'];
    if (rawReason != null) {
      final normalized = AndroidGroupDissolutionReason.normalize(
        rawReason.toString(),
      );
      if (normalized != null && !reasons.contains(normalized)) {
        reasons.add(normalized);
      }
    }
    if (reasons.isNotEmpty) return reasons;
    return androidGroupDissolutionReasonCodes(members);
  }

  String _androidGroupDissolutionReasonLabel(String reason) {
    return switch (AndroidGroupDissolutionReason.normalize(reason)) {
      AndroidGroupDissolutionReason.ownerLeft => '群主退群',
      AndroidGroupDissolutionReason.minimumMemberCount => '群人数低于最低 3 人要求',
      _ => '未知原因',
    };
  }

  String _androidGroupDissolutionReasonText(Iterable<String> reasons) {
    final labels = <String>[];
    for (final reason in reasons) {
      final label = _androidGroupDissolutionReasonLabel(reason);
      if (!labels.contains(label)) labels.add(label);
    }
    return labels.join('；');
  }

  String _androidGroupDissolvedText(
    String prefix,
    Iterable<String> reasons, {
    String suffix = '',
  }) {
    final reasonText = _androidGroupDissolutionReasonText(reasons);
    final reasonSuffix = reasonText.isEmpty ? '' : '：$reasonText';
    return '$prefix。群组已自动解散$reasonSuffix。$suffix'.trim();
  }

  String _androidConversationFilterLabel(
    BuildContext context,
    _AndroidConversationFilter filter,
  ) {
    final l10n = context.l10n;
    return switch (filter) {
      _AndroidConversationFilter.all => l10n.allConversations,
      _AndroidConversationFilter.contacts => l10n.directChats,
      _AndroidConversationFilter.groups => l10n.groupChats,
    };
  }

  List<_AndroidConversationItem> _androidConversationItems({
    required List<AndroidContactRecord> contacts,
    required List<AndroidGroupRecord> groups,
    required _AndroidConversationFilter filter,
  }) {
    final items = <_AndroidConversationItem>[
      if (filter != _AndroidConversationFilter.groups)
        for (final contact in contacts)
          _AndroidConversationItem.contact(
            contact,
            sortUnixMs: _androidLatestContactActivityUnixMs(contact),
          ),
      if (filter != _AndroidConversationFilter.contacts)
        for (final group in groups)
          _AndroidConversationItem.group(
            group,
            sortUnixMs: _androidLatestGroupActivityUnixMs(group),
          ),
    ];
    items.sort((a, b) {
      final timeCompare = b.sortUnixMs.compareTo(a.sortUnixMs);
      if (timeCompare != 0) return timeCompare;
      return a.title.compareTo(b.title);
    });
    return items;
  }

  int _androidLatestContactActivityUnixMs(AndroidContactRecord contact) {
    var latest = contact.p2pTicketUpdatedAtUnixMs ?? 0;
    for (final message in _androidChatStore.messages) {
      if (message.peerKeyId != contact.keyId) continue;
      if (_androidChatStore.findGroup(message.conversationId) != null) {
        continue;
      }
      latest = max(latest, message.createdAtUnixMs);
    }
    return latest;
  }

  int _androidLatestGroupActivityUnixMs(AndroidGroupRecord group) {
    var latest = max(group.updatedAtUnixMs, group.createdAtUnixMs);
    for (final message in _androidChatStore.messages) {
      if (message.conversationId == group.groupId) {
        latest = max(latest, message.createdAtUnixMs);
      }
    }
    return latest;
  }

  Set<String> _visibleAndroidGroupIdsForLocalIdentity({
    required List<AndroidGroupRecord> groups,
    required List<AndroidGroupMemberRecord> groupMembers,
  }) {
    final identityKeyId = _secureIdentity?.keyId ?? '';
    if (identityKeyId.isEmpty) return const <String>{};
    final membersByGroup = <String, List<AndroidGroupMemberRecord>>{};
    for (final member in groupMembers) {
      membersByGroup.putIfAbsent(member.groupId, () => []).add(member);
    }
    final visible = <String>{};
    for (final group in groups) {
      if (!group.isActive) continue;
      final members = membersByGroup[group.groupId] ?? const [];
      if (androidGroupIsVisibleForLocalMember(members, identityKeyId)) {
        visible.add(group.groupId);
      }
    }
    return visible;
  }

  Set<String> _androidGroupIdsToDissolveOnRefresh({
    required List<AndroidGroupRecord> groups,
    required List<AndroidGroupMemberRecord> groupMembers,
  }) {
    final membersByGroup = <String, List<AndroidGroupMemberRecord>>{};
    for (final member in groupMembers) {
      membersByGroup.putIfAbsent(member.groupId, () => []).add(member);
    }
    final dissolved = <String>{};
    for (final group in groups) {
      if (!group.isActive) continue;
      final members = membersByGroup[group.groupId] ?? const [];
      if (androidGroupShouldAutoDissolveForMembers(members)) {
        dissolved.add(group.groupId);
      }
    }
    return dissolved;
  }

  IconData _androidGroupPolicyIcon(String policy) {
    return switch (AndroidGroupPolicy.normalize(policy)) {
      AndroidGroupPolicy.verified => Icons.fingerprint,
      AndroidGroupPolicy.consensus => Icons.how_to_vote_outlined,
      _ => Icons.groups_outlined,
    };
  }

  void _openAndroidChat(AndroidContactRecord contact) {
    setState(() {
      _androidMessageLimitsByContact.putIfAbsent(
        contact.keyId,
        () => _androidMessagesPageSize,
      );
      _selectedAndroidContactKeyId = contact.keyId;
      _selectedAndroidGroupId = null;
      _androidHomeTab = _AndroidHomeTab.chat;
      _androidMessageSelectionMode = false;
      _selectedAndroidMessageIds.clear();
      _markAndroidContactMessagesSeen(contact.keyId);
    });
    unawaited(_refreshAndroidChatStore());
  }

  void _openAndroidGroupChat(AndroidGroupRecord group) {
    setState(() {
      _androidMessageLimitsByGroup.putIfAbsent(
        group.groupId,
        () => _androidMessagesPageSize,
      );
      _selectedAndroidContactKeyId = null;
      _selectedAndroidGroupId = group.groupId;
      _androidHomeTab = _AndroidHomeTab.chat;
      _androidMessageSelectionMode = false;
      _selectedAndroidMessageIds.clear();
      _markAndroidGroupMessagesSeen(group.groupId);
    });
    unawaited(_refreshAndroidChatStore());
  }

  Future<void> _loadEarlierAndroidMessagesForSelectedConversation() async {
    final selectedGroupId = _selectedAndroidGroupId;
    final selectedKeyId = _selectedAndroidContactKeyId;
    if ((selectedKeyId == null && selectedGroupId == null) ||
        _androidLoadingEarlierMessages) {
      return;
    }
    if (_androidMessageCount <= _androidChatStore.messages.length) return;

    _androidLoadingEarlierMessages = true;
    if (mounted) {
      setState(() {
        if (selectedGroupId != null) {
          _androidMessageLimitsByGroup[selectedGroupId] =
              _androidMessageLimitForGroup(selectedGroupId) +
              _androidMessagesPageSize;
        } else if (selectedKeyId != null) {
          _androidMessageLimitsByContact[selectedKeyId] =
              _androidMessageLimitForContact(selectedKeyId) +
              _androidMessagesPageSize;
        }
      });
    }
    try {
      await _refreshAndroidChatStore();
    } finally {
      _androidLoadingEarlierMessages = false;
    }
  }

  void _selectAndroidHomeTab(_AndroidHomeTab tab) {
    if (tab != _AndroidHomeTab.settings) {
      _clearRecoveryPhrase(refresh: false);
    }
    setState(() {
      _androidHomeTab = tab;
      if (tab != _AndroidHomeTab.chat) {
        _androidMessageSelectionMode = false;
        _selectedAndroidMessageIds.clear();
      } else if (_selectedAndroidGroupId != null) {
        _markAndroidGroupMessagesSeen(_selectedAndroidGroupId!);
      } else if (_selectedAndroidContactKeyId != null) {
        _markAndroidContactMessagesSeen(_selectedAndroidContactKeyId!);
      }
    });
  }

  Map<String, Object?> _p2pTicketDebugJson(String? ticket) {
    final parsed = AndroidP2pTicket.tryParse(ticket);
    if (parsed == null) {
      return {'available': false, 'state': 'missing'};
    }
    final now = DateTime.now();
    return {
      'available': true,
      'state': parsed.isExpiredAt(now) ? 'expired' : 'fresh',
      ...parsed.toJson(now: now),
    };
  }

  Future<AndroidP2pStatus> _ensureAndroidP2pListening({
    bool updateDetails = false,
    bool syncServerEndpoint = true,
  }) async {
    final identity = _requireAndroidIdentity();
    final previousTicket = _androidP2pTicket;
    final status = await _androidP2p.start(
      deviceId: _androidDeviceIdFor(identity),
      onEnvelope: _handleAndroidP2pEnvelope,
    );
    if (!mounted) return status;
    setState(() {
      _androidP2pListening = status.listening;
      _androidP2pTicket = status.ticket;
      _androidP2pAddrs = status.addrs;
      _androidP2pPort = status.port;
      if (updateDetails) {
        _details = [
          previousTicket == null || previousTicket == status.ticket
              ? '送达服务已启动。'
              : '送达服务已自动刷新。',
        ].join('\n');
      }
    });
    if (syncServerEndpoint) {
      await _syncAndroidServerEndpointIfNeeded(status);
    }
    return status;
  }

  Future<AndroidP2pStatus> _restartAndroidP2pListening({
    bool updateDetails = false,
    bool syncServerEndpoint = true,
  }) async {
    final identity = _requireAndroidIdentity();
    final status = await _androidP2p.restart(
      deviceId: _androidDeviceIdFor(identity),
      onEnvelope: _handleAndroidP2pEnvelope,
    );
    if (!mounted) return status;
    setState(() {
      _androidP2pListening = status.listening;
      _androidP2pTicket = status.ticket;
      _androidP2pAddrs = status.addrs;
      _androidP2pPort = status.port;
      if (updateDetails) {
        _details = '送达服务已刷新。';
      }
    });
    if (syncServerEndpoint) {
      await _syncAndroidServerEndpointIfNeeded(status);
    }
    return status;
  }

  Future<AndroidP2pAck> _handleAndroidP2pEnvelope(
    Uint8List envelopeBytes,
  ) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    try {
      final result = await _importAndroidOpaqueEnvelopeBytes(
        envelopeBytes,
        updateDetails: false,
      );
      final message = result.message;
      if (mounted) {
        setState(() {
          _details = [
            result.duplicate ? '直连收到重复消息，已忽略。' : '直连收到并解密消息。',
            'sender: ${message.peerDisplayName} / ${message.peerKeyId}',
            'text: ${message.text}',
          ].join('\n');
        });
      }
      return AndroidP2pAck.ok(
        result.receiptEnvelopeId ?? message.envelopeId,
        result.duplicate
            ? 'duplicate ignored'
            : 'imported from ${message.peerDisplayName}',
        recipientResult: await _signedAndroidRecipientResult(
          message,
          envelopeId: result.receiptEnvelopeId,
        ),
        recipientResults: await _signedAndroidRelatedFileResults(
          message,
          result.receiptEnvelopeId ?? message.envelopeId,
        ),
      );
    } catch (error) {
      return AndroidP2pAck.error('', error.toString());
    }
  }

  Future<Map<String, Object?>?> _signedAndroidRecipientResult(
    AndroidMessageRecord message, {
    String? envelopeId,
  }) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final pending = await db.relayHa.incomingResult(
      senderKeyId: message.peerKeyId,
      recipientKeyId: identity.keyId,
      envelopeId: envelopeId ?? message.envelopeId,
    );
    if (pending == null) return null;
    final persisted = pending['signed_result_json'];
    if (persisted is String) {
      return (jsonDecode(persisted) as Map).cast<String, Object?>();
    }
    final descriptor = (jsonDecode(pending['descriptor_json'] as String) as Map)
        .cast<String, Object?>();
    final signed = _nativeCore.haV2({
      'op': 'sign_result',
      'identity_json': identity.identityJson,
      'result': {...descriptor, 'signature': ''},
    });
    await db.relayHa.attachSignedResult(
      jsonEncode(signed),
      verify: (json) async {
        return _nativeCore.haV2({
          'op': 'verify_result',
          'result': jsonDecode(json),
          'contact': jsonDecode(
            _nativeCore.contactFromIdentityJson(identity.identityJson),
          ),
          'binding': {
            'operation_id': 'recipient-result',
            for (final key in [
              'sender_key_id',
              'recipient_key_id',
              'envelope_id',
              'envelope_sha256',
            ])
              key: descriptor[key],
            'not_after': '18446744073709551615',
          },
        });
      },
    );
    return signed;
  }

  Future<List<Map<String, Object?>>> _signedAndroidRelatedFileResults(
    AndroidMessageRecord message,
    String envelopeId,
  ) async {
    final db = await _ensureAndroidDbStore();
    final identity = _requireAndroidIdentity();
    final rows = await db.relayHa.relatedFileResults(
      envelopeId,
      message.peerKeyId,
      identity.keyId,
    );
    final results = <Map<String, Object?>>[];
    for (final row in rows) {
      final signed = await _signedAndroidRecipientResult(
        message,
        envelopeId: row['envelope_id'] as String,
      );
      if (signed != null) results.add(signed);
    }
    return results;
  }

  String _encodeAndroidIntroQrPayload({
    required String bundleJson,
    String? sessionId,
    String? serverUrl,
  }) {
    final bundle = jsonDecode(bundleJson);
    final encodedPayload = sessionId == null || sessionId.trim().isEmpty
        ? bundle
        : {
            'version': 2,
            'bundle': bundle,
            'intro_session_id': sessionId.trim(),
            if (serverUrl != null && serverUrl.trim().isNotEmpty)
              'server_url': serverUrl.trim(),
          };
    final compressed = gzip.encode(utf8.encode(jsonEncode(encodedPayload)));
    final encoded = base64UrlEncode(compressed).replaceAll('=', '');
    return '$_androidIntroQrPrefix$encoded';
  }

  _DecodedAndroidIntroQrPayload _decodeAndroidIntroQrPayload(String payload) {
    final text = payload.trim();
    String decodedText;
    if (text.startsWith(_androidIntroQrPrefix)) {
      final encoded = text.substring(_androidIntroQrPrefix.length).trim();
      if (encoded.isEmpty) {
        throw const SecureStoreException('二维码载荷为空。');
      }
      try {
        final compressed = base64Url.decode(base64Url.normalize(encoded));
        decodedText = utf8.decode(gzip.decode(compressed));
      } catch (error) {
        throw SecureStoreException('二维码载荷无法解码：$error');
      }
    } else if (text.startsWith('{')) {
      decodedText = text;
    } else {
      throw const SecureStoreException('这不是 Envelope 临时加好友二维码。');
    }
    final decoded = jsonDecode(decodedText);
    if (decoded is Map) {
      final map = decoded.cast<String, Object?>();
      final bundle = map['bundle'];
      if (bundle is Map) {
        return _DecodedAndroidIntroQrPayload(
          bundleJson: jsonEncode(bundle),
          sessionId: map['intro_session_id']?.toString(),
          serverUrl: map['server_url']?.toString(),
        );
      }
    }
    return _DecodedAndroidIntroQrPayload(bundleJson: decodedText);
  }

  String _formatAndroidFingerprint(String keyId) {
    final source = keyId.trim();
    final clipped = source.length > 32 ? source.substring(0, 32) : source;
    final parts = <String>[];
    for (var index = 0; index < clipped.length; index += 4) {
      final end = min(index + 4, clipped.length);
      parts.add(clipped.substring(index, end));
    }
    return parts.join(' ');
  }

  String _formatAndroidFingerprintBlock(String keyId) {
    final parts = _formatAndroidFingerprint(keyId).split(' ');
    if (parts.length <= 4) return parts.join(' ');
    return [parts.take(4).join(' '), parts.skip(4).join(' ')].join('\n');
  }

  Future<void> _showAndroidIntroQr() => _run('生成临时二维码', () async {
    final intro = await _createAndroidIntroBundle(
      ttlSeconds: _androidIntroQrTtlSeconds,
    );
    String? sessionId;
    String? serverUrl;
    String? sessionWarning;
    EnvelopeServerClient? client;
    try {
      client = _createEnvelopeServerClient();
      sessionId = _newServerSessionId();
      await client.publishIntroSession(
        sessionId: sessionId,
        ownerBundleJson: intro.bundleJson,
      );
      serverUrl = client.activeBaseUri.toString();
    } catch (error) {
      client?.close();
      client = null;
      sessionId = null;
      sessionWarning = '互加通道暂不可用：$error\n该二维码仍可被对方单向扫描添加。';
    }
    final payload = _encodeAndroidIntroQrPayload(
      bundleJson: intro.bundleJson,
      sessionId: sessionId,
      serverUrl: serverUrl,
    );
    if (!mounted) return;
    setState(() {
      _details = [
        '临时加好友二维码已生成。',
        'contact: ${intro.displayName} / ${intro.keyId}',
        'device: ${intro.deviceId}',
        if (sessionId != null) '互加 session: $sessionId',
        ?sessionWarning,
        'expires: ${DateTime.fromMillisecondsSinceEpoch(intro.expiresAtUnixMs).toLocal()}',
      ].join('\n');
    });
    Timer? pollTimer;
    var dialogOpen = true;
    var pollInFlight = false;
    var pollStatus = sessionId == null
        ? '互加通道未启用；如需双方都添加，请反向再扫一次。'
        : '等待对方扫描并发送互加请求。';
    NativeIntroBundle? pendingResponder;
    Future<void> pollIntroResponse(StateSetter setDialogState) async {
      final activeClient = client;
      final activeSessionId = sessionId;
      if (!dialogOpen ||
          pollInFlight ||
          activeClient == null ||
          activeSessionId == null ||
          pendingResponder != null) {
        return;
      }
      pollInFlight = true;
      try {
        final response = await activeClient.pollIntroSessionResponse(
          sessionId: activeSessionId,
        );
        final responderBundleJson = response.responderBundleJson;
        if (responderBundleJson != null && responderBundleJson.isNotEmpty) {
          final responder = _nativeCore.verifyIntroBundle(responderBundleJson);
          if (responder.keyId == intro.keyId) {
            throw const SecureStoreException('互加请求不能来自当前身份。');
          }
          if (!dialogOpen) return;
          setDialogState(() {
            pendingResponder = responder;
            pollStatus = '收到互加请求，请核对 fingerprint 后确认。';
          });
          pollTimer?.cancel();
        }
      } catch (error) {
        if (!dialogOpen) return;
        setDialogState(() {
          pollStatus = '等待互加请求；最近一次检查失败：$error';
        });
      } finally {
        pollInFlight = false;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (pollTimer == null && client != null && sessionId != null) {
            unawaited(pollIntroResponse(setDialogState));
            pollTimer = Timer.periodic(
              const Duration(seconds: 3),
              (_) => unawaited(pollIntroResponse(setDialogState)),
            );
          }
          final responder = pendingResponder;
          final mediaSize = MediaQuery.sizeOf(context);
          final dialogWidth = min(360.0, mediaSize.width - 96);
          final qrSize = min(208.0, dialogWidth - 44);
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 28,
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
            contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
            title: const Text('临时加好友二维码'),
            content: SizedBox(
              width: dialogWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: qrSize + 20,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xffd9e2de)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: SizedBox.square(
                              dimension: qrSize,
                              child: QrImageView(
                                data: payload,
                                version: QrVersions.auto,
                                size: qrSize,
                                padding: EdgeInsets.zero,
                                backgroundColor: Colors.white,
                                errorCorrectionLevel: QrErrorCorrectLevel.M,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      [
                        '联系人：${intro.displayName}',
                        '指纹：${_formatAndroidFingerprintBlock(intro.keyId)}',
                        '有效期：${DateTime.fromMillisecondsSinceEpoch(intro.expiresAtUnixMs).toLocal()}',
                        if (sessionId != null) '支持对方扫码后发送互加请求。',
                        ?sessionWarning,
                        '截图发送时，请让对方另行比对指纹。',
                      ].join('\n'),
                      style: const TextStyle(fontSize: 12, height: 1.3),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      pollStatus,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff65716d),
                      ),
                    ),
                    if (responder != null) ...[
                      const SizedBox(height: 10),
                      SelectableText(
                        [
                          '对方：${responder.displayName}',
                          '指纹：${_formatAndroidFingerprintBlock(responder.keyId)}',
                          'device：${responder.deviceId}',
                        ].join('\n'),
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: payload));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('二维码内容已复制')));
                },
                child: const Text('复制二维码内容'),
              ),
              if (sessionId != null && responder == null)
                TextButton(
                  onPressed: () => unawaited(pollIntroResponse(setDialogState)),
                  child: const Text('检查互加请求'),
                ),
              if (responder != null)
                FilledButton(
                  onPressed: () async {
                    await _saveAndroidIntroBundle(responder);
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    if (!mounted) return;
                    setState(() {
                      _details = [
                        '已确认互加并保存对方联系人。',
                        'contact: ${responder.displayName} / ${responder.keyId}',
                        'fingerprint: ${_formatAndroidFingerprint(responder.keyId)}',
                      ].join('\n');
                    });
                  },
                  child: const Text('确认添加对方'),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(() {
      dialogOpen = false;
      pollTimer?.cancel();
      client?.close();
    });
  });

  Future<void> _scanAndroidIntroQr() => _run('扫描临时二维码', () async {
    if (!mounted) return;
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (context) => const _AndroidIntroQrScanPage()),
    );
    if (payload == null || payload.trim().isEmpty) return;
    await _importAndroidIntroQrPayload(payload, source: '二维码');
  });

  Future<void> _importAndroidIntroQrPayload(
    String payload, {
    required String source,
  }) async {
    final decodedPayload = _decodeAndroidIntroQrPayload(payload);
    final intro = _nativeCore.verifyIntroBundle(decodedPayload.bundleJson);
    if (!mounted) return;
    final existing = _androidChatStore.findContact(intro.keyId);
    final sameNameDifferentKey = _androidChatStore.contacts.any(
      (contact) =>
          contact.keyId != intro.keyId &&
          contact.displayLabel == intro.displayName,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '确认添加联系人' : '确认更新联系人'),
        content: SelectableText(
          [
            '来源: $source',
            '联系人: ${intro.displayName}',
            'fingerprint: ${_formatAndroidFingerprint(intro.keyId)}',
            'device: ${intro.deviceId}',
            '有效期: ${DateTime.fromMillisecondsSinceEpoch(intro.expiresAtUnixMs).toLocal()}',
            if (intro.p2pTicket != null && intro.p2pTicket!.isNotEmpty)
              '包含短期直连信息',
            if (decodedPayload.sessionId != null) '可向对方发送互加请求，对方确认后会保存你。',
            if (existing != null) '该联系人已存在，将只更新短期路由信息。',
            if (sameNameDifferentKey) '注意：已有同名联系人，但 fingerprint 不同。',
            '截图来源请通过可信渠道比对 fingerprint。',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认保存'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (!mounted) return;
      setState(() {
        _details = [
          '已验证 $source，但未保存联系人。',
          'contact: ${intro.displayName} / ${intro.keyId}',
        ].join('\n');
      });
      return;
    }
    await _saveAndroidIntroBundle(intro);
    if (decodedPayload.sessionId != null) {
      try {
        await _respondAndroidIntroSession(decodedPayload);
        _appendDetails('已向对方发送互加请求；对方确认后会保存你。');
      } catch (error) {
        _appendDetails('联系人已保存，但互加请求发送失败：$error');
      }
    }
    if (!mounted) return;
    setState(() {
      _details = [
        '已通过$source保存联系人。',
        'contact: ${intro.displayName} / ${intro.keyId}',
        'fingerprint: ${_formatAndroidFingerprint(intro.keyId)}',
        'device: ${intro.deviceId}',
        if (intro.p2pTicket != null && intro.p2pTicket!.isNotEmpty)
          '已保存短期直连信息。',
        if (decodedPayload.sessionId != null) '已发送互加请求，等待对方确认。',
      ].join('\n');
    });
  }

  Future<void> _respondAndroidIntroSession(
    _DecodedAndroidIntroQrPayload decodedPayload,
  ) async {
    final sessionId = decodedPayload.sessionId?.trim();
    if (sessionId == null || sessionId.isEmpty) return;
    final myBundle = await _createAndroidIntroBundle(
      ttlSeconds: _androidIntroQrTtlSeconds,
    );
    final client = _createEnvelopeServerClient(decodedPayload.serverUrl);
    try {
      await client.respondIntroSession(
        sessionId: sessionId,
        responderBundleJson: myBundle.bundleJson,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _addAndroidContactFromClipboard() => _run('从剪贴板添加联系人', () async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      throw const SecureStoreException('剪贴板里没有 contact 或临时二维码载荷。');
    }
    if (text.startsWith(_androidIntroQrPrefix)) {
      await _importAndroidIntroQrPayload(text, source: '剪贴板二维码载荷');
      return;
    }
    await _saveAndroidContactJson(text);
  });

  Future<void> _saveAndroidContactJson(String contactJson) async {
    final parsed = _nativeCore.parseContact(contactJson);
    final contact = AndroidContactRecord(
      keyId: parsed.keyId,
      displayName: parsed.displayName,
      contactJson: parsed.contactJson,
    );
    await _saveAndroidContactRecord(contact);
  }

  Future<void> _saveAndroidIntroBundle(NativeIntroBundle intro) async {
    final parsed = _nativeCore.parseContact(intro.contactJson);
    final contact = AndroidContactRecord(
      keyId: parsed.keyId,
      displayName: parsed.displayName,
      contactJson: parsed.contactJson,
      deviceId: intro.deviceId,
      p2pTicket: intro.p2pTicket,
      p2pTicketUpdatedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveAndroidContactRecord(contact);
  }

  Future<void> _saveAndroidContactRecord(AndroidContactRecord contact) async {
    final db = await _ensureAndroidDbStore();
    await db.upsertContact(contact);
    final savedContact = await db.getContact(contact.keyId) ?? contact;
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _selectedAndroidContactKeyId = savedContact.keyId;
      _selectedAndroidGroupId = null;
      _details = [
        '已保存联系人：${_contactTitle(savedContact)} / ${savedContact.keyId}',
        if (savedContact.hasRemark) '原名: ${savedContact.displayName}',
      ].join('\n');
    });
  }

  AndroidContactRecord _currentAndroidContactRecord() {
    final identity = _requireAndroidIdentity();
    final contactJson = _nativeCore.contactFromIdentityJson(
      identity.identityJson,
    );
    final parsed = _nativeCore.parseContact(contactJson);
    return AndroidContactRecord(
      keyId: parsed.keyId,
      displayName: parsed.displayName,
      contactJson: parsed.contactJson,
    );
  }

  String _newAndroidGroupId() => 'grp-${_randomAndroidTransferId()}';

  String _newAndroidGroupEventId() => 'gvt-${_randomAndroidTransferId()}';

  AndroidGroupMemberRecord _memberFromContact({
    required String groupId,
    required AndroidContactRecord contact,
    required String role,
    required String status,
    required String trustState,
    required int now,
    String? invitedByKeyId,
  }) {
    return AndroidGroupMemberRecord(
      groupId: groupId,
      keyId: contact.keyId,
      displayName: contact.displayLabel,
      contactJson: contact.contactJson,
      role: role,
      status: status,
      trustState: trustState,
      invitedByKeyId: invitedByKeyId,
      joinedAtUnixMs: status == AndroidGroupMemberStatus.active ? now : null,
      updatedAtUnixMs: now,
    );
  }

  Map<String, Object?> _groupControlPayload({
    required String type,
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required int now,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final identity = _requireAndroidIdentity();
    final payload = <String, Object?>{
      'version': 1,
      'type': type,
      'event_id': _newAndroidGroupEventId(),
      'actor_key_id': identity.keyId,
      'created_at_unix_ms': now,
      'group': group.toJson(),
      'members': members.map((member) => member.toJson()).toList(),
      ...extra,
    };
    final signature = _nativeCore.signContextPayload(
      identityJson: identity.identityJson,
      context: _androidGroupEventSignatureContext,
      payload: _androidGroupEventSignaturePayloadJson(payload),
    );
    if (signature.keyId != identity.keyId) {
      throw const SecureStoreException('群事件签名身份不匹配。');
    }
    return {...payload, 'signature': signature.signature};
  }

  String _androidGroupEventSignaturePayloadJson(Map<String, Object?> payload) {
    final unsigned = Map<String, Object?>.of(payload)..remove('signature');
    return jsonEncode(unsigned);
  }

  void _validateAndroidGroupControlSignature(
    Map<String, Object?> payload,
    AndroidContactRecord senderContact,
  ) {
    final signature = payload['signature']?.toString() ?? '';
    if (signature.isEmpty) {
      throw const AndroidInvalidEnvelopePayloadException(
        '群组事件缺少 event signature。',
      );
    }
    try {
      final verified = _nativeCore.verifyContactSignature(
        contactJson: senderContact.contactJson,
        context: _androidGroupEventSignatureContext,
        payload: _androidGroupEventSignaturePayloadJson(payload),
        signature: signature,
      );
      if (!verified.valid || verified.keyId != senderContact.keyId) {
        throw const AndroidInvalidEnvelopePayloadException('群组事件签名校验失败。');
      }
    } on AndroidInvalidEnvelopePayloadException {
      rethrow;
    } on EnvelopeNativeException catch (error) {
      throw AndroidInvalidEnvelopePayloadException('群组事件签名校验失败：$error');
    }
  }

  AndroidGroupEventRecord _groupEventFromPayload(
    AndroidGroupRecord group,
    Map<String, Object?> payload,
  ) {
    return AndroidGroupEventRecord(
      eventId: payload['event_id']?.toString() ?? _newAndroidGroupEventId(),
      groupId: group.groupId,
      epoch: group.epoch,
      type: payload['type']?.toString() ?? 'unknown',
      actorKeyId: payload['actor_key_id']?.toString() ?? '',
      createdAtUnixMs:
          (payload['created_at_unix_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      payloadJson: jsonEncode(payload),
      signature: payload['signature']?.toString() ?? '',
    );
  }

  Map<String, Object?> _contactControlPayload({
    required String type,
    required AndroidContactRecord target,
    required int now,
  }) {
    final identity = _requireAndroidIdentity();
    return {
      'version': 1,
      'type': type,
      'event_id': 'cct-${_randomAndroidTransferId()}',
      'actor_key_id': identity.keyId,
      'target_key_id': target.keyId,
      'created_at_unix_ms': now,
    };
  }

  NativeOutboundOpaqueFile _encryptAndroidContactControlEnvelope({
    required AndroidContactRecord recipient,
    required Map<String, Object?> payload,
    required int messageCounter,
  }) {
    final identity = _requireAndroidIdentity();
    return _nativeCore.encryptOpaqueFile(
      identityJson: identity.identityJson,
      recipientContactJson: recipient.contactJson,
      filename: 'contact-control.json',
      mime: _androidContactControlMime,
      payloadBytes: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      messageCounter: messageCounter,
    );
  }

  NativeOutboundOpaqueFile _encryptAndroidGroupControlEnvelope({
    required AndroidContactRecord recipient,
    required Map<String, Object?> payload,
    required int messageCounter,
  }) {
    final identity = _requireAndroidIdentity();
    return _nativeCore.encryptOpaqueFile(
      identityJson: identity.identityJson,
      recipientContactJson: recipient.contactJson,
      filename: 'group-control.json',
      mime: _androidGroupControlMime,
      payloadBytes: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      messageCounter: messageCounter,
    );
  }

  Future<EnvelopeSubmitResponse> _submitAndroidEnvelopeToServer({
    required EnvelopeServerClient client,
    required String recipientKeyId,
    required String envelopeId,
    required String envelopeBase64,
  }) async {
    final startedAt = DateTime.now();
    final identity = _requireAndroidIdentity();
    final request = _nativeCore.createEnvelopeSubmitRequest(
      identityJson: identity.identityJson,
      recipientKeyId: recipientKeyId,
      envelopeId: envelopeId,
      envelopeBase64: envelopeBase64,
    );
    try {
      final response = await _withAndroidServerRegistrationRetry(
        client: client,
        request: () =>
            client.submitEnvelope(submitRequestJson: request.requestJson),
      );
      _logDiagnostic('info', 'server_mailbox_submit_success', {
        'endpoint': client.activeBaseUri.toString(),
        'recipient_key_id': recipientKeyId,
        'envelope_id': envelopeId,
        'stored_until_unix_ms': response.storedUntilUnixMs,
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      return response;
    } catch (error) {
      _logDiagnostic('warn', 'server_mailbox_submit_failure', {
        'endpoint': client.activeBaseUri.toString(),
        'recipient_key_id': recipientKeyId,
        'envelope_id': envelopeId,
        'error': error.toString(),
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      rethrow;
    }
  }

  Future<AndroidP2pAck> _sendAndroidP2pEnvelopeWithCooldown({
    required String recipientKeyId,
    required String envelopeId,
    required String ticket,
    required Uint8List envelopeBytes,
    bool allowDeferred = false,
  }) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final relay = await _getAndroidRelayClient();
    final intent = await AndroidRelayHaAdapter.stageIntent(
      db: db,
      clusterId: relay.clusterId,
      senderKeyId: identity.keyId,
      recipientKeyId: recipientKeyId,
      envelopeId: envelopeId,
      envelopeBase64: _encodeOpaqueEnvelopeBase64(envelopeBytes),
    );
    if (!_androidP2pCooldown.canAttempt(
      recipientKeyId: recipientKeyId,
      ticket: ticket,
    )) {
      final remaining = _androidP2pCooldown.remaining(
        recipientKeyId: recipientKeyId,
        ticket: ticket,
      );
      final seconds = remaining == null
          ? androidP2pFailureCooldown.inSeconds
          : max(1, remaining.inSeconds);
      _logDiagnostic('info', 'p2p_direct_skipped_cooldown', {
        'recipient_key_id': recipientKeyId,
        'remaining_seconds': seconds,
      });
      throw AndroidP2pException('P2P 近期失败，${seconds}s 内跳过直连重试。');
    }
    final startedAt = DateTime.now();
    try {
      final ack = await _androidP2p.sendEnvelope(
        ticket: ticket,
        envelopeBytes: envelopeBytes,
        timeout: androidP2pFastAttemptTimeout,
      );
      final result = ack.recipientResult;
      final contact =
          await db.relayHa.recipientContact(recipientKeyId) ??
          (await db.getKnownContact(recipientKeyId))?.contactJson;
      if (result == null || contact == null) {
        throw const AndroidP2pException('直连已传输，尚未取得可验证的接收结果。');
      }
      await db.relayHa.applyRecipientResult(
        jsonEncode(result),
        verify: (json) async => _nativeCore.haV2({
          'op': 'verify_result',
          'result': jsonDecode(json),
          'contact': jsonDecode(contact),
          'binding': AndroidRelayHaAdapter.binding(intent),
        }),
      );
      for (final related in ack.recipientResults) {
        final relatedIntent = await db.relayHa.outgoing(
          senderKeyId: identity.keyId,
          recipientKeyId: recipientKeyId,
          envelopeId: related['envelope_id'] as String,
        );
        if (relatedIntent == null) continue;
        await db.relayHa.applyRecipientResult(
          jsonEncode(related),
          verify: (json) async => _nativeCore.haV2({
            'op': 'verify_result',
            'result': jsonDecode(json),
            'contact': jsonDecode(contact),
            'binding': AndroidRelayHaAdapter.binding(relatedIntent),
          }),
        );
      }
      if (result['outcome'] != 'delivered' &&
          !(allowDeferred && result['outcome'] == 'deferred')) {
        throw AndroidP2pException('接收方尚未完成处理：${result['outcome']}');
      }
      _androidP2pCooldown.recordSuccess(
        recipientKeyId: recipientKeyId,
        ticket: ticket,
      );
      _logDiagnostic('info', 'p2p_direct_success', {
        'recipient_key_id': recipientKeyId,
        'payload_bytes': envelopeBytes.length,
        'ack_status': ack.status,
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      return ack;
    } catch (error) {
      _androidP2pCooldown.recordFailure(
        recipientKeyId: recipientKeyId,
        ticket: ticket,
      );
      _logDiagnostic('warn', 'p2p_direct_failure', {
        'recipient_key_id': recipientKeyId,
        'payload_bytes': envelopeBytes.length,
        'error': error.toString(),
        'elapsed_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      rethrow;
    }
  }

  Future<List<T>> _runAndroidLimitedConcurrency<T>(
    List<Future<T> Function()> jobs, {
    required int concurrency,
  }) async {
    if (jobs.isEmpty) return <T>[];
    final results = List<T?>.filled(jobs.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= jobs.length) return;
        nextIndex += 1;
        results[index] = await jobs[index]();
      }
    }

    final workerCount = min(max(1, concurrency), jobs.length);
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return results.cast<T>();
  }

  Future<String> _deliverAndroidOpaqueEnvelopeToContact({
    required AndroidContactRecord contact,
    required String envelopeId,
    required String envelopeBase64,
    String? serverUrl,
  }) async {
    final activeContact =
        _androidChatStore.findContact(contact.keyId) ?? contact;
    final ticket = activeContact.p2pTicket?.trim() ?? '';
    if (ticket.isNotEmpty) {
      final parsedTicket = AndroidP2pTicket.tryParse(ticket);
      if (parsedTicket != null && !parsedTicket.isExpired) {
        try {
          final ack = await _sendAndroidP2pEnvelopeWithCooldown(
            recipientKeyId: activeContact.keyId,
            envelopeId: envelopeId,
            ticket: ticket,
            envelopeBytes: _decodeOpaqueEnvelopeBase64(envelopeBase64),
          );
          return 'p2p:${ack.status}';
        } catch (_) {
          // Server mailbox fallback below is the durable path.
        }
      }
    }

    final client = _createEnvelopeServerClient(serverUrl);
    try {
      var recipient = activeContact;
      final deviceId = activeContact.deviceId?.trim() ?? '';
      if (deviceId.isNotEmpty) {
        try {
          final route = await client.lookupRoute(
            ownerKeyId: activeContact.keyId,
            deviceId: deviceId,
          );
          final endpoint = route.endpoint;
          if (endpoint != null && endpoint.p2pTicket.trim().isNotEmpty) {
            recipient = activeContact.copyWith(
              deviceId: endpoint.deviceId,
              p2pTicket: endpoint.p2pTicket,
              p2pTicketUpdatedAtUnixMs: endpoint.createdAtUnixMs,
            );
            final db = await _ensureAndroidDbStore();
            await db.upsertContact(recipient);
            if (!endpoint.isExpired) {
              final ack = await _sendAndroidP2pEnvelopeWithCooldown(
                recipientKeyId: recipient.keyId,
                envelopeId: envelopeId,
                ticket: endpoint.p2pTicket,
                envelopeBytes: _decodeOpaqueEnvelopeBase64(envelopeBase64),
              );
              return 'server_route_p2p:${ack.status}';
            }
          }
        } catch (_) {
          // Route refresh is best effort; mailbox submit below is authoritative.
        }
      }
      await _submitAndroidEnvelopeToServer(
        client: client,
        envelopeId: envelopeId,
        recipientKeyId: recipient.keyId,
        envelopeBase64: envelopeBase64,
      );
      return AndroidDeliveryStatus.serverMailbox;
    } finally {
      client.close();
    }
  }

  Future<String> _deliverAndroidOpaqueEnvelopeBatchToContact({
    required AndroidContactRecord contact,
    required List<_AndroidEnvelopeToSend> envelopes,
    String? serverUrl,
  }) async {
    if (envelopes.isEmpty) {
      return 'empty';
    }
    await _stageAndroidEnvelopeBatch(contact.keyId, envelopes);
    final activeContact =
        _androidChatStore.findContact(contact.keyId) ?? contact;
    final ticket = activeContact.p2pTicket?.trim() ?? '';
    if (ticket.isNotEmpty) {
      final parsedTicket = AndroidP2pTicket.tryParse(ticket);
      if (parsedTicket != null && !parsedTicket.isExpired) {
        try {
          await _sendAndroidP2pEnvelopeBatch(
            recipientKeyId: activeContact.keyId,
            ticket: ticket,
            envelopes: envelopes,
          );
          return 'p2p:ok:${envelopes.length}';
        } catch (_) {
          // Server mailbox fallback below is the durable path.
        }
      }
    }

    final client = _createEnvelopeServerClient(serverUrl);
    try {
      var recipient = activeContact;
      final deviceId = activeContact.deviceId?.trim() ?? '';
      if (deviceId.isNotEmpty) {
        try {
          final route = await client.lookupRoute(
            ownerKeyId: activeContact.keyId,
            deviceId: deviceId,
          );
          final endpoint = route.endpoint;
          if (endpoint != null && endpoint.p2pTicket.trim().isNotEmpty) {
            recipient = activeContact.copyWith(
              deviceId: endpoint.deviceId,
              p2pTicket: endpoint.p2pTicket,
              p2pTicketUpdatedAtUnixMs: endpoint.createdAtUnixMs,
            );
            final db = await _ensureAndroidDbStore();
            await db.upsertContact(recipient);
            if (!endpoint.isExpired) {
              await _sendAndroidP2pEnvelopeBatch(
                recipientKeyId: recipient.keyId,
                ticket: endpoint.p2pTicket,
                envelopes: envelopes,
              );
              return 'server_route_p2p:ok:${envelopes.length}';
            }
          }
        } catch (_) {
          // Route refresh is best effort; mailbox submit below is authoritative.
        }
      }
      for (final envelope in envelopes) {
        await _submitAndroidEnvelopeToServer(
          client: client,
          envelopeId: envelope.envelopeId,
          recipientKeyId: recipient.keyId,
          envelopeBase64: envelope.envelopeBase64,
        );
      }
      return '${AndroidDeliveryStatus.serverMailbox}:${envelopes.length}';
    } finally {
      client.close();
    }
  }

  Future<AndroidGroupRecord> _createAndroidGroup({
    required String name,
    required String policy,
    required List<AndroidContactRecord> invitees,
  }) async {
    final normalizedName = name.trim().isEmpty ? '未命名群组' : name.trim();
    final identity = _requireAndroidIdentity();
    final ownerContact = _currentAndroidContactRecord();
    final now = DateTime.now().millisecondsSinceEpoch;
    final group = AndroidGroupRecord(
      groupId: _newAndroidGroupId(),
      name: normalizedName,
      ownerKeyId: identity.keyId,
      policy: AndroidGroupPolicy.normalize(policy),
      epoch: 1,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
      avatarSeed: normalizedName,
    );
    final uniqueInvitees = <String, AndroidContactRecord>{
      for (final contact in invitees)
        if (contact.keyId != identity.keyId) contact.keyId: contact,
    }.values.toList(growable: false);
    if (uniqueInvitees.length < 2) {
      throw const SecureStoreException('创建群组至少需要选择 2 位联系人。');
    }
    final members = <AndroidGroupMemberRecord>[
      _memberFromContact(
        groupId: group.groupId,
        contact: ownerContact,
        role: AndroidGroupMemberRole.owner,
        status: AndroidGroupMemberStatus.active,
        trustState: AndroidGroupTrustState.verified,
        now: now,
      ),
      for (final contact in uniqueInvitees)
        _memberFromContact(
          groupId: group.groupId,
          contact: contact,
          role: AndroidGroupMemberRole.member,
          status: AndroidGroupMemberStatus.pending,
          trustState: group.policy == AndroidGroupPolicy.consensus
              ? AndroidGroupTrustState.consensusPending
              : AndroidGroupTrustState.inviter,
          now: now,
          invitedByKeyId: identity.keyId,
        ),
    ];
    final payload = _groupControlPayload(
      type: 'group_invite',
      group: group,
      members: members,
      now: now,
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: group,
      members: members,
      payload: payload,
      recipients: members.where((member) => member.keyId != identity.keyId),
      onStaged: () async {
        await _refreshAndroidChatStore();
        if (!mounted) return;
        setState(() {
          _selectedAndroidContactKeyId = null;
          _selectedAndroidGroupId = group.groupId;
          _details = '群组已创建：${group.displayName}\n正在发送群邀请...';
        });
      },
    );
    await _refreshAndroidChatStore();
    if (!mounted) return group;
    setState(() {
      _selectedAndroidContactKeyId = null;
      _selectedAndroidGroupId = group.groupId;
      _details = [
        '群组已创建：${group.displayName}',
        _androidGroupSubtitle(context, group),
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
    return group;
  }

  Future<AndroidMessageRecord> _sendAndroidGroupText({
    required AndroidGroupRecord group,
    required String text,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw const SecureStoreException('请先输入消息内容。');
    }
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final recipients = _androidGroupMessageRecipients(
      group: group,
      members: members,
      selfKeyId: identity.keyId,
    );
    if (recipients.isEmpty) {
      throw const SecureStoreException('该群没有可投递的活跃成员。');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = _groupControlPayload(
      type: 'group_message',
      group: group,
      members: members,
      now: now,
      extra: {'text': normalizedText},
    );
    final baseCounter = await db.getNextMessageCounter();
    final nextCounter = androidAdvanceMessageCounter(
      baseCounter,
      recipients.length,
    );
    await db.setNextMessageCounter(nextCounter);
    var counter = baseCounter;
    final drafts = <_AndroidStagedEnvelopeDraft>[];
    for (var index = 0; index < recipients.length; index += 1) {
      final member = recipients[index];
      final contact = member.toContactRecord();
      final envelope = _encryptAndroidGroupControlEnvelope(
        recipient: contact,
        payload: payload,
        messageCounter: counter,
      );
      counter = androidAdvanceMessageCounter(envelope.messageCounter);
      drafts.add(
        _AndroidStagedEnvelopeDraft(
          contact: contact,
          recipientDisplayName: member.displayLabel,
          envelopeId: envelope.envelopeId,
          envelopeBase64: envelope.envelopeBase64,
          childIndex: index,
        ),
      );
    }
    final stagedBytes = drafts.fold<int>(
      0,
      (total, draft) => total + draft.envelopeBase64.length,
    );
    if (stagedBytes > _androidMaximumStagedOutboundEnvelopeBytes) {
      throw const SecureStoreException('群文本 fanout outbox 超过 256 MiB 安全上限。');
    }
    final logicalMessageId = drafts.first.envelopeId;
    final children = drafts
        .map(
          (draft) => AndroidPendingEnvelopeRecord(
            envelopeId: draft.envelopeId,
            logicalMessageId: logicalMessageId,
            recipientKeyId: draft.contact.keyId,
            recipientDisplayName: draft.recipientDisplayName,
            recipientContactJson: draft.contact.contactJson,
            envelopeBase64: draft.envelopeBase64,
            createdAtUnixMs: now,
            childIndex: draft.childIndex,
            childCount: drafts.length,
          ),
        )
        .toList(growable: false);
    final message = AndroidMessageRecord(
      envelopeId: logicalMessageId,
      conversationId: group.groupId,
      direction: 'outgoing',
      peerKeyId: group.groupId,
      peerDisplayName: group.displayName,
      createdAtUnixMs: now,
      messageCounter: baseCounter,
      text: normalizedText,
      opaqueEnvelopeBase64: '',
      deliveryStatus: AndroidDeliveryStatus.pending,
      deliveryDetail: '群发密文已持久化，等待逐成员投递。',
      deliveryUpdatedAtUnixMs: now,
    );
    await db.stageOutboundEnvelopeBatch(
      logicalMessage: message,
      children: children,
      groupEvent: _groupEventFromPayload(group, payload),
    );
    await _ensureAndroidP2pListening();
    final jobs = children
        .map<Future<_AndroidMemberDeliveryResult> Function()>(
          (child) =>
              () => _deliverAndroidPendingEnvelope(child),
        )
        .toList(growable: false);
    final deliveryResults = await _runAndroidLimitedConcurrency(
      jobs,
      concurrency: _androidGroupDeliveryConcurrency,
    );
    final updated =
        await _refreshAndroidLogicalDelivery(logicalMessageId) ??
        (throw SecureStoreException('群发逻辑消息更新失败：$logicalMessageId'));
    await _refreshAndroidChatStore();
    return updated.copyWith(
      deliveryDetail: deliveryResults.map((result) => result.detail).join('\n'),
    );
  }

  List<AndroidGroupMemberRecord> _androidGroupMessageRecipients({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required String selfKeyId,
  }) {
    AndroidGroupMemberRecord? self;
    for (final member in members) {
      if (member.keyId == selfKeyId) {
        self = member;
        break;
      }
    }
    if (self == null || !self.isActive) {
      throw const SecureStoreException('你尚未加入该群，不能发送群消息。');
    }
    final recipients = members
        .where((member) {
          if (!member.isActive || member.keyId == selfKeyId) return false;
          if (group.policy == AndroidGroupPolicy.verified &&
              !member.isLocallyTrusted) {
            return false;
          }
          return member.contactJson.trim().isNotEmpty;
        })
        .toList(growable: false);
    if (recipients.length > _androidMaximumOfflineGroupRecipients) {
      throw SecureStoreException(
        '群组可投递收件人超过 '
        '$_androidMaximumOfflineGroupRecipients 人资源上限。',
      );
    }
    return recipients;
  }

  Future<_AndroidMemberDeliveryResult> _deliverAndroidPendingEnvelope(
    AndroidPendingEnvelopeRecord child, {
    String? serverUrl,
  }) async {
    final db = await _ensureAndroidDbStore();
    try {
      final status = await _deliverAndroidOpaqueEnvelopeToContact(
        contact: child.toContactRecord(),
        envelopeId: child.envelopeId,
        envelopeBase64: child.envelopeBase64,
        serverUrl: serverUrl,
      );
      final deliveryStatus =
          status.contains(AndroidDeliveryStatus.serverMailbox)
          ? AndroidDeliveryStatus.serverMailbox
          : AndroidDeliveryStatus.sent;
      final route = status.split(':').first;
      await db.updatePendingEnvelopeDelivery(
        envelopeId: child.envelopeId,
        deliveryStatus: deliveryStatus,
        detail: status,
        route: route,
      );
      return _AndroidMemberDeliveryResult(
        detail: '${child.recipientDisplayName}: $status',
        envelopeId: child.envelopeId,
      );
    } catch (error) {
      final detail = error.toString();
      await db.updatePendingEnvelopeDelivery(
        envelopeId: child.envelopeId,
        deliveryStatus: AndroidDeliveryStatus.pending,
        detail: detail,
        route: 'pending',
      );
      return _AndroidMemberDeliveryResult(
        detail: '${child.recipientDisplayName}: $detail',
        failed: true,
        envelopeId: child.envelopeId,
      );
    }
  }

  Future<_AndroidMemberDeliveryResult> _deliverAndroidPendingEnvelopeBatch(
    AndroidContactRecord contact,
    String recipientDisplayName,
    List<AndroidPendingEnvelopeRecord> children, {
    String? serverUrl,
  }) async {
    final db = await _ensureAndroidDbStore();
    final envelopes = children
        .map(
          (child) => _AndroidEnvelopeToSend(
            envelopeId: child.envelopeId,
            envelopeBase64: child.envelopeBase64,
            ordinal: child.childIndex,
          ),
        )
        .toList(growable: false);
    try {
      final status = await _deliverAndroidOpaqueEnvelopeBatchToContact(
        contact: contact,
        envelopes: envelopes,
        serverUrl: serverUrl,
      );
      final deliveryStatus =
          status.contains(AndroidDeliveryStatus.serverMailbox)
          ? AndroidDeliveryStatus.serverMailbox
          : AndroidDeliveryStatus.sent;
      final route = status.split(':').first;
      for (final child in children) {
        await db.updatePendingEnvelopeDelivery(
          envelopeId: child.envelopeId,
          deliveryStatus: deliveryStatus,
          detail: status,
          route: route,
        );
      }
      return _AndroidMemberDeliveryResult(
        detail: '$recipientDisplayName: $status (${children.length} envelopes)',
        envelopeId: children.first.envelopeId,
      );
    } catch (error) {
      final detail = error.toString();
      for (final child in children) {
        await db.updatePendingEnvelopeDelivery(
          envelopeId: child.envelopeId,
          deliveryStatus: AndroidDeliveryStatus.pending,
          detail: detail,
          route: 'pending',
        );
      }
      return _AndroidMemberDeliveryResult(
        detail: '$recipientDisplayName: $detail',
        failed: true,
        envelopeId: children.first.envelopeId,
      );
    }
  }

  Future<AndroidMessageRecord?> _refreshAndroidLogicalDelivery(
    String logicalMessageId,
  ) async {
    final db = await _ensureAndroidDbStore();
    final children = await db.getOutboundEnvelopeBatch(logicalMessageId);
    if (children.isEmpty) {
      return db.getMessage(logicalMessageId);
    }
    final expected = children
        .map((child) => child.childCount)
        .fold<int>(0, max);
    final complete =
        expected == children.length &&
        children.map((child) => child.childIndex).toSet().length == expected;
    final hasPending =
        !complete ||
        children.any(
          (child) => child.deliveryStatus == AndroidDeliveryStatus.pending,
        );
    final status = hasPending
        ? AndroidDeliveryStatus.pending
        : children.any(
            (child) =>
                child.deliveryStatus == AndroidDeliveryStatus.serverMailbox,
          )
        ? AndroidDeliveryStatus.serverMailbox
        : AndroidDeliveryStatus.sent;
    final detail = children
        .map(
          (child) =>
              '${child.recipientDisplayName}: '
              '${child.deliveryStatus}'
              '${child.lastRoute == null ? '' : ' / ${child.lastRoute}'}'
              '${child.lastError == null ? '' : ' / ${child.lastError}'}',
        )
        .join('\n');
    final logicalKind = children.first.logicalKind;
    if (logicalKind == AndroidPendingEnvelopeKind.groupControl) {
      if (!hasPending) {
        await db.deleteOutboundEnvelopeBatch(logicalMessageId);
      }
      return null;
    }
    await db.updateMessageDelivery(
      envelopeId: logicalMessageId,
      deliveryStatus: status,
      deliveryDetail: detail,
    );
    final updated = await db.getMessage(logicalMessageId);
    if (!hasPending) {
      await db.deleteOutboundEnvelopeBatch(logicalMessageId);
    }
    return updated;
  }

  void _validateAndroidGroupFileOutboxBudget({
    required int recipientCount,
    required int totalFileBytes,
    required int chunkCount,
  }) {
    if (recipientCount <= 0 || totalFileBytes < 0 || chunkCount <= 0) {
      throw const SecureStoreException('群文件 outbox 预算参数无效。');
    }
    final estimate =
        recipientCount * (totalFileBytes * 2 + (chunkCount + 1) * 128 * 1024);
    if (estimate > _androidMaximumStagedOutboundEnvelopeBytes) {
      throw SecureStoreException(
        '群文件 fanout 预计需要 ${estimate ~/ (1024 * 1024)} MiB outbox，'
        '超过 256 MiB 安全上限。',
      );
    }
  }

  Future<AndroidMessageRecord> _sendAndroidGroupFile({
    required AndroidGroupRecord group,
    required AndroidPickedFile file,
    String? serverUrl,
  }) async {
    final scan = await _scanAndroidPickedFile(
      file,
      tooLargeMessage: _androidOnlineFileTooLargeMessage(),
    );
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final recipients = _androidGroupMessageRecipients(
      group: group,
      members: members,
      selfKeyId: identity.keyId,
    );
    if (recipients.isEmpty) {
      throw const SecureStoreException('该群没有可投递的活跃成员。');
    }

    final fileName = file.name.trim().isEmpty ? 'file' : file.name.trim();
    final mime = file.mime.trim().isEmpty
        ? 'application/octet-stream'
        : file.mime.trim();
    final transferId = _randomAndroidTransferId();
    final chunkCount = scan.chunkHashes.length;
    final now = DateTime.now().millisecondsSinceEpoch;
    final envelopesPerMember = chunkCount + 1;
    _validateAndroidGroupFileOutboxBudget(
      recipientCount: recipients.length,
      totalFileBytes: scan.totalSize,
      chunkCount: chunkCount,
    );
    final baseCounter = await db.getNextMessageCounter();
    final nextCounter = androidAdvanceMessageCounter(
      baseCounter,
      recipients.length * envelopesPerMember,
    );
    // Reserve every child counter before encryption or any network side effect.
    await db.setNextMessageCounter(nextCounter);

    final manifestPayload = <String, Object?>{
      'version': 1,
      'kind': 'file_manifest',
      'transfer_id': transferId,
      'conversation_id': group.groupId,
      'group_id': group.groupId,
      'group_epoch': group.epoch,
      'filename': fileName,
      'mime': mime,
      'total_size': scan.totalSize,
      'chunk_size': _androidOnlineFileChunkBytes,
      'chunk_count': chunkCount,
      'file_sha256': scan.fileSha256,
      'chunk_sha256': scan.chunkHashes,
    };
    final drafts = <_AndroidStagedEnvelopeDraft>[];
    for (
      var memberIndex = 0;
      memberIndex < recipients.length;
      memberIndex += 1
    ) {
      final member = recipients[memberIndex];
      final contact = member.toContactRecord();
      var memberCounter = androidAdvanceMessageCounter(
        baseCounter,
        memberIndex * envelopesPerMember,
      );
      for (var index = 0; index < chunkCount; index += 1) {
        final chunkBytes = await _readAndroidPickedFileChunkForSend(
          file: file,
          chunkIndex: index,
          totalSize: scan.totalSize,
        );
        final chunkSha256 = _sha256Base64Url(chunkBytes);
        if (chunkSha256 != scan.chunkHashes[index]) {
          throw SecureStoreException('文件分片哈希校验失败：$index。');
        }
        final chunkPayload = <String, Object?>{
          'version': 1,
          'kind': 'file_chunk',
          'transfer_id': transferId,
          'conversation_id': group.groupId,
          'group_id': group.groupId,
          'chunk_index': index,
          'chunk_count': chunkCount,
          'chunk_sha256': chunkSha256,
          'data_b64': _encodeOpaqueEnvelopeBase64(chunkBytes),
        };
        final outboundChunk = _nativeCore.encryptOpaqueFile(
          identityJson: identity.identityJson,
          recipientContactJson: contact.contactJson,
          filename: '$fileName.part${index.toString().padLeft(4, '0')}',
          mime: _androidFileChunkMime,
          payloadBytes: Uint8List.fromList(
            utf8.encode(jsonEncode(chunkPayload)),
          ),
          messageCounter: memberCounter,
        );
        drafts.add(
          _AndroidStagedEnvelopeDraft(
            contact: contact,
            recipientDisplayName: member.displayLabel,
            envelopeId: outboundChunk.envelopeId,
            envelopeBase64: outboundChunk.envelopeBase64,
            childIndex: memberIndex * envelopesPerMember + index,
          ),
        );
        memberCounter = androidAdvanceMessageCounter(
          outboundChunk.messageCounter,
        );
      }

      final outboundManifest = _nativeCore.encryptOpaqueFile(
        identityJson: identity.identityJson,
        recipientContactJson: contact.contactJson,
        filename: '$fileName.manifest.json',
        mime: _androidFileManifestMime,
        payloadBytes: Uint8List.fromList(
          utf8.encode(jsonEncode(manifestPayload)),
        ),
        messageCounter: memberCounter,
      );
      drafts.add(
        _AndroidStagedEnvelopeDraft(
          contact: contact,
          recipientDisplayName: member.displayLabel,
          envelopeId: outboundManifest.envelopeId,
          envelopeBase64: outboundManifest.envelopeBase64,
          childIndex: memberIndex * envelopesPerMember + chunkCount,
        ),
      );
    }

    final children = drafts
        .map(
          (draft) => AndroidPendingEnvelopeRecord(
            envelopeId: draft.envelopeId,
            logicalMessageId: transferId,
            recipientKeyId: draft.contact.keyId,
            recipientDisplayName: draft.recipientDisplayName,
            recipientContactJson: draft.contact.contactJson,
            envelopeBase64: draft.envelopeBase64,
            createdAtUnixMs: now,
            childIndex: draft.childIndex,
            childCount: drafts.length,
          ),
        )
        .toList(growable: false);
    final message = AndroidMessageRecord(
      envelopeId: transferId,
      conversationId: group.groupId,
      direction: 'outgoing',
      peerKeyId: group.groupId,
      peerDisplayName: group.displayName,
      createdAtUnixMs: now,
      messageCounter: baseCounter,
      text: _androidFileMessageText(fileName, scan.totalSize),
      opaqueEnvelopeBase64: '',
      deliveryStatus: AndroidDeliveryStatus.pending,
      deliveryDetail: '群文件密文已持久化，等待逐成员投递。',
      deliveryUpdatedAtUnixMs: now,
      attachmentUri: file.uri,
      attachmentPath: file.uri.startsWith('file://')
          ? Uri.parse(file.uri).toFilePath()
          : null,
      attachmentMime: mime,
    );
    await db.stageOutboundEnvelopeBatch(
      logicalMessage: message,
      children: children,
    );
    await _ensureAndroidP2pListening();
    final jobs = <Future<_AndroidMemberDeliveryResult> Function()>[];
    for (
      var memberIndex = 0;
      memberIndex < recipients.length;
      memberIndex += 1
    ) {
      final member = recipients[memberIndex];
      final firstIndex = memberIndex * envelopesPerMember;
      final memberChildren = children.sublist(
        firstIndex,
        firstIndex + envelopesPerMember,
      );
      jobs.add(
        () => _deliverAndroidPendingEnvelopeBatch(
          member.toContactRecord(),
          member.displayLabel,
          memberChildren,
          serverUrl: serverUrl,
        ),
      );
    }
    final deliveryResults = await _runAndroidLimitedConcurrency(
      jobs,
      concurrency: _androidGroupFileDeliveryConcurrency,
    );
    final updated =
        await _refreshAndroidLogicalDelivery(transferId) ??
        (throw SecureStoreException('群文件逻辑消息更新失败：$transferId'));
    await _refreshAndroidChatStore();
    return updated.copyWith(
      deliveryDetail: deliveryResults.map((result) => result.detail).join('\n'),
    );
  }

  Future<List<String>> _broadcastAndroidGroupControl({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required Map<String, Object?> payload,
    required Iterable<AndroidGroupMemberRecord> recipients,
    Future<void> Function()? onStaged,
  }) async {
    final db = await _ensureAndroidDbStore();
    final seen = <String>{};
    final targets = recipients
        .where((member) => seen.add(member.keyId))
        .toList(growable: false);
    final missingContact = targets
        .where((member) => member.contactJson.trim().isEmpty)
        .map((member) => member.displayLabel)
        .toList(growable: false);
    if (missingContact.isNotEmpty) {
      throw SecureStoreException(
        '群组控制通知缺少收件人 contact，未提交本地群变更：'
        '${missingContact.join('、')}。',
      );
    }
    if (targets.length > _androidMaximumOfflineGroupRecipients) {
      throw SecureStoreException(
        '群组控制通知收件人超过 '
        '$_androidMaximumOfflineGroupRecipients 人资源上限。',
      );
    }
    final firstCounter = await db.getNextMessageCounter();
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(firstCounter, targets.length),
    );
    var counter = firstCounter;
    final event = _groupEventFromPayload(group, payload);
    final logicalMessageId = 'group-event:${event.eventId}';
    final children = <AndroidPendingEnvelopeRecord>[];
    for (var index = 0; index < targets.length; index += 1) {
      final member = targets[index];
      final contact = member.toContactRecord();
      final envelope = _encryptAndroidGroupControlEnvelope(
        recipient: contact,
        payload: payload,
        messageCounter: counter,
      );
      counter = androidAdvanceMessageCounter(envelope.messageCounter);
      children.add(
        AndroidPendingEnvelopeRecord(
          envelopeId: envelope.envelopeId,
          logicalMessageId: logicalMessageId,
          logicalKind: AndroidPendingEnvelopeKind.groupControl,
          recipientKeyId: contact.keyId,
          recipientDisplayName: member.displayLabel,
          recipientContactJson: contact.contactJson,
          envelopeBase64: envelope.envelopeBase64,
          createdAtUnixMs: event.createdAtUnixMs,
          childIndex: index,
          childCount: targets.length,
        ),
      );
    }
    final stagedBytes = children.fold<int>(
      0,
      (total, child) => total + child.envelopeBase64.length,
    );
    if (stagedBytes > _androidMaximumStagedOutboundEnvelopeBytes) {
      throw const SecureStoreException('群组控制通知 outbox 超过 256 MiB 安全上限。');
    }
    final committedMembers = _calculateAndroidConsensusAdmissions(
      group: group,
      members: members,
      events: [
        ...await db.getGroupEvents(groupId: group.groupId),
        event,
      ],
    );
    await db.stageGroupControlTransition(
      group: group,
      members: committedMembers,
      event: event,
      children: children,
    );
    if (onStaged != null) await onStaged();
    if (children.isEmpty) return const [];

    await _ensureAndroidP2pListening();
    final jobs = children
        .map<Future<_AndroidMemberDeliveryResult> Function()>(
          (child) =>
              () => _deliverAndroidPendingEnvelope(child),
        )
        .toList(growable: false);
    final deliveryResults = await _runAndroidLimitedConcurrency(
      jobs,
      concurrency: _androidGroupDeliveryConcurrency,
    );
    await _refreshAndroidLogicalDelivery(logicalMessageId);
    return deliveryResults.map((result) => result.detail).toList();
  }

  Map<String, Object?> _androidConsensusEndorsementSigningMap({
    required AndroidGroupRecord group,
    required String candidateKeyId,
    required String endorserKeyId,
    required int createdAtUnixMs,
  }) {
    return {
      'version': 1,
      'group_id': group.groupId,
      'epoch': group.epoch,
      'candidate_key_id': candidateKeyId,
      'endorser_key_id': endorserKeyId,
      'created_at_unix_ms': createdAtUnixMs,
    };
  }

  String _androidConsensusEndorsementPayloadJson({
    required AndroidGroupRecord group,
    required String candidateKeyId,
    required String endorserKeyId,
    required int createdAtUnixMs,
  }) {
    return jsonEncode(
      _androidConsensusEndorsementSigningMap(
        group: group,
        candidateKeyId: candidateKeyId,
        endorserKeyId: endorserKeyId,
        createdAtUnixMs: createdAtUnixMs,
      ),
    );
  }

  Map<String, Object?> _createAndroidConsensusEndorsement({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord candidate,
    required int now,
  }) {
    final identity = _requireAndroidIdentity();
    final payloadJson = _androidConsensusEndorsementPayloadJson(
      group: group,
      candidateKeyId: candidate.keyId,
      endorserKeyId: identity.keyId,
      createdAtUnixMs: now,
    );
    final signature = _nativeCore.signContextPayload(
      identityJson: identity.identityJson,
      context: _androidGroupConsensusEndorsementContext,
      payload: payloadJson,
    );
    if (signature.keyId != identity.keyId) {
      throw const SecureStoreException('共识背书签名身份不匹配。');
    }
    final signingMap = (jsonDecode(payloadJson) as Map).cast<String, Object?>();
    return {...signingMap, 'signature': signature.signature};
  }

  bool _verifyAndroidConsensusEndorsement({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord endorser,
    required String candidateKeyId,
    required Map<String, Object?> endorsement,
  }) {
    if (endorser.contactJson.trim().isEmpty) return false;
    final version = (endorsement['version'] as num?)?.toInt() ?? 0;
    final epoch = (endorsement['epoch'] as num?)?.toInt() ?? 0;
    final groupId = endorsement['group_id']?.toString() ?? '';
    final endorsedCandidateKeyId =
        endorsement['candidate_key_id']?.toString() ?? '';
    final endorserKeyId = endorsement['endorser_key_id']?.toString() ?? '';
    final createdAtUnixMs =
        (endorsement['created_at_unix_ms'] as num?)?.toInt() ?? 0;
    final signature = endorsement['signature']?.toString() ?? '';
    if (version != 1 ||
        groupId != group.groupId ||
        epoch <= 0 ||
        epoch > group.epoch ||
        endorsedCandidateKeyId != candidateKeyId ||
        endorserKeyId != endorser.keyId ||
        createdAtUnixMs <= 0 ||
        signature.isEmpty) {
      return false;
    }
    final payloadJson = _androidConsensusEndorsementPayloadJson(
      group: group.copyWith(epoch: epoch),
      candidateKeyId: candidateKeyId,
      endorserKeyId: endorser.keyId,
      createdAtUnixMs: createdAtUnixMs,
    );
    try {
      final verified = _nativeCore.verifyContactSignature(
        contactJson: endorser.contactJson,
        context: _androidGroupConsensusEndorsementContext,
        payload: payloadJson,
        signature: signature,
      );
      return verified.valid && verified.keyId == endorser.keyId;
    } catch (_) {
      return false;
    }
  }

  Set<String> _androidConsensusEndorsersForCandidate({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord candidate,
    required List<AndroidGroupMemberRecord> members,
    required List<AndroidGroupEventRecord> events,
  }) {
    final eligibleByKey = {
      for (final member in members)
        if (member.isActive && member.keyId != candidate.keyId)
          member.keyId: member,
    };
    final endorsers = <String>{};
    final invitedBy = candidate.invitedByKeyId?.trim() ?? '';
    if (eligibleByKey.containsKey(invitedBy)) {
      endorsers.add(invitedBy);
    }
    for (final event in events) {
      if (event.type != 'member_endorsed') continue;
      final endorser = eligibleByKey[event.actorKeyId];
      if (endorser == null) continue;
      try {
        final payload = jsonDecode(event.payloadJson);
        if (payload is! Map) continue;
        final map = payload.cast<String, Object?>();
        if (map['candidate_key_id']?.toString() != candidate.keyId) {
          continue;
        }
        final endorsementValue = map['endorsement'];
        if (endorsementValue is! Map) continue;
        final endorsement = endorsementValue.cast<String, Object?>();
        if (_verifyAndroidConsensusEndorsement(
          group: group,
          endorser: endorser,
          candidateKeyId: candidate.keyId,
          endorsement: endorsement,
        )) {
          endorsers.add(endorser.keyId);
        }
      } catch (_) {
        continue;
      }
    }
    return endorsers;
  }

  void _validateIncomingAndroidConsensusEndorsement({
    required AndroidGroupRecord group,
    required Map<String, Object?> payload,
    required List<AndroidGroupMemberRecord> members,
  }) {
    if (group.policy != AndroidGroupPolicy.consensus) {
      throw const AndroidInvalidEnvelopePayloadException('非共识群不能接收共识背书事件。');
    }
    final candidateKeyId = payload['candidate_key_id']?.toString() ?? '';
    final actorKeyId = payload['actor_key_id']?.toString() ?? '';
    final endorsementValue = payload['endorsement'];
    if (candidateKeyId.isEmpty ||
        actorKeyId.isEmpty ||
        endorsementValue is! Map) {
      throw const AndroidInvalidEnvelopePayloadException('共识背书事件缺少候选人或签名。');
    }
    AndroidGroupMemberRecord? candidate;
    AndroidGroupMemberRecord? endorser;
    for (final member in members) {
      if (member.keyId == candidateKeyId) candidate = member;
      if (member.keyId == actorKeyId) endorser = member;
    }
    if (candidate == null || !(candidate.isAccepted || candidate.isActive)) {
      throw const AndroidMailboxMissingPrerequisiteException('共识背书候选人状态无效。');
    }
    if (endorser == null || !endorser.isActive) {
      throw const AndroidInvalidEnvelopePayloadException('共识背书者不是活跃群成员。');
    }
    final endorsement = endorsementValue.cast<String, Object?>();
    if (!_verifyAndroidConsensusEndorsement(
      group: group,
      endorser: endorser,
      candidateKeyId: candidateKeyId,
      endorsement: endorsement,
    )) {
      throw const AndroidInvalidEnvelopePayloadException('共识背书签名校验失败。');
    }
  }

  List<AndroidGroupMemberRecord> _calculateAndroidConsensusAdmissions({
    required AndroidGroupRecord group,
    required List<AndroidGroupMemberRecord> members,
    required List<AndroidGroupEventRecord> events,
  }) {
    if (group.policy != AndroidGroupPolicy.consensus) return members;
    final identityKeyId = _secureIdentity?.keyId ?? '';
    final updated = [...members];
    for (var index = 0; index < updated.length; index += 1) {
      final candidate = updated[index];
      if (!candidate.isAccepted) continue;
      final activeMemberCount = updated
          .where((member) => member.isActive && member.keyId != candidate.keyId)
          .length;
      final threshold =
          _androidConsensusInitialInviteBootstrapApplies(
            group: group,
            candidate: candidate,
            events: events,
          )
          ? 1
          : androidConsensusThreshold(activeMemberCount);
      if (threshold <= 0) continue;
      final endorsers = _androidConsensusEndorsersForCandidate(
        group: group,
        candidate: candidate,
        members: updated,
        events: events,
      );
      if (endorsers.length < threshold) continue;
      final now = DateTime.now().millisecondsSinceEpoch;
      final trustState = candidate.keyId == identityKeyId
          ? AndroidGroupTrustState.verified
          : candidate.isLocallyTrusted
          ? candidate.trustState
          : AndroidGroupTrustState.consensusAdmitted;
      updated[index] = candidate.copyWith(
        status: AndroidGroupMemberStatus.active,
        trustState: trustState,
        joinedAtUnixMs: candidate.joinedAtUnixMs ?? now,
        updatedAtUnixMs: now,
      );
    }
    return updated;
  }

  bool _androidConsensusInitialInviteBootstrapApplies({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord candidate,
    required List<AndroidGroupEventRecord> events,
  }) {
    if (group.policy != AndroidGroupPolicy.consensus) return false;
    final inviterKeyId = candidate.invitedByKeyId?.trim() ?? '';
    if (inviterKeyId.isEmpty || inviterKeyId != group.ownerKeyId) {
      return false;
    }
    for (final event in events) {
      if (event.type != 'group_invite') continue;
      try {
        final decoded = jsonDecode(event.payloadJson);
        if (decoded is! Map) continue;
        final payload = decoded.cast<String, Object?>();
        final groupValue = payload['group'];
        if (groupValue is! Map) continue;
        final eventGroup = AndroidGroupRecord.fromJson(groupValue);
        if (eventGroup.groupId != group.groupId || eventGroup.epoch != 1) {
          continue;
        }
        final membersValue = payload['members'];
        if (membersValue is! List) continue;
        for (final memberValue in membersValue.whereType<Map>()) {
          final member = AndroidGroupMemberRecord.fromJson(memberValue);
          if (member.groupId == group.groupId &&
              member.keyId == candidate.keyId &&
              member.invitedByKeyId == group.ownerKeyId &&
              (member.isPending || member.isAccepted)) {
            return true;
          }
        }
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  Future<void> _acceptAndroidGroupInvite(
    AndroidGroupRecord group, {
    bool openGroupAfterAccept = true,
  }) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final currentGroup = await db.getGroup(group.groupId) ?? group;
    if (!currentGroup.isActive) {
      throw const SecureStoreException('群邀请已失效，群组不再处于活动状态。');
    }
    final members = await db.getGroupMembers(groupId: currentGroup.groupId);
    if (androidGroupShouldAutoDissolveForMembers(members)) {
      await db.deactivateGroup(currentGroup.groupId);
      await _refreshAndroidChatStore();
      throw const SecureStoreException('群邀请已失效，群组已不满足成群条件。');
    }
    AndroidGroupMemberRecord? self;
    for (final member in members) {
      if (member.keyId == identity.keyId) {
        self = member;
        break;
      }
    }
    if (self == null || !self.isPending) {
      throw const SecureStoreException('本机没有可接受的待处理群邀请。');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    var updatedMembers = <AndroidGroupMemberRecord>[];
    final consensusGroup = currentGroup.policy == AndroidGroupPolicy.consensus;
    for (final member in members) {
      updatedMembers.add(
        member.keyId == identity.keyId
            ? member.copyWith(
                status: consensusGroup
                    ? AndroidGroupMemberStatus.accepted
                    : AndroidGroupMemberStatus.active,
                trustState: consensusGroup
                    ? AndroidGroupTrustState.consensusPending
                    : AndroidGroupTrustState.verified,
                joinedAtUnixMs: consensusGroup ? member.joinedAtUnixMs : now,
                updatedAtUnixMs: now,
              )
            : member,
      );
    }
    final updatedGroup = currentGroup.copyWith(
      epoch: currentGroup.epoch + 1,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'member_accepted',
      group: updatedGroup,
      members: updatedMembers,
      now: now,
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: updatedMembers,
      payload: payload,
      recipients: updatedMembers.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
    );
    updatedMembers = await db.getGroupMembers(groupId: updatedGroup.groupId);
    await _refreshAndroidChatStore();
    if (!mounted) return;
    AndroidGroupMemberRecord? acceptedSelf;
    for (final member in updatedMembers) {
      if (member.keyId == identity.keyId) {
        acceptedSelf = member;
        break;
      }
    }
    setState(() {
      if (openGroupAfterAccept) {
        _selectedAndroidContactKeyId = null;
        _selectedAndroidGroupId = updatedGroup.groupId;
        _androidHomeTab = _AndroidHomeTab.chat;
      }
      _details = [
        if (acceptedSelf?.isActive == true)
          '已加入群组：${updatedGroup.displayName}'
        else
          '已接受群邀请：${updatedGroup.displayName}，等待共识背书。',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _declineAndroidGroupInvite(AndroidGroupRecord group) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final currentGroup = await db.getGroup(group.groupId) ?? group;
    final members = await db.getGroupMembers(groupId: currentGroup.groupId);
    AndroidGroupMemberRecord? self;
    for (final member in members) {
      if (member.keyId == identity.keyId) {
        self = member;
        break;
      }
    }
    if (self == null || !(self.isPending || self.isAccepted)) {
      throw const SecureStoreException('本机没有可拒绝的待处理群邀请。');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedMembers = <AndroidGroupMemberRecord>[
      for (final member in members)
        member.keyId == identity.keyId
            ? member.copyWith(
                status: AndroidGroupMemberStatus.left,
                trustState: AndroidGroupTrustState.verified,
                updatedAtUnixMs: now,
              )
            : member,
    ];
    final shouldDissolve = androidGroupShouldAutoDissolveForMembers(
      updatedMembers,
    );
    final dissolutionReasons = shouldDissolve
        ? androidGroupDissolutionReasonCodes(updatedMembers)
        : const <String>[];
    final updatedGroup = currentGroup.copyWith(
      epoch: currentGroup.epoch + 1,
      isActive: shouldDissolve ? false : currentGroup.isActive,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'member_left',
      group: updatedGroup,
      members: updatedMembers,
      now: now,
      extra: {
        if (dissolutionReasons.isNotEmpty)
          'dissolution_reasons': dissolutionReasons,
      },
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: updatedMembers,
      payload: payload,
      recipients: updatedMembers.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        shouldDissolve
            ? _androidGroupDissolvedText(
                '已拒绝群邀请：${currentGroup.displayName}',
                dissolutionReasons,
              )
            : '已拒绝群邀请：${currentGroup.displayName}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _leaveAndroidGroup(
    AndroidGroupRecord group, {
    VoidCallback? onLocalLeaveApplied,
  }) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final currentGroup = await db.getGroup(group.groupId) ?? group;
    final members = await db.getGroupMembers(groupId: currentGroup.groupId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedMembers = <AndroidGroupMemberRecord>[];
    for (final member in members) {
      updatedMembers.add(
        member.keyId == identity.keyId
            ? member.copyWith(
                status: AndroidGroupMemberStatus.left,
                trustState: AndroidGroupTrustState.verified,
                updatedAtUnixMs: now,
              )
            : member,
      );
    }
    final shouldDissolve = androidGroupShouldAutoDissolveForMembers(
      updatedMembers,
    );
    final dissolutionReasons = shouldDissolve
        ? androidGroupDissolutionReasonCodes(updatedMembers)
        : const <String>[];
    final updatedGroup = currentGroup.copyWith(
      epoch: currentGroup.epoch + 1,
      isActive: shouldDissolve ? false : currentGroup.isActive,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'member_left',
      group: updatedGroup,
      members: updatedMembers,
      now: now,
      extra: {
        if (dissolutionReasons.isNotEmpty)
          'dissolution_reasons': dissolutionReasons,
      },
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: updatedMembers,
      payload: payload,
      recipients: updatedMembers.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
      onStaged: () async {
        await _refreshAndroidChatStore();
        if (mounted) {
          setState(() {
            _androidHomeTab = _AndroidHomeTab.contacts;
            _selectedAndroidGroupId = null;
            _details = shouldDissolve
                ? _androidGroupDissolvedText(
                    '已退出群组：${currentGroup.displayName}',
                    dissolutionReasons,
                    suffix: '正在通知其他成员...',
                  )
                : '已退出群组：${currentGroup.displayName}。正在通知其他成员...';
          });
        }
        onLocalLeaveApplied?.call();
      },
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _androidHomeTab = _AndroidHomeTab.contacts;
      _selectedAndroidGroupId = null;
      _details = [
        shouldDissolve
            ? _androidGroupDissolvedText(
                '已退出群组：${currentGroup.displayName}',
                dissolutionReasons,
              )
            : '已退出群组：${currentGroup.displayName}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _removeAndroidGroupMember({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord target,
  }) async {
    final identity = _requireAndroidIdentity();
    if (group.ownerKeyId != identity.keyId) {
      throw const SecureStoreException('只有群主可以移除成员。');
    }
    if (target.keyId == group.ownerKeyId) {
      throw const SecureStoreException('不能移除群主。');
    }
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedMembers = <AndroidGroupMemberRecord>[];
    for (final member in members) {
      updatedMembers.add(
        member.keyId == target.keyId
            ? member.copyWith(
                status: AndroidGroupMemberStatus.removed,
                trustState: AndroidGroupTrustState.unverified,
                updatedAtUnixMs: now,
              )
            : member,
      );
    }
    final shouldDissolve = androidGroupShouldAutoDissolveForMembers(
      updatedMembers,
    );
    final dissolutionReasons = shouldDissolve
        ? androidGroupDissolutionReasonCodes(updatedMembers)
        : const <String>[];
    final updatedGroup = group.copyWith(
      epoch: group.epoch + 1,
      isActive: shouldDissolve ? false : group.isActive,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'member_removed',
      group: updatedGroup,
      members: updatedMembers,
      now: now,
      extra: {
        'target_key_id': target.keyId,
        if (dissolutionReasons.isNotEmpty)
          'dissolution_reasons': dissolutionReasons,
      },
    );
    final recipients = [
      ...updatedMembers.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
      target,
    ];
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: updatedMembers,
      payload: payload,
      recipients: recipients,
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        shouldDissolve
            ? _androidGroupDissolvedText(
                '已移除群成员：${target.displayLabel}',
                dissolutionReasons,
              )
            : '已移除群成员：${target.displayLabel}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _inviteContactsToAndroidGroup({
    required AndroidGroupRecord group,
    required List<AndroidContactRecord> invitees,
  }) async {
    final identity = _requireAndroidIdentity();
    if (group.ownerKeyId != identity.keyId) {
      throw const SecureStoreException('只有群主可以邀请新成员。');
    }
    final db = await _ensureAndroidDbStore();
    final existing = await db.getGroupMembers(groupId: group.groupId);
    final existingKeys = existing.map((member) => member.keyId).toSet();
    final now = DateTime.now().millisecondsSinceEpoch;
    final newMembers = <AndroidGroupMemberRecord>[];
    for (final contact in invitees) {
      if (existingKeys.contains(contact.keyId) ||
          contact.keyId == identity.keyId) {
        continue;
      }
      newMembers.add(
        _memberFromContact(
          groupId: group.groupId,
          contact: contact,
          role: AndroidGroupMemberRole.member,
          status: AndroidGroupMemberStatus.pending,
          trustState: group.policy == AndroidGroupPolicy.consensus
              ? AndroidGroupTrustState.consensusPending
              : AndroidGroupTrustState.inviter,
          now: now,
          invitedByKeyId: identity.keyId,
        ),
      );
    }
    if (newMembers.isEmpty) {
      throw const SecureStoreException('没有可邀请的新联系人。');
    }
    final members = [...existing, ...newMembers];
    final updatedGroup = group.copyWith(
      epoch: group.epoch + 1,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'group_invite',
      group: updatedGroup,
      members: members,
      now: now,
    );
    final recipients = members.where(
      (member) => androidGroupMemberShouldReceiveMembershipControl(
        member,
        identity.keyId,
      ),
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: members,
      payload: payload,
      recipients: recipients,
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        '群邀请已发送：${group.displayName}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _showCreateAndroidGroupDialog() async {
    final createGroupLabel = context.l10n.createGroup;
    final nameController = TextEditingController();
    var policy = AndroidGroupPolicy.normal;
    final selectedKeys = <String>{};
    try {
      final result = await showDialog<Map<String, Object?>?>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) {
            final l10n = context.l10n;
            final contacts = _androidChatStore.contacts;
            return AlertDialog(
              title: Text(l10n.createGroup),
              content: SizedBox(
                width: min(420.0, MediaQuery.sizeOf(context).width - 64),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.groups_outlined),
                          labelText: l10n.groupName,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: AndroidGroupPolicy.normal,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.normalGroupShort,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                            icon: const Icon(
                              Icons.verified_user_outlined,
                              size: 18,
                            ),
                          ),
                          ButtonSegment(
                            value: AndroidGroupPolicy.verified,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.verifiedGroupShort,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                            icon: const Icon(Icons.fingerprint, size: 18),
                          ),
                          ButtonSegment(
                            value: AndroidGroupPolicy.consensus,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                l10n.consensusGroupShort,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                            icon: const Icon(
                              Icons.how_to_vote_outlined,
                              size: 18,
                            ),
                          ),
                        ],
                        selected: {policy},
                        onSelectionChanged: (value) {
                          setDialogState(() => policy = value.single);
                        },
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          l10n.groupInviteesMinimumHint,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff65716d),
                          ),
                        ),
                      ),
                      ...contacts.map(
                        (contact) => CheckboxListTile(
                          dense: true,
                          value: selectedKeys.contains(contact.keyId),
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selectedKeys.add(contact.keyId);
                              } else {
                                selectedKeys.remove(contact.keyId);
                              }
                            });
                          },
                          title: Text(
                            _contactTitle(contact),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _formatAndroidFingerprint(contact.keyId),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          secondary: _AndroidAvatar(
                            label: _contactTitle(contact),
                            seed: _androidAvatarSeedFor(contact),
                            size: 34,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(l10n.cancel),
                ),
                FilledButton.icon(
                  onPressed: selectedKeys.length < 2
                      ? null
                      : () => Navigator.of(context).pop({
                          'name': nameController.text,
                          'policy': policy,
                          'keys': selectedKeys.toList(growable: false),
                        }),
                  icon: const Icon(Icons.group_add_outlined),
                  label: Text(l10n.create),
                ),
              ],
            );
          },
        ),
      );
      if (result == null) return;
      final keys = (result['keys'] as List? ?? const [])
          .map((item) => item.toString())
          .toSet();
      final invitees = _androidChatStore.contacts
          .where((contact) => keys.contains(contact.keyId))
          .toList(growable: false);
      await _run(createGroupLabel, () async {
        await _createAndroidGroup(
          name: result['name']?.toString() ?? '',
          policy: result['policy']?.toString() ?? AndroidGroupPolicy.normal,
          invitees: invitees,
        );
      });
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _endorseAndroidConsensusMember({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord member,
  }) async {
    if (group.policy != AndroidGroupPolicy.consensus) {
      throw const SecureStoreException('该群不是共识群。');
    }
    if (!member.isAccepted) {
      throw const SecureStoreException('对方尚未接受群邀请，不能背书。');
    }
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    AndroidGroupMemberRecord? self;
    AndroidGroupMemberRecord? candidate;
    for (final item in members) {
      if (item.keyId == identity.keyId) self = item;
      if (item.keyId == member.keyId) candidate = item;
    }
    if (self == null || !self.isActive) {
      throw const SecureStoreException('只有活跃群成员可以背书新成员。');
    }
    if (candidate == null || !candidate.isAccepted) {
      throw const SecureStoreException('候选成员状态不是等待共识。');
    }
    final candidateRecord = candidate;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedGroup = group.copyWith(
      epoch: group.epoch + 1,
      updatedAtUnixMs: now,
    );
    final endorsement = _createAndroidConsensusEndorsement(
      group: updatedGroup,
      candidate: candidateRecord,
      now: now,
    );
    final payload = _groupControlPayload(
      type: 'member_endorsed',
      group: updatedGroup,
      members: members,
      now: now,
      extra: {'candidate_key_id': candidate.keyId, 'endorsement': endorsement},
    );
    final recipients = members.where(
      (item) => androidGroupMemberShouldReceiveMembershipControl(
        item,
        identity.keyId,
      ),
    );
    final locallyVerifiedMembers = [
      for (final item in members)
        item.keyId == candidateRecord.keyId
            ? item.copyWith(trustState: AndroidGroupTrustState.verified)
            : item,
    ];
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: locallyVerifiedMembers,
      payload: payload,
      recipients: recipients,
    );
    final admittedMembers = await db.getGroupMembers(groupId: group.groupId);
    final admitted = admittedMembers.any(
      (item) => item.keyId == candidateRecord.keyId && item.isActive,
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        admitted
            ? '已背书并通过共识：${candidateRecord.displayLabel}'
            : '已背书群成员：${candidateRecord.displayLabel}',
        _formatAndroidFingerprint(candidateRecord.keyId),
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _verifyAndroidGroupMember({
    required AndroidGroupRecord group,
    required AndroidGroupMemberRecord member,
  }) async {
    if (group.policy == AndroidGroupPolicy.consensus) {
      return _endorseAndroidConsensusMember(group: group, member: member);
    }
    final db = await _ensureAndroidDbStore();
    await db.updateGroupMemberState(
      groupId: group.groupId,
      keyId: member.keyId,
      status: member.status,
      trustState: AndroidGroupTrustState.verified,
      joinedAtUnixMs: member.joinedAtUnixMs,
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        '已信任群成员 fingerprint。',
        '${member.displayLabel}: ${_formatAndroidFingerprint(member.keyId)}',
      ].join('\n');
    });
  }

  Future<void> _showInviteContactsToGroupDialog(
    AndroidGroupRecord group,
  ) async {
    final existingKeys = _androidChatStore
        .membersForGroup(group.groupId)
        .map((member) => member.keyId)
        .toSet();
    final candidates = _androidChatStore.contacts
        .where((contact) => !existingKeys.contains(contact.keyId))
        .toList(growable: false);
    final selectedKeys = <String>{};
    final result = await showDialog<List<String>?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('邀请成员'),
          content: SizedBox(
            width: min(420.0, MediaQuery.sizeOf(context).width - 64),
            child: candidates.isEmpty
                ? const Text('没有可邀请的新联系人。')
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: candidates
                          .map(
                            (contact) => CheckboxListTile(
                              dense: true,
                              value: selectedKeys.contains(contact.keyId),
                              onChanged: (checked) {
                                setDialogState(() {
                                  if (checked == true) {
                                    selectedKeys.add(contact.keyId);
                                  } else {
                                    selectedKeys.remove(contact.keyId);
                                  }
                                });
                              },
                              title: Text(_contactTitle(contact)),
                              subtitle: Text(
                                _formatAndroidFingerprint(contact.keyId),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: selectedKeys.isEmpty
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(selectedKeys.toList(growable: false)),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('邀请'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.isEmpty) return;
    final invitees = _androidChatStore.contacts
        .where((contact) => result.contains(contact.keyId))
        .toList(growable: false);
    await _run('邀请群成员', () async {
      await _inviteContactsToAndroidGroup(group: group, invitees: invitees);
    });
  }

  Future<void> _renameAndroidGroup({
    required AndroidGroupRecord group,
    required String name,
  }) async {
    final identity = _requireAndroidIdentity();
    if (group.ownerKeyId != identity.keyId) {
      throw const SecureStoreException('只有群主可以修改群名称。');
    }
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw const SecureStoreException('群名称不能为空。');
    }
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedGroup = group.copyWith(
      name: normalizedName,
      epoch: group.epoch + 1,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'group_renamed',
      group: updatedGroup,
      members: members,
      now: now,
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: members,
      payload: payload,
      recipients: members.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        '群名称已更新：${updatedGroup.displayName}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _updateAndroidGroupAvatar({
    required AndroidGroupRecord group,
    required String avatarSeed,
  }) async {
    final identity = _requireAndroidIdentity();
    if (group.ownerKeyId != identity.keyId) {
      throw const SecureStoreException('只有群主可以修改群头像。');
    }
    final normalizedSeed = avatarSeed.trim();
    if (normalizedSeed.isEmpty) {
      throw const SecureStoreException('群头像标识不能为空。');
    }
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedGroup = group.copyWith(
      avatarSeed: normalizedSeed,
      epoch: group.epoch + 1,
      updatedAtUnixMs: now,
    );
    final payload = _groupControlPayload(
      type: 'group_avatar_updated',
      group: updatedGroup,
      members: members,
      now: now,
    );
    final delivery = await _broadcastAndroidGroupControl(
      group: updatedGroup,
      members: members,
      payload: payload,
      recipients: members.where(
        (member) => androidGroupMemberShouldReceiveMembershipControl(
          member,
          identity.keyId,
        ),
      ),
    );
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        '群头像已更新：${updatedGroup.displayName}',
        'avatar_seed: ${updatedGroup.displaySeed}',
        if (delivery.isNotEmpty) ...delivery,
      ].join('\n');
    });
  }

  Future<void> _showRenameAndroidGroupDialog(AndroidGroupRecord group) async {
    final controller = TextEditingController(text: group.displayName);
    try {
      final name = await showDialog<String?>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('修改群名称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.drive_file_rename_outline),
              labelText: '群名称',
            ),
            onSubmitted: (_) => Navigator.of(context).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (name == null) return;
      await _run('修改群名称', () async {
        await _renameAndroidGroup(group: group, name: name);
      });
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showUpdateAndroidGroupAvatarDialog(
    AndroidGroupRecord group,
  ) async {
    final controller = TextEditingController(text: group.displaySeed);
    try {
      final avatarSeed = await showDialog<String?>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('修改群头像'),
            content: SizedBox(
              width: min(420.0, MediaQuery.sizeOf(context).width - 64),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AndroidGroupAvatar(
                    label: group.displayName,
                    seed: controller.text.trim().isEmpty
                        ? group.displaySeed
                        : controller.text.trim(),
                    size: 64,
                    icon: _androidGroupPolicyIcon(group.policy),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.palette_outlined),
                      labelText: '群头像标识',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (_) =>
                        Navigator.of(context).pop(controller.text),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(controller.text),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (avatarSeed == null) return;
      await _run('修改群头像', () async {
        await _updateAndroidGroupAvatar(group: group, avatarSeed: avatarSeed);
      });
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showAndroidGroupDetails(AndroidGroupRecord group) async {
    var acceptingInvite = false;
    var acceptInviteHint = '';
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) => StatefulBuilder(
          builder: (pageContext, setPageState) {
            final activeGroup =
                _androidChatStore.findGroup(group.groupId) ?? group;
            final members = _androidChatStore.membersForGroup(group.groupId);
            final identityKeyId = _secureIdentity?.keyId ?? '';
            AndroidGroupMemberRecord? self;
            for (final member in members) {
              if (member.keyId == identityKeyId) {
                self = member;
                break;
              }
            }
            final isOwner = activeGroup.ownerKeyId == identityKeyId;
            final canAccept =
                _pendingAndroidGroupInviteForLocalIdentity(activeGroup) != null;
            final membersAfterLocalLeave = [
              for (final member in members)
                member.keyId == identityKeyId
                    ? member.copyWith(status: AndroidGroupMemberStatus.left)
                    : member,
            ];
            final ownerCanLeave =
                !isOwner ||
                androidGroupShouldAutoDissolveForMembers(
                  membersAfterLocalLeave,
                );
            final canLeave = self != null && self.isActive && ownerCanLeave;
            return Scaffold(
              appBar: AppBar(
                title: Text(activeGroup.displayName),
                actions: [
                  if (isOwner)
                    IconButton(
                      tooltip: '修改群名称',
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _showRenameAndroidGroupDialog(activeGroup),
                            ),
                      icon: const Icon(Icons.drive_file_rename_outline),
                    ),
                  if (isOwner)
                    IconButton(
                      tooltip: '修改群头像',
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _showUpdateAndroidGroupAvatarDialog(activeGroup),
                            ),
                      icon: const Icon(Icons.palette_outlined),
                    ),
                  if (isOwner)
                    IconButton(
                      tooltip: '邀请成员',
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _showInviteContactsToGroupDialog(activeGroup),
                            ),
                      icon: const Icon(Icons.person_add_alt_1_outlined),
                    ),
                ],
              ),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    _CommandGroup(
                      title: '群组',
                      children: [
                        ListTile(
                          tileColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Color(0xffd9e2de)),
                          ),
                          leading: _AndroidGroupAvatar(
                            label: activeGroup.displayName,
                            seed: activeGroup.displaySeed,
                            size: 44,
                            icon: _androidGroupPolicyIcon(activeGroup.policy),
                          ),
                          title: Text(activeGroup.displayName),
                          subtitle: Text(
                            _androidGroupSubtitle(context, activeGroup),
                          ),
                        ),
                        if (canAccept)
                          _ActionButton(
                            icon: Icons.check_circle_outline,
                            label: acceptingInvite ? '正在接受群邀请...' : '接受群邀请',
                            enabled: !_busy && !acceptingInvite,
                            busy: acceptingInvite,
                            onPressed: () => unawaited(() async {
                              setPageState(() {
                                acceptingInvite = true;
                                acceptInviteHint = '正在接受群邀请并同步给群成员...';
                              });
                              await _run('接受群邀请', () async {
                                await _acceptAndroidGroupInvite(activeGroup);
                              });
                              if (!pageContext.mounted) return;
                              var accepted = false;
                              for (final member
                                  in _androidChatStore.membersForGroup(
                                    group.groupId,
                                  )) {
                                if (member.keyId == identityKeyId &&
                                    !member.isPending) {
                                  accepted = true;
                                  break;
                                }
                              }
                              setPageState(() {
                                acceptingInvite = false;
                                acceptInviteHint = accepted
                                    ? '群邀请已接受，正在等待其它成员同步。'
                                    : _details.trim().isEmpty
                                    ? '处理结束，请查看顶部状态。'
                                    : _details;
                              });
                            }()),
                          ),
                        if (acceptInviteHint.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                if (acceptingInvite) ...[
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: Text(
                                    acceptInviteHint,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xff65716d),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (self != null && self.isActive)
                          _ActionButton(
                            icon: Icons.logout_outlined,
                            label: canLeave ? '退出群组' : '群主退出后群内仍超过 2 人',
                            enabled: !_busy && canLeave,
                            onPressed: () => unawaited(
                              _run('退出群组', () async {
                                await _leaveAndroidGroup(
                                  activeGroup,
                                  onLocalLeaveApplied: () {
                                    if (pageContext.mounted) {
                                      Navigator.of(pageContext).pop();
                                    }
                                  },
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _CommandGroup(
                      title: '成员',
                      children: members
                          .map(
                            (member) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Material(
                                color: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: const BorderSide(
                                    color: Color(0xffd9e2de),
                                  ),
                                ),
                                child: Builder(
                                  builder: (context) {
                                    final canEndorseConsensus =
                                        activeGroup.policy ==
                                            AndroidGroupPolicy.consensus &&
                                        self?.isActive == true &&
                                        member.keyId != identityKeyId &&
                                        member.isAccepted &&
                                        !member.isLocallyTrusted;
                                    final canTrustFingerprint =
                                        activeGroup.policy !=
                                            AndroidGroupPolicy.consensus &&
                                        member.keyId != identityKeyId &&
                                        !member.isLocallyTrusted;
                                    return ListTile(
                                      leading: _AndroidAvatar(
                                        label: member.displayLabel,
                                        seed: member.keyId,
                                        size: 40,
                                      ),
                                      title: Text(
                                        member.isOwner
                                            ? '${member.displayLabel}（群主）'
                                            : member.displayLabel,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: SelectableText(
                                        [
                                          _androidGroupMemberStatusLabel(
                                            member,
                                          ),
                                          _androidGroupMemberTrustLabel(member),
                                          _formatAndroidFingerprint(
                                            member.keyId,
                                          ),
                                        ].join('\n'),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          height: 1.25,
                                        ),
                                      ),
                                      trailing: Wrap(
                                        spacing: 2,
                                        children: [
                                          if (canEndorseConsensus ||
                                              canTrustFingerprint)
                                            IconButton(
                                              tooltip: canEndorseConsensus
                                                  ? '背书入群'
                                                  : '信任 fingerprint',
                                              onPressed: _busy
                                                  ? null
                                                  : () => unawaited(
                                                      _run(
                                                        canEndorseConsensus
                                                            ? '背书群成员'
                                                            : '信任群成员',
                                                        () async {
                                                          await _verifyAndroidGroupMember(
                                                            group: activeGroup,
                                                            member: member,
                                                          );
                                                          setPageState(() {});
                                                        },
                                                      ),
                                                    ),
                                              icon: Icon(
                                                canEndorseConsensus
                                                    ? Icons.how_to_vote_outlined
                                                    : Icons.fingerprint,
                                                size: 20,
                                              ),
                                            ),
                                          if (isOwner &&
                                              member.keyId != identityKeyId &&
                                              member.status !=
                                                  AndroidGroupMemberStatus
                                                      .removed)
                                            IconButton(
                                              tooltip: '移除成员',
                                              onPressed: _busy
                                                  ? null
                                                  : () => unawaited(
                                                      _run('移除群成员', () async {
                                                        await _removeAndroidGroupMember(
                                                          group: activeGroup,
                                                          target: member,
                                                        );
                                                        setPageState(() {});
                                                      }),
                                                    ),
                                              icon: const Icon(
                                                Icons.person_remove_outlined,
                                                size: 20,
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _androidGroupMemberStatusLabel(AndroidGroupMemberRecord member) {
    return switch (member.status) {
      AndroidGroupMemberStatus.active => '状态：已加入',
      AndroidGroupMemberStatus.pending => '状态：待接受',
      AndroidGroupMemberStatus.accepted => '状态：等待共识',
      AndroidGroupMemberStatus.left => '状态：已退出',
      AndroidGroupMemberStatus.removed => '状态：已移除',
      _ => '状态：${member.status}',
    };
  }

  String _androidGroupMemberTrustLabel(AndroidGroupMemberRecord member) {
    return switch (member.trustState) {
      AndroidGroupTrustState.verified => '信任：已核对 fingerprint',
      AndroidGroupTrustState.inviter => '信任：邀请者背书',
      AndroidGroupTrustState.consensusPending => '信任：等待共识',
      AndroidGroupTrustState.consensusAdmitted => '信任：共识通过',
      _ => '信任：未验证',
    };
  }

  Future<void> _editSelectedAndroidContactRemark() async {
    if (_busy) return;
    final contact = _requireSelectedAndroidContact();
    final controller = TextEditingController(text: contact.remark ?? '');
    try {
      final remark = await showDialog<String?>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('联系人备注'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '备注名',
              hintText: contact.displayName,
              helperText: '原名：${contact.displayName}',
            ),
            onSubmitted: (_) => Navigator.of(context).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('清除备注'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (remark == null) return;
      await _run('保存联系人备注', () async {
        final db = await _ensureAndroidDbStore();
        await db.updateContactRemark(keyId: contact.keyId, remark: remark);
        await _refreshAndroidChatStore();
        if (!mounted) return;
        final updated = AndroidDbStore.instance.isOpen
            ? await db.getContact(contact.keyId)
            : null;
        setState(() {
          _details = [
            remark.trim().isEmpty ? '已清除联系人备注。' : '已保存联系人备注。',
            'contact: ${updated?.displayLabel ?? contact.displayLabel} / ${contact.keyId}',
            '原名: ${contact.displayName}',
          ].join('\n');
        });
      });
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteAndroidContactFromUi(AndroidContactRecord contact) async {
    if (_busy) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.deleteContactTitle),
            content: Text(
              context.l10n.deleteContactMessage(_contactTitle(contact)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.person_remove_outlined),
                label: Text(context.l10n.delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    await _run('删除联系人', () async {
      final result = await _deleteAndroidContact(contact);
      if (!mounted) return;
      setState(() {
        _details = [
          result['deleted'] == true
              ? '已删除联系人：${result['display_name']}'
              : '联系人已不在本地列表。',
          result['delivery']?.toString() ?? '',
        ].where((item) => item.trim().isNotEmpty).join('\n');
      });
    });
  }

  Future<Map<String, Object?>> _deleteAndroidContact(
    AndroidContactRecord contact,
  ) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final current = _androidChatStore.findContact(contact.keyId) ?? contact;
    final db = await _ensureAndroidDbStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    var delivery = '';
    try {
      final messageCounter = await db.getNextMessageCounter();
      final envelope = _encryptAndroidContactControlEnvelope(
        recipient: current,
        payload: _contactControlPayload(
          type: 'contact_deleted',
          target: current,
          now: now,
        ),
        messageCounter: messageCounter,
      );
      await db.setNextMessageCounter(
        androidAdvanceMessageCounter(envelope.messageCounter),
      );
      delivery = await _deliverAndroidOpaqueEnvelopeToContact(
        contact: current,
        envelopeId: envelope.envelopeId,
        envelopeBase64: envelope.envelopeBase64,
      );
    } catch (error) {
      delivery = '自动删除通知未送达：$error';
    }

    final deleted = await db.deleteContact(current.keyId);
    _androidIncomingMessageCounts = {
      for (final entry in _androidIncomingMessageCounts.entries)
        if (entry.key != current.keyId) entry.key: entry.value,
    };
    if (_selectedAndroidContactKeyId == current.keyId) {
      _selectedAndroidContactKeyId = null;
    }
    await _refreshAndroidChatStore();
    return {
      'key_id': current.keyId,
      'display_name': _contactTitle(current),
      'deleted': deleted > 0,
      'delivery': delivery,
    };
  }

  Future<NativeIntroBundle> _createAndroidIntroBundle({
    int ttlSeconds = 300,
  }) async {
    final identity = _requireAndroidIdentity();
    final p2pStatus = await _ensureAndroidP2pListening();
    return _nativeCore.createIntroBundle(
      identityJson: identity.identityJson,
      deviceId: _androidDeviceIdFor(identity),
      p2pTicket: p2pStatus.ticket,
      ttlSeconds: ttlSeconds,
    );
  }

  Future<AndroidMessageRecord> _saveOutgoingAndroidText({
    required AndroidContactRecord contact,
    required String text,
  }) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final messageCounter = await db.getNextMessageCounter();
    final outbound = _nativeCore.encryptOpaqueText(
      identityJson: identity.identityJson,
      recipientContactJson: contact.contactJson,
      text: text,
      messageCounter: messageCounter,
    );
    final message = AndroidMessageRecord(
      envelopeId: outbound.envelopeId,
      conversationId: outbound.conversationId,
      direction: 'outgoing',
      peerKeyId: contact.keyId,
      peerDisplayName: _contactTitle(contact),
      createdAtUnixMs: outbound.createdAtUnixMs,
      messageCounter: outbound.messageCounter,
      text: outbound.text,
      opaqueEnvelopeBase64: outbound.envelopeBase64,
      deliveryStatus: AndroidDeliveryStatus.created,
    );
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(outbound.messageCounter),
    );
    await db.addMessage(message);
    await _refreshAndroidChatStore();
    return message;
  }

  String _androidOnlineFileTooLargeMessage() =>
      '在线发送文件最大支持 ${_formatByteCount(_androidOnlineFileMaxBytes)}。'
      '请使用密封生成加密文件后自行发送。';

  Future<_AndroidPickedFileScan> _scanAndroidPickedFile(
    AndroidPickedFile file, {
    int? maxBytes = _androidOnlineFileMaxBytes,
    String? tooLargeMessage,
    int chunkSizeBytes = _androidOnlineFileChunkBytes,
  }) async {
    final knownSize = file.sizeBytes;
    if (maxBytes != null && knownSize != null && knownSize > maxBytes) {
      throw SecureStoreException(
        tooLargeMessage ?? '文件大小超出上限：${_formatByteCount(maxBytes)}。',
      );
    }

    final digestSink = _AndroidDigestSink();
    final digestInput = crypto.sha256.startChunkedConversion(digestSink);
    final chunkHashes = <String>[];
    var totalSize = 0;

    while (true) {
      if (knownSize != null && totalSize >= knownSize) {
        break;
      }
      final requestedLength = knownSize == null
          ? chunkSizeBytes
          : min(chunkSizeBytes, knownSize - totalSize);
      if (requestedLength <= 0) {
        break;
      }
      final chunkBytes = await _secureStore.readPickedFileChunk(
        uri: file.uri,
        offset: totalSize,
        length: requestedLength,
      );
      if (chunkBytes.isEmpty) {
        break;
      }
      totalSize += chunkBytes.length;
      if (maxBytes != null && totalSize > maxBytes) {
        throw SecureStoreException(
          tooLargeMessage ?? '文件大小超出上限：${_formatByteCount(maxBytes)}。',
        );
      }
      digestInput.add(chunkBytes);
      chunkHashes.add(_sha256Base64Url(chunkBytes));
      if (chunkBytes.length < requestedLength) {
        break;
      }
    }

    digestInput.close();
    if (knownSize != null && totalSize != knownSize) {
      throw SecureStoreException(
        '文件读取不完整：期望 ${_formatByteCount(knownSize)}，'
        '实际 ${_formatByteCount(totalSize)}。',
      );
    }
    if (totalSize == 0 && chunkHashes.isEmpty) {
      chunkHashes.add(_sha256Base64Url(Uint8List(0)));
    }
    final digest = digestSink.digest;
    if (digest == null) {
      throw const SecureStoreException('无法计算文件哈希。');
    }
    return _AndroidPickedFileScan(
      totalSize: totalSize,
      fileSha256: _digestBase64Url(digest),
      chunkHashes: chunkHashes,
    );
  }

  Future<Uint8List> _readAndroidPickedFileChunkForSend({
    required AndroidPickedFile file,
    required int chunkIndex,
    required int totalSize,
    int chunkSizeBytes = _androidOnlineFileChunkBytes,
  }) async {
    if (totalSize == 0) {
      return Uint8List(0);
    }
    final offset = chunkIndex * chunkSizeBytes;
    final length = min(chunkSizeBytes, totalSize - offset);
    if (length <= 0) {
      throw SecureStoreException('无效文件分片：$chunkIndex。');
    }
    final chunkBytes = await _secureStore.readPickedFileChunk(
      uri: file.uri,
      offset: offset,
      length: length,
    );
    if (chunkBytes.length != length) {
      throw SecureStoreException(
        '文件分片读取不完整：$chunkIndex，期望 $length bytes，'
        '实际 ${chunkBytes.length} bytes。',
      );
    }
    return chunkBytes;
  }

  Future<Uint8List> _readAndroidPickedFileBytes(
    AndroidPickedFile file, {
    void Function(int bytesRead, int? totalBytes)? onProgress,
  }) async {
    final builder = BytesBuilder(copy: false);
    final knownSize = file.sizeBytes;
    var totalSize = 0;
    while (true) {
      if (knownSize != null && totalSize >= knownSize) {
        break;
      }
      final requestedLength = knownSize == null
          ? _androidOnlineFileChunkBytes
          : min(_androidOnlineFileChunkBytes, knownSize - totalSize);
      if (requestedLength <= 0) {
        break;
      }
      final chunkBytes = await _secureStore.readPickedFileChunk(
        uri: file.uri,
        offset: totalSize,
        length: requestedLength,
      );
      if (chunkBytes.isEmpty) {
        break;
      }
      totalSize += chunkBytes.length;
      builder.add(chunkBytes);
      onProgress?.call(totalSize, knownSize);
      if (chunkBytes.length < requestedLength) {
        break;
      }
    }
    if (knownSize != null && totalSize != knownSize) {
      throw SecureStoreException(
        '文件读取不完整：期望 ${_formatByteCount(knownSize)}，'
        '实际 ${_formatByteCount(totalSize)}。',
      );
    }
    return builder.toBytes();
  }

  Future<AndroidMessageRecord> _saveOutgoingAndroidFile({
    required AndroidContactRecord contact,
    required AndroidPickedFile file,
  }) async {
    final scan = await _scanAndroidPickedFile(
      file,
      tooLargeMessage: _androidOnlineFileTooLargeMessage(),
    );
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final messageCounter = await db.getNextMessageCounter();
    final fileName = file.name.trim().isEmpty ? 'file' : file.name.trim();
    final mime = file.mime.trim().isEmpty
        ? 'application/octet-stream'
        : file.mime.trim();
    final transferId = _randomAndroidTransferId();
    final chunkCount = scan.chunkHashes.length;
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(messageCounter, chunkCount + 1),
    );

    final manifestPayload = <String, Object?>{
      'version': 1,
      'kind': 'file_manifest',
      'transfer_id': transferId,
      'filename': fileName,
      'mime': mime,
      'total_size': scan.totalSize,
      'chunk_size': _androidOnlineFileChunkBytes,
      'chunk_count': chunkCount,
      'file_sha256': scan.fileSha256,
      'chunk_sha256': scan.chunkHashes,
    };
    final manifestJson = jsonEncode(manifestPayload);
    final outbound = _nativeCore.encryptOpaqueFile(
      identityJson: identity.identityJson,
      recipientContactJson: contact.contactJson,
      filename: '$fileName.manifest.json',
      mime: _androidFileManifestMime,
      payloadBytes: Uint8List.fromList(utf8.encode(manifestJson)),
      messageCounter: messageCounter,
    );
    final message = AndroidMessageRecord(
      envelopeId: outbound.envelopeId,
      conversationId: outbound.conversationId,
      direction: 'outgoing',
      peerKeyId: contact.keyId,
      peerDisplayName: _contactTitle(contact),
      createdAtUnixMs: outbound.createdAtUnixMs,
      messageCounter: outbound.messageCounter,
      text: _androidFileMessageText(fileName, scan.totalSize),
      opaqueEnvelopeBase64: '',
      deliveryStatus: AndroidDeliveryStatus.created,
    );
    await db.saveOutgoingFileTransfer(
      transferId: transferId,
      messageEnvelopeId: outbound.envelopeId,
      peerKeyId: contact.keyId,
      peerDisplayName: _contactTitle(contact),
      createdAtUnixMs: outbound.createdAtUnixMs,
      messageCounter: outbound.messageCounter,
      filename: fileName,
      mime: mime,
      totalSize: scan.totalSize,
      chunkSize: _androidOnlineFileChunkBytes,
      chunkCount: chunkCount,
      fileSha256: scan.fileSha256,
      manifestEnvelopeId: outbound.envelopeId,
      manifestEnvelopeBase64: outbound.envelopeBase64,
      manifestJson: manifestJson,
      chunks: const [],
    );
    for (var index = 0; index < chunkCount; index += 1) {
      final chunkBytes = await _readAndroidPickedFileChunkForSend(
        file: file,
        chunkIndex: index,
        totalSize: scan.totalSize,
      );
      final chunkSha256 = _sha256Base64Url(chunkBytes);
      if (chunkSha256 != scan.chunkHashes[index]) {
        throw SecureStoreException('文件分片哈希校验失败：$index。');
      }
      final chunkPayload = <String, Object?>{
        'version': 1,
        'kind': 'file_chunk',
        'transfer_id': transferId,
        'chunk_index': index,
        'chunk_count': chunkCount,
        'chunk_sha256': chunkSha256,
        'data_b64': _encodeOpaqueEnvelopeBase64(chunkBytes),
      };
      final outboundChunk = _nativeCore.encryptOpaqueFile(
        identityJson: identity.identityJson,
        recipientContactJson: contact.contactJson,
        filename: '$fileName.part${index.toString().padLeft(4, '0')}',
        mime: _androidFileChunkMime,
        payloadBytes: Uint8List.fromList(utf8.encode(jsonEncode(chunkPayload))),
        messageCounter: androidAdvanceMessageCounter(messageCounter, index + 1),
      );
      await db.saveOutgoingFileTransferChunk(
        transferId: transferId,
        chunkIndex: index,
        chunkSha256: chunkSha256,
        chunkSize: chunkBytes.length,
        envelopeId: outboundChunk.envelopeId,
        envelopeBase64: outboundChunk.envelopeBase64,
      );
    }
    await db.addMessage(message);
    await _refreshAndroidChatStore();
    return message;
  }

  Future<Map<String, Object?>> _sendAndroidP2pText({
    required String text,
    String? recipientKeyId,
    String? serverUrl,
    bool useServerFallback = true,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    if (text.trim().isEmpty) {
      throw const SecureStoreException('请先输入消息内容。');
    }
    final contact = recipientKeyId == null || recipientKeyId.trim().isEmpty
        ? _requireSelectedAndroidContact()
        : (_androidChatStore.findContact(recipientKeyId.trim()) ??
              (throw SecureStoreException('未知收件人：${recipientKeyId.trim()}')));
    await _ensureAndroidP2pListening();
    final message = await _saveOutgoingAndroidText(
      contact: contact,
      text: text,
    );
    return _deliverAndroidP2pMessage(
      message,
      serverUrl: serverUrl,
      useServerFallback: useServerFallback,
    );
  }

  Future<Map<String, Object?>> _sendAndroidP2pFile({
    required AndroidPickedFile file,
    String? recipientKeyId,
    String? serverUrl,
    bool useServerFallback = true,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final contact = recipientKeyId == null || recipientKeyId.trim().isEmpty
        ? _requireSelectedAndroidContact()
        : (_androidChatStore.findContact(recipientKeyId.trim()) ??
              (throw SecureStoreException('未知收件人：${recipientKeyId.trim()}')));
    await _ensureAndroidP2pListening();
    final message = await _saveOutgoingAndroidFile(
      contact: contact,
      file: file,
    );
    return _deliverAndroidP2pMessage(
      message,
      serverUrl: serverUrl,
      useServerFallback: useServerFallback,
    );
  }

  Future<AndroidPickedFile> _androidPickedFileFromDevicePath({
    required String? path,
    String? name,
    String? mime,
  }) async {
    final normalizedPath = path?.trim() ?? '';
    if (normalizedPath.isEmpty) {
      throw const SecureStoreException('ADB file command requires path.');
    }
    final file = File(normalizedPath);
    if (!await file.exists()) {
      throw SecureStoreException(
        'ADB file path does not exist: $normalizedPath',
      );
    }
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw SecureStoreException(
        'ADB file path is not a file: $normalizedPath',
      );
    }
    final normalizedName = (name == null || name.trim().isEmpty)
        ? p.basename(normalizedPath)
        : name.trim();
    final normalizedMime = (mime == null || mime.trim().isEmpty)
        ? 'application/octet-stream'
        : mime.trim();
    return AndroidPickedFile(
      name: normalizedName,
      mime: normalizedMime,
      uri: Uri.file(file.absolute.path).toString(),
      sizeBytes: stat.size,
    );
  }

  Future<Map<String, Object?>> _deliverAndroidP2pMessage(
    AndroidMessageRecord message, {
    String? serverUrl,
    bool useServerFallback = true,
  }) async {
    final contact = _androidChatStore.findContact(message.peerKeyId);
    if (contact == null) {
      final detail = '联系人不存在：${message.peerKeyId}';
      await _markAndroidMessageDelivery(
        message.envelopeId,
        AndroidDeliveryStatus.pending,
        detail,
      );
      return {
        'ack': {
          'status': 'pending',
          'envelope_id': message.envelopeId,
          'detail': detail,
        },
        'message': _messageToAdbJson(
          message.copyWith(
            deliveryStatus: AndroidDeliveryStatus.pending,
            deliveryDetail: detail,
          ),
        ),
      };
    }
    final db = await _ensureAndroidDbStore();
    final fileTransfer = await db.getFileTransferByMessageEnvelopeId(
      message.envelopeId,
    );
    if (fileTransfer != null) {
      return _deliverAndroidP2pFileTransfer(
        message,
        contact,
        fileTransfer,
        serverUrl: serverUrl,
        useServerFallback: useServerFallback,
      );
    }
    final ticket = contact.p2pTicket?.trim() ?? '';
    if (ticket.isEmpty) {
      final detail = '联系人 ${_contactTitle(contact)} 暂无直连信息';
      return _deliverAndroidServerFallbackOrPending(
        message,
        contact,
        detail,
        serverUrl: serverUrl,
        useServerFallback: useServerFallback,
      );
    }
    final parsedTicket = AndroidP2pTicket.tryParse(ticket);
    if (parsedTicket == null) {
      final detail = '联系人 ${_contactTitle(contact)} 的直连信息无效';
      return _deliverAndroidServerFallbackOrPending(
        message,
        contact,
        detail,
        serverUrl: serverUrl,
        useServerFallback: useServerFallback,
      );
    }
    if (parsedTicket.isExpired) {
      final detail = '联系人 ${_contactTitle(contact)} 的直连信息已失效';
      return _deliverAndroidServerFallbackOrPending(
        message,
        contact,
        detail,
        serverUrl: serverUrl,
        useServerFallback: useServerFallback,
      );
    }
    try {
      final ack = await _sendAndroidP2pEnvelopeWithCooldown(
        recipientKeyId: contact.keyId,
        envelopeId: message.envelopeId,
        ticket: ticket,
        envelopeBytes: _decodeOpaqueEnvelopeBase64(
          message.opaqueEnvelopeBase64,
        ),
      );
      await _markAndroidMessageDelivery(
        message.envelopeId,
        AndroidDeliveryStatus.sent,
        ack.detail,
      );
      return {
        'ack': ack.toJson(),
        'message': _messageToAdbJson(
          message.copyWith(
            deliveryStatus: AndroidDeliveryStatus.sent,
            deliveryDetail: ack.detail,
          ),
        ),
      };
    } catch (error) {
      final detail = error.toString();
      return _deliverAndroidServerFallbackOrPending(
        message,
        contact,
        detail,
        serverUrl: serverUrl,
        useServerFallback: useServerFallback,
      );
    }
  }

  Future<List<_AndroidEnvelopeToSend>> _androidFileTransferEnvelopes(
    Map<String, Object?> transfer,
  ) async {
    final transferId = transfer['transfer_id']?.toString() ?? '';
    if (transferId.isEmpty) {
      throw const SecureStoreException('文件传输缺少 transfer_id。');
    }
    final db = await _ensureAndroidDbStore();
    final chunks = await db.getFileTransferChunks(transferId);
    final envelopes = <_AndroidEnvelopeToSend>[];
    for (final chunk in chunks) {
      final envelopeId = chunk['envelope_id']?.toString() ?? '';
      final envelopeBase64 = chunk['envelope_b64']?.toString() ?? '';
      final index = (chunk['chunk_index'] as num?)?.toInt() ?? -1;
      if (envelopeId.isEmpty || envelopeBase64.isEmpty || index < 0) {
        throw SecureStoreException('文件分片 $index 缺少待发送密文。');
      }
      envelopes.add(
        _AndroidEnvelopeToSend(
          envelopeId: envelopeId,
          envelopeBase64: envelopeBase64,
          ordinal: index,
        ),
      );
    }
    final manifestEnvelopeId =
        transfer['manifest_envelope_id']?.toString() ?? '';
    final manifestEnvelopeBase64 =
        transfer['manifest_envelope_b64']?.toString() ?? '';
    if (manifestEnvelopeId.isEmpty || manifestEnvelopeBase64.isEmpty) {
      throw const SecureStoreException('文件传输缺少 manifest 密文。');
    }
    envelopes.add(
      _AndroidEnvelopeToSend(
        envelopeId: manifestEnvelopeId,
        envelopeBase64: manifestEnvelopeBase64,
        ordinal: envelopes.length,
      ),
    );
    envelopes.sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return envelopes;
  }

  Future<void> _sendAndroidP2pEnvelopeBatch({
    required String recipientKeyId,
    required String ticket,
    required List<_AndroidEnvelopeToSend> envelopes,
  }) async {
    for (final envelope in envelopes) {
      await _sendAndroidP2pEnvelopeWithCooldown(
        recipientKeyId: recipientKeyId,
        envelopeId: envelope.envelopeId,
        allowDeferred: true,
        ticket: ticket,
        envelopeBytes: _decodeOpaqueEnvelopeBase64(envelope.envelopeBase64),
      );
    }
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    for (final envelope in envelopes) {
      final row = await db.relayHa.outgoing(
        senderKeyId: identity.keyId,
        recipientKeyId: recipientKeyId,
        envelopeId: envelope.envelopeId,
      );
      if (row?['delivery_state'] != 'delivered') {
        throw const AndroidP2pException('文件尚未取得全部分片的业务接收证明。');
      }
    }
  }

  Future<void> _stageAndroidEnvelopeBatch(
    String recipientKeyId,
    List<_AndroidEnvelopeToSend> envelopes,
  ) async {
    final db = await _ensureAndroidDbStore();
    final relay = await _getAndroidRelayClient();
    await AndroidRelayHaAdapter.stageBatch(
      db: db,
      clusterId: relay.clusterId,
      senderKeyId: _requireAndroidIdentity().keyId,
      recipientKeyId: recipientKeyId,
      envelopes: {
        for (final envelope in envelopes)
          envelope.envelopeId: envelope.envelopeBase64,
      },
    );
  }

  Future<Map<String, Object?>> _markAndroidFileTransferDelivery({
    required AndroidMessageRecord message,
    required Map<String, Object?> transfer,
    required String status,
    required String detail,
    required String route,
    required int envelopeCount,
  }) async {
    final db = await _ensureAndroidDbStore();
    await _markAndroidMessageDelivery(message.envelopeId, status, detail);
    await db.updateFileTransferStatus(
      transferId: transfer['transfer_id']?.toString() ?? '',
      status: status,
    );
    return {
      'ack': {
        'status': status == AndroidDeliveryStatus.sent ? 'ok' : status,
        'envelope_id': message.envelopeId,
        'detail': detail,
        'route': route,
        'envelope_count': envelopeCount,
      },
      'message': _messageToAdbJson(
        message.copyWith(deliveryStatus: status, deliveryDetail: detail),
      ),
    };
  }

  Future<Map<String, Object?>> _markAndroidFileTransferPending({
    required AndroidMessageRecord message,
    required Map<String, Object?> transfer,
    required String detail,
  }) async {
    final db = await _ensureAndroidDbStore();
    await _markAndroidMessageDelivery(
      message.envelopeId,
      AndroidDeliveryStatus.pending,
      detail,
    );
    await db.updateFileTransferStatus(
      transferId: transfer['transfer_id']?.toString() ?? '',
      status: AndroidDeliveryStatus.pending,
    );
    return {
      'ack': {
        'status': 'pending',
        'envelope_id': message.envelopeId,
        'detail': detail,
      },
      'message': _messageToAdbJson(
        message.copyWith(
          deliveryStatus: AndroidDeliveryStatus.pending,
          deliveryDetail: detail,
        ),
      ),
    };
  }

  Future<Map<String, Object?>> _deliverAndroidP2pFileTransfer(
    AndroidMessageRecord message,
    AndroidContactRecord contact,
    Map<String, Object?> transfer, {
    String? serverUrl,
    bool useServerFallback = true,
  }) async {
    final envelopes = await _androidFileTransferEnvelopes(transfer);
    await _stageAndroidEnvelopeBatch(contact.keyId, envelopes);
    Future<Map<String, Object?>> fallback(String detail) {
      if (!useServerFallback) {
        return _markAndroidFileTransferPending(
          message: message,
          transfer: transfer,
          detail: detail,
        );
      }
      return _deliverAndroidServerFileTransfer(
        message,
        contact,
        transfer,
        envelopes,
        detail,
        serverUrl: serverUrl,
      );
    }

    final ticket = contact.p2pTicket?.trim() ?? '';
    if (ticket.isEmpty) {
      return fallback('联系人 ${_contactTitle(contact)} 暂无直连信息');
    }
    final parsedTicket = AndroidP2pTicket.tryParse(ticket);
    if (parsedTicket == null) {
      return fallback('联系人 ${_contactTitle(contact)} 的直连信息无效');
    }
    if (parsedTicket.isExpired) {
      return fallback('联系人 ${_contactTitle(contact)} 的直连信息已失效');
    }
    try {
      await _sendAndroidP2pEnvelopeBatch(
        recipientKeyId: contact.keyId,
        ticket: ticket,
        envelopes: envelopes,
      );
      final detail = 'P2P 文件分片已送达：${envelopes.length} 个密文 envelope';
      return _markAndroidFileTransferDelivery(
        message: message,
        transfer: transfer,
        status: AndroidDeliveryStatus.sent,
        detail: detail,
        route: 'p2p_chunked',
        envelopeCount: envelopes.length,
      );
    } catch (error) {
      return fallback(error.toString());
    }
  }

  Future<Map<String, Object?>> _deliverAndroidServerFileTransfer(
    AndroidMessageRecord message,
    AndroidContactRecord contact,
    Map<String, Object?> transfer,
    List<_AndroidEnvelopeToSend> envelopes,
    String p2pFailureDetail, {
    String? serverUrl,
  }) async {
    final client = _createEnvelopeServerClient(serverUrl);
    try {
      String routeDetail = '';
      var activeContact = contact;
      final deviceId = contact.deviceId?.trim() ?? '';
      if (deviceId.isNotEmpty) {
        final route = await client.lookupRoute(
          ownerKeyId: contact.keyId,
          deviceId: deviceId,
        );
        final endpoint = route.endpoint;
        if (endpoint != null && endpoint.p2pTicket.trim().isNotEmpty) {
          final db = await _ensureAndroidDbStore();
          activeContact = contact.copyWith(
            deviceId: endpoint.deviceId,
            p2pTicket: endpoint.p2pTicket,
            p2pTicketUpdatedAtUnixMs: endpoint.createdAtUnixMs,
          );
          await db.upsertContact(activeContact);
          await _refreshAndroidChatStore();
          if (!endpoint.isExpired) {
            try {
              await _sendAndroidP2pEnvelopeBatch(
                recipientKeyId: activeContact.keyId,
                ticket: endpoint.p2pTicket,
                envelopes: envelopes,
              );
              final detail =
                  '服务器已刷新直连信息; P2P 文件分片已送达：${envelopes.length} 个密文 envelope';
              return _markAndroidFileTransferDelivery(
                message: message,
                transfer: transfer,
                status: AndroidDeliveryStatus.sent,
                detail: detail,
                route: 'server_route_p2p_chunked',
                envelopeCount: envelopes.length,
              );
            } catch (error) {
              routeDetail = '服务器直连重试失败: $error';
            }
          } else {
            routeDetail = '服务器直连信息已失效';
          }
        } else {
          routeDetail = '服务器暂无直连信息';
        }
      } else {
        routeDetail = '联系人暂无设备路由';
      }

      for (final envelope in envelopes) {
        await _submitAndroidEnvelopeToServer(
          client: client,
          envelopeId: envelope.envelopeId,
          recipientKeyId: activeContact.keyId,
          envelopeBase64: envelope.envelopeBase64,
        );
      }
      final detail = [
        '已写入 Envelope Server 离线邮箱：${envelopes.length} 个文件分片 envelope',
        '直连: $p2pFailureDetail',
        routeDetail,
      ].where((item) => item.trim().isNotEmpty).join(' / ');
      return _markAndroidFileTransferDelivery(
        message: message,
        transfer: transfer,
        status: AndroidDeliveryStatus.serverMailbox,
        detail: detail,
        route: 'server_mailbox_chunked',
        envelopeCount: envelopes.length,
      );
    } catch (error) {
      final detail = '直连: $p2pFailureDetail\n服务器: $error';
      return _markAndroidFileTransferPending(
        message: message,
        transfer: transfer,
        detail: detail,
      );
    } finally {
      client.close();
    }
  }

  Future<Map<String, Object?>> _deliverAndroidServerFallbackOrPending(
    AndroidMessageRecord message,
    AndroidContactRecord contact,
    String p2pFailureDetail, {
    String? serverUrl,
    bool useServerFallback = true,
  }) async {
    if (!useServerFallback) {
      await _markAndroidMessageDelivery(
        message.envelopeId,
        AndroidDeliveryStatus.pending,
        p2pFailureDetail,
      );
      return {
        'ack': {
          'status': 'pending',
          'envelope_id': message.envelopeId,
          'detail': p2pFailureDetail,
        },
        'message': _messageToAdbJson(
          message.copyWith(
            deliveryStatus: AndroidDeliveryStatus.pending,
            deliveryDetail: p2pFailureDetail,
          ),
        ),
      };
    }
    try {
      return await _deliverAndroidServerMessage(
        message,
        contact,
        p2pFailureDetail,
        serverUrl: serverUrl,
      );
    } catch (error) {
      final detail = '直连: $p2pFailureDetail\n服务器: $error';
      await _markAndroidMessageDelivery(
        message.envelopeId,
        AndroidDeliveryStatus.pending,
        detail,
      );
      return {
        'ack': {
          'status': 'pending',
          'envelope_id': message.envelopeId,
          'detail': detail,
        },
        'message': _messageToAdbJson(
          message.copyWith(
            deliveryStatus: AndroidDeliveryStatus.pending,
            deliveryDetail: detail,
          ),
        ),
      };
    }
  }

  Future<Map<String, Object?>> _deliverAndroidServerMessage(
    AndroidMessageRecord message,
    AndroidContactRecord contact,
    String p2pFailureDetail, {
    String? serverUrl,
  }) async {
    final client = _createEnvelopeServerClient(serverUrl);
    try {
      String routeDetail = '';
      var activeContact = contact;
      final deviceId = contact.deviceId?.trim() ?? '';
      if (deviceId.isNotEmpty) {
        final route = await client.lookupRoute(
          ownerKeyId: contact.keyId,
          deviceId: deviceId,
        );
        final endpoint = route.endpoint;
        if (endpoint != null && endpoint.p2pTicket.trim().isNotEmpty) {
          final db = await _ensureAndroidDbStore();
          activeContact = contact.copyWith(
            deviceId: endpoint.deviceId,
            p2pTicket: endpoint.p2pTicket,
            p2pTicketUpdatedAtUnixMs: endpoint.createdAtUnixMs,
          );
          await db.upsertContact(activeContact);
          await _refreshAndroidChatStore();
          if (!endpoint.isExpired) {
            try {
              final ack = await _sendAndroidP2pEnvelopeWithCooldown(
                recipientKeyId: activeContact.keyId,
                envelopeId: message.envelopeId,
                ticket: endpoint.p2pTicket,
                envelopeBytes: _decodeOpaqueEnvelopeBase64(
                  message.opaqueEnvelopeBase64,
                ),
              );
              final detail = '服务器已刷新直连信息; ${ack.detail}';
              await _markAndroidMessageDelivery(
                message.envelopeId,
                AndroidDeliveryStatus.sent,
                detail,
              );
              return {
                'ack': {
                  ...ack.toJson(),
                  'detail': detail,
                  'route': 'server_route_p2p',
                },
                'message': _messageToAdbJson(
                  message.copyWith(
                    deliveryStatus: AndroidDeliveryStatus.sent,
                    deliveryDetail: detail,
                  ),
                ),
              };
            } catch (error) {
              routeDetail = '服务器直连重试失败: $error';
            }
          } else {
            routeDetail = '服务器直连信息已失效';
          }
        } else {
          routeDetail = '服务器暂无直连信息';
        }
      } else {
        routeDetail = '联系人暂无设备路由';
      }

      final submit = await _submitAndroidEnvelopeToServer(
        client: client,
        envelopeId: message.envelopeId,
        recipientKeyId: activeContact.keyId,
        envelopeBase64: message.opaqueEnvelopeBase64,
      );
      final detail = [
        '已写入 Envelope Server 离线邮箱',
        'until ${DateTime.fromMillisecondsSinceEpoch(submit.storedUntilUnixMs).toLocal()}',
        '直连: $p2pFailureDetail',
        routeDetail,
      ].where((item) => item.trim().isNotEmpty).join(' / ');
      await _markAndroidMessageDelivery(
        message.envelopeId,
        AndroidDeliveryStatus.serverMailbox,
        detail,
      );
      return {
        'ack': {
          'status': AndroidDeliveryStatus.serverMailbox,
          'envelope_id': message.envelopeId,
          'detail': detail,
          'route': 'server_mailbox',
        },
        'message': _messageToAdbJson(
          message.copyWith(
            deliveryStatus: AndroidDeliveryStatus.serverMailbox,
            deliveryDetail: detail,
          ),
        ),
      };
    } finally {
      client.close();
    }
  }

  Future<void> _markAndroidMessageDelivery(
    String envelopeId,
    String status,
    String? detail,
  ) async {
    final db = await _ensureAndroidDbStore();
    await db.updateMessageDelivery(
      envelopeId: envelopeId,
      deliveryStatus: status,
      deliveryDetail: detail,
    );
    await _refreshAndroidChatStore();
  }

  Future<void> _sendAndroidP2pFromUi() => _run('发送消息', () async {
    final originalText = _androidMessageController.text;
    final text = originalText.trim();
    if (mounted) {
      setState(() => _androidMessageController.clear());
    }
    Map<String, Object?> result;
    try {
      result = await _sendAndroidP2pText(text: text);
    } catch (_) {
      if (mounted && _androidMessageController.text.isEmpty) {
        setState(() => _androidMessageController.text = originalText);
      }
      rethrow;
    }
    final ack = (result['ack'] as Map).cast<String, Object?>();
    final status = ack['status'];
    if (!mounted) return;
    setState(() {
      _details = status == 'ok'
          ? '消息已送达。'
          : status == AndroidDeliveryStatus.serverMailbox
          ? '消息已存入离线邮箱，等待对方接收。'
          : '消息暂未发送，将自动重试。';
    });
  });

  Future<void> _sendAndroidMessageFromUi() {
    final group = _selectedAndroidGroup;
    if (group == null) {
      return _sendAndroidP2pFromUi();
    }
    return _run('发送群消息', () async {
      final originalText = _androidMessageController.text;
      final text = originalText.trim();
      if (mounted) {
        setState(() => _androidMessageController.clear());
      }
      try {
        await _sendAndroidGroupText(group: group, text: text);
      } catch (_) {
        if (mounted && _androidMessageController.text.isEmpty) {
          setState(() => _androidMessageController.text = originalText);
        }
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _details = '群消息已按成员逐一加密投递。';
      });
    });
  }

  Future<void> _sendAndroidFileFromUi() => _run('发送文件', () async {
    final pickedFile = await _secureStore.pickFileForSealing();
    if (pickedFile == null) {
      if (!mounted) return;
      setState(() => _details = '已取消选择文件。');
      return;
    }
    final group = _selectedAndroidGroup;
    if (group != null) {
      final message = await _sendAndroidGroupFile(
        group: group,
        file: pickedFile,
      );
      if (!mounted) return;
      setState(() {
        _details = message.deliveryStatus == AndroidDeliveryStatus.serverMailbox
            ? '群文件已按成员逐一加密，部分已存入离线邮箱。'
            : message.deliveryStatus == AndroidDeliveryStatus.pending
            ? '群文件部分成员暂未发送，将保留发送状态。'
            : '群文件已按成员逐一加密投递。';
      });
      return;
    }
    final result = await _sendAndroidP2pFile(file: pickedFile);
    final ack = (result['ack'] as Map).cast<String, Object?>();
    final status = ack['status'];
    if (!mounted) return;
    setState(() {
      _details = status == 'ok'
          ? '文件已送达。'
          : status == AndroidDeliveryStatus.serverMailbox
          ? '文件已存入离线邮箱，等待对方接收。'
          : '文件暂未发送，将自动重试。';
    });
  });

  Future<Map<String, Object?>> _retryAndroidPendingMessages({
    String? serverUrl,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    await _ensureAndroidP2pListening();
    final db = await _ensureAndroidDbStore();
    final results = <Map<String, Object?>>[];
    final pendingChildren = await db.getPendingEnvelopes();
    final stagedLogicalIds = await db.getStagedOutboundLogicalMessageIds();
    final childrenByLogicalAndRecipient =
        <String, Map<String, List<AndroidPendingEnvelopeRecord>>>{};
    for (final child in pendingChildren) {
      childrenByLogicalAndRecipient
          .putIfAbsent(child.logicalMessageId, () => {})
          .putIfAbsent(child.recipientKeyId, () => [])
          .add(child);
    }
    for (final logicalEntry in childrenByLogicalAndRecipient.entries) {
      for (final recipientChildren in logicalEntry.value.values) {
        recipientChildren.sort(
          (left, right) => left.childIndex.compareTo(right.childIndex),
        );
        final first = recipientChildren.first;
        final result = await _deliverAndroidPendingEnvelopeBatch(
          first.toContactRecord(),
          first.recipientDisplayName,
          recipientChildren,
          serverUrl: serverUrl,
        );
        results.add({
          'ack': {
            'status': result.failed ? 'pending' : 'ok',
            'envelope_id': first.envelopeId,
            'logical_message_id': logicalEntry.key,
            'detail': result.detail,
          },
        });
      }
      await _refreshAndroidLogicalDelivery(logicalEntry.key);
    }
    for (final logicalMessageId in stagedLogicalIds.difference(
      childrenByLogicalAndRecipient.keys.toSet(),
    )) {
      await _refreshAndroidLogicalDelivery(logicalMessageId);
    }

    final pending = await db.getPendingMessages();
    for (final message in pending) {
      if (stagedLogicalIds.contains(message.envelopeId)) continue;
      final fileTransfer = await db.getFileTransferByMessageEnvelopeId(
        message.envelopeId,
      );
      if (message.opaqueEnvelopeBase64.trim().isEmpty && fileTransfer == null) {
        const detail = '旧版群发记录缺少可重试的子信封；保留待处理状态。';
        await db.updateMessageDelivery(
          envelopeId: message.envelopeId,
          deliveryStatus: AndroidDeliveryStatus.pending,
          deliveryDetail: detail,
        );
        results.add({
          'ack': {
            'status': 'pending',
            'envelope_id': message.envelopeId,
            'detail': detail,
          },
        });
        continue;
      }
      results.add(
        await _deliverAndroidP2pMessage(message, serverUrl: serverUrl),
      );
    }
    await _refreshAndroidChatStore();
    final remainingPendingMessages = await db.getPendingMessageCount();
    final remainingPendingGroupControls = await db
        .getPendingGroupControlCount();
    final sent = results.where((result) {
      final status = (result['ack'] as Map?)?['status'];
      return status == 'ok' || status == AndroidDeliveryStatus.serverMailbox;
    }).length;
    return {
      'attempted': results.length,
      'sent': sent,
      'remaining_pending':
          remainingPendingMessages + remainingPendingGroupControls,
      'remaining_pending_messages': remainingPendingMessages,
      'remaining_pending_group_controls': remainingPendingGroupControls,
      'results': results,
    };
  }

  Future<Map<String, Object?>> _pullAndroidServerMailbox({
    String? serverUrl,
    bool updateDetails = false,
    bool refreshIdentity = true,
  }) async {
    if (_androidMailboxPullInFlight) {
      return {
        'pulled': 0,
        'imported': 0,
        'duplicates': 0,
        'quarantined': 0,
        'deferred_remaining': 0,
        'acked': 0,
        'skipped': 'already_running',
        'items': const <Map<String, Object?>>[],
      };
    }
    _androidMailboxPullInFlight = true;
    try {
      if (refreshIdentity) {
        await _refreshSecureIdentity();
      }
      await _refreshAndroidChatStore();
      final identity = _requireAndroidIdentity();
      final db = await _ensureAndroidDbStore();
      final pruned = await db.pruneMailboxReliability();
      final client = _createEnvelopeServerClient(serverUrl);
      try {
        final pullRequest = _nativeCore.createMailboxPullRequest(
          identityJson: identity.identityJson,
          limit: 50,
        );
        final response = await _withAndroidServerRegistrationRetry(
          client: client,
          request: () => client.pullMailbox(
            recipientKeyId: identity.keyId,
            pullRequestJson: pullRequest.requestJson,
          ),
        );
        final items = <Map<String, Object?>>[];
        final ackEnvelopeIds = <String>{};
        var importedCount = 0;
        var duplicateCount = 0;
        var quarantinedCount = 0;
        for (final envelope in response.envelopes) {
          final existingQuarantine = await db.getMailboxQuarantine(
            envelope.envelopeId,
          );
          if (existingQuarantine != null) {
            ackEnvelopeIds.add(envelope.envelopeId);
            items.add({
              'envelope_id': envelope.envelopeId,
              'quarantined': true,
              'reason_code': existingQuarantine.reasonCode,
            });
            continue;
          }
          final existingDeferred = await db.getDeferredMailboxEnvelope(
            envelope.envelopeId,
          );
          if (existingDeferred != null) {
            // The authenticated raw body is already durable. A previous ACK
            // may have been lost, so ACK this server copy again and retry the
            // local causal queue after the complete mailbox page is imported.
            ackEnvelopeIds.add(envelope.envelopeId);
            items.add({
              'envelope_id': envelope.envelopeId,
              'deferred': true,
              'reason_code': existingDeferred.reasonCode,
            });
            continue;
          }
          final senderCandidates = _androidKnownContactCandidates()
              .where((candidate) => candidate.keyId == envelope.senderKeyId)
              .toList(growable: false);
          if (senderCandidates.isEmpty) {
            final quarantinedAt = DateTime.now().millisecondsSinceEpoch;
            await db.addMailboxQuarantine(
              envelopeId: envelope.envelopeId,
              senderKeyId: envelope.senderKeyId,
              reasonCode: 'unknown_sender',
              reasonDetail: 'mailbox sender_key_id 不在联系人或群成员目录中。',
              envelopeBase64: envelope.envelopeBase64,
              quarantinedAtUnixMs: quarantinedAt,
            );
            ackEnvelopeIds.add(envelope.envelopeId);
            quarantinedCount += 1;
            items.add({
              'envelope_id': envelope.envelopeId,
              'quarantined': true,
              'reason_code': 'unknown_sender',
            });
            continue;
          }
          try {
            final importResult = await _importAndroidOpaqueEnvelopeBase64(
              envelope.envelopeBase64,
              targetSenderContact: senderCandidates.first,
              updateDetails: false,
            );
            if (importResult.duplicate) {
              duplicateCount += 1;
            } else {
              importedCount += 1;
            }
            items.add({
              'envelope_id': envelope.envelopeId,
              'duplicate': importResult.duplicate,
              'text': importResult.message.text,
              'sender_key_id': importResult.message.peerKeyId,
            });
            ackEnvelopeIds.add(envelope.envelopeId);
          } catch (error) {
            final classification = classifyAndroidMailboxImportFailure(error);
            var deferred = false;
            var quarantined = false;
            if (!classification.permanent &&
                classification.reasonCode == 'missing_prerequisite') {
              deferred = await db.stageDeferredMailboxEnvelope(
                recipientIdentityKeyId: identity.keyId,
                envelopeId: envelope.envelopeId,
                senderKeyId: envelope.senderKeyId,
                envelopeBase64: envelope.envelopeBase64,
                reasonCode: classification.reasonCode,
                reasonDetail: classification.detail,
                nowUnixMs: DateTime.now().millisecondsSinceEpoch,
              );
              ackEnvelopeIds.add(envelope.envelopeId);
              if (!deferred) {
                quarantined = true;
                quarantinedCount += 1;
              }
            } else if (classification.permanent) {
              await db.addMailboxQuarantine(
                recipientIdentityKeyId: identity.keyId,
                envelopeId: envelope.envelopeId,
                senderKeyId: envelope.senderKeyId,
                reasonCode: classification.reasonCode,
                reasonDetail: classification.detail,
                envelopeBase64: envelope.envelopeBase64,
                quarantinedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
              );
              ackEnvelopeIds.add(envelope.envelopeId);
              quarantined = true;
              quarantinedCount += 1;
            }
            items.add({
              'envelope_id': envelope.envelopeId,
              'error': classification.detail,
              'reason_code': classification.reasonCode,
              if (deferred) 'deferred': true,
              if (quarantined) 'quarantined': true,
            });
            _logDiagnostic(
              'warn',
              quarantined
                  ? 'mailbox_item_quarantined'
                  : 'mailbox_item_deferred',
              {
                'envelope_id': envelope.envelopeId,
                'sender_key_id': envelope.senderKeyId,
                'reason_code': classification.reasonCode,
                'error': classification.detail,
              },
            );
          }
        }

        // A predecessor can appear later in the same oldest-50 page. Retry
        // only after the page has settled so future-epoch group events can be
        // imported without consuming their replay counters prematurely.
        final deferredRetry = await _retryAndroidDeferredMailbox();
        importedCount += deferredRetry.imported;
        duplicateCount += deferredRetry.duplicates;
        quarantinedCount += deferredRetry.quarantined;
        items.addAll(deferredRetry.items);

        var deletedCount = 0;
        if (ackEnvelopeIds.isNotEmpty) {
          final ackRequest = _nativeCore.createMailboxAckRequest(
            identityJson: identity.identityJson,
            envelopeIds: ackEnvelopeIds.toList(growable: false),
          );
          final ack = await client.ackMailbox(
            recipientKeyId: identity.keyId,
            ackRequestJson: ackRequest.requestJson,
          );
          deletedCount = ack.deletedCount;
          await db.markMailboxQuarantineAcknowledged(
            envelopeIds: ackEnvelopeIds,
            acknowledgedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        await _refreshAndroidChatStore();
        final deferredRemaining =
            (await db.getDeferredMailboxEnvelopes()).length;
        final result = {
          'pulled': response.envelopes.length,
          'imported': importedCount,
          'duplicates': duplicateCount,
          'quarantined': quarantinedCount,
          'acked': deletedCount,
          'deferred_remaining': deferredRemaining,
          'pruned': pruned.removedQuarantineCount + pruned.removedDeferredCount,
          'items': items,
        };
        if (mounted && updateDetails) {
          setState(() {
            _details = [
              '新消息拉取完成。',
              'pulled: ${result['pulled']}',
              'imported: ${result['imported']}',
              'duplicates: ${result['duplicates']}',
              'quarantined: ${result['quarantined']}',
              'deferred: ${result['deferred_remaining']}',
              'acked: ${result['acked']}',
            ].join('\n');
          });
        }
        return result;
      } finally {
        client.close();
      }
    } finally {
      _androidMailboxPullInFlight = false;
    }
  }

  Future<_AndroidDeferredMailboxRetryResult>
  _retryAndroidDeferredMailbox() async {
    final db = await _ensureAndroidDbStore();
    final records = await db.getDeferredMailboxEnvelopes();
    var imported = 0;
    var duplicates = 0;
    var quarantined = 0;
    final items = <Map<String, Object?>>[];
    for (final record in records) {
      final senderCandidates = _androidKnownContactCandidates()
          .where((candidate) => candidate.keyId == record.senderKeyId)
          .toList(growable: false);
      try {
        if (senderCandidates.isEmpty) {
          throw const AndroidEnvelopeCiphertextRejectedException(
            '已知发送方的信封认证或解密失败。',
          );
        }
        final result = await _importAndroidOpaqueEnvelopeBase64(
          record.envelopeBase64,
          targetSenderContact: senderCandidates.first,
          updateDetails: false,
        );
        await db.deleteDeferredMailboxEnvelope(record.envelopeId);
        if (result.duplicate) {
          duplicates += 1;
        } else {
          imported += 1;
        }
        items.add({
          'envelope_id': record.envelopeId,
          'deferred_retry': 'imported',
          'duplicate': result.duplicate,
        });
      } catch (error) {
        final classification = classifyAndroidMailboxImportFailure(error);
        final attemptedAt = DateTime.now().millisecondsSinceEpoch;
        if (classification.permanent) {
          await db.moveDeferredMailboxEnvelopeToQuarantine(
            recipientIdentityKeyId: _requireAndroidIdentity().keyId,
            record: record,
            reasonCode: classification.reasonCode,
            reasonDetail: classification.detail,
            quarantinedAtUnixMs: attemptedAt,
          );
          quarantined += 1;
        } else {
          await db.updateDeferredMailboxFailure(
            record: record,
            reasonCode: classification.reasonCode,
            reasonDetail: classification.detail,
            attemptedAtUnixMs: attemptedAt,
          );
        }
        items.add({
          'envelope_id': record.envelopeId,
          'deferred_retry': classification.permanent
              ? 'quarantined'
              : 'waiting',
          'reason_code': classification.reasonCode,
          'error': classification.detail,
        });
      }
    }
    return _AndroidDeferredMailboxRetryResult(
      imported: imported,
      duplicates: duplicates,
      quarantined: quarantined,
      items: items,
    );
  }

  Future<Map<String, Object?>> _syncAndroidDeliveryReceipts({
    String? serverUrl,
  }) async {
    if (_androidDeliveryReceiptSyncInFlight) {
      return {'checked': 0, 'delivered': 0, 'skipped': 'already_running'};
    }
    _androidDeliveryReceiptSyncInFlight = true;
    try {
      await _refreshSecureIdentity(startP2p: false);
      final identity = _requireAndroidIdentity();
      final db = await _ensureAndroidDbStore();
      final waiting = await db.getServerMailboxMessages(limit: 100);
      if (waiting.isEmpty) {
        return {'checked': 0, 'delivered': 0};
      }

      final request = _nativeCore.createDeliveryStatusRequest(
        identityJson: identity.identityJson,
        envelopeIds: waiting.map((message) => message.envelopeId).toList(),
      );
      final client = _createEnvelopeServerClient(serverUrl);
      try {
        final response = await _withAndroidServerRegistrationRetry(
          client: client,
          request: () => client.deliveryStatus(
            senderKeyId: identity.keyId,
            statusRequestJson: request.requestJson,
          ),
        );
        var delivered = 0;
        for (final item in response.items.where((item) => item.isDelivered)) {
          final deliveredAt = item.deliveredAtUnixMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  item.deliveredAtUnixMs!,
                ).toLocal();
          await db.updateMessageDelivery(
            envelopeId: item.envelopeId,
            deliveryStatus: AndroidDeliveryStatus.sent,
            deliveryDetail: deliveredAt == null
                ? '服务器回执：对方已接收'
                : '服务器回执：对方已于 $deliveredAt 接收',
          );
          final transfer = await db.getFileTransferByMessageEnvelopeId(
            item.envelopeId,
          );
          if (transfer != null) {
            await db.updateFileTransferStatus(
              transferId: transfer['transfer_id']?.toString() ?? '',
              status: AndroidDeliveryStatus.sent,
            );
          }
          delivered += 1;
        }
        if (delivered > 0) {
          await _refreshAndroidChatStore();
        }
        return {
          'checked': waiting.length,
          'delivered': delivered,
          'items': response.items
              .map(
                (item) => {
                  'envelope_id': item.envelopeId,
                  'status': item.status,
                  if (item.deliveredAtUnixMs != null)
                    'delivered_at_unix_ms': item.deliveredAtUnixMs,
                },
              )
              .toList(),
        };
      } finally {
        client.close();
      }
    } finally {
      _androidDeliveryReceiptSyncInFlight = false;
    }
  }

  Future<Map<String, Object?>?> _syncAndroidDeliveryReceiptsSilently() async {
    try {
      return await _syncAndroidDeliveryReceipts();
    } catch (error) {
      _logDiagnostic('warn', 'delivery_receipt_sync_failure', {
        'error': error.toString(),
      });
      debugPrint('Envelope delivery receipt sync failed: $error');
      return null;
    }
  }

  Uint8List _decodeOpaqueEnvelopeBase64(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const AndroidInvalidEnvelopePayloadException('离线信封 base64 为空。');
    }
    return base64Url.decode(base64Url.normalize(trimmed));
  }

  String _encodeOpaqueEnvelopeBase64(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  String _sha256Base64Url(List<int> bytes) =>
      base64UrlEncode(crypto.sha256.convert(bytes).bytes).replaceAll('=', '');

  String _digestBase64Url(crypto.Digest digest) =>
      base64UrlEncode(digest.bytes).replaceAll('=', '');

  String _randomAndroidTransferId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _randomOpaqueEnvelopeFileName() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _canExportAndroidMessageEnvelope(AndroidMessageRecord message) =>
      message.opaqueEnvelopeBase64.trim().isNotEmpty;

  Future<AndroidSavedFile> _writeAndroidOfflineEnvelopeFile(
    List<int> envelopeBytes,
  ) async {
    final bytes = envelopeBytes is Uint8List
        ? envelopeBytes
        : Uint8List.fromList(envelopeBytes);
    return _secureStore.saveSealedEnvelopeFile(
      name: '${_randomOpaqueEnvelopeFileName()}.envelope',
      bytes: bytes,
    );
  }

  Future<AndroidSavedFile> _createAndroidOfflineEnvelopeFile() {
    return _secureStore.createSavedFile(
      name: '${_randomOpaqueEnvelopeFileName()}.envelope',
      mime: _androidEnvelopeFileMime,
      childDir: 'sealed',
    );
  }

  Future<int> _appendAndroidSavedFileAscii(
    AndroidSavedFile file,
    String text,
  ) async {
    final bytes = Uint8List.fromList(ascii.encode(text));
    await _secureStore.appendSavedFileBytes(uri: file.uri, bytes: bytes);
    return bytes.length;
  }

  Future<int> _appendAndroidSavedFileBytes(
    AndroidSavedFile file,
    Uint8List bytes,
  ) async {
    await _secureStore.appendSavedFileBytes(uri: file.uri, bytes: bytes);
    return bytes.length;
  }

  Future<AndroidSavedFile> _writeAndroidReceivedPayloadFile(
    NativeInboundOpaquePayload payload,
  ) async {
    final fileName = _androidReceivedPayloadFileName(payload);
    return _secureStore.saveReceivedFile(
      name: fileName,
      mime: payload.mime,
      bytes: payload.payloadBytes,
    );
  }

  String _androidSavedFileDisplayPath(AndroidSavedFile file) {
    final displayPath = file.displayPath.trim();
    if (displayPath.isNotEmpty) return displayPath;
    return file.uri;
  }

  String _androidReceivedPayloadFileName(NativeInboundOpaquePayload payload) {
    final fallbackName = 'file${_androidFileExtensionForMime(payload.mime)}';
    var name = (payload.filename?.trim().isNotEmpty ?? false)
        ? payload.filename!.trim()
        : fallbackName;
    name = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\u0000-\u001F]'), '_')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = fallbackName;
    }
    if (p.extension(name).isEmpty) {
      name = '$name${_androidFileExtensionForMime(payload.mime)}';
    }
    if (name.length > 140) {
      final extension = p.extension(name);
      final base = p.basenameWithoutExtension(name);
      final clippedBase = base.substring(0, min(base.length, 120));
      name = '$clippedBase$extension';
    }
    final prefix = payload.envelopeId.length >= 8
        ? payload.envelopeId.substring(0, 8)
        : payload.envelopeId;
    return '$prefix-$name';
  }

  String _androidFileExtensionForMime(String mime) {
    return switch (mime.toLowerCase().split(';').first.trim()) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'video/mp4' => '.mp4',
      'video/quicktime' => '.mov',
      'application/pdf' => '.pdf',
      'text/plain' => '.txt',
      _ => '',
    };
  }

  Future<_AndroidInboundPayloadMessageContent>
  _androidMessageContentForInboundPayload(
    NativeInboundOpaquePayload payload,
  ) async {
    if (payload.isText) {
      return _AndroidInboundPayloadMessageContent(text: payload.text);
    }
    final file = await _writeAndroidReceivedPayloadFile(payload);
    final displayName = payload.filename?.trim().isNotEmpty == true
        ? payload.filename!.trim()
        : file.name;
    final savedPath = file.displayPath.trim().isNotEmpty
        ? file.displayPath.trim()
        : file.uri;
    final text = [
      '文件：$displayName (${_formatByteCount(payload.payloadLength)})',
      savedPath,
    ].join('\n');
    return _AndroidInboundPayloadMessageContent(
      text: text,
      attachmentUri: file.uri,
      attachmentPath: savedPath,
      attachmentMime: file.mime,
    );
  }

  String _formatByteCount(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
    final mib = kib / 1024;
    if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
    final gib = mib / 1024;
    return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GB';
  }

  String _androidFileMessageText(String filename, int totalSize) =>
      '文件：$filename (${_formatByteCount(totalSize)})';

  String _androidReceivingFileProgressText({
    String? filename,
    int? totalSize,
    required int received,
    required int total,
  }) {
    final safeTotal = max(total, 1);
    final percent = ((received.clamp(0, safeTotal) / safeTotal) * 100)
        .round()
        .clamp(0, 99);
    final name = filename?.trim();
    if (name != null && name.isNotEmpty) {
      final size = totalSize == null ? '' : ' (${_formatByteCount(totalSize)})';
      return ['文件：$name$size', '接收中 $percent%'].join('\n');
    }
    return '文件接收中 $percent%';
  }

  String _formatOptionalByteCount(int? bytes) {
    if (bytes == null) return '未知大小';
    return _formatByteCount(bytes);
  }

  Future<void> _pasteAndroidEnvelope() => _run('粘贴离线信封', () async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      throw const SecureStoreException('剪贴板里没有离线信封 base64。');
    }
    if (!mounted) return;
    setState(() => _androidEnvelopeBase64Controller.text = text);
  });

  Future<void> _importAndroidEnvelope() => _run('导入离线信封', () async {
    await _importAndroidOpaqueEnvelopeBase64(
      _androidEnvelopeBase64Controller.text.trim(),
    );
  });

  Future<AndroidMessageRecord> _selectOfflineEnvelopeMessage({
    String? envelopeId,
  }) async {
    final db = await _ensureAndroidDbStore();
    if (envelopeId != null && envelopeId.trim().isNotEmpty) {
      final message = await db.getMessage(envelopeId.trim());
      if (message != null) {
        if (!_canExportAndroidMessageEnvelope(message)) {
          throw SecureStoreException('该消息没有离线信封数据：${envelopeId.trim()}');
        }
        return message;
      }
      throw SecureStoreException('未找到离线信封：${envelopeId.trim()}');
    }
    final pending = await db.getPendingMessages();
    if (pending.isNotEmpty) {
      final message = pending.last;
      if (message.opaqueEnvelopeBase64.isNotEmpty) return message;
    }
    final latestOutgoing = await db.getLatestOutgoingMessage();
    if (latestOutgoing != null &&
        latestOutgoing.opaqueEnvelopeBase64.isNotEmpty) {
      return latestOutgoing;
    }
    for (final message in _androidChatStore.messages.reversed) {
      if (_canExportAndroidMessageEnvelope(message)) {
        return message;
      }
    }
    throw const SecureStoreException('没有可导出的离线信封。');
  }

  Future<List<Map<String, Object?>>> _exportAndroidOfflineEnvelopeMessages(
    List<AndroidMessageRecord> messages,
  ) async {
    final exportable = messages
        .where(_canExportAndroidMessageEnvelope)
        .toList(growable: false);
    if (exportable.isEmpty) {
      throw const SecureStoreException('请先选择至少一条带离线信封数据的消息。');
    }

    final results = <Map<String, Object?>>[];
    for (final message in exportable) {
      final envelopeBytes = _decodeOpaqueEnvelopeBase64(
        message.opaqueEnvelopeBase64,
      );
      final file = await _writeAndroidOfflineEnvelopeFile(envelopeBytes);
      results.add({
        'envelope_id': message.envelopeId,
        'delivery_status': message.deliveryStatus,
        'envelope_base64': message.opaqueEnvelopeBase64,
        'bytes': envelopeBytes.length,
        'path': file.displayPath.trim().isNotEmpty
            ? file.displayPath.trim()
            : file.uri,
        'uri': file.uri,
      });
    }
    await Clipboard.setData(
      ClipboardData(
        text: exportable
            .map((message) => message.opaqueEnvelopeBase64.trim())
            .join('\n'),
      ),
    );
    return results;
  }

  Future<Map<String, Object?>> _exportAndroidOfflineEnvelope({
    String? envelopeId,
  }) async {
    await _refreshAndroidChatStore();
    final message = await _selectOfflineEnvelopeMessage(envelopeId: envelopeId);
    final results = await _exportAndroidOfflineEnvelopeMessages([message]);
    return results.single;
  }

  Future<_AndroidSealResult> _createAndroidTextSealResult(
    AndroidContactRecord contact,
    String text,
  ) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw const SecureStoreException('请先输入要密封的文本。');
    }
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final messageCounter = await db.getNextMessageCounter();
    final outbound = _nativeCore.encryptOpaqueText(
      identityJson: identity.identityJson,
      recipientContactJson: contact.contactJson,
      text: normalizedText,
      messageCounter: messageCounter,
    );
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(outbound.messageCounter),
    );
    final envelopeBytes = outbound.envelopeBytes;
    final file = await _writeAndroidOfflineEnvelopeFile(envelopeBytes);
    final savedPath = _androidSavedFileDisplayPath(file);
    final record = AndroidSealedEnvelopeRecord(
      envelopeId: outbound.envelopeId,
      kind: 'text',
      recipientKeyId: contact.keyId,
      recipientDisplayName: _contactTitle(contact),
      createdAtUnixMs: outbound.createdAtUnixMs,
      messageCounter: outbound.messageCounter,
      sourceName: null,
      payloadSize: utf8.encode(normalizedText).length,
      envelopeSize: envelopeBytes.length,
      path: savedPath,
      uri: file.uri,
      displayPath: file.displayPath,
      mime: file.mime,
      sizeBytes: file.bytes,
    );
    await db.addSealedEnvelope(record);
    return _AndroidSealResult(
      label: '密封文本',
      path: savedPath,
      record: record,
      details: [
        '文本已密封为信封文件。',
        'recipient: ${_contactTitle(contact)} / ${contact.keyId}',
        '信封: ${outbound.envelopeId}',
        'bytes: ${envelopeBytes.length}',
        savedPath,
      ].join('\n'),
    );
  }

  Future<_AndroidSealResult?> _createAndroidFileSealResult(
    AndroidContactRecord contact,
  ) async {
    final pickedFile = await _secureStore.pickFileForSealing();
    if (pickedFile == null) {
      return null;
    }
    return _createAndroidFileSealResultForPickedFile(contact, pickedFile);
  }

  Future<_AndroidSealResult> _createAndroidFileSealResultForPickedFile(
    AndroidContactRecord contact,
    AndroidPickedFile pickedFile,
  ) async {
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final messageCounter = await db.getNextMessageCounter();
    final fileName = pickedFile.name.trim().isEmpty
        ? 'file'
        : pickedFile.name.trim();
    final mime = pickedFile.mime.trim().isEmpty
        ? 'application/octet-stream'
        : pickedFile.mime.trim();
    final scan = await _scanAndroidPickedFile(
      pickedFile,
      maxBytes: null,
      chunkSizeBytes: _androidOfflineFileChunkBytes,
    );
    final transferId = _randomAndroidTransferId();
    final chunkCount = scan.chunkHashes.length;
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(messageCounter, chunkCount + 1),
    );
    final manifestPayload = <String, Object?>{
      'version': 1,
      'kind': 'offline_file_manifest',
      'transfer_id': transferId,
      'filename': fileName,
      'mime': mime,
      'total_size': scan.totalSize,
      'chunk_size': _androidOfflineFileChunkBytes,
      'chunk_count': chunkCount,
      'file_sha256': scan.fileSha256,
      'chunk_sha256': scan.chunkHashes,
    };
    final outbound = _nativeCore.encryptOpaqueFile(
      identityJson: identity.identityJson,
      recipientContactJson: contact.contactJson,
      filename: '$fileName.manifest.json',
      mime: _androidOfflineFileManifestMime,
      payloadBytes: Uint8List.fromList(
        utf8.encode(jsonEncode(manifestPayload)),
      ),
      messageCounter: messageCounter,
    );
    final file = await _createAndroidOfflineEnvelopeFile();
    var writtenBytes = 0;
    var completed = false;
    try {
      writtenBytes += await _appendAndroidSavedFileAscii(
        file,
        '$_androidOfflineStreamMagic\n',
      );
      writtenBytes += await _appendAndroidSavedFileAscii(
        file,
        '${outbound.envelopeBase64}\n',
      );
      for (var index = 0; index < chunkCount; index += 1) {
        final chunkBytes = await _readAndroidPickedFileChunkForSend(
          file: pickedFile,
          chunkIndex: index,
          totalSize: scan.totalSize,
          chunkSizeBytes: _androidOfflineFileChunkBytes,
        );
        final chunkSha256 = _sha256Base64Url(chunkBytes);
        if (chunkSha256 != scan.chunkHashes[index]) {
          throw SecureStoreException('离线文件分片哈希校验失败：$index。');
        }
        final outboundChunk = _nativeCore.encryptOpaqueFile(
          identityJson: identity.identityJson,
          recipientContactJson: contact.contactJson,
          filename: '$transferId.part${index.toString().padLeft(6, '0')}',
          mime: _androidOfflineFileChunkMime,
          payloadBytes: chunkBytes,
          messageCounter: androidAdvanceMessageCounter(
            messageCounter,
            index + 1,
          ),
        );
        writtenBytes += await _appendAndroidSavedFileAscii(
          file,
          '${outboundChunk.envelopeBase64}\n',
        );
      }
      final sealedFile = await _secureStore.finishSavedFile(
        file: file,
        bytes: writtenBytes,
      );
      final savedPath = _androidSavedFileDisplayPath(sealedFile);
      final record = AndroidSealedEnvelopeRecord(
        envelopeId: outbound.envelopeId,
        kind: 'file',
        recipientKeyId: contact.keyId,
        recipientDisplayName: _contactTitle(contact),
        createdAtUnixMs: outbound.createdAtUnixMs,
        messageCounter: outbound.messageCounter,
        sourceName: fileName,
        payloadSize: scan.totalSize,
        envelopeSize: writtenBytes,
        path: savedPath,
        uri: sealedFile.uri,
        displayPath: sealedFile.displayPath,
        mime: sealedFile.mime,
        sizeBytes: sealedFile.bytes,
      );
      await db.addSealedEnvelope(record);
      completed = true;
      return _AndroidSealResult(
        label: '密封文件',
        path: savedPath,
        record: record,
        details: [
          '文件已密封为流式信封文件。',
          'recipient: ${_contactTitle(contact)} / ${contact.keyId}',
          'file: $fileName',
          'payload: ${_formatByteCount(scan.totalSize)}',
          'chunks: $chunkCount',
          '信封: ${outbound.envelopeId}',
          'bytes: $writtenBytes',
          savedPath,
        ].join('\n'),
      );
    } finally {
      if (!completed) {
        await _secureStore.deleteSavedFile(
          uri: file.uri,
          path: file.displayPath,
        );
      }
    }
  }

  void _ensureAndroidOfflineEnvelopeLineWithinLimit(String envelopeBase64) {
    if (envelopeBase64.length > _androidMaximumOfflineEnvelopeLineCharacters) {
      throw SecureStoreException(
        '离线信封单行超过 '
        '$_androidMaximumOfflineEnvelopeLineCharacters 字符资源上限。',
      );
    }
  }

  Future<_AndroidSealResult> _createAndroidGroupTextSealResult(
    AndroidGroupRecord group,
    String text,
  ) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw const SecureStoreException('请先输入要密封的群组文本。');
    }
    if (!group.isActive) {
      throw const SecureStoreException('群组已解散，不能继续离线密封。');
    }

    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final recipients = _androidGroupMessageRecipients(
      group: group,
      members: members,
      selfKeyId: identity.keyId,
    );
    if (recipients.isEmpty) {
      throw const SecureStoreException('该群没有可离线密封的活跃成员。');
    }
    if (recipients.length > _androidMaximumOfflineGroupRecipients) {
      throw SecureStoreException(
        '群组离线密封收件人超过 '
        '$_androidMaximumOfflineGroupRecipients 人资源上限。',
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = _groupControlPayload(
      type: 'group_message',
      group: group,
      members: members,
      now: now,
      extra: {'text': normalizedText},
    );
    final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final firstCounter = await db.getNextMessageCounter();
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(firstCounter, recipients.length),
    );
    var counter = firstCounter;
    String? firstEnvelopeId;
    final file = await _createAndroidOfflineEnvelopeFile();
    var writtenBytes = 0;
    var completed = false;
    try {
      writtenBytes += await _appendAndroidSavedFileAscii(
        file,
        '$_androidOfflineGroupStreamMagic\n',
      );
      for (final member in recipients) {
        final outbound = _nativeCore.encryptOpaqueFile(
          identityJson: identity.identityJson,
          recipientContactJson: member.contactJson,
          filename: 'group-control.json',
          mime: _androidGroupControlMime,
          payloadBytes: payloadBytes,
          messageCounter: counter,
        );
        _ensureAndroidOfflineEnvelopeLineWithinLimit(outbound.envelopeBase64);
        firstEnvelopeId ??= outbound.envelopeId;
        writtenBytes += await _appendAndroidSavedFileAscii(
          file,
          '${outbound.envelopeBase64}\n',
        );
        counter = androidAdvanceMessageCounter(outbound.messageCounter);
      }

      final sealedFile = await _secureStore.finishSavedFile(
        file: file,
        bytes: writtenBytes,
      );
      final savedPath = _androidSavedFileDisplayPath(sealedFile);
      final record = AndroidSealedEnvelopeRecord(
        envelopeId:
            firstEnvelopeId ??
            (throw const SecureStoreException('群组离线密封未生成任何收件人信封。')),
        kind: 'group_text',
        recipientKeyId: group.groupId,
        recipientDisplayName: group.displayName,
        createdAtUnixMs: now,
        messageCounter: firstCounter,
        sourceName: null,
        payloadSize: payloadBytes.length,
        envelopeSize: writtenBytes,
        path: savedPath,
        uri: sealedFile.uri,
        displayPath: sealedFile.displayPath,
        mime: sealedFile.mime,
        sizeBytes: sealedFile.bytes,
      );
      await db.addSealedEnvelope(record);
      completed = true;
      return _AndroidSealResult(
        label: '密封群组文本',
        path: savedPath,
        record: record,
        details: [
          '群组文本已密封为逐成员信封流。',
          'group: ${group.displayName} / ${group.groupId}',
          'recipients: ${recipients.length}',
          '信封: ${record.envelopeId}',
          'bytes: $writtenBytes',
          savedPath,
        ].join('\n'),
      );
    } finally {
      if (!completed) {
        await _secureStore.deleteSavedFile(
          uri: file.uri,
          path: file.displayPath,
        );
      }
    }
  }

  Future<_AndroidSealResult?> _createAndroidGroupFileSealResult(
    AndroidGroupRecord group,
  ) async {
    final pickedFile = await _secureStore.pickFileForSealing();
    if (pickedFile == null) return null;
    return _createAndroidGroupFileSealResultForPickedFile(group, pickedFile);
  }

  Future<_AndroidSealResult> _createAndroidGroupFileSealResultForPickedFile(
    AndroidGroupRecord group,
    AndroidPickedFile pickedFile,
  ) async {
    if (!group.isActive) {
      throw const SecureStoreException('群组已解散，不能继续离线密封。');
    }
    final identity = _requireAndroidIdentity();
    final db = await _ensureAndroidDbStore();
    final members = await db.getGroupMembers(groupId: group.groupId);
    final recipients = _androidGroupMessageRecipients(
      group: group,
      members: members,
      selfKeyId: identity.keyId,
    );
    if (recipients.isEmpty) {
      throw const SecureStoreException('该群没有可离线密封的活跃成员。');
    }
    if (recipients.length > _androidMaximumOfflineGroupRecipients) {
      throw SecureStoreException(
        '群组离线密封收件人超过 '
        '$_androidMaximumOfflineGroupRecipients 人资源上限。',
      );
    }

    final fileName = pickedFile.name.trim().isEmpty
        ? 'file'
        : pickedFile.name.trim();
    final mime = pickedFile.mime.trim().isEmpty
        ? 'application/octet-stream'
        : pickedFile.mime.trim();
    final scan = await _scanAndroidPickedFile(
      pickedFile,
      maxBytes: null,
      chunkSizeBytes: _androidOfflineFileChunkBytes,
    );
    final chunkCount = scan.chunkHashes.length;
    if (chunkCount > _androidMaximumOfflineGroupChunks) {
      throw SecureStoreException(
        '群组离线文件需要 $chunkCount 个分片，超过 '
        '$_androidMaximumOfflineGroupChunks 个资源上限。',
      );
    }
    final envelopesPerRecipient = chunkCount + 1;
    final envelopeCount = recipients.length * envelopesPerRecipient;
    if (envelopeCount > _androidMaximumOfflineGroupEnvelopeLines) {
      throw SecureStoreException(
        '群组离线文件需要 $envelopeCount 条密文，超过 '
        '$_androidMaximumOfflineGroupEnvelopeLines 条资源上限。',
      );
    }

    final transferId = _randomAndroidTransferId();
    final manifestPayload = <String, Object?>{
      'version': 1,
      'kind': 'offline_file_manifest',
      'transfer_id': transferId,
      'conversation_id': group.groupId,
      'group_id': group.groupId,
      'group_epoch': group.epoch,
      'filename': fileName,
      'mime': mime,
      'total_size': scan.totalSize,
      'chunk_size': _androidOfflineFileChunkBytes,
      'chunk_count': chunkCount,
      'file_sha256': scan.fileSha256,
      'chunk_sha256': scan.chunkHashes,
    };
    final manifestBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(manifestPayload)),
    );
    final firstCounter = await db.getNextMessageCounter();
    await db.setNextMessageCounter(
      androidAdvanceMessageCounter(firstCounter, envelopeCount),
    );
    String? firstEnvelopeId;
    final output = await _createAndroidOfflineEnvelopeFile();
    final digestSink = _AndroidDigestSink();
    final digestInput = crypto.sha256.startChunkedConversion(digestSink);
    var digestClosed = false;
    var writtenPayloadBytes = 0;
    var writtenBytes = 0;
    var completed = false;
    try {
      writtenBytes += await _appendAndroidSavedFileAscii(
        output,
        '$_androidOfflineGroupStreamMagic\n',
      );
      for (
        var recipientIndex = 0;
        recipientIndex < recipients.length;
        recipientIndex += 1
      ) {
        final member = recipients[recipientIndex];
        final manifestEnvelope = _nativeCore.encryptOpaqueFile(
          identityJson: identity.identityJson,
          recipientContactJson: member.contactJson,
          filename: '$fileName.manifest.json',
          mime: _androidOfflineFileManifestMime,
          payloadBytes: manifestBytes,
          messageCounter: androidAdvanceMessageCounter(
            firstCounter,
            recipientIndex * envelopesPerRecipient,
          ),
        );
        _ensureAndroidOfflineEnvelopeLineWithinLimit(
          manifestEnvelope.envelopeBase64,
        );
        firstEnvelopeId ??= manifestEnvelope.envelopeId;
        writtenBytes += await _appendAndroidSavedFileAscii(
          output,
          '${manifestEnvelope.envelopeBase64}\n',
        );
      }

      for (var chunkIndex = 0; chunkIndex < chunkCount; chunkIndex += 1) {
        final chunkBytes = await _readAndroidPickedFileChunkForSend(
          file: pickedFile,
          chunkIndex: chunkIndex,
          totalSize: scan.totalSize,
          chunkSizeBytes: _androidOfflineFileChunkBytes,
        );
        final actualHash = _sha256Base64Url(chunkBytes);
        if (actualHash != scan.chunkHashes[chunkIndex]) {
          throw SecureStoreException(
            '群组离线密封期间源文件发生变化：分片 $chunkIndex SHA-256 不一致。',
          );
        }
        digestInput.add(chunkBytes);
        writtenPayloadBytes += chunkBytes.length;
        for (
          var recipientIndex = 0;
          recipientIndex < recipients.length;
          recipientIndex += 1
        ) {
          final member = recipients[recipientIndex];
          final chunkEnvelope = _nativeCore.encryptOpaqueFile(
            identityJson: identity.identityJson,
            recipientContactJson: member.contactJson,
            filename:
                '$transferId.part${chunkIndex.toString().padLeft(6, '0')}',
            mime: _androidOfflineFileChunkMime,
            payloadBytes: chunkBytes,
            messageCounter: androidAdvanceMessageCounter(
              firstCounter,
              recipientIndex * envelopesPerRecipient + chunkIndex + 1,
            ),
          );
          _ensureAndroidOfflineEnvelopeLineWithinLimit(
            chunkEnvelope.envelopeBase64,
          );
          writtenBytes += await _appendAndroidSavedFileAscii(
            output,
            '${chunkEnvelope.envelopeBase64}\n',
          );
        }
      }

      digestInput.close();
      digestClosed = true;
      final writtenDigest = digestSink.digest;
      if (writtenPayloadBytes != scan.totalSize ||
          writtenDigest == null ||
          _digestBase64Url(writtenDigest) != scan.fileSha256) {
        throw const SecureStoreException('群组离线密封期间源文件发生变化，已拒绝生成不一致信封。');
      }

      final sealedFile = await _secureStore.finishSavedFile(
        file: output,
        bytes: writtenBytes,
      );
      final savedPath = _androidSavedFileDisplayPath(sealedFile);
      final record = AndroidSealedEnvelopeRecord(
        envelopeId:
            firstEnvelopeId ??
            (throw const SecureStoreException('群组离线密封未生成 manifest。')),
        kind: 'group_file',
        recipientKeyId: group.groupId,
        recipientDisplayName: group.displayName,
        createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
        messageCounter: firstCounter,
        sourceName: fileName,
        payloadSize: scan.totalSize,
        envelopeSize: writtenBytes,
        path: savedPath,
        uri: sealedFile.uri,
        displayPath: sealedFile.displayPath,
        mime: sealedFile.mime,
        sizeBytes: sealedFile.bytes,
      );
      await db.addSealedEnvelope(record);
      completed = true;
      return _AndroidSealResult(
        label: '密封群组文件',
        path: savedPath,
        record: record,
        details: [
          '群组文件已密封为逐成员流式信封。',
          'group: ${group.displayName} / ${group.groupId}',
          'recipients: ${recipients.length}',
          'file: $fileName',
          'payload: ${_formatByteCount(scan.totalSize)}',
          'chunks: $chunkCount',
          'envelopes: $envelopeCount',
          '信封: ${record.envelopeId}',
          'bytes: $writtenBytes',
          savedPath,
        ].join('\n'),
      );
    } finally {
      if (!digestClosed) {
        try {
          digestInput.close();
        } catch (_) {
          // Best-effort hash cleanup; the real failure is reported above.
        }
      }
      if (!completed) {
        await _secureStore.deleteSavedFile(
          uri: output.uri,
          path: output.displayPath,
        );
      }
    }
  }

  List<AndroidMessageRecord> _selectedAndroidMessageRecords() {
    final selectedIds = _selectedAndroidMessageIds;
    return _androidMessagesForSelectedConversation()
        .where((message) => selectedIds.contains(message.envelopeId))
        .toList(growable: false);
  }

  void _toggleAndroidMessageSelection(AndroidMessageRecord message) {
    setState(() {
      _androidMessageSelectionMode = true;
      if (_selectedAndroidMessageIds.contains(message.envelopeId)) {
        _selectedAndroidMessageIds.remove(message.envelopeId);
      } else {
        _selectedAndroidMessageIds.add(message.envelopeId);
      }
      if (_selectedAndroidMessageIds.isEmpty) {
        _androidMessageSelectionMode = false;
      }
    });
  }

  void _clearAndroidMessageSelection() {
    setState(() {
      _androidMessageSelectionMode = false;
      _selectedAndroidMessageIds.clear();
    });
  }

  void _selectAllVisibleAndroidMessages() {
    final visibleIds = _androidMessagesForSelectedConversation()
        .map((message) => message.envelopeId)
        .toList(growable: false);
    if (visibleIds.isEmpty) {
      setState(() => _details = '当前聊天列表没有可选择的消息。');
      return;
    }
    setState(() {
      _androidMessageSelectionMode = true;
      _selectedAndroidMessageIds
        ..clear()
        ..addAll(visibleIds);
    });
  }

  Future<void> _deleteSelectedAndroidMessagesFromUi() async {
    final selectedMessages = _selectedAndroidMessageRecords();
    if (selectedMessages.isEmpty) return;
    final receivedFileCount = selectedMessages
        .where(
          (message) =>
              !message.isOutgoing &&
              _androidSavedFilePathForMessage(message) != null,
        )
        .length;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除聊天记录'),
            content: Text(
              [
                '将删除 ${selectedMessages.length} 条聊天记录。',
                if (receivedFileCount > 0)
                  '其中 $receivedFileCount 条接收文件会同时删除磁盘文件。',
              ].join('\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    await _run('删除聊天记录', () async {
      final messages = _selectedAndroidMessageRecords();
      if (messages.isEmpty) return;

      var deletedFileCount = 0;
      var missingFileCount = 0;
      final deletedFileKeys = <String>{};
      for (final message in messages) {
        if (message.isOutgoing) continue;
        final path = _androidSavedFilePathForMessage(message);
        final uri = message.attachmentUri?.trim();
        if ((path == null || path.isEmpty) && (uri == null || uri.isEmpty)) {
          continue;
        }
        final key = '${uri ?? ''}\u0000${path ?? ''}';
        if (!deletedFileKeys.add(key)) continue;
        final deleted = await _secureStore.deleteSavedFile(
          uri: uri,
          path: path,
        );
        if (deleted) {
          deletedFileCount += 1;
        } else {
          missingFileCount += 1;
        }
      }

      final db = await _ensureAndroidDbStore();
      final deletedMessageCount = await db.deleteMessages(
        messages.map((message) => message.envelopeId).toList(growable: false),
      );
      if (!mounted) return;
      setState(() {
        _androidMessageSelectionMode = false;
        _selectedAndroidMessageIds.clear();
        _details = [
          '已删除 $deletedMessageCount 条聊天记录。',
          if (deletedFileCount > 0) '已删除 $deletedFileCount 个接收文件。',
          if (missingFileCount > 0) '$missingFileCount 个接收文件未找到，已跳过。',
        ].join('\n');
      });
      await _refreshAndroidChatStore();
    });
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidOpaqueEnvelopeBase64(
    String envelopeBase64, {
    AndroidContactRecord? targetSenderContact,
    bool updateDetails = true,
  }) async {
    final envelopeBytes = _decodeOpaqueEnvelopeBase64(envelopeBase64);
    return _importAndroidOpaqueEnvelopeBytes(
      envelopeBytes,
      envelopeBase64: envelopeBase64.trim(),
      targetSenderContact: targetSenderContact,
      updateDetails: updateDetails,
    );
  }

  Future<void> _importAndroidOfflineEnvelopeFromFile() =>
      _run('从文件导入离线信封', () async {
        final envelopeFile = await _secureStore.pickOfflineEnvelopeFile();
        if (envelopeFile == null) {
          throw const SecureStoreException('未选择离线信封文件。');
        }
        await _importAndroidOfflineEnvelopeFileCore(envelopeFile);
      });

  Future<void> _importAndroidOfflineEnvelopeFile(AndroidPickedFile file) =>
      _run('打开离线信封', () => _importAndroidOfflineEnvelopeFileCore(file));

  Future<void> _importAndroidOfflineEnvelopeFileCore(
    AndroidPickedFile envelopeFile,
  ) async {
    final fileSize = envelopeFile.sizeBytes;
    debugPrint(
      'Envelope offline import picked file: '
      'name=${envelopeFile.name}, size=$fileSize, uri=${envelopeFile.uri}',
    );
    if (mounted) {
      setState(() {
        _details = [
          '已选择信封文件。',
          '文件：${envelopeFile.name}',
          '大小：${_formatOptionalByteCount(fileSize)}',
          '正在读取文件头...',
        ].join('\n');
      });
    }
    if (await _isAndroidOfflineGroupStreamEnvelopeFile(envelopeFile)) {
      if (mounted) {
        setState(() {
          _details = [
            '已识别群组流式信封。',
            '文件：${envelopeFile.name}',
            '信封大小：${_formatOptionalByteCount(fileSize)}',
            '正在寻找本机可拆封内容...',
          ].join('\n');
        });
      }
      await _importAndroidOfflineGroupStreamEnvelopeFile(envelopeFile);
      return;
    }
    if (await _isAndroidOfflineStreamEnvelopeFile(envelopeFile)) {
      if (mounted) {
        setState(() {
          _details = [
            '已识别流式信封。',
            '文件：${envelopeFile.name}',
            '信封大小：${_formatOptionalByteCount(fileSize)}',
            '正在读取 manifest...',
          ].join('\n');
        });
      }
      await _importAndroidOfflineStreamEnvelopeFile(envelopeFile);
      return;
    }
    if (fileSize != null && fileSize > _androidLegacyOfflineEnvelopeMaxBytes) {
      throw SecureStoreException(
        [
          '该文件不是新版流式信封，而是旧版单体信封或未知格式。',
          '文件：${envelopeFile.name}',
          '大小：${_formatByteCount(fileSize)}',
          '旧版单体信封不能流式拆封，大文件会导致 Android 内存压力或无响应。',
          '请在新版 Envelope 中重新密封，生成 $_androidOfflineStreamMagic 格式的信封后再拆封。',
        ].join('\n'),
      );
    }
    if (mounted) {
      setState(() {
        _details = [
          '正在读取旧版单体信封。',
          '文件：${envelopeFile.name}',
          '大小：${_formatOptionalByteCount(fileSize)}',
        ].join('\n');
      });
    }
    final envelopeBytes = await _readAndroidPickedFileBytes(
      envelopeFile,
      onProgress: (bytesRead, totalBytes) {
        if (!mounted) return;
        setState(() {
          _details = [
            '正在读取旧版单体信封。',
            '文件：${envelopeFile.name}',
            '进度：${_formatByteCount(bytesRead)} / ${_formatOptionalByteCount(totalBytes)}',
          ].join('\n');
        });
      },
    );
    if (envelopeBytes.isEmpty) {
      throw const SecureStoreException('离线信封文件为空。');
    }
    if (mounted) {
      setState(() {
        _details = [
          '旧版单体信封读取完成。',
          '文件：${envelopeFile.name}',
          '正在尝试拆封...',
        ].join('\n');
      });
    }
    await _importAndroidOpaqueEnvelopeBytes(
      envelopeBytes,
      writeDuplicateFile: true,
    );
  }

  Future<bool> _isAndroidOfflineStreamEnvelopeFile(
    AndroidPickedFile file,
  ) async {
    final magicBytes = ascii.encode('$_androidOfflineStreamMagic\n');
    final head = await _secureStore.readPickedFileChunk(
      uri: file.uri,
      offset: 0,
      length: magicBytes.length,
    );
    if (head.length < magicBytes.length) return false;
    for (var index = 0; index < magicBytes.length; index += 1) {
      if (head[index] != magicBytes[index]) return false;
    }
    return true;
  }

  Future<bool> _isAndroidOfflineGroupStreamEnvelopeFile(
    AndroidPickedFile file,
  ) async {
    final magicBytes = ascii.encode('$_androidOfflineGroupStreamMagic\n');
    final head = await _secureStore.readPickedFileChunk(
      uri: file.uri,
      offset: 0,
      length: magicBytes.length,
    );
    if (head.length < magicBytes.length) return false;
    for (var index = 0; index < magicBytes.length; index += 1) {
      if (head[index] != magicBytes[index]) return false;
    }
    return true;
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidOfflineStreamEnvelopeFile(
    AndroidPickedFile file,
  ) async {
    final db = await _ensureAndroidDbStore();
    _AndroidDecryptedOpaquePayload? manifestPayload;
    _AndroidFileManifest? manifest;
    AndroidContactRecord? senderContact;
    AndroidSavedFile? outputFile;
    AndroidSavedFile? finishedFile;
    var outputWritten = 0;
    var chunkIndex = 0;
    final digestSink = _AndroidDigestSink();
    final digestInput = crypto.sha256.startChunkedConversion(digestSink);

    try {
      await _forEachAndroidPickedFileLine(file, (lineIndex, line) async {
        if (lineIndex == 0) {
          if (line != _androidOfflineStreamMagic) {
            throw const SecureStoreException('离线流式信封文件头无效。');
          }
          return true;
        }
        if (line.trim().isEmpty) {
          return true;
        }
        if (lineIndex == 1) {
          final decrypted = _decryptAndroidOpaquePayloadBase64(line);
          if (decrypted.payload.mime != _androidOfflineFileManifestMime) {
            throw const SecureStoreException('离线流式信封缺少文件 manifest。');
          }
          final manifestJson = _decodeAndroidFileTransferPayload(
            decrypted.payload,
          );
          manifest = _validateAndroidFileManifest(
            manifestJson,
            expectedKind: 'offline_file_manifest',
            maxBytes: null,
            maxChunkSize: _androidOfflineFileChunkBytes,
          );
          manifestPayload = decrypted;
          senderContact = decrypted.contact;
          final currentManifest = manifest!;
          outputFile = await _secureStore.createSavedFile(
            name: _safeAndroidReceivedFileName(
              currentManifest.filename,
              currentManifest.mime,
            ),
            mime: currentManifest.mime,
            childDir: 'received',
          );
          if (mounted) {
            setState(() {
              _details = [
                '正在拆封流式信封。',
                'sender: ${_contactTitle(decrypted.contact)} / ${decrypted.contact.keyId}',
                '文件：${currentManifest.filename} (${_formatByteCount(currentManifest.totalSize)})',
                '分片：0/${currentManifest.chunkCount}',
                '已写入：0 B',
              ].join('\n');
            });
          }
          return true;
        }

        final currentManifest = manifest;
        final currentSenderContact = senderContact;
        final currentOutputFile = outputFile;
        if (currentManifest == null ||
            currentSenderContact == null ||
            currentOutputFile == null) {
          throw const SecureStoreException('离线流式信封 manifest 尚未读取。');
        }
        if (chunkIndex >= currentManifest.chunkCount) {
          throw const SecureStoreException('离线流式信封包含多余分片。');
        }
        final decrypted = _decryptAndroidOpaquePayloadBase64(
          line,
          targetSenderContact: currentSenderContact,
        );
        if (decrypted.payload.mime != _androidOfflineFileChunkMime) {
          throw SecureStoreException('离线流式信封分片类型无效：${decrypted.payload.mime}');
        }
        final chunkBytes = decrypted.payload.payloadBytes;
        final expectedHash = currentManifest.chunkSha256[chunkIndex];
        if (_sha256Base64Url(chunkBytes) != expectedHash) {
          throw SecureStoreException('离线流式信封分片 $chunkIndex SHA-256 校验失败。');
        }
        digestInput.add(chunkBytes);
        outputWritten += await _appendAndroidSavedFileBytes(
          currentOutputFile,
          chunkBytes,
        );
        chunkIndex += 1;
        if (mounted &&
            (chunkIndex == 1 ||
                chunkIndex == currentManifest.chunkCount ||
                chunkIndex % 2 == 0)) {
          setState(() {
            _details = [
              '正在拆封流式信封。',
              'sender: ${_contactTitle(currentSenderContact)} / ${currentSenderContact.keyId}',
              '文件：${currentManifest.filename} (${_formatByteCount(currentManifest.totalSize)})',
              '分片：$chunkIndex/${currentManifest.chunkCount}',
              '已写入：${_formatByteCount(outputWritten)}',
            ].join('\n');
          });
        }
        return true;
      });

      final currentManifest = manifest;
      final currentManifestPayload = manifestPayload;
      final currentSenderContact = senderContact;
      final currentOutputFile = outputFile;
      if (currentManifest == null ||
          currentManifestPayload == null ||
          currentSenderContact == null ||
          currentOutputFile == null) {
        throw const SecureStoreException('离线流式信封文件不完整。');
      }
      if (chunkIndex != currentManifest.chunkCount) {
        throw SecureStoreException(
          '离线流式信封分片不完整：$chunkIndex/${currentManifest.chunkCount}',
        );
      }
      if (outputWritten != currentManifest.totalSize) {
        throw SecureStoreException(
          '文件大小校验失败：$outputWritten != ${currentManifest.totalSize}',
        );
      }
      digestInput.close();
      final digest = digestSink.digest;
      if (digest == null ||
          _digestBase64Url(digest) != currentManifest.fileSha256) {
        throw const SecureStoreException('文件整体 SHA-256 校验失败。');
      }
      finishedFile = await _secureStore.finishSavedFile(
        file: currentOutputFile,
        bytes: outputWritten,
      );
      final savedPath = finishedFile.displayPath.trim().isNotEmpty
          ? finishedFile.displayPath.trim()
          : finishedFile.uri;
      final receivedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
      final message = AndroidMessageRecord(
        envelopeId: currentManifestPayload.payload.envelopeId,
        conversationId: currentManifestPayload.payload.conversationId,
        direction: 'incoming',
        isRead: false,
        peerKeyId: currentSenderContact.keyId,
        peerDisplayName: _contactTitle(currentSenderContact),
        createdAtUnixMs: receivedAtUnixMs,
        messageCounter: currentManifestPayload.payload.messageCounter,
        text: [
          '文件：${currentManifest.filename} (${_formatByteCount(currentManifest.totalSize)})',
          savedPath,
        ].join('\n'),
        opaqueEnvelopeBase64: '',
        attachmentUri: finishedFile.uri,
        attachmentPath: savedPath,
        attachmentMime: finishedFile.mime,
      );
      final inserted = await db.addMessage(
        message,
        recipientIdentityKeyId: _requireAndroidIdentity().keyId,
        createRelayResult: true,
      );
      final savedMessage = inserted
          ? message
          : (await db.getMessage(message.envelopeId)) ?? message;
      await _refreshAndroidChatStore();
      if (mounted) {
        setState(() {
          _details = [
            inserted ? '离线流式信封已拆封。' : '离线流式信封已拆封，聊天记录已存在。',
            'sender: ${_contactTitle(currentSenderContact)} / ${currentSenderContact.keyId}',
            message.text,
          ].join('\n');
        });
      }
      return _AndroidEnvelopeImportResult(
        message: savedMessage,
        duplicate: !inserted,
      );
    } finally {
      final incompleteOutputFile = outputFile;
      if (finishedFile == null && incompleteOutputFile != null) {
        await _secureStore.deleteSavedFile(
          uri: incompleteOutputFile.uri,
          path: incompleteOutputFile.displayPath,
        );
      }
    }
  }

  Future<_AndroidEnvelopeImportResult>
  _importAndroidOfflineGroupStreamEnvelopeFile(AndroidPickedFile file) async {
    final db = await _ensureAndroidDbStore();
    _AndroidEnvelopeImportResult? completedResult;
    _AndroidDecryptedOpaquePayload? manifestPayload;
    _AndroidFileManifest? manifest;
    AndroidContactRecord? senderContact;
    AndroidSavedFile? outputFile;
    AndroidSavedFile? finishedFile;
    String? groupConversationId;
    var outputWritten = 0;
    var chunkIndex = 0;
    var decryptableLines = 0;
    var skippedLines = 0;
    var digestClosed = false;
    final digestSink = _AndroidDigestSink();
    final digestInput = crypto.sha256.startChunkedConversion(digestSink);

    try {
      await _forEachAndroidPickedFileLine(file, (lineIndex, line) async {
        if (lineIndex == 0) {
          if (line != _androidOfflineGroupStreamMagic) {
            throw const SecureStoreException('群组离线流式信封文件头无效。');
          }
          return true;
        }
        if (line.trim().isEmpty) {
          return true;
        }

        if (manifest == null) {
          _AndroidDecryptedOpaquePayload decrypted;
          try {
            decrypted = _decryptAndroidOpaquePayloadBase64(line);
          } catch (_) {
            skippedLines += 1;
            return true;
          }
          decryptableLines += 1;
          if (decrypted.payload.mime == _androidGroupControlMime) {
            completedResult = await _importAndroidGroupControlPayload(
              decrypted.payload,
              decrypted.contact,
              decrypted.envelopeBase64,
              updateDetails: false,
            );
            if (mounted) {
              setState(() {
                _details = [
                  '群组离线文本已拆封。',
                  'sender: ${_contactTitle(decrypted.contact)} / ${decrypted.contact.keyId}',
                  completedResult!.message.text,
                  'skipped: $skippedLines',
                ].join('\n');
              });
            }
            return false;
          }
          if (decrypted.payload.mime != _androidOfflineFileManifestMime) {
            throw SecureStoreException(
              '群组离线流式信封首个可拆封载荷类型无效：${decrypted.payload.mime}',
            );
          }
          final manifestJson = _decodeAndroidFileTransferPayload(
            decrypted.payload,
          );
          final parsedManifest = _validateAndroidFileManifest(
            manifestJson,
            expectedKind: 'offline_file_manifest',
            maxBytes: null,
            maxChunkSize: _androidOfflineFileChunkBytes,
          );
          final parsedGroupConversationId =
              await _validateAndroidGroupFileManifestIfNeeded(
                manifestJson,
                decrypted.contact,
                db,
              );
          manifest = parsedManifest;
          manifestPayload = decrypted;
          senderContact = decrypted.contact;
          groupConversationId = parsedGroupConversationId;
          outputFile = await _secureStore.createSavedFile(
            name: _safeAndroidReceivedFileName(
              parsedManifest.filename,
              parsedManifest.mime,
            ),
            mime: parsedManifest.mime,
            childDir: 'received',
          );
          if (mounted) {
            setState(() {
              _details = [
                '正在拆封群组流式信封。',
                'sender: ${_contactTitle(decrypted.contact)} / ${decrypted.contact.keyId}',
                '文件：${parsedManifest.filename} (${_formatByteCount(parsedManifest.totalSize)})',
                '分片：0/${parsedManifest.chunkCount}',
                '已跳过非本机密文：$skippedLines',
              ].join('\n');
            });
          }
          return true;
        }

        final currentManifest = manifest!;
        final currentSenderContact = senderContact!;
        final currentOutputFile = outputFile!;
        if (chunkIndex >= currentManifest.chunkCount) {
          return false;
        }
        _AndroidDecryptedOpaquePayload decrypted;
        try {
          decrypted = _decryptAndroidOpaquePayloadBase64(
            line,
            targetSenderContact: currentSenderContact,
          );
        } catch (_) {
          skippedLines += 1;
          return true;
        }
        decryptableLines += 1;
        if (decrypted.payload.mime != _androidOfflineFileChunkMime) {
          throw SecureStoreException(
            '群组离线流式信封分片类型无效：${decrypted.payload.mime}',
          );
        }
        final chunkBytes = decrypted.payload.payloadBytes;
        final expectedHash = currentManifest.chunkSha256[chunkIndex];
        if (_sha256Base64Url(chunkBytes) != expectedHash) {
          throw SecureStoreException('群组离线流式信封分片 $chunkIndex SHA-256 校验失败。');
        }
        digestInput.add(chunkBytes);
        outputWritten += await _appendAndroidSavedFileBytes(
          currentOutputFile,
          chunkBytes,
        );
        chunkIndex += 1;
        if (mounted &&
            (chunkIndex == 1 ||
                chunkIndex == currentManifest.chunkCount ||
                chunkIndex % 2 == 0)) {
          setState(() {
            _details = [
              '正在拆封群组流式信封。',
              'sender: ${_contactTitle(currentSenderContact)} / ${currentSenderContact.keyId}',
              '文件：${currentManifest.filename} (${_formatByteCount(currentManifest.totalSize)})',
              '分片：$chunkIndex/${currentManifest.chunkCount}',
              '已写入：${_formatByteCount(outputWritten)}',
              '已跳过非本机密文：$skippedLines',
            ].join('\n');
          });
        }
        if (chunkIndex < currentManifest.chunkCount) {
          return true;
        }

        if (outputWritten != currentManifest.totalSize) {
          throw SecureStoreException(
            '文件大小校验失败：$outputWritten != ${currentManifest.totalSize}',
          );
        }
        digestInput.close();
        digestClosed = true;
        final digest = digestSink.digest;
        if (digest == null ||
            _digestBase64Url(digest) != currentManifest.fileSha256) {
          throw const SecureStoreException('文件整体 SHA-256 校验失败。');
        }
        finishedFile = await _secureStore.finishSavedFile(
          file: currentOutputFile,
          bytes: outputWritten,
        );
        final savedPath = finishedFile!.displayPath.trim().isNotEmpty
            ? finishedFile!.displayPath.trim()
            : finishedFile!.uri;
        final currentManifestPayload = manifestPayload!;
        final receivedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
        final message = AndroidMessageRecord(
          envelopeId: currentManifestPayload.payload.envelopeId,
          conversationId:
              groupConversationId ??
              currentManifestPayload.payload.conversationId,
          direction: 'incoming',
          isRead: false,
          peerKeyId: currentSenderContact.keyId,
          peerDisplayName: _contactTitle(currentSenderContact),
          createdAtUnixMs: receivedAtUnixMs,
          messageCounter: currentManifestPayload.payload.messageCounter,
          text: [
            '文件：${currentManifest.filename} (${_formatByteCount(currentManifest.totalSize)})',
            savedPath,
          ].join('\n'),
          opaqueEnvelopeBase64: '',
          attachmentUri: finishedFile!.uri,
          attachmentPath: savedPath,
          attachmentMime: finishedFile!.mime,
        );
        final inserted = await db.addMessage(
          message,
          recipientIdentityKeyId: _requireAndroidIdentity().keyId,
          createRelayResult: true,
        );
        final savedMessage = inserted
            ? message
            : (await db.getMessage(message.envelopeId)) ?? message;
        await _refreshAndroidChatStore();
        if (mounted) {
          setState(() {
            _details = [
              inserted ? '群组离线流式信封已拆封。' : '群组离线流式信封已拆封，聊天记录已存在。',
              'sender: ${_contactTitle(currentSenderContact)} / ${currentSenderContact.keyId}',
              message.text,
              'skipped: $skippedLines',
            ].join('\n');
          });
        }
        completedResult = _AndroidEnvelopeImportResult(
          message: savedMessage,
          duplicate: !inserted,
        );
        return false;
      });

      final result = completedResult;
      if (result != null) return result;
      final currentManifest = manifest;
      if (currentManifest == null) {
        throw SecureStoreException(
          decryptableLines == 0
              ? '未找到可由本机身份解密的群组离线信封内容。'
              : '群组离线流式信封缺少文件 manifest。',
        );
      }
      throw SecureStoreException(
        '群组离线流式信封分片不完整：$chunkIndex/${currentManifest.chunkCount}',
      );
    } finally {
      if (!digestClosed) {
        try {
          digestInput.close();
        } catch (_) {
          // Best-effort cleanup; the real failure is reported above.
        }
      }
      final incompleteOutputFile = outputFile;
      if (finishedFile == null && incompleteOutputFile != null) {
        await _secureStore.deleteSavedFile(
          uri: incompleteOutputFile.uri,
          path: incompleteOutputFile.displayPath,
        );
      }
    }
  }

  Future<void> _forEachAndroidPickedFileLine(
    AndroidPickedFile file,
    Future<bool> Function(int lineIndex, String line) onLine,
  ) async {
    final lineBuilder = BytesBuilder(copy: false);
    final knownSize = file.sizeBytes;
    var offset = 0;
    var lineIndex = 0;
    while (true) {
      if (knownSize != null && offset >= knownSize) {
        break;
      }
      final requestedLength = knownSize == null
          ? _androidOfflineStreamReadBytes
          : min(_androidOfflineStreamReadBytes, knownSize - offset);
      if (requestedLength <= 0) {
        break;
      }
      final chunk = await _secureStore.readPickedFileChunk(
        uri: file.uri,
        offset: offset,
        length: requestedLength,
      );
      if (chunk.isEmpty) {
        break;
      }
      offset += chunk.length;
      var start = 0;
      for (var index = 0; index < chunk.length; index += 1) {
        if (chunk[index] != 0x0a) continue;
        if (index > start) {
          if (lineBuilder.length + index - start >
              _androidMaximumOfflineEnvelopeLineCharacters) {
            throw SecureStoreException(
              '离线信封单行超过 '
              '$_androidMaximumOfflineEnvelopeLineCharacters 字符资源上限。',
            );
          }
          lineBuilder.add(chunk.sublist(start, index));
        }
        if (lineIndex > _androidMaximumOfflineGroupEnvelopeLines) {
          throw SecureStoreException(
            '离线信封密文行超过 '
            '$_androidMaximumOfflineGroupEnvelopeLines 条资源上限。',
          );
        }
        final lineBytes = lineBuilder.takeBytes();
        var line = ascii.decode(lineBytes, allowInvalid: true);
        if (line.endsWith('\r')) {
          line = line.substring(0, line.length - 1);
        }
        final shouldContinue = await onLine(lineIndex, line);
        lineIndex += 1;
        if (!shouldContinue) return;
        start = index + 1;
      }
      if (start < chunk.length) {
        if (lineBuilder.length + chunk.length - start >
            _androidMaximumOfflineEnvelopeLineCharacters) {
          throw SecureStoreException(
            '离线信封单行超过 '
            '$_androidMaximumOfflineEnvelopeLineCharacters 字符资源上限。',
          );
        }
        lineBuilder.add(chunk.sublist(start));
      }
      if (chunk.length < requestedLength) {
        break;
      }
    }
    final trailing = lineBuilder.takeBytes();
    if (trailing.isNotEmpty) {
      if (lineIndex > _androidMaximumOfflineGroupEnvelopeLines) {
        throw SecureStoreException(
          '离线信封密文行超过 '
          '$_androidMaximumOfflineGroupEnvelopeLines 条资源上限。',
        );
      }
      var line = ascii.decode(trailing, allowInvalid: true);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      await onLine(lineIndex, line);
    }
  }

  _AndroidDecryptedOpaquePayload _decryptAndroidOpaquePayloadBase64(
    String envelopeBase64, {
    AndroidContactRecord? targetSenderContact,
  }) {
    final identity = _requireAndroidIdentity();
    final normalizedBase64 = envelopeBase64.trim();
    if (normalizedBase64.isEmpty) {
      throw const AndroidInvalidEnvelopePayloadException('离线信封为空。');
    }
    NativeInboundOpaquePayload? inbound;
    AndroidContactRecord? contact;
    Object? lastError;
    final candidates = targetSenderContact == null
        ? _androidKnownContactCandidates()
        : <AndroidContactRecord>[targetSenderContact];
    for (final candidate in candidates) {
      try {
        inbound = _nativeCore.decryptOpaquePayload(
          identityJson: identity.identityJson,
          senderContactJson: candidate.contactJson,
          envelopeBase64: normalizedBase64,
        );
        contact = candidate;
        break;
      } on EnvelopeNativeException catch (error) {
        lastError = error;
      }
    }
    if (inbound == null || contact == null) {
      throw AndroidEnvelopeCiphertextRejectedException(
        _opaqueEnvelopeDecryptFailureMessage(
          candidates: candidates,
          targetSenderContact: targetSenderContact,
          lastError: lastError,
        ),
        lastError,
      );
    }
    return _AndroidDecryptedOpaquePayload(
      payload: inbound,
      contact: contact,
      envelopeBase64: normalizedBase64,
    );
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidOpaqueEnvelopeBytes(
    List<int> envelopeBytes, {
    String? envelopeBase64,
    AndroidContactRecord? targetSenderContact,
    bool updateDetails = true,
    bool writeDuplicateFile = false,
  }) async {
    final identity = _requireAndroidIdentity();
    if (envelopeBytes.isEmpty) {
      throw const AndroidInvalidEnvelopePayloadException('离线信封为空。');
    }
    final normalizedBase64 =
        envelopeBase64?.trim() ?? _encodeOpaqueEnvelopeBase64(envelopeBytes);
    NativeInboundOpaquePayload? inbound;
    AndroidContactRecord? contact;
    Object? lastError;
    final candidates = targetSenderContact == null
        ? _androidKnownContactCandidates()
        : <AndroidContactRecord>[targetSenderContact];
    for (final candidate in candidates) {
      try {
        inbound = _nativeCore.decryptOpaquePayload(
          identityJson: identity.identityJson,
          senderContactJson: candidate.contactJson,
          envelopeBase64: normalizedBase64,
        );
        contact = candidate;
        break;
      } on EnvelopeNativeException catch (error) {
        lastError = error;
      }
    }
    if (inbound == null || contact == null) {
      throw AndroidEnvelopeCiphertextRejectedException(
        _opaqueEnvelopeDecryptFailureMessage(
          candidates: candidates,
          targetSenderContact: targetSenderContact,
          lastError: lastError,
        ),
        lastError,
      );
    }
    final decrypted = inbound;
    final senderContact = contact;
    final receiptDb = await _ensureAndroidDbStore();
    final priorResult = await receiptDb.relayHa.incomingResult(
      senderKeyId: senderContact.keyId,
      recipientKeyId: identity.keyId,
      envelopeId: decrypted.envelopeId,
    );
    if (priorResult != null) {
      if (priorResult['envelope_sha256'] != _sha256Base64Url(envelopeBytes)) {
        throw const AndroidInvalidEnvelopePayloadException('同一信封 ID 的密文不一致。');
      }
      if (priorResult['outcome'] == 'delivered' ||
          priorResult['outcome'] == 'rejected') {
        final stored = await receiptDb.getMessage(decrypted.envelopeId);
        return _AndroidEnvelopeImportResult(
          message:
              stored ??
              AndroidMessageRecord(
                envelopeId: decrypted.envelopeId,
                conversationId: decrypted.conversationId,
                direction: 'incoming',
                peerKeyId: senderContact.keyId,
                peerDisplayName: _contactTitle(senderContact),
                createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
                messageCounter: decrypted.messageCounter,
                text: '此前已处理的信封。',
                opaqueEnvelopeBase64: normalizedBase64,
              ),
          duplicate: true,
          receiptEnvelopeId: decrypted.envelopeId,
        );
      }
    }
    if (decrypted.mime == _androidGroupControlMime) {
      return _importAndroidGroupControlPayload(
        decrypted,
        senderContact,
        normalizedBase64,
        updateDetails: updateDetails,
      );
    }
    if (decrypted.mime == _androidContactControlMime) {
      return _importAndroidContactControlPayload(
        decrypted,
        senderContact,
        normalizedBase64,
        updateDetails: updateDetails,
      );
    }
    if (decrypted.mime == _androidFileChunkMime ||
        decrypted.mime == _androidFileManifestMime) {
      final result = await _importAndroidFileTransferPayload(
        decrypted,
        senderContact,
        normalizedBase64,
        updateDetails: updateDetails,
      );
      final db = await _ensureAndroidDbStore();
      final payload = _decodeAndroidFileTransferPayload(decrypted);
      await db.relayHa.recordFilePart(
        senderKeyId: senderContact.keyId,
        recipientKeyId: identity.keyId,
        envelopeId: decrypted.envelopeId,
        envelopeBase64: normalizedBase64,
        transferId: payload['transfer_id'] as String,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
      );
      return _AndroidEnvelopeImportResult(
        message: result.message,
        duplicate: result.duplicate,
        receiptEnvelopeId: decrypted.envelopeId,
      );
    }
    final db = await _ensureAndroidDbStore();
    final existing = await db.getMessage(decrypted.envelopeId);
    if (existing != null) {
      final duplicateContent = writeDuplicateFile && !decrypted.isText
          ? await _androidMessageContentForInboundPayload(decrypted)
          : null;
      await _refreshAndroidChatStore();
      if (mounted && updateDetails) {
        setState(() {
          _androidEnvelopeBase64Controller.clear();
          _details = [
            duplicateContent == null ? '重复离线信封已忽略。' : '重复离线信封已拆封，聊天记录已存在。',
            'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
            duplicateContent?.text ?? existing.text,
          ].join('\n');
        });
      }
      return _AndroidEnvelopeImportResult(message: existing, duplicate: true);
    }
    final content = await _androidMessageContentForInboundPayload(decrypted);
    final receivedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
    final message = AndroidMessageRecord(
      envelopeId: decrypted.envelopeId,
      conversationId: decrypted.conversationId,
      direction: 'incoming',
      isRead: false,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: receivedAtUnixMs,
      messageCounter: decrypted.messageCounter,
      text: content.text,
      opaqueEnvelopeBase64: normalizedBase64,
      attachmentUri: content.attachmentUri,
      attachmentPath: content.attachmentPath,
      attachmentMime: content.attachmentMime,
    );
    final inserted = await db.addMessage(
      message,
      recipientIdentityKeyId: _requireAndroidIdentity().keyId,
      createRelayResult: true,
    );
    final savedMessage = inserted
        ? message
        : (await db.getMessage(message.envelopeId)) ?? message;
    await _refreshAndroidChatStore();
    if (mounted && updateDetails) {
      setState(() {
        _androidEnvelopeBase64Controller.clear();
        _details = [
          inserted ? '已导入并解密消息。' : '重复离线信封已忽略。',
          'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
          'text: ${savedMessage.text}',
        ].join('\n');
      });
    }
    return _AndroidEnvelopeImportResult(
      message: savedMessage,
      duplicate: !inserted,
    );
  }

  String _opaqueEnvelopeDecryptFailureMessage({
    required List<AndroidContactRecord> candidates,
    required AndroidContactRecord? targetSenderContact,
    required Object? lastError,
  }) {
    final suffix = lastError == null ? '' : '\n最后错误：$lastError';
    final lastErrorText = lastError?.toString() ?? '';
    if (lastErrorText.contains(
      'opaque envelope authentication or decryption failed',
    )) {
      return [
        '无法拆封该离线信封。',
        '它可能不是发给本机当前身份。',
        '请确认发送方选择的是本机当前 contact；如果本机重装过，请重新交换 contact 后再密封。$suffix',
      ].join('\n');
    }
    if (targetSenderContact != null) {
      return '无法用 ${_contactTitle(targetSenderContact)} 的 contact 解密该离线信封。$suffix';
    }
    if (candidates.isEmpty) {
      return '本机没有保存任何 contact。请先添加发送方 contact。$suffix';
    }
    return '无法用任何已保存 contact 解密该离线信封。请确认已添加发送方最新 contact。$suffix';
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidFileTransferPayload(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    String normalizedEnvelopeBase64, {
    bool updateDetails = true,
  }) async {
    final decoded = _decodeAndroidFileTransferPayload(payload);
    final kind = decoded['kind']?.toString() ?? '';
    if (kind == 'file_chunk') {
      return _importAndroidFileChunkPayload(
        payload,
        senderContact,
        decoded,
        updateDetails: updateDetails,
      );
    }
    if (kind == 'file_manifest') {
      return _importAndroidFileManifestPayload(
        payload,
        senderContact,
        decoded,
        normalizedEnvelopeBase64,
        updateDetails: updateDetails,
      );
    }
    throw AndroidInvalidEnvelopePayloadException('未知文件分片载荷：$kind');
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidContactControlPayload(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    String normalizedEnvelopeBase64, {
    bool updateDetails = true,
  }) async {
    final decoded = jsonDecode(utf8.decode(payload.payloadBytes));
    if (decoded is! Map) {
      throw const AndroidInvalidEnvelopePayloadException(
        '联系人控制载荷不是 JSON object。',
      );
    }
    final map = decoded.cast<String, Object?>();
    if (map['version'] != 1) {
      throw const AndroidInvalidEnvelopePayloadException('不支持的联系人控制载荷版本。');
    }
    final type = map['type']?.toString() ?? '';
    if (type != 'contact_deleted') {
      throw AndroidInvalidEnvelopePayloadException('未知联系人控制事件：$type');
    }
    final actorKeyId = map['actor_key_id']?.toString() ?? '';
    if (actorKeyId.isEmpty || actorKeyId != senderContact.keyId) {
      throw AndroidInvalidEnvelopePayloadException(
        '联系人控制载荷 actor 与发送方不一致：$actorKeyId / ${senderContact.keyId}',
      );
    }
    final selfKeyId = _requireAndroidIdentity().keyId;
    final targetKeyId = map['target_key_id']?.toString() ?? '';
    if (targetKeyId != selfKeyId) {
      throw AndroidInvalidEnvelopePayloadException(
        '联系人控制载荷目标不是本机身份：$targetKeyId / $selfKeyId',
      );
    }

    final db = await _ensureAndroidDbStore();
    final deleted = await db.deleteContact(senderContact.keyId);
    _androidIncomingMessageCounts = {
      for (final entry in _androidIncomingMessageCounts.entries)
        if (entry.key != senderContact.keyId) entry.key: entry.value,
    };
    if (_selectedAndroidContactKeyId == senderContact.keyId) {
      _selectedAndroidContactKeyId = null;
    }
    await _refreshAndroidChatStore();
    final summary = deleted > 0
        ? '联系人已自动删除：${_contactTitle(senderContact)}'
        : '联系人删除通知已处理：${_contactTitle(senderContact)}';
    final eventMessage = AndroidMessageRecord(
      envelopeId: payload.envelopeId,
      conversationId: senderContact.keyId,
      direction: 'incoming',
      isRead: false,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
      messageCounter: payload.messageCounter,
      text: summary,
      opaqueEnvelopeBase64: normalizedEnvelopeBase64,
    );
    if (mounted && updateDetails) {
      setState(() {
        _androidEnvelopeBase64Controller.clear();
        _details = [
          summary,
          'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
        ].join('\n');
      });
    }
    return _AndroidEnvelopeImportResult(
      message: eventMessage,
      duplicate: false,
    );
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidGroupControlPayload(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    String normalizedEnvelopeBase64, {
    bool updateDetails = true,
  }) async {
    final db = await _ensureAndroidDbStore();
    final existingMessage = await db.getMessage(payload.envelopeId);
    if (existingMessage != null) {
      return _AndroidEnvelopeImportResult(
        message: existingMessage,
        duplicate: true,
      );
    }
    final decoded = jsonDecode(utf8.decode(payload.payloadBytes));
    if (decoded is! Map) {
      throw const AndroidInvalidEnvelopePayloadException(
        '群组控制载荷不是 JSON object。',
      );
    }
    final map = decoded.cast<String, Object?>();
    if (map['version'] != 1) {
      throw const AndroidInvalidEnvelopePayloadException('不支持的群组控制载荷版本。');
    }
    final actorKeyId = map['actor_key_id']?.toString() ?? '';
    if (actorKeyId.isEmpty || actorKeyId != senderContact.keyId) {
      throw AndroidInvalidEnvelopePayloadException(
        '群组控制载荷 actor 与发送方不一致：$actorKeyId / ${senderContact.keyId}',
      );
    }
    _validateAndroidGroupControlSignature(map, senderContact);
    final incomingState = decodeAndroidGroupControlState(map);
    final group = incomingState.group;
    final incomingMembers = incomingState.members;
    final type = map['type']?.toString() ?? '';
    if (!_androidSupportedPortableGroupEventTypes.contains(type)) {
      throw AndroidInvalidEnvelopePayloadException('未知群组控制事件：$type');
    }
    final existingGroup = await db.getGroup(group.groupId);
    final existingMembers = await db.getGroupMembers(groupId: group.groupId);
    if (androidGroupEpochNeedsCausalDeferral(
      eventType: type,
      incomingEpoch: group.epoch,
      currentEpoch: existingGroup?.epoch,
    )) {
      final expectedEpoch = existingGroup == null
          ? 1
          : type == 'group_message'
          ? existingGroup.epoch
          : existingGroup.epoch + 1;
      throw AndroidMailboxMissingPrerequisiteException(
        '群组事件 epoch 必须为 $expectedEpoch，实际为 ${group.epoch}。',
      );
    }
    if (existingGroup == null &&
        (type != 'group_invite' ||
            senderContact.keyId != group.ownerKeyId ||
            group.epoch != 1 ||
            !group.isActive ||
            incomingMembers.where((member) => member.isOwner).length != 1 ||
            !incomingMembers.any(
              (member) =>
                  member.keyId == group.ownerKeyId &&
                  member.isOwner &&
                  member.isActive,
            ))) {
      throw const AndroidInvalidEnvelopePayloadException(
        '只有活跃群主发送的 group_invite 才能创建本地群组。',
      );
    }
    if (existingGroup != null &&
        type != 'group_message' &&
        !existingMembers.any((member) => member.keyId == senderContact.keyId)) {
      throw const AndroidMailboxMissingPrerequisiteException('群组事件发送方不是已知群成员。');
    }
    final storedGroup = type == 'group_message' && existingGroup != null
        ? existingGroup
        : _newerAndroidGroupRecord(existingGroup, group);
    final staleEvent =
        existingGroup != null && group.epoch < existingGroup.epoch;
    var mergedMembers = type == 'group_message'
        ? existingMembers
        : staleEvent
        ? existingMembers
        : _mergeIncomingAndroidGroupMembers(
            type: type,
            existingMembers: existingMembers,
            incomingMembers: incomingMembers,
          );
    if (type == 'member_endorsed') {
      _validateIncomingAndroidConsensusEndorsement(
        group: group,
        payload: map,
        members: mergedMembers,
      );
    }
    if (type == 'group_message') {
      final selfKeyId = _requireAndroidIdentity().keyId;
      final self = mergedMembers
          .where((member) => member.keyId == selfKeyId)
          .toList(growable: false);
      if (self.isEmpty || !self.first.isActive) {
        throw const AndroidInvalidEnvelopePayloadException(
          '本机身份不是该群活跃成员，拒绝导入群消息。',
        );
      }
      final senderMember = mergedMembers
          .where((member) => member.keyId == senderContact.keyId)
          .toList(growable: false);
      if (senderMember.isEmpty || !senderMember.first.isActive) {
        throw const AndroidInvalidEnvelopePayloadException(
          '发送方不是该群活跃成员，拒绝导入群消息。',
        );
      }
    }
    final groupEvent = _groupEventFromPayload(group, map);
    mergedMembers = _calculateAndroidConsensusAdmissions(
      group: storedGroup,
      members: mergedMembers,
      events: [
        ...await db.getGroupEvents(groupId: group.groupId),
        groupEvent,
      ],
    );
    final membershipLossEvent =
        type == 'member_left' || type == 'member_removed';
    final groupDissolvedByEvent =
        membershipLossEvent &&
        (!storedGroup.isActive ||
            androidGroupShouldAutoDissolveForMembers(mergedMembers));
    final committedGroup = groupDissolvedByEvent
        ? storedGroup.copyWith(isActive: false)
        : storedGroup;

    if (type == 'group_message') {
      final existing = await db.getMessage(payload.envelopeId);
      if (existing != null) {
        await _refreshAndroidChatStore();
        return _AndroidEnvelopeImportResult(message: existing, duplicate: true);
      }
      final text = map['text']?.toString() ?? '';
      final receivedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
      final message = AndroidMessageRecord(
        envelopeId: payload.envelopeId,
        conversationId: storedGroup.groupId,
        direction: 'incoming',
        isRead: false,
        peerKeyId: senderContact.keyId,
        peerDisplayName: _contactTitle(senderContact),
        createdAtUnixMs: receivedAtUnixMs,
        messageCounter: payload.messageCounter,
        text: text,
        opaqueEnvelopeBase64: normalizedEnvelopeBase64,
      );
      final inserted = await db.importGroupControlTransition(
        group: committedGroup,
        members: mergedMembers,
        event: groupEvent,
        message: message,
        recipientIdentityKeyId: _requireAndroidIdentity().keyId,
        createRelayResult: true,
      );
      final savedMessage = inserted
          ? message
          : (await db.getMessage(message.envelopeId)) ?? message;
      await _refreshAndroidChatStore();
      if (mounted && updateDetails) {
        setState(() {
          _details = [
            inserted ? '已导入群消息。' : '重复群消息已忽略。',
            'group: ${storedGroup.displayName}',
            'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
            savedMessage.text,
          ].join('\n');
        });
      }
      return _AndroidEnvelopeImportResult(
        message: savedMessage,
        duplicate: !inserted,
      );
    }

    final personalNotice =
        type == 'group_invite' ||
        (membershipLossEvent && groupDissolvedByEvent);
    final dissolutionReasons = groupDissolvedByEvent
        ? _androidGroupDissolutionReasonsFromPayload(map, mergedMembers)
        : const <String>[];
    final dissolutionReasonText = _androidGroupDissolutionReasonText(
      dissolutionReasons,
    );
    final dissolutionSummary = dissolutionReasonText.isEmpty
        ? '群已解散：${storedGroup.displayName}'
        : '群已解散：${storedGroup.displayName}（原因：$dissolutionReasonText）';
    final summary = switch (type) {
      'group_invite' => '收到群邀请：${storedGroup.displayName}',
      'member_accepted' => '群成员已接受邀请：${storedGroup.displayName}',
      'member_endorsed' => '群成员已背书：${storedGroup.displayName}',
      'group_renamed' => '群名称已更新：${storedGroup.displayName}',
      'group_avatar_updated' => '群头像已更新：${storedGroup.displayName}',
      'member_removed' when groupDissolvedByEvent => dissolutionSummary,
      'member_removed' => '群成员已移除：${storedGroup.displayName}',
      'member_left' when groupDissolvedByEvent => dissolutionSummary,
      'member_left' => '群成员已退出：${storedGroup.displayName}',
      _ => '收到群组事件：${storedGroup.displayName}',
    };
    final eventMessage = AndroidMessageRecord(
      envelopeId: payload.envelopeId,
      conversationId: personalNotice
          ? senderContact.keyId
          : storedGroup.groupId,
      direction: 'incoming',
      isRead: false,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
      messageCounter: payload.messageCounter,
      text: summary,
      opaqueEnvelopeBase64: normalizedEnvelopeBase64,
      deliveryDetail: _androidGroupControlMessageDetail(
        type: type,
        groupId: storedGroup.groupId,
      ),
    );
    final inserted = await db.importGroupControlTransition(
      group: committedGroup,
      members: mergedMembers,
      event: groupEvent,
      message: eventMessage,
      recipientIdentityKeyId: _requireAndroidIdentity().keyId,
      createRelayResult: true,
    );
    final savedEventMessage = inserted
        ? eventMessage
        : (await db.getMessage(eventMessage.envelopeId)) ?? eventMessage;
    await _refreshAndroidChatStore();
    if (mounted && updateDetails) {
      setState(() {
        _details = [
          inserted ? summary : '重复群组事件已忽略：${storedGroup.displayName}',
          'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
        ].join('\n');
      });
    }
    return _AndroidEnvelopeImportResult(
      message: savedEventMessage,
      duplicate: !inserted,
    );
  }

  AndroidGroupRecord _newerAndroidGroupRecord(
    AndroidGroupRecord? existing,
    AndroidGroupRecord incoming,
  ) {
    if (existing == null) return incoming;
    if (incoming.epoch > existing.epoch) return incoming;
    if (incoming.epoch < existing.epoch) return existing;
    if (incoming.updatedAtUnixMs >= existing.updatedAtUnixMs) return incoming;
    return existing;
  }

  List<AndroidGroupMemberRecord> _mergeIncomingAndroidGroupMembers({
    required String type,
    required List<AndroidGroupMemberRecord> existingMembers,
    required List<AndroidGroupMemberRecord> incomingMembers,
  }) {
    final existingByKey = {
      for (final member in existingMembers) member.keyId: member,
    };
    final merged = <String, AndroidGroupMemberRecord>{};
    for (final incoming in incomingMembers) {
      final existing = existingByKey[incoming.keyId];
      if (existing == null) {
        merged[incoming.keyId] = incoming;
        continue;
      }
      final destructive =
          incoming.status == AndroidGroupMemberStatus.removed ||
          incoming.status == AndroidGroupMemberStatus.left ||
          type == 'member_removed' ||
          type == 'member_left';
      if (destructive) {
        merged[incoming.keyId] = incoming;
        continue;
      }
      if (existing.isActive &&
          incoming.status != AndroidGroupMemberStatus.active) {
        merged[incoming.keyId] = existing.copyWith(
          displayName: incoming.displayName.isEmpty
              ? existing.displayName
              : incoming.displayName,
          contactJson: incoming.contactJson.isEmpty
              ? existing.contactJson
              : incoming.contactJson,
          updatedAtUnixMs: max(
            existing.updatedAtUnixMs,
            incoming.updatedAtUnixMs,
          ),
        );
        continue;
      }
      merged[incoming.keyId] =
          incoming.updatedAtUnixMs >= existing.updatedAtUnixMs
          ? incoming
          : existing;
    }
    for (final existing in existingMembers) {
      merged.putIfAbsent(existing.keyId, () => existing);
    }
    return merged.values.toList(growable: false);
  }

  Map<String, Object?> _decodeAndroidFileTransferPayload(
    NativeInboundOpaquePayload payload,
  ) {
    final decoded = jsonDecode(utf8.decode(payload.payloadBytes));
    if (decoded is! Map) {
      throw const AndroidInvalidEnvelopePayloadException(
        '文件分片载荷不是 JSON object。',
      );
    }
    final map = decoded.cast<String, Object?>();
    if ((map['version'] as num?)?.toInt() != 1) {
      throw const AndroidInvalidEnvelopePayloadException('不支持的文件分片版本。');
    }
    return map;
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidFileChunkPayload(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    Map<String, Object?> chunkJson, {
    bool updateDetails = true,
  }) async {
    final transferId = _requiredAndroidTransferString(chunkJson, 'transfer_id');
    final chunkIndex = _requiredAndroidTransferInt(chunkJson, 'chunk_index');
    final chunkCount = _requiredAndroidTransferInt(chunkJson, 'chunk_count');
    final chunkSha256 = _requiredAndroidTransferString(
      chunkJson,
      'chunk_sha256',
    );
    final dataBase64 = _requiredAndroidTransferString(chunkJson, 'data_b64');
    if (chunkIndex < 0 || chunkIndex >= chunkCount) {
      throw AndroidInvalidEnvelopePayloadException(
        '文件分片序号无效：$chunkIndex / $chunkCount',
      );
    }
    final chunkBytes = base64Url.decode(base64Url.normalize(dataBase64));
    final actualSha256 = _sha256Base64Url(chunkBytes);
    if (actualSha256 != chunkSha256) {
      throw const AndroidInvalidEnvelopePayloadException('文件分片 SHA-256 校验失败。');
    }

    final db = await _ensureAndroidDbStore();
    await db.upsertInboundFileChunk(
      transferId: transferId,
      chunkIndex: chunkIndex,
      chunkSha256: chunkSha256,
      chunkSize: chunkBytes.length,
      envelopeId: payload.envelopeId,
      chunkDataBase64: dataBase64,
    );
    final completed = await _tryCompleteAndroidFileTransfer(
      transferId,
      senderContact,
      updateDetails: updateDetails,
    );
    if (completed != null) return completed;
    final received = await db.getReceivedFileChunkCount(transferId);
    final transfer = await db.getFileTransfer(transferId);
    final filename = transfer?['filename']?.toString();
    final totalSize = (transfer?['total_size'] as num?)?.toInt();
    final partial = _partialAndroidFileTransferMessage(
      payload,
      senderContact,
      _androidReceivingFileProgressText(
        filename: filename,
        totalSize: totalSize,
        received: received,
        total: chunkCount,
      ),
    );
    if (mounted && updateDetails) {
      setState(() => _details = partial.text);
    }
    return _AndroidEnvelopeImportResult(message: partial, duplicate: false);
  }

  Future<_AndroidEnvelopeImportResult> _importAndroidFileManifestPayload(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    Map<String, Object?> manifestJson,
    String normalizedEnvelopeBase64, {
    bool updateDetails = true,
  }) async {
    final manifest = _validateAndroidFileManifest(manifestJson);
    final db = await _ensureAndroidDbStore();
    await _validateAndroidGroupFileManifestIfNeeded(
      manifestJson,
      senderContact,
      db,
    );
    await db.upsertInboundFileManifest(
      transferId: manifest.transferId,
      messageEnvelopeId: payload.envelopeId,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: payload.createdAtUnixMs,
      messageCounter: payload.messageCounter,
      filename: manifest.filename,
      mime: manifest.mime,
      totalSize: manifest.totalSize,
      chunkSize: manifest.chunkSize,
      chunkCount: manifest.chunkCount,
      fileSha256: manifest.fileSha256,
      manifestEnvelopeId: payload.envelopeId,
      manifestEnvelopeBase64: normalizedEnvelopeBase64,
      manifestJson: jsonEncode(manifestJson),
    );
    final completed = await _tryCompleteAndroidFileTransfer(
      manifest.transferId,
      senderContact,
      updateDetails: updateDetails,
    );
    if (completed != null) return completed;
    final received = await db.getReceivedFileChunkCount(manifest.transferId);
    final partial = _partialAndroidFileTransferMessage(
      payload,
      senderContact,
      _androidReceivingFileProgressText(
        filename: manifest.filename,
        totalSize: manifest.totalSize,
        received: received,
        total: manifest.chunkCount,
      ),
    );
    if (mounted && updateDetails) {
      setState(() => _details = partial.text);
    }
    return _AndroidEnvelopeImportResult(message: partial, duplicate: false);
  }

  _AndroidFileManifest _validateAndroidFileManifest(
    Map<String, Object?> manifestJson, {
    String expectedKind = 'file_manifest',
    int? maxBytes = _androidOnlineFileMaxBytes,
    int maxChunkSize = _androidOnlineFileChunkBytes,
  }) {
    final kind = manifestJson['kind']?.toString() ?? '';
    if (kind != expectedKind) {
      throw AndroidInvalidEnvelopePayloadException('文件 manifest 类型无效：$kind');
    }
    final transferId = _requiredAndroidTransferString(
      manifestJson,
      'transfer_id',
    );
    final filename = _requiredAndroidTransferString(manifestJson, 'filename');
    final mime = _requiredAndroidTransferString(manifestJson, 'mime');
    final totalSize = _requiredAndroidTransferInt(manifestJson, 'total_size');
    final chunkSize = _requiredAndroidTransferInt(manifestJson, 'chunk_size');
    final chunkCount = _requiredAndroidTransferInt(manifestJson, 'chunk_count');
    final fileSha256 = _requiredAndroidTransferString(
      manifestJson,
      'file_sha256',
    );
    final chunkHashesValue = manifestJson['chunk_sha256'];
    if (chunkHashesValue is! List) {
      throw const AndroidInvalidEnvelopePayloadException(
        '文件 manifest 缺少 chunk_sha256。',
      );
    }
    final chunkHashes = chunkHashesValue
        .map((item) => item.toString())
        .toList();
    if (totalSize < 0 || (maxBytes != null && totalSize > maxBytes)) {
      throw AndroidInvalidEnvelopePayloadException(
        maxBytes == null
            ? '文件大小无效：${_formatByteCount(totalSize)}'
            : '在线文件大小超出上限：${_formatByteCount(totalSize)} > '
                  '${_formatByteCount(maxBytes)}',
      );
    }
    if (chunkSize <= 0 || chunkSize > maxChunkSize) {
      throw AndroidInvalidEnvelopePayloadException(
        '文件 chunk_size 无效：$chunkSize',
      );
    }
    if (chunkCount <= 0 || chunkHashes.length != chunkCount) {
      throw AndroidInvalidEnvelopePayloadException(
        '文件 chunk_count 无效：$chunkCount / ${chunkHashes.length}',
      );
    }
    return _AndroidFileManifest(
      transferId: transferId,
      filename: filename,
      mime: mime,
      totalSize: totalSize,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      fileSha256: fileSha256,
      chunkSha256: chunkHashes,
    );
  }

  Future<_AndroidEnvelopeImportResult?> _tryCompleteAndroidFileTransfer(
    String transferId,
    AndroidContactRecord senderContact, {
    bool updateDetails = true,
  }) async {
    final db = await _ensureAndroidDbStore();
    final transfer = await db.getFileTransfer(transferId);
    if (transfer == null) return null;
    final manifestJsonText = transfer['manifest_json']?.toString() ?? '';
    if (manifestJsonText.isEmpty) return null;
    final manifestJson = (jsonDecode(manifestJsonText) as Map)
        .cast<String, Object?>();
    final manifest = _validateAndroidFileManifest(manifestJson);
    final groupConversationId = await _validateAndroidGroupFileManifestIfNeeded(
      manifestJson,
      senderContact,
      db,
    );
    final chunks = await db.getFileTransferChunks(transferId);
    if (chunks.length < manifest.chunkCount) return null;

    final chunksByIndex = <int, Map<String, Object?>>{
      for (final chunk in chunks)
        ((chunk['chunk_index'] as num?)?.toInt() ?? -1): chunk,
    };
    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < manifest.chunkCount; index += 1) {
      final chunk = chunksByIndex[index];
      final dataBase64 = chunk?['chunk_data_b64']?.toString() ?? '';
      if (chunk == null || dataBase64.isEmpty) return null;
      final bytes = base64Url.decode(base64Url.normalize(dataBase64));
      final expectedHash = manifest.chunkSha256[index];
      if (_sha256Base64Url(bytes) != expectedHash) {
        throw AndroidInvalidEnvelopePayloadException(
          '文件分片 $index SHA-256 校验失败。',
        );
      }
      builder.add(bytes);
    }
    final fileBytes = builder.takeBytes();
    if (fileBytes.length != manifest.totalSize) {
      throw AndroidInvalidEnvelopePayloadException(
        '文件大小校验失败：${fileBytes.length} != ${manifest.totalSize}',
      );
    }
    if (_sha256Base64Url(fileBytes) != manifest.fileSha256) {
      throw const AndroidInvalidEnvelopePayloadException('文件整体 SHA-256 校验失败。');
    }

    final messageEnvelopeId =
        transfer['message_envelope_id']?.toString() ??
        transfer['manifest_envelope_id']?.toString() ??
        transferId;
    final conversationId = groupConversationId ?? messageEnvelopeId;
    final existing = await db.getMessage(messageEnvelopeId);
    if (existing != null) {
      await db.updateFileTransferStatus(
        transferId: transferId,
        status: AndroidDeliveryStatus.received,
        savedPath: transfer['saved_path']?.toString(),
      );
      await _refreshAndroidChatStore();
      return _AndroidEnvelopeImportResult(message: existing, duplicate: true);
    }

    final savedFile = await _secureStore.saveReceivedFile(
      name: _safeAndroidReceivedFileName(manifest.filename, manifest.mime),
      mime: manifest.mime,
      bytes: fileBytes,
    );
    final savedPath = savedFile.displayPath.trim().isNotEmpty
        ? savedFile.displayPath.trim()
        : savedFile.uri;
    final receivedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
    final message = AndroidMessageRecord(
      envelopeId: messageEnvelopeId,
      conversationId: conversationId,
      direction: 'incoming',
      isRead: false,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: receivedAtUnixMs,
      messageCounter: (transfer['message_counter'] as num?)?.toInt() ?? 0,
      text: [
        '文件：${manifest.filename} (${_formatByteCount(manifest.totalSize)})',
        savedPath,
      ].join('\n'),
      opaqueEnvelopeBase64: '',
      attachmentUri: savedFile.uri,
      attachmentPath: savedPath,
      attachmentMime: savedFile.mime,
    );
    final inserted = await db.addMessage(
      message,
      recipientIdentityKeyId: _requireAndroidIdentity().keyId,
      createRelayResult: true,
    );
    final savedMessage = inserted
        ? message
        : (await db.getMessage(message.envelopeId)) ?? message;
    await db.updateFileTransferStatus(
      transferId: transferId,
      status: AndroidDeliveryStatus.received,
      savedPath: savedPath,
    );
    await db.clearInboundFileChunkData(transferId);
    await _refreshAndroidChatStore();
    if (mounted && updateDetails) {
      setState(() {
        _details = [
          inserted ? '文件分片已接收并重组。' : '重复文件分片已忽略。',
          'sender: ${_contactTitle(senderContact)} / ${senderContact.keyId}',
          savedMessage.text,
        ].join('\n');
      });
    }
    return _AndroidEnvelopeImportResult(
      message: savedMessage,
      duplicate: !inserted,
    );
  }

  AndroidMessageRecord _partialAndroidFileTransferMessage(
    NativeInboundOpaquePayload payload,
    AndroidContactRecord senderContact,
    String text,
  ) {
    return AndroidMessageRecord(
      envelopeId: payload.envelopeId,
      conversationId: payload.conversationId,
      direction: 'incoming',
      isRead: false,
      peerKeyId: senderContact.keyId,
      peerDisplayName: _contactTitle(senderContact),
      createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
      messageCounter: payload.messageCounter,
      text: text,
      opaqueEnvelopeBase64: '',
    );
  }

  Future<String?> _validateAndroidGroupFileManifestIfNeeded(
    Map<String, Object?> manifestJson,
    AndroidContactRecord senderContact,
    AndroidDbStore db,
  ) async {
    final groupId =
        (manifestJson['group_id']?.toString() ??
                manifestJson['conversation_id']?.toString() ??
                '')
            .trim();
    if (groupId.isEmpty || !groupId.startsWith('grp-')) {
      return null;
    }
    final group = await db.getGroup(groupId);
    if (group == null || !group.isActive) {
      throw AndroidMailboxMissingPrerequisiteException('群文件所属群组不可用：$groupId');
    }
    final identity = _requireAndroidIdentity();
    final members = await db.getGroupMembers(groupId: groupId);
    AndroidGroupMemberRecord? self;
    AndroidGroupMemberRecord? sender;
    for (final member in members) {
      if (member.keyId == identity.keyId) self = member;
      if (member.keyId == senderContact.keyId) sender = member;
    }
    if (self == null || !self.isActive) {
      throw const AndroidInvalidEnvelopePayloadException(
        '本机身份不是该群活跃成员，拒绝导入群文件。',
      );
    }
    if (sender == null || !sender.isActive) {
      throw const AndroidInvalidEnvelopePayloadException(
        '发送方不是该群活跃成员，拒绝导入群文件。',
      );
    }
    if (group.policy == AndroidGroupPolicy.verified &&
        !sender.isLocallyTrusted) {
      throw const AndroidInvalidEnvelopePayloadException(
        '发送方尚未通过本机 fingerprint 验证，拒绝导入群文件。',
      );
    }
    return groupId;
  }

  String _safeAndroidReceivedFileName(String filename, String mime) {
    var name = filename.trim().isEmpty ? 'file' : filename.trim();
    name = name
        .replaceAll('\\', '_')
        .replaceAll('/', '_')
        .replaceAll(RegExp(r'[\x00-\x1f]'), '_');
    if (!p.basename(name).contains('.') &&
        _androidFileExtensionForMime(mime).isNotEmpty) {
      name = '$name${_androidFileExtensionForMime(mime)}';
    }
    return name;
  }

  String _requiredAndroidTransferString(
    Map<String, Object?> value,
    String field,
  ) {
    final text = value[field]?.toString() ?? '';
    if (text.trim().isEmpty) {
      throw AndroidInvalidEnvelopePayloadException('文件分片载荷缺少 $field。');
    }
    return text;
  }

  int _requiredAndroidTransferInt(Map<String, Object?> value, String field) {
    final raw = value[field];
    if (raw is num) return raw.toInt();
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed == null) {
      throw AndroidInvalidEnvelopePayloadException('文件分片载荷缺少 $field。');
    }
    return parsed;
  }

  Future<Object?> _handleAdbBridgeCall(MethodCall call) async {
    if (call.method != 'handleCommand') {
      throw MissingPluginException('Unknown ADB bridge method: ${call.method}');
    }
    final args =
        (call.arguments as Map?)?.cast<Object?, Object?>() ??
        const <Object?, Object?>{};
    final command = args['command']?.toString() ?? '';

    try {
      final value = await _runAdbBridgeCommand(command, args);
      final encoded = _encodeAdbBridgeResponse({
        'ok': true,
        'command': command,
        'request_id': args['request_id']?.toString() ?? '',
        'value': value,
      });
      debugPrint('ENVELOPE_ADB_RESULT_BYTES ${encoded.length}');
      return encoded;
    } catch (error) {
      final encoded = _encodeAdbBridgeResponse({
        'ok': false,
        'command': command,
        'request_id': args['request_id']?.toString() ?? '',
        'error': error.toString(),
      });
      debugPrint('ENVELOPE_ADB_RESULT_BYTES ${encoded.length}');
      return encoded;
    }
  }

  Future<Object?> _runAdbBridgeCommand(
    String command,
    Map<Object?, Object?> args,
  ) async {
    switch (command) {
      case 'createIdentity':
        return _adbCreateIdentity(args['display_name']?.toString());
      case 'exportContact':
        return _adbExportContact();
      case 'importContact':
        return _adbImportContact(_decodeAdbPayload(args));
      case 'deleteContact':
        return _adbDeleteContact(args['recipient_key_id']?.toString());
      case 'exportIntroBundle':
        return _adbExportIntroBundle();
      case 'importIntroBundle':
        return _adbImportIntroBundle(_decodeAdbPayload(args));
      case 'sendText':
        final text = args['text']?.toString();
        return _adbSendText(
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
          recipientKeyId: args['recipient_key_id']?.toString(),
        );
      case 'writeTestFile':
        return _adbWriteTestFile(
          name: args['name']?.toString(),
          payloadBase64: args['payload_base64']?.toString(),
          text: args['text']?.toString(),
        );
      case 'p2pStart':
        return _adbP2pStart();
      case 'p2pRefresh':
        return _adbP2pRefresh();
      case 'p2pStop':
        return _adbP2pStop();
      case 'p2pStatus':
        return _adbP2pStatus();
      case 'p2pSendText':
        final text = args['text']?.toString();
        return _adbP2pSendText(
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
          recipientKeyId: args['recipient_key_id']?.toString(),
          serverUrl: args['server_url']?.toString(),
        );
      case 'p2pSendFile':
        return _adbP2pSendFile(
          path: args['path']?.toString(),
          name: args['name']?.toString(),
          mime: args['mime']?.toString(),
          recipientKeyId: args['recipient_key_id']?.toString(),
          serverUrl: args['server_url']?.toString(),
        );
      case 'serverRegister':
        return _adbServerRegister(args['server_url']?.toString());
      case 'serverPullMailbox':
        return _adbServerPullMailbox(args['server_url']?.toString());
      case 'serverSendText':
        final text = args['text']?.toString();
        return _adbServerSendText(
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
          recipientKeyId: args['recipient_key_id']?.toString(),
          serverUrl: args['server_url']?.toString(),
        );
      case 'serverSendFile':
        return _adbP2pSendFile(
          path: args['path']?.toString(),
          name: args['name']?.toString(),
          mime: args['mime']?.toString(),
          recipientKeyId: args['recipient_key_id']?.toString(),
          serverUrl: args['server_url']?.toString(),
        );
      case 'p2pLoopbackTest':
        final text = args['text']?.toString();
        return _adbP2pLoopbackTest(
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
        );
      case 'retryPending':
        return _adbRetryPending(args['server_url']?.toString());
      case 'exportOfflineEnvelope':
        return _adbExportOfflineEnvelope(args['envelope_id']?.toString());
      case 'sealText':
        final text = args['text']?.toString();
        return _adbSealText(
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
          recipientKeyId: args['recipient_key_id']?.toString(),
        );
      case 'sealFile':
        return _adbSealFile(
          path: args['path']?.toString(),
          name: args['name']?.toString(),
          mime: args['mime']?.toString(),
          recipientKeyId: args['recipient_key_id']?.toString(),
        );
      case 'importOfflineEnvelope':
        return _adbImportOfflineEnvelope(_decodeAdbPayload(args));
      case 'importOfflineEnvelopeFile':
        return _adbImportOfflineEnvelopeFile(args['path']?.toString());
      case 'importOfflineEnvelopeFromClipboard':
        return _adbImportOfflineEnvelopeFromClipboard();
      case 'createGroup':
        return _adbCreateGroup(
          name: args['name']?.toString(),
          policy: args['policy']?.toString(),
          memberKeyIds: args['member_key_ids']?.toString(),
        );
      case 'acceptGroup':
        return _adbAcceptGroup(args['group_id']?.toString());
      case 'declineGroup':
        return _adbDeclineGroup(args['group_id']?.toString());
      case 'leaveGroup':
        return _adbLeaveGroup(args['group_id']?.toString());
      case 'renameGroup':
        return _adbRenameGroup(
          groupId: args['group_id']?.toString(),
          name: args['name']?.toString(),
        );
      case 'updateGroupAvatar':
        return _adbUpdateGroupAvatar(
          groupId: args['group_id']?.toString(),
          avatarSeed: args['avatar_seed']?.toString(),
        );
      case 'verifyGroupMember':
      case 'endorseGroupMember':
        return _adbVerifyGroupMember(
          groupId: args['group_id']?.toString(),
          memberKeyId: args['member_key_id']?.toString(),
        );
      case 'groupSendText':
        final text = args['text']?.toString();
        return _adbGroupSendText(
          groupId: args['group_id']?.toString(),
          text: text == null || text.isEmpty ? _decodeAdbPayload(args) : text,
        );
      case 'groupSendFile':
        return _adbGroupSendFile(
          groupId: args['group_id']?.toString(),
          path: args['path']?.toString(),
          name: args['name']?.toString(),
          mime: args['mime']?.toString(),
          serverUrl: args['server_url']?.toString(),
        );
      case 'integrationSelfTest':
        return _adbIntegrationSelfTest();
      case 'readStore':
        return _adbReadStore();
      case 'clearChatStore':
        await _clearAndroidChatStorage();
        return {'cleared': true};
      default:
        throw SecureStoreException('unknown ADB command: $command');
    }
  }

  Future<Map<String, Object?>> _adbCreateIdentity(String? displayName) async {
    final phrase = _nativeCore.generateRecoveryPhrase();
    final summary = _nativeCore.recoverIdentity(
      displayName: (displayName == null || displayName.trim().isEmpty)
          ? _currentDisplayName
          : displayName.trim(),
      recoveryPhrase: phrase,
    );
    final record = await _secureStore.writeIdentity(summary.identityJson);
    await _clearAndroidChatStorage(refresh: false);
    if (mounted) {
      setState(() {
        _secureIdentityReady = true;
        _secureIdentity = record;
        _secureIdentityLabel = record.label;
        _androidChatStore = AndroidChatStore.empty();
        _androidMessageLimitsByContact.clear();
        _androidMessageLimitsByGroup.clear();
        _androidIncomingMessageCounts = const <String, int>{};
        _androidIncomingConversationCounts = const <String, int>{};
        _androidMessageCount = 0;
        _androidPendingCount = 0;
        _selectedAndroidContactKeyId = null;
        _selectedAndroidGroupId = null;
        _androidMessageSelectionMode = false;
        _selectedAndroidMessageIds.clear();
        _details = 'ADB debug: identity created for ${record.label}';
      });
    }
    return {
      'display_name': record.displayName,
      'key_id': record.keyId,
      'contact_json': summary.contactJson,
    };
  }

  Future<Map<String, Object?>> _adbExportContact() async {
    await _refreshSecureIdentity();
    final identity = _requireAndroidIdentity();
    final contactJson = _nativeCore.contactFromIdentityJson(
      identity.identityJson,
    );
    final parsed = _nativeCore.parseContact(contactJson);
    return {
      'display_name': parsed.displayName,
      'key_id': parsed.keyId,
      'contact_json': parsed.contactJson,
    };
  }

  Future<Map<String, Object?>> _adbImportContact(String contactJson) async {
    await _refreshAndroidChatStore();
    await _saveAndroidContactJson(contactJson);
    final parsed = _nativeCore.parseContact(contactJson);
    return {
      'display_name': parsed.displayName,
      'key_id': parsed.keyId,
      'contacts': _androidChatStore.contacts.length,
    };
  }

  Future<Map<String, Object?>> _adbDeleteContact(String? recipientKeyId) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final contact = _adbRequiredContact(recipientKeyId);
    final result = await _deleteAndroidContact(contact);
    return {...result, 'contacts': _androidChatStore.contacts.length};
  }

  Future<Map<String, Object?>> _adbExportIntroBundle() async {
    await _refreshSecureIdentity();
    final bundle = await _createAndroidIntroBundle();
    return {
      'display_name': bundle.displayName,
      'key_id': bundle.keyId,
      'device_id': bundle.deviceId,
      'p2p_ticket': bundle.p2pTicket,
      'bundle_json': bundle.bundleJson,
    };
  }

  Future<Map<String, Object?>> _adbImportIntroBundle(String bundleJson) async {
    await _refreshAndroidChatStore();
    final intro = _nativeCore.verifyIntroBundle(bundleJson);
    await _saveAndroidIntroBundle(intro);
    return {
      'display_name': intro.displayName,
      'key_id': intro.keyId,
      'device_id': intro.deviceId,
      'p2p_ticket': intro.p2pTicket,
      'contacts': _androidChatStore.contacts.length,
    };
  }

  Future<Map<String, Object?>> _adbSendText({
    required String text,
    required String? recipientKeyId,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    if (text.trim().isEmpty) {
      throw const SecureStoreException('ADB sendText requires text.');
    }
    final contact = recipientKeyId == null || recipientKeyId.trim().isEmpty
        ? (_androidChatStore.contacts.isEmpty
              ? null
              : _androidChatStore.contacts.first)
        : _androidChatStore.findContact(recipientKeyId.trim());
    if (contact == null) {
      throw SecureStoreException(
        'ADB sendText unknown recipient: ${recipientKeyId ?? ''}',
      );
    }
    final message = await _saveOutgoingAndroidText(
      contact: contact,
      text: text.trim(),
    );
    return _messageToAdbJson(message);
  }

  Future<Map<String, Object?>> _adbWriteTestFile({
    required String? name,
    required String? payloadBase64,
    required String? text,
  }) async {
    final rawName = name?.trim() ?? '';
    final safeName = rawName.isEmpty
        ? 'envelope-e2e-${DateTime.now().millisecondsSinceEpoch}.bin'
        : rawName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final bytes = payloadBase64 == null || payloadBase64.trim().isEmpty
        ? Uint8List.fromList(utf8.encode(text ?? ''))
        : base64Decode(payloadBase64.trim());
    final dir = Directory(p.join(Directory.systemTemp.path, 'envelope-e2e'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    final stat = await file.stat();
    return {'path': file.absolute.path, 'name': safeName, 'size': stat.size};
  }

  Future<Map<String, Object?>> _adbP2pStart() async {
    await _refreshSecureIdentity();
    final status = await _ensureAndroidP2pListening();
    return status.toJson();
  }

  Future<Map<String, Object?>> _adbP2pRefresh() async {
    await _refreshSecureIdentity();
    final status = await _restartAndroidP2pListening();
    return status.toJson();
  }

  Future<Map<String, Object?>> _adbP2pStop() async {
    await _androidP2p.stop();
    if (mounted) {
      setState(() {
        _androidP2pListening = false;
        _androidP2pTicket = null;
        _androidP2pAddrs = const [];
        _androidP2pPort = null;
        _details = 'ADB P2P stopped';
      });
    }
    return {'stopped': true};
  }

  Future<Map<String, Object?>> _adbP2pStatus() async {
    final status = _androidP2p.status;
    return {
      'listening': _androidP2pListening,
      'ticket': _androidP2pTicket,
      'addrs': _androidP2pAddrs,
      'port': _androidP2pPort,
      'ticket_state': _p2pTicketDebugJson(_androidP2pTicket),
      if (status != null) 'expires_at_unix_ms': status.expiresAtUnixMs,
    };
  }

  Future<Map<String, Object?>> _adbP2pSendText({
    required String text,
    required String? recipientKeyId,
    String? serverUrl,
  }) async {
    return _sendAndroidP2pText(
      text: text,
      recipientKeyId: recipientKeyId,
      serverUrl: serverUrl,
    );
  }

  AndroidContactRecord _adbRequiredContact(String? recipientKeyId) {
    final keyId = recipientKeyId?.trim() ?? '';
    final contact = keyId.isEmpty
        ? (_androidChatStore.contacts.isEmpty
              ? null
              : _androidChatStore.contacts.first)
        : _androidChatStore.findContact(keyId);
    if (contact == null) {
      throw SecureStoreException(
        'ADB command unknown recipient: ${recipientKeyId ?? ''}',
      );
    }
    return contact;
  }

  Future<Map<String, Object?>> _adbP2pSendFile({
    required String? path,
    required String? name,
    required String? mime,
    required String? recipientKeyId,
    String? serverUrl,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final file = await _androidPickedFileFromDevicePath(
      path: path,
      name: name,
      mime: mime,
    );
    return _sendAndroidP2pFile(
      file: file,
      recipientKeyId: recipientKeyId,
      serverUrl: serverUrl,
    );
  }

  Map<String, Object?> _sealResultToAdbJson(_AndroidSealResult result) {
    return {
      'label': result.label,
      'path': result.path,
      'envelope_id': result.record.envelopeId,
      'kind': result.record.kind,
      'recipient_key_id': result.record.recipientKeyId,
      'recipient_display_name': result.record.recipientDisplayName,
      'created_at_unix_ms': result.record.createdAtUnixMs,
      'payload_size': result.record.payloadSize,
      'envelope_size': result.record.envelopeSize,
      'source_name': result.record.sourceName,
      'details': result.details,
    };
  }

  Future<Map<String, Object?>> _adbSealText({
    required String text,
    required String? recipientKeyId,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final contact = _adbRequiredContact(recipientKeyId);
    final result = await _createAndroidTextSealResult(contact, text);
    await _refreshAndroidChatStore();
    return _sealResultToAdbJson(result);
  }

  Future<Map<String, Object?>> _adbSealFile({
    required String? path,
    required String? name,
    required String? mime,
    required String? recipientKeyId,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final contact = _adbRequiredContact(recipientKeyId);
    final file = await _androidPickedFileFromDevicePath(
      path: path,
      name: name,
      mime: mime,
    );
    final result = await _createAndroidFileSealResultForPickedFile(
      contact,
      file,
    );
    await _refreshAndroidChatStore();
    return _sealResultToAdbJson(result);
  }

  Future<Map<String, Object?>> _adbServerRegister(String? serverUrl) async {
    final response = await _registerAndroidServerEndpoint(serverUrl: serverUrl);
    return {
      'owner_key_id': response.ownerKeyId,
      'device_id': response.deviceId,
      'expires_at_unix_ms': response.expiresAtUnixMs,
      'server_url': _serverUrl(serverUrl),
    };
  }

  Future<Map<String, Object?>> _adbServerPullMailbox(String? serverUrl) {
    return _pullAndroidServerMailbox(serverUrl: serverUrl);
  }

  Future<Map<String, Object?>> _adbServerSendText({
    required String text,
    required String? recipientKeyId,
    required String? serverUrl,
  }) {
    return _sendAndroidP2pText(
      text: text,
      recipientKeyId: recipientKeyId,
      serverUrl: serverUrl,
    );
  }

  Future<Map<String, Object?>> _adbP2pLoopbackTest({
    required String text,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final status = await _ensureAndroidP2pListening();
    final bundle = await _createAndroidIntroBundle();
    await _saveAndroidIntroBundle(bundle);
    final result = await _sendAndroidP2pText(
      text: text,
      recipientKeyId: bundle.keyId,
      useServerFallback: false,
    );
    await _refreshAndroidChatStore();
    final messagesForSelf = _androidChatStore.messages
        .where((message) => message.peerKeyId == bundle.keyId)
        .map((message) => _messageToAdbJson(message, includeEnvelope: false))
        .toList();
    return {
      'listener': status.toJson(),
      'self_contact': {
        'key_id': bundle.keyId,
        'display_name': bundle.displayName,
        'device_id': bundle.deviceId,
        'p2p_ticket': bundle.p2pTicket,
      },
      'send_result': result,
      'messages_for_self': messagesForSelf,
      'contacts': _androidChatStore.contacts.length,
      'messages': _androidChatStore.messages.length,
    };
  }

  Future<Map<String, Object?>> _adbRetryPending(String? serverUrl) async {
    return _retryAndroidPendingMessages(serverUrl: serverUrl);
  }

  Future<Map<String, Object?>> _adbExportOfflineEnvelope(
    String? envelopeId,
  ) async {
    final result = await _exportAndroidOfflineEnvelope(envelopeId: envelopeId);
    return {
      'envelope_id': result['envelope_id'],
      'delivery_status': result['delivery_status'],
      'bytes': result['bytes'],
      'path': result['path'],
      'copied_to_clipboard': true,
    };
  }

  Future<Map<String, Object?>> _adbImportOfflineEnvelope(
    String envelopeBase64,
  ) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final importResult = await _importAndroidOpaqueEnvelopeBase64(
      envelopeBase64,
      updateDetails: false,
    );
    return {
      ..._messageToAdbJson(importResult.message),
      'duplicate': importResult.duplicate,
    };
  }

  Future<Map<String, Object?>> _adbImportOfflineEnvelopeFile(
    String? path,
  ) async {
    if (path == null || path.trim().isEmpty) {
      throw const SecureStoreException(
        'importOfflineEnvelopeFile requires path.',
      );
    }
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final pickedFile = await _androidPickedFileFromDevicePath(
      path: path,
      mime: 'application/octet-stream',
    );
    if (await _isAndroidOfflineGroupStreamEnvelopeFile(pickedFile)) {
      final importResult = await _importAndroidOfflineGroupStreamEnvelopeFile(
        pickedFile,
      );
      return {
        ..._messageToAdbJson(importResult.message),
        'duplicate': importResult.duplicate,
      };
    }
    if (await _isAndroidOfflineStreamEnvelopeFile(pickedFile)) {
      final importResult = await _importAndroidOfflineStreamEnvelopeFile(
        pickedFile,
      );
      return {
        ..._messageToAdbJson(importResult.message),
        'duplicate': importResult.duplicate,
      };
    }
    final envelopeBytes = await File(path.trim()).readAsBytes();
    final importResult = await _importAndroidOpaqueEnvelopeBytes(
      envelopeBytes,
      updateDetails: false,
    );
    return {
      ..._messageToAdbJson(importResult.message),
      'duplicate': importResult.duplicate,
    };
  }

  Future<Map<String, Object?>> _adbImportOfflineEnvelopeFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final envelopeBase64 = data?.text?.trim() ?? '';
    if (envelopeBase64.isEmpty) {
      throw const SecureStoreException('剪贴板里没有离线信封 base64。');
    }
    return _adbImportOfflineEnvelope(envelopeBase64);
  }

  List<String> _adbParseKeyIds(String? value) {
    return (value ?? '')
        .split(RegExp(r'[,;\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  Future<AndroidGroupRecord> _adbRequiredGroup(String? groupId) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final normalizedGroupId = groupId?.trim() ?? '';
    final group = normalizedGroupId.isEmpty
        ? (_androidChatStore.groups.isEmpty
              ? null
              : _androidChatStore.groups.first)
        : _androidChatStore.findGroup(normalizedGroupId);
    if (group == null) {
      throw SecureStoreException('ADB command unknown group: ${groupId ?? ''}');
    }
    return group;
  }

  Future<Map<String, Object?>> _adbGroupSnapshot(String groupId) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final db = await _ensureAndroidDbStore();
    final group = await db.getGroup(groupId);
    if (group == null) {
      throw SecureStoreException('ADB command unknown group: $groupId');
    }
    final members = await db.getGroupMembers(groupId: groupId);
    final messages = await db.getMessages(conversationId: groupId);
    final events = await db.getGroupEvents(groupId: groupId);
    return {
      'group': _groupToAdbJson(group),
      'members': members.map(_groupMemberToAdbJson).toList(),
      'messages': messages
          .map((message) => _messageToAdbJson(message, includeEnvelope: false))
          .toList(),
      'events': events
          .map(
            (event) => {
              'event_id': event.eventId,
              'group_id': event.groupId,
              'epoch': event.epoch,
              'type': event.type,
              'actor_key_id': event.actorKeyId,
              'created_at_unix_ms': event.createdAtUnixMs,
              'signature': event.signature,
            },
          )
          .toList(),
    };
  }

  Future<Map<String, Object?>> _adbCreateGroup({
    required String? name,
    required String? policy,
    required String? memberKeyIds,
  }) async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final requestedIds = _adbParseKeyIds(memberKeyIds);
    final invitees = requestedIds.isEmpty
        ? _androidChatStore.contacts
        : requestedIds
              .map((keyId) {
                final contact = _androidChatStore.findContact(keyId);
                if (contact == null) {
                  throw SecureStoreException(
                    'ADB createGroup unknown contact: $keyId',
                  );
                }
                return contact;
              })
              .toList(growable: false);
    if (invitees.isEmpty) {
      throw const SecureStoreException('ADB createGroup requires invitees.');
    }
    final normalizedPolicy = AndroidGroupPolicy.normalize(policy ?? '');
    final group = await _createAndroidGroup(
      name: (name == null || name.trim().isEmpty)
          ? 'ADB $normalizedPolicy ${DateTime.now().millisecondsSinceEpoch}'
          : name.trim(),
      policy: normalizedPolicy,
      invitees: invitees,
    );
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbAcceptGroup(String? groupId) async {
    final group = await _adbRequiredGroup(groupId);
    await _acceptAndroidGroupInvite(group);
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbDeclineGroup(String? groupId) async {
    final group = await _adbRequiredGroup(groupId);
    await _declineAndroidGroupInvite(group);
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbLeaveGroup(String? groupId) async {
    final group = await _adbRequiredGroup(groupId);
    await _leaveAndroidGroup(group);
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbRenameGroup({
    required String? groupId,
    required String? name,
  }) async {
    final group = await _adbRequiredGroup(groupId);
    await _renameAndroidGroup(group: group, name: name ?? '');
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbUpdateGroupAvatar({
    required String? groupId,
    required String? avatarSeed,
  }) async {
    final group = await _adbRequiredGroup(groupId);
    await _updateAndroidGroupAvatar(group: group, avatarSeed: avatarSeed ?? '');
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbVerifyGroupMember({
    required String? groupId,
    required String? memberKeyId,
  }) async {
    final group = await _adbRequiredGroup(groupId);
    final normalizedMemberKeyId = memberKeyId?.trim() ?? '';
    if (normalizedMemberKeyId.isEmpty) {
      throw const SecureStoreException(
        'ADB verifyGroupMember requires member_key_id.',
      );
    }
    final db = await _ensureAndroidDbStore();
    final member = await db.getGroupMember(
      groupId: group.groupId,
      keyId: normalizedMemberKeyId,
    );
    if (member == null) {
      throw SecureStoreException(
        'ADB verifyGroupMember unknown member: $normalizedMemberKeyId',
      );
    }
    await _verifyAndroidGroupMember(group: group, member: member);
    return _adbGroupSnapshot(group.groupId);
  }

  Future<Map<String, Object?>> _adbGroupSendText({
    required String? groupId,
    required String text,
  }) async {
    final group = await _adbRequiredGroup(groupId);
    final message = await _sendAndroidGroupText(group: group, text: text);
    return {
      'message': _messageToAdbJson(message, includeEnvelope: false),
      'snapshot': await _adbGroupSnapshot(group.groupId),
    };
  }

  Future<Map<String, Object?>> _adbGroupSendFile({
    required String? groupId,
    required String? path,
    required String? name,
    required String? mime,
    required String? serverUrl,
  }) async {
    final group = await _adbRequiredGroup(groupId);
    final file = await _androidPickedFileFromDevicePath(
      path: path,
      name: name,
      mime: mime,
    );
    final message = await _sendAndroidGroupFile(
      group: group,
      file: file,
      serverUrl: serverUrl,
    );
    return {
      'message': _messageToAdbJson(message, includeEnvelope: false),
      'snapshot': await _adbGroupSnapshot(group.groupId),
    };
  }

  Future<Map<String, Object?>> _adbIntegrationSelfTest() async {
    await _refreshSecureIdentity();
    await _clearAndroidChatStorage();

    final startStatus = await _ensureAndroidP2pListening();
    final selfBundle = await _createAndroidIntroBundle();
    await _saveAndroidIntroBundle(selfBundle);

    final first = await _sendAndroidP2pText(
      text: '集成测试1：P2P 成功投递。',
      recipientKeyId: selfBundle.keyId,
      useServerFallback: false,
    );
    final firstAck = (first['ack'] as Map).cast<String, Object?>();
    final firstMessage = (first['message'] as Map).cast<String, Object?>();

    await _androidP2p.stop();
    if (mounted) {
      setState(() {
        _androidP2pListening = false;
        _androidP2pTicket = null;
        _androidP2pAddrs = const [];
        _androidP2pPort = null;
      });
    }

    final pending = await _sendAndroidP2pText(
      text: '集成测试2：故意进入 pending。',
      recipientKeyId: selfBundle.keyId,
      useServerFallback: false,
    );
    final pendingAck = (pending['ack'] as Map).cast<String, Object?>();
    final pendingMessage = (pending['message'] as Map).cast<String, Object?>();
    await _refreshAndroidChatStore();
    final db = await _ensureAndroidDbStore();
    final pendingAfterFailure = await db.getPendingMessageCount();

    final offlineEnvelope = await _exportAndroidOfflineEnvelope(
      envelopeId: pendingMessage['envelope_id']?.toString(),
    );
    final offlineEnvelopeImported = await _adbImportOfflineEnvelopeFile(
      offlineEnvelope['path']?.toString(),
    );

    final refreshedBundle = await _createAndroidIntroBundle();
    await _saveAndroidIntroBundle(refreshedBundle);
    final third = await _sendAndroidP2pText(
      text: '集成测试3：刷新直连状态后再次成功。',
      recipientKeyId: refreshedBundle.keyId,
      useServerFallback: false,
    );
    final thirdAck = (third['ack'] as Map).cast<String, Object?>();

    final retry = await _retryAndroidPendingMessages();
    await _refreshAndroidChatStore();
    final finalMessages = await db.getMessages();
    final finalPendingCount = await db.getPendingMessageCount();

    return {
      'p2p_listener': {'addrs': startStatus.addrs, 'port': startStatus.port},
      'first': {
        'ack': firstAck['status'],
        'delivery': firstMessage['delivery_status'],
      },
      'pending': {
        'ack': pendingAck['status'],
        'delivery': pendingMessage['delivery_status'],
        'count_after_failure': pendingAfterFailure,
      },
      'offline_envelope': {
        'envelope_id': offlineEnvelope['envelope_id'],
        'delivery_status': offlineEnvelope['delivery_status'],
        'path': offlineEnvelope['path'],
        'bytes': offlineEnvelope['bytes'],
        'import_text': offlineEnvelopeImported['text'],
      },
      'third': {'ack': thirdAck['status']},
      'retry': {
        'attempted': retry['attempted'],
        'sent': retry['sent'],
        'remaining_pending': retry['remaining_pending'],
      },
      'final': {
        'contacts': _androidChatStore.contacts.length,
        'messages': finalMessages.length,
        'pending': finalPendingCount,
        'sent': finalMessages
            .where(
              (message) =>
                  message.direction == 'outgoing' &&
                  message.deliveryStatus == AndroidDeliveryStatus.sent,
            )
            .length,
      },
    };
  }

  Future<Map<String, Object?>> _adbReadStore() async {
    await _refreshSecureIdentity();
    await _refreshAndroidChatStore();
    final db = await _ensureAndroidDbStore();
    final messages = await db.getMessages();
    final sealedEnvelopes = await db.getSealedEnvelopes();
    final pendingCount = await db.getPendingMessageCount();
    return {
      'identity': _secureIdentity == null
          ? null
          : {
              'display_name': _secureIdentity!.displayName,
              'key_id': _secureIdentity!.keyId,
            },
      'contacts': _androidChatStore.contacts
          .map(
            (contact) => {
              'display_label': contact.displayLabel,
              'display_name': contact.displayName,
              'remark': contact.remark,
              'key_id': contact.keyId,
              'device_id': contact.deviceId,
              'p2p_ticket_state': _p2pTicketDebugJson(contact.p2pTicket),
            },
          )
          .toList(),
      'messages': messages
          .map((message) => _messageToAdbJson(message, includeEnvelope: false))
          .toList(),
      'groups': _androidChatStore.groups.map(_groupToAdbJson).toList(),
      'group_members': _androidChatStore.groupMembers
          .map(_groupMemberToAdbJson)
          .toList(),
      'sealed_envelopes': sealedEnvelopes
          .map((record) => record.toJson())
          .toList(),
      'messages_loaded': _androidChatStore.messages.length,
      'messages_total': messages.length,
      'pending_total': pendingCount,
      'next_message_counter': _androidChatStore.nextMessageCounter,
    };
  }

  Map<String, Object?> _messageToAdbJson(
    AndroidMessageRecord message, {
    bool includeEnvelope = true,
  }) {
    return {
      'envelope_id': message.envelopeId,
      'conversation_id': message.conversationId,
      'direction': message.direction,
      'peer_key_id': message.peerKeyId,
      'peer_display_name': message.peerDisplayName,
      'created_at_unix_ms': message.createdAtUnixMs,
      'message_counter': message.messageCounter,
      'text': message.text,
      'delivery_status': message.deliveryStatus,
      'delivery_detail': message.deliveryDetail,
      'delivery_updated_at_unix_ms': message.deliveryUpdatedAtUnixMs,
      'attachment_uri': message.attachmentUri,
      'attachment_path': message.attachmentPath,
      'attachment_mime': message.attachmentMime,
      if (includeEnvelope) 'opaque_envelope_b64': message.opaqueEnvelopeBase64,
    };
  }

  Map<String, Object?> _groupToAdbJson(AndroidGroupRecord group) {
    return {
      'group_id': group.groupId,
      'name': group.name,
      'display_name': group.displayName,
      'owner_key_id': group.ownerKeyId,
      'policy': group.policy,
      'epoch': group.epoch,
      'created_at_unix_ms': group.createdAtUnixMs,
      'updated_at_unix_ms': group.updatedAtUnixMs,
      'avatar_seed': group.avatarSeed,
      'is_active': group.isActive,
    };
  }

  Map<String, Object?> _groupMemberToAdbJson(AndroidGroupMemberRecord member) {
    return {
      'group_id': member.groupId,
      'key_id': member.keyId,
      'display_name': member.displayName,
      'display_label': member.displayLabel,
      'role': member.role,
      'status': member.status,
      'trust_state': member.trustState,
      'invited_by_key_id': member.invitedByKeyId,
      'joined_at_unix_ms': member.joinedAtUnixMs,
      'updated_at_unix_ms': member.updatedAtUnixMs,
      'has_contact_json': member.contactJson.trim().isNotEmpty,
    };
  }

  String _decodeAdbPayload(Map<Object?, Object?> args) {
    final plain = args['payload']?.toString();
    if (plain != null && plain.isNotEmpty) {
      return plain;
    }
    final encoded = args['payload_base64']?.toString();
    if (encoded == null || encoded.isEmpty) {
      throw const SecureStoreException('ADB command requires payload.');
    }
    return utf8.decode(base64.decode(encoded));
  }

  String _encodeAdbBridgeResponse(Map<String, Object?> response) {
    return base64.encode(utf8.encode(jsonEncode(response)));
  }

  Future<void> _exportContact() => _run('导出联系人', () async {
    await _cli.exportContact(_storeDir, File(_exportPath));
  });

  Future<void> _addContact() => _run('添加联系人', () async {
    await _cli.addContact(_storeDir, File(_contactPath));
    await _refreshStore();
  });

  Future<void> _importEnvelope() => _run('导入离线信封', () async {
    final output = await _cli.importEnvelope(_storeDir, File(_importPath));
    await _refreshStore();
    if (mounted) setState(() => _details = output);
  });

  Future<void> _startP2pServe() async {
    if (_busy || _p2pListening || !_storeReady) return;
    setState(() {
      _busy = true;
      _status = '启动 P2P 监听';
      _details = '';
      _myP2pTicketController.clear();
    });

    try {
      final process = await _cli.startP2pServe(_storeDir);
      _p2pProcess = process;
      _p2pStdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleP2pOutput);
      _p2pStderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _handleP2pOutput(line, isError: true));
      unawaited(_watchP2pExit(process));

      if (!mounted) return;
      setState(() {
        _p2pListening = true;
        _status = 'P2P 正在启动';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'P2P 监听失败';
        _details = error.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopP2pServe() async {
    final process = _p2pProcess;
    if (process == null) return;
    process.kill();
    await _p2pStdoutSubscription?.cancel();
    await _p2pStderrSubscription?.cancel();
    if (!mounted) return;
    setState(() {
      _p2pProcess = null;
      _p2pListening = false;
      _status = _storeReady ? 'store 已打开' : '未打开 store';
    });
  }

  Future<void> _watchP2pExit(Process process) async {
    final exitCode = await process.exitCode;
    if (!mounted || _p2pProcess != process) return;
    setState(() {
      _p2pProcess = null;
      _p2pListening = false;
      _status = 'P2P 监听已停止';
    });
    _appendDetails('P2P 监听进程退出：$exitCode');
  }

  void _handleP2pOutput(String line, {bool isError = false}) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !mounted) return;

    final ticketPrefix = 'p2p ticket: ';
    setState(() {
      if (trimmed.startsWith(ticketPrefix)) {
        _myP2pTicketController.text = trimmed.substring(ticketPrefix.length);
        _status = 'P2P 监听中';
      }
    });
    _appendDetails(isError ? 'P2P ERR: $trimmed' : trimmed);

    if (trimmed.startsWith('imported:') ||
        trimmed.startsWith('duplicate envelope ignored:')) {
      unawaited(_refreshStore());
    }
  }

  void _appendDetails(String line) {
    if (!mounted) return;
    setState(() {
      final lines = [
        ..._details.splitLines().where((item) => item.trim().isNotEmpty),
        line,
      ];
      _details = lines
          .skip(lines.length > 24 ? lines.length - 24 : 0)
          .join('\n');
    });
  }

  Future<void> _copyMyP2pTicket() async {
    final ticket = _myP2pTicketController.text.trim();
    if (ticket.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: ticket));
    if (mounted) setState(() => _status = '直连调试信息已复制');
  }

  void _selectContact(ContactRow contact) {
    setState(() {
      _sendRecipientController.text = contact.keyId;
      _status = '已选择联系人：${contact.name}';
    });
  }

  void _ensureKnownRecipient(String recipient) {
    if (recipient.isEmpty) {
      throw const CliException('请先填写收件人，或点击联系人列表选择一个联系人。');
    }
    final normalized = recipient.toLowerCase();
    final matched = _contacts.any(
      (contact) =>
          contact.keyId.toLowerCase() == normalized ||
          contact.name.toLowerCase() == normalized,
    );
    if (!matched) {
      throw const CliException(
        '本地 store 没有这个收件人。请先添加对方最新的 contact 文件，或点击联系人列表选择。',
      );
    }
  }

  Future<void> _sendP2p() => _run('P2P 发送', () async {
    final recipient = _sendRecipientController.text.trim();
    _ensureKnownRecipient(recipient);
    final output = await _cli.sendP2p(
      _storeDir,
      recipient,
      _sendTextController.text,
      _peerP2pTicketController.text.trim(),
    );
    await _refreshStore();
    if (mounted) setState(() => _details = output);
  });

  Future<void> _exportEnvelope() => _run('导出离线信封', () async {
    final recipient = _sendRecipientController.text.trim();
    _ensureKnownRecipient(recipient);
    final output = await _cli.exportEnvelope(
      _storeDir,
      recipient,
      _sendTextController.text,
      File(_sendOutputPath),
    );
    await _refreshStore();
    if (mounted) setState(() => _details = output);
  });

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return _buildAndroidScaffold(context);
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _SideBar(
              busy: _busy,
              storeReady: _storeReady,
              status: _status,
              storeDirController: _storeDirController,
              displayNameController: _displayNameController,
              exportPathController: _exportPathController,
              contactPathController: _contactPathController,
              importPathController: _importPathController,
              sendRecipientController: _sendRecipientController,
              sendTextController: _sendTextController,
              sendOutputPathController: _sendOutputPathController,
              storeDirHint: _defaultStoreDirPath,
              exportPathHint: _defaultExportPath,
              contactPathHint: _defaultContactPath,
              importPathHint: _defaultImportPath,
              sendOutputPathHint: _defaultSendOutputPath,
              myP2pTicketController: _myP2pTicketController,
              peerP2pTicketController: _peerP2pTicketController,
              p2pListening: _p2pListening,
              nativeReady: _native != null,
              nativeError: _nativeError,
              androidSecureStoreReady: _secureStore.isSupported,
              secureIdentityReady: _secureIdentityReady,
              secureIdentityLabel: _secureIdentityLabel,
              onInitStore: _initStore,
              onResetStore: _resetStore,
              recoveryPhraseController: _recoveryPhraseController,
              onGenerateRecoveryPhrase: _generateRecoveryPhrase,
              onPreviewRecoveredIdentity: _previewRecoveredIdentity,
              onCreateAndSaveAndroidIdentity: _createAndSaveAndroidIdentity,
              onSaveRecoveredAndroidIdentity: _saveRecoveredAndroidIdentity,
              onLoadAndroidIdentity: _loadAndroidIdentity,
              onClearAndroidIdentity: _clearAndroidIdentity,
              onRefresh: _refreshStore,
              onExportContact: _exportContact,
              onAddContact: _addContact,
              onImportEnvelope: _importEnvelope,
              onExportEnvelope: _exportEnvelope,
              onStartP2p: _startP2pServe,
              onStopP2p: _stopP2pServe,
              onCopyP2pTicket: _copyMyP2pTicket,
              onSendP2p: _sendP2p,
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _MainWorkspace(
                busy: _busy,
                details: _details,
                contacts: _contacts,
                messages: _messages,
                onSelectContact: _selectContact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidScaffold(BuildContext context) {
    final l10n = context.l10n;
    if (!_androidLocalLockChecked) {
      return _buildAndroidLocalLockGate(context, loading: true);
    }
    if (_androidLocalLockEnabled && !_androidLocalLockUnlocked) {
      return _buildAndroidLocalLockGate(context);
    }
    final body = switch (_androidHomeTab) {
      _AndroidHomeTab.about => _buildAndroidAboutPage(context),
      _AndroidHomeTab.contacts => _buildAndroidContactsPage(context),
      _AndroidHomeTab.chat => _buildAndroidChatPage(context),
      _AndroidHomeTab.unseal => _buildAndroidUnsealPage(context),
      _AndroidHomeTab.settings => _buildAndroidSettingsPage(context),
    };
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _androidHomeTab.index,
        onDestinationSelected: (index) =>
            _selectAndroidHomeTab(_AndroidHomeTab.values[index]),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.info_outline),
            selectedIcon: const Icon(Icons.info),
            label: l10n.aboutSection,
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_alt_outlined),
            selectedIcon: const Icon(Icons.people_alt),
            label: l10n.contactsTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.forum_outlined),
            selectedIcon: const Icon(Icons.forum),
            label: l10n.chatTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.lock_open_outlined),
            selectedIcon: const Icon(Icons.lock_open),
            label: l10n.unsealTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.settingsTab,
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidLocalLockGate(
    BuildContext context, {
    bool loading = false,
  }) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: const Color(0xfffff7ed),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    child: const Icon(Icons.lock_rounded, size: 34),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    l10n.localLockTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    loading
                        ? l10n.localLockChecking
                        : l10n.localLockDescription,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xff55645f),
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: loading || _androidLocalLockBusy
                        ? null
                        : () => unawaited(
                            _unlockAndroidLocalLock(
                              reason: l10n.localLockUnlockReason,
                            ),
                          ),
                    icon: _androidLocalLockBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_outlined),
                    label: Text(loading ? l10n.localLockChecking : l10n.unlock),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _appDisplayVersion,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xff8a9792),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAndroidContactsPage(BuildContext context) {
    final l10n = context.l10n;
    final contacts = _androidChatStore.contacts;
    final visibleGroupIds = _visibleAndroidGroupIdsForLocalIdentity(
      groups: _androidChatStore.groups,
      groupMembers: _androidChatStore.groupMembers,
    );
    final groups = _androidChatStore.groups
        .where((group) => visibleGroupIds.contains(group.groupId))
        .toList(growable: false);
    final conversationItems = _androidConversationItems(
      contacts: contacts,
      groups: groups,
      filter: _androidConversationFilter,
    );
    final contactUnreadCount = contacts.fold<int>(
      0,
      (total, contact) => total + _newIncomingMessageCountFor(contact),
    );
    final groupUnreadCount = groups.fold<int>(
      0,
      (total, group) => total + _newIncomingGroupMessageCountFor(group),
    );
    int unreadCountForFilter(_AndroidConversationFilter filter) {
      return switch (filter) {
        _AndroidConversationFilter.all => contactUnreadCount + groupUnreadCount,
        _AndroidConversationFilter.contacts => contactUnreadCount,
        _AndroidConversationFilter.groups => groupUnreadCount,
      };
    }

    return SafeArea(
      child: Column(
        children: [
          _buildAndroidContactsTopBar(
            context,
            visibleGroupCount: groups.length,
          ),
          _AndroidConversationFilterBar(
            selected: _androidConversationFilter,
            labelFor: (filter) =>
                _androidConversationFilterLabel(context, filter),
            unreadCountFor: unreadCountForFilter,
            onChanged: (filter) {
              setState(() => _androidConversationFilter = filter);
            },
          ),
          Expanded(
            child: Stack(
              children: [
                contacts.isEmpty && groups.isEmpty
                    ? _AndroidContactsEmptyState(
                        onShowQr:
                            _secureIdentityReady && _native != null && !_busy
                            ? _showAndroidIntroQr
                            : null,
                        onScanQr:
                            _secureIdentityReady && _native != null && !_busy
                            ? _scanAndroidIntroQr
                            : null,
                        onPasteContact: _busy
                            ? null
                            : _addAndroidContactFromClipboard,
                      )
                    : conversationItems.isEmpty
                    ? _AndroidFilteredContactsEmptyState(
                        icon:
                            _androidConversationFilter ==
                                _AndroidConversationFilter.groups
                            ? Icons.groups_outlined
                            : Icons.person_outline,
                        title:
                            _androidConversationFilter ==
                                _AndroidConversationFilter.groups
                            ? l10n.noGroupChatsTitle
                            : l10n.noDirectChatsTitle,
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _AndroidConversationListView(
                          key: ValueKey(
                            'conversation-list-${_androidConversationFilter.name}',
                          ),
                          items: conversationItems,
                          selectedContactKeyId: _selectedAndroidContactKeyId,
                          selectedGroupId: _selectedAndroidGroupId,
                          contactUnreadCountFor: _newIncomingMessageCountFor,
                          groupUnreadCountFor: _newIncomingGroupMessageCountFor,
                          contactTitleFor: _contactTitle,
                          contactSubtitleFor: _contactSubtitle,
                          contactAvatarSeedFor: _androidAvatarSeedFor,
                          groupTitleFor: _androidGroupTitle,
                          groupSubtitleFor: (group) =>
                              _androidGroupSubtitle(context, group),
                          groupPolicyLabelFor: (group) =>
                              _androidGroupPolicyLabel(context, group.policy),
                          groupPolicyIconFor: (group) =>
                              _androidGroupPolicyIcon(group.policy),
                          onOpenContact: _openAndroidChat,
                          onOpenGroup: _openAndroidGroupChat,
                          onEditContact: (contact) async {
                            setState(() {
                              _selectedAndroidContactKeyId = contact.keyId;
                              _selectedAndroidGroupId = null;
                            });
                            await _editSelectedAndroidContactRemark();
                          },
                          onDeleteContact: _deleteAndroidContactFromUi,
                          busy: _busy,
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidContactsTopBar(
    BuildContext context, {
    required int visibleGroupCount,
  }) {
    final l10n = context.l10n;
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
      ),
      child: Row(
        children: [
          const _EnvelopeBrandMark(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.contactsTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  l10n.contactsSummary(
                    _androidChatStore.contacts.length,
                    visibleGroupCount,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: l10n.addContact,
            enabled: _secureIdentityReady && _native != null && !_busy,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onSelected: (value) {
              switch (value) {
                case 'show_qr':
                  unawaited(_showAndroidIntroQr());
                case 'scan_qr':
                  unawaited(_scanAndroidIntroQr());
                case 'paste':
                  unawaited(_addAndroidContactFromClipboard());
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'show_qr',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.qr_code_2_outlined),
                  title: Text(l10n.showQr),
                ),
              ),
              PopupMenuItem(
                value: 'scan_qr',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.qr_code_scanner_outlined),
                  title: Text(l10n.scanQr),
                ),
              ),
              PopupMenuItem(
                value: 'paste',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.content_paste_outlined),
                  title: Text(l10n.pasteAddContact),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: l10n.createGroup,
            onPressed:
                _secureIdentityReady &&
                    _native != null &&
                    !_busy &&
                    _androidChatStore.contacts.isNotEmpty
                ? () => unawaited(_showCreateAndroidGroupDialog())
                : null,
            icon: const Icon(Icons.group_add_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidChatPage(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildAndroidChatTopBar(context),
          Expanded(child: _buildAndroidChatBody(context)),
          _buildAndroidComposer(context),
        ],
      ),
    );
  }

  Widget _buildAndroidUnsealPage(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
            ),
            child: Row(
              children: [
                const _EnvelopeBrandMark(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.unsealTitle,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        l10n.unsealSubtitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff65716d),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                _CommandGroup(
                  title: l10n.importEnvelopeFile,
                  children: [
                    _ActionButton(
                      icon: Icons.file_open_outlined,
                      label: l10n.importEnvelopeFile,
                      enabled:
                          _secureIdentityReady && _native != null && !_busy,
                      onPressed: _importAndroidOfflineEnvelopeFromFile,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _CommandGroup(
                  title: l10n.envelopeBase64,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: _androidEnvelopeBase64Controller,
                        minLines: 5,
                        maxLines: 9,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          height: 1.25,
                        ),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(
                            Icons.mark_email_unread_outlined,
                          ),
                          labelText: l10n.envelopeBase64,
                          hintText: l10n.envelopeBase64Hint,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.content_paste_outlined,
                            label: l10n.paste,
                            enabled: !_busy,
                            onPressed: _pasteAndroidEnvelope,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.lock_open_outlined,
                            label: l10n.unsealTab,
                            enabled:
                                _secureIdentityReady &&
                                _native != null &&
                                !_busy,
                            onPressed: _importAndroidEnvelope,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_details.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _SettingsDetailsBox(
                    text: _details,
                    onOpenFile: _openAndroidPathFile,
                    onOpenPath: _openAndroidPathFolder,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidAboutPage(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
            ),
            child: Row(
              children: [
                const _EnvelopeBrandMark(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.aboutSection,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        l10n.aboutDescription,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff65716d),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _CommandGroup(
                  title: l10n.aboutSection,
                  children: [
                    _AboutVersionBlock(
                      version: _appDisplayVersion,
                      signingFingerprint: _androidSigningFingerprint,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _CommandGroup(
                  title: l10n.helpSection,
                  children: [
                    _ActionButton(
                      icon: Icons.menu_book_outlined,
                      label: l10n.openUserManual,
                      enabled: true,
                      onPressed: () =>
                          unawaited(_openBundledUserManual(context)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _CommandGroup(
                  title: l10n.projectSection,
                  children: [
                    _ActionButton(
                      icon: Icons.code_outlined,
                      label: l10n.sourceCodeRepository,
                      enabled: true,
                      onPressed: () =>
                          unawaited(_openAndroidSourceRepository(context)),
                    ),
                    _AboutInfoRow(
                      icon: Icons.balance_outlined,
                      label: l10n.license,
                      value: _appLicense,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAndroidSettingsPage(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        return _buildAndroidSettingsSheet(
          context,
          setSheetState,
          showCloseButton: false,
        );
      },
    );
  }

  Widget _buildAndroidChatTopBar(BuildContext context) {
    final l10n = context.l10n;
    final pendingCount = _androidPendingCount;
    final contact = _selectedAndroidContact;
    final group = _selectedAndroidGroup;
    final visibleMessages = _androidMessagesForSelectedConversation();
    final canSealEnvelope =
        _secureIdentityReady &&
        _native != null &&
        (contact != null || group != null) &&
        !_busy;
    if (_androidMessageSelectionMode) {
      final selectedCount = _selectedAndroidMessageIds.length;
      return Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: l10n.exitSelection,
              onPressed: _busy ? null : _clearAndroidMessageSelection,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                l10n.selectedMessages(selectedCount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            IconButton(
              tooltip: l10n.selectAllMessages,
              onPressed: _busy || visibleMessages.isEmpty
                  ? null
                  : _selectAllVisibleAndroidMessages,
              icon: const Icon(Icons.select_all_outlined),
            ),
            IconButton.filledTonal(
              tooltip: l10n.deleteSelectedMessages,
              onPressed: _busy || selectedCount == 0
                  ? null
                  : _deleteSelectedAndroidMessagesFromUi,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
      ),
      child: Row(
        children: [
          _AndroidAvatar(
            label: _secureIdentity?.displayName ?? '我',
            seed: _secureIdentity?.keyId ?? 'me',
            size: 42,
            fallbackIcon: Icons.person_outline,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  group != null
                      ? _androidGroupTitle(group)
                      : contact == null
                      ? l10n.chooseConversationTitle
                      : _contactTitle(contact),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  [
                    _secureIdentityReady
                        ? l10n.identityReady
                        : l10n.identityNotInitialized,
                    if (group != null) _androidGroupSubtitle(context, group),
                    if (group == null && contact != null)
                      _contactSubtitle(contact),
                    if (pendingCount > 0) 'pending $pendingCount',
                  ].join(' / '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                  ),
                ),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (contact != null || group != null) ...[
            IconButton.filledTonal(
              tooltip: l10n.seal,
              onPressed: canSealEnvelope
                  ? () => unawaited(_openAndroidSealPage(context))
                  : null,
              icon: const Icon(Icons.lock_outline),
            ),
            const SizedBox(width: 10),
          ],
          if (group != null) ...[
            const SizedBox(width: 6),
            IconButton.filledTonal(
              tooltip: l10n.groupMembers,
              onPressed: _busy
                  ? null
                  : () => unawaited(_showAndroidGroupDetails(group)),
              icon: const Icon(Icons.groups_outlined),
            ),
          ],
          const SizedBox(width: 10),
          group != null
              ? _AndroidGroupAvatar(
                  label: _androidGroupTitle(group),
                  seed: group.displaySeed,
                  size: 42,
                  icon: _androidGroupPolicyIcon(group.policy),
                )
              : contact == null
              ? const _AndroidAvatar(
                  label: '?',
                  seed: 'empty-contact',
                  size: 42,
                  fallbackIcon: Icons.person_outline,
                )
              : _AndroidAvatar(
                  label: _contactTitle(contact),
                  seed: _androidAvatarSeedFor(contact),
                  size: 42,
                ),
        ],
      ),
    );
  }

  Widget _buildAndroidGroupInviteActions(
    BuildContext context,
    AndroidGroupRecord group, {
    bool compact = false,
  }) {
    final l10n = context.l10n;
    final pendingInvite = _pendingAndroidGroupInviteForLocalIdentity(group);
    if (pendingInvite == null) {
      final members = _androidChatStore.membersForGroup(group.groupId);
      final expired =
          !group.isActive || androidGroupShouldAutoDissolveForMembers(members);
      return Text(
        expired ? l10n.groupInviteExpired : l10n.groupInviteHandled,
        style: const TextStyle(
          color: Color(0xff65716d),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => unawaited(
                  _run(
                    '接受群邀请',
                    () => _acceptAndroidGroupInvite(
                      group,
                      openGroupAfterAccept: false,
                    ),
                  ),
                ),
          icon: _busy && !compact
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline),
          label: Text(_busy ? l10n.groupInviteBusy : l10n.acceptGroupInvite),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => unawaited(
                  _run('拒绝群邀请', () => _declineAndroidGroupInvite(group)),
                ),
          icon: const Icon(Icons.cancel_outlined),
          label: Text(l10n.declineGroupInvite),
        ),
      ],
    );
  }

  Widget? _buildAndroidGroupControlMessageExtra(
    BuildContext context,
    AndroidMessageRecord message,
  ) {
    final ref = _androidGroupControlMessageRefFor(message);
    if (ref == null || ref.type != 'group_invite') return null;
    final group = _androidChatStore.findGroup(ref.groupId);
    if (group == null) return null;
    return _buildAndroidGroupInviteActions(context, group, compact: true);
  }

  Widget _buildAndroidChatBody(BuildContext context) {
    final l10n = context.l10n;
    final contact = _selectedAndroidContact;
    final group = _selectedAndroidGroup;
    final chronologicalMessages = _androidMessagesForSelectedConversation();
    final messages = chronologicalMessages.reversed.toList(growable: false);
    final hasMore = _androidMessageCount > _androidChatStore.messages.length;
    final contactInviteCards = contact == null
        ? const <AndroidGroupRecord>[]
        : _pendingAndroidGroupInvitesFromContact(
            contact,
            chronologicalMessages,
          );
    if (contact == null && group == null) {
      return _EmptyActionState(
        icon: Icons.people_alt_outlined,
        title: l10n.chooseConversationTitle,
        message: l10n.chooseConversationMessage,
        actionLabel: l10n.openContacts,
        onAction: () => _selectAndroidHomeTab(_AndroidHomeTab.contacts),
      );
    }
    final inviteCards = [
      for (final inviteGroup in contactInviteCards)
        _AndroidGroupInviteCard(
          title: l10n.groupInviteTitle,
          message: l10n.groupInviteMessage(
            _androidGroupTitle(inviteGroup),
            AndroidGroupPolicy.label(inviteGroup.policy),
          ),
          busy: _busy,
          onAccept: () => unawaited(
            _run(
              '接受群邀请',
              () => _acceptAndroidGroupInvite(
                inviteGroup,
                openGroupAfterAccept: false,
              ),
            ),
          ),
          onDecline: () => unawaited(
            _run('拒绝群邀请', () => _declineAndroidGroupInvite(inviteGroup)),
          ),
        ),
    ];
    final messageArea = messages.isEmpty
        ? inviteCards.isNotEmpty
              ? const Expanded(child: SizedBox.expand())
              : Expanded(
                  child: _EmptyActionState(
                    icon: Icons.forum_outlined,
                    title: l10n.noMessagesTitle,
                    message: group == null
                        ? l10n.firstContactMessage(_contactTitle(contact!))
                        : l10n.firstGroupMessage(_androidGroupTitle(group)),
                  ),
                )
        : Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                final isUserScroll =
                    notification is ScrollUpdateNotification &&
                    notification.dragDetails != null;
                final isNearTop =
                    notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 48;
                if (hasMore && isUserScroll && isNearTop) {
                  unawaited(
                    _loadEarlierAndroidMessagesForSelectedConversation(),
                  );
                }
                return false;
              },
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                itemCount: messages.length + (hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == messages.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Center(
                        child: TextButton.icon(
                          onPressed: _busy || _androidLoadingEarlierMessages
                              ? null
                              : _loadEarlierAndroidMessagesForSelectedConversation,
                          icon: const Icon(Icons.history_outlined),
                          label: Text(
                            _androidLoadingEarlierMessages
                                ? l10n.loadingEarlier
                                : l10n.loadEarlier,
                          ),
                        ),
                      ),
                    );
                  }
                  final message = messages[index];
                  return _AndroidMessageTile(
                    message: message,
                    peerLabel: group == null
                        ? _contactTitle(contact!)
                        : message.isOutgoing
                        ? _androidGroupTitle(group)
                        : message.peerDisplayName,
                    showIncomingPeerLabel: group != null,
                    showEnvelopeAction: false,
                    selectionMode: _androidMessageSelectionMode,
                    selected: _selectedAndroidMessageIds.contains(
                      message.envelopeId,
                    ),
                    canSelect: true,
                    onTap: _androidMessageSelectionMode
                        ? () => _toggleAndroidMessageSelection(message)
                        : null,
                    onLongPress: _busy
                        ? null
                        : () => _toggleAndroidMessageSelection(message),
                    onOpenSavedFile: _busy
                        ? null
                        : (message) => unawaited(
                            _openAndroidSavedFile(context, message),
                          ),
                    onOpenSavedFileLocation: _busy
                        ? null
                        : (message) => unawaited(
                            _openAndroidSavedFileLocation(context, message),
                          ),
                    onLoadSavedFilePreview: _loadAndroidSavedFilePreview,
                    extraContent: _buildAndroidGroupControlMessageExtra(
                      context,
                      message,
                    ),
                  );
                },
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...inviteCards, messageArea],
    );
  }

  Future<void> _copyAndroidSealedEnvelopePath(
    BuildContext context,
    String path,
  ) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('密封文件路径已复制')));
  }

  Future<void> _openAndroidPathFolder(BuildContext context, String path) async {
    try {
      final result = await _secureStore.openContainingFolder(path);
      if (!context.mounted) return;
      _showAndroidOpenLocationResult(context, result);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开文件夹：$error')));
    }
  }

  Future<void> _openAndroidPathFile(BuildContext context, String path) async {
    try {
      await _secureStore.openSavedFile(path: path);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开文件：$error')));
    }
  }

  Future<void> _openAndroidSealedEnvelopeLocation(
    BuildContext context,
    AndroidSealedEnvelopeRecord record,
  ) async {
    if (record.isDeleted) return;
    final uri = record.uri?.trim();
    final path = record.locationPath.trim();
    if ((uri == null || uri.isEmpty) && path.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条密封记录没有可打开的保存路径')));
      return;
    }
    try {
      final result = await _secureStore.openSavedFileLocation(
        uri: uri,
        path: path,
        mime: record.mime,
      );
      if (!context.mounted) return;
      _showAndroidOpenLocationResult(context, result);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开保存位置：$error')));
    }
  }

  Future<void> _openAndroidSavedFileLocation(
    BuildContext context,
    AndroidMessageRecord message,
  ) async {
    if (message.attachmentDeleted) return;
    final uri = message.attachmentUri?.trim();
    final path = _androidSavedFilePathForMessage(message);
    if ((uri == null || uri.isEmpty) && (path == null || path.isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条记录没有可打开的文件路径')));
      return;
    }
    try {
      final result = await _secureStore.openSavedFileLocation(
        uri: uri,
        path: path,
        mime: message.attachmentMime,
      );
      if (!context.mounted) return;
      _showAndroidOpenLocationResult(context, result);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开保存位置：$error')));
    }
  }

  Future<void> _openAndroidSavedFile(
    BuildContext context,
    AndroidMessageRecord message,
  ) async {
    if (message.attachmentDeleted) return;
    final uri = message.attachmentUri?.trim();
    final path = _androidSavedFilePathForMessage(message);
    if ((uri == null || uri.isEmpty) && (path == null || path.isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条记录没有可打开的文件')));
      return;
    }
    try {
      await _secureStore.openSavedFile(
        uri: uri,
        path: path,
        mime: message.attachmentMime,
      );
    } catch (_) {
      try {
        final result = await _secureStore.openSavedFileLocation(
          uri: uri,
          path: path,
          mime: message.attachmentMime,
        );
        if (!context.mounted) return;
        _showAndroidOpenLocationResult(context, result);
        return;
      } catch (locationError) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开文件，也无法打开保存位置：$locationError')),
        );
      }
      return;
    }
  }

  Future<AndroidSavedFilePreview?> _loadAndroidSavedFilePreview(
    AndroidMessageRecord message,
  ) {
    if (message.attachmentDeleted) {
      return Future<AndroidSavedFilePreview?>.value(null);
    }
    final uri = message.attachmentUri?.trim() ?? '';
    final path = _androidSavedFilePathForMessage(message)?.trim() ?? '';
    final mime = message.attachmentMime?.trim() ?? '';
    if (uri.isEmpty && path.isEmpty) {
      return Future<AndroidSavedFilePreview?>.value(null);
    }
    final key = '$uri\n$path\n$mime';
    return _androidSavedFilePreviewCache.putIfAbsent(key, () async {
      try {
        return await _secureStore.loadSavedFilePreview(
          uri: uri,
          path: path,
          mime: mime,
        );
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> _clearAndroidEnvelopeCache() => _run('清空文件缓存', () async {
    if (!await _requireAndroidLocalUnlockForHighRisk('清空文件缓存会删除接收文件和密封文件。')) {
      throw const SecureStoreException('本地锁屏认证未通过。');
    }
    final db = await _ensureAndroidDbStore();
    final result = await _secureStore.clearEnvelopeCache();
    final deletedAtUnixMs = DateTime.now().millisecondsSinceEpoch;
    final messageRows = await db.markCachedMessageFilesDeleted(
      deletedAtUnixMs: deletedAtUnixMs,
    );
    final sealedRows = await db.markSealedEnvelopeFilesDeleted(
      deletedAtUnixMs: deletedAtUnixMs,
    );
    _androidSavedFilePreviewCache.clear();
    await _refreshAndroidChatStore();
    if (!mounted) return;
    setState(() {
      _details = [
        '文件缓存已清空。',
        'received 删除文件数: ${result.receivedDeleted}',
        'sealed 删除文件数: ${result.sealedDeleted}',
        '聊天附件标记已删除: $messageRows',
        '密封记录标记已删除: $sealedRows',
      ].join('\n');
    });
  });

  Future<void> _exportDiagnosticLogs() => _run('导出诊断日志', () async {
    final log = _diagnosticLog;
    if (log == null) {
      throw const SecureStoreException('诊断日志尚未初始化。');
    }
    await log.info('diagnostic_export_requested');
    final bytes = await log.exportBytes();
    final file = await _secureStore.createSavedFile(
      name: log.exportFileName(),
      mime: 'application/x-ndjson',
      childDir: 'diagnostics',
    );
    await _secureStore.appendSavedFileBytes(
      uri: file.uri,
      bytes: Uint8List.fromList(bytes),
    );
    final finished = await _secureStore.finishSavedFile(
      file: file,
      bytes: bytes.length,
    );
    if (!mounted) return;
    setState(() {
      _details = [
        '诊断日志已导出。',
        '文件: ${finished.displayPath}',
        '大小: ${finished.bytes} bytes',
      ].join('\n');
    });
  });

  Future<void> _clearDiagnosticLogs() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '清空诊断日志';
      _details = '';
    });
    try {
      final log = _diagnosticLog;
      if (log == null) {
        throw const SecureStoreException('诊断日志尚未初始化。');
      }
      final deleted = await log.clear();
      if (!mounted) return;
      setState(() {
        _status = '清空诊断日志完成';
        _details = '已删除 $deleted 个诊断日志文件。';
      });
    } catch (error) {
      if (!mounted) return;
      final message = error.toString();
      setState(() {
        _status = '清空诊断日志失败';
        _details = message;
      });
      _showRunErrorSnackBar(message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showAndroidOpenLocationResult(
    BuildContext context,
    AndroidOpenLocationResult result,
  ) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result.openedPickerAtFolder) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已定位到保存目录，请按需使用此文件夹。')),
      );
      return;
    }
    if (result.unavailable) {
      final folder = _androidReadableFolderPath(result.folderPath);
      messenger.showSnackBar(
        SnackBar(content: Text('系统无法直接定位保存目录。请点文件图标打开文件，或在文件管理器中进入 $folder。')),
      );
    }
  }

  Future<void> _openBundledUserManual(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const _AndroidUserManualPage()),
    );
  }

  Future<void> _openAndroidSourceRepository(BuildContext context) async {
    try {
      final opened = await _secureStore.openExternalUrl(_sourceRepositoryUrl);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开源代码仓库')));
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开源代码仓库：$error')));
    }
  }

  Widget _buildAndroidComposer(BuildContext context) {
    final l10n = context.l10n;
    final canSend =
        _secureIdentityReady &&
        _native != null &&
        _hasSelectedAndroidConversation &&
        !_busy;
    final canSendFile =
        canSend &&
        (_selectedAndroidContact != null || _selectedAndroidGroup != null);
    return Container(
      padding: EdgeInsets.fromLTRB(
        14,
        10,
        14,
        12 + MediaQuery.viewInsetsOf(context).bottom.clamp(0, 18),
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xffd9e2de))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton.outlined(
            tooltip: l10n.addFile,
            onPressed: canSendFile ? _sendAndroidFileFromUi : null,
            icon: const Icon(Icons.attach_file_outlined),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _androidMessageController,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.edit_note_outlined),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            tooltip: l10n.send,
            onPressed: canSend ? _sendAndroidMessageFromUi : null,
            icon: const Icon(Icons.send_outlined),
          ),
        ],
      ),
    );
  }

  Future<void> _openAndroidSealPage(BuildContext context) async {
    if (_selectedAndroidContact == null && _selectedAndroidGroup == null) {
      _showRunErrorSnackBar('请先选择联系人或群组再使用密封。');
      return;
    }
    final controller = TextEditingController(
      text: _androidMessageController.text,
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (routeContext) =>
              _buildAndroidSealPage(routeContext, controller),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Widget _buildAndroidSealPage(
    BuildContext context,
    TextEditingController textController,
  ) {
    _AndroidSealResult? sealResult;
    String? errorText;
    var pageBusy = false;

    Future<void> runSeal(
      String label,
      Future<_AndroidSealResult?> Function() action,
      StateSetter setPageState,
    ) async {
      if (_busy || pageBusy) return;
      setPageState(() {
        pageBusy = true;
        errorText = null;
      });
      if (mounted) {
        setState(() {
          _busy = true;
          _status = label;
          _details = '';
        });
      }
      try {
        if (!await _requireAndroidLocalUnlockForHighRisk('$label 需要确认身份。')) {
          throw const SecureStoreException('本地锁屏认证未通过。');
        }
        final result = await action();
        await _refreshAndroidChatStore();
        if (mounted) {
          setState(() {
            _status = result == null ? '$label 已取消' : '$label 完成';
            _details = result?.details ?? '已取消选择文件。';
          });
        }
        if (context.mounted) {
          setPageState(() => sealResult = result);
        }
      } catch (error) {
        final message = error.toString();
        if (mounted) {
          setState(() {
            _status = '$label 失败';
            _details = message;
          });
          _showRunErrorSnackBar(message);
        }
        if (context.mounted) {
          setPageState(() => errorText = message);
        }
      } finally {
        if (mounted) {
          setState(() => _busy = false);
        }
        if (context.mounted) {
          setPageState(() => pageBusy = false);
        }
      }
    }

    return StatefulBuilder(
      builder: (pageContext, setPageState) {
        final contact = _selectedAndroidContact;
        final group = _selectedAndroidGroup;
        final canSeal =
            _secureIdentityReady &&
            _native != null &&
            (contact != null || (group != null && group.isActive)) &&
            !_busy &&
            !pageBusy;
        final canSealText = canSeal && textController.text.trim().isNotEmpty;
        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            title: const Text('密封'),
            actions: [
              if (pageBusy || _busy)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                _CommandGroup(
                  title: '收件人',
                  children: [
                    _AndroidSealRecipientCard(
                      contact: contact,
                      group: group,
                      groupIcon: group == null
                          ? null
                          : _androidGroupPolicyIcon(group.policy),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _CommandGroup(
                  title: '文本',
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: textController,
                        minLines: 3,
                        maxLines: 7,
                        onChanged: (_) => setPageState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.edit_note_outlined),
                          labelText: '待密封文本',
                        ),
                      ),
                    ),
                    _ActionButton(
                      icon: Icons.lock_outline,
                      label: '密封文本',
                      enabled: canSealText,
                      onPressed: () => unawaited(
                        runSeal(
                          group == null ? '密封文本' : '密封群组文本',
                          () => group == null
                              ? _createAndroidTextSealResult(
                                  contact!,
                                  textController.text,
                                )
                              : _createAndroidGroupTextSealResult(
                                  group,
                                  textController.text,
                                ),
                          setPageState,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _CommandGroup(
                  title: '文件',
                  children: [
                    _ActionButton(
                      icon: Icons.attach_file_outlined,
                      label: '选择文件并密封',
                      enabled: canSeal,
                      onPressed: () => unawaited(
                        runSeal(
                          group == null ? '密封文件' : '密封群组文件',
                          () => group == null
                              ? _createAndroidFileSealResult(contact!)
                              : _createAndroidGroupFileSealResult(group),
                          setPageState,
                        ),
                      ),
                    ),
                  ],
                ),
                if (pageBusy) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(minHeight: 2),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(pageContext).colorScheme.error,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
                if (sealResult != null) ...[
                  const SizedBox(height: 14),
                  _buildAndroidSealResultPanel(pageContext, sealResult!),
                ],
                const SizedBox(height: 22),
                _CommandGroup(
                  title: '历史密封记录',
                  children: [
                    _AndroidSealHistoryList(
                      records: _androidSealHistory,
                      onOpenFolder: (record) => unawaited(
                        _openAndroidSealedEnvelopeLocation(pageContext, record),
                      ),
                      onCopyPath: (path) => unawaited(
                        _copyAndroidSealedEnvelopePath(pageContext, path),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAndroidSealResultPanel(
    BuildContext context,
    _AndroidSealResult result,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xfffffbf5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffffd7aa)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(
              Icons.mark_email_read_outlined,
              size: 18,
              color: Color(0xff9a3412),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '密封文件已生成 / ${result.label}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xff9a3412),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatAndroidUnixMsWithMillis(result.record.createdAtUnixMs),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff9a3412),
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  result.path,
                  onTap: () => _openAndroidSealedEnvelopeLocation(
                    context,
                    result.record,
                  ),
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.25,
                    color: Color(0xff43302b),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '打开文件夹',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                _openAndroidSealedEnvelopeLocation(context, result.record),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
          ),
          IconButton(
            tooltip: '复制路径',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                _copyAndroidSealedEnvelopePath(context, result.path),
            icon: const Icon(Icons.copy_all_outlined, size: 18),
          ),
        ],
      ),
    );
  }

  VoidCallback _settingsAction(
    Future<void> Function() action,
    StateSetter setSheetState,
  ) {
    return () {
      void refreshSheet() {
        try {
          setSheetState(() {});
        } catch (_) {
          // The settings sheet may have been closed while an async action runs.
        }
      }

      refreshSheet();
      unawaited(
        action().whenComplete(() {
          if (mounted) {
            refreshSheet();
          }
        }),
      );
    };
  }

  Widget _buildAndroidSettingsSheet(
    BuildContext context,
    StateSetter setSheetState, {
    bool showCloseButton = true,
  }) {
    final l10n = context.l10n;
    const autoBackupIntervalOptions = <int>[0, 6, 12, 24, 72];
    const autoBackupRetentionOptions = <int>[3, 7, 14, 30];
    final autoBackupIntervalValue =
        autoBackupIntervalOptions.contains(_androidAutoBackupIntervalHours)
        ? _androidAutoBackupIntervalHours
        : AndroidAutoBackupSettings.defaults.intervalHours;
    final autoBackupRetentionValue =
        autoBackupRetentionOptions.contains(_androidAutoBackupRetentionCount)
        ? _androidAutoBackupRetentionCount
        : AndroidAutoBackupSettings.defaults.retentionCount;
    final restoreLocalBackupButton = _ActionButton(
      icon: Icons.restore_outlined,
      label: l10n.restoreLocalBackup,
      enabled:
          _secureStore.isSupported &&
          _native != null &&
          !_busy &&
          !_androidLocalBackupInFlight,
      onPressed: _settingsAction(_importAndroidLocalBackup, setSheetState),
    );
    final localBackupChildren = <Widget>[
      _SettingsInfoRow(
        icon: Icons.backup_outlined,
        title: l10n.localBackupSection,
        value: l10n.localBackupDescription,
      ),
      _SettingsInfoRow(
        icon: Icons.schedule_outlined,
        title: l10n.autoBackupTitle,
        value:
            '${l10n.autoBackupDescription}\n${_androidAutoBackupStatus(l10n)}',
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<int>(
          initialValue: autoBackupIntervalValue,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.timer_outlined),
            labelText: l10n.autoBackupInterval,
          ),
          items: [
            for (final hours in autoBackupIntervalOptions)
              DropdownMenuItem<int>(
                value: hours,
                child: Text(_androidAutoBackupIntervalLabel(l10n, hours)),
              ),
          ],
          onChanged: _secureStore.isSupported && !_busy
              ? (value) {
                  if (value == null) return;
                  setSheetState(() {
                    _androidAutoBackupIntervalHours = value;
                  });
                  unawaited(
                    _setAndroidAutoBackupIntervalHours(value).whenComplete(() {
                      if (!mounted) return;
                      try {
                        setSheetState(() {});
                      } catch (_) {}
                    }),
                  );
                }
              : null,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<int>(
          initialValue: autoBackupRetentionValue,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.history_outlined),
            labelText: l10n.autoBackupRetention,
          ),
          items: [
            for (final count in autoBackupRetentionOptions)
              DropdownMenuItem<int>(
                value: count,
                child: Text(l10n.autoBackupKeepCount(count)),
              ),
          ],
          onChanged: _secureStore.isSupported && !_busy
              ? (value) {
                  if (value == null) return;
                  setSheetState(() {
                    _androidAutoBackupRetentionCount = value;
                  });
                  unawaited(
                    _setAndroidAutoBackupRetentionCount(value).whenComplete(() {
                      if (!mounted) return;
                      try {
                        setSheetState(() {});
                      } catch (_) {}
                    }),
                  );
                }
              : null,
        ),
      ),
      _ActionButton(
        icon: Icons.ios_share_outlined,
        label: l10n.exportLocalBackup,
        enabled:
            _secureIdentityReady &&
            _secureStore.isSupported &&
            _native != null &&
            !_busy &&
            !_androidLocalBackupInFlight,
        onPressed: _settingsAction(_exportAndroidLocalBackup, setSheetState),
      ),
    ];
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xffd9e2de))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.settingsTitle,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (showCloseButton)
                    IconButton(
                      tooltip: l10n.close,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CommandGroup(
                      title: l10n.identitySection,
                      children: [
                        _StatusLine(
                          status: _secureIdentityLabel ?? l10n.identityMissing,
                          ready: _secureIdentityReady,
                        ),
                        if (!_secureIdentityReady) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _displayNameController,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.badge_outlined),
                              labelText: l10n.displayName,
                              hintText: l10n.defaultDisplayName,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _ActionButton(
                            icon: Icons.add_moderator_outlined,
                            label: l10n.createSaveIdentity,
                            enabled:
                                _secureStore.isSupported &&
                                _native != null &&
                                !_busy,
                            onPressed: _settingsAction(
                              _createAndSaveAndroidIdentity,
                              setSheetState,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: _recoveryPhraseController,
                            minLines: 3,
                            maxLines: 6,
                            keyboardType: TextInputType.visiblePassword,
                            autocorrect: false,
                            enableSuggestions: false,
                            smartDashesType: SmartDashesType.disabled,
                            smartQuotesType: SmartQuotesType.disabled,
                            onChanged: (_) => setSheetState(() {}),
                            style: const TextStyle(fontSize: 13, height: 1.35),
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.key_outlined),
                              labelText: l10n.recoveryPhraseLabel,
                              hintText: l10n.recoveryPhraseHint,
                            ),
                          ),
                        ),
                        restoreLocalBackupButton,
                        _ActionButton(
                          icon: Icons.backspace_outlined,
                          label: l10n.clearRecoveryPhrase,
                          enabled:
                              _recoveryPhraseController.text
                                  .trim()
                                  .isNotEmpty &&
                              !_busy,
                          onPressed: () {
                            _clearRecoveryPhrase();
                            setSheetState(() {});
                          },
                        ),
                        if (_secureIdentityReady)
                          _ActionButton(
                            icon: Icons.delete_outline,
                            label: l10n.clearLocalIdentity,
                            enabled:
                                _secureStore.isSupported &&
                                _secureIdentityReady &&
                                !_busy,
                            onPressed: _settingsAction(
                              _clearAndroidIdentity,
                              setSheetState,
                            ),
                          ),
                        if (_native == null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              l10n.nativeCoreMissing(_nativeError),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _CommandGroup(
                      title: l10n.localBackupSection,
                      children: localBackupChildren,
                    ),
                    const SizedBox(height: 22),
                    _CommandGroup(
                      title: l10n.securitySection,
                      children: [
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          secondary: const Icon(Icons.screen_lock_portrait),
                          title: Text(
                            l10n.localLockSettingTitle,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            _androidLocalLockAvailable
                                ? l10n.localLockSettingSubtitle
                                : l10n.localLockUnavailable,
                          ),
                          value: _androidLocalLockEnabled,
                          onChanged:
                              _secureStore.isSupported &&
                                  _androidLocalLockChecked &&
                                  !_busy
                              ? (enabled) {
                                  setSheetState(() {});
                                  unawaited(
                                    _setAndroidLocalLockEnabled(
                                      enabled,
                                    ).whenComplete(() {
                                      if (mounted) {
                                        try {
                                          setSheetState(() {});
                                        } catch (_) {}
                                      }
                                    }),
                                  );
                                }
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _CommandGroup(
                      title: l10n.messageSyncSection,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _StatusLine(
                            status: _androidMessageSyncStatus(l10n),
                            ready:
                                _secureIdentityReady &&
                                _androidLastMessageSyncError == null,
                          ),
                        ),
                        _SettingsInfoRow(
                          icon: Icons.sync_outlined,
                          title: l10n.messageSyncAutoTitle,
                          value: l10n.messageSyncAutoDescription,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: _envelopeServerUrlController,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.hub_outlined),
                              labelText: l10n.messageSyncServiceEntryTitle,
                              hintText: l10n.messageSyncServiceHint,
                              helperText: l10n.messageSyncServiceHelp,
                            ),
                            onSubmitted: (_) => _settingsAction(
                              _saveAndroidSyncServiceUrl,
                              setSheetState,
                            )(),
                          ),
                        ),
                        _SettingsInfoRow(
                          icon: Icons.cloud_done_outlined,
                          title: l10n.messageSyncServiceTitle,
                          value: _serverUrlForDisplay(l10n),
                        ),
                        _ActionButton(
                          icon: Icons.save_outlined,
                          label: l10n.messageSyncServiceSave,
                          enabled: _secureStore.isSupported && !_busy,
                          onPressed: _settingsAction(
                            _saveAndroidSyncServiceUrl,
                            setSheetState,
                          ),
                        ),
                        _ActionButton(
                          icon: Icons.sync,
                          label: l10n.messageSyncNow,
                          enabled:
                              _configuredEnvelopeServerUrl.isNotEmpty &&
                              _secureIdentityReady &&
                              _native != null &&
                              !_busy,
                          onPressed: _settingsAction(
                            _syncAndroidMessagesFromUi,
                            setSheetState,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _CommandGroup(
                      title: '存储',
                      children: [
                        _SettingsInfoRow(
                          icon: Icons.folder_delete_outlined,
                          title: '文件缓存',
                          value:
                              '清空 Download/Envelope/received 和 Download/Envelope/sealed。',
                        ),
                        _ActionButton(
                          icon: Icons.cleaning_services_outlined,
                          label: '清空文件缓存',
                          enabled: _secureStore.isSupported && !_busy,
                          onPressed: _settingsAction(
                            _clearAndroidEnvelopeCache,
                            setSheetState,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _CommandGroup(
                      title: l10n.diagnosticsSection,
                      children: [
                        _SettingsInfoRow(
                          icon: Icons.bug_report_outlined,
                          title: l10n.diagnosticsLogTitle,
                          value: l10n.diagnosticsLogDescription,
                        ),
                        _ActionButton(
                          icon: Icons.ios_share_outlined,
                          label: l10n.exportDiagnosticLogs,
                          enabled:
                              _secureStore.isSupported &&
                              _diagnosticLog != null &&
                              !_busy,
                          onPressed: _settingsAction(
                            _exportDiagnosticLogs,
                            setSheetState,
                          ),
                        ),
                        _ActionButton(
                          icon: Icons.delete_sweep_outlined,
                          label: l10n.clearDiagnosticLogs,
                          enabled: _diagnosticLog != null && !_busy,
                          onPressed: _settingsAction(
                            _clearDiagnosticLogs,
                            setSheetState,
                          ),
                        ),
                      ],
                    ),
                    if (_details.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _SettingsDetailsBox(
                        text: _details,
                        onOpenPath: _openAndroidPathFolder,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AndroidIntroQrScanPage extends StatefulWidget {
  const _AndroidIntroQrScanPage();

  @override
  State<_AndroidIntroQrScanPage> createState() =>
      _AndroidIntroQrScanPageState();
}

class _AndroidIntroQrScanPageState extends State<_AndroidIntroQrScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描临时二维码')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _handleCapture),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 248,
                height: 248,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.64),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '扫描 Envelope 临时加好友二维码。截图来源仍需另行比对 fingerprint。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsDetailsBox extends StatelessWidget {
  const _SettingsDetailsBox({
    required this.text,
    this.onOpenFile,
    this.onOpenPath,
  });

  final String text;
  final Future<void> Function(BuildContext context, String path)? onOpenFile;
  final Future<void> Function(BuildContext context, String path)? onOpenPath;

  @override
  Widget build(BuildContext context) {
    final openFile = onOpenFile;
    final openPath = onOpenPath;
    final canOpenSavedPath = openFile != null || openPath != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xffeaf2ef),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9e2de)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '详情',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: '复制详情',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                },
                icon: const Icon(Icons.copy_all_outlined, size: 18),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 190),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: !canOpenSavedPath
                    ? SelectableText(
                        text,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                          height: 1.35,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in const LineSplitter().convert(text))
                            if (_androidSavedFilePathFromLine(line)
                                case final path?)
                              _AndroidSavedFilePathLine(
                                text: path,
                                fontSize: 12,
                                tooltip: openFile == null ? '打开文件夹' : '打开文件',
                                icon: openFile == null
                                    ? Icons.folder_open_outlined
                                    : Icons.file_open_outlined,
                                onOpenSavedFile: () => unawaited(
                                  (openFile ?? openPath!)(context, path),
                                ),
                                onOpenSavedFileLocation: openFile == null
                                    ? null
                                    : () => unawaited(
                                        openPath?.call(context, path),
                                      ),
                              )
                            else
                              SelectableText(
                                line,
                                style: const TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsInfoRow extends StatelessWidget {
  const _SettingsInfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xff24785f)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidSealRecipientCard extends StatelessWidget {
  const _AndroidSealRecipientCard({
    required this.contact,
    required this.group,
    required this.groupIcon,
  });

  final AndroidContactRecord? contact;
  final AndroidGroupRecord? group;
  final IconData? groupIcon;

  @override
  Widget build(BuildContext context) {
    final current = contact;
    final currentGroup = group;
    final hasTarget = current != null || currentGroup != null;
    final label = currentGroup != null
        ? currentGroup.displayName
        : current?.displayLabel ?? '未选择收件人';
    final subtitle = currentGroup != null
        ? '${currentGroup.groupId} / 逐成员加密'
        : current?.keyId ?? '请先从联系人或群组进入聊天。';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9e2de)),
      ),
      child: Row(
        children: [
          currentGroup != null
              ? _AndroidGroupAvatar(
                  label: currentGroup.displayName,
                  seed: currentGroup.displaySeed,
                  size: 42,
                  icon: groupIcon ?? Icons.groups_outlined,
                )
              : current == null
              ? const _AndroidAvatar(
                  label: '?',
                  seed: 'seal-empty-contact',
                  size: 42,
                  fallbackIcon: Icons.person_outline,
                )
              : _AndroidAvatar(
                  label: current.displayLabel,
                  seed: current.keyId,
                  size: 42,
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                  ),
                ),
                if (currentGroup != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    '仅当前策略允许的活跃成员可拆封。',
                    style: TextStyle(
                      fontSize: 11,
                      color: hasTarget
                          ? const Color(0xff315c44)
                          : const Color(0xff65716d),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidSealHistoryList extends StatelessWidget {
  const _AndroidSealHistoryList({
    required this.records,
    required this.onOpenFolder,
    required this.onCopyPath,
  });

  final List<AndroidSealedEnvelopeRecord> records;
  final ValueChanged<AndroidSealedEnvelopeRecord> onOpenFolder;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffd9e2de)),
        ),
        child: const Text(
          '暂无密封记录',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xff65716d), fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        for (final record in records)
          _AndroidSealHistoryTile(
            record: record,
            onOpenFolder: record.isDeleted ? null : () => onOpenFolder(record),
            onCopyPath: record.isDeleted
                ? null
                : () => onCopyPath(record.locationPath),
          ),
      ],
    );
  }
}

class _AndroidSealHistoryTile extends StatelessWidget {
  const _AndroidSealHistoryTile({
    required this.record,
    required this.onOpenFolder,
    required this.onCopyPath,
  });

  final AndroidSealedEnvelopeRecord record;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onCopyPath;

  @override
  Widget build(BuildContext context) {
    final typeLabel = record.isFile ? '文件' : '文本';
    final sourceName = record.sourceName?.trim();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9e2de)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                record.isFile
                    ? Icons.attach_file_outlined
                    : Icons.text_fields_outlined,
                size: 18,
                color: const Color(0xff1f3a5f),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$typeLabel / ${record.recipientDisplayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制路径',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                onPressed: onCopyPath,
                icon: const Icon(Icons.copy_all_outlined, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _formatAndroidUnixMsWithMillis(record.createdAtUnixMs),
            style: const TextStyle(fontSize: 12, color: Color(0xff65716d)),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (sourceName != null && sourceName.isNotEmpty) sourceName,
              'payload ${_formatAndroidByteCount(record.payloadSize)}',
              'envelope ${_formatAndroidByteCount(record.envelopeSize)}',
            ].join(' / '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xff65716d)),
          ),
          const SizedBox(height: 6),
          if (record.isDeleted)
            const Text(
              '文件已删除',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xff9a3412),
                fontWeight: FontWeight.w800,
              ),
            )
          else if (onOpenFolder != null)
            _AndroidSavedFilePathLine(
              text: record.locationPath,
              fontSize: 12,
              tooltip: '打开文件夹',
              icon: Icons.folder_open_outlined,
              onOpenSavedFile: onOpenFolder!,
            ),
        ],
      ),
    );
  }
}

class _AndroidContactsEmptyState extends StatelessWidget {
  const _AndroidContactsEmptyState({
    required this.onShowQr,
    required this.onScanQr,
    required this.onPasteContact,
  });

  final VoidCallback? onShowQr;
  final VoidCallback? onScanQr;
  final VoidCallback? onPasteContact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.people_alt_outlined,
              size: 44,
              color: Color(0xff65716d),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.noContactsTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onShowQr,
              icon: const Icon(Icons.qr_code_2_outlined),
              label: Text(l10n.showQr),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: onScanQr,
              icon: const Icon(Icons.qr_code_scanner_outlined),
              label: Text(l10n.scanQr),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onPasteContact,
              icon: const Icon(Icons.content_paste_outlined),
              label: Text(l10n.pasteAddContact),
            ),
          ],
        ),
      ),
    );
  }
}

class _AndroidConversationFilterBar extends StatelessWidget {
  const _AndroidConversationFilterBar({
    required this.selected,
    required this.labelFor,
    required this.unreadCountFor,
    required this.onChanged,
  });

  final _AndroidConversationFilter selected;
  final String Function(_AndroidConversationFilter) labelFor;
  final int Function(_AndroidConversationFilter) unreadCountFor;
  final ValueChanged<_AndroidConversationFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    const filters = [
      _AndroidConversationFilter.all,
      _AndroidConversationFilter.contacts,
      _AndroidConversationFilter.groups,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffedf2ef))),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SegmentedButton<_AndroidConversationFilter>(
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: [
              for (final filter in filters)
                ButtonSegment(
                  value: filter,
                  icon: Icon(_androidConversationFilterIcon(filter), size: 18),
                  label: Text(labelFor(filter)),
                ),
            ],
            selected: {selected},
            onSelectionChanged: (selection) => onChanged(selection.single),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Row(
                children: [
                  for (final filter in filters)
                    Expanded(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (unreadCountFor(filter) > 0)
                            Positioned(
                              top: 2,
                              right: 18,
                              child: _AndroidTinyUnreadBadge(
                                text: unreadCountFor(filter) > 99
                                    ? '99+'
                                    : unreadCountFor(filter).toString(),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _androidConversationFilterIcon(_AndroidConversationFilter filter) {
  return switch (filter) {
    _AndroidConversationFilter.all => Icons.all_inbox_outlined,
    _AndroidConversationFilter.contacts => Icons.person_outline,
    _AndroidConversationFilter.groups => Icons.groups_outlined,
  };
}

class _AndroidTinyUnreadBadge extends StatelessWidget {
  const _AndroidTinyUnreadBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xffef4444),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class _AndroidConversationItem {
  const _AndroidConversationItem._({
    required this.contact,
    required this.group,
    required this.sortUnixMs,
  });

  factory _AndroidConversationItem.contact(
    AndroidContactRecord contact, {
    required int sortUnixMs,
  }) {
    return _AndroidConversationItem._(
      contact: contact,
      group: null,
      sortUnixMs: sortUnixMs,
    );
  }

  factory _AndroidConversationItem.group(
    AndroidGroupRecord group, {
    required int sortUnixMs,
  }) {
    return _AndroidConversationItem._(
      contact: null,
      group: group,
      sortUnixMs: sortUnixMs,
    );
  }

  final AndroidContactRecord? contact;
  final AndroidGroupRecord? group;
  final int sortUnixMs;

  String get title => group?.displayName ?? contact?.displayLabel ?? '';
}

class _AndroidConversationListView extends StatelessWidget {
  const _AndroidConversationListView({
    super.key,
    required this.items,
    required this.selectedContactKeyId,
    required this.selectedGroupId,
    required this.contactUnreadCountFor,
    required this.groupUnreadCountFor,
    required this.contactTitleFor,
    required this.contactSubtitleFor,
    required this.contactAvatarSeedFor,
    required this.groupTitleFor,
    required this.groupSubtitleFor,
    required this.groupPolicyLabelFor,
    required this.groupPolicyIconFor,
    required this.onOpenContact,
    required this.onOpenGroup,
    required this.onEditContact,
    required this.onDeleteContact,
    required this.busy,
  });

  final List<_AndroidConversationItem> items;
  final String? selectedContactKeyId;
  final String? selectedGroupId;
  final int Function(AndroidContactRecord) contactUnreadCountFor;
  final int Function(AndroidGroupRecord) groupUnreadCountFor;
  final String Function(AndroidContactRecord) contactTitleFor;
  final String Function(AndroidContactRecord) contactSubtitleFor;
  final String Function(AndroidContactRecord) contactAvatarSeedFor;
  final String Function(AndroidGroupRecord) groupTitleFor;
  final String Function(AndroidGroupRecord) groupSubtitleFor;
  final String Function(AndroidGroupRecord) groupPolicyLabelFor;
  final IconData Function(AndroidGroupRecord) groupPolicyIconFor;
  final ValueChanged<AndroidContactRecord> onOpenContact;
  final ValueChanged<AndroidGroupRecord> onOpenGroup;
  final ValueChanged<AndroidContactRecord> onEditContact;
  final ValueChanged<AndroidContactRecord> onDeleteContact;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        final group = item.group;
        if (group != null) {
          return _AndroidGroupConversationTile(
            group: group,
            selected: selectedGroupId == group.groupId,
            unreadCount: groupUnreadCountFor(group),
            title: groupTitleFor(group),
            subtitle: groupSubtitleFor(group),
            policyLabel: groupPolicyLabelFor(group),
            policyIcon: groupPolicyIconFor(group),
            onOpen: () => onOpenGroup(group),
          );
        }
        final contact = item.contact!;
        return _AndroidContactConversationTile(
          selected: selectedContactKeyId == contact.keyId,
          unreadCount: contactUnreadCountFor(contact),
          title: contactTitleFor(contact),
          subtitle: contactSubtitleFor(contact),
          seed: contactAvatarSeedFor(contact),
          onOpen: () => onOpenContact(contact),
          onEdit: busy ? null : () => onEditContact(contact),
          onDelete: busy ? null : () => onDeleteContact(contact),
        );
      },
    );
  }
}

class _AndroidContactConversationTile extends StatelessWidget {
  const _AndroidContactConversationTile({
    required this.selected,
    required this.unreadCount,
    required this.title,
    required this.subtitle,
    required this.seed,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final bool selected;
  final int unreadCount;
  final String title;
  final String subtitle;
  final String seed;
  final VoidCallback onOpen;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffffedd5) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? const Color(0xfff97316) : const Color(0xffd9e2de),
        ),
      ),
      child: ListTile(
        onTap: onOpen,
        minVerticalPadding: 12,
        leading: _AndroidAvatarBadge(
          label: title,
          seed: seed,
          size: 48,
          count: unreadCount,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '编辑备注',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_note_outlined),
            ),
            IconButton(
              tooltip: context.l10n.deleteContact,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _AndroidGroupConversationTile extends StatelessWidget {
  const _AndroidGroupConversationTile({
    required this.group,
    required this.selected,
    required this.unreadCount,
    required this.title,
    required this.subtitle,
    required this.policyLabel,
    required this.policyIcon,
    required this.onOpen,
  });

  final AndroidGroupRecord group;
  final bool selected;
  final int unreadCount;
  final String title;
  final String subtitle;
  final String policyLabel;
  final IconData policyIcon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xffffedd5) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? const Color(0xfff97316) : const Color(0xffd9e2de),
        ),
      ),
      child: ListTile(
        onTap: onOpen,
        minVerticalPadding: 12,
        leading: _AndroidGroupAvatarBadge(
          label: title,
          seed: group.displaySeed,
          size: 48,
          count: unreadCount,
          icon: policyIcon,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
            _AndroidGroupPolicyChip(label: policyLabel, icon: policyIcon),
          ],
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _AndroidGroupPolicyChip extends StatelessWidget {
  const _AndroidGroupPolicyChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 112),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xffeef6f1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xffcfe1d7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xff315c44)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xff315c44),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidFilteredContactsEmptyState extends StatelessWidget {
  const _AndroidFilteredContactsEmptyState({
    required this.icon,
    required this.title,
  });

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: const Color(0xff8a9792)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _AndroidGroupAvatarBadge extends StatelessWidget {
  const _AndroidGroupAvatarBadge({
    required this.label,
    required this.seed,
    required this.size,
    required this.count,
    required this.icon,
  });

  final String label;
  final String seed;
  final double size;
  final int count;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final badgeText = count > 99 ? '99+' : count.toString();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _AndroidGroupAvatar(label: label, seed: seed, size: size, icon: icon),
          if (count > 0)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                constraints: BoxConstraints(
                  minWidth: size * 0.36,
                  minHeight: size * 0.36,
                ),
                padding: EdgeInsets.symmetric(horizontal: size * 0.08),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xffef4444),
                  borderRadius: BorderRadius.circular(size * 0.22),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.2,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AndroidGroupAvatar extends StatelessWidget {
  const _AndroidGroupAvatar({
    required this.label,
    required this.seed,
    required this.size,
    required this.icon,
  });

  final String label;
  final String seed;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _AndroidAvatar.colorFor(seed.isEmpty ? label : seed),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.52),
    );
  }
}

class _AndroidAvatarBadge extends StatelessWidget {
  const _AndroidAvatarBadge({
    required this.label,
    required this.seed,
    required this.size,
    required this.count,
  });

  final String label;
  final String seed;
  final double size;
  final int count;

  @override
  Widget build(BuildContext context) {
    final badgeText = count > 99 ? '99+' : count.toString();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _AndroidAvatar(label: label, seed: seed, size: size),
          if (count > 0)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                constraints: BoxConstraints(
                  minWidth: size * 0.36,
                  minHeight: size * 0.36,
                ),
                padding: EdgeInsets.symmetric(horizontal: size * 0.08),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xffef4444),
                  borderRadius: BorderRadius.circular(size * 0.22),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.2,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AndroidAvatar extends StatelessWidget {
  const _AndroidAvatar({
    required this.label,
    required this.seed,
    required this.size,
    this.fallbackIcon,
  });

  final String label;
  final String seed;
  final double size;
  final IconData? fallbackIcon;

  static const List<Color> _palette = [
    Color(0xfff97316),
    Color(0xff0f766e),
    Color(0xff2563eb),
    Color(0xff7c3aed),
    Color(0xffbe123c),
    Color(0xff15803d),
  ];

  static Color colorFor(String seed) {
    var value = 0;
    for (final code in seed.codeUnits) {
      value = (value * 31 + code) & 0x7fffffff;
    }
    return _palette[value % _palette.length];
  }

  String get _initial {
    final text = label.trim();
    if (text.isEmpty || text == '?') return '';
    return text.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final initial = _initial;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: colorFor(seed), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: initial.isEmpty
          ? Icon(
              fallbackIcon ?? Icons.person_outline,
              color: Colors.white,
              size: size * 0.52,
            )
          : Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w900,
              ),
            ),
    );
  }
}

class _EmptyActionState extends StatelessWidget {
  const _EmptyActionState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xff65716d)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xff65716d)),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AndroidGroupInviteCard extends StatelessWidget {
  const _AndroidGroupInviteCard({
    required this.title,
    required this.message,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final String title;
  final String message;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffffcf0),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe5d18b)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mark_email_unread_outlined, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: const TextStyle(color: Color(0xff4f5a56))),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy ? null : onAccept,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(
                        busy ? l10n.groupInviteBusy : l10n.acceptGroupInvite,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onDecline,
                      icon: const Icon(Icons.cancel_outlined),
                      label: Text(l10n.declineGroupInvite),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({
    required this.busy,
    required this.storeReady,
    required this.status,
    required this.storeDirController,
    required this.displayNameController,
    required this.exportPathController,
    required this.contactPathController,
    required this.importPathController,
    required this.sendRecipientController,
    required this.sendTextController,
    required this.sendOutputPathController,
    required this.storeDirHint,
    required this.exportPathHint,
    required this.contactPathHint,
    required this.importPathHint,
    required this.sendOutputPathHint,
    required this.myP2pTicketController,
    required this.peerP2pTicketController,
    required this.p2pListening,
    required this.nativeReady,
    required this.nativeError,
    required this.androidSecureStoreReady,
    required this.secureIdentityReady,
    required this.secureIdentityLabel,
    required this.onInitStore,
    required this.onResetStore,
    required this.recoveryPhraseController,
    required this.onGenerateRecoveryPhrase,
    required this.onPreviewRecoveredIdentity,
    required this.onCreateAndSaveAndroidIdentity,
    required this.onSaveRecoveredAndroidIdentity,
    required this.onLoadAndroidIdentity,
    required this.onClearAndroidIdentity,
    required this.onRefresh,
    required this.onExportContact,
    required this.onAddContact,
    required this.onImportEnvelope,
    required this.onExportEnvelope,
    required this.onStartP2p,
    required this.onStopP2p,
    required this.onCopyP2pTicket,
    required this.onSendP2p,
  });

  final bool busy;
  final bool storeReady;
  final bool p2pListening;
  final bool nativeReady;
  final bool androidSecureStoreReady;
  final bool secureIdentityReady;
  final String status;
  final String? nativeError;
  final String? secureIdentityLabel;
  final TextEditingController storeDirController;
  final TextEditingController displayNameController;
  final TextEditingController exportPathController;
  final TextEditingController contactPathController;
  final TextEditingController importPathController;
  final TextEditingController sendRecipientController;
  final TextEditingController sendTextController;
  final TextEditingController sendOutputPathController;
  final String storeDirHint;
  final String exportPathHint;
  final String contactPathHint;
  final String importPathHint;
  final String sendOutputPathHint;
  final TextEditingController myP2pTicketController;
  final TextEditingController peerP2pTicketController;
  final TextEditingController recoveryPhraseController;
  final VoidCallback onInitStore;
  final VoidCallback onResetStore;
  final VoidCallback onGenerateRecoveryPhrase;
  final VoidCallback onPreviewRecoveredIdentity;
  final VoidCallback onCreateAndSaveAndroidIdentity;
  final VoidCallback onSaveRecoveredAndroidIdentity;
  final VoidCallback onLoadAndroidIdentity;
  final VoidCallback onClearAndroidIdentity;
  final VoidCallback onRefresh;
  final VoidCallback onExportContact;
  final VoidCallback onAddContact;
  final VoidCallback onImportEnvelope;
  final VoidCallback onExportEnvelope;
  final VoidCallback onStartP2p;
  final VoidCallback onStopP2p;
  final VoidCallback onCopyP2pTicket;
  final VoidCallback onSendP2p;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 330,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _EnvelopeBrandMark(size: 42),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Envelope',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              _FieldLabel('Store'),
              TextField(
                controller: storeDirController,
                minLines: 1,
                maxLines: 2,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.folder_outlined),
                  hintText: storeDirHint,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: displayNameController,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.badge_outlined),
                  labelText: '显示名',
                  hintText: _defaultDisplayName,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy ? null : onInitStore,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('初始化'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '刷新',
                    onPressed: busy ? null : onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : onResetStore,
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('重新生成用户'),
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _StatusLine(status: status, ready: storeReady),
              const SizedBox(height: 24),
              _CommandGroup(
                title: 'Rust Core',
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: recoveryPhraseController,
                      minLines: 2,
                      maxLines: 4,
                      keyboardType: TextInputType.visiblePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.key_outlined),
                        labelText: 'BIP39 24 词恢复词',
                        hintText: '输入 24 个恢复词，或点击生成恢复词',
                      ),
                    ),
                  ),
                  _ActionButton(
                    icon: Icons.generating_tokens_outlined,
                    label: '生成恢复词',
                    enabled: nativeReady && !busy,
                    onPressed: onGenerateRecoveryPhrase,
                  ),
                  _ActionButton(
                    icon: Icons.manage_search_outlined,
                    label: '恢复身份预览',
                    enabled: nativeReady && !busy,
                    onPressed: onPreviewRecoveredIdentity,
                  ),
                  if (!nativeReady)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        nativeError == null
                            ? 'Rust native core 未加载'
                            : 'Rust native core 未加载：$nativeError',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandGroup(
                title: 'Android Store',
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(
                          secureIdentityReady
                              ? Icons.verified_user_outlined
                              : Icons.lock_outline,
                          size: 18,
                          color: secureIdentityReady
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            androidSecureStoreReady
                                ? secureIdentityLabel ?? '尚未保存本机身份'
                                : '仅 Android 可用',
                            style: TextStyle(
                              color: secureIdentityReady
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ActionButton(
                    icon: Icons.add_moderator_outlined,
                    label: '创建并加密保存身份',
                    enabled: androidSecureStoreReady && nativeReady && !busy,
                    onPressed: onCreateAndSaveAndroidIdentity,
                  ),
                  _ActionButton(
                    icon: Icons.restore_outlined,
                    label: '从恢复词保存身份',
                    enabled: androidSecureStoreReady && nativeReady && !busy,
                    onPressed: onSaveRecoveredAndroidIdentity,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.visibility_outlined,
                          label: '读取',
                          enabled: androidSecureStoreReady && !busy,
                          onPressed: onLoadAndroidIdentity,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.delete_outline,
                          label: '清除',
                          enabled: androidSecureStoreReady && !busy,
                          onPressed: onClearAndroidIdentity,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandGroup(
                title: 'P2P',
                children: [
                  _TicketField(
                    controller: myP2pTicketController,
                    label: '我的 ticket',
                    readOnly: true,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: p2pListening
                              ? Icons.stop_circle_outlined
                              : Icons.sensors,
                          label: p2pListening ? '停止监听' : '启动监听',
                          enabled: storeReady && !busy,
                          onPressed: p2pListening ? onStopP2p : onStartP2p,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: '复制直连调试信息',
                        onPressed: myP2pTicketController.text.trim().isEmpty
                            ? null
                            : onCopyP2pTicket,
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandGroup(
                title: '联系人',
                children: [
                  _PathField(
                    controller: exportPathController,
                    icon: Icons.ios_share,
                    label: '导出路径',
                    hintText: exportPathHint,
                  ),
                  _ActionButton(
                    icon: Icons.ios_share,
                    label: '导出我的 contact',
                    enabled: storeReady && !busy,
                    onPressed: onExportContact,
                  ),
                  _PathField(
                    controller: contactPathController,
                    icon: Icons.person_outline,
                    label: '联系人文件',
                    hintText: contactPathHint,
                  ),
                  _ActionButton(
                    icon: Icons.person_add_alt,
                    label: '添加联系人',
                    enabled: storeReady && !busy,
                    onPressed: onAddContact,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandGroup(
                title: '发送',
                children: [
                  _PathField(
                    controller: sendRecipientController,
                    icon: Icons.person_search_outlined,
                    label: '收件人 key id 或显示名',
                    hintText: '点击联系人列表选择，或输入 key id / 显示名',
                  ),
                  _PathField(
                    controller: sendOutputPathController,
                    icon: Icons.output_outlined,
                    label: '输出离线信封路径',
                    hintText: sendOutputPathHint,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: sendTextController,
                      minLines: 3,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.edit_note),
                        labelText: '消息内容',
                        hintText: _defaultDesktopMessageHint,
                      ),
                    ),
                  ),
                  _ActionButton(
                    icon: Icons.send_outlined,
                    label: '导出离线信封',
                    enabled: storeReady && !busy,
                    onPressed: onExportEnvelope,
                  ),
                  _TicketField(
                    controller: peerP2pTicketController,
                    label: '对方直连调试信息',
                    hintText: '粘贴对方直连调试信息',
                  ),
                  _ActionButton(
                    icon: Icons.hub_outlined,
                    label: 'P2P 发送',
                    enabled: storeReady && !busy,
                    onPressed: onSendP2p,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CommandGroup(
                title: '导入',
                children: [
                  _PathField(
                    controller: importPathController,
                    icon: Icons.attach_file,
                    label: '导入路径',
                    hintText: importPathHint,
                  ),
                  _ActionButton(
                    icon: Icons.description_outlined,
                    label: '导入离线信封',
                    enabled: storeReady && !busy,
                    onPressed: onImportEnvelope,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '开发版 store 未加密',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _androidSavedFilePathForMessage(AndroidMessageRecord message) {
  final attachmentPath = message.attachmentPath?.trim();
  if (attachmentPath != null && attachmentPath.isNotEmpty) {
    return attachmentPath;
  }
  return _androidSavedFilePathFromText(message.text);
}

bool _androidMessageHasMediaAttachmentPreview(AndroidMessageRecord message) {
  final mime = message.attachmentMime?.trim().toLowerCase() ?? '';
  if (mime.startsWith('image/') || mime.startsWith('video/')) {
    return true;
  }

  final path = _androidSavedFilePathForMessage(message)?.toLowerCase() ?? '';
  return const {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.mp4',
    '.mov',
    '.m4v',
    '.mkv',
    '.webm',
    '.avi',
    '.3gp',
  }.any(path.endsWith);
}

bool _androidMessageIsVideoAttachment(AndroidMessageRecord message) {
  final mime = message.attachmentMime?.trim().toLowerCase() ?? '';
  if (mime.startsWith('video/')) return true;
  final path = _androidSavedFilePathForMessage(message)?.toLowerCase() ?? '';
  return const {
    '.mp4',
    '.mov',
    '.m4v',
    '.mkv',
    '.webm',
    '.avi',
    '.3gp',
  }.any(path.endsWith);
}

String? _androidSavedFilePathFromText(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final path = _androidSavedFilePathFromLine(line);
    if (path != null) return path;
  }
  return null;
}

String? _androidSavedFilePathFromLine(String line) {
  const legacyPrefix = '保存路径：';
  const detailPrefix = 'path:';
  final trimmed = line.trim();
  final path = trimmed.startsWith(legacyPrefix)
      ? trimmed.substring(legacyPrefix.length).trim()
      : trimmed.toLowerCase().startsWith(detailPrefix)
      ? trimmed.substring(detailPrefix.length).trim()
      : trimmed;
  if (path.isEmpty || !_looksLikeAndroidSavedFilePath(path)) return null;
  return path;
}

bool _looksLikeAndroidSavedFilePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('Download/Envelope/') ||
      normalized.startsWith('Downloads/Envelope/') ||
      normalized.startsWith('/sdcard/Envelope/') ||
      normalized.startsWith('/sdcard/Download/Envelope/') ||
      normalized.startsWith('/storage/') ||
      normalized.startsWith('content://');
}

String _androidReadableFolderPath(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) return 'Download/Envelope';
  const storageDownloadPrefix = '/storage/emulated/0/Download/';
  if (normalized.startsWith(storageDownloadPrefix)) {
    return 'Download/${normalized.substring(storageDownloadPrefix.length)}';
  }
  const sdcardDownloadPrefix = '/sdcard/Download/';
  if (normalized.startsWith(sdcardDownloadPrefix)) {
    return 'Download/${normalized.substring(sdcardDownloadPrefix.length)}';
  }
  return normalized;
}

String _androidUserFacingMessageText(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.length == 1) {
    final converted = _androidConvertEngineeringProgressLine(lines.single);
    if (converted != null) return converted;
  }
  final visible = <String>[];
  for (final line in lines) {
    final converted = _androidConvertEngineeringProgressLine(line);
    if (converted != null) {
      visible.add(converted);
      continue;
    }
    if (_androidIsEngineeringMessageLine(line)) continue;
    visible.add(line);
  }
  final normalized = visible.join('\n').trim();
  return normalized.isEmpty ? text : normalized;
}

String _androidMessageBodyText(String displayText) {
  final visible = const LineSplitter()
      .convert(displayText)
      .where((line) => !RegExp(r'^接收中\s+\d+%$').hasMatch(line.trim()))
      .map((line) {
        final match = RegExp(r'^(文件接收中)\s+\d+%$').firstMatch(line.trim());
        return match?.group(1) ?? line;
      })
      .toList();
  final normalized = visible.join('\n').trim();
  return normalized.isEmpty ? '文件接收中' : normalized;
}

String? _androidConvertEngineeringProgressLine(String line) {
  final trimmed = line.trim();
  final chunkMatch = RegExp(
    r'^文件分片已接收：\s*(\d+)\s*/\s*(\d+)$',
  ).firstMatch(trimmed);
  if (chunkMatch != null) {
    return _androidReceivingProgressLabel(
      int.tryParse(chunkMatch.group(1) ?? '') ?? 0,
      int.tryParse(chunkMatch.group(2) ?? '') ?? 1,
    );
  }
  final manifestMatch = RegExp(
    r'^文件\s+manifest\s+已接收，等待分片：\s*(\d+)\s*/\s*(\d+)$',
  ).firstMatch(trimmed);
  if (manifestMatch != null) {
    return _androidReceivingProgressLabel(
      int.tryParse(manifestMatch.group(1) ?? '') ?? 0,
      int.tryParse(manifestMatch.group(2) ?? '') ?? 1,
    );
  }
  return null;
}

bool _androidIsEngineeringMessageLine(String line) {
  final trimmed = line.trim();
  final lower = trimmed.toLowerCase();
  return trimmed.startsWith('分片：') || lower.startsWith('chunks:');
}

String _androidReceivingProgressLabel(int received, int total) {
  final safeTotal = max(total, 1);
  final percent = ((received.clamp(0, safeTotal) / safeTotal) * 100)
      .round()
      .clamp(0, 99);
  return '接收中 $percent%';
}

bool _androidTextLooksLikeFileMessage(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('文件：') || trimmed.startsWith('文件接收中');
}

_AndroidMessageProgressInfo? _androidMessageProgressInfo(
  AndroidMessageRecord message,
  String displayText,
) {
  final receivingMatch = RegExp(r'接收中\s+(\d+)%').firstMatch(displayText);
  if (receivingMatch != null) {
    final percent = int.tryParse(receivingMatch.group(1) ?? '') ?? 0;
    return _AndroidMessageProgressInfo(
      label: '接收中 $percent%',
      value: (percent.clamp(0, 100)) / 100,
    );
  }
  if (message.isOutgoing &&
      _androidTextLooksLikeFileMessage(displayText) &&
      message.deliveryStatus == AndroidDeliveryStatus.created) {
    return const _AndroidMessageProgressInfo(label: '发送中');
  }
  return null;
}

String _formatAndroidUnixMsWithMillis(int unixMs) {
  if (unixMs <= 0) return '';
  final timestamp = DateTime.fromMillisecondsSinceEpoch(unixMs).toLocal();
  return '${timestamp.year}-${_twoAndroidDigits(timestamp.month)}-'
      '${_twoAndroidDigits(timestamp.day)} '
      '${_twoAndroidDigits(timestamp.hour)}:'
      '${_twoAndroidDigits(timestamp.minute)}:'
      '${_twoAndroidDigits(timestamp.second)}.'
      '${_threeAndroidDigits(timestamp.millisecond)}';
}

String _twoAndroidDigits(int value) => value.toString().padLeft(2, '0');

String _threeAndroidDigits(int value) => value.toString().padLeft(3, '0');

String _formatAndroidByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  final gib = mib / 1024;
  return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GB';
}

class _AndroidMessageProgressInfo {
  const _AndroidMessageProgressInfo({required this.label, this.value});

  final String label;
  final double? value;
}

class _AndroidMessageText extends StatelessWidget {
  const _AndroidMessageText({
    required this.text,
    required this.savedPath,
    required this.onOpenSavedFile,
    this.onOpenSavedFileLocation,
    this.attachmentDeleted = false,
    this.openSavedFileTooltip = '打开保存位置',
    this.openSavedFileIcon = Icons.folder_open_outlined,
  });

  final String text;
  final String? savedPath;
  final VoidCallback? onOpenSavedFile;
  final VoidCallback? onOpenSavedFileLocation;
  final bool attachmentDeleted;
  final String openSavedFileTooltip;
  final IconData openSavedFileIcon;

  @override
  Widget build(BuildContext context) {
    final path = savedPath;
    final openSavedFile = onOpenSavedFile;
    if (attachmentDeleted) {
      final lines = const LineSplitter()
          .convert(text)
          .where((line) => _androidSavedFilePathFromLine(line) == null)
          .toList(growable: false);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            if (line.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SelectableText(
                  line,
                  style: const TextStyle(fontSize: 14, height: 1.35),
                ),
              ),
          const Text(
            '文件已删除',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xff9a3412),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );
    }
    if (path == null || openSavedFile == null) {
      return SelectableText(
        text,
        style: const TextStyle(fontSize: 14, height: 1.35),
      );
    }

    final lines = const LineSplitter().convert(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < lines.length; index += 1) ...[
          if (_androidSavedFilePathFromLine(lines[index]) == path)
            _AndroidSavedFilePathLine(
              text: path,
              onOpenSavedFile: openSavedFile,
              onOpenSavedFileLocation: onOpenSavedFileLocation,
              tooltip: openSavedFileTooltip,
              icon: openSavedFileIcon,
            )
          else
            SelectableText(
              lines[index],
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
          if (index != lines.length - 1) const SizedBox(height: 2),
        ],
      ],
    );
  }
}

class _AndroidSavedFilePathLine extends StatelessWidget {
  const _AndroidSavedFilePathLine({
    required this.text,
    required this.onOpenSavedFile,
    this.onOpenSavedFileLocation,
    this.fontSize = 14,
    this.tooltip = '打开保存位置',
    this.icon = Icons.folder_open_outlined,
  });

  final String text;
  final VoidCallback onOpenSavedFile;
  final VoidCallback? onOpenSavedFileLocation;
  final double fontSize;
  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: SelectableText(
            text,
            onTap: onOpenSavedFile,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.35,
              color: color,
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          onPressed: onOpenSavedFile,
          icon: Icon(icon, size: 18),
        ),
        if (onOpenSavedFileLocation != null)
          IconButton(
            tooltip: '打开保存位置',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            padding: EdgeInsets.zero,
            onPressed: onOpenSavedFileLocation,
            icon: const Icon(Icons.folder_open_outlined, size: 18),
          ),
      ],
    );
  }
}

class _AndroidMediaAttachmentPreview extends StatelessWidget {
  const _AndroidMediaAttachmentPreview({
    required this.message,
    required this.loadPreview,
    required this.onOpenFile,
  });

  final AndroidMessageRecord message;
  final Future<AndroidSavedFilePreview?> Function(AndroidMessageRecord)
  loadPreview;
  final VoidCallback? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final isVideo = _androidMessageIsVideoAttachment(message);
    final borderRadius = BorderRadius.circular(6);
    return ClipRRect(
      borderRadius: borderRadius,
      child: Material(
        color: const Color(0xffe8efec),
        child: InkWell(
          onTap: onOpenFile,
          child: SizedBox(
            width: double.infinity,
            height: 168,
            child: FutureBuilder<AndroidSavedFilePreview?>(
              future: loadPreview(message),
              builder: (context, snapshot) {
                final preview = snapshot.data;
                final child = preview == null
                    ? Center(
                        child: Icon(
                          isVideo
                              ? Icons.movie_creation_outlined
                              : Icons.image_outlined,
                          size: 38,
                          color: const Color(0xff65716d),
                        ),
                      )
                    : Image.memory(
                        preview.bytes,
                        width: double.infinity,
                        height: 168,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      );
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    child,
                    if (isVideo)
                      Center(
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.48),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AndroidMessageTile extends StatelessWidget {
  const _AndroidMessageTile({
    required this.message,
    required this.peerLabel,
    this.showIncomingPeerLabel = false,
    this.showEnvelopeAction = false,
    this.selectionMode = false,
    this.selected = false,
    this.canSelect = true,
    this.onTap,
    this.onLongPress,
    this.onOpenSavedFile,
    this.onOpenSavedFileLocation,
    this.onLoadSavedFilePreview,
    this.extraContent,
  });

  final AndroidMessageRecord message;
  final String peerLabel;
  final bool showIncomingPeerLabel;
  final bool showEnvelopeAction;
  final bool selectionMode;
  final bool selected;
  final bool canSelect;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<AndroidMessageRecord>? onOpenSavedFile;
  final ValueChanged<AndroidMessageRecord>? onOpenSavedFileLocation;
  final Future<AndroidSavedFilePreview?> Function(AndroidMessageRecord)?
  onLoadSavedFilePreview;
  final Widget? extraContent;

  String get _deliveryLabel {
    if (!message.isOutgoing) return '';
    return switch (message.deliveryStatus) {
      AndroidDeliveryStatus.created => '发送中',
      AndroidDeliveryStatus.pending => '待重试',
      AndroidDeliveryStatus.sent => '已送达',
      AndroidDeliveryStatus.legacySent => '历史发送状态（未验证）',
      AndroidDeliveryStatus.rejected => '接收方已拒绝',
      AndroidDeliveryStatus.expired => '已过期',
      AndroidDeliveryStatus.serverMailbox => '等待接收',
      _ => '已发送',
    };
  }

  String get _timestampLabel {
    final unixMs = message.createdAtUnixMs;
    if (unixMs <= 0) return '';
    final timestamp = DateTime.fromMillisecondsSinceEpoch(unixMs).toLocal();
    final now = DateTime.now();
    if (timestamp.year == now.year &&
        timestamp.month == now.month &&
        timestamp.day == now.day) {
      return _formatTimeWithMillis(timestamp);
    }
    if (timestamp.year == now.year) {
      return '${_twoDigits(timestamp.month)}-${_twoDigits(timestamp.day)} '
          '${_formatTimeWithMillis(timestamp)}';
    }
    return '${timestamp.year}-${_twoDigits(timestamp.month)}-'
        '${_twoDigits(timestamp.day)} ${_formatTimeWithMillis(timestamp)}';
  }

  String _formatTimeWithMillis(DateTime timestamp) =>
      '${_twoDigits(timestamp.hour)}:${_twoDigits(timestamp.minute)}:'
      '${_twoDigits(timestamp.second)}.${_threeDigits(timestamp.millisecond)}';

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  String _threeDigits(int value) => value.toString().padLeft(3, '0');

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayText = _androidUserFacingMessageText(message.text);
    final bodyText = _androidMessageBodyText(displayText);
    final progress = _androidMessageProgressInfo(message, displayText);
    final showDeliveryStatus = message.isOutgoing && progress == null;
    final shouldShowIncomingPeerLabel =
        showIncomingPeerLabel && peerLabel.trim().isNotEmpty;
    final baseColor = message.isOutgoing
        ? const Color(0xffeaf2ef)
        : Colors.white;
    final attachmentDeleted = message.attachmentDeleted;
    final savedPath = attachmentDeleted
        ? null
        : _androidSavedFilePathForMessage(message);
    final canOpenSavedFile = savedPath != null && !attachmentDeleted;
    final showMediaPreview =
        canOpenSavedFile &&
        onLoadSavedFilePreview != null &&
        _androidMessageHasMediaAttachmentPreview(message);
    final openSavedFile = selectionMode || !canOpenSavedFile
        ? null
        : onOpenSavedFile;
    final openSavedFileLocation = selectionMode || !canOpenSavedFile
        ? null
        : onOpenSavedFileLocation;
    final primarySavedFileAction = openSavedFile;
    final secondarySavedFileLocationAction = openSavedFileLocation;
    final selectionCheckbox = selectionMode
        ? <Widget>[
            SizedBox(
              width: 36,
              height: 36,
              child: Checkbox(
                value: selected,
                onChanged: canSelect && onTap != null
                    ? (_) => onTap?.call()
                    : null,
              ),
            ),
            const SizedBox(width: 4),
          ]
        : const <Widget>[];
    final header = message.isOutgoing
        ? Row(
            children: [
              ...selectionCheckbox,
              Icon(
                Icons.north_east_outlined,
                size: 16,
                color: canSelect
                    ? colorScheme.primary
                    : const Color(0xff8b9692),
              ),
              const SizedBox(width: 6),
              const Spacer(),
              if (_timestampLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  _timestampLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff65716d),
                  ),
                ),
              ],
            ],
          )
        : Row(
            children: [
              ...selectionCheckbox,
              if (_timestampLabel.isNotEmpty)
                Text(
                  _timestampLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff65716d),
                  ),
                ),
              if (shouldShowIncomingPeerLabel) ...[
                if (_timestampLabel.isNotEmpty) const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '接收自 $peerLabel',
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 6),
              Icon(
                Icons.south_west_outlined,
                size: 16,
                color: canSelect
                    ? colorScheme.primary
                    : const Color(0xff8b9692),
              ),
            ],
          );
    final card = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected ? const Color(0xffd7eee7) : baseColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? colorScheme.primary : const Color(0xffd9e2de),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 8),
          if (showMediaPreview) ...[
            _AndroidMediaAttachmentPreview(
              message: message,
              loadPreview: onLoadSavedFilePreview!,
              onOpenFile: primarySavedFileAction == null
                  ? null
                  : () => primarySavedFileAction(message),
            ),
            const SizedBox(height: 8),
          ],
          _AndroidMessageText(
            text: bodyText,
            savedPath: savedPath,
            onOpenSavedFile: primarySavedFileAction == null
                ? null
                : () => primarySavedFileAction(message),
            onOpenSavedFileLocation: secondarySavedFileLocationAction == null
                ? null
                : () => secondarySavedFileLocationAction(message),
            attachmentDeleted: attachmentDeleted,
            openSavedFileTooltip: '打开文件',
            openSavedFileIcon: Icons.file_open_outlined,
          ),
          if (extraContent != null) ...[
            const SizedBox(height: 10),
            extraContent!,
          ],
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: progress.value,
                backgroundColor: const Color(0xffe3ebe7),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              progress.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xff65716d)),
            ),
          ],
          if (showDeliveryStatus) ...[
            const SizedBox(height: 6),
            Text(
              _deliveryLabel,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xff65716d)),
            ),
          ],
          if (selectionMode && !canSelect) ...[
            const SizedBox(height: 6),
            const Text(
              '无离线信封数据',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xff8b5e13),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (message.isOutgoing && showEnvelopeAction) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: message.opaqueEnvelopeBase64),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制离线信封'),
            ),
          ],
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: message.isOutgoing
          ? card
          : LayoutBuilder(
              builder: (context, constraints) {
                return Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: max(280.0, constraints.maxWidth * 0.86),
                    ),
                    child: card,
                  ),
                );
              },
            ),
    );
  }
}

class _MainWorkspace extends StatelessWidget {
  const _MainWorkspace({
    required this.busy,
    required this.details,
    required this.contacts,
    required this.messages,
    required this.onSelectContact,
  });

  final bool busy;
  final String details;
  final List<ContactRow> contacts;
  final List<MessageRow> messages;
  final ValueChanged<ContactRow> onSelectContact;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          alignment: Alignment.centerLeft,
          color: Colors.white,
          child: Row(
            children: [
              const Text(
                '本地消息',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 16),
              _Metric(label: '联系人', value: contacts.length.toString()),
              const SizedBox(width: 8),
              _Metric(label: '消息', value: messages.length.toString()),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: _ContactsPanel(
                    contacts: contacts,
                    onSelectContact: onSelectContact,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(child: _MessagesPanel(messages: messages)),
              ],
            ),
          ),
        ),
        if (details.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
            color: const Color(0xffeaf2ef),
            child: SelectableText(
              details,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _ContactsPanel extends StatelessWidget {
  const _ContactsPanel({required this.contacts, required this.onSelectContact});

  final List<ContactRow> contacts;
  final ValueChanged<ContactRow> onSelectContact;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: '联系人',
      icon: Icons.people_alt_outlined,
      child: contacts.isEmpty
          ? const _EmptyState(text: '暂无联系人')
          : ListView.separated(
              itemCount: contacts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final contact = contacts[index];
                return ListTile(
                  dense: true,
                  onTap: () => onSelectContact(contact),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: const Color(0xffdbe8e2),
                    child: Text(
                      contact.name.characters.first.toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xff24584e),
                      ),
                    ),
                  ),
                  title: Text(
                    contact.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    contact.keyId,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                );
              },
            ),
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  const _MessagesPanel({required this.messages});

  final List<MessageRow> messages;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: '消息',
      icon: Icons.forum_outlined,
      child: messages.isEmpty
          ? const _EmptyState(text: '暂无消息')
          : ListView.separated(
              padding: const EdgeInsets.only(top: 4),
              itemCount: messages.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final message = messages[index];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xffd9e2de)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            message.direction == 'Outgoing'
                                ? '我'
                                : message.sender,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            message.timestamp,
                            style: const TextStyle(
                              color: Color(0xff65716d),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        message.text,
                        style: const TextStyle(fontSize: 14, height: 1.35),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffbfcfa),
        border: Border.all(color: const Color(0xffd9e2de)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _CommandGroup extends StatelessWidget {
  const _CommandGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_FieldLabel(title), const SizedBox(height: 8), ...children],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton.icon(
        onPressed: enabled && !busy ? onPressed : null,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
        label: Align(alignment: Alignment.centerLeft, child: Text(label)),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(42),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class _AboutInfoRow extends StatelessWidget {
  const _AboutInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xfffbfcfa),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9e2de)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xff35544a)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidUserManualPage extends StatefulWidget {
  const _AndroidUserManualPage();

  @override
  State<_AndroidUserManualPage> createState() => _AndroidUserManualPageState();
}

class _AndroidUserManualPageState extends State<_AndroidUserManualPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _error = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = error.description;
            });
          },
        ),
      );
    unawaited(_loadBundledManual());
  }

  Future<void> _loadBundledManual() async {
    try {
      await _controller.loadFlutterAsset(_androidUserManualAsset);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(l10n.openUserManual),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xff24150f),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      body: Stack(
        children: [
          if (_error == null)
            WebViewWidget(controller: _controller)
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 42,
                      color: Color(0xff9a3412),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '无法打开内置用户手册',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff65716d),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

class _AboutVersionBlock extends StatelessWidget {
  const _AboutVersionBlock({
    required this.version,
    required this.signingFingerprint,
  });

  final String version;
  final String signingFingerprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffbfcfa),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9e2de)),
      ),
      child: Row(
        children: [
          const _EnvelopeBrandMark(size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.aboutProductName,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  version,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff65716d),
                  ),
                ),
                if (signingFingerprint.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.signingFingerprint,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff65716d),
                    ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    signingFingerprint,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 10,
                      color: Color(0xff65716d),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.controller,
    required this.icon,
    required this.label,
    this.hintText,
  });

  final TextEditingController controller;
  final IconData icon;
  final String label;
  final String? hintText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 2,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          prefixIcon: Icon(icon),
          labelText: label,
          hintText: hintText,
        ),
      ),
    );
  }
}

class _TicketField extends StatelessWidget {
  const _TicketField({
    required this.controller,
    required this.label,
    this.readOnly = false,
    this.hintText,
  });

  final TextEditingController controller;
  final String label;
  final bool readOnly;
  final String? hintText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        minLines: 2,
        maxLines: 4,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.key_outlined),
          labelText: label,
          hintText: hintText,
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status, required this.ready});

  final String status;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          ready ? Icons.check_circle : Icons.info_outline,
          color: ready ? const Color(0xff24785f) : const Color(0xff8a6a18),
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            status,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _EnvelopeBrandMark extends StatelessWidget {
  const _EnvelopeBrandMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final badgeSize = size * 0.42;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xfff97316),
                borderRadius: BorderRadius.circular(size * 0.22),
              ),
              child: Icon(
                Icons.mail_outline_rounded,
                color: Colors.white,
                size: size * 0.64,
              ),
            ),
          ),
          Positioned(
            right: -size * 0.03,
            bottom: -size * 0.03,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                color: const Color(0xff1f3a5f),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: size * 0.07),
              ),
              child: Icon(
                Icons.lock_rounded,
                color: Colors.white,
                size: size * 0.23,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffd1ded8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(color: Color(0xff66736f), fontSize: 13),
      ),
    );
  }
}

class EnvelopeCli {
  EnvelopeCli(this.repoRoot);

  final Directory repoRoot;

  Future<Directory?> backupStoreIfExists(Directory dir) async {
    final storeFile = File(p.join(dir.path, 'store.json'));
    if (!storeFile.existsSync()) {
      return null;
    }

    final parent = dir.parent;
    final name = p.basename(dir.path);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    var backup = Directory(p.join(parent.path, '$name.backup.$stamp'));
    var index = 1;
    while (backup.existsSync()) {
      backup = Directory(p.join(parent.path, '$name.backup.$stamp.$index'));
      index += 1;
    }
    await dir.rename(backup.path);
    return backup;
  }

  Future<void> initStore(Directory dir, String name) async {
    await _run(['store', 'init', '--dir', dir.path, '--name', name]);
  }

  Future<void> exportContact(Directory dir, File out) async {
    await _run([
      'store',
      'export-contact',
      '--dir',
      dir.path,
      '--out',
      out.path,
    ]);
  }

  Future<void> addContact(Directory dir, File contact) async {
    await _run([
      'store',
      'add-contact',
      '--dir',
      dir.path,
      '--contact',
      contact.path,
    ]);
  }

  Future<List<ContactRow>> listContacts(Directory dir) async {
    final output = await _run(['store', 'list-contacts', '--dir', dir.path]);
    return output
        .splitLines()
        .where((line) => line.trim().isNotEmpty)
        .map(ContactRow.parse)
        .toList();
  }

  Future<String> importEnvelope(Directory dir, File input) async {
    return _run([
      'store',
      'import-envelope',
      '--dir',
      dir.path,
      '--input',
      input.path,
    ]);
  }

  Future<String> exportEnvelope(
    Directory dir,
    String recipient,
    String text,
    File out,
  ) async {
    return _run([
      'store',
      'export-envelope',
      '--dir',
      dir.path,
      '--recipient',
      recipient,
      '--text',
      text,
      '--out',
      out.path,
    ]);
  }

  Future<Process> startP2pServe(Directory dir) {
    final invocation = _invocation(['store', 'p2p-serve', '--dir', dir.path]);
    return Process.start(
      invocation.executable,
      invocation.arguments,
      workingDirectory: repoRoot.path,
    );
  }

  Future<String> sendP2p(
    Directory dir,
    String recipient,
    String text,
    String ticket,
  ) async {
    return _run([
      'store',
      'p2p-send',
      '--dir',
      dir.path,
      '--recipient',
      recipient,
      '--text',
      text,
      '--ticket',
      ticket,
    ]);
  }

  Future<List<MessageRow>> listMessages(Directory dir) async {
    final output = await _run(['store', 'list-messages', '--dir', dir.path]);
    return output
        .splitLines()
        .where((line) => line.trim().isNotEmpty)
        .map(MessageRow.parse)
        .toList();
  }

  Future<String> _run(List<String> envelopeArgs) async {
    final invocation = _invocation(envelopeArgs);
    final result = await Process.run(
      invocation.executable,
      invocation.arguments,
      workingDirectory: repoRoot.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (result.exitCode != 0) {
      throw CliException(
        [
          if (stdout.isNotEmpty) stdout,
          if (stderr.isNotEmpty) stderr,
        ].join('\n'),
      );
    }
    return stdout;
  }

  _CliInvocation _invocation(List<String> envelopeArgs) {
    final exeName = _exeName('envelope-cli');
    final appDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      p.join(appDir.path, exeName),
      p.join(appDir.path, 'bin', exeName),
      p.join(repoRoot.path, exeName),
      p.join(repoRoot.path, 'bin', exeName),
      p.join(repoRoot.path, 'target', 'release', exeName),
      p.join(repoRoot.path, 'target', 'debug', exeName),
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return _CliInvocation(candidate, envelopeArgs);
      }
    }
    return _CliInvocation('cargo', [
      'run',
      '-q',
      '-p',
      'envelope-cli',
      '--',
      ...envelopeArgs,
    ]);
  }
}

class _CliInvocation {
  const _CliInvocation(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class _DecodedAndroidIntroQrPayload {
  const _DecodedAndroidIntroQrPayload({
    required this.bundleJson,
    this.sessionId,
    this.serverUrl,
  });

  final String bundleJson;
  final String? sessionId;
  final String? serverUrl;
}

class _AndroidSealResult {
  const _AndroidSealResult({
    required this.label,
    required this.path,
    required this.record,
    required this.details,
  });

  final String label;
  final String path;
  final AndroidSealedEnvelopeRecord record;
  final String details;
}

class _AndroidEnvelopeImportResult {
  const _AndroidEnvelopeImportResult({
    required this.message,
    required this.duplicate,
    this.receiptEnvelopeId,
  });

  final AndroidMessageRecord message;
  final bool duplicate;
  final String? receiptEnvelopeId;
}

class _AndroidDecryptedOpaquePayload {
  const _AndroidDecryptedOpaquePayload({
    required this.payload,
    required this.contact,
    required this.envelopeBase64,
  });

  final NativeInboundOpaquePayload payload;
  final AndroidContactRecord contact;
  final String envelopeBase64;
}

class _AndroidInboundPayloadMessageContent {
  const _AndroidInboundPayloadMessageContent({
    required this.text,
    this.attachmentUri,
    this.attachmentPath,
    this.attachmentMime,
  });

  final String text;
  final String? attachmentUri;
  final String? attachmentPath;
  final String? attachmentMime;
}

class _AndroidEnvelopeToSend {
  const _AndroidEnvelopeToSend({
    required this.envelopeId,
    required this.envelopeBase64,
    required this.ordinal,
  });

  final String envelopeId;
  final String envelopeBase64;
  final int ordinal;
}

class _AndroidFileManifest {
  const _AndroidFileManifest({
    required this.transferId,
    required this.filename,
    required this.mime,
    required this.totalSize,
    required this.chunkSize,
    required this.chunkCount,
    required this.fileSha256,
    required this.chunkSha256,
  });

  final String transferId;
  final String filename;
  final String mime;
  final int totalSize;
  final int chunkSize;
  final int chunkCount;
  final String fileSha256;
  final List<String> chunkSha256;
}

class _AndroidPickedFileScan {
  const _AndroidPickedFileScan({
    required this.totalSize,
    required this.fileSha256,
    required this.chunkHashes,
  });

  final int totalSize;
  final String fileSha256;
  final List<String> chunkHashes;
}

class _AndroidDigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

class ContactRow {
  const ContactRow({required this.keyId, required this.name});

  final String keyId;
  final String name;

  static ContactRow parse(String line) {
    final parts = line.split('\t');
    return ContactRow(
      keyId: parts.isNotEmpty ? parts[0] : '',
      name: parts.length > 1 ? parts.sublist(1).join(' ') : 'Unknown',
    );
  }
}

class MessageRow {
  const MessageRow({
    required this.timestamp,
    required this.sender,
    required this.direction,
    required this.text,
  });

  final String timestamp;
  final String sender;
  final String direction;
  final String text;

  static MessageRow parse(String line) {
    final parts = line.split('\t');
    if (parts.length >= 4) {
      return MessageRow(
        timestamp: parts[0],
        sender: parts[1],
        direction: parts[2],
        text: parts.sublist(3).join('\t'),
      );
    }
    return MessageRow(
      timestamp: parts.isNotEmpty ? parts[0] : '',
      sender: parts.length > 1 ? parts[1] : 'Unknown',
      direction: 'Incoming',
      text: parts.length > 2 ? parts.sublist(2).join('\t') : '',
    );
  }
}

class CliException implements Exception {
  const CliException(this.message);

  final String message;

  @override
  String toString() => message;
}

Directory findRepoRoot() {
  final appDir = File(Platform.resolvedExecutable).parent;
  return _findRepoRootFrom(Directory.current) ??
      _findRepoRootFrom(appDir) ??
      appDir;
}

Directory? _findRepoRootFrom(Directory start) {
  var current = start;
  while (true) {
    if (File(p.join(current.path, 'Cargo.toml')).existsSync() &&
        Directory(p.join(current.path, 'crates')).existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return null;
    }
    current = parent;
  }
}

String _exeName(String name) => Platform.isWindows ? '$name.exe' : name;

extension on String {
  List<String> splitLines() => split(RegExp(r'\r?\n'));
}
