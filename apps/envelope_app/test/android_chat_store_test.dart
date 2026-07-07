import 'package:flutter_test/flutter_test.dart';
import 'package:envelope_app/android_chat_store.dart';

void main() {
  test('AndroidChatStore parses legacy JSON and normalizes records', () {
    final store = AndroidChatStore.fromJsonString('''
{
  "version": 1,
  "contacts": [
    {
      "key_id": "bob-key",
      "display_name": "Bob",
      "remark": "客户-张三",
      "contact_json": "{\\"display_name\\":\\"Bob\\"}"
    },
    {
      "key_id": "alice-key",
      "display_name": "Alice",
      "contact_json": "{\\"display_name\\":\\"Alice\\"}"
    }
  ],
  "messages": [
    {
      "envelope_id": "newer",
      "conversation_id": "conversation",
      "direction": "incoming",
      "peer_key_id": "bob-key",
      "peer_display_name": "Bob",
      "created_at_unix_ms": 2000,
      "message_counter": 2,
      "text": "newer message",
      "opaque_envelope_b64": "AAAA",
      "delivery_status": "received"
    },
    {
      "envelope_id": "older",
      "conversation_id": "conversation",
      "direction": "outgoing",
      "peer_key_id": "alice-key",
      "peer_display_name": "Alice",
      "created_at_unix_ms": 1000,
      "message_counter": 1,
      "text": "older message",
      "opaque_envelope_b64": "BBBB",
      "delivery_status": "sent"
    }
  ],
  "next_message_counter": 0
}
''');

    expect(store.contacts.map((contact) => contact.displayLabel), [
      'Alice',
      '客户-张三',
    ]);
    expect(store.contacts.map((contact) => contact.displayName), [
      'Alice',
      'Bob',
    ]);
    expect(store.contacts.last.remark, '客户-张三');
    expect(store.messages.map((message) => message.envelopeId), [
      'older',
      'newer',
    ]);
    expect(store.nextMessageCounter, 1);
  });

  test('pendingMessages returns only outgoing pending messages', () {
    final store = AndroidChatStore(
      contacts: const [],
      nextMessageCounter: 3,
      messages: [
        _message(
          envelopeId: 'created',
          direction: 'outgoing',
          deliveryStatus: AndroidDeliveryStatus.created,
        ),
        _message(
          envelopeId: 'pending',
          direction: 'outgoing',
          deliveryStatus: AndroidDeliveryStatus.pending,
        ),
        _message(
          envelopeId: 'incoming',
          direction: 'incoming',
          deliveryStatus: AndroidDeliveryStatus.received,
        ),
      ],
    );

    expect(store.pendingMessages().map((message) => message.envelopeId), [
      'pending',
    ]);
  });

  test('AndroidMessageRecord marks deleted attachments', () {
    const deletedAt = 1782792000123;
    final message =
        _message(
          envelopeId: 'file-message',
          direction: 'incoming',
          deliveryStatus: AndroidDeliveryStatus.received,
        ).copyWith(
          text: '文件：photo.jpg\nDownload/Envelope/received/photo.jpg',
          attachmentPath: 'Download/Envelope/received/photo.jpg',
          attachmentMime: 'image/jpeg',
          attachmentDeletedAtUnixMs: deletedAt,
        );

    final json = message.toJson();
    expect(json['attachment_deleted_at_unix_ms'], deletedAt);

    final parsed = AndroidMessageRecord.fromJson(json);
    expect(parsed.attachmentDeleted, isTrue);
    expect(parsed.attachmentDeletedAtUnixMs, deletedAt);
    expect(parsed.attachmentPath, 'Download/Envelope/received/photo.jpg');
  });

  test('AndroidMessageRecord tracks only valid incoming counters', () {
    final incoming = _message(
      envelopeId: 'env-in',
      direction: 'incoming',
      deliveryStatus: AndroidDeliveryStatus.received,
    );

    expect(incoming.hasTrackableIncomingCounter, isTrue);
    expect(
      incoming.copyWith(direction: 'outgoing').hasTrackableIncomingCounter,
      isFalse,
    );
    expect(
      incoming.copyWith(messageCounter: 0).hasTrackableIncomingCounter,
      isFalse,
    );
    expect(
      incoming.copyWith(peerKeyId: ' ').hasTrackableIncomingCounter,
      isFalse,
    );
  });

  test('AndroidChatStore parses group records and members', () {
    final store = AndroidChatStore.fromJson({
      'contacts': const [],
      'messages': const [],
      'next_message_counter': 9,
      'groups': [
        {
          'group_id': 'group-1',
          'name': '项目组',
          'owner_key_id': 'owner-key',
          'policy': AndroidGroupPolicy.consensus,
          'epoch': 2,
          'created_at_unix_ms': 1000,
          'updated_at_unix_ms': 2000,
          'avatar_seed': 'seed',
          'is_active': 1,
        },
      ],
      'group_members': [
        {
          'group_id': 'group-1',
          'key_id': 'owner-key',
          'display_name': 'Owner',
          'contact_json': '{"display_name":"Owner"}',
          'role': AndroidGroupMemberRole.owner,
          'status': AndroidGroupMemberStatus.active,
          'trust_state': AndroidGroupTrustState.verified,
          'joined_at_unix_ms': 1000,
          'updated_at_unix_ms': 1000,
        },
        {
          'group_id': 'group-1',
          'key_id': 'member-key',
          'display_name': 'Member',
          'contact_json': '{"display_name":"Member"}',
          'role': AndroidGroupMemberRole.member,
          'status': AndroidGroupMemberStatus.accepted,
          'trust_state': AndroidGroupTrustState.consensusAdmitted,
          'invited_by_key_id': 'owner-key',
          'updated_at_unix_ms': 1500,
        },
      ],
    });

    expect(store.groups.single.groupId, 'group-1');
    expect(store.groups.single.policy, AndroidGroupPolicy.consensus);
    expect(store.activeMembersForGroup('group-1').map((m) => m.keyId), [
      'owner-key',
    ]);
    expect(
      store.findGroupMember('group-1', 'member-key')?.trustState,
      AndroidGroupTrustState.consensusAdmitted,
    );
    expect(store.findGroupMember('group-1', 'member-key')?.isAccepted, isTrue);
    expect(
      store.findGroupMember('group-1', 'member-key')?.isLocallyTrusted,
      isTrue,
    );
  });

  test('androidConsensusThreshold uses ceil of sixty percent', () {
    expect(androidConsensusThreshold(0), 0);
    expect(androidConsensusThreshold(1), 1);
    expect(androidConsensusThreshold(2), 2);
    expect(androidConsensusThreshold(3), 2);
    expect(androidConsensusThreshold(4), 3);
    expect(androidConsensusThreshold(5), 3);
    expect(androidConsensusThreshold(10), 6);
  });

  test(
    'androidGroupShouldAutoDissolve requires at least three remaining members',
    () {
      expect(androidGroupShouldAutoDissolve(0), isTrue);
      expect(androidGroupShouldAutoDissolve(1), isTrue);
      expect(androidGroupShouldAutoDissolve(2), isTrue);
      expect(androidGroupShouldAutoDissolve(3), isFalse);
      expect(androidGroupShouldAutoDissolve(4), isFalse);
    },
  );

  test('androidGroupRemainingMemberCount includes pending invites', () {
    final members = [
      _groupMember('owner', AndroidGroupMemberStatus.active),
      _groupMember('pending-a', AndroidGroupMemberStatus.pending),
      _groupMember('pending-b', AndroidGroupMemberStatus.pending),
      _groupMember('left-c', AndroidGroupMemberStatus.left),
    ];
    expect(androidGroupRemainingMemberCount(members), 3);
    expect(androidGroupShouldAutoDissolveForMembers(members), isFalse);
  });

  test('androidGroupShouldAutoDissolveForMembers counts pending minimum', () {
    expect(
      androidGroupShouldAutoDissolveForMembers([
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('pending-a', AndroidGroupMemberStatus.pending),
      ]),
      isTrue,
    );
  });

  test(
    'androidGroupIsVisibleForLocalMember keeps active invitee during formation',
    () {
      final members = [
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('accepted-a', AndroidGroupMemberStatus.active),
        _groupMember('pending-b', AndroidGroupMemberStatus.pending),
      ];

      expect(
        androidGroupIsVisibleForLocalMember(members, 'accepted-a'),
        isTrue,
      );
    },
  );

  test('androidGroupIsVisibleForLocalMember hides pending invitee', () {
    final members = [
      _groupMember('owner', AndroidGroupMemberStatus.active),
      _groupMember('pending-a', AndroidGroupMemberStatus.pending),
      _groupMember('pending-b', AndroidGroupMemberStatus.pending),
    ];

    expect(androidGroupIsVisibleForLocalMember(members, 'pending-a'), isFalse);
  });

  test(
    'androidGroupIsVisibleForLocalMember stays visible with three remaining',
    () {
      final members = [
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('accepted-a', AndroidGroupMemberStatus.active),
        _groupMember('removed-b', AndroidGroupMemberStatus.removed),
        _groupMember('pending-c', AndroidGroupMemberStatus.pending),
      ];

      expect(
        androidGroupIsVisibleForLocalMember(members, 'accepted-a'),
        isTrue,
      );
    },
  );

  test(
    'androidGroupIsVisibleForLocalMember hides invite after owner leaves',
    () {
      final members = [
        _groupMember('owner', AndroidGroupMemberStatus.left),
        _groupMember('accepted-a', AndroidGroupMemberStatus.active),
        _groupMember('pending-b', AndroidGroupMemberStatus.pending),
      ];

      expect(androidGroupShouldAutoDissolveForMembers(members), isTrue);
      expect(
        androidGroupIsVisibleForLocalMember(members, 'pending-b'),
        isFalse,
      );
    },
  );

  test(
    'androidGroupMemberShouldReceiveMembershipControl includes pending members',
    () {
      expect(
        androidGroupMemberShouldReceiveMembershipControl(
          _groupMember('active', AndroidGroupMemberStatus.active),
          'self',
        ),
        isTrue,
      );
      expect(
        androidGroupMemberShouldReceiveMembershipControl(
          _groupMember('pending', AndroidGroupMemberStatus.pending),
          'self',
        ),
        isTrue,
      );
      expect(
        androidGroupMemberShouldReceiveMembershipControl(
          _groupMember('accepted', AndroidGroupMemberStatus.accepted),
          'self',
        ),
        isTrue,
      );
      expect(
        androidGroupMemberShouldReceiveMembershipControl(
          _groupMember('left', AndroidGroupMemberStatus.left),
          'self',
        ),
        isFalse,
      );
      expect(
        androidGroupMemberShouldReceiveMembershipControl(
          _groupMember('self', AndroidGroupMemberStatus.active),
          'self',
        ),
        isFalse,
      );
    },
  );

  test('androidGroupShouldAutoDissolveForMembers dissolves below minimum', () {
    expect(
      androidGroupShouldAutoDissolveForMembers([
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('member-a', AndroidGroupMemberStatus.active),
        _groupMember('member-b', AndroidGroupMemberStatus.left),
      ]),
      isTrue,
    );
    expect(
      androidGroupShouldAutoDissolveForMembers([
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('member-a', AndroidGroupMemberStatus.active),
        _groupMember('member-b', AndroidGroupMemberStatus.removed),
        _groupMember('pending-c', AndroidGroupMemberStatus.pending),
      ]),
      isFalse,
    );
  });

  test(
    'androidGroupShouldAutoDissolveForMembers dissolves without active owner',
    () {
      expect(
        androidGroupShouldAutoDissolveForMembers([
          _groupMember('owner', AndroidGroupMemberStatus.left),
          _groupMember('member-a', AndroidGroupMemberStatus.active),
          _groupMember('member-b', AndroidGroupMemberStatus.active),
          _groupMember('pending-c', AndroidGroupMemberStatus.pending),
        ]),
        isTrue,
      );
    },
  );

  test('androidGroupDissolutionReasonCodes reports concrete causes', () {
    expect(
      androidGroupDissolutionReasonCodes([
        _groupMember('owner', AndroidGroupMemberStatus.left),
        _groupMember('member-a', AndroidGroupMemberStatus.active),
      ]),
      [
        AndroidGroupDissolutionReason.ownerLeft,
        AndroidGroupDissolutionReason.minimumMemberCount,
      ],
    );
    expect(
      androidGroupDissolutionReasonCodes([
        _groupMember('owner', AndroidGroupMemberStatus.active),
        _groupMember('member-a', AndroidGroupMemberStatus.active),
      ]),
      [AndroidGroupDissolutionReason.minimumMemberCount],
    );
    expect(
      androidGroupDissolutionReasonCodes([
        _groupMember('owner', AndroidGroupMemberStatus.left),
        _groupMember('member-a', AndroidGroupMemberStatus.active),
        _groupMember('member-b', AndroidGroupMemberStatus.active),
        _groupMember('pending-c', AndroidGroupMemberStatus.pending),
      ]),
      [AndroidGroupDissolutionReason.ownerLeft],
    );
  });
}

AndroidMessageRecord _message({
  required String envelopeId,
  required String direction,
  required String deliveryStatus,
}) {
  return AndroidMessageRecord(
    envelopeId: envelopeId,
    conversationId: 'conversation',
    direction: direction,
    peerKeyId: 'peer-key',
    peerDisplayName: 'Peer',
    createdAtUnixMs: 1000,
    messageCounter: 1,
    text: 'hello',
    opaqueEnvelopeBase64: 'AAAA',
    deliveryStatus: deliveryStatus,
  );
}

AndroidGroupMemberRecord _groupMember(String keyId, String status) {
  return AndroidGroupMemberRecord(
    groupId: 'group-1',
    keyId: keyId,
    displayName: keyId,
    contactJson: '{}',
    role: keyId == 'owner'
        ? AndroidGroupMemberRole.owner
        : AndroidGroupMemberRole.member,
    status: status,
    trustState: AndroidGroupTrustState.verified,
    updatedAtUnixMs: 1000,
  );
}
