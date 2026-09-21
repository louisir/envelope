import 'dart:io';

import 'package:envelope_app/android_db_store.dart';
import 'package:envelope_app/android_relay_ha_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late AndroidDbStore db;
  late AndroidRelayHaClient client;
  final config = <String, Object?>{
    'cluster_id': 'cluster',
    'control_generation': '1',
    'config_epoch': '1',
    'not_after': '99999',
    'business_nodes': [
      {'node_id': 's1', 'public_url': 'https://primary.test/'},
      {'node_id': 's2', 'public_url': 'https://backup.test/'},
    ],
  };
  // Isolates client orchestration from native cryptography, which uses the
  // shared Rust vectors. Every acceptance here still goes through this seam.
  Map<String, Object?> verify(Map<String, Object?> request) {
    if (request['op'] == 'verify_config') {
      return Map.from(request['config'] as Map);
    }
    if (request['op'] == 'verify_status') {
      final status = (request['status'] as Map).cast<String, Object?>();
      if (status['nonce'] != request['nonce']) {
        throw const FormatException('bad nonce');
      }
      return {
        'status': status,
        'watermark': {
          'cluster_id': 'cluster',
          'control_generation': '1',
          'config_epoch': '1',
          'leader_term': status['leader_term'],
        },
      };
    }
    if (request['op'] == 'hash') return {'sha256': 'digest'};
    if (request['op'] == 'sign_request') return request;
    throw StateError('Unexpected native operation');
  }

  Map<String, Object?> status(
    Uri node,
    String path, {
    String role = 'leader',
    String term = '1',
  }) => {
    'node_id': node.host == 'primary.test' ? 's1' : 's2',
    'role': role,
    'mode': 'normal',
    'ready': role == 'leader',
    'leader_term': term,
    'nonce': Uri.parse(path).queryParameters['nonce'],
    'expires_at': '5000',
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('envelope-ha-network-');
    db = AndroidDbStore.forTesting(
      databaseFactory: databaseFactoryFfi,
      databaseDirectory: directory.path,
    );
    await db.init('test-only');
  });
  tearDown(() async {
    client.close();
    await db.close();
    await directory.delete(recursive: true);
  });

  AndroidRelayHaClient makeClient(RelayHaTransport transport) =>
      AndroidRelayHaClient(
        adminPublic: 'pinned',
        clusterId: 'cluster',
        bootstrapUrls: ['https://primary.test/'],
        native: verify,
        store: db.relayHa,
        transport: transport,
        now: () => 1000,
      );

  test(
    'concurrent calls share discovery and configuration never sets active address',
    () async {
      var configCalls = 0;
      var statusCalls = 0;
      client = makeClient((node, method, path, body) async {
        if (path == 'v2/cluster/config') {
          configCalls++;
          return config;
        }
        statusCalls++;
        expect(client.activeBaseUri, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return status(node, path);
      });
      await Future.wait(List.generate(10, (_) => client.discover()));
      expect(configCalls, 1);
      expect(statusCalls, 1);
      expect(client.activeBaseUri, Uri.parse('https://primary.test/'));
      expect(client.state, RelayConnectionState.readyNormal);
      expect(
        (await db.relayHa.clusterState('cluster'))!['watermark'],
        containsPair('leader_term', '1'),
      );
    },
  );

  test(
    'NOT_LEADER reauthenticates configured backup with the same business body',
    () async {
      var failed = false;
      final bodies = <Object?>[];
      client = makeClient((node, method, path, body) async {
        if (path == 'v2/cluster/config') return config;
        if (path.startsWith('v2/cluster/status')) {
          return status(
            node,
            path,
            role: failed && node.host == 'primary.test' ? 'follower' : 'leader',
            term: failed ? '2' : '1',
          );
        }
        bodies.add(body!['body_b64']);
        if (!failed) {
          failed = true;
          throw const RelayHaException('NOT_LEADER');
        }
        expect(node.host, 'backup.test');
        return {'accepted': true};
      });
      final response = await client.request(
        path: 'v2/envelopes',
        requestKind: 'store_envelope',
        actorId: 'sender',
        operationId: 'fixed-operation',
        identityJson: '{}',
        body: {'id': 'fixed'},
      );
      expect(response['accepted'], true);
      expect(bodies, hasLength(2));
      expect(bodies[0], bodies[1]);
      expect(client.activeBaseUri!.host, 'backup.test');
    },
  );

  test(
    'rate limit and auth conflict never evade policy through another node',
    () async {
      var writes = 0;
      client = makeClient((node, method, path, body) async {
        if (path == 'v2/cluster/config') return config;
        if (path.startsWith('v2/cluster/status')) return status(node, path);
        writes++;
        throw const RelayHaException(
          'RATE_LIMITED',
          retryAfter: Duration(seconds: 30),
        );
      });
      await expectLater(
        client.request(
          path: 'v2/envelopes',
          requestKind: 'store_envelope',
          actorId: 'sender',
          operationId: 'fixed-operation',
          identityJson: '{}',
          body: {},
        ),
        throwsA(
          isA<RelayHaException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
      expect(writes, 1);
    },
  );

  test('persisted higher term refuses stale leader after restart', () async {
    await db.relayHa.saveClusterState({
      'config': config,
      'watermark': {
        'cluster_id': 'cluster',
        'control_generation': '1',
        'config_epoch': '1',
        'leader_term': '7',
      },
    });
    client = makeClient(
      (node, method, path, body) async =>
          path == 'v2/cluster/config' ? config : status(node, path, term: '6'),
    );
    await expectLater(client.discover(), throwsA(isA<RelayHaException>()));
    expect(client.activeBaseUri, isNull);
    expect(
      (await db.relayHa.clusterState('cluster'))!['watermark'],
      containsPair('leader_term', '7'),
    );
  });
}
