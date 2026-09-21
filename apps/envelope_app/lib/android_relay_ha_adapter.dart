import 'dart:convert';

import 'android_db_store.dart';
import 'android_relay_ha_client.dart';
import 'android_relay_ha_store.dart';
import 'android_server.dart';
import 'envelope_native.dart';

/// Keeps the presentation DTOs used by the UI while replacing every network
/// operation with authenticated v2. No v1 request is issued by this adapter.
class AndroidRelayHaAdapter extends EnvelopeServerClient {
  AndroidRelayHaAdapter(
    super.baseUrl, {
    required this.client,
    required this.database,
    required this.identityJson,
    required this.contactJson,
    required this.actorId,
    required this.native,
  });

  final Future<AndroidRelayHaClient> Function() client;
  final Future<AndroidDbStore> Function() database;
  final String identityJson;
  final String contactJson;
  final String actorId;
  final EnvelopeNative native;
  Uri? _active;
  @override
  Uri get activeBaseUri => _active ?? baseUri;

  Future<Map<String, Object?>> _call(
    String path,
    String kind,
    Map<String, Object?> body, {
    String? operation,
    String method = 'POST',
  }) async {
    final relay = await client();
    try {
      return await relay.request(
        path: path,
        requestKind: kind,
        actorId: actorId,
        operationId:
            operation ?? '$kind-${DateTime.now().microsecondsSinceEpoch}',
        identityJson: identityJson,
        body: body,
        method: method,
      );
    } finally {
      _active = relay.activeBaseUri;
    }
  }

  @override
  Future<Map<String, Object?>> health() async {
    final relay = await client();
    final status = await relay.discover();
    _active = relay.activeBaseUri;
    return status;
  }

  @override
  Future<NodeSetManifest?> refreshNodeManifest({bool force = false}) async {
    await (await client()).discover(force: force);
    return null;
  }

  @override
  Future<DeviceRegistrationResponse> registerDevice({
    required String ownerContactJson,
    required String endpointJson,
  }) async {
    final endpoint = _map(jsonDecode(endpointJson));
    Future<void> register(String version) async {
      await _call('v2/devices/register', 'register_route', {
        'owner_contact': jsonDecode(ownerContactJson),
        'endpoint': endpoint,
        'expected_version': version,
      }, method: 'PUT');
    }

    try {
      await register('0');
    } on RelayHaException catch (error) {
      if (error.code != 'OBJECT_VERSION_CONFLICT') rethrow;
      final lookup = await _call('v2/routes/lookup', 'lookup_route', {
        'owner_key_id': actorId,
        'device_id': endpoint['device_id'],
      });
      await register(lookup['object_version'] as String);
    }
    return DeviceRegistrationResponse(
      ownerKeyId: actorId,
      deviceId: endpoint['device_id'] as String,
      expiresAtUnixMs: (endpoint['expires_at_unix_ms'] as num).toInt(),
    );
  }

  @override
  Future<RouteLookupResponse> lookupRoute({
    required String ownerKeyId,
    required String deviceId,
  }) async {
    final response = await _call('v2/routes/lookup', 'lookup_route', {
      'owner_key_id': ownerKeyId,
      'device_id': deviceId,
    });
    return RouteLookupResponse(
      ownerKeyId: ownerKeyId,
      deviceId: deviceId,
      endpoint: response['endpoint'] == null
          ? null
          : DeviceEndpointUpdate.fromJson(_map(response['endpoint'])),
    );
  }

  static Future<Map<String, Object?>> stageIntent({
    required AndroidDbStore db,
    required String clusterId,
    required String senderKeyId,
    required String recipientKeyId,
    required String envelopeId,
    required String envelopeBase64,
  }) async {
    await stageBatch(
      db: db,
      clusterId: clusterId,
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
      envelopes: {envelopeId: envelopeBase64},
    );
    return (await db.relayHa.outgoing(
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
      envelopeId: envelopeId,
    ))!;
  }

