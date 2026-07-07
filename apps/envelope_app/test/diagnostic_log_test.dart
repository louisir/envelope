import 'dart:convert';
import 'dart:io';

import 'package:envelope_app/diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('envelope_diag_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('writes sanitized jsonl and exports logs', () async {
    final log = DiagnosticLogService(
      directory: tempDir,
      now: () => DateTime.utc(2026, 7, 6, 1, 2, 3, 4),
      baseFields: const {'app_version': 'test'},
    );

    await log.info('send_message', {
      'message_text': 'secret text',
      'payload_bytes': 42,
      'endpoint': 'https://example.test',
    });

    final lines = utf8.decode(await log.exportBytes()).trim().split('\n');
    expect(lines, hasLength(1));
    final entry = jsonDecode(lines.single) as Map<String, Object?>;
    expect(entry['event'], 'send_message');
    expect(entry['app_version'], 'test');
    final fields = (entry['fields'] as Map).cast<String, Object?>();
    expect(fields['message_text'], '<redacted>');
    expect(fields['payload_bytes'], 42);
    expect(fields['endpoint'], 'https://example.test');
  });

  test('clears diagnostic log files', () async {
    final log = DiagnosticLogService(directory: tempDir);
    await log.warn('failure', {'error': 'network'});

    expect(utf8.decode(await log.exportBytes()).trim(), isNotEmpty);
    final deleted = await log.clear();

    expect(deleted, greaterThan(0));
    expect(utf8.decode(await log.exportBytes()).trim(), isEmpty);
  });
}
