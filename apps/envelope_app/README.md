# Envelope App / 信封 App

Envelope / 信封的 Flutter 客户端。

Flutter client for Envelope.

当前角色 / Current roles:

```text
Android: current product client, using Rust C ABI, Android Keystore, SQLCipher,
QR intro bundles, P2P, multi-entry Envelope Server route retry / mailbox,
offline sealing, file preview / cache cleanup, local backup and recovery,
auto backup settings, release signing / update manifests, group flows, durable
fan-out outbox (including membership control events), persistent unread state,
and bounded mailbox poison quarantine / causal deferral.

Windows desktop: current WPF product client using the same Rust C ABI and wire
formats, with DPAPI-protected identity slots, encrypted state, P2P / mailbox,
offline sealing, group flows, durable fan-out outbox, and persistent unread
state. It does not proxy cryptography through envelope-cli.
```

Android mailbox reliability follows the Windows client policy: unknown senders
and deterministic authentication / payload failures are retained only as
bounded audit metadata and ACKed, while authenticated future-epoch group events
are durably retained in SQLCipher and retried after causal predecessors arrive.
The deferred raw queue is limited to 256 envelopes, 12 MiB per envelope,
64 MiB total, and seven days. Group membership-control fan-out uses stable
`group-event:<event_id>` logical IDs and stages the group mutation, event, and
all recipient ciphertext children in one transaction before network delivery.
Incoming group state, membership, event messages, and replay counters also
commit atomically; a failed database write leaves the event safe to retry.
Control recipients include pending / accepted invitees as well as active
members, so they do not miss the intervening epochs needed by causal retry.

`test/android_db_reliability_integration_test.dart` exercises the actual schema
and transactions with SQLite FFI: v11 / v13 migrations, injected write failures,
partial fan-out restart, replay rejection, deferred recovery, and queue pruning.
These host-side tests do not replace Android SQLCipher / device interruption
acceptance tests.

常用命令从仓库根目录运行 / Common commands from the repository root:

```powershell
.\scripts\build-android-ffi.ps1
.\scripts\build-android-apk.ps1
.\scripts\build-android-apk.ps1 -Mode release
.\scripts\build-android-apk.ps1 -Mode release -EnableAdbBridge
.\scripts\verify-client-parity.ps1
.\scripts\build-client-pair.ps1 -AppVersion v1.0.1.202609210001 -BuildName 1.0.1
```

正式发布包使用 `-Mode release`，不要启用 ADB bridge；测试机自动化和 USB 调试包可以加 `-EnableAdbBridge`。

Official release packages use `-Mode release` without ADB bridge. Test-device automation and USB debugging builds may add `-EnableAdbBridge`.

直接使用 Flutter 时从本目录运行 / Run from this directory when using Flutter directly:

```powershell
flutter run -d android
flutter test
flutter analyze
```

Windows 产品客户端是相邻目录中的 WPF 应用，应从仓库根目录使用
`.\scripts\build-windows-wpf.ps1` 构建；本 Flutter 工程的桌面分支仅保留为开发兼容代码，不代表 Windows 发布版。

The Windows product client is the WPF application in the sibling directory and
is built from the repository root with `.\scripts\build-windows-wpf.ps1`. The
desktop branch in this Flutter project remains development compatibility code,
not the Windows release client.

Android 恢复流程围绕“恢复词 + 本地备份文件”一次完成；本地备份文件保存在 `Download/Envelope/backups`，新备份由本机身份自加密，自动备份策略可在设置页配置。

Android recovery is centered on a single recovery phrase plus local backup file flow. Local backup files are stored under `Download/Envelope/backups`; new backups are self-encrypted with the local identity, and auto-backup policy is configurable in Settings.

Android 声明 `envelope://yourturn/open` 深链，并以 `application/vnd.westwardsoft.envelope`（兼容 `application/envelope`）接收系统文件 Intent。深链会打开“拆封”页；从文件管理器打开 `.envelope` 时会直接导入该 URI。尚未建立身份时，导入请求会保留到创建或恢复身份完成后再处理。

Android declares the `envelope://yourturn/open` deep link and accepts system file intents with `application/vnd.westwardsoft.envelope` (plus the legacy `application/envelope`). The deep link opens the Open tab; opening an `.envelope` file from a file manager imports that URI. If no identity exists yet, the import remains pending until identity creation or recovery finishes.

项目级状态和产品边界见 `../../README.md` 和 `../../docs/design.md`。

The project-level status and product boundaries are documented in `../../README.md` and `../../docs/design.md`.
