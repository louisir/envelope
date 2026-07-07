import 'package:envelope_app/android_chat_store.dart';
import 'package:envelope_app/android_db_store.dart';
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
}
