import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _NativeCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

void main() {
  final path = Platform.environment['ENVELOPE_HA_FFI_LIBRARY'];
  test(
    'shared signed vectors verify through the same C ABI used by Android',
    () {
      final library = DynamicLibrary.open(path!);
      final call = library.lookupFunction<_NativeCall, _DartCall>(
        'envelope_ffi_ha_v2',
      );
      final free = library.lookupFunction<_NativeFree, _DartFree>(
        'envelope_ffi_free_string',
      );
      Map<String, Object?> dispatchRaw(String json) {
        final input = json.toNativeUtf8();
        Pointer<Utf8>? output;
        try {
          output = call(input);
          expect(output, isNot(nullptr));
          return (jsonDecode(output.toDartString()) as Map)
              .cast<String, Object?>();
        } finally {
          malloc.free(input);
          if (output != null && output != nullptr) free(output);
        }
      }

      Map<String, Object?> dispatch(Map<String, Object?> value) =>
          dispatchRaw(jsonEncode(value));
      final fixture =
          jsonDecode(
                File(
                  '../../tests/fixtures/ha-v2/vectors.json',
                ).readAsStringSync(),
              )
              as Map;
      final vectors = fixture['valid'] as List;
      Map<String, Object?> document(String name) =>
          ((vectors.singleWhere((entry) => entry['name'] == name)
                      as Map)['document']
                  as Map)
              .cast<String, Object?>();
      final config = document('cluster_config');
      final status = document('cluster_status');
      final result = document('recipient_delivered');
      expect(
        dispatch({
          'op': 'verify_config',
          'config': config,
          'admin_public': fixture['administrator_public'],
          'now': fixture['now_ms'],
        })['ok'],
        true,
      );
      final statusVerified = dispatch({
        'op': 'verify_status',
        'config': config,
        'status': status,
        'nonce': status['nonce'],
        'now': fixture['now_ms'],
        'watermark': null,
      });
      expect(statusVerified['ok'], true);
      expect(
        (statusVerified['value'] as Map)['watermark']['leader_term'],
        '9007199254740993',
      );
      expect(
        dispatch({
          'op': 'verify_receipt',
          'config': config,
          'receipt': document('commit_receipt'),
          'binding': fixture['binding'],
          'admin_public': fixture['administrator_public'],
        })['ok'],
        true,
      );
      expect(
        dispatch({
          'op': 'verify_result',
          'result': result,
          'contact': fixture['recipient_contact'],
          'binding': fixture['binding'],
        })['ok'],
        true,
      );
      final expired = document('expired_commit_receipt');
      expect(
        dispatch({
          'op': 'verify_receipt',
          'config': config,
          'receipt': expired,
          'binding': fixture['binding'],
          'admin_public': fixture['administrator_public'],
        })['ok'],
        true,
      );
      expect(
        dispatch({
          'op': 'verify_receipt',
          'config': config,
          'receipt': {...expired, 'expiry_evidence': null},
          'binding': fixture['binding'],
          'admin_public': fixture['administrator_public'],
        })['ok'],
        false,
      );
      expect(
        dispatch({
          'op': 'verify_result',
          'result': {...result, 'outcome': 'rejected'},
          'contact': fixture['recipient_contact'],
          'binding': fixture['binding'],
        })['ok'],
        false,
      );
      final duplicate = fixture['duplicate_recipient_result_json'] as String;
      expect(
        dispatchRaw(
          '{"op":"verify_result","result":$duplicate,'
          '"contact":${jsonEncode(fixture['recipient_contact'])},'
          '"binding":${jsonEncode(fixture['binding'])}}',
        )['ok'],
        false,
      );
      final rotated = vectors.where(
        (entry) => entry['name'] == 'rotated_cluster_config',
      );
      if (rotated.isNotEmpty) {
        expect(
          dispatch({
            'op': 'verify_receipt',
            'config': document('rotated_cluster_config'),
            'receipt': document('historical_commit_receipt'),
            'binding': fixture['binding'],
            'admin_public': fixture['administrator_public'],
          })['ok'],
          true,
        );
      }
    },
    skip: path == null
        ? 'Set ENVELOPE_HA_FFI_LIBRARY to the candidate native library for the release gate.'
        : false,
  );
}
