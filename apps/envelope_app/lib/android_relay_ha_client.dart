import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'android_relay_ha_store.dart';
import 'relay_ha_json.dart';

typedef RelayHaNative =
    Map<String, Object?> Function(Map<String, Object?> input);
typedef RelayHaTransport =
    Future<Map<String, Object?>> Function(
      Uri endpoint,
      String method,
      String path,
      Map<String, Object?>? body,
    );

enum RelayConnectionState {
  discovering,
  readyNormal,
  readyDegraded,
  suspect,
  noQuorum,
  recovering,
  upgradeRequired,
}

class RelayHaException implements Exception {
  const RelayHaException(
    this.code, {
    this.retryAfter,
    this.detail = '',
    this.reasonCode,
  });
  final String code;
  final Duration? retryAfter;
  final String detail;
  final String? reasonCode;
  bool get permitsFailover => const {
    'NOT_LEADER',
    'NOT_READY',
    'NO_QUORUM',
    'REPLICA_UNAVAILABLE',
    'PAYLOAD_UNAVAILABLE',
    'TRANSPORT_ERROR',
  }.contains(code);
  @override
  String toString() => '$code${detail.isEmpty ? '' : ': $detail'}';
}

/// A v2-only transport: static trust, dynamic leadership and business endpoint
/// are separate. Clients authenticate a leader; they never elect one.
class AndroidRelayHaClient {
  AndroidRelayHaClient({
    required this.adminPublic,
    required this.clusterId,
    required List<String> bootstrapUrls,
    required this.native,
    required this.store,
    RelayHaTransport? transport,
    int Function()? now,
  }) : bootstrapUris = bootstrapUrls.map(Uri.parse).toList(growable: false),
       _transportOverride = transport,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (bootstrapUris.isEmpty ||
        bootstrapUris.any(
          (uri) =>
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              uri.path != '/',
        )) {
      throw const FormatException(
        'HA bootstrap requires HTTPS origin URLs ending in /',
      );
    }
    _http.connectionTimeout = const Duration(seconds: 3);
  }

  final String adminPublic;
  final String clusterId;
  final List<Uri> bootstrapUris;
  final RelayHaNative native;
  final AndroidRelayHaStore store;
  final RelayHaTransport? _transportOverride;
  final int Function() _now;
  final HttpClient _http = HttpClient();
  Future<Map<String, Object?>>? _discovery;
  Map<String, Object?>? _config;
  Map<String, Object?>? _watermark;
  Map<String, Object?>? _leaderStatus;
  Uri? _active;
  RelayConnectionState state = RelayConnectionState.discovering;
  Uri? get activeBaseUri => _active;
  Map<String, Object?>? get config =>
      _config == null ? null : Map.unmodifiable(_config!);

  void close() => _http.close(force: true);

  Future<Map<String, Object?>> discover({bool force = false}) async {
    final pending = _discovery;
    if (pending != null) return pending;
    final status = _leaderStatus;
    if (!force &&
        status != null &&
        _active != null &&
        BigInt.parse(status['expires_at'] as String) > BigInt.from(_now())) {
      return status;
    }
    final next = _discover();
    _discovery = next;
    try {
      return await next;
    } finally {
      if (identical(_discovery, next)) _discovery = null;
    }
  }

  Future<Map<String, Object?>> _discover() async {
    state = RelayConnectionState.discovering;
    _leaderStatus = null;
    final previousActive = _active;
    _active = null;
    await _loadConfig();
    final config = _config!;
    final nodes = (config['business_nodes'] as List)
        .map((node) => (node as Map).cast<String, Object?>())
        .toList();
    nodes.sort(
      (a, b) => a['public_url'] == previousActive?.toString()
          ? -1
          : b['public_url'] == previousActive?.toString()
          ? 1
          : 0,
    );
    var noQuorum = false;
    Object? lastError;
    for (final node in nodes) {
      final endpoint = Uri.parse(node['public_url'] as String);
      final nonce = _nonce();
      try {
        final response = await _request(
          endpoint,
          'GET',
          'v2/cluster/status?nonce=${Uri.encodeQueryComponent(nonce)}',
          null,
        );
        final verified = native({
          'op': 'verify_status',
          'config': config,
          'status': response,
          'nonce': nonce,
          'now': _now().toString(),
          'watermark': _watermark,
        });
        final status = (verified['status'] as Map).cast<String, Object?>();
        if (status['node_id'] != node['node_id']) {
          throw const FormatException(
            'Status signer does not match requested endpoint',
          );
        }
        final watermark = (verified['watermark'] as Map)
            .cast<String, Object?>();
        await store.saveClusterState({
          'config': config,
          'watermark': watermark,
          'active_base_uri': status['role'] == 'leader'
              ? endpoint.toString()
              : null,
        });
        _watermark = watermark;
        if (status['role'] == 'leader' &&
            status['ready'] == true &&
            (status['mode'] == 'normal' || status['mode'] == 'degraded')) {
          _active = endpoint;
          _leaderStatus = status;
          state = status['mode'] == 'normal'
              ? RelayConnectionState.readyNormal
              : RelayConnectionState.readyDegraded;
          return status;
        }
        noQuorum |= status['reason_code'] == 'NO_QUORUM';
      } catch (error) {
        if (error is RelayHaException && error.code == 'UPGRADE_REQUIRED') {
          state = RelayConnectionState.upgradeRequired;
          rethrow;
        }
        noQuorum |= error is RelayHaException && error.code == 'NO_QUORUM';
        lastError = error;
      }
    }
    state = noQuorum
        ? RelayConnectionState.noQuorum
        : RelayConnectionState.recovering;
    throw RelayHaException(
      noQuorum ? 'NO_QUORUM' : 'NOT_READY',
      detail: lastError?.toString() ?? 'No authenticated ready leader',
    );
  }

  Future<void> _loadConfig() async {
    final cached = _config;
    Object? lastError;
    final candidates = <Uri>{
      if (cached != null)
        for (final node in cached['business_nodes'] as List)
          Uri.parse((node as Map)['public_url'] as String),
      ...bootstrapUris,
    };
    for (final endpoint in candidates) {
      try {
        final raw = await _request(endpoint, 'GET', 'v2/cluster/config', null);
        final config = native({
          'op': 'verify_config',
          'config': raw,
          'admin_public': adminPublic,
          'now': _now().toString(),
        });
        if (config['cluster_id'] != clusterId) {
          throw const FormatException('Bootstrap returned another cluster');
        }
        final stored = await store.clusterState(config['cluster_id'] as String);
        final old = stored == null
            ? null
            : (stored['watermark'] as Map).cast<String, Object?>();
        final sameGeneration =
            old?['control_generation'] == config['control_generation'];
        final watermark = <String, Object?>{
          'cluster_id': config['cluster_id'],
          'control_generation': config['control_generation'],
          'config_epoch': config['config_epoch'],
          'leader_term': sameGeneration ? old!['leader_term'] : '0',
        };
        await store.saveClusterState({
          'config': config,
          'watermark': watermark,
        });
        _config = config;
        _watermark = watermark;
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw RelayHaException(
      'NOT_READY',
      detail: 'Cannot verify cluster configuration: $lastError',
    );
  }

  Future<Map<String, Object?>> request({
    required String path,
    required String requestKind,
    required String actorId,
    required String operationId,
    required String identityJson,
    required Map<String, Object?> body,
    String method = 'POST',
  }) async {
    if (!path.startsWith('v2/') ||
        path.contains('..') ||
        path.contains('://')) {
      throw const FormatException('Only v2 relative request paths are allowed');
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      await discover(force: attempt > 0);
      final config = _config!;
      final bodyBase64 = base64Url
          .encode(utf8.encode(jsonEncode(body)))
          .replaceAll('=', '');
      final signed = native({
        'op': 'sign_request',
        'identity_json': identityJson,
        'body_b64': bodyBase64,
        'auth': {
          'protocol_version': 2,
          'cluster_id': config['cluster_id'],
          'control_generation': config['control_generation'],
          'config_epoch': config['config_epoch'],
          'actor_id': actorId,
          'operation_id': operationId,
          'nonce': _nonce(),
          'requested_at': _now().toString(),
          'request_kind': requestKind,
          'body_sha256': native({
            'op': 'hash',
            'body_b64': bodyBase64,
          })['sha256'],
          'signature': '',
        },
      });
      try {
        return await _request(_active!, method, path, signed);
      } catch (error) {
        if (error is! RelayHaException ||
            !error.permitsFailover ||
            attempt == 1) {
          rethrow;
        }
        state = RelayConnectionState.suspect;
        _leaderStatus = null;
      }
    }
    throw const RelayHaException('NOT_READY');
  }

  Future<Map<String, Object?>> _request(
    Uri endpoint,
    String method,
    String path,
    Map<String, Object?>? body,
  ) async {
    final encodedBody = body?['body_b64'];
    final timeout =
        (encodedBody is String && encodedBody.length > 350000) ||
            path.endsWith('/pull')
        ? const Duration(seconds: 60)
        : const Duration(seconds: 8);
    try {
      final request = _transportOverride;
      if (request != null) {
        return await request(endpoint, method, path, body).timeout(timeout);
      }
      return await _httpRequest(
        endpoint,
        method,
        path,
        body,
        timeout,
      ).timeout(timeout);
    } on TimeoutException {
      throw const RelayHaException('TRANSPORT_ERROR', detail: 'Timed out');
    } on SocketException {
      throw const RelayHaException(
        'TRANSPORT_ERROR',
        detail: 'Connection unavailable',
      );
    } on HttpException {
      throw const RelayHaException(
        'TRANSPORT_ERROR',
        detail: 'Invalid HTTP response',
      );
    }
  }

  Future<Map<String, Object?>> _httpRequest(
    Uri endpoint,
    String method,
    String path,
    Map<String, Object?>? body,
    Duration timeout,
  ) async {
    HttpClientRequest? pending;
    var timedOut = false;
    final deadline = Timer(timeout, () {
      timedOut = true;
      pending?.abort(TimeoutException('HA request deadline'));
    });
    try {
      final request = await _http.openUrl(method, endpoint.resolve(path));
      pending = request;
      if (timedOut) {
        request.abort();
        throw TimeoutException('HA request deadline');
      }
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 16 * 1024 * 1024) {
          request.abort();
          throw const FormatException('HA response exceeds 16 MiB');
        }
        bytes.add(chunk);
      }
      final content = utf8.decode(bytes.takeBytes());
      final decoded = decodeRelayJson(content);
      if (decoded is! Map) {
        throw const FormatException('HA response must be an object');
      }
      final json = decoded.cast<String, Object?>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final seconds = int.tryParse(
          response.headers.value(HttpHeaders.retryAfterHeader) ?? '',
        );
        throw RelayHaException(
          json['code']?.toString() ?? 'HTTP_${response.statusCode}',
          reasonCode: (json['reason_code'] ?? json['reason'])?.toString(),
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
          detail: json['detail']?.toString() ?? '',
        );
      }
      return json;
    } finally {
      deadline.cancel();
    }
  }

  static String _nonce() => base64Url
      .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
}
