import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

enum RelayStorageState { localPending, stagedSingle, replicated }

enum RelayDeliveryState { pending, deferred, delivered, rejected, expired }

extension RelayStorageStateValue on RelayStorageState {
  String get wireValue => switch (this) {
    RelayStorageState.localPending => 'local_pending',
    RelayStorageState.stagedSingle => 'staged_single',
    RelayStorageState.replicated => 'replicated',
  };
}

/// Immutable send intent. Its ciphertext, operation and expiry survive retries.
class RelayOutgoingEnvelope {
  RelayOutgoingEnvelope({
    required this.clusterId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.envelopeId,
    required this.operationId,
    required this.logicalMessageId,
    required this.envelopeBase64,
    required this.createdAt,
    required this.notAfter,
  }) {
    if ([
          clusterId,
          senderKeyId,
          recipientKeyId,
          envelopeId,
          operationId,
          logicalMessageId,
        ].any((value) => value.trim().isEmpty) ||
        createdAt < 0 ||
        notAfter <= createdAt ||
        base64Url.decode(base64Url.normalize(envelopeBase64)).isEmpty) {
      throw const FormatException('Invalid HA outbox intent');
    }
  }

  final String clusterId;
  final String senderKeyId;
  final String recipientKeyId;
  final String envelopeId;
  final String operationId;
  final String logicalMessageId;
  final String envelopeBase64;
  final int createdAt;
  final int notAfter;

  String get envelopeSha256 => base64Url
      .encode(
        sha256
            .convert(base64Url.decode(base64Url.normalize(envelopeBase64)))
            .bytes,
      )
      .replaceAll('=', '');

  Map<String, Object?> toRow() => {
    'cluster_id': clusterId,
    'sender_key_id': senderKeyId,
    'recipient_key_id': recipientKeyId,
    'envelope_id': envelopeId,
    'operation_id': operationId,
    'logical_message_id': logicalMessageId,
    'envelope_b64': envelopeBase64,
    'envelope_sha256': envelopeSha256,
    'created_at': createdAt,
    'not_after': notAfter,
    'storage_state': 'local_pending',
    'delivery_state': 'pending',
  };
}

/// The verifier must use the shared Rust v2 implementation with a trusted
/// cluster configuration/contact. JSON parsing or an HTTP 200 is not verification.
typedef RelayProofVerifier = Future<Map<String, Object?>> Function(String json);

/// Separate from legacy pending_envelopes: deleting chat presentation cannot
/// delete HA recovery material. Legacy ACKs never enter these tables.
class AndroidRelayHaStore {
  AndroidRelayHaStore(this._db);

  final Database _db;
  static const _identityWhere =
      'sender_key_id = ? AND recipient_key_id = ? AND envelope_id = ?';

