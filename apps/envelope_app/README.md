# Envelope App

Flutter client for Envelope / 信封.

Current roles:

```text
Android: current product MVP, using Rust C ABI, Android Keystore, SQLCipher, QR intro bundles, P2P, multi-entry Envelope Server route retry / mailbox, offline sealing, file preview / cache cleanup, release signing / update manifests, and group MVP flows.
Windows desktop: development verification shell that still calls envelope-cli and uses the local JSON store.
```

Common commands from the repository root:

```powershell
.\scripts\build-android-ffi.ps1
.\scripts\build-android-apk.ps1
.\scripts\build-android-apk.ps1 -Mode release
.\scripts\build-android-apk.ps1 -Mode release -EnableAdbBridge
```

Run from this directory when using Flutter directly:

```powershell
flutter run -d android
flutter run -d windows
flutter test
flutter analyze
```

The project-level status and product boundaries are documented in `../../README.md` and `../../docs/design.md`.
