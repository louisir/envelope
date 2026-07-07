import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'envelope_native.dart';

const String envelopeNodeManifestSigningPublic =
    'RHma4xYC6bw759wgFj6szZlZPySZkzOWYey8QdZ3LlU';

const Duration _envelopeServerRequestTimeout = Duration(seconds: 12);
const int _nodeChallengeMaxClockSkewMs = 5 * 60 * 1000;

class EnvelopeServerClient {
  EnvelopeServerClient(
    String baseUrl, {
    HttpClient? httpClient,
    this.nativeCore,
    List<String>? bootstrapUrls,
  }) : baseUri = _parseBaseUri(baseUrl),
       _httpClient = httpClient ?? HttpClient(),
       _bootstrapUris = _buildBootstrapUris(
         baseUrl,
         bootstrapUrls ?? const <String>[],
       ) {
    if (httpClient == null) {
      _httpClient.connectionTimeout = const Duration(seconds: 8);
    }
  }

  final Uri baseUri;
  final HttpClient _httpClient;
  final EnvelopeNative? nativeCore;
  final List<Uri> _bootstrapUris;
  Uri? _lastUsedBaseUri;

  static NodeSetManifest? _cachedManifest;
  static final Map<String, int> _verifiedNodeEpochByUri = <String, int>{};

  Uri get activeBaseUri => _lastUsedBaseUri ?? baseUri;

  static void clearNodeCache() {
    _cachedManifest = null;
    _verifiedNodeEpochByUri.clear();
  }

  Future<Map<String, Object?>> health() async {
    return _request('GET', 'health');
  }

  Future<NodeSetManifest?> refreshNodeManifest({bool force = false}) async {
    return _refreshNodeManifest(force: force);
  }

  Future<DeviceRegistrationResponse> registerDevice({
    required String ownerContactJson,
    required String endpointJson,
  }) async {
    final body = {
      'version': 1,
      'owner_contact': _decodeJsonObject(ownerContactJson, 'ownerContactJson'),
      'endpoint': _decodeJsonObject(endpointJson, 'endpointJson'),
    };
    final response = await _request('PUT', 'v1/devices/register', body: body);
    return DeviceRegistrationResponse.fromJson(response);
  }

  Future<RouteLookupResponse> lookupRoute({
    required String ownerKeyId,
    required String deviceId,
  }) async {
    final response = await _request(
      'GET',
      'v1/routes/${Uri.encodeComponent(ownerKeyId)}/${Uri.encodeComponent(deviceId)}',
    );
    return RouteLookupResponse.fromJson(response);
  }

  Future<EnvelopeSubmitResponse> submitEnvelope({
    required String submitRequestJson,
  }) async {
    final response = await _request(
      'POST',
      'v1/envelopes',
      body: _decodeJsonObject(submitRequestJson, 'submitRequestJson'),
    );
    return EnvelopeSubmitResponse.fromJson(response);
  }

  Future<MailboxPullResponse> pullMailbox({
    required String recipientKeyId,
    required String pullRequestJson,
  }) async {
    final response = await _request(
      'POST',
      'v1/mailbox/${Uri.encodeComponent(recipientKeyId)}/pull',
      body: _decodeJsonObject(pullRequestJson, 'pullRequestJson'),
    );
    return MailboxPullResponse.fromJson(response);
  }

  Future<MailboxAckResponse> ackMailbox({
    required String recipientKeyId,
    required String ackRequestJson,
  }) async {
    final response = await _request(
      'POST',
      'v1/mailbox/${Uri.encodeComponent(recipientKeyId)}/ack',
      body: _decodeJsonObject(ackRequestJson, 'ackRequestJson'),
    );
    return MailboxAckResponse.fromJson(response);
  }

  Future<DeliveryStatusResponse> deliveryStatus({
    required String senderKeyId,
    required String statusRequestJson,
  }) async {
    final response = await _request(
      'POST',
      'v1/delivery/${Uri.encodeComponent(senderKeyId)}/status',
      body: _decodeJsonObject(statusRequestJson, 'statusRequestJson'),
    );
    return DeliveryStatusResponse.fromJson(response);
  }

  Future<IntroSessionPublishResponse> publishIntroSession({
    required String sessionId,
    required String ownerBundleJson,
  }) async {
    final response = await _request(
      'PUT',
      'v1/intro-sessions/${Uri.encodeComponent(sessionId)}',
      body: {
        'version': 1,
        'owner_bundle': _decodeJsonObject(ownerBundleJson, 'ownerBundleJson'),
      },
    );
    return IntroSessionPublishResponse.fromJson(response);
  }

