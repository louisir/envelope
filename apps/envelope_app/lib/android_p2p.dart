import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _ticketPrefix = 'envelope-p2p-tcp-v1.';
const _protocolVersion = 1;
const _maxFrameBytes = 8 * 1024 * 1024;
const _defaultTicketTtl = Duration(minutes: 30);
const _defaultTicketRefreshBefore = Duration(minutes: 5);
const Duration androidP2pFastAttemptTimeout = Duration(seconds: 3);
const Duration androidP2pFailureCooldown = Duration(seconds: 30);

typedef AndroidP2pEnvelopeHandler =
    Future<AndroidP2pAck> Function(Uint8List envelopeBytes);

class AndroidP2pCooldownTracker {
  AndroidP2pCooldownTracker({this.cooldown = androidP2pFailureCooldown});

  final Duration cooldown;
  final Map<String, DateTime> _blockedUntilByKey = <String, DateTime>{};

  bool canAttempt({
    required String recipientKeyId,
    required String ticket,
    DateTime? now,
  }) {
    final key = _key(recipientKeyId, ticket);
    if (key == null) return true;
    final current = now ?? DateTime.now();
    final blockedUntil = _blockedUntilByKey[key];
    if (blockedUntil == null) return true;
    if (current.isBefore(blockedUntil)) return false;
    _blockedUntilByKey.remove(key);
    return true;
  }

  Duration? remaining({
    required String recipientKeyId,
    required String ticket,
    DateTime? now,
  }) {
    final key = _key(recipientKeyId, ticket);
    if (key == null) return null;
    final current = now ?? DateTime.now();
    final blockedUntil = _blockedUntilByKey[key];
    if (blockedUntil == null) return null;
    if (!current.isBefore(blockedUntil)) {
      _blockedUntilByKey.remove(key);
      return null;
    }
    return blockedUntil.difference(current);
  }

  void recordFailure({
    required String recipientKeyId,
    required String ticket,
    DateTime? now,
  }) {
    final key = _key(recipientKeyId, ticket);
    if (key == null) return;
    final current = now ?? DateTime.now();
    _blockedUntilByKey[key] = current.add(cooldown);
  }

  void recordSuccess({required String recipientKeyId, required String ticket}) {
    final key = _key(recipientKeyId, ticket);
    if (key == null) return;
    _blockedUntilByKey.remove(key);
  }

  static String? _key(String recipientKeyId, String ticket) {
    final recipient = recipientKeyId.trim();
    final normalizedTicket = ticket.trim();
    if (recipient.isEmpty || normalizedTicket.isEmpty) return null;
    return '$recipient\n$normalizedTicket';
  }
}

class AndroidP2pTransport {
  ServerSocket? _server;
  AndroidP2pEnvelopeHandler? _handler;
  AndroidP2pStatus? _status;
  StreamSubscription<Socket>? _subscription;

  bool get isListening => _server != null;

  AndroidP2pStatus? get status => _status;

  Future<AndroidP2pStatus> start({
    required String deviceId,
    required AndroidP2pEnvelopeHandler onEnvelope,
    Duration ttl = _defaultTicketTtl,
    Duration refreshBefore = _defaultTicketRefreshBefore,
  }) async {
    final existing = _status;
    if (_server != null && existing != null) {
      if (!existing.shouldRefreshAt(DateTime.now(), refreshBefore)) {
        _handler = onEnvelope;
        return existing;
      }
      await stop();
    }

    _handler = onEnvelope;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _subscription = server.listen(
      (socket) => unawaited(_handleSocket(socket)),
      onError: (_) {},
      cancelOnError: false,
    );

    final addrs = await _localIpv4Addresses();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ticket = AndroidP2pTicket(
      deviceId: deviceId,
      addrs: addrs,
      port: server.port,
      createdAtUnixMs: now,
      expiresAtUnixMs: now + ttl.inMilliseconds,
    );
    final status = AndroidP2pStatus(
      listening: true,
      ticket: ticket.encode(),
      addrs: addrs,
      port: server.port,
      expiresAtUnixMs: ticket.expiresAtUnixMs,
    );
    _status = status;
    return status;
  }

  Future<AndroidP2pStatus> restart({
    required String deviceId,
    required AndroidP2pEnvelopeHandler onEnvelope,
    Duration ttl = _defaultTicketTtl,
  }) async {
    await stop();
    return start(deviceId: deviceId, onEnvelope: onEnvelope, ttl: ttl);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close();
    _server = null;
    _handler = null;
    _status = null;
  }

