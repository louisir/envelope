import 'dart:convert';

const int androidMessageCounterNamespaceBits = 32;
const int androidMessageCounterStride = 1 << androidMessageCounterNamespaceBits;
const int androidMessageCounterNamespaceMask = androidMessageCounterStride - 1;
const int androidMaximumMessageCounter = 0x7fffffffffffffff;
const int androidMaximumMessageCounterSequence =
    androidMaximumMessageCounter >> androidMessageCounterNamespaceBits;
const int androidPortableRestoreCounterReservation = 1024;
const int androidMaximumPortableReceivedCounters = 1000000;
const int androidMaximumPortableGroupEvents = 10000;
const int androidMaximumPortableGroupEventPayloadBytes = 1024 * 1024;
const int androidMaximumPortableGroupEventPayloadTotalBytes = 16 * 1024 * 1024;

bool androidHasValidCounterLane({
  required int nextMessageCounter,
  required int counterNamespace,
  required int counterNamespaceBits,
}) {
  return counterNamespaceBits == androidMessageCounterNamespaceBits &&
      counterNamespace > 0 &&
      counterNamespace <= androidMessageCounterNamespaceMask &&
      nextMessageCounter >= androidMessageCounterStride &&
      nextMessageCounter <= androidMaximumMessageCounter &&
      (nextMessageCounter & androidMessageCounterNamespaceMask) ==
          counterNamespace;
}

int androidMessageCounterSequence(int counter) {
  if (counter <= 0) return 0;
  return counter < androidMessageCounterStride
      ? counter
      : counter >> androidMessageCounterNamespaceBits;
}

int androidComposeMessageCounter(int sequence, int counterNamespace) {
  if (sequence <= 0 || sequence > androidMaximumMessageCounterSequence) {
    throw RangeError.range(
      sequence,
      1,
      androidMaximumMessageCounterSequence,
      'sequence',
    );
  }
  if (counterNamespace <= 0 ||
      counterNamespace > androidMessageCounterNamespaceMask) {
    throw RangeError.range(
      counterNamespace,
      1,
      androidMessageCounterNamespaceMask,
      'counterNamespace',
    );
  }
  return (sequence << androidMessageCounterNamespaceBits) | counterNamespace;
}

int androidAdvanceMessageCounter(int counter, [int count = 1]) {
  if (counter <= 0) {
    throw RangeError.value(counter, 'counter', 'must be positive');
  }
  if (count < 0) {
    throw RangeError.value(count, 'count', 'must not be negative');
  }
  final delta = counter >= androidMessageCounterStride
      ? count * androidMessageCounterStride
      : count;
  final result = counter + delta;
  if (result > androidMaximumMessageCounter) {
    throw StateError('Android message counter lane is exhausted');
  }
  return result;
}

int androidInferredCounterNamespace({
  required int nextMessageCounter,
  required int counterNamespace,
  required int counterNamespaceBits,
}) {
  if (counterNamespace != 0 ||
      counterNamespaceBits != 0 ||
      nextMessageCounter < androidMessageCounterStride) {
    return 0;
  }
  return nextMessageCounter & androidMessageCounterNamespaceMask;
}

class AndroidReceivedCounterRange {
  const AndroidReceivedCounterRange(this.start, this.end);

  factory AndroidReceivedCounterRange.fromJson(Object? json) {
    if (json is! List || json.length != 2) {
      throw const FormatException(
        'received counter range must have two bounds',
      );
    }
    final start = _positiveCounter(json[0]);
    final end = _positiveCounter(json[1]);
    if (end < start) {
      throw const FormatException('received counter range end precedes start');
    }
    return AndroidReceivedCounterRange(start, end);
  }

  final int start;
  final int end;

  int get length => end - start + 1;

  List<int> toJson() => [start, end];
}

class AndroidReceivedCounterRanges {
  const AndroidReceivedCounterRanges({
    required this.senderKeyId,
    required this.ranges,
  });

  factory AndroidReceivedCounterRanges.fromJson(Map<Object?, Object?> json) {
    final senderKeyId = (json['sender_key_id']?.toString() ?? '').trim();
    if (senderKeyId.isEmpty) {
      throw const FormatException('received counter sender_key_id is empty');
    }
    final wireRanges = json['ranges'];
    if (wireRanges is! List) {
      throw const FormatException('received counter ranges must be an array');
    }
    return AndroidReceivedCounterRanges(
      senderKeyId: senderKeyId,
      ranges: _normalizeCounterRanges(
        wireRanges.map(AndroidReceivedCounterRange.fromJson),
      ),
    );
  }

  final String senderKeyId;
  final List<AndroidReceivedCounterRange> ranges;

  int get counterCount => ranges.fold(0, (sum, range) => sum + range.length);

  Map<String, Object?> toJson() => {
    'sender_key_id': senderKeyId,
    'ranges': ranges.map((range) => range.toJson()).toList(),
  };
}

int _positiveCounter(Object? value) {
  if (value is! num) {
    throw const FormatException('received counter bound is not numeric');
  }
  final parsed = value.toInt();
  if (parsed <= 0 || parsed > androidMaximumMessageCounter || parsed != value) {
    throw const FormatException('received counter bound is invalid');
  }
  return parsed;
}

List<AndroidReceivedCounterRange> _normalizeCounterRanges(
  Iterable<AndroidReceivedCounterRange> ranges,
) {
  final sorted = ranges.toList()
    ..sort((left, right) {
      final start = left.start.compareTo(right.start);
      return start != 0 ? start : left.end.compareTo(right.end);
    });
  final result = <AndroidReceivedCounterRange>[];
  for (final range in sorted) {
    if (result.isEmpty) {
      result.add(range);
      continue;
    }
    final previous = result.last;
    if (range.start <= previous.end ||
        (previous.end < androidMaximumMessageCounter &&
            range.start == previous.end + 1)) {
      result[result.length - 1] = AndroidReceivedCounterRange(
        previous.start,
        range.end > previous.end ? range.end : previous.end,
      );
    } else {
      result.add(range);
    }
  }
  return List.unmodifiable(result);
}

