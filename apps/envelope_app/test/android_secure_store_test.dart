import 'dart:typed_data';

import 'package:envelope_app/android_secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AndroidPickedFile parses URI metadata without eager bytes', () {
    final file = AndroidPickedFile.fromMap({
      'name': 'video.mp4',
      'mime': 'video/mp4',
      'uri': 'content://media/video/1',
      'size': 123456,
    });

    expect(file.name, 'video.mp4');
    expect(file.mime, 'video/mp4');
    expect(file.uri, 'content://media/video/1');
    expect(file.sizeBytes, 123456);
  });

  test('AndroidPickedFile rejects missing URI', () {
    expect(
      () => AndroidPickedFile.fromMap({'name': 'file.bin'}),
      throwsA(isA<SecureStoreException>()),
    );
  });

  test('AndroidOpenLocationResult parses picker fallback result', () {
    final result = AndroidOpenLocationResult.fromValue({
      'status': 'openedPickerAtFolder',
      'method': 'documentTree',
      'folderPath': '/storage/emulated/0/Download/Envelope/sealed',
    });

    expect(result.openedPickerAtFolder, isTrue);
    expect(result.openedDirectly, isFalse);
    expect(result.method, 'documentTree');
    expect(result.folderPath, '/storage/emulated/0/Download/Envelope/sealed');
  });

  test('AndroidSavedFilePreview parses preview bytes', () {
    final preview = AndroidSavedFilePreview.fromMap({
      'bytes': Uint8List.fromList([1, 2, 3]),
      'mime': 'image/jpeg',
      'width': 320,
      'height': 180,
    });

    expect(preview.bytes, [1, 2, 3]);
    expect(preview.mime, 'image/jpeg');
    expect(preview.width, 320);
    expect(preview.height, 180);
  });

  test('AndroidClearEnvelopeCacheResult parses deleted counts', () {
    final result = AndroidClearEnvelopeCacheResult.fromMap({
      'receivedDeleted': 2,
      'sealedDeleted': 3,
    });

    expect(result.receivedDeleted, 2);
    expect(result.sealedDeleted, 3);
  });
}