  Future<IntroSessionRespondResponse> respondIntroSession({
    required String sessionId,
    required String responderBundleJson,
  }) async {
    final response = await _request(
      'POST',
      'v1/intro-sessions/${Uri.encodeComponent(sessionId)}/response',
      body: {
        'version': 1,
        'responder_bundle': _decodeJsonObject(
          responderBundleJson,
          'responderBundleJson',
        ),
      },
    );
    return IntroSessionRespondResponse.fromJson(response);
  }

  Future<IntroSessionPollResponse> pollIntroSessionResponse({
    required String sessionId,
  }) async {
    final response = await _request(
      'GET',
      'v1/intro-sessions/${Uri.encodeComponent(sessionId)}/response',
    );
    return IntroSessionPollResponse.fromJson(response);
  }

  void close() => _httpClient.close(force: true);

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final candidates = await _requestCandidateUris(path);
    final errors = <String>[];
    for (final candidate in candidates) {
      try {
        await _verifyManifestNodeForRequest(candidate, path);
        final response = await _requestAt(candidate, method, path, body: body);
        _lastUsedBaseUri = candidate;
        return response;
      } catch (error) {
        if (!_shouldTryNextNode(error)) {
          if (error is EnvelopeServerHttpException) {
            _lastUsedBaseUri = error.baseUri;
          }
          rethrow;
        }
        errors.add('${_displayUri(candidate)}: $error');
      }
    }
    throw EnvelopeServerException(
      'Envelope Server unavailable across ${candidates.length} node(s): '
      '${errors.join(' | ')}',
    );
  }

  Future<List<Uri>> _requestCandidateUris(String path) async {
    if (!_isNodeDiscoveryPath(path)) {
      await _refreshNodeManifest();
    }
    final manifest = _cachedManifest;
    final candidates = <Uri>[
      activeBaseUri,
      baseUri,
      if (manifest != null) ...manifest.sortedNodeUris(),
      ..._bootstrapUris,
    ];
    return _uniqueUris(candidates);
  }

  Future<NodeSetManifest?> _refreshNodeManifest({bool force = false}) async {
    final native = nativeCore;
    if (native == null) return _cachedManifest;
    final cached = _cachedManifest;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        cached != null &&
        cached.validUntilUnixMs >
            now + const Duration(minutes: 5).inMilliseconds) {
      return cached;
    }

    final candidates = _uniqueUris([
      activeBaseUri,
      baseUri,
      if (cached != null) ...cached.sortedNodeUris(),
      ..._bootstrapUris,
    ]);
    var accepted = cached;
    for (final candidate in candidates) {
      try {
        final manifestJson = await _requestAt(
          candidate,
          'GET',
          'v1/nodes/manifest',
        );
        final manifest = NodeSetManifest.fromJson(manifestJson);
        final verification = native.verifyNodeSetManifest(
          manifestJson: jsonEncode(manifest.toJson()),
          manifestSigningPublic: envelopeNodeManifestSigningPublic,
          nowUnixMs: now,
        );
        if (verification.manifestId != manifest.manifestId ||
            verification.epoch != manifest.epoch) {
          throw const EnvelopeServerException(
            'Node manifest verification summary mismatch',
          );
        }
        await _verifyNodeChallenge(candidate, manifest, strict: true);
        if (accepted == null || manifest.epoch >= accepted.epoch) {
          accepted = manifest;
          _cachedManifest = manifest;
        }
        _lastUsedBaseUri = candidate;
        return accepted;
      } catch (error) {
        if (!_shouldTryNextNode(error)) rethrow;
      }
    }
    return accepted;
  }

  Future<void> _verifyManifestNodeForRequest(Uri uri, String path) async {
    if (_isNodeDiscoveryPath(path) || nativeCore == null) return;
    final manifest = _cachedManifest;
    if (manifest == null) return;
    final node = manifest.nodeForUri(uri);
    if (node == null) return;
    final key = '${_uriKey(uri)}@${manifest.epoch}';
    if (_verifiedNodeEpochByUri[key] == manifest.epoch) return;
    await _verifyNodeChallenge(uri, manifest, strict: false);
  }

  Future<void> _verifyNodeChallenge(
    Uri uri,
    NodeSetManifest manifest, {
    required bool strict,
  }) async {
    final native = nativeCore;
    if (native == null) return;
    final node = manifest.nodeForUri(uri);
    if (node == null) {
      if (strict) {
        throw EnvelopeServerException(
          'Node manifest does not contain ${_displayUri(uri)}',
        );
      }
      return;
    }
    final challenge = _base64UrlNoPad(_secureRandomBytes(32));
    final requestedAt = DateTime.now().millisecondsSinceEpoch;
    final request = NodeChallengeRequest(
      nodeId: node.nodeId,
      challengeBase64: challenge,
      requestedAtUnixMs: requestedAt,
    );
    final responseJson = await _requestAt(
      uri,
      'POST',
      'v1/node/challenge',
      body: request.toJson(),
    );
    final response = NodeChallengeResponse.fromJson(responseJson);
    final verification = native.verifyNodeChallenge(
      requestJson: jsonEncode(request.toJson()),
      responseJson: jsonEncode(response.toJson()),
      nodePublicKey: node.publicKey,
      nowUnixMs: DateTime.now().millisecondsSinceEpoch,
      maxClockSkewMs: _nodeChallengeMaxClockSkewMs,
    );
    if (!verification.valid || verification.nodeId != node.nodeId) {
      throw EnvelopeServerException(
        'Node challenge verification failed for ${node.nodeId}',
      );
    }
    _verifiedNodeEpochByUri['${_uriKey(uri)}@${manifest.epoch}'] =
        manifest.epoch;
  }

  Future<Map<String, Object?>> _requestAt(
    Uri base,
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = await _httpClient
        .openUrl(method, base.resolve(path))
        .timeout(_envelopeServerRequestTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      _envelopeServerRequestTimeout,
    );
    final responseBody = await utf8
        .decodeStream(response)
        .timeout(_envelopeServerRequestTimeout);
    final status = response.statusCode;
    Map<String, Object?>? decoded;
    if (responseBody.trim().isNotEmpty) {
      try {
        decoded = _decodeJsonObject(responseBody, 'response');
      } catch (error) {
        if (status >= 200 && status < 300) {
          throw EnvelopeServerTransportException(
            'Invalid JSON response from ${_displayUri(base)}: $error',
          );
        }
      }
    }
    if (status < 200 || status >= 300) {
      final error = decoded?['error']?.toString();
      throw EnvelopeServerHttpException(
        baseUri: base,
        statusCode: status,
        reason: response.reasonPhrase,
        apiError: error,
        responseWasJson: decoded != null,
        message:
            'HTTP $status ${error == null || error.isEmpty ? response.reasonPhrase : error}',
      );
    }
    return decoded ?? <String, Object?>{};
  }

  static Uri _parseBaseUri(String baseUrl) {
    final value = baseUrl.trim();
    if (value.isEmpty) {
      throw const EnvelopeServerException('Envelope Server URL is empty');
    }
    final uri = Uri.parse(value.endsWith('/') ? value : '$value/');
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw EnvelopeServerException('Invalid Envelope Server URL: $baseUrl');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw EnvelopeServerException(
        'Unsupported Envelope Server URL scheme: ${uri.scheme}',
      );
    }
    return uri;
  }

  static List<Uri> _buildBootstrapUris(
    String baseUrl,
    List<String> bootstrapUrls,
  ) {
    return _uniqueUris([
      _parseBaseUri(baseUrl),
      for (final url in bootstrapUrls) _parseBaseUri(url),
    ]);
  }
}