List<AndroidReceivedCounterRanges> androidNormalizeReceivedCounterRanges(
  Iterable<AndroidReceivedCounterRanges> senders,
) {
  final bySender = <String, List<AndroidReceivedCounterRange>>{};
  for (final sender in senders) {
    final keyId = sender.senderKeyId.trim();
    if (keyId.isEmpty) {
      throw const FormatException('received counter sender_key_id is empty');
    }
    bySender.putIfAbsent(keyId, () => []).addAll(sender.ranges);
  }
  final result =
      bySender.entries
          .map(
            (entry) => AndroidReceivedCounterRanges(
              senderKeyId: entry.key,
              ranges: _normalizeCounterRanges(entry.value),
            ),
          )
          .where((sender) => sender.ranges.isNotEmpty)
          .toList()
        ..sort((left, right) => left.senderKeyId.compareTo(right.senderKeyId));
  final count = result.fold(0, (sum, sender) => sum + sender.counterCount);
  if (count > androidMaximumPortableReceivedCounters) {
    throw const FormatException(
      'portable received counter ranges are too large',
    );
  }
  return List.unmodifiable(result);
}

List<AndroidReceivedCounterRanges> _parsePortableReceivedCounterRanges(
  Object? value,
) {
  if (value == null) return const [];
  if (value is! List) {
    throw const FormatException(
      'portable received_counter_ranges must be an array',
    );
  }
  final result = <AndroidReceivedCounterRanges>[];
  for (final item in value) {
    if (item is! Map) {
      throw const FormatException(
        'portable received counter must be an object',
      );
    }
    result.add(AndroidReceivedCounterRanges.fromJson(item));
  }
  return androidNormalizeReceivedCounterRanges(result);
}

List<AndroidGroupEventRecord> _parsePortableGroupEvents(Object? value) {
  if (value == null) return const [];
  if (value is! List) {
    throw const FormatException('portable group_events must be an array');
  }
  final events = <AndroidGroupEventRecord>[];
  for (final item in value) {
    if (item is! Map) {
      throw const FormatException('portable group_event must be an object');
    }
    events.add(AndroidGroupEventRecord.fromPortableBackupJson(item));
  }
  return androidNormalizePortableGroupEvents(events);
}

class AndroidChatStore {
  const AndroidChatStore({
    required this.contacts,
    required this.messages,
    required this.nextMessageCounter,
    this.groups = const [],
    this.groupMembers = const [],
    this.groupEvents = const [],
    this.counterNamespace = 0,
    this.counterNamespaceBits = 0,
    this.counterDeviceId,
    this.receivedCounterRecipientKeyId,
    this.receivedCounterRanges = const [],
    this.retiredCounterNamespaces = const [],
  });

  factory AndroidChatStore.empty() {
    return const AndroidChatStore(
      contacts: [],
      messages: [],
      nextMessageCounter: 1,
      groups: [],
      groupMembers: [],
      groupEvents: [],
      receivedCounterRanges: [],
    );
  }

