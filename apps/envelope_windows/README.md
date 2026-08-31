# Envelope Windows / WPF

`Envelope.Windows` is the Windows product client for the Envelope protocol. It uses
C#/.NET 8 WPF for the desktop UI and calls the same Rust `envelope-ffi` C ABI as the
Android client, so identity, Contact, IntroBundle, opaque-envelope, backup, and
server-signature formats remain interoperable.

The WPF client generates Android-compatible contact QR codes, decodes QR images,
and reads or writes `ENVELOPE_GROUP_STREAM_V1` group offline text/file streams
with one opaque ciphertext per eligible recipient.

## Projects

```text
Envelope.Windows          WPF application, MVVM pages and Windows integration
Envelope.Windows.Core     protocol, native FFI, encrypted state, networking and domain services
Envelope.Windows.Tests    console verification executable (protocol, storage, QR, UI-boundary tests)
```

The application keeps private state under `%LOCALAPPDATA%\Envelope`. A random
256-bit master key is protected for the current Windows account with DPAPI; each
state slot is separately encrypted with AES-256-GCM and authenticated with its slot
name. User-visible received, sealed, backup, and diagnostic exports live under
`%USERPROFILE%\Downloads\Envelope`.

## Build

From the repository root:

```powershell
.\scripts\build-windows-wpf.ps1
```

The script builds `envelope_ffi.dll`, restores and builds the .NET solution, runs
the verification executable, publishes the WPF app, copies the native DLL, writes
an executable SHA-256 file, and creates:

```text
target\portable\Envelope-Windows-win-x64.zip
```

The default package is framework-dependent and requires the .NET 8 Windows
Desktop Runtime on the destination PC. Where NuGet runtime packs are available,
use `-SelfContained` to create a package that includes the .NET runtime:

```powershell
.\scripts\build-windows-wpf.ps1 -SelfContained
```

For an ordinary development build:

```powershell
cargo build -p envelope-ffi
dotnet build .\apps\envelope_windows\Envelope.Windows.sln
```

Copy `target\debug\envelope_ffi.dll` beside `Envelope.Windows.exe` before launching
outside the repository build script.

## Security boundary

- Rust owns identity derivation, signatures, contact validation, opaque-envelope
  encryption/decryption, and signed server requests.
- C# owns Windows account protection, local encrypted state, WPF interaction,
  mailbox/P2P orchestration, files, and diagnostics.
- Diagnostics must never contain message plaintext, file contents, private identity
  JSON, the recovery phrase, or the local master key.
- One Envelope identity remains a single active messaging endpoint. Restoring it on
  Windows is an explicit endpoint migration, not multi-device synchronization.
