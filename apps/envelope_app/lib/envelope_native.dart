import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _NativeNoArg = Pointer<Utf8> Function();
typedef _DartNoArg = Pointer<Utf8> Function();
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);
typedef _NativeRecover = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DartRecover = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeLocalBackup =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DartLocalBackup = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeContactFromIdentity = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartContactFromIdentity = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeParseContact = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartParseContact = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeCreateIntroBundle =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartCreateIntroBundle =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _NativeVerifyIntroBundle = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartVerifyIntroBundle = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeSignContextPayload =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartSignContextPayload =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeVerifyContactSignature =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef _DartVerifyContactSignature =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    );
typedef _NativeVerifyNodeSetManifest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartVerifyNodeSetManifest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _NativeVerifyNodeChallenge =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Uint64,
      Uint64,
    );
typedef _DartVerifyNodeChallenge =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
    );
typedef _NativeEncryptOpaqueText =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartEncryptOpaqueText =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _NativeEncryptOpaqueFile =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint8>,
      IntPtr,
      Uint64,
    );
typedef _DartEncryptOpaqueFile =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint8>,
      int,
      int,
    );
typedef _NativeDecryptOpaqueText =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartDecryptOpaqueText =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeDecryptOpaquePayload =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartDecryptOpaquePayload =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeCreateDeviceEndpointUpdate =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Uint64,
      Uint64,
    );
typedef _DartCreateDeviceEndpointUpdate =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
    );
typedef _NativeCreateMailboxPullRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, Uint32, Uint64);
typedef _DartCreateMailboxPullRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, int, int);
typedef _NativeCreateEnvelopeSubmitRequest =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Uint64,
      Uint64,
    );
typedef _DartCreateEnvelopeSubmitRequest =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
    );
typedef _NativeCreateMailboxAckRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartCreateMailboxAckRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _NativeCreateDeliveryStatusRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartCreateDeliveryStatusRequest =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int);