  factory AndroidChatStore.fromJsonString(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Android chat store must be a JSON object');
    }
    return AndroidChatStore.fromJson(decoded);
  }

  factory AndroidChatStore.fromJson(Map<String, Object?> json) {
    return AndroidChatStore(
      contacts: (json['contacts'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AndroidContactRecord.fromJson(item))
          .toList(),
      messages: (json['messages'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AndroidMessageRecord.fromJson(item))
          .toList(),
      groups: (json['groups'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AndroidGroupRecord.fromJson(item))
          .toList(),
      groupMembers: (json['group_members'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AndroidGroupMemberRecord.fromJson(item))
          .toList(),
      groupEvents: _parsePortableGroupEvents(json['group_events']),
      nextMessageCounter: (json['next_message_counter'] as num?)?.toInt() ?? 1,
      counterNamespace: (json['counter_namespace'] as num?)?.toInt() ?? 0,
      counterNamespaceBits:
          (json['counter_namespace_bits'] as num?)?.toInt() ?? 0,
      counterDeviceId: json['counter_device_id']?.toString(),
      receivedCounterRecipientKeyId: json['received_counter_recipient_key_id']
          ?.toString(),
      receivedCounterRanges: _parsePortableReceivedCounterRanges(
        json['received_counter_ranges'],
      ),
    ).normalized();
  }

  final List<AndroidContactRecord> contacts;
  final List<AndroidMessageRecord> messages;
  final int nextMessageCounter;
  final List<AndroidGroupRecord> groups;
  final List<AndroidGroupMemberRecord> groupMembers;
  final List<AndroidGroupEventRecord> groupEvents;
  final int counterNamespace;
  final int counterNamespaceBits;
  final String? counterDeviceId;
  final String? receivedCounterRecipientKeyId;
  final List<AndroidReceivedCounterRanges> receivedCounterRanges;
  final List<int> retiredCounterNamespaces;

  bool get hasValidCounterLane => androidHasValidCounterLane(
    nextMessageCounter: nextMessageCounter,
    counterNamespace: counterNamespace,
    counterNamespaceBits: counterNamespaceBits,
  );

  AndroidChatStore normalized() {
    final sortedContacts = [...contacts]
      ..sort((a, b) => a.displayLabel.compareTo(b.displayLabel));
    final sortedMessages = [...messages]
      ..sort((a, b) => a.createdAtUnixMs.compareTo(b.createdAtUnixMs));
    final sortedGroups = [...groups]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final sortedGroupMembers = [...groupMembers]
      ..sort((a, b) {
        final groupCompare = a.groupId.compareTo(b.groupId);
        if (groupCompare != 0) return groupCompare;
        final roleCompare = a.role.compareTo(b.role);
        if (roleCompare != 0) return roleCompare;
        return a.displayLabel.compareTo(b.displayLabel);
      });
    final normalizedGroupEvents = androidNormalizePortableGroupEvents(
      groupEvents,
    );
    final normalizedRetiredNamespaces =
        retiredCounterNamespaces
            .where(
              (value) =>
                  value > 0 &&
                  value <= androidMessageCounterNamespaceMask &&
                  value != counterNamespace,
            )
            .toSet()
            .toList()
          ..sort();
    return AndroidChatStore(
      contacts: sortedContacts,
      messages: sortedMessages,
      nextMessageCounter: nextMessageCounter < 1 ? 1 : nextMessageCounter,
      groups: sortedGroups,
      groupMembers: sortedGroupMembers,
      groupEvents: normalizedGroupEvents,
      counterNamespace: counterNamespace,
      counterNamespaceBits: counterNamespaceBits,
      counterDeviceId: counterDeviceId?.trim(),
      receivedCounterRecipientKeyId: receivedCounterRecipientKeyId?.trim(),
      receivedCounterRanges: androidNormalizeReceivedCounterRanges(
        receivedCounterRanges,
      ),
      retiredCounterNamespaces: normalizedRetiredNamespaces,
    );
  }

  AndroidContactRecord? findContact(String keyId) {
    for (final contact in contacts) {
      if (contact.keyId == keyId) return contact;
    }
    return null;
  }

  AndroidGroupRecord? findGroup(String groupId) {
    for (final group in groups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }

  AndroidGroupMemberRecord? findGroupMember(String groupId, String keyId) {
    for (final member in groupMembers) {
      if (member.groupId == groupId && member.keyId == keyId) return member;
    }
    return null;
  }

  List<AndroidGroupMemberRecord> membersForGroup(String groupId) {
    return groupMembers
        .where((member) => member.groupId == groupId)
        .toList(growable: false);
  }

  List<AndroidGroupMemberRecord> activeMembersForGroup(String groupId) {
    return groupMembers
        .where((member) => member.groupId == groupId && member.isActive)
        .toList(growable: false);
  }

  AndroidChatStore upsertContact(AndroidContactRecord contact) {
    final next = [
      for (final item in contacts)
        if (item.keyId != contact.keyId) item,
      contact,
    ];
    return copyWith(contacts: next).normalized();
  }

  AndroidChatStore addMessage(AndroidMessageRecord message) {
    final exists = messages.any(
      (item) => item.envelopeId == message.envelopeId,
    );
    if (exists) return this;
    return copyWith(messages: [...messages, message]).normalized();
  }

  AndroidChatStore upsertMessage(AndroidMessageRecord message) {
    final next = [
      for (final item in messages)
        if (item.envelopeId != message.envelopeId) item,
      message,
    ];
    return copyWith(messages: next).normalized();
  }

  AndroidChatStore updateMessageDelivery({
    required String envelopeId,
    required String deliveryStatus,
    String? deliveryDetail,
  }) {
    return copyWith(
      messages: [
        for (final item in messages)
          if (item.envelopeId == envelopeId)
            item.copyWith(
              deliveryStatus: deliveryStatus,
              deliveryDetail: deliveryDetail,
              deliveryUpdatedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
            )
          else
            item,
      ],
    ).normalized();
  }

  List<AndroidMessageRecord> pendingMessages() {
    return messages
        .where(
          (message) =>
              message.direction == 'outgoing' &&
              message.deliveryStatus == AndroidDeliveryStatus.pending,
        )
        .toList();
  }

  AndroidChatStore copyWith({
    List<AndroidContactRecord>? contacts,
    List<AndroidMessageRecord>? messages,
    int? nextMessageCounter,
    List<AndroidGroupRecord>? groups,
    List<AndroidGroupMemberRecord>? groupMembers,
    List<AndroidGroupEventRecord>? groupEvents,
    int? counterNamespace,
    int? counterNamespaceBits,
    String? counterDeviceId,
    String? receivedCounterRecipientKeyId,
    List<AndroidReceivedCounterRanges>? receivedCounterRanges,
    List<int>? retiredCounterNamespaces,
  }) {
    return AndroidChatStore(
      contacts: contacts ?? this.contacts,
      messages: messages ?? this.messages,
      nextMessageCounter: nextMessageCounter ?? this.nextMessageCounter,
      groups: groups ?? this.groups,
      groupMembers: groupMembers ?? this.groupMembers,
      groupEvents: groupEvents ?? this.groupEvents,
      counterNamespace: counterNamespace ?? this.counterNamespace,
      counterNamespaceBits: counterNamespaceBits ?? this.counterNamespaceBits,
      counterDeviceId: counterDeviceId ?? this.counterDeviceId,
      receivedCounterRecipientKeyId:
          receivedCounterRecipientKeyId ?? this.receivedCounterRecipientKeyId,
      receivedCounterRanges:
          receivedCounterRanges ?? this.receivedCounterRanges,
      retiredCounterNamespaces:
          retiredCounterNamespaces ?? this.retiredCounterNamespaces,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'version': 1,
      'contacts': contacts.map((item) => item.toJson()).toList(),
      'messages': messages.map((item) => item.toJson()).toList(),
      'groups': groups.map((item) => item.toJson()).toList(),
      'group_members': groupMembers.map((item) => item.toJson()).toList(),
      'group_events': groupEvents
          .map((item) => item.toPortableBackupJson())
          .toList(),
      'next_message_counter': nextMessageCounter,
      if (hasValidCounterLane) ...{
        'counter_namespace': counterNamespace,
        'counter_namespace_bits': counterNamespaceBits,
        if (counterDeviceId != null && counterDeviceId!.trim().isNotEmpty)
          'counter_device_id': counterDeviceId!.trim(),
      },
      if (receivedCounterRecipientKeyId != null &&
          receivedCounterRecipientKeyId!.trim().isNotEmpty)
        'received_counter_recipient_key_id': receivedCounterRecipientKeyId!
            .trim(),
      'received_counter_ranges': receivedCounterRanges
          .map((sender) => sender.toJson())
          .toList(),
    };
  }

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

Set<int> androidCounterNamespacesToExclude(Iterable<AndroidChatStore> stores) {
  final result = <int>{};
  for (final store in stores) {
    result.addAll(
      store.retiredCounterNamespaces.where(
        (value) => value > 0 && value <= androidMessageCounterNamespaceMask,
      ),
    );
    if (store.counterNamespace > 0 &&
        store.counterNamespace <= androidMessageCounterNamespaceMask) {
      result.add(store.counterNamespace);
    }
    final inferred = androidInferredCounterNamespace(
      nextMessageCounter: store.nextMessageCounter,
      counterNamespace: store.counterNamespace,
      counterNamespaceBits: store.counterNamespaceBits,
    );
    if (inferred > 0) result.add(inferred);
  }
  return result;
}

AndroidChatStore androidPreparePortableBackupRestore({
  required AndroidChatStore backupStore,
  required AndroidChatStore currentCounterState,
  required String recipientIdentityKeyId,
  required int newCounterNamespace,
  required String newCounterDeviceId,
}) {
  final recipientKeyId = recipientIdentityKeyId.trim();
  if (recipientKeyId.isEmpty) {
    throw const FormatException('portable backup recipient identity is empty');
  }
  final backupRecipient =
      backupStore.receivedCounterRecipientKeyId?.trim() ?? '';
  if (backupRecipient.isNotEmpty && backupRecipient != recipientKeyId) {
    throw const FormatException(
      'portable received counters belong to another recipient identity',
    );
  }
  if (newCounterDeviceId.trim().isEmpty) {
    throw const FormatException('new counter device id is empty');
  }
  final excluded = androidCounterNamespacesToExclude([
    currentCounterState,
    backupStore,
  ]);
  if (newCounterNamespace <= 0 ||
      newCounterNamespace > androidMessageCounterNamespaceMask ||
      excluded.contains(newCounterNamespace)) {
    throw const FormatException(
      'new counter namespace is invalid or belongs to an old endpoint',
    );
  }

  final currentRecipient =
      currentCounterState.receivedCounterRecipientKeyId?.trim() ?? '';
  final sameCurrentIdentity = currentRecipient == recipientKeyId;
  final backupSequence = androidMessageCounterSequence(
    backupStore.nextMessageCounter,
  );
  final currentSequence = sameCurrentIdentity
      ? androidMessageCounterSequence(currentCounterState.nextMessageCounter)
      : 0;
  final highWater = backupSequence > currentSequence
      ? backupSequence
      : currentSequence;
  final nextSequence =
      highWater <=
          androidMaximumMessageCounterSequence -
              androidPortableRestoreCounterReservation
      ? (highWater + androidPortableRestoreCounterReservation)
            .clamp(1, androidMaximumMessageCounterSequence)
            .toInt()
      : 1;
  final mergedReceivedCounters = androidNormalizeReceivedCounterRanges([
    if (sameCurrentIdentity) ...currentCounterState.receivedCounterRanges,
    ...backupStore.receivedCounterRanges,
  ]);
  final retired = <int>{...excluded}..remove(newCounterNamespace);

  return backupStore
      .copyWith(
        messages: const [],
        nextMessageCounter: androidComposeMessageCounter(
          nextSequence,
          newCounterNamespace,
        ),
        counterNamespace: newCounterNamespace,
        counterNamespaceBits: androidMessageCounterNamespaceBits,
        counterDeviceId: newCounterDeviceId.trim(),
        receivedCounterRecipientKeyId: recipientKeyId,
        receivedCounterRanges: mergedReceivedCounters,
        retiredCounterNamespaces: retired.toList(),
      )
      .normalized();
}

class AndroidContactRecord {
  const AndroidContactRecord({
    required this.keyId,
    required this.displayName,
    required this.contactJson,
    this.remark,
    this.deviceId,
    this.p2pTicket,
    this.p2pTicketUpdatedAtUnixMs,
  });

  factory AndroidContactRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidContactRecord(
      keyId: json['key_id']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      contactJson: json['contact_json']?.toString() ?? '',
      remark: json['remark']?.toString(),
      deviceId: json['device_id']?.toString(),
      p2pTicket: json['p2p_ticket']?.toString(),
      p2pTicketUpdatedAtUnixMs: (json['p2p_ticket_updated_at_unix_ms'] as num?)
          ?.toInt(),
    );
  }

  final String keyId;
  final String displayName;
  final String contactJson;
  final String? remark;
  final String? deviceId;
  final String? p2pTicket;
  final int? p2pTicketUpdatedAtUnixMs;

  bool get hasP2pTicket => p2pTicket != null && p2pTicket!.trim().isNotEmpty;
  bool get hasRemark => remark != null && remark!.trim().isNotEmpty;
  String get displayLabel => hasRemark ? remark!.trim() : displayName;

  AndroidContactRecord copyWith({
    String? keyId,
    String? displayName,
    String? contactJson,
    String? remark,
    bool clearRemark = false,
    String? deviceId,
    String? p2pTicket,
    int? p2pTicketUpdatedAtUnixMs,
  }) {
    return AndroidContactRecord(
      keyId: keyId ?? this.keyId,
      displayName: displayName ?? this.displayName,
      contactJson: contactJson ?? this.contactJson,
      remark: clearRemark ? null : (remark ?? this.remark),
      deviceId: deviceId ?? this.deviceId,
      p2pTicket: p2pTicket ?? this.p2pTicket,
      p2pTicketUpdatedAtUnixMs:
          p2pTicketUpdatedAtUnixMs ?? this.p2pTicketUpdatedAtUnixMs,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'key_id': keyId,
      'display_name': displayName,
      'contact_json': contactJson,
      if (remark != null && remark!.trim().isNotEmpty) 'remark': remark!.trim(),
      if (deviceId != null && deviceId!.isNotEmpty) 'device_id': deviceId,
      if (p2pTicket != null && p2pTicket!.isNotEmpty) 'p2p_ticket': p2pTicket,
      if (p2pTicketUpdatedAtUnixMs != null)
        'p2p_ticket_updated_at_unix_ms': p2pTicketUpdatedAtUnixMs,
    };
  }
}

class AndroidMessageRecord {
  const AndroidMessageRecord({
    required this.envelopeId,
    required this.conversationId,
    required this.direction,
    required this.peerKeyId,
    required this.peerDisplayName,
    required this.createdAtUnixMs,
    required this.messageCounter,
    required this.text,
    required this.opaqueEnvelopeBase64,
    this.deliveryStatus = AndroidDeliveryStatus.received,
    this.deliveryDetail,
    this.deliveryUpdatedAtUnixMs,
    this.attachmentUri,
    this.attachmentPath,
    this.attachmentMime,
    this.attachmentDeletedAtUnixMs,
  });

  factory AndroidMessageRecord.fromJson(Map<Object?, Object?> json) {
    final direction = json['direction']?.toString() ?? 'incoming';
    return AndroidMessageRecord(
      envelopeId: json['envelope_id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      direction: direction,
      peerKeyId: json['peer_key_id']?.toString() ?? '',
      peerDisplayName: json['peer_display_name']?.toString() ?? '',
      createdAtUnixMs: (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      messageCounter: (json['message_counter'] as num?)?.toInt() ?? 0,
      text: json['text']?.toString() ?? '',
      opaqueEnvelopeBase64: json['opaque_envelope_b64']?.toString() ?? '',
      deliveryStatus:
          json['delivery_status']?.toString() ??
          (direction == 'outgoing'
              ? AndroidDeliveryStatus.created
              : AndroidDeliveryStatus.received),
      deliveryDetail: json['delivery_detail']?.toString(),
      deliveryUpdatedAtUnixMs: (json['delivery_updated_at_unix_ms'] as num?)
          ?.toInt(),
      attachmentUri: json['attachment_uri']?.toString(),
      attachmentPath: json['attachment_path']?.toString(),
      attachmentMime: json['attachment_mime']?.toString(),
      attachmentDeletedAtUnixMs: (json['attachment_deleted_at_unix_ms'] as num?)
          ?.toInt(),
    );
  }

  final String envelopeId;
  final String conversationId;
  final String direction;
  final String peerKeyId;
  final String peerDisplayName;
  final int createdAtUnixMs;
  final int messageCounter;
  final String text;
  final String opaqueEnvelopeBase64;
  final String deliveryStatus;
  final String? deliveryDetail;
  final int? deliveryUpdatedAtUnixMs;
  final String? attachmentUri;
  final String? attachmentPath;
  final String? attachmentMime;
  final int? attachmentDeletedAtUnixMs;

  bool get isOutgoing => direction == 'outgoing';
  bool get hasTrackableIncomingCounter =>
      direction == 'incoming' &&
      peerKeyId.trim().isNotEmpty &&
      conversationId.trim().isNotEmpty &&
      messageCounter > 0;
  bool get attachmentDeleted => (attachmentDeletedAtUnixMs ?? 0) > 0;

  AndroidMessageRecord copyWith({
    String? envelopeId,
    String? conversationId,
    String? direction,
    String? peerKeyId,
    String? peerDisplayName,
    int? createdAtUnixMs,
    int? messageCounter,
    String? text,
    String? opaqueEnvelopeBase64,
    String? deliveryStatus,
    String? deliveryDetail,
    int? deliveryUpdatedAtUnixMs,
    String? attachmentUri,
    String? attachmentPath,
    String? attachmentMime,
    int? attachmentDeletedAtUnixMs,
  }) {
    return AndroidMessageRecord(
      envelopeId: envelopeId ?? this.envelopeId,
      conversationId: conversationId ?? this.conversationId,
      direction: direction ?? this.direction,
      peerKeyId: peerKeyId ?? this.peerKeyId,
      peerDisplayName: peerDisplayName ?? this.peerDisplayName,
      createdAtUnixMs: createdAtUnixMs ?? this.createdAtUnixMs,
      messageCounter: messageCounter ?? this.messageCounter,
      text: text ?? this.text,
      opaqueEnvelopeBase64: opaqueEnvelopeBase64 ?? this.opaqueEnvelopeBase64,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      deliveryDetail: deliveryDetail ?? this.deliveryDetail,
      deliveryUpdatedAtUnixMs:
          deliveryUpdatedAtUnixMs ?? this.deliveryUpdatedAtUnixMs,
      attachmentUri: attachmentUri ?? this.attachmentUri,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      attachmentMime: attachmentMime ?? this.attachmentMime,
      attachmentDeletedAtUnixMs:
          attachmentDeletedAtUnixMs ?? this.attachmentDeletedAtUnixMs,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'envelope_id': envelopeId,
      'conversation_id': conversationId,
      'direction': direction,
      'peer_key_id': peerKeyId,
      'peer_display_name': peerDisplayName,
      'created_at_unix_ms': createdAtUnixMs,
      'message_counter': messageCounter,
      'text': text,
      'opaque_envelope_b64': opaqueEnvelopeBase64,
      'delivery_status': deliveryStatus,
      if (deliveryDetail != null && deliveryDetail!.isNotEmpty)
        'delivery_detail': deliveryDetail,
      if (deliveryUpdatedAtUnixMs != null)
        'delivery_updated_at_unix_ms': deliveryUpdatedAtUnixMs,
      if (attachmentUri != null && attachmentUri!.isNotEmpty)
        'attachment_uri': attachmentUri,
      if (attachmentPath != null && attachmentPath!.isNotEmpty)
        'attachment_path': attachmentPath,
      if (attachmentMime != null && attachmentMime!.isNotEmpty)
        'attachment_mime': attachmentMime,
      if (attachmentDeletedAtUnixMs != null)
        'attachment_deleted_at_unix_ms': attachmentDeletedAtUnixMs,
    };
  }
}

class AndroidDeliveryStatus {
  const AndroidDeliveryStatus._();

  static const created = 'created';
  static const pending = 'pending';
  static const sent = 'sent';
  static const serverMailbox = 'server_mailbox';
  static const received = 'received';
}

class AndroidGroupPolicy {
  const AndroidGroupPolicy._();

  static const normal = 'normal';
  static const verified = 'verified';
  static const consensus = 'consensus';

  static const values = <String>[normal, verified, consensus];

  static String normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : normal;
  }

  static String label(String value) {
    return switch (normalize(value)) {
      verified => '验证群',
      consensus => '共识群',
      _ => '普通群',
    };
  }
}

class AndroidGroupMemberRole {
  const AndroidGroupMemberRole._();

  static const owner = 'owner';
  static const member = 'member';

  static String normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == owner ? owner : member;
  }
}

class AndroidGroupMemberStatus {
  const AndroidGroupMemberStatus._();

  static const active = 'active';
  static const pending = 'pending';
  static const accepted = 'accepted';
  static const left = 'left';
  static const removed = 'removed';

  static const values = <String>[active, pending, accepted, left, removed];

  static String normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : pending;
  }
}

class AndroidGroupTrustState {
  const AndroidGroupTrustState._();

  static const verified = 'verified';
  static const inviter = 'inviter';
  static const unverified = 'unverified';
  static const consensusPending = 'consensus_pending';
  static const consensusAdmitted = 'consensus_admitted';

  static const values = <String>[
    verified,
    inviter,
    unverified,
    consensusPending,
    consensusAdmitted,
  ];

  static String normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : unverified;
  }
}

class AndroidGroupDissolutionReason {
  const AndroidGroupDissolutionReason._();

  static const ownerLeft = 'owner_left';
  static const minimumMemberCount = 'minimum_member_count';

  static const values = <String>[ownerLeft, minimumMemberCount];

  static String? normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : null;
  }
}

int androidConsensusThreshold(int existingActiveMemberCount) {
  if (existingActiveMemberCount <= 0) return 0;
  return (existingActiveMemberCount * 6 + 9) ~/ 10;
}

bool androidGroupMembershipCountsTowardMinimum(
  AndroidGroupMemberRecord member,
) {
  return member.status != AndroidGroupMemberStatus.left &&
      member.status != AndroidGroupMemberStatus.removed;
}

int androidGroupRemainingMemberCount(
  Iterable<AndroidGroupMemberRecord> members,
) {
  return members.where(androidGroupMembershipCountsTowardMinimum).length;
}

bool androidGroupShouldAutoDissolve(int remainingMemberCount) {
  return remainingMemberCount < 3;
}

bool androidGroupShouldAutoDissolveForMembers(
  Iterable<AndroidGroupMemberRecord> members,
) {
  final list = members.toList(growable: false);
  if (androidGroupShouldAutoDissolve(androidGroupRemainingMemberCount(list))) {
    return true;
  }
  final hasActiveOwner = list.any(
    (member) => member.isOwner && member.isActive,
  );
  return !hasActiveOwner;
}

List<String> androidGroupDissolutionReasonCodes(
  Iterable<AndroidGroupMemberRecord> members,
) {
  final list = members.toList(growable: false);
  final reasons = <String>[];
  final hasActiveOwner = list.any(
    (member) => member.isOwner && member.isActive,
  );
  if (!hasActiveOwner) {
    reasons.add(AndroidGroupDissolutionReason.ownerLeft);
  }
  if (androidGroupRemainingMemberCount(list) < 3) {
    reasons.add(AndroidGroupDissolutionReason.minimumMemberCount);
  }
  return reasons;
}

bool androidGroupIsVisibleForLocalMember(
  Iterable<AndroidGroupMemberRecord> members,
  String localKeyId,
) {
  final normalizedLocalKeyId = localKeyId.trim();
  if (normalizedLocalKeyId.isEmpty) return false;
  final list = members.toList(growable: false);
  AndroidGroupMemberRecord? self;
  for (final member in list) {
    if (member.keyId == normalizedLocalKeyId) {
      self = member;
      break;
    }
  }
  if (self == null) return false;
  final selfStatus = self.status;
  if (androidGroupShouldAutoDissolveForMembers(list)) {
    return false;
  }
  return selfStatus == AndroidGroupMemberStatus.active ||
      selfStatus == AndroidGroupMemberStatus.accepted;
}

bool androidGroupMemberShouldReceiveMembershipControl(
  AndroidGroupMemberRecord member,
  String localKeyId,
) {
  final normalizedLocalKeyId = localKeyId.trim();
  if (normalizedLocalKeyId.isNotEmpty && member.keyId == normalizedLocalKeyId) {
    return false;
  }
  return member.status != AndroidGroupMemberStatus.left &&
      member.status != AndroidGroupMemberStatus.removed;
}

class AndroidGroupRecord {
  const AndroidGroupRecord({
    required this.groupId,
    required this.name,
    required this.ownerKeyId,
    required this.policy,
    required this.epoch,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    this.avatarSeed,
    this.isActive = true,
  });

  factory AndroidGroupRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidGroupRecord(
      groupId: json['group_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      ownerKeyId: json['owner_key_id']?.toString() ?? '',
      policy: AndroidGroupPolicy.normalize(json['policy']?.toString() ?? ''),
      epoch: (json['epoch'] as num?)?.toInt() ?? 1,
      createdAtUnixMs: (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      updatedAtUnixMs: (json['updated_at_unix_ms'] as num?)?.toInt() ?? 0,
      avatarSeed: json['avatar_seed']?.toString(),
      isActive: _jsonBool(json['is_active'], defaultValue: true),
    );
  }

  final String groupId;
  final String name;
  final String ownerKeyId;
  final String policy;
  final int epoch;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final String? avatarSeed;
  final bool isActive;

  String get displayName => name.trim().isEmpty ? '未命名群组' : name.trim();
  String get displaySeed =>
      (avatarSeed?.trim().isNotEmpty ?? false) ? avatarSeed!.trim() : groupId;

  AndroidGroupRecord copyWith({
    String? groupId,
    String? name,
    String? ownerKeyId,
    String? policy,
    int? epoch,
    int? createdAtUnixMs,
    int? updatedAtUnixMs,
    String? avatarSeed,
    bool? isActive,
  }) {
    return AndroidGroupRecord(
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      ownerKeyId: ownerKeyId ?? this.ownerKeyId,
      policy: policy == null
          ? this.policy
          : AndroidGroupPolicy.normalize(policy),
      epoch: epoch ?? this.epoch,
      createdAtUnixMs: createdAtUnixMs ?? this.createdAtUnixMs,
      updatedAtUnixMs: updatedAtUnixMs ?? this.updatedAtUnixMs,
      avatarSeed: avatarSeed ?? this.avatarSeed,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'group_id': groupId,
      'name': name,
      'owner_key_id': ownerKeyId,
      'policy': AndroidGroupPolicy.normalize(policy),
      'epoch': epoch,
      'created_at_unix_ms': createdAtUnixMs,
      'updated_at_unix_ms': updatedAtUnixMs,
      'avatar_seed': avatarSeed,
      'is_active': isActive ? 1 : 0,
    };
  }
}

class AndroidGroupMemberRecord {
  const AndroidGroupMemberRecord({
    required this.groupId,
    required this.keyId,
    required this.displayName,
    required this.contactJson,
    required this.role,
    required this.status,
    required this.trustState,
    this.invitedByKeyId,
    this.joinedAtUnixMs,
    required this.updatedAtUnixMs,
  });

  factory AndroidGroupMemberRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidGroupMemberRecord(
      groupId: json['group_id']?.toString() ?? '',
      keyId: json['key_id']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      contactJson: json['contact_json']?.toString() ?? '',
      role: AndroidGroupMemberRole.normalize(json['role']?.toString() ?? ''),
      status: AndroidGroupMemberStatus.normalize(
        json['status']?.toString() ?? '',
      ),
      trustState: AndroidGroupTrustState.normalize(
        json['trust_state']?.toString() ?? '',
      ),
      invitedByKeyId: json['invited_by_key_id']?.toString(),
      joinedAtUnixMs: (json['joined_at_unix_ms'] as num?)?.toInt(),
      updatedAtUnixMs: (json['updated_at_unix_ms'] as num?)?.toInt() ?? 0,
    );
  }

  final String groupId;
  final String keyId;
  final String displayName;
  final String contactJson;
  final String role;
  final String status;
  final String trustState;
  final String? invitedByKeyId;
  final int? joinedAtUnixMs;
  final int updatedAtUnixMs;

  bool get isOwner => role == AndroidGroupMemberRole.owner;
  bool get isActive => status == AndroidGroupMemberStatus.active;
  bool get isPending => status == AndroidGroupMemberStatus.pending;
  bool get isAccepted => status == AndroidGroupMemberStatus.accepted;
  bool get isLocallyTrusted =>
      trustState == AndroidGroupTrustState.verified ||
      trustState == AndroidGroupTrustState.inviter ||
      trustState == AndroidGroupTrustState.consensusAdmitted;
  String get displayLabel => displayName.trim().isEmpty ? keyId : displayName;

  AndroidContactRecord toContactRecord() {
    return AndroidContactRecord(
      keyId: keyId,
      displayName: displayLabel,
      contactJson: contactJson,
    );
  }

  AndroidGroupMemberRecord copyWith({
    String? groupId,
    String? keyId,
    String? displayName,
    String? contactJson,
    String? role,
    String? status,
    String? trustState,
    String? invitedByKeyId,
    int? joinedAtUnixMs,
    bool clearJoinedAt = false,
    int? updatedAtUnixMs,
  }) {
    return AndroidGroupMemberRecord(
      groupId: groupId ?? this.groupId,
      keyId: keyId ?? this.keyId,
      displayName: displayName ?? this.displayName,
      contactJson: contactJson ?? this.contactJson,
      role: role == null ? this.role : AndroidGroupMemberRole.normalize(role),
      status: status == null
          ? this.status
          : AndroidGroupMemberStatus.normalize(status),
      trustState: trustState == null
          ? this.trustState
          : AndroidGroupTrustState.normalize(trustState),
      invitedByKeyId: invitedByKeyId ?? this.invitedByKeyId,
      joinedAtUnixMs: clearJoinedAt
          ? null
          : (joinedAtUnixMs ?? this.joinedAtUnixMs),
      updatedAtUnixMs: updatedAtUnixMs ?? this.updatedAtUnixMs,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'group_id': groupId,
      'key_id': keyId,
      'display_name': displayName,
      'contact_json': contactJson,
      'role': AndroidGroupMemberRole.normalize(role),
      'status': AndroidGroupMemberStatus.normalize(status),
      'trust_state': AndroidGroupTrustState.normalize(trustState),
      'invited_by_key_id': invitedByKeyId,
      'joined_at_unix_ms': joinedAtUnixMs,
      'updated_at_unix_ms': updatedAtUnixMs,
    };
  }
}

class AndroidGroupEventRecord {
  const AndroidGroupEventRecord({
    required this.eventId,
    required this.groupId,
    required this.epoch,
    required this.type,
    required this.actorKeyId,
    required this.createdAtUnixMs,
    required this.payloadJson,
    this.signature = '',
  });

  factory AndroidGroupEventRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidGroupEventRecord(
      eventId: json['event_id']?.toString() ?? '',
      groupId: json['group_id']?.toString() ?? '',
      epoch: (json['epoch'] as num?)?.toInt() ?? 1,
      type: json['event_type']?.toString() ?? json['type']?.toString() ?? '',
      actorKeyId: json['actor_key_id']?.toString() ?? '',
      createdAtUnixMs: (json['created_at_unix_ms'] as num?)?.toInt() ?? 0,
      payloadJson: json['payload_json']?.toString() ?? '',
      signature: json['signature']?.toString() ?? '',
    );
  }

  factory AndroidGroupEventRecord.fromPortableBackupJson(
    Map<Object?, Object?> json,
  ) {
    final eventId = _requiredPortableGroupEventString(json, 'event_id');
    final groupId = _requiredPortableGroupEventString(json, 'group_id');
    final type = _requiredPortableGroupEventString(json, 'type');
    final actorKeyId = _requiredPortableGroupEventString(json, 'actor_key_id');
    final groupEpoch = json['group_epoch'];
    final createdAtUnixMs = json['created_at_unix_ms'];
    if (groupEpoch is! num ||
        groupEpoch.toInt() != groupEpoch ||
        groupEpoch.toInt() <= 0 ||
        createdAtUnixMs is! num ||
        createdAtUnixMs.toInt() != createdAtUnixMs ||
        createdAtUnixMs.toInt() <= 0) {
      throw const FormatException(
        'portable group event epoch or timestamp is invalid',
      );
    }
    final payloadValue = json['payload_json'];
    if (payloadValue is! String || payloadValue.trim().isEmpty) {
      throw const FormatException('portable group event payload_json is empty');
    }
    final payloadJson = payloadValue;
    String signature = '';
    try {
      final payload = jsonDecode(payloadJson);
      if (payload is Map) signature = payload['signature']?.toString() ?? '';
    } catch (_) {
      // The restore verifier reports the malformed signed payload.
    }
    return AndroidGroupEventRecord(
      eventId: eventId,
      groupId: groupId,
      epoch: groupEpoch.toInt(),
      type: type,
      actorKeyId: actorKeyId,
      createdAtUnixMs: createdAtUnixMs.toInt(),
      payloadJson: payloadJson,
      signature: signature,
    );
  }

  final String eventId;
  final String groupId;
  final int epoch;
  final String type;
  final String actorKeyId;
  final int createdAtUnixMs;
  final String payloadJson;
  final String signature;

  Map<String, Object?> toJson() {
    return {
      'event_id': eventId,
      'group_id': groupId,
      'epoch': epoch,
      'event_type': type,
      'actor_key_id': actorKeyId,
      'created_at_unix_ms': createdAtUnixMs,
      'payload_json': payloadJson,
      'signature': signature,
    };
  }

  Map<String, Object?> toPortableBackupJson() {
    return {
      'event_id': eventId,
      'group_id': groupId,
      'type': type,
      'actor_key_id': actorKeyId,
      'group_epoch': epoch,
      'created_at_unix_ms': createdAtUnixMs,
      'payload_json': payloadJson,
    };
  }
}

