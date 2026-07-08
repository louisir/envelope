# Envelope App / 信封 App

Envelope / 信封的 Flutter 客户端。

Flutter client for Envelope.

当前角色 / Current roles:

```text
Android: current product MVP, using Rust C ABI, Android Keystore, SQLCipher,
QR intro bundles, P2P, multi-entry Envelope Server route retry / mailbox,
offline sealing, file preview / cache cleanup, local backup and recovery,
auto backup settings, release signing / update manifests, and group MVP flows.

Windows desktop: development verification shell that still calls envelope-cli
and uses the local JSON store.
```

常用命令从仓库根目录运行 / Common commands from the repository root:

```powershell
.\scripts\build-android-ffi.ps1
.\scripts\build-android-apk.ps1
.\scripts\build-android-apk.ps1 -Mode release
.\scripts\build-android-apk.ps1 -Mode release -EnableAdbBridge
```

正式发布包使用 `-Mode release`，不要启用 ADB bridge；测试机自动化和 USB 调试包可以加 `-EnableAdbBridge`。

Official release packages use `-Mode release` without ADB bridge. Test-device automation and USB debugging builds may add `-EnableAdbBridge`.

直接使用 Flutter 时从本目录运行 / Run from this directory when using Flutter directly:

```powershell
flutter run -d android
flutter run -d windows
flutter test
flutter analyze
```

Android 恢复流程围绕“恢复词 + 本地备份文件”一次完成；本地备份文件保存在 `Download/Envelope/backups`，新备份由本机身份自加密，自动备份策略可在设置页配置。

Android recovery is centered on a single recovery phrase plus local backup file flow. Local backup files are stored under `Download/Envelope/backups`; new backups are self-encrypted with the local identity, and auto-backup policy is configurable in Settings.

项目级状态和产品边界见 `../../README.md` 和 `../../docs/design.md`。

The project-level status and product boundaries are documented in `../../README.md` and `../../docs/design.md`.