class NodeSetManifest {
  const NodeSetManifest({
    required this.version,
    required this.manifestId,
    required this.epoch,
    required this.validFromUnixMs,
    required this.validUntilUnixMs,
    required this.prevManifestHash,
    required this.nodes,
    required this.revokedNodeIds,
    required this.signature,
  });

  final int version;
  final String manifestId;
  final int epoch;
  final int validFromUnixMs;
  final int validUntilUnixMs;
  final String? prevManifestHash;
  final List<NodeDescriptor> nodes;
  final List<String> revokedNodeIds;
  final String signature;

  static NodeSetManifest fromJson(Map<String, Object?> json) {
    return NodeSetManifest(
      version: (json['version'] as num).toInt(),
      manifestId: json['manifest_id'] as String,
      epoch: (json['epoch'] as num).toInt(),
      validFromUnixMs: (json['valid_from_unix_ms'] as num).toInt(),
      validUntilUnixMs: (json['valid_until_unix_ms'] as num).toInt(),
      prevManifestHash: json['prev_manifest_hash'] as String?,
      nodes: (json['nodes'] as List? ?? const [])
          .whereType<Map>()
          .map((node) => NodeDescriptor.fromJson(node.cast<String, Object?>()))
          .toList(growable: false),
      revokedNodeIds: (json['revoked_node_ids'] as List? ?? const [])
          .map((nodeId) => nodeId.toString())
          .toList(growable: false),
      signature: json['signature'] as String,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'manifest_id': manifestId,
    'epoch': epoch,
    'valid_from_unix_ms': validFromUnixMs,
    'valid_until_unix_ms': validUntilUnixMs,
    'prev_manifest_hash': prevManifestHash,
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'revoked_node_ids': revokedNodeIds,
    'signature': signature,
  };

  NodeDescriptor? nodeForUri(Uri uri) {
    final key = _uriKey(uri);
    for (final node in nodes) {
      if (_uriKey(node.baseUri) == key) return node;
    }
    return null;
  }

  List<Uri> sortedNodeUris() {
    final sorted = [...nodes]
      ..sort((a, b) {
        final weightCompare = b.weight.compareTo(a.weight);
        if (weightCompare != 0) return weightCompare;
        return a.nodeId.compareTo(b.nodeId);
      });
    return sorted.map((node) => node.baseUri).toList(growable: false);
  }
}

class NodeDescriptor {
  NodeDescriptor({
    required this.nodeId,
    required this.baseUrl,
    required this.publicKey,
    required this.capabilities,
    required this.weight,
    required this.region,
    required this.validUntilUnixMs,
  }) : baseUri = EnvelopeServerClient._parseBaseUri(baseUrl);

