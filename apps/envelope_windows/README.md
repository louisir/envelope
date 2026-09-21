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

On startup, the app registers the current user as the handler for
`envelope://` and `.envelope` files (`application/vnd.westwardsoft.envelope`).
`envelope://yourturn/open` activates the existing app instance and opens the
Unseal page. Opening a `.envelope` file imports that exact file; when no local
identity exists yet, the path remains pending until identity creation or
recovery completes.

## Build

### Desktop messenger shell

The window opens on Messages with a 68 px navigation rail, a 280 px conversation
list, and a persistent composer. Light mode uses Android's orange/cream palette
and gray-green outgoing bubbles. The application icon embeds the original Android
launcher PNGs; `scripts/sync-windows-brand-assets.ps1` regenerates the PNG/ICO assets.

Closing the window hides it to the Windows notification area while background
sync continues. The tray menu provides Open, temporary Do not disturb, Lock,
Settings, and Quit. Notifications show only unread counts. Reading requires the
selected chat to be visible and active; hidden windows and other pages preserve
unread messages. Manual Lock requires the app's six-digit unlock code when reopened.
Quit stops background reception. Windows notification settings can suppress popups.

`Envelope.Windows.UiTests` checks these UI boundaries and renders all pages using
isolated example data; this does not exercise real peer delivery. Local unlock uses
the app's six-digit code (initially `123456`), configurable in Settings → Security.
The bundled `windows-user-manual.html` provides matching Simplified Chinese and
English instructions, including platform-specific locking, tray behavior, and HA delivery states.
For isolated process smoke tests, use `ENVELOPE_LOCAL_APPDATA_ROOT`,
`ENVELOPE_PROFILE_ROOT`, and `ENVELOPE_SKIP_SHELL_REGISTRATION=1` to avoid changing
the user's state or file associations. These variables are not required normally.

Use `-SelfContained -PackageSuffix <version>` to produce a versioned ZIP without
replacing the previous portable package. Extract the entire ZIP before starting
`Envelope.Windows.exe`; keep the DLLs and runtime files beside it.

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

`build-windows-wpf.ps1` accepts the same `-AppVersion` and `-BuildName`
arguments as the Android build. To guard the shared FFI and wire constants and
produce both packages with exactly one version value, run:

```powershell
.\scripts\verify-client-parity.ps1
.\scripts\build-client-pair.ps1 -AppVersion v1.0.1.202609210001 -BuildName 1.0.1
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
