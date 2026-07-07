import 'dart:io';

import 'package:flutter/services.dart';

class AndroidSecureIdentityStore {
  static const MethodChannel _channel = MethodChannel(
    'com.westwardsoft.envelope/secure_store',
  );

  bool get isSupported => Platform.isAndroid;

  Future<bool> hasIdentity() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('hasIdentity') ?? false;
  }

  Future<SecureIdentityRecord?> readIdentity() async {
    if (!isSupported) return null;
    final value = await _channel.invokeMethod<Object?>('readIdentity');
    if (value == null) return null;
    if (value is Map) {
      return SecureIdentityRecord.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('secure store returned invalid identity');
  }

  Future<SecureIdentityRecord> writeIdentity(String identityJson) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('writeIdentity', {
      'identityJson': identityJson,
    });
    if (value is Map) {
      return SecureIdentityRecord.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('secure store did not return identity');
  }

  Future<void> clearIdentity() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('clearIdentity');
  }

  Future<String?> readChatStore() async {
    if (!isSupported) return null;
    return await _channel.invokeMethod<String?>('readChatStore');
  }

  Future<void> writeChatStore(String storeJson) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    await _channel.invokeMethod<void>('writeChatStore', {
      'storeJson': storeJson,
    });
  }

  Future<void> clearChatStore() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('clearChatStore');
  }

  Future<String?> readSyncServiceUrl() async {
    if (!isSupported) return null;
    return await _channel.invokeMethod<String?>('readSyncServiceUrl');
  }

  Future<void> writeSyncServiceUrl(String serverUrl) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    await _channel.invokeMethod<void>('writeSyncServiceUrl', {
      'serverUrl': serverUrl,
    });
  }

  Future<bool> readLocalLockEnabled() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('readLocalLockEnabled') ?? false;
  }

  Future<void> writeLocalLockEnabled(bool enabled) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    await _channel.invokeMethod<void>('writeLocalLockEnabled', {
      'enabled': enabled,
    });
  }

  Future<bool> isLocalAuthenticationAvailable() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>(
          'isLocalAuthenticationAvailable',
        ) ??
        false;
  }

  Future<bool> authenticateLocalUser({
    required String title,
    String? subtitle,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    return await _channel.invokeMethod<bool>('authenticateLocalUser', {
          'title': title,
          'subtitle': subtitle,
        }) ??
        false;
  }

  Future<String> getAppSigningCertificateSha256() async {
    if (!isSupported) return '';
    return await _channel.invokeMethod<String>(
          'getAppSigningCertificateSha256',
        ) ??
        '';
  }

  Future<String> getDatabasePassword() async {
    if (!isSupported) return '';
    final value = await _channel.invokeMethod<String>('getDatabasePassword');
    if (value == null || value.isEmpty) {
      throw const SecureStoreException('Failed to generate database password');
    }
    return value;
  }

  Future<String> getDiagnosticLogDirectory() async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<String>(
      'getDiagnosticLogDirectory',
    );
    if (value == null || value.trim().isEmpty) {
      throw const SecureStoreException('diagnostic log directory is empty');
    }
    return value;
  }

  Future<AndroidOpenLocationResult> openContainingFolder(String path) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      throw const SecureStoreException('No folder path was provided');
    }
    final value = await _channel.invokeMethod<Object?>('openContainingFolder', {
      'path': normalizedPath,
    });
    return AndroidOpenLocationResult.fromValue(value);
  }

  Future<AndroidOpenLocationResult> openSavedFileLocation({
    String? uri,
    String? path,
    String? mime,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final normalizedUri = uri?.trim() ?? '';
    final normalizedPath = path?.trim() ?? '';
    if (normalizedUri.isEmpty && normalizedPath.isEmpty) {
      throw const SecureStoreException('No saved file path was provided');
    }
    final value = await _channel.invokeMethod<Object?>(
      'openSavedFileLocation',
      {
        'uri': normalizedUri,
        'path': normalizedPath,
        'mime': mime?.trim() ?? '',
      },
    );
    return AndroidOpenLocationResult.fromValue(value);
  }

  Future<AndroidPickedFile?> pickOfflineEnvelopeFile() async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>(
      'pickOfflineEnvelopeFile',
    );
    if (value == null) return null;
    if (value is Map) {
      return AndroidPickedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException(
      'offline envelope picker returned invalid file',
    );
  }

  Future<AndroidPickedFile?> pickFileForSealing() async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('pickFileForSealing');
    if (value == null) return null;
    if (value is Map) {
      return AndroidPickedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('file picker returned invalid file');
  }

  Future<AndroidPickedFile?> pickLocalBackupFile() => pickOfflineEnvelopeFile();

  Future<Uint8List> readPickedFileChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Uint8List>(
      'readPickedFileChunk',
      {'uri': uri, 'offset': offset, 'length': length},
    );
    if (value == null) {
      throw const SecureStoreException('file chunk reader returned null');
    }
    return value;
  }

  Future<AndroidSavedFile> saveReceivedFile({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('saveReceivedFile', {
      'name': name,
      'mime': mime,
      'bytes': bytes,
    });
    if (value is Map) {
      return AndroidSavedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('saveReceivedFile returned invalid file');
  }

  Future<AndroidSavedFile> saveSealedEnvelopeFile({
    required String name,
    required Uint8List bytes,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>(
      'saveSealedEnvelopeFile',
      {'name': name, 'bytes': bytes},
    );
    if (value is Map) {
      return AndroidSavedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException(
      'saveSealedEnvelopeFile returned invalid file',
    );
  }

  Future<AndroidSavedFile> createSavedFile({
    required String name,
    required String mime,
    required String childDir,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('createSavedFile', {
      'name': name,
      'mime': mime,
      'childDir': childDir,
    });
    if (value is Map) {
      return AndroidSavedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('createSavedFile returned invalid file');
  }

  Future<void> appendSavedFileBytes({
    required String uri,
    required Uint8List bytes,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    await _channel.invokeMethod<void>('appendSavedFileBytes', {
      'uri': uri,
      'bytes': bytes,
    });
  }

  Future<AndroidSavedFile> finishSavedFile({
    required AndroidSavedFile file,
    required int bytes,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('finishSavedFile', {
      'name': file.name,
      'mime': file.mime,
      'uri': file.uri,
      'displayPath': file.displayPath,
      'bytes': bytes,
    });
    if (value is Map) {
      return AndroidSavedFile.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException('finishSavedFile returned invalid file');
  }

  Future<void> openSavedFile({String? uri, String? path, String? mime}) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final normalizedUri = uri?.trim() ?? '';
    final normalizedPath = path?.trim() ?? '';
    if (normalizedUri.isEmpty && normalizedPath.isEmpty) {
      throw const SecureStoreException('No saved file path was provided');
    }
    await _channel.invokeMethod<void>('openSavedFile', {
      'uri': normalizedUri,
      'path': normalizedPath,
      'mime': mime?.trim() ?? '',
    });
  }

  Future<AndroidSavedFilePreview?> loadSavedFilePreview({
    String? uri,
    String? path,
    String? mime,
    int maxSize = 512,
  }) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final normalizedUri = uri?.trim() ?? '';
    final normalizedPath = path?.trim() ?? '';
    if (normalizedUri.isEmpty && normalizedPath.isEmpty) {
      return null;
    }
    final value = await _channel.invokeMethod<Object?>('loadSavedFilePreview', {
      'uri': normalizedUri,
      'path': normalizedPath,
      'mime': mime?.trim() ?? '',
      'maxSize': maxSize,
    });
    if (value == null) return null;
    if (value is Map) {
      return AndroidSavedFilePreview.fromMap(value.cast<Object?, Object?>());
    }
    throw const SecureStoreException(
      'loadSavedFilePreview returned invalid preview',
    );
  }

  Future<AndroidClearEnvelopeCacheResult> clearEnvelopeCache() async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final value = await _channel.invokeMethod<Object?>('clearEnvelopeCache');
    if (value is Map) {
      return AndroidClearEnvelopeCacheResult.fromMap(
        value.cast<Object?, Object?>(),
      );
    }
    return const AndroidClearEnvelopeCacheResult(
      receivedDeleted: 0,
      sealedDeleted: 0,
    );
  }

  Future<bool> deleteSavedFile({String? uri, String? path}) async {
    if (!isSupported) {
      throw const SecureStoreException('Android secure store is unavailable');
    }
    final normalizedUri = uri?.trim() ?? '';
    final normalizedPath = path?.trim() ?? '';
    if (normalizedUri.isEmpty && normalizedPath.isEmpty) {
      return false;
    }
    return await _channel.invokeMethod<bool>('deleteSavedFile', {
          'uri': normalizedUri,
          'path': normalizedPath,
        }) ??
        false;
  }
}

class AndroidPickedFile {
  const AndroidPickedFile({
    required this.name,
    required this.mime,
    required this.uri,
    required this.sizeBytes,
  });

  final String name;
  final String mime;
  final String uri;
  final int? sizeBytes;

  factory AndroidPickedFile.fromMap(Map<Object?, Object?> value) {
    final uri = value['uri']?.toString() ?? '';
    if (uri.isEmpty) {
      throw const SecureStoreException('file picker returned invalid uri');
    }
    final rawSize = value['size'];
    final size = rawSize is num ? rawSize.toInt() : null;
    return AndroidPickedFile(
      name: value['name']?.toString() ?? 'file',
      mime: value['mime']?.toString() ?? 'application/octet-stream',
      uri: uri,
      sizeBytes: size == null || size < 0 ? null : size,
    );
  }
}

class AndroidSavedFile {
  const AndroidSavedFile({
    required this.name,
    required this.mime,
    required this.uri,
    required this.displayPath,
    required this.bytes,
  });

  final String name;
  final String mime;
  final String uri;
  final String displayPath;
  final int bytes;

  factory AndroidSavedFile.fromMap(Map<Object?, Object?> value) {
    return AndroidSavedFile(
      name: value['name']?.toString() ?? 'file',
      mime: value['mime']?.toString() ?? 'application/octet-stream',
      uri: value['uri']?.toString() ?? '',
      displayPath: value['displayPath']?.toString() ?? '',
      bytes: (value['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class AndroidSavedFilePreview {
  const AndroidSavedFilePreview({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;

  factory AndroidSavedFilePreview.fromMap(Map<Object?, Object?> value) {
    final bytes = value['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      throw const SecureStoreException('preview returned invalid bytes');
    }
    return AndroidSavedFilePreview(
      bytes: bytes,
      mime: value['mime']?.toString() ?? 'image/jpeg',
      width: (value['width'] as num?)?.toInt() ?? 0,
      height: (value['height'] as num?)?.toInt() ?? 0,
    );
  }
}

class AndroidClearEnvelopeCacheResult {
  const AndroidClearEnvelopeCacheResult({
    required this.receivedDeleted,
    required this.sealedDeleted,
  });

  final int receivedDeleted;
  final int sealedDeleted;

  factory AndroidClearEnvelopeCacheResult.fromMap(Map<Object?, Object?> value) {
    return AndroidClearEnvelopeCacheResult(
      receivedDeleted: (value['receivedDeleted'] as num?)?.toInt() ?? 0,
      sealedDeleted: (value['sealedDeleted'] as num?)?.toInt() ?? 0,
    );
  }
}

class AndroidOpenLocationResult {
  const AndroidOpenLocationResult({
    required this.status,
    required this.method,
    required this.folderPath,
  });

  final String status;
  final String method;
  final String folderPath;

  bool get openedDirectly => status == 'openedDirectly';
  bool get openedPickerAtFolder => status == 'openedPickerAtFolder';

  factory AndroidOpenLocationResult.fromValue(Object? value) {
    if (value == null) {
      return const AndroidOpenLocationResult(
        status: 'openedDirectly',
        method: 'unknown',
        folderPath: '',
      );
    }
    if (value is Map) {
      final map = value.cast<Object?, Object?>();
      return AndroidOpenLocationResult(
        status: map['status']?.toString() ?? 'openedDirectly',
        method: map['method']?.toString() ?? 'unknown',
        folderPath: map['folderPath']?.toString() ?? '',
      );
    }
    return AndroidOpenLocationResult(
      status: value.toString().isEmpty ? 'openedDirectly' : value.toString(),
      method: 'unknown',
      folderPath: '',
    );
  }
}

class SecureIdentityRecord {
  const SecureIdentityRecord({
    required this.identityJson,
    required this.keyId,
    required this.displayName,
  });

  final String identityJson;
  final String keyId;
  final String displayName;

  factory SecureIdentityRecord.fromMap(Map<Object?, Object?> value) {
    return SecureIdentityRecord(
      identityJson: value['identityJson']?.toString() ?? '',
      keyId: value['keyId']?.toString() ?? '',
      displayName: value['displayName']?.toString() ?? '',
    );
  }

  String get label {
    if (displayName.isEmpty && keyId.isEmpty) return '已保存身份';
    if (displayName.isEmpty) return keyId;
    if (keyId.isEmpty) return displayName;
    return '$displayName / $keyId';
  }
}

class SecureStoreException implements Exception {
  const SecureStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