  final String nodeId;
  final String baseUrl;
  final Uri baseUri;
  final String publicKey;
  final List<String> capabilities;
  final int weight;
  final String? region;
  final int validUntilUnixMs;

  static NodeDescriptor fromJson(Map<String, Object?> json) {
    return NodeDescriptor(
      nodeId: json['node_id'] as String,
      baseUrl: json['base_url'] as String,
      publicKey: json['public_key'] as String,
      capabilities: (json['capabilities'] as List? ?? const [])
          .map((capability) => capability.toString())
          .toList(growable: false),
      weight: (json['weight'] as num).toInt(),
      region: json['region'] as String?,
      validUntilUnixMs: (json['valid_until_unix_ms'] as num).toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'node_id': nodeId,
    'base_url': baseUrl,
    'public_key': publicKey,
    'capabilities': capabilities,
    'weight': weight,
    'region': region,
    'valid_until_unix_ms': validUntilUnixMs,
  };
}

class NodeChallengeRequest {
  const NodeChallengeRequest({
    required this.nodeId,
    required this.challengeBase64,
    required this.requestedAtUnixMs,
  });

  final String nodeId;
  final String challengeBase64;
  final int requestedAtUnixMs;

  Map<String, Object?> toJson() => {
    'version': 1,
    'node_id': nodeId,
    'challenge_b64': challengeBase64,
    'requested_at_unix_ms': requestedAtUnixMs,
  };
}

class NodeChallengeResponse {
  const NodeChallengeResponse({
    required this.version,
    required this.status,
    required this.nodeId,
    required this.challengeBase64,
    required this.requestedAtUnixMs,
    required this.signedAtUnixMs,
    required this.signature,
  });

  final int version;
  final String status;
  final String nodeId;
  final String challengeBase64;
  final int requestedAtUnixMs;
  final int signedAtUnixMs;
  final String signature;

  static NodeChallengeResponse fromJson(Map<String, Object?> json) {
    return NodeChallengeResponse(
      version: (json['version'] as num).toInt(),
      status: json['status'] as String,
      nodeId: json['node_id'] as String,
      challengeBase64: json['challenge_b64'] as String,
      requestedAtUnixMs: (json['requested_at_unix_ms'] as num).toInt(),
      signedAtUnixMs: (json['signed_at_unix_ms'] as num).toInt(),
      signature: json['signature'] as String,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'status': status,
    'node_id': nodeId,
    'challenge_b64': challengeBase64,
    'requested_at_unix_ms': requestedAtUnixMs,
    'signed_at_unix_ms': signedAtUnixMs,
    'signature': signature,
  };
}

class DeviceRegistrationResponse {
  const DeviceRegistrationResponse({
    required this.ownerKeyId,
    required this.deviceId,
    required this.expiresAtUnixMs,
  });

  final String ownerKeyId;
  final String deviceId;
  final int expiresAtUnixMs;

