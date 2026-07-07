import 'package:flutter_test/flutter_test.dart';
import 'package:envelope_app/android_p2p.dart';

void main() {
  test('AndroidP2pTicket round trips route metadata', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1_000_000);
    final ticket = AndroidP2pTicket(
      deviceId: 'android-1234',
      addrs: const ['192.168.1.22', '10.0.0.8'],
      port: 39123,
      createdAtUnixMs: now.millisecondsSinceEpoch,
      expiresAtUnixMs: now
          .add(const Duration(seconds: 65))
          .millisecondsSinceEpoch,
    );

    final parsed = AndroidP2pTicket.parse(ticket.encode());

    expect(parsed.deviceId, 'android-1234');
    expect(parsed.addrs, ['192.168.1.22', '10.0.0.8']);
    expect(parsed.port, 39123);
    expect(parsed.isExpiredAt(now), isFalse);
    expect(parsed.remainingSecondsAt(now), 65);
    expect(parsed.toJson(now: now), containsPair('expired', false));
    expect(parsed.toJson(now: now), containsPair('remaining_seconds', 65));
  });

  test('AndroidP2pTicket reports expired tickets', () {
    final now = DateTime.fromMillisecondsSinceEpoch(2_000_000);
    final ticket = AndroidP2pTicket(
      deviceId: 'android-5678',
      addrs: const ['192.168.1.33'],
      port: 49123,
      createdAtUnixMs: now
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
      expiresAtUnixMs: now.millisecondsSinceEpoch,
    );

    final parsed = AndroidP2pTicket.parse(ticket.encode());

    expect(parsed.isExpiredAt(now), isTrue);
    expect(parsed.remainingAt(now), Duration.zero);
    expect(parsed.remainingSecondsAt(now), 0);
  });

  test('AndroidP2pTicket.tryParse rejects invalid values', () {
    expect(AndroidP2pTicket.tryParse(null), isNull);
    expect(AndroidP2pTicket.tryParse(''), isNull);
    expect(AndroidP2pTicket.tryParse('not-a-ticket'), isNull);
  });

  test('AndroidP2pStatus includes ticket freshness', () {
    final now = DateTime.fromMillisecondsSinceEpoch(3_000_000);
    final ticket = AndroidP2pTicket(
      deviceId: 'android-9012',
      addrs: const ['192.168.1.44'],
      port: 59123,
      createdAtUnixMs: now.millisecondsSinceEpoch,
      expiresAtUnixMs: now
          .add(const Duration(minutes: 10))
          .millisecondsSinceEpoch,
    ).encode();

    final status = AndroidP2pStatus(
      listening: true,
      ticket: ticket,
      addrs: const ['192.168.1.44'],
      port: 59123,
      expiresAtUnixMs: now
          .add(const Duration(minutes: 10))
          .millisecondsSinceEpoch,
    ).toJson(now: now);

    expect(status['ticket_expired'], false);
    expect(status['ticket_needs_refresh'], false);
    expect(status['ticket_remaining_seconds'], 600);
  });

  test('AndroidP2pTicket reports refresh window', () {
    final now = DateTime.fromMillisecondsSinceEpoch(4_000_000);
    final ticket = AndroidP2pTicket(
      deviceId: 'android-refresh',
      addrs: const ['192.168.1.55'],
      port: 49124,
      createdAtUnixMs: now.millisecondsSinceEpoch,
      expiresAtUnixMs: now
          .add(const Duration(minutes: 3))
          .millisecondsSinceEpoch,
    );

    expect(ticket.shouldRefreshAt(now, const Duration(minutes: 5)), isTrue);
    expect(ticket.shouldRefreshAt(now, const Duration(minutes: 1)), isFalse);
  });

  test('AndroidP2pCooldownTracker blocks only the failed ticket', () {
    final now = DateTime.fromMillisecondsSinceEpoch(5_000_000);
    final tracker = AndroidP2pCooldownTracker(
      cooldown: const Duration(seconds: 30),
    );

    expect(
      tracker.canAttempt(recipientKeyId: 'bob', ticket: 'ticket-a', now: now),
      isTrue,
    );

    tracker.recordFailure(recipientKeyId: 'bob', ticket: 'ticket-a', now: now);

    expect(
      tracker.canAttempt(
        recipientKeyId: 'bob',
        ticket: 'ticket-a',
        now: now.add(const Duration(seconds: 10)),
      ),
      isFalse,
    );
    expect(
      tracker.remaining(
        recipientKeyId: 'bob',
        ticket: 'ticket-a',
        now: now.add(const Duration(seconds: 10)),
      ),
      const Duration(seconds: 20),
    );
    expect(
      tracker.canAttempt(
        recipientKeyId: 'bob',
        ticket: 'ticket-b',
        now: now.add(const Duration(seconds: 10)),
      ),
      isTrue,
    );
    expect(
      tracker.canAttempt(
        recipientKeyId: 'bob',
        ticket: 'ticket-a',
        now: now.add(const Duration(seconds: 31)),
      ),
      isTrue,
    );
  });

  test('AndroidP2pCooldownTracker clears successful tickets', () {
    final now = DateTime.fromMillisecondsSinceEpoch(6_000_000);
    final tracker = AndroidP2pCooldownTracker(
      cooldown: const Duration(seconds: 30),
    );

    tracker.recordFailure(recipientKeyId: 'bob', ticket: 'ticket-a', now: now);
    tracker.recordSuccess(recipientKeyId: 'bob', ticket: 'ticket-a');

    expect(
      tracker.canAttempt(
        recipientKeyId: 'bob',
        ticket: 'ticket-a',
        now: now.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
  });
}
