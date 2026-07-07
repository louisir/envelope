import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:envelope_app/android_server.dart';

void main() {
  test('server route response parses optional endpoint update', () {
    final response = RouteLookupResponse.fromJson({
      'version': 1,
      'owner_identity_key_id': 'a' * 32,
      'device_id': 'android-1234',
      'endpoint': {
        'version': 1,
        'owner_identity_key_id': 'a' * 32,
        'device_id': 'android-1234',
        'device_list_version': 1,
        'p2p_ticket': 'envelope-p2p-tcp-v1.test',
        'session_id': 'session-1',
        'created_at_unix_ms': 1000,
        'expires_at_unix_ms': 2000,
        'signature': 'sig',
      },
    });

    expect(response.ownerKeyId, 'a' * 32);
    expect(response.deviceId, 'android-1234');
    expect(response.endpoint?.p2pTicket, 'envelope-p2p-tcp-v1.test');
    expect(response.hasEndpoint, isTrue);
  });

  test('mailbox pull response parses envelopes', () {
    final response = MailboxPullResponse.fromJson({
      'version': 1,
      'recipient_key_id': 'b' * 32,
      'envelopes': [
        {
          'envelope_id': '00000000-0000-4000-8000-000000000001',
          'sender_key_id': 'a' * 32,
          'recipient_key_id': 'b' * 32,
          'envelope_b64': base64Url.encode([1, 2, 3]),
          'received_at_unix_ms': 1000,
          'expires_at_unix_ms': 2000,
        },
      ],
    });

    expect(response.recipientKeyId, 'b' * 32);
    expect(response.envelopes.single.senderKeyId, 'a' * 32);
    expect(response.envelopes.single.envelopeBase64, isNotEmpty);
  });

  test('intro session poll response preserves responder bundle JSON', () {
    final response = IntroSessionPollResponse.fromJson({
      'version': 1,
      'session_id': 'session-abc',
      'owner_key_id': 'a' * 32,
      'responder_bundle': {
        'version': 1,
        'contact': {'key_id': 'b' * 32},
        'device_id': 'android-bbbb',
        'expires_at_unix_ms': 2000,
      },
      'updated_at_unix_ms': 1500,
    });

    expect(response.sessionId, 'session-abc');
    expect(response.ownerKeyId, 'a' * 32);
    expect(response.hasResponderBundle, isTrue);
    expect(response.responderBundleJson, contains('android-bbbb'));
  });

  test('delivery status response parses delivered receipts', () {
    final response = DeliveryStatusResponse.fromJson({
      'version': 1,
      'sender_key_id': 'a' * 32,
      'items': [
        {
          'envelope_id': '00000000-0000-4000-8000-000000000001',
          'recipient_key_id': 'b' * 32,
          'status': 'delivered',
          'delivered_at_unix_ms': 1234,
        },
      ],
    });

    expect(response.senderKeyId, 'a' * 32);
    expect(response.items.single.isDelivered, isTrue);
    expect(response.items.single.deliveredAtUnixMs, 1234);
  });

  test('HTTP missing device route error is classified for auto register', () {
    final error = EnvelopeServerHttpException(
      baseUri: Uri.parse('https://node.example/'),
      statusCode: 404,
      reason: 'Not Found',
      apiError: 'identity has no registered device route',
      responseWasJson: true,
      message: 'HTTP 404 identity has no registered device route',
    );

    expect(error.isMissingRegisteredDeviceRoute, isTrue);
  });

  test('unrelated HTTP 404 is not treated as missing device route', () {
    final error = EnvelopeServerHttpException(
      baseUri: Uri.parse('https://node.example/'),
      statusCode: 404,
      reason: 'Not Found',
      apiError: 'route not found',
      responseWasJson: true,
      message: 'HTTP 404 route not found',
    );

    expect(error.isMissingRegisteredDeviceRoute, isFalse);
  });
}