  Future<AndroidP2pAck> sendEnvelope({
    required String ticket,
    required Uint8List envelopeBytes,
    Duration timeout = androidP2pFastAttemptTimeout,
  }) async {
    final parsed = AndroidP2pTicket.parse(ticket);
    if (parsed.isExpired) {
      throw const AndroidP2pException('直连信息已失效，请等待自动刷新后重试。');
    }
    if (envelopeBytes.length > _maxFrameBytes) {
      throw const AndroidP2pException('opaque envelope 文件过大。');
    }

    Object? lastError;
    for (final addr in parsed.addrs) {
      Socket? socket;
      try {
        socket = await Socket.connect(addr, parsed.port, timeout: timeout);
        await _writeFrame(socket, envelopeBytes);
        final ackPayload = await _readFrame(socket, timeout: timeout);
        final ack = AndroidP2pAck.fromJsonBytes(ackPayload);
        if (!ack.ok) {
          throw AndroidP2pException('P2P 投递被拒绝：${ack.detail}');
        }
        return ack;
      } catch (error) {
        lastError = error;
      } finally {
        socket?.destroy();
      }
    }
    throw AndroidP2pException('P2P 连接失败：${lastError ?? 'no address'}');
  }

  Future<void> _handleSocket(Socket socket) async {
    try {
      final handler = _handler;
      if (handler == null) {
        await _writeFrame(
          socket,
          AndroidP2pAck.error('', 'P2P listener unavailable').toJsonBytes(),
        );
        return;
      }

      final payload = await _readFrame(socket);
      final ack = await handler(payload);
      await _writeFrame(socket, ack.toJsonBytes());
    } catch (error) {
      await _writeFrame(
        socket,
        AndroidP2pAck.error('', error.toString()).toJsonBytes(),
      );
    } finally {
      await socket.flush();
      await socket.close();
    }
  }
}

class AndroidP2pStatus {
  const AndroidP2pStatus({
    required this.listening,
    required this.ticket,
    required this.addrs,
    required this.port,
    required this.expiresAtUnixMs,
  });

  final bool listening;
  final String ticket;
  final List<String> addrs;
  final int port;
  final int expiresAtUnixMs;

  Map<String, Object?> toJson({DateTime? now}) {
    final reference = now ?? DateTime.now();
    final parsedTicket = AndroidP2pTicket.tryParse(ticket);
    return {
      'listening': listening,
      'ticket': ticket,
      'addrs': addrs,
      'port': port,
      'expires_at_unix_ms': expiresAtUnixMs,
      if (parsedTicket != null) ...{
        'ticket_expired': parsedTicket.isExpiredAt(reference),
        'ticket_needs_refresh': shouldRefreshAt(
          reference,
          _defaultTicketRefreshBefore,
        ),
        'ticket_remaining_seconds': parsedTicket.remainingSecondsAt(reference),
      },
    };
  }

  bool shouldRefreshAt(DateTime now, Duration refreshBefore) {
    final remainingMillis = expiresAtUnixMs - now.millisecondsSinceEpoch;
    return remainingMillis <= refreshBefore.inMilliseconds;
  }
}