  Future<void> rememberRecipientContact(
    String keyId,
    String contactJson,
  ) async {
    await _db.insert('metadata', {
      'key': 'relay_ha_contact:$keyId',
      'value': contactJson,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<String?> recipientContact(String keyId) async {
    final rows = await _db.query(
      'metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['relay_ha_contact:$keyId'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  String _retryKey(Map<String, Object?> row) =>
      'relay_ha_retry:${jsonEncode(_identity(row))}';

  Future<Map<String, Object?>?> outgoingRetry(Map<String, Object?> row) async {
    final entries = await _db.query(
      'metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_retryKey(row)],
      limit: 1,
    );
    return entries.isEmpty
        ? null
        : (jsonDecode(entries.single['value'] as String) as Map)
              .cast<String, Object?>();
  }

  Future<void> recordOutgoingFailure(
    Map<String, Object?> row, {
    required String code,
    required bool retryable,
    required int now,
    Duration? retryAfter,
    double? jitter,
  }) async {
    final old = await outgoingRetry(row);
    final attempt = ((old?['attempt'] as int?) ?? 0) + 1;
    final seconds = attempt >= 6 ? 30 : 1 << (attempt - 1);
    final delay =
        (seconds *
                1000 *
                (0.8 + (jitter ?? Random.secure().nextDouble()) * 0.4))
            .round();
    final floor = retryAfter?.inMilliseconds ?? 0;
    await _db.insert('metadata', {
      'key': _retryKey(row),
      'value': jsonEncode({
        'attempt': attempt,
        'code': code,
        'blocked': !retryable,
        'next_attempt_at': now + max(delay, floor),
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearOutgoingFailure(Map<String, Object?> row) async {
    await _db.delete('metadata', where: 'key = ?', whereArgs: [_retryKey(row)]);
  }

  static Future<void> createTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_ha_outbox (
        sender_key_id TEXT NOT NULL, recipient_key_id TEXT NOT NULL,
        envelope_id TEXT NOT NULL, cluster_id TEXT NOT NULL,
        operation_id TEXT NOT NULL, logical_message_id TEXT NOT NULL,
        envelope_b64 TEXT NOT NULL, envelope_sha256 TEXT NOT NULL,
        created_at INTEGER NOT NULL, not_after INTEGER NOT NULL,
        storage_state TEXT NOT NULL CHECK(storage_state IN
          ('local_pending','staged_single','replicated')),
        delivery_state TEXT NOT NULL CHECK(delivery_state IN
          ('pending','deferred','delivered','rejected','expired')),
        storage_evidence_json TEXT, result_evidence_json TEXT,
        result_sequence TEXT, result_id TEXT,
        PRIMARY KEY(sender_key_id, recipient_key_id, envelope_id),
        UNIQUE(sender_key_id, operation_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_ha_result_outbox (
        sender_key_id TEXT NOT NULL, recipient_key_id TEXT NOT NULL,
        envelope_id TEXT NOT NULL, envelope_sha256 TEXT NOT NULL,
        descriptor_json TEXT NOT NULL, signed_result_json TEXT,
        submitted_result_id TEXT,
        result_sequence TEXT NOT NULL, result_id TEXT NOT NULL,
        outcome TEXT NOT NULL CHECK(outcome IN ('deferred','delivered','rejected')),
        PRIMARY KEY(sender_key_id, recipient_key_id, envelope_id),
        UNIQUE(recipient_key_id, result_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_ha_cluster_state (
        cluster_id TEXT PRIMARY KEY, state_json TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_ha_file_parts (
        sender_key_id TEXT NOT NULL, recipient_key_id TEXT NOT NULL,
        envelope_id TEXT NOT NULL, envelope_sha256 TEXT NOT NULL,
        transfer_id TEXT NOT NULL, received_at INTEGER NOT NULL,
        PRIMARY KEY(sender_key_id, recipient_key_id, envelope_id)
      )
    ''');
  }

  /// The optional business callback executes in the SAME transaction and must
  /// use its executor, never call back into AndroidDbStore (which would deadlock).
  Future<void> stageOutgoing(
    List<RelayOutgoingEnvelope> envelopes, {
    Future<void> Function(DatabaseExecutor txn)? persistBusiness,
  }) async {
    if (envelopes.isEmpty) throw ArgumentError('HA outbox batch is empty');
    await _db.transaction((txn) async {
      for (final envelope in envelopes) {
        final row = envelope.toRow();
        final existing = await txn.query(
          'relay_ha_outbox',
          where: _identityWhere,
          whereArgs: _identity(row),
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final old = existing.single;
          for (final key in [
            'cluster_id',
            'operation_id',
            'envelope_sha256',
            'created_at',
            'not_after',
            'logical_message_id',
          ]) {
            if (old[key] != row[key]) {
              throw const FormatException('HA outbox ID_CONFLICT');
            }
          }
          continue;
        }
        await txn.insert('relay_ha_outbox', row);
      }
      await persistBusiness?.call(txn);
    });
  }

  static const _outboxMetadataColumns = [
    'sender_key_id',
    'recipient_key_id',
    'envelope_id',
    'cluster_id',
    'operation_id',
    'logical_message_id',
    'envelope_sha256',
    'created_at',
    'not_after',
    'storage_state',
    'delivery_state',
  ];

  Future<List<Map<String, Object?>>> pendingOutgoing({
    bool includeBodies = true,
    bool includeExpired = false,
  }) => _db.query(
    'relay_ha_outbox',
    columns: includeBodies ? null : _outboxMetadataColumns,
    where: includeExpired
        ? "delivery_state IN ('pending','deferred','expired') AND envelope_b64 <> ''"
        : "delivery_state IN ('pending','deferred') AND envelope_b64 <> ''",
    orderBy: 'created_at ASC',
  );

  Future<List<Map<String, Object?>>> outgoingForLogicalMessage(
    String logicalMessageId,
  ) => _db.query(
    'relay_ha_outbox',
    columns: _outboxMetadataColumns,
    where: 'logical_message_id = ?',
    whereArgs: [logicalMessageId],
  );

  Future<Map<String, Object?>?> outgoing({
    required String senderKeyId,
    required String recipientKeyId,
    required String envelopeId,
  }) async {
    final rows = await _db.query(
      'relay_ha_outbox',
      where: _identityWhere,
      whereArgs: [senderKeyId, recipientKeyId, envelopeId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> applyStorageEvidence(
    String receiptJson, {
    required RelayProofVerifier verify,
  }) async {
    // Verification deliberately precedes state access/mutation. Exceptions
    // leave the durable outbox unchanged, including ciphertext and fixed TTL.
    final receipt = await verify(receiptJson);
    final storage = receipt['storage_state'];
    if (receipt['protocol_version'] != 2 ||
        (storage != 'staged_single' && storage != 'replicated')) {
      throw const FormatException('Invalid v2 storage proof');
    }
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'relay_ha_outbox',
        where: _identityWhere,
        whereArgs: _identity(receipt),
        limit: 1,
      );
      if (rows.isEmpty) throw const FormatException('Unknown HA send intent');
      final old = rows.single;
      for (final key in ['cluster_id', 'operation_id', 'envelope_sha256']) {
        if (receipt[key] != old[key]) {
          throw const FormatException('Storage proof does not match outbox');
        }
      }
      if (receipt['not_after'] != old['not_after'].toString()) {
        throw const FormatException('Storage proof changed fixed expiry');
      }
      if (old['storage_state'] == 'replicated' && storage != 'replicated') {
        return; // A delayed staging proof cannot downgrade known durability.
      }
      final expiry = receipt['expiry_evidence'];
      final expired = receipt['delivery_state'] == 'expired';
      if (expired &&
          (storage != 'replicated' ||
              expiry is! Map ||
              BigInt.parse(expiry['expired_at'] as String) <
                  BigInt.from(old['not_after'] as int))) {
        throw const FormatException(
          'Expiry requires independently verified durable evidence',
        );
      }
      if (old['delivery_state'] == 'expired' && !expired) {
        return; // Retain the independent expiry proof when a stale store receipt arrives.
      }
      await txn.update(
        'relay_ha_outbox',
        {
          'storage_state': storage,
          'storage_evidence_json': receiptJson,
          if (expired &&
              old['delivery_state'] != 'delivered' &&
              old['delivery_state'] != 'rejected')
            'delivery_state': 'expired',
        },
        where: _identityWhere,
        whereArgs: _identity(receipt),
      );
    });
  }

  Future<void> applyRecipientResult(
    String resultJson, {
    required RelayProofVerifier verify,
  }) async {
    final result = await verify(resultJson);
    _validateDescriptor(result);
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'relay_ha_outbox',
        where: _identityWhere,
        whereArgs: _identity(result),
        limit: 1,
      );
      if (rows.isEmpty ||
          rows.single['envelope_sha256'] != result['envelope_sha256']) {
        throw const FormatException('Recipient result does not match outbox');
      }
      final old = rows.single;
      final sequence = BigInt.parse(result['result_sequence'] as String);
      final oldSequence = BigInt.tryParse(
        old['result_sequence']?.toString() ?? '',
      );
      if (oldSequence != null && sequence <= oldSequence) {
        final lastResult = old['result_evidence_json'] == null
            ? null
            : jsonDecode(old['result_evidence_json'] as String) as Map;
        if (sequence == oldSequence &&
            (old['result_id'] != result['result_id'] ||
                (lastResult?['outcome'] ?? old['delivery_state']) !=
                    result['outcome'])) {
          throw const FormatException('Conflicting recipient result sequence');
        }
        return;
      }
      final state = old['delivery_state'];
      final latePreExpiryDelivery =
          state == 'expired' &&
          result['outcome'] == 'delivered' &&
          BigInt.parse(result['received_at'] as String) <
              BigInt.from(old['not_after'] as int);
      if (state == 'delivered' ||
          state == 'rejected' ||
          (state == 'expired' && !latePreExpiryDelivery)) {
        throw const FormatException(
          'Terminal delivery result cannot be replaced',
        );
      }
      await txn.update(
        'relay_ha_outbox',
        {
          'delivery_state': result['outcome'],
          'result_evidence_json': resultJson,
          'result_sequence': result['result_sequence'],
          'result_id': result['result_id'],
        },
        where: _identityWhere,
        whereArgs: _identity(result),
      );
    });
  }

  /// Call ONLY after validating/decrypting the envelope. A delivered descriptor
  /// requires persistBusiness; partial files must use deferred, not delivered.
  /// Signing happens after this function commits, so a crash can sign the same
  /// persisted result_id/sequence without repeating the business effects.
  Future<Map<String, Object?>> persistIncomingResult(
    Map<String, Object?> descriptor, {
    required Future<void> Function(DatabaseExecutor txn) persistBusiness,
  }) async {
    _validateDescriptor(descriptor);
    if (descriptor.containsKey('signature')) {
      throw const FormatException('Result must not be signed before commit');
    }
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'relay_ha_result_outbox',
        where: _identityWhere,
        whereArgs: _identity(descriptor),
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final old = rows.single;
        if (old['envelope_sha256'] != descriptor['envelope_sha256']) {
          throw const FormatException('Incoming HA ID_CONFLICT');
        }
        if (old['outcome'] != 'deferred') return _json(old['descriptor_json']);
        final oldSequence = BigInt.parse(old['result_sequence'] as String);
        final nextSequence = BigInt.parse(
          descriptor['result_sequence'] as String,
        );
        if (nextSequence <= oldSequence) return _json(old['descriptor_json']);
      }
      await persistBusiness(txn);
      final row = <String, Object?>{
        for (final key in [
          'sender_key_id',
          'recipient_key_id',
          'envelope_id',
          'envelope_sha256',
          'result_sequence',
          'result_id',
          'outcome',
        ])
          key: descriptor[key],
        'descriptor_json': jsonEncode(descriptor),
        'signed_result_json': null,
      };
      if (rows.isEmpty) {
        await txn.insert('relay_ha_result_outbox', row);
      } else {
        await txn.update(
          'relay_ha_result_outbox',
          row,
          where: _identityWhere,
          whereArgs: _identity(descriptor),
        );
      }
      return Map<String, Object?>.from(descriptor);
    });
  }

  Future<void> attachSignedResult(
    String resultJson, {
    required RelayProofVerifier verify,
  }) async {
    final result = await verify(resultJson);
    _validateDescriptor(result);
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'relay_ha_result_outbox',
        where: _identityWhere,
        whereArgs: _identity(result),
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const FormatException('No committed result descriptor');
      }
      final descriptor = _json(rows.single['descriptor_json']);
      for (final entry in descriptor.entries) {
        if (result[entry.key] != entry.value) {
          throw const FormatException(
            'Signed result differs from committed descriptor',
          );
        }
      }
      await txn.update(
        'relay_ha_result_outbox',
        {'signed_result_json': resultJson},
        where: _identityWhere,
        whereArgs: _identity(result),
      );
    });
  }

  Future<List<Map<String, Object?>>> pendingResults({
    bool onlyUnconfirmed = false,
  }) => _db.query(
    'relay_ha_result_outbox',
    where: onlyUnconfirmed
        ? 'submitted_result_id IS NULL OR submitted_result_id <> result_id'
        : null,
  );

  Future<void> markResultReplicated(Map<String, Object?> result) async {
    await _db.update(
      'relay_ha_result_outbox',
      {'submitted_result_id': result['result_id']},
      where: '$_identityWhere AND result_id = ?',
      whereArgs: [..._identity(result), result['result_id']],
    );
  }

  Future<List<Map<String, Object?>>> relatedFileResults(
    String envelopeId,
    String senderKeyId,
    String recipientKeyId,
  ) async {
    return _db.rawQuery(
      '''
      SELECT result.* FROM relay_ha_result_outbox result
      JOIN relay_ha_file_parts part ON part.sender_key_id = result.sender_key_id
        AND part.recipient_key_id = result.recipient_key_id AND part.envelope_id = result.envelope_id
      WHERE part.transfer_id IN (SELECT transfer_id FROM relay_ha_file_parts WHERE envelope_id = ?)
      AND part.sender_key_id = ? AND part.recipient_key_id = ?
      AND result.outcome = 'delivered'
    ''',
      [envelopeId, senderKeyId, recipientKeyId],
    );
  }

  /// Called after the file importer persisted the verified part. A crash before
  /// this record is retried from the same server/P2P envelope. Completion checks
  /// the durable file/chat reference before upgrading ALL part descriptors.
  Future<void> recordFilePart({
    required String senderKeyId,
    required String recipientKeyId,
    required String envelopeId,
    required String envelopeBase64,
    required String transferId,
    required int receivedAt,
  }) async {
    final hash = base64Url
        .encode(
          sha256
              .convert(base64Url.decode(base64Url.normalize(envelopeBase64)))
              .bytes,
        )
        .replaceAll('=', '');
    await _db.transaction((txn) async {
      final identity = [senderKeyId, recipientKeyId, envelopeId];
      final old = await txn.query(
        'relay_ha_file_parts',
        where: _identityWhere,
        whereArgs: identity,
        limit: 1,
      );
      if (old.isNotEmpty &&
          (old.single['envelope_sha256'] != hash ||
              old.single['transfer_id'] != transferId)) {
        throw const FormatException('File part HA ID_CONFLICT');
      }
      await txn.insert('relay_ha_file_parts', {
        'sender_key_id': senderKeyId,
        'recipient_key_id': recipientKeyId,
        'envelope_id': envelopeId,
        'envelope_sha256': hash,
        'transfer_id': transferId,
        'received_at': receivedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final transfers = await txn.query(
        'file_transfers',
        where: 'transfer_id = ?',
        whereArgs: [transferId],
        limit: 1,
      );
      var complete = false;
      if (transfers.isNotEmpty && transfers.single['status'] == 'received') {
        final messages = await txn.query(
          'messages',
          where: 'envelope_id = ? AND attachment_uri IS NOT NULL',
          whereArgs: [transfers.single['message_envelope_id']],
          limit: 1,
        );
        complete = messages.isNotEmpty;
      }
      final chunks = await txn.query(
        'file_transfer_chunks',
        columns: ['envelope_id'],
        where: 'transfer_id = ? AND envelope_id = ?',
        whereArgs: [transferId, envelopeId],
        limit: 1,
      );
      if (!complete &&
          chunks.isEmpty &&
          (transfers.isEmpty ||
              transfers.single['manifest_envelope_id'] != envelopeId)) {
        throw const FormatException('File part has no persisted business data');
      }
      final parts = complete
          ? await txn.query(
              'relay_ha_file_parts',
              where:
                  'sender_key_id = ? AND recipient_key_id = ? AND transfer_id = ?',
              whereArgs: [senderKeyId, recipientKeyId, transferId],
            )
          : await txn.query(
              'relay_ha_file_parts',
              where: _identityWhere,
              whereArgs: identity,
            );
      for (final part in parts) {
        final existing = await txn.query(
          'relay_ha_result_outbox',
          where: _identityWhere,
          whereArgs: _identity(part),
          limit: 1,
        );
        final outcome = complete ? 'delivered' : 'deferred';
        if (existing.isNotEmpty && existing.single['outcome'] == outcome) {
          continue;
        }
        if (existing.isNotEmpty && existing.single['outcome'] != 'deferred') {
          continue;
        }
        final result = <String, Object?>{
          'version': 2,
          for (final key in [
            'sender_key_id',
            'recipient_key_id',
            'envelope_id',
            'envelope_sha256',
          ])
            key: part[key],
          'outcome': outcome,
          'reason_code': complete ? '' : 'FILE_INCOMPLETE',
          'received_at': (complete ? receivedAt : part['received_at'])
              .toString(),
          'result_id': base64Url
              .encode(
                sha256
                    .convert(
                      utf8.encode(
                        jsonEncode([
                          senderKeyId,
                          recipientKeyId,
                          part['envelope_id'],
                          part['envelope_sha256'],
                          outcome,
                        ]),
                      ),
                    )
                    .bytes,
              )
              .replaceAll('=', ''),
          'result_sequence': complete ? '2' : '1',
        };
        final row = <String, Object?>{
          for (final key in [
            'sender_key_id',
            'recipient_key_id',
            'envelope_id',
            'envelope_sha256',
            'result_id',
            'result_sequence',
            'outcome',
          ])
            key: result[key],
          'descriptor_json': jsonEncode(result),
          'signed_result_json': null,
        };
        if (existing.isEmpty) {
          await txn.insert('relay_ha_result_outbox', row);
        } else {
          await txn.update(
            'relay_ha_result_outbox',
            row,
            where: _identityWhere,
            whereArgs: _identity(part),
          );
        }
      }
    });
  }

  Future<String?> mailboxCursor(String recipientKeyId) async {
    final rows = await _db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['relay_ha_cursor:$recipientKeyId'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String?;
  }

  Future<void> saveMailboxCursor(String recipientKeyId, String? cursor) async {
    await _db.insert('metadata', {
      'key': 'relay_ha_cursor:$recipientKeyId',
      'value': cursor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markMailboxObserved(Map<String, Object?> binding) async {
    await _db.insert('metadata', {
      'key': 'relay_ha_mailbox:${jsonEncode(_identity(binding))}',
      'value': jsonEncode(binding),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> wasMailboxObserved(Map<String, Object?> result) async =>
      (await _db.query(
        'metadata',
        columns: ['key'],
        where: 'key = ?',
        whereArgs: ['relay_ha_mailbox:${jsonEncode(_identity(result))}'],
        limit: 1,
      )).isNotEmpty;

  Future<Map<String, Object?>?> incomingResult({
    required String senderKeyId,
    required String recipientKeyId,
    required String envelopeId,
  }) async {
    final rows = await _db.query(
      'relay_ha_result_outbox',
      where: _identityWhere,
      whereArgs: [senderKeyId, recipientKeyId, envelopeId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<void> recordOutcomeInTransaction(
    DatabaseExecutor txn, {
    required String senderKeyId,
    required String recipientKeyId,
    required String envelopeId,
    required String envelopeBase64,
    required int receivedAt,
    String outcome = 'delivered',
    String reasonCode = '',
  }) async {
    // Streaming/chunked files deliberately have no message-level opaque body.
    // They need the file transaction to resolve individual part descriptors.
    if (envelopeBase64.isEmpty) return;
    final hash = base64Url
        .encode(
          sha256
              .convert(base64Url.decode(base64Url.normalize(envelopeBase64)))
              .bytes,
        )
        .replaceAll('=', '');
    final descriptor = <String, Object?>{
      'version': 2,
      'sender_key_id': senderKeyId,
      'recipient_key_id': recipientKeyId,
      'envelope_id': envelopeId,
      'envelope_sha256': hash,
      'outcome': outcome,
      'reason_code': reasonCode,
      'received_at': receivedAt.toString(),
      'result_id': base64Url
          .encode(
            sha256
                .convert(
                  utf8.encode(
                    jsonEncode([
                      senderKeyId,
                      recipientKeyId,
                      envelopeId,
                      hash,
                      outcome,
                    ]),
                  ),
                )
                .bytes,
          )
          .replaceAll('=', ''),
      'result_sequence': '1',
    };
    final rows = await txn.query(
      'relay_ha_result_outbox',
      where: _identityWhere,
      whereArgs: _identity(descriptor),
      limit: 1,
    );
    if (rows.isNotEmpty) {
      if (rows.single['envelope_sha256'] != hash) {
        throw const FormatException('Incoming HA ID_CONFLICT');
      }
      if (rows.single['outcome'] != 'deferred' ||
          rows.single['outcome'] == outcome) {
        return;
      }
      descriptor['result_sequence'] =
          (BigInt.parse(rows.single['result_sequence'] as String) + BigInt.one)
              .toString();
    }
    final row = <String, Object?>{
      for (final key in [
        'sender_key_id',
        'recipient_key_id',
        'envelope_id',
        'envelope_sha256',
        'result_sequence',
        'result_id',
        'outcome',
      ])
        key: descriptor[key],
      'descriptor_json': jsonEncode(descriptor),
      'signed_result_json': null,
    };
    if (rows.isEmpty) {
      await txn.insert('relay_ha_result_outbox', row);
    } else {
      await txn.update(
        'relay_ha_result_outbox',
        row,
        where: _identityWhere,
        whereArgs: _identity(descriptor),
      );
    }
  }

  Future<Map<String, Object?>?> clusterState(String clusterId) async {
    final rows = await _db.query(
      'relay_ha_cluster_state',
      where: 'cluster_id = ?',
      whereArgs: [clusterId],
      limit: 1,
    );
    return rows.isEmpty ? null : _json(rows.single['state_json']);
  }

  /// Configuration/status must already have passed the shared native verifier.
  /// The transaction also prevents racing discovery tasks from persisting a
  /// lower trust watermark over a newer observation.
  Future<void> saveClusterState(Map<String, Object?> state) async {
    final watermark = (state['watermark'] as Map).cast<String, Object?>();
    final clusterId = watermark['cluster_id'] as String;
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'relay_ha_cluster_state',
        where: 'cluster_id = ?',
        whereArgs: [clusterId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final oldState = _json(rows.single['state_json']);
        final old = (oldState['watermark'] as Map).cast<String, Object?>();
        final generation = BigInt.parse(
          watermark['control_generation'] as String,
        );
        final oldGeneration = BigInt.parse(old['control_generation'] as String);
        final epoch = BigInt.parse(watermark['config_epoch'] as String);
        final oldEpoch = BigInt.parse(old['config_epoch'] as String);
        if (generation < oldGeneration ||
            epoch < oldEpoch ||
            (generation > oldGeneration && epoch <= oldEpoch) ||
            (generation == oldGeneration &&
                BigInt.parse(watermark['leader_term'] as String) <
                    BigInt.parse(old['leader_term'] as String))) {
          throw const FormatException('HA trust watermark rollback');
        }
      }
      await txn.insert('relay_ha_cluster_state', {
        'cluster_id': clusterId,
        'state_json': jsonEncode(state),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // Terminal identity/hash guards remain after body deletion. Replicated by
  // itself is deliberately insufficient for release in first-release policy.
  Future<int> releaseTerminalBodies() => _db.update(
    'relay_ha_outbox',
    {'envelope_b64': ''},
    where:
        "delivery_state IN ('delivered','rejected') AND result_evidence_json IS NOT NULL",
  );

  static List<Object?> _identity(Map<String, Object?> value) => [
    value['sender_key_id'],
    value['recipient_key_id'],
    value['envelope_id'],
  ];

  static Map<String, Object?> _json(Object? value) =>
      (jsonDecode(value as String) as Map).cast<String, Object?>();

  static void _validateDescriptor(Map<String, Object?> value) {
    if (value['version'] != 2 ||
        !['deferred', 'delivered', 'rejected'].contains(value['outcome']) ||
        [
          'sender_key_id',
          'recipient_key_id',
          'envelope_id',
          'envelope_sha256',
          'result_id',
        ].any(
          (key) => value[key] is! String || (value[key] as String).isEmpty,
        ) ||
        ['received_at', 'result_sequence'].any(
          (key) =>
              value[key] is! String ||
              !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value[key] as String),
        )) {
      throw const FormatException('Invalid v2 recipient result descriptor');
    }
  }
}