class EnvelopeNative {
  EnvelopeNative._(DynamicLibrary library)
    : _free = library.lookupFunction<_NativeFree, _DartFree>(
        'envelope_ffi_free_string',
      ),
      _protocolInfo = library.lookupFunction<_NativeNoArg, _DartNoArg>(
        'envelope_ffi_protocol_info',
      ),
      _generateRecoveryPhrase = library
          .lookupFunction<_NativeNoArg, _DartNoArg>(
            'envelope_ffi_generate_recovery_phrase',
          ),
      _recoverIdentity = library.lookupFunction<_NativeRecover, _DartRecover>(
        'envelope_ffi_recover_identity',
      ),
      _encryptLocalBackup = library
          .lookupFunction<_NativeLocalBackup, _DartLocalBackup>(
            'envelope_ffi_encrypt_local_backup',
          ),
      _decryptLocalBackup = library
          .lookupFunction<_NativeLocalBackup, _DartLocalBackup>(
            'envelope_ffi_decrypt_local_backup',
          ),
      _contactFromIdentity = library
          .lookupFunction<_NativeContactFromIdentity, _DartContactFromIdentity>(
            'envelope_ffi_contact_from_identity',
          ),
      _parseContact = library
          .lookupFunction<_NativeParseContact, _DartParseContact>(
            'envelope_ffi_parse_contact',
          ),
      _createIntroBundle = library
          .lookupFunction<_NativeCreateIntroBundle, _DartCreateIntroBundle>(
            'envelope_ffi_create_intro_bundle',
          ),
      _verifyIntroBundle = library
          .lookupFunction<_NativeVerifyIntroBundle, _DartVerifyIntroBundle>(
            'envelope_ffi_verify_intro_bundle',
          ),
      _signContextPayload = library
          .lookupFunction<_NativeSignContextPayload, _DartSignContextPayload>(
            'envelope_ffi_sign_context_payload',
          ),
      _verifyContactSignature = library
          .lookupFunction<
            _NativeVerifyContactSignature,
            _DartVerifyContactSignature
          >('envelope_ffi_verify_contact_signature'),
      _verifyNodeSetManifest = library
          .lookupFunction<
            _NativeVerifyNodeSetManifest,
            _DartVerifyNodeSetManifest
          >('envelope_ffi_verify_node_set_manifest'),
      _verifyNodeChallenge = library
          .lookupFunction<_NativeVerifyNodeChallenge, _DartVerifyNodeChallenge>(
            'envelope_ffi_verify_node_challenge',
          ),
      _encryptOpaqueText = library
          .lookupFunction<_NativeEncryptOpaqueText, _DartEncryptOpaqueText>(
            'envelope_ffi_encrypt_opaque_text',
          ),
      _encryptOpaqueFile = library
          .lookupFunction<_NativeEncryptOpaqueFile, _DartEncryptOpaqueFile>(
            'envelope_ffi_encrypt_opaque_file',
          ),
      _decryptOpaqueText = library
          .lookupFunction<_NativeDecryptOpaqueText, _DartDecryptOpaqueText>(
            'envelope_ffi_decrypt_opaque_text',
          ),
      _decryptOpaquePayload = library
          .lookupFunction<
            _NativeDecryptOpaquePayload,
            _DartDecryptOpaquePayload
          >('envelope_ffi_decrypt_opaque_payload'),
      _createDeviceEndpointUpdate = library
          .lookupFunction<
            _NativeCreateDeviceEndpointUpdate,
            _DartCreateDeviceEndpointUpdate
          >('envelope_ffi_create_device_endpoint_update'),
      _createMailboxPullRequest = library
          .lookupFunction<
            _NativeCreateMailboxPullRequest,
            _DartCreateMailboxPullRequest
          >('envelope_ffi_create_mailbox_pull_request'),
      _createEnvelopeSubmitRequest = library
          .lookupFunction<
            _NativeCreateEnvelopeSubmitRequest,
            _DartCreateEnvelopeSubmitRequest
          >('envelope_ffi_create_envelope_submit_request'),
      _createMailboxAckRequest = library
          .lookupFunction<
            _NativeCreateMailboxAckRequest,
            _DartCreateMailboxAckRequest
          >('envelope_ffi_create_mailbox_ack_request'),
      _createDeliveryStatusRequest = library
          .lookupFunction<
            _NativeCreateDeliveryStatusRequest,
            _DartCreateDeliveryStatusRequest
          >('envelope_ffi_create_delivery_status_request');

  final _DartFree _free;
  final _DartNoArg _protocolInfo;
  final _DartNoArg _generateRecoveryPhrase;
  final _DartRecover _recoverIdentity;
  final _DartLocalBackup _encryptLocalBackup;
  final _DartLocalBackup _decryptLocalBackup;
  final _DartContactFromIdentity _contactFromIdentity;
  final _DartParseContact _parseContact;
  final _DartCreateIntroBundle _createIntroBundle;
  final _DartVerifyIntroBundle _verifyIntroBundle;
  final _DartSignContextPayload _signContextPayload;
  final _DartVerifyContactSignature _verifyContactSignature;
  final _DartVerifyNodeSetManifest _verifyNodeSetManifest;
  final _DartVerifyNodeChallenge _verifyNodeChallenge;
  final _DartEncryptOpaqueText _encryptOpaqueText;
  final _DartEncryptOpaqueFile _encryptOpaqueFile;
  final _DartDecryptOpaqueText _decryptOpaqueText;
  final _DartDecryptOpaquePayload _decryptOpaquePayload;
  final _DartCreateDeviceEndpointUpdate _createDeviceEndpointUpdate;
  final _DartCreateMailboxPullRequest _createMailboxPullRequest;
  final _DartCreateEnvelopeSubmitRequest _createEnvelopeSubmitRequest;
  final _DartCreateMailboxAckRequest _createMailboxAckRequest;
  final _DartCreateDeliveryStatusRequest _createDeliveryStatusRequest;