class AndroidP2pTicket {
  const AndroidP2pTicket({
    required this.deviceId,
    required this.addrs,
    required this.port,
    required this.createdAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final String deviceId;
  final List<String> addrs;
  final int port;
  final int createdAtUnixMs;
  final int expiresAtUnixMs;

  bool get isExpired => isExpiredAt(DateTime.now());

  bool isExpiredAt(DateTime now) =>
      expiresAtUnixMs <= now.millisecondsSinceEpoch;

  Duration remainingAt(DateTime now) {
    final remainingMillis = expiresAtUnixMs - now.millisecondsSinceEpoch;
    if (remainingMillis <= 0) return Duration.zero;
    return Duration(milliseconds: remainingMillis);
  }

  int remainingSecondsAt(DateTime now) {
    final remainingMillis = expiresAtUnixMs - now.millisecondsSinceEpoch;
    if (remainingMillis <= 0) return 0;
    return (remainingMillis + 999) ~/ 1000;
  }

  bool shouldRefreshAt(DateTime now, Duration refreshBefore) =>
      remainingAt(now) <= refreshBefore;

  String encode() {
    final payload = jsonEncode({
      'version': _protocolVersion,
      'protocol': 'tcp.v1',
      'device_id': deviceId,
      'addrs': addrs,
      'port': port,
      'created_at_unix_ms': createdAtUnixMs,
      'expires_at_unix_ms': expiresAtUnixMs,
    });
    return '$_ticketPrefix${base64UrlEncode(utf8.encode(payload))}';
  }

  static AndroidP2pTicket parse(String ticket) {
    if (!ticket.startsWith(_ticketPrefix)) {
      throw const AndroidP2pException('不支持的 P2P ticket 格式。');
    }
    final encoded = ticket.substring(_ticketPrefix.length);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)));
    if (decoded is! Map<String, Object?>) {
      throw const AndroidP2pException('P2P ticket 内容格式不正确。');
    }
    final version = (decoded['version'] as num?)?.toInt();
    if (version != _protocolVersion) {
      throw AndroidP2pException('不支持的 P2P ticket 版本：$version。');
    }
    final protocol = decoded['protocol']?.toString();
    if (protocol != 'tcp.v1') {
      throw AndroidP2pException('不支持的 P2P ticket 协议：$protocol。');
    }
    final addrs = (decoded['addrs'] as List? ?? const [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
    if (addrs.isEmpty) {
      throw const AndroidP2pException('P2P ticket 没有可用地址。');
    }
    final port = (decoded['port'] as num?)?.toInt() ?? 0;
    if (port <= 0 || port > 65535) {
      throw const AndroidP2pException('P2P ticket 端口无效。');
    }
    return AndroidP2pTicket(
      deviceId: decoded['device_id']?.toString() ?? '',
      addrs: addrs,
      port: port,
      createdAtUnixMs: (decoded['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      expiresAtUnixMs: (decoded['expires_at_unix_ms'] as num?)?.toInt() ?? 0,
    );
  }

  static AndroidP2pTicket? tryParse(String? ticket) {
    final value = ticket?.trim() ?? '';
    if (value.isEmpty) return null;
    try {
      return AndroidP2pTicket.parse(value);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson({DateTime? now}) {
    final reference = now ?? DateTime.now();
    return {
      'version': _protocolVersion,
      'protocol': 'tcp.v1',
      'device_id': deviceId,
      'addrs': addrs,
      'port': port,
      'created_at_unix_ms': createdAtUnixMs,
      'expires_at_unix_ms': expiresAtUnixMs,
      'expired': isExpiredAt(reference),
      'remaining_seconds': remainingSecondsAt(reference),
    };
  }
}

class AndroidP2pAck {
  const AndroidP2pAck({
    required this.status,
    required this.envelopeId,
    required this.detail,
  });

  final String status;
  final String envelopeId;
  final String detail;

  bool get ok => status == 'ok';

  factory AndroidP2pAck.ok(String envelopeId, String detail) {
    return AndroidP2pAck(status: 'ok', envelopeId: envelopeId, detail: detail);
  }

  factory AndroidP2pAck.error(String envelopeId, String detail) {
    return AndroidP2pAck(
      status: 'error',
      envelopeId: envelopeId,
      detail: detail,
    );
  }

  factory AndroidP2pAck.fromJsonBytes(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const AndroidP2pException('P2P ack 格式不正确。');
    }
    return AndroidP2pAck(
      status: decoded['status']?.toString() ?? 'error',
      envelopeId: decoded['envelope_id']?.toString() ?? '',
      detail: decoded['detail']?.toString() ?? '',
    );
  }

  Uint8List toJsonBytes() {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': _protocolVersion,
          'status': status,
          'envelope_id': envelopeId,
          'detail': detail,
        }),
      ),
    );
  }

  Map<String, Object?> toJson() {
    return {'status': status, 'envelope_id': envelopeId, 'detail': detail};
  }
}

class AndroidP2pException implements Exception {
  const AndroidP2pException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<List<String>> _localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  final records = <({String address, int priority})>[];
  for (final interface in interfaces) {
    final name = interface.name.toLowerCase();
    final priority = name.startsWith('wlan')
        ? 0
        : name.startsWith('eth')
        ? 1
        : name.startsWith('tun') || name.startsWith('rmnet')
        ? 9
        : 5;
    for (final addr in interface.addresses) {
      if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
        records.add((address: addr.address, priority: priority));
      }
    }
  }
  records.sort((a, b) {
    final priority = a.priority.compareTo(b.priority);
    if (priority != 0) return priority;
    return a.address.compareTo(b.address);
  });
  final seen = <String>{};
  return [
    for (final record in records)
      if (seen.add(record.address)) record.address,
  ];
}

Future<void> _writeFrame(Socket socket, List<int> payload) async {
  if (payload.length > _maxFrameBytes) {
    throw AndroidP2pException('P2P frame too large: ${payload.length}');
  }
  final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
  socket.add(header.buffer.asUint8List());
  socket.add(payload);
  await socket.flush();
}

Future<Uint8List> _readFrame(
  Socket socket, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final builder = BytesBuilder(copy: false);
  int? frameLength;

  await for (final chunk in socket.timeout(timeout)) {
    builder.add(chunk);
    final bytes = builder.toBytes();
    if (frameLength == null && bytes.length >= 4) {
      final data = ByteData.sublistView(bytes, 0, 4);
      frameLength = data.getUint32(0, Endian.big);
      if (frameLength > _maxFrameBytes) {
        throw AndroidP2pException('P2P frame too large: $frameLength');
      }
    }
    final length = frameLength;
    if (length != null && bytes.length >= 4 + length) {
      return Uint8List.sublistView(bytes, 4, 4 + length);
    }
  }
  throw const AndroidP2pException('P2P connection closed before full frame');
}
