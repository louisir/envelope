import 'dart:convert';
import 'dart:io';

import 'package:envelope_app/android_chat_store.dart';
import 'package:envelope_app/android_db_store.dart';
import 'package:envelope_app/android_mailbox_reliability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Run the production schema, migrations and transactions on real SQLite.
// This verifies persistence, not Android SQLCipher encryption or device I/O.
void main() {
  sqfliteFfiInit();
  late Directory directory;
  late AndroidDbStore store;
  late int now;

  Future<Database> rawDatabase() => databaseFactoryFfi.openDatabase(
    p.join(directory.path, 'envelope_chat_secure.db'),
  );

  Future<void> reopen() async {
    await store.close();
    store = AndroidDbStore.forTesting(
      databaseFactory: databaseFactoryFfi,
      databaseDirectory: directory.path,
    );
    await store.init('test-only-not-encrypted');
  }

  AndroidGroupRecord group(int epoch) => AndroidGroupRecord(
    groupId: 'group-1',
    name: 'Group $epoch',
    ownerKeyId: 'owner',
    policy: AndroidGroupPolicy.normal,
    epoch: epoch,
    createdAtUnixMs: now,
    updatedAtUnixMs: now + epoch,
  );

  List<AndroidGroupMemberRecord> members({bool removed = false}) => [
    for (final key in ['owner', 'peer-1', 'peer-2'])
      AndroidGroupMemberRecord(
        groupId: 'group-1',
        keyId: key,
        displayName: key,
        contactJson: jsonEncode({'key_id': key}),
        role: key == 'owner'
            ? AndroidGroupMemberRole.owner
            : AndroidGroupMemberRole.member,
        status: removed && key == 'peer-2'
            ? AndroidGroupMemberStatus.removed
            : AndroidGroupMemberStatus.active,
        trustState: AndroidGroupTrustState.verified,
        updatedAtUnixMs: now,
      ),
  ];

  AndroidGroupEventRecord event(int epoch, {String? id}) =>
      AndroidGroupEventRecord(
        eventId: id ?? 'event-$epoch',
        groupId: 'group-1',
        epoch: epoch,
        type: 'group_renamed',
        actorKeyId: 'owner',
        createdAtUnixMs: now + epoch,
        payloadJson: jsonEncode({'epoch': epoch}),
        signature: 'signature-$epoch',
      );

  AndroidMessageRecord message(String id, int counter) => AndroidMessageRecord(
    envelopeId: id,
    conversationId: 'group-1',
    direction: 'incoming',
    peerKeyId: 'owner',
    peerDisplayName: 'Owner',
    createdAtUnixMs: now,
    messageCounter: counter,
    text: 'Group event',
    opaqueEnvelopeBase64: 'AQID',
    isRead: false,
  );

  List<AndroidPendingEnvelopeRecord> children(int epoch) => [
    for (var index = 0; index < 2; index++)
      AndroidPendingEnvelopeRecord(
        envelopeId: 'child-$epoch-$index',
        logicalMessageId: 'group-event:event-$epoch',
        logicalKind: AndroidPendingEnvelopeKind.groupControl,
        recipientKeyId: 'peer-${index + 1}',
        recipientDisplayName: 'Peer ${index + 1}',
        recipientContactJson: '{}',
        envelopeBase64: base64Encode([epoch, index, 3]),
        createdAtUnixMs: now,
        childIndex: index,
        childCount: 2,
      ),
  ];

  Future<bool> importEvent(
    int epoch, {
    String? envelopeId,
    String? eventId,
    int? counter,
    bool removed = false,
  }) => store.importGroupControlTransition(
    group: group(epoch),
    members: members(removed: removed),
    event: event(epoch, id: eventId),
    message: message(envelopeId ?? 'incoming-$epoch', counter ?? epoch),
    recipientIdentityKeyId: 'self',
    createRelayResult: true,
  );

  Future<bool> defer(String id, {int? time, String body = 'AQID'}) =>
      store.stageDeferredMailboxEnvelope(
        envelopeId: id,
        senderKeyId: 'owner',
        envelopeBase64: body,
        reasonCode: 'missing_prerequisite',
        reasonDetail: 'future epoch',
        nowUnixMs: time ?? now,
        recipientIdentityKeyId: 'self',
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('envelope-reliability-');
    now = DateTime.now().millisecondsSinceEpoch;
    store = AndroidDbStore.forTesting(
      databaseFactory: databaseFactoryFfi,
      databaseDirectory: directory.path,
    );
    await store.init('test-only-not-encrypted');
  });

  tearDown(() async {
    await store.close();
    // Only this test's freshly created isolated directory is removed.
    await directory.delete(recursive: true);
  });

  for (final oldVersion in [11, 13]) {
    test('v$oldVersion database migrates to v15 without losing data', () async {
      await store.upsertContact(
        const AndroidContactRecord(
          keyId: 'owner',
          displayName: 'Owner',
          contactJson: '{}',
        ),
      );
      await store.addMessage(
        message('existing', 123),
        recipientIdentityKeyId: 'self',
      );
      await store.stageGroupControlTransition(
        group: group(1),
        members: members(),
        event: event(1),
        children: children(1),
      );
      final db = await rawDatabase();
      await db.execute('DROP TABLE mailbox_quarantine');
      await db.execute('DROP TABLE deferred_mailbox_envelopes');
      if (oldVersion == 11) {
        await db.execute('DROP TABLE pending_envelopes');
        await db.execute('ALTER TABLE messages DROP COLUMN is_read');
      } else {
        await db.execute(
          'ALTER TABLE pending_envelopes DROP COLUMN logical_kind',
        );
      }
      await db.setVersion(oldVersion);
      await reopen();

      expect(await (await rawDatabase()).getVersion(), 15);
      expect((await store.getContact('owner'))!.displayName, 'Owner');
      expect((await store.getMessage('existing'))!.messageCounter, 123);
      expect((await store.getGroup('group-1'))!.epoch, 1);
      expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(1));
      final pending = await store.getPendingEnvelopes();
      expect(pending, hasLength(oldVersion == 11 ? 0 : 2));
      expect(
        pending.every(
          (child) => child.logicalKind == AndroidPendingEnvelopeKind.message,
        ),
        isTrue,
      );
      expect(await store.getDeferredMailboxEnvelopes(), isEmpty);
      // The existing replay ledger also survives migration.
      await expectLater(
        store.addMessage(
          message('replay', 123),
          recipientIdentityKeyId: 'self',
        ),
        throwsA(isA<AndroidMessageCounterReplayException>()),
      );
    });
  }

  test(
    'outbound group transaction rolls back all children and state',
    () async {
      await store.createGroupWithMembers(
        group: group(1),
        members: members(),
        event: event(1),
      );
      final db = await rawDatabase();
      await db.execute('''
      CREATE TRIGGER fail_child BEFORE INSERT ON pending_envelopes
      WHEN NEW.child_index = 1
      BEGIN SELECT RAISE(ABORT, 'injected child write failure'); END
    ''');
      await expectLater(
        store.stageGroupControlTransition(
          group: group(2),
          members: members(removed: true),
          event: event(2),
          children: children(2),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await store.getGroup('group-1'))!.epoch, 1);
      expect(
        (await store.getGroupMember(
          groupId: 'group-1',
          keyId: 'peer-2',
        ))!.isActive,
        isTrue,
      );
      expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(1));
      expect(await store.getPendingEnvelopes(), isEmpty);
      await db.execute('DROP TRIGGER fail_child');

      await store.stageGroupControlTransition(
        group: group(2),
        members: members(removed: true),
        event: event(2),
        children: children(2),
      );
      await reopen();
      expect((await store.getGroup('group-1'))!.epoch, 2);
      expect(
        (await store.getGroupMember(
          groupId: 'group-1',
          keyId: 'peer-2',
        ))!.status,
        AndroidGroupMemberStatus.removed,
      );
      expect(await store.getPendingGroupControlCount(), 1);
      expect((await store.getPendingEnvelopes()).map((row) => row.envelopeId), [
        'child-2-0',
        'child-2-1',
      ]);
    },
  );

  test(
    'partial fanout restarts with only failed children and stable ciphertext',
    () async {
      final batch = children(1);
      await store.stageGroupControlTransition(
        group: group(1),
        members: members(),
        event: event(1),
        children: batch,
      );
      await store.updatePendingEnvelopeDelivery(
        envelopeId: batch[0].envelopeId,
        deliveryStatus: AndroidDeliveryStatus.serverMailbox,
        detail: 'stored by server',
        route: 'mailbox',
      );
      await store.updatePendingEnvelopeDelivery(
        envelopeId: batch[1].envelopeId,
        deliveryStatus: AndroidDeliveryStatus.pending,
        detail: 'offline',
        route: 'pending',
      );
      await reopen();
      final remaining = await store.getPendingEnvelopes();
      expect(remaining, hasLength(1));
      expect(remaining.single.envelopeId, batch[1].envelopeId);
      expect(remaining.single.envelopeBase64, batch[1].envelopeBase64);
      expect(remaining.single.attemptCount, 1);
      expect(remaining.single.nextAttemptAtUnixMs, isNotNull);
      expect(
        (await store.getOutboundEnvelopeBatch(
          batch[0].logicalMessageId,
        )).first.envelopeBase64,
        isEmpty,
      );
      await store.updatePendingEnvelopeDelivery(
        envelopeId: batch[1].envelopeId,
        deliveryStatus: AndroidDeliveryStatus.sent,
        detail: 'received',
        route: 'p2p',
      );
      expect(await store.getPendingGroupControlCount(), 0);
      expect(await store.getPendingEnvelopes(), isEmpty);
    },
  );

  test('zero-recipient control still commits its local group event', () async {
    await store.stageGroupControlTransition(
      group: group(1),
      members: members(),
      event: event(1),
      children: const [],
    );
    await reopen();
    expect((await store.getGroup('group-1'))!.epoch, 1);
    expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(1));
    expect(await store.getPendingGroupControlCount(), 0);
  });

  test(
    'inbound failure rolls back epoch, membership, message and replay counter',
    () async {
      await importEvent(1);
      final db = await rawDatabase();
      await db.execute('''
      CREATE TRIGGER fail_event BEFORE INSERT ON group_events
      WHEN NEW.epoch = 2
      BEGIN SELECT RAISE(ABORT, 'injected event write failure'); END
    ''');
      await expectLater(
        importEvent(2, removed: true),
        throwsA(isA<DatabaseException>()),
      );
      expect((await store.getGroup('group-1'))!.epoch, 1);
      expect(
        (await store.getGroupMember(
          groupId: 'group-1',
          keyId: 'peer-2',
        ))!.isActive,
        isTrue,
      );
      expect(await store.getMessage('incoming-2'), isNull);
      expect(
        (await store.relayHa.pendingResults()).map((row) => row['envelope_id']),
        isNot(contains('incoming-2')),
      );
      expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(1));
      await db.execute('DROP TRIGGER fail_event');
      await reopen();
      // Retry with exactly the same envelope and counter succeeds after rollback.
      expect(await importEvent(2, removed: true), isTrue);
      expect(await importEvent(2, removed: true), isFalse);
      expect((await store.getGroup('group-1'))!.epoch, 2);
      expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(2));
      await expectLater(
        importEvent(3, counter: 2),
        throwsA(isA<AndroidMessageCounterReplayException>()),
      );
      expect((await store.getGroup('group-1'))!.epoch, 2);
      expect(await store.getMessage('incoming-3'), isNull);
    },
  );

  test(
    'duplicate event does not roll back newer state; conflicting id is atomic',
    () async {
      await importEvent(1);
      await importEvent(2);
      expect(
        await importEvent(1, envelopeId: 'other-route', counter: 3),
        isTrue,
      );
      expect((await store.getGroup('group-1'))!.epoch, 2);
      expect(await store.getGroupEvents(groupId: 'group-1'), hasLength(2));
      await expectLater(
        importEvent(3, eventId: 'event-1', envelopeId: 'conflict', counter: 4),
        throwsA(isA<AndroidInvalidEnvelopePayloadException>()),
      );
      expect(await store.getMessage('conflict'), isNull);
      expect((await store.getGroup('group-1'))!.epoch, 2);
      expect(await importEvent(3, counter: 4), isTrue);
    },
  );

  test(
    'deferred raw body survives restart, then imports after prerequisite',
    () async {
      await importEvent(1);
      expect(
        androidGroupEpochNeedsCausalDeferral(
          eventType: 'group_renamed',
          incomingEpoch: 3,
          currentEpoch: 1,
        ),
        isTrue,
      );
      expect(await defer('future-3'), isTrue);
      await defer('future-3', time: now + 100);
      await reopen();
      final pending = (await store.getDeferredMailboxEnvelopes()).single;
      expect(pending.envelopeId, 'future-3');
      expect(pending.envelopeBase64, 'AQID');
      expect(pending.firstDeferredAtUnixMs, now);
      expect(pending.attemptCount, 2);
      final deferredResult = (await store.relayHa.pendingResults()).singleWhere(
        (row) => row['envelope_id'] == 'future-3',
      );
      expect(deferredResult['outcome'], 'deferred');
      expect(deferredResult['signed_result_json'], isNull);
      expect(await store.getMessage('future-3'), isNull);
      await importEvent(2);
      expect(
        androidGroupEpochNeedsCausalDeferral(
          eventType: 'group_renamed',
          incomingEpoch: 3,
          currentEpoch: (await store.getGroup('group-1'))!.epoch,
        ),
        isFalse,
      );
      await importEvent(3, envelopeId: pending.envelopeId);
      // A crash after import but before deletion is safe: dedup, then cleanup.
      await reopen();
      expect(await importEvent(3, envelopeId: pending.envelopeId), isFalse);
      final completedResult = (await store.relayHa.pendingResults())
          .singleWhere((row) => row['envelope_id'] == 'future-3');
      expect(completedResult['outcome'], 'delivered');
      expect(completedResult['result_sequence'], '2');
      await store.deleteDeferredMailboxEnvelope(pending.envelopeId);
      expect(await store.getDeferredMailboxEnvelopes(), isEmpty);
    },
  );

  test(
    'quarantine retains only metadata and ACK state across restart',
    () async {
      const rejected = 'private-opaque-body-do-not-store';
      await store.addMailboxQuarantine(
        envelopeId: 'poison',
        senderKeyId: 'owner',
        reasonCode: 'authentication_failed',
        reasonDetail: 'invalid ciphertext',
        envelopeBase64: rejected,
        quarantinedAtUnixMs: now,
      );
      expect(
        (await store.getMailboxQuarantine('poison'))!.acknowledgedAtUnixMs,
        isNull,
      );
      await store.markMailboxQuarantineAcknowledged(
        envelopeIds: ['poison'],
        acknowledgedAtUnixMs: now + 1,
      );
      await reopen();
      final saved = (await store.getMailboxQuarantine('poison'))!;
      expect(saved.acknowledgedAtUnixMs, now + 1);
      expect(saved.envelopeSha256, androidMailboxEnvelopeSha256(rejected));
      final rows = await (await rawDatabase()).query('mailbox_quarantine');
      expect(jsonEncode(rows), isNot(contains(rejected)));
      expect(rows.single.containsKey('envelope_b64'), isFalse);
    },
  );

  test(
    'failed deferred-to-quarantine write preserves the original raw body',
    () async {
      await defer('future');
      final pending = (await store.getDeferredMailboxEnvelope('future'))!;
      final db = await rawDatabase();
      await db.execute('''
      CREATE TRIGGER fail_quarantine BEFORE INSERT ON mailbox_quarantine
      BEGIN SELECT RAISE(ABORT, 'injected quarantine write failure'); END
    ''');
      await expectLater(
        store.moveDeferredMailboxEnvelopeToQuarantine(
          record: pending,
          reasonCode: 'invalid_payload',
          reasonDetail: 'invalid',
          quarantinedAtUnixMs: now,
          recipientIdentityKeyId: 'self',
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await store.getDeferredMailboxEnvelope('future'))!.envelopeBase64,
        pending.envelopeBase64,
      );
      expect(await store.getMailboxQuarantine('future'), isNull);
      expect(
        (await store.relayHa.pendingResults()).single['outcome'],
        'deferred',
      );
      await db.execute('DROP TRIGGER fail_quarantine');
      await store.moveDeferredMailboxEnvelopeToQuarantine(
        record: pending,
        reasonCode: 'invalid_payload',
        reasonDetail: 'invalid',
        quarantinedAtUnixMs: now,
        recipientIdentityKeyId: 'self',
      );
      expect(await store.getDeferredMailboxEnvelope('future'), isNull);
      expect(await store.getMailboxQuarantine('future'), isNotNull);
      expect(
        (await store.relayHa.pendingResults()).single['outcome'],
        'rejected',
      );
      expect(
        (await store.relayHa.pendingResults()).single['result_sequence'],
        '2',
      );
    },
  );

  test(
    'startup prunes expired and excess deferred rows without rewriting survivors',
    () async {
      final db = await rawDatabase();
      await db.transaction((txn) async {
        for (var index = 0; index < 258; index++) {
          await txn.insert(
            'deferred_mailbox_envelopes',
            AndroidDeferredMailboxEnvelopeRecord(
              envelopeId: 'queued-${index.toString().padLeft(3, '0')}',
              senderKeyId: 'owner',
              envelopeBase64: 'AQID',
              reasonCode: 'missing_prerequisite',
              reasonDetail: 'future',
              envelopeSizeBytes: 4,
              firstDeferredAtUnixMs: index == 0
                  ? now - const Duration(days: 8).inMilliseconds
                  : now + index,
              lastAttemptAtUnixMs: now,
            ).toJson(),
          );
        }
      });
      // Retained raw data must not be deleted/reinserted during normalization.
      await db.execute('''
      CREATE TRIGGER preserve_survivor BEFORE DELETE ON deferred_mailbox_envelopes
      WHEN OLD.envelope_id = 'queued-257'
      BEGIN SELECT RAISE(ABORT, 'survivor was rewritten'); END
    ''');
      await reopen();
      expect(await store.getDeferredMailboxEnvelopes(), hasLength(256));
      expect(
        (await store.getMailboxQuarantine('queued-000'))!.reasonCode,
        'deferred_expired',
      );
      expect(
        (await store.getMailboxQuarantine('queued-001'))!.reasonCode,
        'deferred_capacity_evicted',
      );
      expect(
        (await store.getDeferredMailboxEnvelope('queued-257'))!.envelopeBase64,
        'AQID',
      );
    },
  );

  test(
    'evicting a deferred ciphertext atomically advances its recipient result',
    () async {
      await defer('expired-local');
      final db = await rawDatabase();
      await db.update(
        'deferred_mailbox_envelopes',
        {
          'first_deferred_at_unix_ms':
              now - const Duration(days: 8).inMilliseconds,
        },
        where: 'envelope_id = ?',
        whereArgs: ['expired-local'],
      );
      await reopen();
      expect(await store.getDeferredMailboxEnvelope('expired-local'), isNull);
      final result = (await store.relayHa.pendingResults()).single;
      expect(result['outcome'], 'rejected');
      expect(result['result_sequence'], '2');
      expect(result['signed_result_json'], isNull);
    },
  );
}