  static Future<void> stageBatch({
    required AndroidDbStore db,
    required String clusterId,
    required String senderKeyId,
    required String recipientKeyId,
    required Map<String, String> envelopes,
  }) async {
    final contact = await db.getKnownContact(recipientKeyId);
    if (contact != null) {
      await db.relayHa.rememberRecipientContact(
        recipientKeyId,
        contact.contactJson,
      );
    }
    final intents = <RelayOutgoingEnvelope>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final envelope in envelopes.entries) {
      final envelopeId = envelope.key;
      final old = await db.relayHa.outgoing(
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
        envelopeId: envelopeId,
      );
      final intent = RelayOutgoingEnvelope(
        clusterId: clusterId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
        envelopeId: envelopeId,
        operationId: old?['operation_id'] as String? ?? 'send-$envelopeId',
        logicalMessageId:
            old?['logical_message_id'] as String? ??
            await db.logicalMessageIdForEnvelope(envelopeId),
        envelopeBase64: envelope.value,
        createdAt: old?['created_at'] as int? ?? now,
        notAfter:
            old?['not_after'] as int? ??
            now + const Duration(days: 7).inMilliseconds,
      );
      intents.add(intent);
    }
    await db.relayHa.stageOutgoing(intents);
  }

  static Map<String, Object?> binding(Map<String, Object?> row) => {
    for (final key in [
      'operation_id',
      'sender_key_id',
      'recipient_key_id',
      'envelope_id',
      'envelope_sha256',
    ])
      key: row[key],
    'not_after': row['not_after'].toString(),
  };

  @override
  Future<EnvelopeSubmitResponse> submitEnvelope({
    required String submitRequestJson,
  }) async {
    final input = _map(jsonDecode(submitRequestJson));
    final db = await database();
    final relay = await client();
    final row = await stageIntent(
      db: db,
      clusterId: relay.clusterId,
      senderKeyId: actorId,
      recipientKeyId: input['recipient_key_id'] as String,
      envelopeId: input['envelope_id'] as String,
      envelopeBase64: input['envelope_b64'] as String,
    );
    late final Map<String, Object?> response;
    try {
      response = await _call('v2/envelopes', 'store_envelope', {
        'binding': binding(row),
        'sender_contact': jsonDecode(contactJson),
        'envelope_b64': row['envelope_b64'],
        'created_at': row['created_at'].toString(),
      }, operation: row['operation_id'] as String);
    } on RelayHaException catch (error) {
      await db.relayHa.recordOutgoingFailure(
        row,
        code: error.code,
        retryable: error.permitsFailover || error.code == 'RATE_LIMITED',
        retryAfter: error.retryAfter,
        now: DateTime.now().millisecondsSinceEpoch,
      );
      rethrow;
    }
    final receipt = response['receipt'] is Map
        ? _map(response['receipt'])
        : response;
    await db.relayHa.applyStorageEvidence(
      jsonEncode(receipt),
      verify: (json) async => native.haV2({
        'op': 'verify_receipt',
        'admin_public': relay.adminPublic,
        'config': relay.config,
        'receipt': jsonDecode(json),
        'binding': binding(row),
      }),
    );
    await db.relayHa.clearOutgoingFailure(row);
    return EnvelopeSubmitResponse(
      envelopeId: row['envelope_id'] as String,
      storedUntilUnixMs: row['not_after'] as int,
    );
  }

  @override
  Future<MailboxPullResponse> pullMailbox({
    required String recipientKeyId,
    required String pullRequestJson,
  }) async {
    if (recipientKeyId != actorId) {
      throw const FormatException('Mailbox identity mismatch');
    }
    final input = _map(jsonDecode(pullRequestJson));
    final db = await database();
    final response = await _call(
      'v2/mailbox/${Uri.encodeComponent(actorId)}/pull',
      'pull_mailbox',
      {
        'limit': input['limit'] ?? 50,
        'cursor': await db.relayHa.mailboxCursor(actorId),
      },
    );
    final relay = await client();
    final items = <MailboxEnvelope>[];
    for (final raw in response['items'] as List) {
      final item = _map(raw);
      final envelope = _map(item['binding']);
      if (envelope['recipient_key_id'] != actorId) {
        throw const FormatException(
          'Pulled envelope belongs to another recipient',
        );
      }
      final hash = native.haV2({
        'op': 'hash',
        'body_b64': item['envelope_b64'],
      });
      if (hash['sha256'] != envelope['envelope_sha256']) {
        throw const FormatException('Pulled envelope hash mismatch');
      }
      native.haV2({
        'op': 'verify_receipt',
        'admin_public': relay.adminPublic,
        'config': relay.config,
        'receipt': item['receipt'],
        'binding': envelope,
      });
      await db.relayHa.markMailboxObserved(envelope);
      items.add(
        MailboxEnvelope(
          envelopeId: envelope['envelope_id'] as String,
          senderKeyId: envelope['sender_key_id'] as String,
          recipientKeyId: actorId,
          envelopeBase64: item['envelope_b64'] as String,
          receivedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
          expiresAtUnixMs: int.parse(envelope['not_after'] as String),
        ),
      );
    }
    await db.relayHa.saveMailboxCursor(
      actorId,
      response['next_cursor'] as String?,
    );
    return MailboxPullResponse(recipientKeyId: actorId, envelopes: items);
  }

  @override
  Future<MailboxAckResponse> ackMailbox({
    required String recipientKeyId,
    required String ackRequestJson,
  }) async {
    if (recipientKeyId != actorId) {
      throw const FormatException('Recipient result identity mismatch');
    }
    final db = await database();
    var acknowledged = 0;
    final pending = (await db.relayHa.pendingResults(
      onlyUnconfirmed: true,
    )).where((row) => row['recipient_key_id'] == actorId).take(50);
    for (final row in pending) {
      final result = await signPendingResult(row);
      final response = await _call(
        'v2/mailbox/${Uri.encodeComponent(actorId)}/results',
        'record_result',
        {'result': result, 'recipient_contact': jsonDecode(contactJson)},
        operation: 'result-${result['result_id']}',
      );
      if (response['status'] == 'replicated') {
        await db.relayHa.markResultReplicated(result);
        acknowledged++;
      }
    }
    // A legacy bad-envelope/partial-file ACK with no committed descriptor never
    // tells v2 to delete ciphertext or manufacture a recipient confirmation.
    return MailboxAckResponse(deletedCount: acknowledged);
  }

  Future<Map<String, Object?>> signPendingResult(
    Map<String, Object?> row,
  ) async {
    if (row['signed_result_json'] is String) {
      return _map(jsonDecode(row['signed_result_json'] as String));
    }
    final descriptor = _map(jsonDecode(row['descriptor_json'] as String));
    final result = native.haV2({
      'op': 'sign_result',
      'identity_json': identityJson,
      'result': {...descriptor, 'signature': ''},
    });
    await (await database()).relayHa.attachSignedResult(
      jsonEncode(result),
      verify: (json) async => native.haV2({
        'op': 'verify_result',
        'result': jsonDecode(json),
        'contact': jsonDecode(contactJson),
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
      }),
    );
    return result;
  }

  @override
  Future<DeliveryStatusResponse> deliveryStatus({
    required String senderKeyId,
    required String statusRequestJson,
  }) async {
    final ids = (_map(jsonDecode(statusRequestJson))['envelope_ids'] as List)
        .cast<String>()
        .toSet();
    final db = await database();
    final rows =
        (await db.relayHa.pendingOutgoing(
              includeBodies: false,
              includeExpired: true,
            ))
            .where(
              (row) =>
                  row['sender_key_id'] == actorId &&
                  ids.contains(row['envelope_id']),
            )
            .toList();
    if (rows.isEmpty) {
      return DeliveryStatusResponse(senderKeyId: actorId, items: const []);
    }
    final response = await _call('v2/delivery/status', 'delivery_status', {
      'bindings': rows.map(binding).toList(),
    });
    final relay = await client();
    final items = <DeliveryStatusItem>[];
    for (final raw in response['items'] as List) {
      final item = _map(raw);
      final itemBinding = _map(item['binding']);
      final matching = rows
          .where(
            (row) =>
                row['envelope_id'] == itemBinding['envelope_id'] &&
                row['recipient_key_id'] == itemBinding['recipient_key_id'],
          )
          .toList();
      if (matching.length != 1 ||
          jsonEncode(binding(matching.single)) != jsonEncode(itemBinding)) {
        // Compare fields, not JSON object order, below.
        if (matching.length != 1 ||
            binding(
              matching.single,
            ).entries.any((e) => itemBinding[e.key] != e.value)) {
          throw const FormatException('Unexpected delivery status binding');
        }
      }
      if (item['receipt'] != null) {
        await db.relayHa.applyStorageEvidence(
          jsonEncode(item['receipt']),
          verify: (json) async => native.haV2({
            'op': 'verify_receipt',
            'admin_public': relay.adminPublic,
            'config': relay.config,
            'receipt': jsonDecode(json),
            'binding': binding(matching.single),
          }),
        );
      }
      final result = item['result'];
      if (result is! Map) continue;
      final recipientId = itemBinding['recipient_key_id'] as String;
      final contact =
          await db.relayHa.recipientContact(recipientId) ??
          (await db.getKnownContact(recipientId))?.contactJson;
      if (contact == null) continue;
      await db.relayHa.applyRecipientResult(
        jsonEncode(result),
        verify: (json) async => native.haV2({
          'op': 'verify_result',
          'result': jsonDecode(json),
          'contact': jsonDecode(contact),
          'binding': binding(matching.single),
        }),
      );
      items.add(
        DeliveryStatusItem(
          envelopeId: itemBinding['envelope_id'] as String,
          recipientKeyId: itemBinding['recipient_key_id'] as String,
          status: result['outcome'] as String,
          deliveredAtUnixMs: result['outcome'] == 'delivered'
              ? int.parse(result['received_at'] as String)
              : null,
        ),
      );
    }
    return DeliveryStatusResponse(senderKeyId: actorId, items: items);
  }

  @override
  Future<IntroSessionPublishResponse> publishIntroSession({
    required String sessionId,
    required String ownerBundleJson,
  }) async {
    final bundle = _map(jsonDecode(ownerBundleJson));
    await _call(
      'v2/intro-sessions/${Uri.encodeComponent(sessionId)}',
      'intro_publish',
      {'session_id': sessionId, 'owner_bundle': bundle},
      method: 'PUT',
      operation: 'intro-publish-$sessionId',
    );
    return IntroSessionPublishResponse(
      sessionId: sessionId,
      ownerKeyId: actorId,
      expiresAtUnixMs: (bundle['expires_at_unix_ms'] as num).toInt(),
    );
  }

  @override
  Future<IntroSessionRespondResponse> respondIntroSession({
    required String sessionId,
    required String responderBundleJson,
  }) async {
    final bundle = _map(jsonDecode(responderBundleJson));
    await _call(
      'v2/intro-sessions/${Uri.encodeComponent(sessionId)}/response',
      'intro_respond',
      {'session_id': sessionId, 'responder_bundle': bundle},
      operation: 'intro-response-$sessionId-$actorId',
    );
    return IntroSessionRespondResponse(
      sessionId: sessionId,
      responderKeyId: actorId,
      expiresAtUnixMs: (bundle['expires_at_unix_ms'] as num).toInt(),
    );
  }

  @override
  Future<IntroSessionPollResponse> pollIntroSessionResponse({
    required String sessionId,
  }) async {
    final response = await _call(
      'v2/intro-sessions/${Uri.encodeComponent(sessionId)}/response',
      'intro_lookup',
      {'session_id': sessionId},
    );
    return IntroSessionPollResponse.fromJson({
      ...response,
      'updated_at_unix_ms':
          int.tryParse(response['object_version']?.toString() ?? '') ?? 0,
    });
  }

  static Map<String, Object?> _map(Object? value) =>
      (value as Map).cast<String, Object?>();
}