  static EnvelopeNative load(Directory repoRoot) {
    if (Platform.isAndroid) {
      return EnvelopeNative._(DynamicLibrary.open('libenvelope_ffi.so'));
    }

    final libraryName = _libraryName();
    final appDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      p.join(appDir.path, libraryName),
      p.join(appDir.path, 'bin', libraryName),
      p.join(repoRoot.path, libraryName),
      p.join(repoRoot.path, 'bin', libraryName),
      p.join(repoRoot.path, 'target', 'release', libraryName),
      p.join(repoRoot.path, 'target', 'debug', libraryName),
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return EnvelopeNative._(DynamicLibrary.open(candidate));
      }
    }
    throw EnvelopeNativeException(
      'envelope-ffi native library not found: $libraryName',
    );
  }

  Map<String, Object?> protocolInfo() {
    final value = _callJson(_protocolInfo);
    if (value is! Map) {
      throw const EnvelopeNativeException(
        'protocol info must be a JSON object',
      );
    }
    return value.cast<String, Object?>();
  }

  String generateRecoveryPhrase() =>
      _callJson(_generateRecoveryPhrase) as String;

  NativeIdentitySummary recoverIdentity({
    required String displayName,
    required String recoveryPhrase,
  }) {
    final displayNamePtr = displayName.toNativeUtf8();
    final recoveryPhrasePtr = recoveryPhrase.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(_recoverIdentity(displayNamePtr, recoveryPhrasePtr)),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'identity summary must be a JSON object',
        );
      }
      return NativeIdentitySummary.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(displayNamePtr);
      malloc.free(recoveryPhrasePtr);
    }
  }

  String encryptLocalBackup({
    required String recoveryPhrase,
    required String plaintextJson,
  }) {
    final recoveryPhrasePtr = recoveryPhrase.toNativeUtf8();
    final plaintextPtr = plaintextJson.toNativeUtf8();
    try {
      return _decodeResponse(
            _takeString(_encryptLocalBackup(recoveryPhrasePtr, plaintextPtr)),
          )
          as String;
    } finally {
      malloc.free(recoveryPhrasePtr);
      malloc.free(plaintextPtr);
    }
  }

  String decryptLocalBackup({
    required String recoveryPhrase,
    required String backupJson,
  }) {
    final recoveryPhrasePtr = recoveryPhrase.toNativeUtf8();
    final backupPtr = backupJson.toNativeUtf8();
    try {
      return _decodeResponse(
            _takeString(_decryptLocalBackup(recoveryPhrasePtr, backupPtr)),
          )
          as String;
    } finally {
      malloc.free(recoveryPhrasePtr);
      malloc.free(backupPtr);
    }
  }

  String contactFromIdentityJson(String identityJson) {
    final identityPtr = identityJson.toNativeUtf8();
    try {
      return _decodeResponse(_takeString(_contactFromIdentity(identityPtr)))
          as String;
    } finally {
      malloc.free(identityPtr);
    }
  }

  NativeContactSummary parseContact(String contactJson) {
    final contactPtr = contactJson.toNativeUtf8();
    try {
      final value = _decodeResponse(_takeString(_parseContact(contactPtr)));
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'contact summary must be a JSON object',
        );
      }
      return NativeContactSummary.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(contactPtr);
    }
  }

  NativeIntroBundle createIntroBundle({
    required String identityJson,
    required String deviceId,
    String p2pTicket = '',
    int ttlSeconds = 300,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final deviceIdPtr = deviceId.toNativeUtf8();
    final ticketPtr = p2pTicket.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createIntroBundle(identityPtr, deviceIdPtr, ticketPtr, ttlSeconds),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'intro bundle summary must be a JSON object',
        );
      }
      return NativeIntroBundle.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(deviceIdPtr);
      malloc.free(ticketPtr);
    }
  }

  NativeIntroBundle verifyIntroBundle(String bundleJson) {
    final bundlePtr = bundleJson.toNativeUtf8();
    try {
      final value = _decodeResponse(_takeString(_verifyIntroBundle(bundlePtr)));
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'intro bundle summary must be a JSON object',
        );
      }
      return NativeIntroBundle.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(bundlePtr);
    }
  }

  NativeSignature signContextPayload({
    required String identityJson,
    required String context,
    required String payload,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final contextPtr = context.toNativeUtf8();
    final payloadPtr = payload.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(_signContextPayload(identityPtr, contextPtr, payloadPtr)),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'signature summary must be a JSON object',
        );
      }
      return NativeSignature.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(contextPtr);
      malloc.free(payloadPtr);
    }
  }

  NativeSignatureVerification verifyContactSignature({
    required String contactJson,
    required String context,
    required String payload,
    required String signature,
  }) {
    final contactPtr = contactJson.toNativeUtf8();
    final contextPtr = context.toNativeUtf8();
    final payloadPtr = payload.toNativeUtf8();
    final signaturePtr = signature.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _verifyContactSignature(
            contactPtr,
            contextPtr,
            payloadPtr,
            signaturePtr,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'signature verification summary must be a JSON object',
        );
      }
      return NativeSignatureVerification.fromJson(
        value.cast<String, Object?>(),
      );
    } finally {
      malloc.free(contactPtr);
      malloc.free(contextPtr);
      malloc.free(payloadPtr);
      malloc.free(signaturePtr);
    }
  }

  NativeNodeSetManifestVerification verifyNodeSetManifest({
    required String manifestJson,
    required String manifestSigningPublic,
    int nowUnixMs = 0,
  }) {
    final manifestPtr = manifestJson.toNativeUtf8();
    final publicPtr = manifestSigningPublic.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(_verifyNodeSetManifest(manifestPtr, publicPtr, nowUnixMs)),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'node manifest verification summary must be a JSON object',
        );
      }
      return NativeNodeSetManifestVerification.fromJson(
        value.cast<String, Object?>(),
      );
    } finally {
      malloc.free(manifestPtr);
      malloc.free(publicPtr);
    }
  }

  NativeNodeChallengeVerification verifyNodeChallenge({
    required String requestJson,
    required String responseJson,
    required String nodePublicKey,
    int nowUnixMs = 0,
    int maxClockSkewMs = 300000,
  }) {
    final requestPtr = requestJson.toNativeUtf8();
    final responsePtr = responseJson.toNativeUtf8();
    final publicPtr = nodePublicKey.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _verifyNodeChallenge(
            requestPtr,
            responsePtr,
            publicPtr,
            nowUnixMs,
            maxClockSkewMs,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'node challenge verification summary must be a JSON object',
        );
      }
      return NativeNodeChallengeVerification.fromJson(
        value.cast<String, Object?>(),
      );
    } finally {
      malloc.free(requestPtr);
      malloc.free(responsePtr);
      malloc.free(publicPtr);
    }
  }

  NativeOutboundOpaqueText encryptOpaqueText({
    required String identityJson,
    required String recipientContactJson,
    required String text,
    required int messageCounter,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final contactPtr = recipientContactJson.toNativeUtf8();
    final textPtr = text.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _encryptOpaqueText(identityPtr, contactPtr, textPtr, messageCounter),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'outbound opaque text must be a JSON object',
        );
      }
      return NativeOutboundOpaqueText.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(contactPtr);
      malloc.free(textPtr);
    }
  }

  NativeOutboundOpaqueFile encryptOpaqueFile({
    required String identityJson,
    required String recipientContactJson,
    required String filename,
    required String mime,
    required Uint8List payloadBytes,
    required int messageCounter,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final contactPtr = recipientContactJson.toNativeUtf8();
    final filenamePtr = filename.toNativeUtf8();
    final mimePtr = mime.toNativeUtf8();
    final allocationLength = payloadBytes.isEmpty ? 1 : payloadBytes.length;
    final payloadPtr = malloc<Uint8>(allocationLength);
    payloadPtr.asTypedList(allocationLength).setAll(0, payloadBytes);
    try {
      final value = _decodeResponse(
        _takeString(
          _encryptOpaqueFile(
            identityPtr,
            contactPtr,
            filenamePtr,
            mimePtr,
            payloadPtr,
            payloadBytes.length,
            messageCounter,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'outbound opaque file must be a JSON object',
        );
      }
      return NativeOutboundOpaqueFile.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(contactPtr);
      malloc.free(filenamePtr);
      malloc.free(mimePtr);
      malloc.free(payloadPtr);
    }
  }

  NativeInboundOpaqueText decryptOpaqueText({
    required String identityJson,
    required String senderContactJson,
    required String envelopeBase64,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final contactPtr = senderContactJson.toNativeUtf8();
    final envelopePtr = envelopeBase64.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(_decryptOpaqueText(identityPtr, contactPtr, envelopePtr)),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'inbound opaque text must be a JSON object',
        );
      }
      return NativeInboundOpaqueText.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(contactPtr);
      malloc.free(envelopePtr);
    }
  }

  NativeInboundOpaquePayload decryptOpaquePayload({
    required String identityJson,
    required String senderContactJson,
    required String envelopeBase64,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final contactPtr = senderContactJson.toNativeUtf8();
    final envelopePtr = envelopeBase64.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _decryptOpaquePayload(identityPtr, contactPtr, envelopePtr),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'inbound opaque payload must be a JSON object',
        );
      }
      return NativeInboundOpaquePayload.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(contactPtr);
      malloc.free(envelopePtr);
    }
  }

  NativeDeviceEndpointUpdate createDeviceEndpointUpdate({
    required String identityJson,
    required String deviceId,
    required String p2pTicket,
    required String sessionId,
    int deviceListVersion = 1,
    int ttlSeconds = 1800,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final deviceIdPtr = deviceId.toNativeUtf8();
    final ticketPtr = p2pTicket.toNativeUtf8();
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createDeviceEndpointUpdate(
            identityPtr,
            deviceIdPtr,
            ticketPtr,
            sessionPtr,
            deviceListVersion,
            ttlSeconds,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'device endpoint update must be a JSON object',
        );
      }
      return NativeDeviceEndpointUpdate.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(deviceIdPtr);
      malloc.free(ticketPtr);
      malloc.free(sessionPtr);
    }
  }

  NativeServerRequest createMailboxPullRequest({
    required String identityJson,
    int limit = 50,
    int requestedAtUnixMs = 0,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createMailboxPullRequest(identityPtr, limit, requestedAtUnixMs),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'mailbox pull request must be a JSON object',
        );
      }
      return NativeServerRequest.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
    }
  }

  NativeServerRequest createEnvelopeSubmitRequest({
    required String identityJson,
    required String recipientKeyId,
    required String envelopeId,
    required String envelopeBase64,
    int ttlSeconds = 0,
    int submittedAtUnixMs = 0,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final recipientPtr = recipientKeyId.toNativeUtf8();
    final envelopeIdPtr = envelopeId.toNativeUtf8();
    final envelopePtr = envelopeBase64.toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createEnvelopeSubmitRequest(
            identityPtr,
            recipientPtr,
            envelopeIdPtr,
            envelopePtr,
            ttlSeconds,
            submittedAtUnixMs,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'envelope submit request must be a JSON object',
        );
      }
      return NativeServerRequest.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(recipientPtr);
      malloc.free(envelopeIdPtr);
      malloc.free(envelopePtr);
    }
  }

  NativeServerRequest createMailboxAckRequest({
    required String identityJson,
    required List<String> envelopeIds,
    int ackedAtUnixMs = 0,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final envelopeIdsPtr = jsonEncode(envelopeIds).toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createMailboxAckRequest(identityPtr, envelopeIdsPtr, ackedAtUnixMs),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'mailbox ack request must be a JSON object',
        );
      }
      return NativeServerRequest.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(envelopeIdsPtr);
    }
  }

  NativeServerRequest createDeliveryStatusRequest({
    required String identityJson,
    required List<String> envelopeIds,
    int requestedAtUnixMs = 0,
  }) {
    final identityPtr = identityJson.toNativeUtf8();
    final envelopeIdsPtr = jsonEncode(envelopeIds).toNativeUtf8();
    try {
      final value = _decodeResponse(
        _takeString(
          _createDeliveryStatusRequest(
            identityPtr,
            envelopeIdsPtr,
            requestedAtUnixMs,
          ),
        ),
      );
      if (value is! Map) {
        throw const EnvelopeNativeException(
          'delivery status request must be a JSON object',
        );
      }
      return NativeServerRequest.fromJson(value.cast<String, Object?>());
    } finally {
      malloc.free(identityPtr);
      malloc.free(envelopeIdsPtr);
    }
  }

  Object? _callJson(_DartNoArg call) => _decodeResponse(_takeString(call()));

  String _takeString(Pointer<Utf8> ptr) {
    if (ptr == nullptr) {
      throw const EnvelopeNativeException('native call returned null');
    }
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr);
    }
  }
}

