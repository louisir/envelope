import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'android_chat_store.dart';
import 'android_secure_store.dart';
import 'envelope_native.dart';

const int androidMaximumMailboxQuarantineRecords = 1000;
const int androidMaximumDeferredMailboxEnvelopeCount = 256;
const int androidMaximumDeferredMailboxEnvelopeBytes = 12 * 1024 * 1024;
const int androidMaximumDeferredMailboxTotalBytes = 64 * 1024 * 1024;
const Duration androidDeferredMailboxRetention = Duration(days: 7);

class AndroidEnvelopeCiphertextRejectedException implements Exception {
  const AndroidEnvelopeCiphertextRejectedException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class AndroidInvalidEnvelopePayloadException implements Exception {
  const AndroidInvalidEnvelopePayloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AndroidMailboxMissingPrerequisiteException implements Exception {
  const AndroidMailboxMissingPrerequisiteException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AndroidMessageCounterReplayException implements Exception {
  const AndroidMessageCounterReplayException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AndroidMailboxFailureClassification {
  const AndroidMailboxFailureClassification({
    required this.permanent,
    required this.reasonCode,
    required this.detail,
  });

  final bool permanent;
  final String reasonCode;
  final String detail;
}

AndroidMailboxFailureClassification classifyAndroidMailboxImportFailure(
  Object error,
) {
  // FormatException.toString includes the offending source (possibly plaintext).
  // Quarantine diagnostics retain metadata, never the rejected payload itself.
  final detail = sanitizeAndroidMailboxFailureDetail(
    error is FormatException ? error.message : error.toString(),
  );
  if (error is AndroidEnvelopeCiphertextRejectedException) {
    return AndroidMailboxFailureClassification(
      permanent: true,
      reasonCode: 'authentication_failed',
      detail: detail,
    );
  }
  if (error is AndroidMessageCounterReplayException) {
    return AndroidMailboxFailureClassification(
      permanent: true,
      reasonCode: 'replay',
      detail: detail,
    );
  }
  if (error is AndroidInvalidEnvelopePayloadException) {
    return AndroidMailboxFailureClassification(
      permanent: true,
      reasonCode: 'invalid_payload',
      detail: detail,
    );
  }
  if (error is FormatException) {
    return AndroidMailboxFailureClassification(
      permanent: true,
      reasonCode: 'invalid_json',
      detail: detail,
    );
  }
  if (error is AndroidMailboxMissingPrerequisiteException) {
    return AndroidMailboxFailureClassification(
      permanent: false,
      reasonCode: 'missing_prerequisite',
      detail: detail,
    );
  }
  if (error is EnvelopeNativeException) {
    final replay = _containsReplayMarker(detail);
    return AndroidMailboxFailureClassification(
      permanent: replay,
      reasonCode: replay ? 'replay' : 'contact_or_key_unavailable',
      detail: detail,
    );
  }
  if (error is SecureStoreException) {
    return AndroidMailboxFailureClassification(
      permanent: false,
      reasonCode: 'transient_local_failure',
      detail: detail,
    );
  }
  return AndroidMailboxFailureClassification(
    permanent: false,
    reasonCode: 'transient_processing_failure',
    detail: detail,
  );
}

bool _containsReplayMarker(String value) {
  final lower = value.toLowerCase();
  return lower.contains('counter') ||
      lower.contains('replay') ||
      value.contains('计数器') ||
      value.contains('重放');
}

String sanitizeAndroidMailboxFailureDetail(String detail) {
  const maximumLength = 512;
  final normalized = detail.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  return normalized.length <= maximumLength
      ? normalized
      : normalized.substring(0, maximumLength);
}

String androidMailboxEnvelopeSha256(String envelopeBase64) =>
    crypto.sha256.convert(utf8.encode(envelopeBase64)).toString();

int androidMailboxEnvelopeSizeBytes(String envelopeBase64) =>
    utf8.encode(envelopeBase64).length;

({AndroidGroupRecord group, List<AndroidGroupMemberRecord> members})
decodeAndroidGroupControlState(Map<String, Object?> payload) {
  bool positiveInteger(Object? value) =>
      value is num && value.isFinite && value > 0 && value == value.toInt();
  bool nonemptyString(Object? value) =>
      value is String && value.trim().isNotEmpty;

  final groupValue = payload['group'];
  final membersValue = payload['members'];
  if (payload['version'] != 1 ||
      !nonemptyString(payload['event_id']) ||
      !positiveInteger(payload['created_at_unix_ms']) ||
      groupValue is! Map ||
      !nonemptyString(groupValue['group_id']) ||
      !nonemptyString(groupValue['owner_key_id']) ||
      !positiveInteger(groupValue['epoch']) ||
      membersValue is! List ||
      membersValue.isEmpty) {
    throw const AndroidInvalidEnvelopePayloadException('群组控制载荷元数据无效。');
  }
  try {
    final group = AndroidGroupRecord.fromJson(groupValue);
    final members = <AndroidGroupMemberRecord>[];
    final keys = <String>{};
    for (final value in membersValue) {
      if (value is! Map ||
          value['group_id'] != group.groupId ||
          !nonemptyString(value['key_id']) ||
          !keys.add(value['key_id'] as String)) {
        throw const AndroidInvalidEnvelopePayloadException('群组控制载荷成员无效或重复。');
      }
      members.add(AndroidGroupMemberRecord.fromJson(value));
    }
    return (group: group, members: members);
  } on TypeError {
    // Only schema conversion errors are permanent; database/platform errors
    // outside this parser must remain retriable and must not trigger an ACK.
    throw const AndroidInvalidEnvelopePayloadException('群组控制载荷字段类型无效。');
  }
}

class AndroidMailboxQuarantineRecord {
  const AndroidMailboxQuarantineRecord({
    required this.envelopeId,
    required this.senderKeyId,
    required this.reasonCode,
    required this.reasonDetail,
    required this.envelopeSha256,
    required this.envelopeSizeBytes,
    required this.quarantinedAtUnixMs,
    this.acknowledgedAtUnixMs,
  });

  factory AndroidMailboxQuarantineRecord.fromJson(Map<Object?, Object?> json) {
    return AndroidMailboxQuarantineRecord(
      envelopeId: json['envelope_id']?.toString() ?? '',
      senderKeyId: json['sender_key_id']?.toString() ?? '',
      reasonCode: json['reason_code']?.toString() ?? '',
      reasonDetail: json['reason_detail']?.toString() ?? '',
      envelopeSha256: json['envelope_sha256']?.toString() ?? '',
      envelopeSizeBytes: (json['envelope_size_bytes'] as num?)?.toInt() ?? 0,
      quarantinedAtUnixMs:
          (json['quarantined_at_unix_ms'] as num?)?.toInt() ?? 0,
      acknowledgedAtUnixMs: (json['acknowledged_at_unix_ms'] as num?)?.toInt(),
    );
  }

  final String envelopeId;
  final String senderKeyId;
  final String reasonCode;
  final String reasonDetail;
  final String envelopeSha256;
  final int envelopeSizeBytes;
  final int quarantinedAtUnixMs;
  final int? acknowledgedAtUnixMs;

  AndroidMailboxQuarantineRecord copyWith({int? acknowledgedAtUnixMs}) =>
      AndroidMailboxQuarantineRecord(
        envelopeId: envelopeId,
        senderKeyId: senderKeyId,
        reasonCode: reasonCode,
        reasonDetail: reasonDetail,
        envelopeSha256: envelopeSha256,
        envelopeSizeBytes: envelopeSizeBytes,
        quarantinedAtUnixMs: quarantinedAtUnixMs,
        acknowledgedAtUnixMs: acknowledgedAtUnixMs ?? this.acknowledgedAtUnixMs,
      );

  Map<String, Object?> toJson() => {
    'envelope_id': envelopeId,
    'sender_key_id': senderKeyId,
    'reason_code': reasonCode,
    'reason_detail': reasonDetail,
    'envelope_sha256': envelopeSha256,
    'envelope_size_bytes': envelopeSizeBytes,
    'quarantined_at_unix_ms': quarantinedAtUnixMs,
    'acknowledged_at_unix_ms': acknowledgedAtUnixMs,
  };
}

class AndroidDeferredMailboxEnvelopeRecord {
  const AndroidDeferredMailboxEnvelopeRecord({
    required this.envelopeId,
    required this.senderKeyId,
    required this.envelopeBase64,
    required this.reasonCode,
    required this.reasonDetail,
    required this.envelopeSizeBytes,
    required this.firstDeferredAtUnixMs,
    required this.lastAttemptAtUnixMs,
    this.attemptCount = 1,
  });

  factory AndroidDeferredMailboxEnvelopeRecord.fromJson(
    Map<Object?, Object?> json,
  ) {
    return AndroidDeferredMailboxEnvelopeRecord(
      envelopeId: json['envelope_id']?.toString() ?? '',
      senderKeyId: json['sender_key_id']?.toString() ?? '',
      envelopeBase64: json['envelope_b64']?.toString() ?? '',
      reasonCode: json['reason_code']?.toString() ?? '',
      reasonDetail: json['reason_detail']?.toString() ?? '',
      envelopeSizeBytes: (json['envelope_size_bytes'] as num?)?.toInt() ?? 0,
      firstDeferredAtUnixMs:
          (json['first_deferred_at_unix_ms'] as num?)?.toInt() ?? 0,
      lastAttemptAtUnixMs:
          (json['last_attempt_at_unix_ms'] as num?)?.toInt() ?? 0,
      attemptCount: (json['attempt_count'] as num?)?.toInt() ?? 1,
    );
  }

  final String envelopeId;
  final String senderKeyId;
  final String envelopeBase64;
  final String reasonCode;
  final String reasonDetail;
  final int envelopeSizeBytes;
  final int firstDeferredAtUnixMs;
  final int lastAttemptAtUnixMs;
  final int attemptCount;

  AndroidDeferredMailboxEnvelopeRecord copyWith({
    String? senderKeyId,
    String? envelopeBase64,
    String? reasonCode,
    String? reasonDetail,
    int? envelopeSizeBytes,
    int? lastAttemptAtUnixMs,
    int? attemptCount,
  }) => AndroidDeferredMailboxEnvelopeRecord(
    envelopeId: envelopeId,
    senderKeyId: senderKeyId ?? this.senderKeyId,
    envelopeBase64: envelopeBase64 ?? this.envelopeBase64,
    reasonCode: reasonCode ?? this.reasonCode,
    reasonDetail: reasonDetail ?? this.reasonDetail,
    envelopeSizeBytes: envelopeSizeBytes ?? this.envelopeSizeBytes,
    firstDeferredAtUnixMs: firstDeferredAtUnixMs,
    lastAttemptAtUnixMs: lastAttemptAtUnixMs ?? this.lastAttemptAtUnixMs,
    attemptCount: attemptCount ?? this.attemptCount,
  );

  Map<String, Object?> toJson() => {
    'envelope_id': envelopeId,
    'sender_key_id': senderKeyId,
    'envelope_b64': envelopeBase64,
    'reason_code': reasonCode,
    'reason_detail': reasonDetail,
    'envelope_size_bytes': envelopeSizeBytes,
    'first_deferred_at_unix_ms': firstDeferredAtUnixMs,
    'last_attempt_at_unix_ms': lastAttemptAtUnixMs,
    'attempt_count': attemptCount,
  };
}

class AndroidMailboxReliabilityNormalization {
  const AndroidMailboxReliabilityNormalization({
    required this.quarantine,
    required this.deferred,
    required this.removedQuarantineCount,
    required this.removedDeferredCount,
  });

  final List<AndroidMailboxQuarantineRecord> quarantine;
  final List<AndroidDeferredMailboxEnvelopeRecord> deferred;
  final int removedQuarantineCount;
  final int removedDeferredCount;
}

AndroidMailboxReliabilityNormalization normalizeAndroidMailboxReliability({
  required Iterable<AndroidMailboxQuarantineRecord> quarantine,
  required Iterable<AndroidDeferredMailboxEnvelopeRecord> deferred,
  required int nowUnixMs,
}) {
  final originalQuarantineCount = quarantine.length;
  final originalDeferredCount = deferred.length;
  final cutoff = nowUnixMs - androidDeferredMailboxRetention.inMilliseconds;
  final keptQuarantine = quarantine
      .where((record) => record.quarantinedAtUnixMs >= cutoff)
      .toList();
  final orderedDeferred = deferred.toList()
    ..sort((left, right) {
      final byTime = left.firstDeferredAtUnixMs.compareTo(
        right.firstDeferredAtUnixMs,
      );
      return byTime != 0 ? byTime : left.envelopeId.compareTo(right.envelopeId);
    });
  final keptDeferred = <AndroidDeferredMailboxEnvelopeRecord>[];
  for (final record in orderedDeferred) {
    final invalid =
        record.envelopeId.trim().isEmpty ||
        record.senderKeyId.trim().isEmpty ||
        record.envelopeBase64.trim().isEmpty ||
        record.envelopeSizeBytes <= 0 ||
        record.envelopeSizeBytes > androidMaximumDeferredMailboxEnvelopeBytes;
    final expired = record.firstDeferredAtUnixMs < cutoff;
    if (!invalid && !expired) {
      keptDeferred.add(record);
      continue;
    }
    keptQuarantine.add(
      _quarantineFromDeferred(
        record,
        reasonCode: invalid ? 'deferred_metadata_invalid' : 'deferred_expired',
        detail: invalid
            ? '持久化 deferred mailbox metadata 无效，已移除 raw body。'
            : '等待群组因果前置超过 7 天，已移除 raw body。',
        nowUnixMs: nowUnixMs,
      ),
    );
  }

  var totalBytes = keptDeferred.fold<int>(
    0,
    (total, record) =>
        total + (record.envelopeSizeBytes < 0 ? 0 : record.envelopeSizeBytes),
  );
  while (keptDeferred.length > androidMaximumDeferredMailboxEnvelopeCount ||
      totalBytes > androidMaximumDeferredMailboxTotalBytes) {
    final oldest = keptDeferred.removeAt(0);
    totalBytes -= oldest.envelopeSizeBytes < 0 ? 0 : oldest.envelopeSizeBytes;
    keptQuarantine.add(
      _quarantineFromDeferred(
        oldest,
        reasonCode: 'deferred_capacity_evicted',
        detail: 'deferred mailbox raw queue 达到容量上限，最旧项目已仅保留审计 metadata。',
        nowUnixMs: nowUnixMs,
      ),
    );
  }

  final quarantineByEnvelopeId = <String, AndroidMailboxQuarantineRecord>{};
  for (final record in keptQuarantine) {
    final existing = quarantineByEnvelopeId[record.envelopeId];
    if (existing == null ||
        record.quarantinedAtUnixMs >= existing.quarantinedAtUnixMs) {
      quarantineByEnvelopeId[record.envelopeId] = record;
    }
  }
  final deduplicatedQuarantine = quarantineByEnvelopeId.values.toList();
  deduplicatedQuarantine.sort((left, right) {
    final byTime = right.quarantinedAtUnixMs.compareTo(
      left.quarantinedAtUnixMs,
    );
    return byTime != 0 ? byTime : right.envelopeId.compareTo(left.envelopeId);
  });
  final normalizedQuarantine = deduplicatedQuarantine
      .take(androidMaximumMailboxQuarantineRecords)
      .toList(growable: false);
  final quarantineDifference =
      originalQuarantineCount - normalizedQuarantine.length;
  final deferredDifference = originalDeferredCount - keptDeferred.length;
  return AndroidMailboxReliabilityNormalization(
    quarantine: normalizedQuarantine,
    deferred: keptDeferred,
    removedQuarantineCount: quarantineDifference < 0 ? 0 : quarantineDifference,
    removedDeferredCount: deferredDifference < 0 ? 0 : deferredDifference,
  );
}

AndroidMailboxQuarantineRecord _quarantineFromDeferred(
  AndroidDeferredMailboxEnvelopeRecord record, {
  required String reasonCode,
  required String detail,
  required int nowUnixMs,
}) {
  return AndroidMailboxQuarantineRecord(
    envelopeId: record.envelopeId,
    senderKeyId: record.senderKeyId,
    reasonCode: reasonCode,
    reasonDetail: sanitizeAndroidMailboxFailureDetail(detail),
    envelopeSha256: androidMailboxEnvelopeSha256(record.envelopeBase64),
    envelopeSizeBytes: androidMailboxEnvelopeSizeBytes(record.envelopeBase64),
    quarantinedAtUnixMs: nowUnixMs,
    acknowledgedAtUnixMs: nowUnixMs,
  );
}

bool androidGroupEpochNeedsCausalDeferral({
  required String eventType,
  required int incomingEpoch,
  required int? currentEpoch,
}) {
  if (currentEpoch == null) return eventType != 'group_invite';
  if (eventType == 'group_message') return incomingEpoch > currentEpoch;
  return incomingEpoch > currentEpoch + 1;
}
