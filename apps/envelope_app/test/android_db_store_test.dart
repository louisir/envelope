import 'package:envelope_app/android_chat_store.dart';
import 'package:envelope_app/android_db_store.dart';
import 'package:envelope_app/android_mailbox_reliability.dart';
import 'package:envelope_app/android_secure_store.dart';
import 'package:envelope_app/envelope_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AndroidSealedEnvelopeRecord maps database fields', () {
    const record = AndroidSealedEnvelopeRecord(
      envelopeId: 'env-1',
      kind: 'file',
      recipientKeyId: 'recipient-key',
      recipientDisplayName: 'Alice',
      createdAtUnixMs: 1782792000123,
      messageCounter: 42,
      sourceName: 'photo.jpg',
      payloadSize: 1234,
      envelopeSize: 2345,
      path: 'Download/Envelope/sealed/env-1.envelope',
      uri: 'content://media/external/downloads/42',
      displayPath: 'Download/Envelope/sealed/env-1.envelope',
      mime: 'application/octet-stream',
      sizeBytes: 2345,
      deletedAtUnixMs: 1782792000999,
    );

    final json = record.toJson();
    expect(json['envelope_id'], 'env-1');
    expect(json['kind'], 'file');
    expect(json['path'], 'Download/Envelope/sealed/env-1.envelope');
    expect(json['uri'], 'content://media/external/downloads/42');
    expect(json['display_path'], 'Download/Envelope/sealed/env-1.envelope');
    expect(json['mime'], 'application/octet-stream');
    expect(json['size_bytes'], 2345);
    expect(json['deleted_at_unix_ms'], 1782792000999);

    final parsed = AndroidSealedEnvelopeRecord.fromJson(json);
    expect(parsed.envelopeId, record.envelopeId);
    expect(parsed.isFile, isTrue);
    expect(parsed.recipientDisplayName, 'Alice');
    expect(parsed.createdAtUnixMs, 1782792000123);
    expect(parsed.sourceName, 'photo.jpg');
    expect(parsed.payloadSize, 1234);
    expect(parsed.envelopeSize, 2345);
    expect(parsed.path, record.path);
    expect(parsed.uri, record.uri);
    expect(parsed.displayPath, record.displayPath);
    expect(parsed.mime, record.mime);
    expect(parsed.sizeBytes, record.sizeBytes);
    expect(parsed.isDeleted, isTrue);
    expect(parsed.deletedAtUnixMs, record.deletedAtUnixMs);
    expect(parsed.locationPath, record.displayPath);
  });

  test('Android sealed group kinds classify file payloads', () {
    final base = <String, Object?>{
      'envelope_id': 'env-group',
      'recipient_key_id': 'group-1',
      'recipient_display_name': 'Group',
      'created_at_unix_ms': 1782792000123,
      'message_counter': 42,
      'payload_size': 4,
      'envelope_size': 8,
      'path': 'Download/Envelope/sealed/group.envelope',
    };

    expect(
      AndroidSealedEnvelopeRecord.fromJson({
        ...base,
        'kind': 'group_file',
      }).isFile,
      isTrue,
    );
    expect(
      AndroidSealedEnvelopeRecord.fromJson({
        ...base,
        'kind': 'group_text',
      }).isFile,
      isFalse,
    );
  });

  test('AndroidPendingEnvelopeRecord preserves durable fanout metadata', () {
    const record = AndroidPendingEnvelopeRecord(
      envelopeId: 'child-2',
      logicalMessageId: 'logical-1',
      recipientKeyId: 'recipient-key',
      recipientDisplayName: 'Alice',
      recipientContactJson: '{"key_id":"recipient-key"}',
      envelopeBase64: 'AQID',
      createdAtUnixMs: 1782792000123,
      childIndex: 1,
      childCount: 3,
      attemptCount: 2,
      nextAttemptAtUnixMs: 1782792030123,
      lastError: 'offline',
      lastRoute: 'pending',
    );

    final parsed = AndroidPendingEnvelopeRecord.fromJson(record.toJson());
    expect(parsed.envelopeId, record.envelopeId);
    expect(parsed.logicalMessageId, record.logicalMessageId);
    expect(parsed.childIndex, 1);
    expect(parsed.childCount, 3);
    expect(parsed.attemptCount, 2);
    expect(parsed.deliveryStatus, AndroidDeliveryStatus.pending);
    expect(parsed.envelopeBase64, 'AQID');
    expect(parsed.toContactRecord().displayName, 'Alice');
    expect(parsed.logicalKind, AndroidPendingEnvelopeKind.message);
  });

  test('AndroidPendingEnvelopeRecord preserves group control batches', () {
    const record = AndroidPendingEnvelopeRecord(
      envelopeId: 'control-child',
      logicalMessageId: 'group-event:gvt-1',
      logicalKind: AndroidPendingEnvelopeKind.groupControl,
      recipientKeyId: 'recipient-key',
      recipientDisplayName: 'Alice',
      recipientContactJson: '{"key_id":"recipient-key"}',
      envelopeBase64: 'AQID',
      createdAtUnixMs: 1782792000123,
      childIndex: 0,
      childCount: 1,
    );

    final parsed = AndroidPendingEnvelopeRecord.fromJson(record.toJson());
    expect(parsed.logicalMessageId, 'group-event:gvt-1');
    expect(parsed.logicalKind, AndroidPendingEnvelopeKind.groupControl);
  });

  test(
    'AndroidMessageRecord persists unread and defaults legacy rows to read',
    () {
      const record = AndroidMessageRecord(
        envelopeId: 'incoming-1',
        conversationId: 'peer-1',
        direction: 'incoming',
        peerKeyId: 'peer-1',
        peerDisplayName: 'Alice',
        createdAtUnixMs: 1782792000123,
        messageCounter: 42,
        text: 'hello',
        opaqueEnvelopeBase64: 'AQID',
        isRead: false,
      );

      final row = record.toJson();
      expect(row['is_read'], 0);
      expect(AndroidMessageRecord.fromJson(row).isRead, isFalse);
      final legacyRow = Map<Object?, Object?>.from(row)..remove('is_read');
      expect(AndroidMessageRecord.fromJson(legacyRow).isRead, isTrue);
    },
  );

  test('Android group records map database fields', () {
    const group = AndroidGroupRecord(
      groupId: 'grp-1',
      name: 'Design',
      ownerKeyId: 'owner-key',
      policy: AndroidGroupPolicy.verified,
      epoch: 3,
      createdAtUnixMs: 1782792000123,
      updatedAtUnixMs: 1782792000456,
      avatarSeed: 'Design',
    );
    const member = AndroidGroupMemberRecord(
      groupId: 'grp-1',
      keyId: 'member-key',
      displayName: 'Alice',
      contactJson: '{"display_name":"Alice"}',
      role: AndroidGroupMemberRole.member,
      status: AndroidGroupMemberStatus.accepted,
      trustState: AndroidGroupTrustState.consensusAdmitted,
      invitedByKeyId: 'owner-key',
      updatedAtUnixMs: 1782792000456,
    );

    final parsedGroup = AndroidGroupRecord.fromJson(group.toJson());
    final parsedMember = AndroidGroupMemberRecord.fromJson(member.toJson());

    expect(parsedGroup.groupId, 'grp-1');
    expect(parsedGroup.policy, AndroidGroupPolicy.verified);
    expect(parsedGroup.isActive, isTrue);
    expect(parsedMember.keyId, 'member-key');
    expect(parsedMember.isAccepted, isTrue);
    expect(parsedMember.isLocallyTrusted, isTrue);
  });

  test('Android mailbox failure classification matches Windows policy', () {
    expect(
      classifyAndroidMailboxImportFailure(
        const AndroidEnvelopeCiphertextRejectedException('bad ciphertext'),
      ).reasonCode,
      'authentication_failed',
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const AndroidMessageCounterReplayException('检测到重放计数器'),
      ).permanent,
      isTrue,
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const AndroidInvalidEnvelopePayloadException('bad payload'),
      ).permanent,
      isTrue,
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const AndroidMailboxMissingPrerequisiteException('future epoch'),
      ).reasonCode,
      'missing_prerequisite',
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const EnvelopeNativeException('contact missing'),
      ).permanent,
      isFalse,
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const SecureStoreException('disk unavailable'),
      ).reasonCode,
      'transient_local_failure',
    );
    expect(
      classifyAndroidMailboxImportFailure(
        const FormatException('bad json'),
      ).reasonCode,
      'invalid_json',
    );
  });

  test('mailbox diagnostics do not persist malformed JSON source', () {
    const error = FormatException('Invalid JSON', 'PRIVATE_PAYLOAD', 3);
    final failure = classifyAndroidMailboxImportFailure(error);
    expect(failure.permanent, isTrue);
    expect(failure.detail, 'Invalid JSON');
    expect(failure.detail, isNot(contains('PRIVATE_PAYLOAD')));
    expect(
      classifyAndroidMailboxImportFailure(StateError('local I/O')).permanent,
      isFalse,
    );
  });

  test('group parser accepts future epochs and rejects malformed schema', () {
    final payload = <String, Object?>{
      'version': 1,
      'event_id': 'invite-7',
      'created_at_unix_ms': 123,
      'group': {'group_id': 'g', 'owner_key_id': 'owner', 'epoch': 7},
      'members': [
        {
          'group_id': 'g',
          'key_id': 'owner',
          'role': 'owner',
          'status': 'active',
        },
      ],
    };
    expect(decodeAndroidGroupControlState(payload).group.epoch, 7);
    for (final invalid in <Map<String, Object?>>[
      {...payload, 'version': '1'},
      {...payload, 'event_id': ''},
      {...payload, 'created_at_unix_ms': 1.5},
      {
        ...payload,
        'group': {'group_id': 'g', 'owner_key_id': 'owner', 'epoch': '7'},
      },
      {
        ...payload,
        'members': [null],
      },
      {
        ...payload,
        'members': [
          {'group_id': 'different-group', 'key_id': 'owner'},
        ],
      },
      {
        ...payload,
        'members': [
          {'group_id': 'g', 'key_id': 'owner'},
          {'group_id': 'g', 'key_id': 'owner'},
        ],
      },
      {
        ...payload,
        'members': [
          {'group_id': 'g', 'key_id': 'owner', 'updated_at_unix_ms': 'bad'},
        ],
      },
    ]) {
      expect(
        () => decodeAndroidGroupControlState(invalid),
        throwsA(isA<AndroidInvalidEnvelopePayloadException>()),
      );
    }
  });

  test('Android mailbox queues enforce seven-day and capacity bounds', () {
    const dayMs = Duration.millisecondsPerDay;
    const now = 1782792000123;
    final quarantine = <AndroidMailboxQuarantineRecord>[
      const AndroidMailboxQuarantineRecord(
        envelopeId: 'expired',
        senderKeyId: 'sender',
        reasonCode: 'invalid_payload',
        reasonDetail: 'old',
        envelopeSha256: '00',
        envelopeSizeBytes: 1,
        quarantinedAtUnixMs: now - 8 * dayMs,
      ),
      for (var index = 0; index < 1005; index += 1)
        AndroidMailboxQuarantineRecord(
          envelopeId: 'poison-$index',
          senderKeyId: 'sender',
          reasonCode: 'invalid_payload',
          reasonDetail: 'metadata only',
          envelopeSha256: '00',
          envelopeSizeBytes: 1,
          quarantinedAtUnixMs: now + index,
        ),
    ];
    final deferred = <AndroidDeferredMailboxEnvelopeRecord>[
      const AndroidDeferredMailboxEnvelopeRecord(
        envelopeId: 'deferred-expired',
        senderKeyId: 'sender',
        envelopeBase64: 'AQID',
        reasonCode: 'missing_prerequisite',
        reasonDetail: 'old',
        envelopeSizeBytes: 4,
        firstDeferredAtUnixMs: now - 8 * dayMs,
        lastAttemptAtUnixMs: now - 8 * dayMs,
      ),
      for (
        var index = 0;
        index < androidMaximumDeferredMailboxEnvelopeCount + 4;
        index += 1
      )
        AndroidDeferredMailboxEnvelopeRecord(
          envelopeId: 'deferred-$index',
          senderKeyId: 'sender',
          envelopeBase64: 'AQID',
          reasonCode: 'missing_prerequisite',
          reasonDetail: 'waiting',
          envelopeSizeBytes: 4,
          firstDeferredAtUnixMs: now + index,
          lastAttemptAtUnixMs: now + index,
        ),
    ];

    final normalized = normalizeAndroidMailboxReliability(
      quarantine: quarantine,
      deferred: deferred,
      nowUnixMs: now,
    );

    expect(
      normalized.quarantine.length,
      androidMaximumMailboxQuarantineRecords,
    );
    expect(
      normalized.quarantine.any((record) => record.envelopeId == 'expired'),
      isFalse,
    );
    expect(
      normalized.deferred.length,
      androidMaximumDeferredMailboxEnvelopeCount,
    );
    expect(
      normalized.deferred.any(
        (record) => record.envelopeId == 'deferred-expired',
      ),
      isFalse,
    );
    final deferredOnly = normalizeAndroidMailboxReliability(
      quarantine: const [],
      deferred: deferred,
      nowUnixMs: now,
    );
    expect(
      deferredOnly.quarantine.any(
        (record) =>
            record.reasonCode == 'deferred_capacity_evicted' &&
            record.acknowledgedAtUnixMs == now,
      ),
      isTrue,
    );
    expect(
      deferredOnly.quarantine.first.toJson().containsKey('envelope_b64'),
      isFalse,
    );
  });

  test('Android causal epoch detection defers only missing successors', () {
    expect(
      androidGroupEpochNeedsCausalDeferral(
        eventType: 'group_avatar_updated',
        incomingEpoch: 4,
        currentEpoch: 2,
      ),
      isTrue,
    );
    expect(
      androidGroupEpochNeedsCausalDeferral(
        eventType: 'group_avatar_updated',
        incomingEpoch: 3,
        currentEpoch: 2,
      ),
      isFalse,
    );
    expect(
      androidGroupEpochNeedsCausalDeferral(
        eventType: 'group_message',
        incomingEpoch: 3,
        currentEpoch: 2,
      ),
      isTrue,
    );
    expect(
      androidGroupEpochNeedsCausalDeferral(
        eventType: 'group_invite',
        incomingEpoch: 1,
        currentEpoch: null,
      ),
      isFalse,
    );
  });
}