class NativeIdentitySummary {
  const NativeIdentitySummary({
    required this.keyId,
    required this.displayName,
    required this.contactJson,
    required this.identityJson,
  });

  final String keyId;
  final String displayName;
  final String contactJson;
  final String identityJson;

  static NativeIdentitySummary fromJson(Map<String, Object?> json) {
    return NativeIdentitySummary(
      keyId: json['key_id'] as String,
      displayName: json['display_name'] as String,
      contactJson: json['contact_json'] as String,
      identityJson: json['identity_json'] as String,
    );
  }
}

class NativeContactSummary {
  const NativeContactSummary({
    required this.keyId,
    required this.displayName,
    required this.contactJson,
  });

  final String keyId;
  final String displayName;
  final String contactJson;

  static NativeContactSummary fromJson(Map<String, Object?> json) {
    return NativeContactSummary(
      keyId: json['key_id'] as String,
      displayName: json['display_name'] as String,
      contactJson: json['contact_json'] as String,
    );
  }
}

class NativeIntroBundle {
  const NativeIntroBundle({
    required this.keyId,
    required this.displayName,
    required this.contactJson,
    required this.bundleJson,
    required this.deviceId,
    required this.p2pTicket,
    required this.createdAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final String keyId;
  final String displayName;
  final String contactJson;
  final String bundleJson;
  final String deviceId;
  final String? p2pTicket;
  final int createdAtUnixMs;
  final int expiresAtUnixMs;

  static NativeIntroBundle fromJson(Map<String, Object?> json) {
    return NativeIntroBundle(
      keyId: json['key_id'] as String,
      displayName: json['display_name'] as String,
      contactJson: json['contact_json'] as String,
      bundleJson: json['bundle_json'] as String,
      deviceId: json['device_id'] as String,
      p2pTicket: json['p2p_ticket'] as String?,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class NativeSignature {
  const NativeSignature({required this.keyId, required this.signature});

  final String keyId;
  final String signature;

  static NativeSignature fromJson(Map<String, Object?> json) {
    return NativeSignature(
      keyId: json['key_id'] as String,
      signature: json['signature'] as String,
    );
  }
}

class NativeSignatureVerification {
  const NativeSignatureVerification({required this.keyId, required this.valid});

  final String keyId;
  final bool valid;

  static NativeSignatureVerification fromJson(Map<String, Object?> json) {
    return NativeSignatureVerification(
      keyId: json['key_id'] as String,
      valid: json['valid'] as bool,
    );
  }
}

class NativeNodeSetManifestVerification {
  const NativeNodeSetManifestVerification({
    required this.manifestId,
    required this.epoch,
    required this.nodeCount,
    required this.validUntilUnixMs,
  });

  final String manifestId;
  final int epoch;
  final int nodeCount;
  final int validUntilUnixMs;

  static NativeNodeSetManifestVerification fromJson(Map<String, Object?> json) {
    return NativeNodeSetManifestVerification(
      manifestId: json['manifest_id'] as String,
      epoch: (json['epoch'] as num).toInt(),
      nodeCount: (json['node_count'] as num).toInt(),
      validUntilUnixMs: (json['valid_until_unix_ms'] as num).toInt(),
    );
  }
}

class NativeNodeChallengeVerification {
  const NativeNodeChallengeVerification({
    required this.nodeId,
    required this.valid,
  });

  final String nodeId;
  final bool valid;

  static NativeNodeChallengeVerification fromJson(Map<String, Object?> json) {
    return NativeNodeChallengeVerification(
      nodeId: json['node_id'] as String,
      valid: json['valid'] as bool,
    );
  }
}

class NativeOutboundOpaqueText {
  const NativeOutboundOpaqueText({
    required this.envelopeId,
    required this.conversationId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.createdAtUnixMs,
    required this.messageCounter,
    required this.payloadKind,
    required this.mime,
    required this.filename,
    required this.envelopeBase64,
    required this.envelopeLength,
    required this.text,
  });

  final String envelopeId;
  final String conversationId;
  final String senderKeyId;
  final String recipientKeyId;
  final int createdAtUnixMs;
  final int messageCounter;
  final String payloadKind;
  final String mime;
  final String? filename;
  final String envelopeBase64;
  final int envelopeLength;
  final String text;

  Uint8List get envelopeBytes =>
      base64Url.decode(base64Url.normalize(envelopeBase64));

  static NativeOutboundOpaqueText fromJson(Map<String, Object?> json) {
    return NativeOutboundOpaqueText(
      envelopeId: json['envelope_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      messageCounter: (json['message_counter'] as num).toInt(),
      payloadKind: json['payload_kind'] as String,
      mime: json['mime'] as String,
      filename: json['filename'] as String?,
      envelopeBase64: json['envelope_b64'] as String,
      envelopeLength: (json['envelope_len'] as num).toInt(),
      text: json['text'] as String,
    );
  }
}

class NativeOutboundOpaqueFile {
  const NativeOutboundOpaqueFile({
    required this.envelopeId,
    required this.conversationId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.createdAtUnixMs,
    required this.messageCounter,
    required this.payloadKind,
    required this.mime,
    required this.filename,
    required this.payloadLength,
    required this.envelopeBase64,
    required this.envelopeLength,
  });

  final String envelopeId;
  final String conversationId;
  final String senderKeyId;
  final String recipientKeyId;
  final int createdAtUnixMs;
  final int messageCounter;
  final String payloadKind;
  final String mime;
  final String? filename;
  final int payloadLength;
  final String envelopeBase64;
  final int envelopeLength;

  Uint8List get envelopeBytes =>
      base64Url.decode(base64Url.normalize(envelopeBase64));

  static NativeOutboundOpaqueFile fromJson(Map<String, Object?> json) {
    return NativeOutboundOpaqueFile(
      envelopeId: json['envelope_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      messageCounter: (json['message_counter'] as num).toInt(),
      payloadKind: json['payload_kind'] as String,
      mime: json['mime'] as String,
      filename: json['filename'] as String?,
      payloadLength: (json['payload_len'] as num).toInt(),
      envelopeBase64: json['envelope_b64'] as String,
      envelopeLength: (json['envelope_len'] as num).toInt(),
    );
  }
}

class NativeInboundOpaqueText {
  const NativeInboundOpaqueText({
    required this.envelopeId,
    required this.conversationId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.createdAtUnixMs,
    required this.messageCounter,
    required this.payloadKind,
    required this.mime,
    required this.filename,
    required this.text,
  });

  final String envelopeId;
  final String conversationId;
  final String senderKeyId;
  final String recipientKeyId;
  final int createdAtUnixMs;
  final int messageCounter;
  final String payloadKind;
  final String mime;
  final String? filename;
  final String text;

  static NativeInboundOpaqueText fromJson(Map<String, Object?> json) {
    return NativeInboundOpaqueText(
      envelopeId: json['envelope_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      messageCounter: (json['message_counter'] as num).toInt(),
      payloadKind: json['payload_kind'] as String,
      mime: json['mime'] as String,
      filename: json['filename'] as String?,
      text: json['text'] as String,
    );
  }
}

class NativeInboundOpaquePayload {
  const NativeInboundOpaquePayload({
    required this.envelopeId,
    required this.conversationId,
    required this.senderKeyId,
    required this.recipientKeyId,
    required this.createdAtUnixMs,
    required this.messageCounter,
    required this.payloadKind,
    required this.mime,
    required this.filename,
    required this.payloadLength,
    required this.payloadBase64,
  });

  final String envelopeId;
  final String conversationId;
  final String senderKeyId;
  final String recipientKeyId;
  final int createdAtUnixMs;
  final int messageCounter;
  final String payloadKind;
  final String mime;
  final String? filename;
  final int payloadLength;
  final String payloadBase64;

  Uint8List get payloadBytes =>
      base64Url.decode(base64Url.normalize(payloadBase64));

  bool get isText => mime == 'text/plain; charset=utf-8';

  String get text {
    if (!isText) {
      throw const EnvelopeNativeException('opaque payload is not text');
    }
    return utf8.decode(payloadBytes);
  }

  static NativeInboundOpaquePayload fromJson(Map<String, Object?> json) {
    return NativeInboundOpaquePayload(
      envelopeId: json['envelope_id'] as String,
      conversationId: json['conversation_id'] as String,
      senderKeyId: json['sender_key_id'] as String,
      recipientKeyId: json['recipient_key_id'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      messageCounter: (json['message_counter'] as num).toInt(),
      payloadKind: json['payload_kind'] as String,
      mime: json['mime'] as String,
      filename: json['filename'] as String?,
      payloadLength: (json['payload_len'] as num).toInt(),
      payloadBase64: json['payload_b64'] as String,
    );
  }
}

class NativeDeviceEndpointUpdate {
  const NativeDeviceEndpointUpdate({
    required this.ownerKeyId,
    required this.deviceId,
    required this.endpointJson,
    required this.ownerContactJson,
    required this.createdAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final String ownerKeyId;
  final String deviceId;
  final String endpointJson;
  final String ownerContactJson;
  final int createdAtUnixMs;
  final int expiresAtUnixMs;

  static NativeDeviceEndpointUpdate fromJson(Map<String, Object?> json) {
    return NativeDeviceEndpointUpdate(
      ownerKeyId: json['owner_key_id'] as String,
      deviceId: json['device_id'] as String,
      endpointJson: json['endpoint_json'] as String,
      ownerContactJson: json['owner_contact_json'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
      expiresAtUnixMs: (json['expires_at_unix_ms'] as num).toInt(),
    );
  }
}

class NativeServerRequest {
  const NativeServerRequest({
    required this.requestJson,
    required this.keyId,
    required this.createdAtUnixMs,
  });

  final String requestJson;
  final String keyId;
  final int createdAtUnixMs;

  static NativeServerRequest fromJson(Map<String, Object?> json) {
    return NativeServerRequest(
      requestJson: json['request_json'] as String,
      keyId: json['key_id'] as String,
      createdAtUnixMs: (json['created_at_unix_ms'] as num).toInt(),
    );
  }
}

class EnvelopeNativeException implements Exception {
  const EnvelopeNativeException(this.message);

  final String message;

  @override
  String toString() => message;
}

Object? _decodeResponse(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map<String, Object?>) {
    throw const EnvelopeNativeException(
      'native response must be a JSON object',
    );
  }
  if (decoded['ok'] == true) {
    return decoded['value'];
  }
  throw EnvelopeNativeException(
    decoded['error']?.toString() ?? 'native call failed',
  );
}

String _libraryName() {
  if (Platform.isWindows) return 'envelope_ffi.dll';
  if (Platform.isMacOS) return 'libenvelope_ffi.dylib';
  return 'libenvelope_ffi.so';
}
