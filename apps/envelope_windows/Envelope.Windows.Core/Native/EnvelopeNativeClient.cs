using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Envelope.Windows.Core.Models;

namespace Envelope.Windows.Core.Native;

public sealed class EnvelopeNativeClient : IEnvelopeNativeClient
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    public EnvelopeNativeClient(string? libraryPath = null)
    {
        NativeMethods.ConfigureLibraryPath(libraryPath);
    }

    public ProtocolInfo GetProtocolInfo() =>
        Invoke<ProtocolInfo>(NativeMethods.ProtocolInfo);

    public RecoveryPhrase GenerateRecoveryPhrase()
    {
        var value = Invoke<string>(NativeMethods.GenerateRecoveryPhrase);
        return RecoveryPhrase.Parse(value);
    }

    public IdentitySummary RecoverIdentity(
        string displayName,
        RecoveryPhrase recoveryPhrase)
    {
        ArgumentNullException.ThrowIfNull(recoveryPhrase);
        return RecoverIdentityCore(displayName, recoveryPhrase.Value);
    }

    public IdentitySummary RecoverIdentity(string displayName, string recoveryPhrase) =>
        RecoverIdentity(displayName, RecoveryPhrase.Parse(recoveryPhrase));

    private static IdentitySummary RecoverIdentityCore(
        string displayName,
        string recoveryPhrase)
    {
        using var displayNameValue = new Utf8String(displayName);
        using var recoveryPhraseValue = new Utf8String(recoveryPhrase, sensitive: true);
        return Invoke<IdentitySummary>(() => NativeMethods.RecoverIdentity(
            displayNameValue.Pointer,
            recoveryPhraseValue.Pointer));
    }

    public string EncryptLocalBackup(
        RecoveryPhrase recoveryPhrase,
        string plaintextJson)
    {
        ArgumentNullException.ThrowIfNull(recoveryPhrase);
        using var recoveryPhraseValue = new Utf8String(recoveryPhrase.Value, sensitive: true);
        using var plaintextValue = new Utf8String(plaintextJson, sensitive: true);
        return Invoke<string>(() => NativeMethods.EncryptLocalBackup(
            recoveryPhraseValue.Pointer,
            plaintextValue.Pointer));
    }

    public string DecryptLocalBackup(
        RecoveryPhrase recoveryPhrase,
        string backupJson)
    {
        ArgumentNullException.ThrowIfNull(recoveryPhrase);
        using var recoveryPhraseValue = new Utf8String(recoveryPhrase.Value, sensitive: true);
        using var backupValue = new Utf8String(backupJson);
        return Invoke<string>(() => NativeMethods.DecryptLocalBackup(
            recoveryPhraseValue.Pointer,
            backupValue.Pointer));
    }

    public string ContactFromIdentity(string identityJson)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        return Invoke<string>(() => NativeMethods.ContactFromIdentity(identityValue.Pointer));
    }

    public ContactSummary ParseContact(string contactJson)
    {
        using var contactValue = new Utf8String(contactJson);
        return Invoke<ContactSummary>(() => NativeMethods.ParseContact(contactValue.Pointer));
    }

    public IntroBundleSummary CreateIntroBundle(
        string identityJson,
        string deviceId,
        string p2pTicket = "",
        ulong ttlSeconds = 300)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var deviceValue = new Utf8String(deviceId);
        using var ticketValue = new Utf8String(p2pTicket);
        return Invoke<IntroBundleSummary>(() => NativeMethods.CreateIntroBundle(
            identityValue.Pointer,
            deviceValue.Pointer,
            ticketValue.Pointer,
            ttlSeconds));
    }

    public IntroBundleSummary VerifyIntroBundle(string bundleJson)
    {
        using var bundleValue = new Utf8String(bundleJson);
        return Invoke<IntroBundleSummary>(() =>
            NativeMethods.VerifyIntroBundle(bundleValue.Pointer));
    }

    public SignatureSummary SignContextPayload(
        string identityJson,
        string context,
        string payload)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var contextValue = new Utf8String(context);
        using var payloadValue = new Utf8String(payload);
        return Invoke<SignatureSummary>(() => NativeMethods.SignContextPayload(
            identityValue.Pointer,
            contextValue.Pointer,
            payloadValue.Pointer));
    }

    public SignatureVerificationSummary VerifyContactSignature(
        string contactJson,
        string context,
        string payload,
        string signature)
    {
        using var contactValue = new Utf8String(contactJson);
        using var contextValue = new Utf8String(context);
        using var payloadValue = new Utf8String(payload);
        using var signatureValue = new Utf8String(signature);
        return Invoke<SignatureVerificationSummary>(() =>
            NativeMethods.VerifyContactSignature(
                contactValue.Pointer,
                contextValue.Pointer,
                payloadValue.Pointer,
                signatureValue.Pointer));
    }

    public NodeSetManifestVerificationSummary VerifyNodeSetManifest(
        string manifestJson,
        string manifestSigningPublic,
        ulong nowUnixMs = 0)
    {
        using var manifestValue = new Utf8String(manifestJson);
        using var publicValue = new Utf8String(manifestSigningPublic);
        return Invoke<NodeSetManifestVerificationSummary>(() =>
            NativeMethods.VerifyNodeSetManifest(
                manifestValue.Pointer,
                publicValue.Pointer,
                nowUnixMs));
    }

    public NodeChallengeVerificationSummary VerifyNodeChallenge(
        string requestJson,
        string responseJson,
        string nodePublicKey,
        ulong nowUnixMs = 0,
        ulong maxClockSkewMs = 300_000)
    {
        using var requestValue = new Utf8String(requestJson);
        using var responseValue = new Utf8String(responseJson);
        using var publicValue = new Utf8String(nodePublicKey);
        return Invoke<NodeChallengeVerificationSummary>(() =>
            NativeMethods.VerifyNodeChallenge(
                requestValue.Pointer,
                responseValue.Pointer,
                publicValue.Pointer,
                nowUnixMs,
                maxClockSkewMs));
    }

    public OutboundOpaqueTextSummary EncryptOpaqueText(
        string identityJson,
        string recipientContactJson,
        string text,
        ulong messageCounter)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var contactValue = new Utf8String(recipientContactJson);
        using var textValue = new Utf8String(text, sensitive: true);
        return Invoke<OutboundOpaqueTextSummary>(() => NativeMethods.EncryptOpaqueText(
            identityValue.Pointer,
            contactValue.Pointer,
            textValue.Pointer,
            messageCounter));
    }

    public OutboundOpaquePayloadSummary EncryptOpaqueFile(
        string identityJson,
        string recipientContactJson,
        string filename,
        string mime,
        byte[] payloadBytes,
        ulong messageCounter)
    {
        ArgumentNullException.ThrowIfNull(payloadBytes);
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var contactValue = new Utf8String(recipientContactJson);
        using var filenameValue = new Utf8String(filename);
        using var mimeValue = new Utf8String(mime);

        var payloadHandle = default(GCHandle);
        try
        {
            var payloadPointer = IntPtr.Zero;
            if (payloadBytes.Length > 0)
            {
                payloadHandle = GCHandle.Alloc(payloadBytes, GCHandleType.Pinned);
                payloadPointer = payloadHandle.AddrOfPinnedObject();
            }

            return Invoke<OutboundOpaquePayloadSummary>(() =>
                NativeMethods.EncryptOpaqueFile(
                    identityValue.Pointer,
                    contactValue.Pointer,
                    filenameValue.Pointer,
                    mimeValue.Pointer,
                    payloadPointer,
                    checked((nuint)payloadBytes.LongLength),
                    messageCounter));
        }
        finally
        {
            if (payloadHandle.IsAllocated)
            {
                payloadHandle.Free();
            }
        }
    }

    public InboundOpaqueTextSummary DecryptOpaqueText(
        string identityJson,
        string senderContactJson,
        string envelopeBase64)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var contactValue = new Utf8String(senderContactJson);
        using var envelopeValue = new Utf8String(envelopeBase64);
        return Invoke<InboundOpaqueTextSummary>(() => NativeMethods.DecryptOpaqueText(
            identityValue.Pointer,
            contactValue.Pointer,
            envelopeValue.Pointer));
    }

    public InboundOpaquePayloadSummary DecryptOpaquePayload(
        string identityJson,
        string senderContactJson,
        string envelopeBase64)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var contactValue = new Utf8String(senderContactJson);
        using var envelopeValue = new Utf8String(envelopeBase64);
        return Invoke<InboundOpaquePayloadSummary>(() => NativeMethods.DecryptOpaquePayload(
            identityValue.Pointer,
            contactValue.Pointer,
            envelopeValue.Pointer));
    }

    public DeviceEndpointUpdateSummary CreateDeviceEndpointUpdate(
        string identityJson,
        string deviceId,
        string p2pTicket,
        string sessionId,
        ulong deviceListVersion = 1,
        ulong ttlSeconds = 1_800)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var deviceValue = new Utf8String(deviceId);
        using var ticketValue = new Utf8String(p2pTicket);
        using var sessionValue = new Utf8String(sessionId, sensitive: true);
        return Invoke<DeviceEndpointUpdateSummary>(() =>
            NativeMethods.CreateDeviceEndpointUpdate(
                identityValue.Pointer,
                deviceValue.Pointer,
                ticketValue.Pointer,
                sessionValue.Pointer,
                deviceListVersion,
                ttlSeconds));
    }

    public ServerRequestSummary CreateMailboxPullRequest(
        string identityJson,
        uint limit = 50,
        ulong requestedAtUnixMs = 0)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        return Invoke<ServerRequestSummary>(() => NativeMethods.CreateMailboxPullRequest(
            identityValue.Pointer,
            limit,
            requestedAtUnixMs));
    }

    public ServerRequestSummary CreateEnvelopeSubmitRequest(
        string identityJson,
        string recipientKeyId,
        string envelopeId,
        string envelopeBase64,
        ulong ttlSeconds = 0,
        ulong submittedAtUnixMs = 0)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var recipientValue = new Utf8String(recipientKeyId);
        using var envelopeIdValue = new Utf8String(envelopeId);
        using var envelopeValue = new Utf8String(envelopeBase64);
        return Invoke<ServerRequestSummary>(() => NativeMethods.CreateEnvelopeSubmitRequest(
            identityValue.Pointer,
            recipientValue.Pointer,
            envelopeIdValue.Pointer,
            envelopeValue.Pointer,
            ttlSeconds,
            submittedAtUnixMs));
    }

    public ServerRequestSummary CreateMailboxAckRequest(
        string identityJson,
        IReadOnlyCollection<string> envelopeIds,
        ulong ackedAtUnixMs = 0)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var envelopeIdsValue = CreateEnvelopeIdsValue(envelopeIds);
        return Invoke<ServerRequestSummary>(() => NativeMethods.CreateMailboxAckRequest(
            identityValue.Pointer,
            envelopeIdsValue.Pointer,
            ackedAtUnixMs));
    }

    public ServerRequestSummary CreateDeliveryStatusRequest(
        string identityJson,
        IReadOnlyCollection<string> envelopeIds,
        ulong requestedAtUnixMs = 0)
    {
        using var identityValue = new Utf8String(identityJson, sensitive: true);
        using var envelopeIdsValue = CreateEnvelopeIdsValue(envelopeIds);
        return Invoke<ServerRequestSummary>(() =>
            NativeMethods.CreateDeliveryStatusRequest(
                identityValue.Pointer,
                envelopeIdsValue.Pointer,
                requestedAtUnixMs));
    }

    private static Utf8String CreateEnvelopeIdsValue(
        IReadOnlyCollection<string> envelopeIds)
    {
        ArgumentNullException.ThrowIfNull(envelopeIds);
        return new Utf8String(JsonSerializer.Serialize(envelopeIds, JsonOptions));
    }

    private static T Invoke<T>(Func<IntPtr> nativeCall)
    {
        ArgumentNullException.ThrowIfNull(nativeCall);
        try
        {
            var pointer = nativeCall();
            if (pointer == IntPtr.Zero)
            {
                throw new EnvelopeNativeException("Native call returned a null response.");
            }

            string responseJson;
            try
            {
                responseJson = Marshal.PtrToStringUTF8(pointer)
                    ?? throw new EnvelopeNativeException(
                        "Native call returned an invalid UTF-8 response.");
            }
            finally
            {
                NativeMethods.FreeString(pointer);
            }

            return DecodeResponse<T>(responseJson);
        }
        catch (EnvelopeNativeException)
        {
            throw;
        }
        catch (Exception error) when (
            error is DllNotFoundException or
                BadImageFormatException or
                EntryPointNotFoundException or
                TypeInitializationException)
        {
            throw new EnvelopeNativeException(
                "Unable to load envelope_ffi.dll. Build crates/envelope-ffi for Windows x64 " +
                "and place the DLL beside the application, or set ENVELOPE_FFI_PATH.",
                error);
        }
    }

    private static T DecodeResponse<T>(string responseJson)
    {
        try
        {
            using var document = JsonDocument.Parse(responseJson);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new EnvelopeNativeException(
                    "Native response must be a JSON object.");
            }

            var ok = root.TryGetProperty("ok", out var okValue) &&
                okValue.ValueKind is JsonValueKind.True;
            if (!ok)
            {
                var message = root.TryGetProperty("error", out var errorValue) &&
                    errorValue.ValueKind == JsonValueKind.String
                    ? errorValue.GetString()
                    : null;
                throw new EnvelopeNativeException(message ?? "Native call failed.");
            }

            if (!root.TryGetProperty("value", out var value) ||
                value.ValueKind == JsonValueKind.Null)
            {
                throw new EnvelopeNativeException(
                    "Native success response did not contain a value.");
            }

            return value.Deserialize<T>(JsonOptions)
                ?? throw new EnvelopeNativeException(
                    $"Native response could not be decoded as {typeof(T).Name}.");
        }
        catch (JsonException error)
        {
            throw new EnvelopeNativeException(
                "Native response was not valid Envelope JSON.",
                error);
        }
    }

    private sealed class Utf8String : IDisposable
    {
        private readonly int _byteLength;
        private readonly bool _sensitive;
        private IntPtr _pointer;

        public Utf8String(string value, bool sensitive = false)
        {
            ArgumentNullException.ThrowIfNull(value);
            if (value.IndexOf('\0') >= 0)
            {
                throw new ArgumentException(
                    "Native string arguments cannot contain NUL characters.",
                    nameof(value));
            }

            _byteLength = Encoding.UTF8.GetByteCount(value) + 1;
            _sensitive = sensitive;
            _pointer = Marshal.StringToCoTaskMemUTF8(value);
        }

        public IntPtr Pointer => _pointer != IntPtr.Zero
            ? _pointer
            : throw new ObjectDisposedException(nameof(Utf8String));

        public void Dispose()
        {
            var pointer = Interlocked.Exchange(ref _pointer, IntPtr.Zero);
            if (pointer == IntPtr.Zero)
            {
                return;
            }

            if (_sensitive)
            {
                for (var index = 0; index < _byteLength; index++)
                {
                    Marshal.WriteByte(pointer, index, 0);
                }
            }

            Marshal.FreeCoTaskMem(pointer);
        }
    }
}
