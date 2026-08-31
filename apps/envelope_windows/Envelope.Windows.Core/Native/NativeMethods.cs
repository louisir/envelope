using System.Reflection;
using System.Runtime.InteropServices;

namespace Envelope.Windows.Core.Native;

internal static class NativeMethods
{
    internal const string LibraryName = "envelope_ffi";

    private static readonly object ConfigurationLock = new();
    private static string? _preferredLibraryPath;

    static NativeMethods()
    {
        NativeLibrary.SetDllImportResolver(
            typeof(NativeMethods).Assembly,
            ResolveLibrary);
    }

    internal static void ConfigureLibraryPath(string? libraryPath)
    {
        if (string.IsNullOrWhiteSpace(libraryPath))
        {
            return;
        }

        var fullPath = Path.GetFullPath(libraryPath);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException(
                "Envelope native library was not found.",
                fullPath);
        }

        lock (ConfigurationLock)
        {
            if (_preferredLibraryPath is not null &&
                !string.Equals(
                    _preferredLibraryPath,
                    fullPath,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "The Envelope native library path was already configured.");
            }

            _preferredLibraryPath = fullPath;
        }
    }

    private static IntPtr ResolveLibrary(
        string libraryName,
        Assembly assembly,
        DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, LibraryName, StringComparison.Ordinal))
        {
            return IntPtr.Zero;
        }

        foreach (var candidate in CandidatePaths())
        {
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
            {
                return handle;
            }
        }

        return IntPtr.Zero;
    }

    private static IEnumerable<string> CandidatePaths()
    {
        string? preferred;
        lock (ConfigurationLock)
        {
            preferred = _preferredLibraryPath;
        }

        if (!string.IsNullOrWhiteSpace(preferred))
        {
            yield return preferred;
        }

        var environmentPath = Environment.GetEnvironmentVariable("ENVELOPE_FFI_PATH");
        if (!string.IsNullOrWhiteSpace(environmentPath))
        {
            yield return Path.GetFullPath(environmentPath);
        }

        const string fileName = "envelope_ffi.dll";
        var baseDirectory = AppContext.BaseDirectory;
        yield return Path.Combine(baseDirectory, fileName);
        yield return Path.Combine(baseDirectory, "bin", fileName);

        var currentDirectory = Environment.CurrentDirectory;
        yield return Path.Combine(currentDirectory, fileName);
        yield return Path.Combine(currentDirectory, "bin", fileName);
        yield return Path.Combine(currentDirectory, "target", "release", fileName);
        yield return Path.Combine(currentDirectory, "target", "debug", fileName);

        var directory = new DirectoryInfo(currentDirectory);
        for (var depth = 0; depth < 5 && directory is not null; depth++, directory = directory.Parent)
        {
            yield return Path.Combine(directory.FullName, "target", "release", fileName);
            yield return Path.Combine(directory.FullName, "target", "debug", fileName);
        }
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_free_string")]
    internal static extern void FreeString(IntPtr value);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_protocol_info")]
    internal static extern IntPtr ProtocolInfo();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_generate_recovery_phrase")]
    internal static extern IntPtr GenerateRecoveryPhrase();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_recover_identity")]
    internal static extern IntPtr RecoverIdentity(IntPtr displayName, IntPtr recoveryPhrase);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_encrypt_local_backup")]
    internal static extern IntPtr EncryptLocalBackup(IntPtr recoveryPhrase, IntPtr plaintextJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_decrypt_local_backup")]
    internal static extern IntPtr DecryptLocalBackup(IntPtr recoveryPhrase, IntPtr backupJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_contact_from_identity")]
    internal static extern IntPtr ContactFromIdentity(IntPtr identityJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_parse_contact")]
    internal static extern IntPtr ParseContact(IntPtr contactJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_intro_bundle")]
    internal static extern IntPtr CreateIntroBundle(
        IntPtr identityJson,
        IntPtr deviceId,
        IntPtr p2pTicket,
        ulong ttlSeconds);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_verify_intro_bundle")]
    internal static extern IntPtr VerifyIntroBundle(IntPtr bundleJson);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_sign_context_payload")]
    internal static extern IntPtr SignContextPayload(
        IntPtr identityJson,
        IntPtr context,
        IntPtr payload);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_verify_contact_signature")]
    internal static extern IntPtr VerifyContactSignature(
        IntPtr contactJson,
        IntPtr context,
        IntPtr payload,
        IntPtr signature);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_verify_node_set_manifest")]
    internal static extern IntPtr VerifyNodeSetManifest(
        IntPtr manifestJson,
        IntPtr manifestSigningPublic,
        ulong nowUnixMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_verify_node_challenge")]
    internal static extern IntPtr VerifyNodeChallenge(
        IntPtr requestJson,
        IntPtr responseJson,
        IntPtr nodePublicKey,
        ulong nowUnixMs,
        ulong maxClockSkewMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_encrypt_opaque_text")]
    internal static extern IntPtr EncryptOpaqueText(
        IntPtr identityJson,
        IntPtr recipientContactJson,
        IntPtr text,
        ulong messageCounter);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_encrypt_opaque_file")]
    internal static extern IntPtr EncryptOpaqueFile(
        IntPtr identityJson,
        IntPtr recipientContactJson,
        IntPtr filename,
        IntPtr mime,
        IntPtr payloadBytes,
        nuint payloadLength,
        ulong messageCounter);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_decrypt_opaque_text")]
    internal static extern IntPtr DecryptOpaqueText(
        IntPtr identityJson,
        IntPtr senderContactJson,
        IntPtr envelopeBase64);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_decrypt_opaque_payload")]
    internal static extern IntPtr DecryptOpaquePayload(
        IntPtr identityJson,
        IntPtr senderContactJson,
        IntPtr envelopeBase64);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_device_endpoint_update")]
    internal static extern IntPtr CreateDeviceEndpointUpdate(
        IntPtr identityJson,
        IntPtr deviceId,
        IntPtr p2pTicket,
        IntPtr sessionId,
        ulong deviceListVersion,
        ulong ttlSeconds);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_mailbox_pull_request")]
    internal static extern IntPtr CreateMailboxPullRequest(
        IntPtr identityJson,
        uint limit,
        ulong requestedAtUnixMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_envelope_submit_request")]
    internal static extern IntPtr CreateEnvelopeSubmitRequest(
        IntPtr identityJson,
        IntPtr recipientKeyId,
        IntPtr envelopeId,
        IntPtr envelopeBase64,
        ulong ttlSeconds,
        ulong submittedAtUnixMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_mailbox_ack_request")]
    internal static extern IntPtr CreateMailboxAckRequest(
        IntPtr identityJson,
        IntPtr envelopeIdsJson,
        ulong ackedAtUnixMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true, EntryPoint = "envelope_ffi_create_delivery_status_request")]
    internal static extern IntPtr CreateDeliveryStatusRequest(
        IntPtr identityJson,
        IntPtr envelopeIdsJson,
        ulong requestedAtUnixMs);
}
