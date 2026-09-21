import 'dart:convert';
import 'dart:io';

import 'package:envelope_app/relay_ha_json.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reject duplicate keys at any depth including escaped aliases', () {
    for (final json in [
      '{"version":2,"version":2}',
      '{"proof":[{"node_id":"a","node_id":"b"}]}',
      r'{"a":1,"\u0061":2}',
    ]) {
      expect(() => decodeRelayJson(json), throwsFormatException);
    }
  });
  test(
    'shared vectors retain canonical decimal strings beyond JS precision',
    () {
      final fixture = File(
        '../../tests/fixtures/ha-v2/vectors.json',
      ).readAsStringSync();
      final parsed = decodeRelayJson(fixture) as Map;
      expect(parsed, jsonDecode(fixture));
      expect(
        () => decodeRelayJson(
          parsed['duplicate_recipient_result_json'] as String,
        ),
        throwsFormatException,
      );
    final vectors = parsed['valid'] as List;
      final status =
          (vectors.singleWhere((v) => v['name'] == 'cluster_status')
                  as Map)['document']
              as Map;
      expect(status['leader_term'], '9007199254740993');
    },
  );
  test('reject malformed grammar and excessive nesting', () {
    for (final input in [
      '{"a":1,}',
      '[1,]',
      '{"a":"unterminated}',
      '[true]junk',
      '[${'[' * 65}1${']' * 65}]',
    ]) {
      expect(() => decodeRelayJson(input), throwsFormatException);
    }
  });
}
