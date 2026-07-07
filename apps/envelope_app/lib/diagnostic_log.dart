import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const int defaultDiagnosticLogMaxFileBytes = 1024 * 1024;
const int defaultDiagnosticLogMaxFiles = 5;

class DiagnosticLogService {
  DiagnosticLogService({
    required this.directory,
    this.maxFileBytes = defaultDiagnosticLogMaxFileBytes,
    this.maxFiles = defaultDiagnosticLogMaxFiles,
    DateTime Function()? now,
    Map<String, Object?> baseFields = const <String, Object?>{},
  }) : _now = now ?? DateTime.now,
       _baseFields = Map<String, Object?>.unmodifiable(baseFields);

  final Directory directory;
  final int maxFileBytes;
  final int maxFiles;
  final DateTime Function() _now;
  final Map<String, Object?> _baseFields;

  File get _currentFile =>
      File(p.join(directory.path, 'envelope-diagnostic-current.jsonl'));

  Future<void> initialize() async {
    await directory.create(recursive: true);
    await _rotateIfNeeded();
    await _pruneOldFiles();
  }

  Future<void> info(String event, [Map<String, Object?> fields = const {}]) =>
      log('info', event, fields);

  Future<void> warn(String event, [Map<String, Object?> fields = const {}]) =>
      log('warn', event, fields);

  Future<void> error(String event, [Map<String, Object?> fields = const {}]) =>
      log('error', event, fields);

  Future<void> log(
    String level,
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    await initialize();
    final timestamp = _now().toUtc();
    final entry = <String, Object?>{
      'ts': timestamp.toIso8601String(),
      'level': level,
      'event': event,
      ..._sanitizeMap(_baseFields),
      if (fields.isNotEmpty) 'fields': _sanitizeMap(fields),
    };
    await _currentFile.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
    await _rotateIfNeeded();
    await _pruneOldFiles();
  }

  Future<List<int>> exportBytes() async {
    await initialize();
    final files = await _logFiles();
    final buffer = StringBuffer();
    for (final file in files) {
      final text = await file.readAsString();
      if (text.isEmpty) continue;
      buffer.write(text);
      if (!text.endsWith('\n')) {
        buffer.writeln();
      }
    }
    return utf8.encode(buffer.toString());
  }

  Future<int> clear() async {
    await directory.create(recursive: true);
    final files = await _logFiles(includeMissingCurrent: true);
    var deleted = 0;
    for (final file in files) {
      if (await file.exists()) {
        await file.delete();
        deleted += 1;
      }
    }
    return deleted;
  }

  String exportFileName() {
    final stamp = _compactTimestamp(_now().toUtc());
    return 'envelope-diagnostic-$stamp.jsonl';
  }

  Future<List<File>> _logFiles({bool includeMissingCurrent = false}) async {
    if (!await directory.exists()) {
      return includeMissingCurrent ? <File>[_currentFile] : <File>[];
    }
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == 'envelope-diagnostic-current.jsonl' ||
          (name.startsWith('envelope-diagnostic-') &&
              name.endsWith('.jsonl'))) {
        files.add(entity);
      }
    }
    if (includeMissingCurrent &&
        !files.any((file) => file.path == _currentFile.path)) {
      files.add(_currentFile);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final currentIndex = files.indexWhere(
      (file) => file.path == _currentFile.path,
    );
    if (currentIndex >= 0) {
      final current = files.removeAt(currentIndex);
      files.add(current);
    }
    return files;
  }

  Future<void> _rotateIfNeeded() async {
    final current = _currentFile;
    if (!await current.exists()) return;
    final size = await current.length();
    if (size <= maxFileBytes) return;
    final rotated = await _nextRotatedFile();
    await current.rename(rotated.path);
  }

  Future<File> _nextRotatedFile() async {
    final stamp = _compactTimestamp(_now().toUtc());
    for (var index = 0; index < 100; index += 1) {
      final suffix = index == 0 ? '' : '-$index';
      final file = File(
        p.join(directory.path, 'envelope-diagnostic-$stamp$suffix.jsonl'),
      );
      if (!await file.exists()) return file;
    }
    return File(
      p.join(
        directory.path,
        'envelope-diagnostic-$stamp-${_now().microsecondsSinceEpoch}.jsonl',
      ),
    );
  }

  Future<void> _pruneOldFiles() async {
    final keep = maxFiles.clamp(1, 1000);
    final files = await _logFiles();
    if (files.length <= keep) return;
    final archived = files
        .where((file) => file.path != _currentFile.path)
        .toList(growable: true);
    final removeCount = files.length - keep;
    for (final file in archived.take(removeCount)) {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}

Map<String, Object?> _sanitizeMap(Map<String, Object?> input) {
  return input.map(
    (key, value) => MapEntry(
      key,
      _isSensitiveKey(key) ? '<redacted>' : _sanitizeValue(value),
    ),
  );
}

Object? _sanitizeValue(Object? value) {
  if (value == null || value is num || value is bool) return value;
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is String) return _truncate(value);
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(
        key.toString(),
        _isSensitiveKey(key.toString()) ? '<redacted>' : _sanitizeValue(item),
      ),
    );
  }
  if (value is Iterable) {
    return value.map(_sanitizeValue).toList(growable: false);
  }
  return _truncate(value.toString());
}

bool _isSensitiveKey(String key) {
  final normalized = key.toLowerCase();
  if (normalized == 'bytes' || normalized == 'payload') {
    return true;
  }
  return const [
    'base64',
    'body',
    'contact',
    'envelope',
    'file_name',
    'filename',
    'identity',
    'key',
    'message',
    'password',
    'path',
    'phrase',
    'secret',
    'signature',
    'text',
    'ticket',
    'uri',
  ].any(normalized.contains);
}

String _truncate(String value, {int maxLength = 512}) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}...<truncated>';
}

String _compactTimestamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  return '${value.year}'
      '${two(value.month)}'
      '${two(value.day)}T'
      '${two(value.hour)}'
      '${two(value.minute)}'
      '${two(value.second)}'
      '${three(value.millisecond)}Z';
}