String _requiredPortableGroupEventString(
  Map<Object?, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('portable group event $key is empty');
  }
  return value.trim();
}

List<AndroidGroupEventRecord> androidNormalizePortableGroupEvents(
  Iterable<AndroidGroupEventRecord> events,
) {
  final byId = <String, AndroidGroupEventRecord>{};
  var inputCount = 0;
  var payloadBytes = 0;
  for (final event in events) {
    inputCount += 1;
    if (inputCount > androidMaximumPortableGroupEvents) {
      throw const FormatException('portable backup has too many group events');
    }
    if (event.eventId.trim().isEmpty ||
        event.groupId.trim().isEmpty ||
        event.type.trim().isEmpty ||
        event.actorKeyId.trim().isEmpty ||
        event.epoch <= 0 ||
        event.createdAtUnixMs <= 0 ||
        event.payloadJson.trim().isEmpty) {
      throw const FormatException('portable group event fields are incomplete');
    }
    final eventPayloadBytes = utf8.encode(event.payloadJson).length;
    if (eventPayloadBytes > androidMaximumPortableGroupEventPayloadBytes) {
      throw const FormatException('portable group event payload is too large');
    }
    payloadBytes += eventPayloadBytes;
    if (payloadBytes > androidMaximumPortableGroupEventPayloadTotalBytes) {
      throw const FormatException(
        'portable group event payload total is too large',
      );
    }
    final normalized = AndroidGroupEventRecord(
      eventId: event.eventId.trim(),
      groupId: event.groupId.trim(),
      epoch: event.epoch,
      type: event.type.trim(),
      actorKeyId: event.actorKeyId.trim(),
      createdAtUnixMs: event.createdAtUnixMs,
      payloadJson: event.payloadJson,
      signature: event.signature,
    );
    final existing = byId[normalized.eventId];
    if (existing != null && !_samePortableGroupEvent(existing, normalized)) {
      throw FormatException(
        'portable group event id conflicts: ${normalized.eventId}',
      );
    }
    byId[normalized.eventId] = normalized;
  }
  final result = byId.values.toList()
    ..sort((left, right) {
      final group = left.groupId.compareTo(right.groupId);
      if (group != 0) return group;
      final epoch = left.epoch.compareTo(right.epoch);
      if (epoch != 0) return epoch;
      final created = left.createdAtUnixMs.compareTo(right.createdAtUnixMs);
      if (created != 0) return created;
      return left.eventId.compareTo(right.eventId);
    });
  return List.unmodifiable(result);
}

bool _samePortableGroupEvent(
  AndroidGroupEventRecord left,
  AndroidGroupEventRecord right,
) {
  return left.eventId == right.eventId &&
      left.groupId == right.groupId &&
      left.epoch == right.epoch &&
      left.type == right.type &&
      left.actorKeyId == right.actorKeyId &&
      left.createdAtUnixMs == right.createdAtUnixMs &&
      left.payloadJson == right.payloadJson;
}

bool _jsonBool(Object? value, {required bool defaultValue}) {
  if (value == null) return defaultValue;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final normalized = value.toString().trim().toLowerCase();
  if (normalized == 'true' || normalized == '1') return true;
  if (normalized == 'false' || normalized == '0') return false;
  return defaultValue;
}