  static DeviceRegistrationResponse fromJson(Map<String, Object?> json) {
    return DeviceRegistrationResponse(
      ownerKeyId: json['owner_identity_key_id'] as String,
      deviceId: json['device_id'] as String,
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class RouteLookupResponse {
  const RouteLookupResponse({
    required this.ownerKeyId,
    required this.deviceId,
    required this.endpoint,
  });

  final String ownerKeyId;
  final String deviceId;
  final DeviceEndpointUpdate? endpoint;

  bool get hasEndpoint => endpoint != null;

  static RouteLookupResponse fromJson(Map<String, Object?> json) {
    final endpoint = json['endpoint'];
    return RouteLookupResponse(
      ownerKeyId: json['owner_identity_key_id'] as String,
      deviceId: json['device_id'] as String,
      endpoint: endpoint is Map
          ? DeviceEndpointUpdate.fromJson(endpoint.cast<String, Object?>())
          : null,
    );
  }
}

class DeviceEndpointUpdate {
  const DeviceEndpointUpdate({
    required this.ownerKeyId,
    required this.deviceId,
    required this.p2pTicket,
    required this.createdAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final String ownerKeyId;
  final String deviceId;
  final String p2pTicket;
  final int createdAtUnixMs;
  final int expiresAtUnixMs;

  bool get isExpired =>
      expiresAtUnixMs <= DateTime.now().millisecondsSinceEpoch;

  static DeviceEndpointUpdate fromJson(Map<String, Object?> json) {
    return DeviceEndpointUpdate(
      ownerKeyId: json['owner_identity_key_id'] as String,
      deviceId: json['device_id'] as String,
      p2pTicket: json['p2p_ticket'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class EnvelopeSubmitResponse {
  const EnvelopeSubmitResponse({
    required this.envelopeId,
    required this.storedUntilUnixMs,
  });

  final String envelopeId;
  final int storedUntilUnixMs;

  static EnvelopeSubmitResponse fromJson(Map<String, Object?> json) {
    return EnvelopeSubmitResponse(
      envelopeId: json['envelope_id'] as String,
      storedUntilUnixMs: (json['stored_until_unix_ms'] as num).toInt(),
    );
  }
}

class MailboxPullResponse {
  const MailboxPullResponse({
    required this.recipientKeyId,
    required this.envelopes,
  });

  final String recipientKeyId;
  final List<MailboxEnvelope> envelopes;

  static MailboxPullResponse fromJson(Map<String, Object?> json) {
    return MailboxPullResponse(
      recipientKeyId: json['recipient_key_id'] as String,
      envelopes: (json['envelopes'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => MailboxEnvelope.fromJson(item.cast<String, Object?>()))
          .toList(),
    );
  }
}

class MailboxEnvelope {
  const MailboxEnvelope({
    required this.envelopeId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.envelopeBase64,
    required this.receivedAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final String envelopeId;
  final String senderKeyId;
  final String recipientKeyId;
  final String envelopeBase64;
  final int receivedAtUnixMs;
  final int expiresAtUnixMs;

  static MailboxEnvelope fromJson(Map<String, Object?> json) {
    return MailboxEnvelope(
      envelopeId: json['envelope_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      envelopeBase64: json['envelope_b64'] as String,
      receivedAtUnixMs: (json['received_at_unix_ms'] as num).toInt(),
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class MailboxAckResponse {
  const MailboxAckResponse({required this.deletedCount});

  final int deletedCount;

  static MailboxAckResponse fromJson(Map<String, Object?> json) {
    return MailboxAckResponse(
      deletedCount: (json['deleted_count'] as num).toInt(),
    );
  }
}

class DeliveryStatusResponse {
  const DeliveryStatusResponse({
    required this.senderKeyId,
    required this.items,
  });

  final String senderKeyId;
  final List<DeliveryStatusItem> items;

  static DeliveryStatusResponse fromJson(Map<String, Object?> json) {
    return DeliveryStatusResponse(
      senderKeyId: json['sender_key_id'] as String,
      items: (json['items'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => DeliveryStatusItem.fromJson(item.cast<String, Object?>()),
          )
          .toList(),
    );
  }
}

class DeliveryStatusItem {
  const DeliveryStatusItem({
    required this.envelopeId,
    required this.recipientKeyId,
    required this.status,
    required this.deliveredAtUnixMs,
  });

  final String envelopeId;
  final String? recipientKeyId;
  final String status;
  final int? deliveredAtUnixMs;

  bool get isDelivered => status == 'delivered';

  static DeliveryStatusItem fromJson(Map<String, Object?> json) {
    return DeliveryStatusItem(
      envelopeId: json['envelope_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String?,
      status: json['status'] as String,
      deliveredAtUnixMs: (json['delivered_at_unix_ms'] as num?)?.toInt(),
    );
  }
}

class IntroSessionPublishResponse {
  const IntroSessionPublishResponse({
    required this.sessionId,
    required this.ownerKeyId,
    required this.expiresAtUnixMs,
  });

  final String sessionId;
  final String ownerKeyId;
  final int expiresAtUnixMs;

  static IntroSessionPublishResponse fromJson(Map<String, Object?> json) {
    return IntroSessionPublishResponse(
      sessionId: json['session_id'] as String,
      ownerKeyId: json['owner_key_id'] as String,
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class IntroSessionRespondResponse {
  const IntroSessionRespondResponse({
    required this.sessionId,
    required this.responderKeyId,
    required this.expiresAtUnixMs,
  });

  final String sessionId;
  final String responderKeyId;
  final int expiresAtUnixMs;

  static IntroSessionRespondResponse fromJson(Map<String, Object?> json) {
    return IntroSessionRespondResponse(
      sessionId: json['session_id'] as String,
      responderKeyId: json['responder_key_id'] as String,
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class IntroSessionPollResponse {
  const IntroSessionPollResponse({
    required this.sessionId,
    required this.ownerKeyId,
    required this.responderBundleJson,
    required this.updatedAtUnixMs,
  });

  final String sessionId;
  final String ownerKeyId;
  final String? responderBundleJson;
  final int updatedAtUnixMs;

  bool get hasResponderBundle =>
      responderBundleJson != null && responderBundleJson!.trim().isNotEmpty;

  static IntroSessionPollResponse fromJson(Map<String, Object?> json) {
    final responderBundle = json['responder_bundle'];
    return IntroSessionPollResponse(
      sessionId: json['session_id'] as String,
      ownerKeyId: json['owner_key_id'] as String,
      responderBundleJson: responderBundle is Map
          ? jsonEncode(responderBundle)
          : null,
      updatedAtUnixMs: (json['updated_at_unix_ms'] as num).toInt(),
    );
  }
}

class EnvelopeServerException implements Exception {
  const EnvelopeServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class EnvelopeServerTransportException extends EnvelopeServerException {
  const EnvelopeServerTransportException(super.message);
}

class EnvelopeServerHttpException extends EnvelopeServerException {
  const EnvelopeServerHttpException({
    required this.baseUri,
    required this.statusCode,
    required this.reason,
    required this.apiError,
    required this.responseWasJson,
    required String message,
  }) : super(message);

  final Uri baseUri;
  final int statusCode;
  final String reason;
  final String? apiError;
  final bool responseWasJson;

  bool get isMissingRegisteredDeviceRoute {
    final detail = (apiError == null || apiError!.trim().isEmpty)
        ? message
        : apiError!;
    final normalized = detail.toLowerCase();
    return statusCode == HttpStatus.notFound &&
        normalized.contains('identity has no registered') &&
        normalized.contains('device route');
  }
}

Map<String, Object?> _decodeJsonObject(String json, String label) {
  final decoded = jsonDecode(json);
  if (decoded is Map) return decoded.cast<String, Object?>();
  throw FormatException('$label must be a JSON object');
}

bool _isNodeDiscoveryPath(String path) {
  return path == 'v1/nodes/manifest' || path == 'v1/node/challenge';
}

bool _shouldTryNextNode(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException ||
      error is EnvelopeServerTransportException ||
      error is FormatException) {
    return true;
  }
  if (error is EnvelopeServerHttpException) {
    if (!error.responseWasJson) return true;
    return error.statusCode == HttpStatus.requestTimeout ||
        error.statusCode == HttpStatus.tooManyRequests ||
        error.statusCode >= 500;
  }
  return false;
}

List<Uri> _uniqueUris(Iterable<Uri> uris) {
  final seen = <String>{};
  final result = <Uri>[];
  for (final uri in uris) {
    final key = _uriKey(uri);
    if (seen.add(key)) result.add(uri);
  }
  return result;
}

String _uriKey(Uri uri) {
  final normalized = Uri(
    scheme: uri.scheme.toLowerCase(),
    userInfo: uri.userInfo,
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: '/',
  );
  return normalized.toString();
}

String _displayUri(Uri uri) => _uriKey(uri).replaceFirst(RegExp(r'/$'), '');

Uint8List _secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

String _base64UrlNoPad(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}
