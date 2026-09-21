import 'dart:convert';
import 'dart:io';

import 'package:envelope_app/android_chat_store.dart';
import 'package:envelope_app/android_db_store.dart';
import 'package:envelope_app/android_relay_ha_adapter.dart';
import 'package:envelope_app/android_relay_ha_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late AndroidDbStore store;
  RelayOutgoingEnvelope intent({String body = 'AQID', int expiry = 9000}) =>
      RelayOutgoingEnvelope(
        clusterId: 'cluster',
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopeId: 'envelope',
        operationId: 'operation',
        logicalMessageId: 'message',
        envelopeBase64: body,
        createdAt: 1000,
        notAfter: expiry,
      );
  Future<Map<String, Object?>> row() async => (await store.relayHa.outgoing(
    senderKeyId: 'sender',
    recipientKeyId: 'recipient',
    envelopeId: 'envelope',
  ))!;
  // These tests isolate persistence/transition policy. Crypto is tested by the
  // shared Rust fixtures and the FFI contract tests, not this injected verifier.
  Future<Map<String, Object?>> verified(String value) async =>
      (jsonDecode(value) as Map).cast<String, Object?>();
  Map<String, Object?> result({
    String outcome = 'delivered',
    String seq = '1',
  }) => {
    'version': 2,
    'sender_key_id': 'sender',
    'recipient_key_id': 'recipient',
    'envelope_id': 'envelope',
    'envelope_sha256': intent().envelopeSha256,
    'outcome': outcome,
    'reason_code': '',
    'received_at': '2000',
    'result_id': 'result-$seq',
    'result_sequence': seq,
  };
  Map<String, Object?> receipt(String state) => {
    'protocol_version': 2,
    'cluster_id': 'cluster',
    'operation_id': 'operation',
    'sender_key_id': 'sender',
    'recipient_key_id': 'recipient',
    'envelope_id': 'envelope',
    'envelope_sha256': intent().envelopeSha256,
    'not_after': '9000',
    'storage_state': state,
  };
  Future<void> reopen() async {
    await store.close();
    store = AndroidDbStore.forTesting(
      databaseFactory: databaseFactoryFfi,
      databaseDirectory: directory.path,
    );
    await store.init('test-only');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('envelope-ha-dart-');
    store = AndroidDbStore.forTesting(
      databaseFactory: databaseFactoryFfi,
      databaseDirectory: directory.path,
    );
    await store.init('test-only');
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'outbox ciphertext and immutable operation survive crash/reopen',
    () async {
      await store.relayHa.stageOutgoing([intent()]);
      await reopen();
      expect((await row())['envelope_b64'], 'AQID');
      await store.relayHa.stageOutgoing([intent()]);
      expect(await store.relayHa.pendingOutgoing(), hasLength(1));
      await expectLater(
        store.relayHa.stageOutgoing([intent(body: 'BAUG')]),
        throwsFormatException,
      );
      await expectLater(
        store.relayHa.stageOutgoing([intent(expiry: 9999)]),
        throwsFormatException,
      );
      expect((await row())['not_after'], 9000);
    },
  );

  test('business/outbox batch rolls back together on write failure', () async {
    await expectLater(
      store.relayHa.stageOutgoing(
        [intent()],
        persistBusiness: (txn) async {
          await txn.insert('metadata', {'key': 'business', 'value': 'new'});
          throw StateError('injected commit failure');
        },
      ),
      throwsStateError,
    );
    await reopen();
    expect(await store.relayHa.pendingOutgoing(), isEmpty);
  });

  test(
    'proof failures and stale staging never downgrade or delete body',
    () async {
      await store.relayHa.stageOutgoing([intent()]);
      await expectLater(
        store.relayHa.applyStorageEvidence(
          '{}',
          verify: (_) async {
            throw const FormatException('invalid signature');
          },
        ),
        throwsFormatException,
      );
      expect((await row())['storage_state'], 'local_pending');
      await store.relayHa.applyStorageEvidence(
        jsonEncode(receipt('replicated')),
        verify: verified,
      );
      await store.relayHa.applyStorageEvidence(
        jsonEncode(receipt('staged_single')),
        verify: verified,
      );
      await store.relayHa.releaseTerminalBodies();
      await reopen();
      expect((await row())['storage_state'], 'replicated');
      expect((await row())['delivery_state'], 'pending');
      expect((await row())['envelope_b64'], 'AQID');
    },
  );

  test('chat deletion preserves hidden HA recovery outbox', () async {
    await store.relayHa.stageOutgoing([intent()]);
    await store.addMessage(
      const AndroidMessageRecord(
        envelopeId: 'message',
        conversationId: 'recipient',
        direction: 'outgoing',
        peerKeyId: 'recipient',
        peerDisplayName: 'Recipient',
        createdAtUnixMs: 1000,
        messageCounter: 1,
        text: 'Hello',
        opaqueEnvelopeBase64: 'AQID',
      ),
    );
    await store.deleteMessages(['message']);
    expect((await row())['envelope_b64'], 'AQID');
  });

  test(
    'prepared batch retains unattempted parts before any transport starts',
    () async {
      await AndroidRelayHaAdapter.stageBatch(
        db: store,
        clusterId: 'cluster',
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopes: {'part-a': 'AQID', 'part-b': 'BAUG', 'manifest': 'BwgJ'},
      );
      await store.deleteMessages(['manifest']);
      await reopen();
      final rows = await store.relayHa.pendingOutgoing();
      expect(rows, hasLength(3));
      expect(
        rows.map((row) => row['envelope_b64']),
        containsAll(['AQID', 'BAUG', 'BwgJ']),
      );
      final before = rows.first['not_after'];
      await AndroidRelayHaAdapter.stageBatch(
        db: store,
        clusterId: 'cluster',
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopes: {'part-a': 'AQID', 'part-b': 'BAUG', 'manifest': 'BwgJ'},
      );
      expect(
        (await store.relayHa.pendingOutgoing()).first['not_after'],
        before,
      );
    },
  );

  test(
    'expiry needs independent proof and accepts a late pre-expiry delivered result',
    () async {
      await store.relayHa.stageOutgoing([intent()]);
      await expectLater(
        store.relayHa.applyStorageEvidence(
          jsonEncode({...receipt('replicated'), 'delivery_state': 'expired'}),
          verify: verified,
        ),
        throwsFormatException,
      );
      expect((await row())['delivery_state'], 'pending');
      await store.relayHa.applyRecipientResult(
        jsonEncode(result(outcome: 'deferred')),
        verify: verified,
      );
      await store.relayHa.applyStorageEvidence(
        jsonEncode({
          ...receipt('replicated'),
          'delivery_state': 'expired',
          'expiry_evidence': {'expired_at': '9000'},
        }),
        verify: verified,
      );
      await reopen();
      expect((await row())['delivery_state'], 'expired');
      await store.relayHa.applyStorageEvidence(
        jsonEncode(receipt('replicated')),
        verify: verified,
      );
      expect(
        jsonDecode(
          (await row())['storage_evidence_json'] as String,
        )['delivery_state'],
        'expired',
      );
      await store.relayHa.applyRecipientResult(
        jsonEncode(result(outcome: 'deferred')),
        verify: verified,
      );
      expect((await row())['delivery_state'], 'expired');
      expect(await store.relayHa.pendingOutgoing(), isEmpty);
      expect(
        await store.relayHa.pendingOutgoing(includeExpired: true),
        hasLength(1),
      );
      await expectLater(
        store.relayHa.applyRecipientResult(
          jsonEncode({...result(seq: '2'), 'received_at': '9000'}),
          verify: verified,
        ),
        throwsFormatException,
      );
      await store.relayHa.applyRecipientResult(
        jsonEncode(result(seq: '2')),
        verify: verified,
      );
      expect((await row())['delivery_state'], 'delivered');
    },
  );

  test(
    'retry backoff and terminal validation failure survive restart',
    () async {
      await store.relayHa.stageOutgoing([intent()]);
      final original = await row();
      for (var attempt = 1; attempt <= 7; attempt++) {
        await store.relayHa.recordOutgoingFailure(
          original,
          code: 'NO_QUORUM',
          retryable: true,
          now: 1000,
          jitter: 0.5,
        );
        final retry = (await store.relayHa.outgoingRetry(original))!;
        expect(retry['attempt'], attempt);
        expect(
          retry['next_attempt_at'],
          1000 + (attempt >= 6 ? 30 : 1 << (attempt - 1)) * 1000,
        );
      }
      await store.relayHa.recordOutgoingFailure(
        original,
        code: 'RATE_LIMITED',
        retryable: true,
        now: 1000,
        retryAfter: const Duration(seconds: 90),
        jitter: 0.5,
      );
      expect(
        (await store.relayHa.outgoingRetry(original))!['next_attempt_at'],
        91000,
      );
      await store.relayHa.recordOutgoingFailure(
        original,
        code: 'ID_CONFLICT',
        retryable: false,
        now: 1000,
        jitter: 0.5,
      );
      await reopen();
      expect((await store.relayHa.outgoingRetry(original))!['blocked'], isTrue);
      expect((await row())['envelope_b64'], 'AQID');
      expect((await row())['not_after'], 9000);
    },
  );

  test(
    'recipient trust for outstanding messages survives address-book changes',
    () async {
      await store.relayHa.rememberRecipientContact(
        'recipient',
        '{"key_id":"recipient"}',
      );
      await store.relayHa.rememberRecipientContact(
        'recipient',
        '{"key_id":"other"}',
      );
      await reopen();
      expect(
        await store.relayHa.recipientContact('recipient'),
        '{"key_id":"recipient"}',
      );
    },
  );

  test(
    'result descriptor and business write commit atomically and dedup',
    () async {
      var applications = 0;
      Future<void> apply(DatabaseExecutor txn) async {
        applications++;
        await txn.insert('metadata', {'key': 'received', 'value': 'durable'});
      }

      final first = await store.relayHa.persistIncomingResult(
        result(),
        persistBusiness: apply,
      );
      await reopen();
      final duplicate = await store.relayHa.persistIncomingResult(
        result(seq: '2'),
        persistBusiness: apply,
      );
      expect(duplicate, first);
      expect(applications, 1);
      expect(
        (await store.relayHa.pendingResults()).single['signed_result_json'],
        isNull,
      );
      await store.relayHa.attachSignedResult(
        jsonEncode({...first, 'signature': 'signed'}),
        verify: verified,
      );
      await reopen();
      expect(
        (await store.relayHa.pendingResults()).single['signed_result_json'],
        contains('signed'),
      );
    },
  );

  test(
    'cannot sign unknown descriptor or changed outcome after local commit',
    () async {
      await expectLater(
        store.relayHa.attachSignedResult(
          jsonEncode(result()),
          verify: verified,
        ),
        throwsFormatException,
      );
      await store.relayHa.persistIncomingResult(
        result(outcome: 'deferred'),
        persistBusiness: (_) async {},
      );
      await expectLater(
        store.relayHa.attachSignedResult(
          jsonEncode(result()),
          verify: verified,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'deferred keeps body and final signed result permits cleanup only once',
    () async {
      await store.relayHa.stageOutgoing([intent()]);
      await store.relayHa.applyRecipientResult(
        jsonEncode(result(outcome: 'deferred')),
        verify: verified,
      );
      await store.relayHa.releaseTerminalBodies();
      expect((await row())['envelope_b64'], 'AQID');
      await store.relayHa.applyRecipientResult(
        jsonEncode(result(seq: '2')),
        verify: verified,
      );
      await store.relayHa.releaseTerminalBodies();
      await reopen();
      expect((await row())['envelope_b64'], '');
      expect((await row())['envelope_sha256'], intent().envelopeSha256);
      await store.relayHa.stageOutgoing([intent()]);
      expect((await row())['envelope_b64'], '');
      await expectLater(
        store.relayHa.applyRecipientResult(
          jsonEncode(result(outcome: 'rejected', seq: '2')),
          verify: verified,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'file completion upgrades all parts only after durable file/chat reference',
    () async {
      await store.upsertInboundFileChunk(
        transferId: 'file',
        chunkIndex: 0,
        chunkSha256: 'chunk-hash',
        chunkSize: 3,
        envelopeId: 'part',
        chunkDataBase64: 'AQID',
      );
      await store.relayHa.recordFilePart(
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopeId: 'part',
        envelopeBase64: 'AQID',
        transferId: 'file',
        receivedAt: 1000,
      );
      final deferred = (await store.relayHa.pendingResults()).single;
      expect(deferred['outcome'], 'deferred');
      final raw = await databaseFactoryFfi.openDatabase(
        '${directory.path}/envelope_chat_secure.db',
      );
      await raw.insert('file_transfers', {
        'transfer_id': 'file',
        'message_envelope_id': 'manifest',
        'direction': 'incoming',
        'peer_key_id': 'sender',
        'peer_display_name': 'Sender',
        'created_at_unix_ms': 1000,
        'message_counter': 1,
        'filename': 'test.bin',
        'mime': 'application/octet-stream',
        'total_size': 3,
        'chunk_size': 3,
        'chunk_count': 1,
        'file_sha256': 'hash',
        'manifest_envelope_id': 'manifest',
        'manifest_envelope_b64': 'BAUG',
        'manifest_json': '{}',
        'status': 'received',
        'saved_path': '/durable/test.bin',
      });
      await store.relayHa.recordFilePart(
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopeId: 'manifest',
        envelopeBase64: 'BAUG',
        transferId: 'file',
        receivedAt: 2000,
      );
      expect(
        (await store.relayHa.pendingResults()).every(
          (r) => r['outcome'] == 'deferred',
        ),
        isTrue,
      );
      await store.addMessage(
        const AndroidMessageRecord(
          envelopeId: 'manifest',
          conversationId: 'sender',
          direction: 'incoming',
          peerKeyId: 'sender',
          peerDisplayName: 'Sender',
          createdAtUnixMs: 1000,
          messageCounter: 1,
          text: 'File',
          opaqueEnvelopeBase64: '',
          attachmentUri: 'file:///durable/test.bin',
        ),
        recipientIdentityKeyId: 'recipient',
      );
      await store.relayHa.recordFilePart(
        senderKeyId: 'sender',
        recipientKeyId: 'recipient',
        envelopeId: 'manifest',
        envelopeBase64: 'BAUG',
        transferId: 'file',
        receivedAt: 3000,
      );
      await reopen();
      final complete = await store.relayHa.relatedFileResults(
        'manifest',
        'sender',
        'recipient',
      );
      expect(complete, hasLength(2));
      expect(
        complete.every(
          (r) => r['outcome'] == 'delivered' && r['result_sequence'] == '2',
        ),
        isTrue,
      );
      expect(
        await store.relayHa.relatedFileResults(
          'manifest',
          'stranger',
          'recipient',
        ),
        isEmpty,
      );
    },
  );
}
