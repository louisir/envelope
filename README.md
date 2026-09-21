# Envelope / 信封

Envelope 是一个面向 Android 和 Windows 的端到端加密通信项目。

Envelope is an end-to-end encrypted communication project for Android and Windows.

消息、文件和群组事件会被编码为 opaque 加密信封。客户端负责身份、加密、解密和本地状态；Envelope Server 负责路由、mailbox 兜底、intro 会话和节点发现，但不能解密消息内容。

Messages, files, and group events are encoded as opaque encrypted envelopes. The client owns identity, encryption, decryption, and local state. Envelope Server provides routing, mailbox fallback, intro sessions, and node discovery, but cannot decrypt message content.

当前状态：MVP / 持续开发中。仓库包含 Flutter / Android 客户端和 C# / WPF Windows 客户端；两端共用 Rust 协议与密码学核心。项目尚未经过独立安全审计。

Status: MVP / active development. The repository contains Flutter / Android and C# / WPF Windows clients backed by the same Rust protocol and cryptographic core. The project has not completed an independent security audit.

## 能力 / Features

- 一对一端到端加密文本和文件消息。 / One-to-one end-to-end encrypted text and file messages.
- Android Keystore 保护本地数据库密钥。 / Android Keystore protects the local database key.
- SQLCipher 本地聊天数据库。 / Local SQLCipher chat database.
- Windows DPAPI CurrentUser 保护随机主密钥，并用 AES-256-GCM 分槽加密本机状态。 / Windows DPAPI CurrentUser protects a random master key, and AES-256-GCM encrypts each local state slot.
- Windows 使用独立的六位应用解锁码，覆盖启动、应用级离开后恢复及敏感操作；手动锁定状态跨重启保留。 / Windows uses an independent six-digit app unlock code for startup, application-level resume, and sensitive actions; manual locking persists across restarts.
- Windows WPF 常驻托盘即时通信界面，支持消息、联系人、拆封、设置和关于，中英文切换；图标与浅色配色对齐 Android，Windows 另支持深色主题。 / Windows WPF tray messenger with Messages, Contacts, Open, Settings, and About, Chinese/English localization, and icons and light colors aligned with Android; Windows also supports a dark theme.
- 恢复词 + 本地备份文件的一次性恢复流程，可恢复身份、联系人、群组和本机设置。 / One-step recovery with recovery phrase plus local backup file, restoring identity, contacts, groups, and local settings.
- 本机身份自加密的本地备份，以及可配置的自动备份策略。 / Self-encrypted local backups and configurable auto-backup policy.
- Android / Windows 二维码互扫（Windows 可生成并读取图片）、签名 Contact / IntroBundle 文本交换、短期 intro-session 双向互加，以及保存前 fingerprint 人工确认。 / Android / Windows QR exchange (Windows generation and image decoding), signed Contact / IntroBundle text exchange, short-lived mutual intro sessions, and manual fingerprint confirmation before saving.
- 投递兜底链路：P2P direct -> server route retry -> server mailbox。 / Delivery fallback path: P2P direct -> server route retry -> server mailbox.
- 基于签名 `NodeSetManifest` 的多入口服务节点池。 / Multi-entry service node pool based on signed `NodeSetManifest`.
- route、mailbox、receipt 和 ACK tombstone 的服务端 best-effort 节点同步。 / Best-effort server-side node sync for routes, mailbox items, receipts, and ACK tombstones.
- HA v2 中继实现：etcd 仲裁、双 SQLite 业务副本、签名投递证明及两端客户端适配；完整产品验收仍在进行。 / HA v2 relay implementation with etcd quorum, two SQLite business replicas, signed delivery proofs, and adapters for both clients; full product acceptance is still in progress.
- 一对一及群组文本和文件离线密封；群组流为每位可投递成员分别加密。 / One-to-one and group offline sealing for text and files, with a separately encrypted group-stream copy per eligible recipient.
- 群组在线消息，按接收成员逐一加密 fan-out。 / Online group messages with per-recipient encrypted fan-out.
- 普通群、验证群和共识群，包含本机 fingerprint 信任、成员控制事件及群文件 fan-out。 / Normal, verified, and consensus groups with local fingerprint trust, membership control events, and group-file fan-out.
- Android 和 Windows 都在联网前持久化群成员控制事件的逐收件人密文，中断后以稳定 envelope id 重试。 / Android and Windows both durably stage per-recipient group membership-control ciphertext before networking and retry interrupted delivery with stable envelope ids.
- Android 和 Windows 都实施有界 mailbox 坏密文隔离和未来 epoch 因果延迟重试，避免队首坏项阻塞合法消息。 / Android and Windows both implement bounded mailbox poison quarantine and future-epoch causal deferral so a bad head item cannot block valid messages.
- Windows 聊天界面按页加载、Ctrl / Shift 多选和本机批量删除。 / Windows chat paging, Ctrl / Shift multi-select, and local bulk deletion.
- 客户端诊断日志和 replay 检测。 / Client diagnostic logs and replay detection.
- Android release APK 签名和 update manifest 生成。 / Android release APK signing and update manifest generation.
- YourTurn 交接：Windows 和 Android 接管 `envelope://yourturn/open`；Windows 注册当前用户的 `.envelope` 文件关联，Android 通过正式 MIME 接收 `.envelope` 文件。 / YourTurn handoff: Windows and Android handle `envelope://yourturn/open`; Windows registers a per-user `.envelope` association and Android receives `.envelope` files through the vendor MIME type.

## 密码学概览 / Cryptography Overview

以下内容描述当前协议 v1 的实际实现，不代表独立安全审计结论。协议实现以 [`envelope-core`](crates/envelope-core/src/lib.rs) 源码为准。

The following describes the current protocol v1 implementation and is not an independent security audit. The [`envelope-core`](crates/envelope-core/src/lib.rs) source is authoritative.

- 身份与认证：使用 Ed25519 身份签名密钥和 X25519 长期密钥协商密钥；联系人 `key_id` 取两把公钥带上下文 SHA-256 摘要的前 16 字节。 / Identity and authentication use an Ed25519 identity signing key and a long-term X25519 key-agreement key. A contact `key_id` is the first 16 bytes of a context-bound SHA-256 digest of both public keys.
- 消息与文件：每个 opaque envelope 生成新的临时 X25519 密钥，与接收者长期 X25519 公钥协商共享秘密，再通过 HKDF-SHA-256 派生 256 位密钥，并使用 XChaCha20-Poly1305 进行带认证加密；信封内部同时包含发送者的 Ed25519 签名。 / Each opaque message or file envelope generates a fresh ephemeral X25519 key, agrees a shared secret with the recipient's long-term X25519 public key, derives a 256-bit key with HKDF-SHA-256, and uses XChaCha20-Poly1305 authenticated encryption. The encrypted envelope body also carries the sender's Ed25519 signature.
- 身份恢复：由操作系统安全随机数生成 BIP39 英文 24 词恢复词；BIP39 seed 通过 HKDF-SHA-256 和不同用途的 context 分别派生签名、密钥协商及备份密钥。 / Identity recovery uses a 24-word English BIP39 phrase generated from operating-system secure randomness. The BIP39 seed is separated by HKDF-SHA-256 contexts into signing, key-agreement, and backup keys.
- 本地备份：备份密钥由恢复词派生，使用 XChaCha20-Poly1305、随机 24 字节 nonce 和固定 associated data 加密。 / Local backups derive their key from the recovery phrase and use XChaCha20-Poly1305 with a random 24-byte nonce and fixed associated data.
- Android 本地存储：聊天数据库使用 SQLCipher；身份记录和随机生成的 32 字节数据库口令由 Android Keystore 中的 AES 密钥保护。首选 AES-256-GCM，兼容回退路径包括 AES-128-GCM 和 AES-128-CBC-PKCS7；CBC 回退路径不是 AEAD 模式。 / Android local storage uses SQLCipher for chat data. Identity records and the randomly generated 32-byte database passphrase are protected by an AES key in Android Keystore. AES-256-GCM is preferred, with AES-128-GCM and AES-128-CBC-PKCS7 compatibility fallbacks; the CBC fallback is not an AEAD mode.
- 群消息不使用共享群密钥；当前实现对每个接收成员分别使用上述一对一 envelope 加密。 / Group messages do not use a shared group key; the current implementation encrypts a separate one-to-one envelope for each recipient.
- 基础设施元数据：节点清单和节点 challenge 使用 Ed25519 签名；Android update manifest 使用 RSA-PSS-SHA256 签名并包含 APK SHA-256。 / Infrastructure metadata uses Ed25519 signatures for node manifests and node challenges. Android update manifests use RSA-PSS-SHA256 and include the APK SHA-256 digest.

当前协议不是 Signal Protocol、Double Ratchet 或 MLS 的实现，也不宣称具备前向保密或入侵后安全性。每封信封虽然使用新的发送端临时 X25519 密钥，但接收端使用长期 X25519 密钥；该长期私钥泄露可能使攻击者解密此前截获的信封。项目仍处于 MVP 阶段，尚未经过独立安全审计。

The current protocol is not an implementation of Signal Protocol, Double Ratchet, or MLS, and it does not claim forward secrecy or post-compromise security. Although every envelope uses a fresh sender-side ephemeral X25519 key, the recipient uses a long-term X25519 key; compromise of that private key may allow previously captured envelopes to be decrypted. The project remains an unaudited MVP.

## 当前边界 / Current Boundaries

- 旧版 v1 mailbox 与节点同步仍为 best-effort，不是基于仲裁的跨节点强一致存储。 / Legacy v1 mailbox and node sync remain best-effort, not quorum-based strongly consistent replication.
- HA v2 与旧版 v1 分开部署；已完成部分隔离测试与公网进程故障验证，完整双端 UI、网络分区、容量和长期运行验收尚未完成，详见 [验证记录](docs/ha-v1.0.1-verification.md)。 / HA v2 is deployed separately from legacy v1. Selected isolated tests and public-server process-failure checks have passed; full dual-client UI, network-partition, capacity, and endurance acceptance remain open. See the [verification record](docs/ha-v1.0.1-verification.md).
- Android 与 Windows 客户端采用单 active messaging endpoint 模型；恢复到另一平台是显式迁移，不是多端同步。 / Android and Windows clients use a single-active-messaging-endpoint model; recovery onto another platform is an explicit migration, not multi-device sync.
- 群消息不是 MLS，也不使用共享群密钥。 / Group messaging is not MLS and does not use shared group keys.
- 群组离线密封会随成员数放大密文文件，不使用共享群密钥。 / Group offline sealing expands the ciphertext file with recipient count and does not use a shared group key.
- WebSocket relay、TURN、音视频和多设备同步尚未实现。 / WebSocket relay, TURN, audio/video, and multi-device sync are not implemented.

## 仓库结构 / Repository Layout

```text
apps/envelope_app        Flutter / Android client
apps/envelope_windows    C# / .NET 8 WPF Windows client
apps/envelope-server     Rust Envelope Server
apps/envelope-cli        development CLI
crates/envelope-core     identity, contacts, signatures, and envelope crypto
crates/envelope-ffi      Rust FFI used by the Android and Windows clients
crates/envelope-store    development local store
crates/envelope-net      P2P prototype layer
crates/envelope-server-core
                          server protocol and node manifest types
deploy/envelope-server   Linux deployment scripts
docs                     design document and Android / Windows user manuals
scripts                  build, release, and test scripts
```

## 快速开始 / Quick Start

### 下载与安装 / Download and Install

从 [GitHub Releases](https://github.com/louisir/envelope/releases/latest) 下载 Windows portable ZIP 或 Android release APK；每个平台的完整构建号和 SHA-256 以对应 Release 为准。

Download the Windows portable ZIP or Android release APK from [GitHub Releases](https://github.com/louisir/envelope/releases/latest). Each release lists the full build identifier and SHA-256 for each platform.

- Windows：下载自包含的 x64 ZIP，完整解压后运行 `Envelope.Windows.exe`，无需另外安装 .NET。关闭窗口会隐藏到系统托盘；左键托盘图标打开窗口，右键直接打开菜单，选择“退出”才结束程序。 / Windows: extract the entire self-contained x64 ZIP and run `Envelope.Windows.exe`; no separate .NET installation is needed. Closing the window hides it to the tray. Left-click the tray icon to open the window, right-click for its menu, and choose Quit to exit.
- Windows 首次初始化的六位解锁码为 `123456`；请在“设置 → 安全”中修改。手动锁定后，再打开主窗口会要求输入应用解锁码，不依赖 Windows Hello 或 Windows 账户密码。portable 指免安装，私有状态仍保存在 `%LOCALAPPDATA%\Envelope`，不会随 ZIP 迁移。 / The initial Windows six-digit unlock code is `123456`; change it in Settings → Security. After manual locking, reopening the main window requests this app code, without Windows Hello or a Windows account password. Portable means installation-free; private state remains in `%LOCALAPPDATA%\Envelope` and does not travel with the ZIP.
- Android：当前发布 APK 支持 ARM64、Android 7.0（API 24）及以上。包名为 `com.iamlouis.envelope`，可覆盖安装同包名、同签名的旧版；更早的 `com.westwardsoft.envelope` 是独立应用，数据不会自动迁移。 / Android: the current APK supports ARM64 devices running Android 7.0 (API 24) or later. Its package ID is `com.iamlouis.envelope`; it can update an existing app with the same ID and signature. The older `com.westwardsoft.envelope` package is a separate app, and its data is not migrated automatically.

### 源码构建 / Build from Source

运行 CLI 演示 / Run the CLI demo:

```powershell
cargo run -p envelope-cli -- demo --out-dir target/envelope-demo
```

运行 Rust 测试 / Run Rust tests:

```powershell
cargo test --workspace
```

本地启动 Envelope Server / Start Envelope Server locally:

```powershell
cargo run -p envelope-server -- --bind 127.0.0.1:19093 --database target/envelope-server/envelope-server.sqlite3
```

构建 Android FFI / Build Android FFI:

```powershell
.\scripts\build-android-ffi.ps1
```

构建 Android APK / Build Android APK:

```powershell
.\scripts\build-android-apk.ps1
```

构建 release APK / Build a release APK:

```powershell
.\scripts\build-android-apk.ps1 -Mode release
```

校验 Android / Windows 共享契约并用同一版本号构建两端发布包 / Verify the shared Android / Windows contracts and build both packages with one version:

```powershell
.\scripts\verify-client-parity.ps1
.\scripts\build-client-pair.ps1 -AppVersion v1.0.1.202609210001 -BuildName 1.0.1
```

构建带 ADB bridge 的测试 release APK / Build a test release APK with ADB bridge:

```powershell
.\scripts\build-android-apk.ps1 -Mode release -EnableAdbBridge
```

正式 GitHub Release 发布包不启用 ADB bridge；USB 测试和自动化验证包可以启用。

Official GitHub Release packages do not enable ADB bridge; USB test and automation verification builds may enable it.

构建 Windows WPF 客户端与发布包 / Build the Windows WPF client and package:

```powershell
.\scripts\build-windows-wpf.ps1
```

该脚本构建同仓库的 `envelope_ffi.dll`、编译并验证 .NET solution，然后在 `target\portable` 生成 Windows x64 包和可执行文件 SHA-256。开发说明见 [apps/envelope_windows/README.md](apps/envelope_windows/README.md)。

The script builds the repository's `envelope_ffi.dll`, compiles and verifies the .NET solution, and then creates the Windows x64 package and executable SHA-256 under `target\portable`. See [apps/envelope_windows/README.md](apps/envelope_windows/README.md) for development details.

客户端发布包包含 HA 中继引导配置。自建或切换服务时，在设置页的“消息同步 / 中继矩阵入口”中填写对应的服务域名或 IP，并按 HA 部署说明配置客户端信任信息。

Client release packages include HA relay bootstrap configuration. For a self-hosted or alternative service, set its domain or IP in Settings -> Message Sync / Relay Matrix Entry and configure client trust as described in the HA deployment guide.

恢复新设备时，在“设置 / 我的身份”输入 BIP39 24 词恢复词，然后点击“用恢复词从本地备份恢复”并选择本地备份文件。新备份位于 `Download/Envelope/backups`，由本机身份自加密；自动备份可在设置页配置间隔和保留数量。

To restore a new device, enter the BIP39 24-word recovery phrase in Settings -> My Identity, then tap Restore from phrase and local backup and choose the backup file. New backups are stored under `Download/Envelope/backups` and self-encrypted with the local identity; the auto-backup interval and retention count are configurable in Settings.

运行 Android 检查 / Run Android checks:

```powershell
cd apps/envelope_app
flutter analyze
flutter test
```

## 服务端部署 / Server Deployment

Envelope Server 是 Rust + Axum 服务。Linux 部署脚本位于 [deploy/envelope-server](deploy/envelope-server)。

Envelope Server is a Rust + Axum service. Linux deployment scripts are in [deploy/envelope-server](deploy/envelope-server).

主要服务端功能 / Main server features:

- 设备 route 注册和查询。 / Device route registration and lookup.
- mailbox 提交、拉取和 ACK。 / Mailbox submit, pull, and ACK.
- delivery receipt 状态查询。 / Delivery receipt status lookup.
- intro session 交换。 / Intro session exchange.
- 签名节点清单和节点 challenge。 / Signed node manifests and node challenges.
- best-effort 节点同步。 / Best-effort node sync.
- 基础滥用防护限制。 / Basic abuse-protection limits.

HA v2 使用独立的 `envelope-server-ha` 入口；部署前请阅读 [HA 部署说明](deploy/envelope-server/ha/README.md)、[恢复操作手册](deploy/envelope-server/ha/recovery.md)与[验收边界](docs/ha-v1.0.1-verification.md)。从源码构建 HA 服务端还需要 Protocol Buffers 编译器 `protoc`，可通过 `PROTOC` 环境变量指定路径。

HA v2 uses the separate `envelope-server-ha` entry point. Before deployment, read the [HA deployment guide](deploy/envelope-server/ha/README.md), [recovery runbook](deploy/envelope-server/ha/recovery.md), and [acceptance boundaries](docs/ha-v1.0.1-verification.md). Building the HA server also requires the Protocol Buffers compiler `protoc`; set `PROTOC` to its path if needed.

## 文档 / Documentation

- [设计文档 / Design Document](docs/design.md)
- [主备实现设计 HA-D1 / HA-D1 Implementation Design](docs/design.md#16-首版主备实现设计--first-release-ha-implementation-design)
- [VPS 主备中继协议 / VPS HA Relay Protocol](docs/relay-ha-protocol.md)
- [主备专项验收标准 / HA Acceptance Criteria](docs/relay-ha-acceptance.md)
- [v1.0.1 HA 验证记录与未完成项 / HA Verification and Open Acceptance Items](docs/ha-v1.0.1-verification.md)
- [VPS 多来源发现与客户端选点（后续方向）/ Future VPS Discovery and Selection](docs/vps-discovery-and-selection.md)
- [Android 用户手册 / Android User Manual](docs/android-user-manual.html)
- [Windows 用户手册 / Windows User Manual](docs/windows-user-manual.html)
- [Android / Windows 产品验收计划 / Product Acceptance Plan](docs/acceptance-plan.md)
- [产品验收清单 / Acceptance Checklist](docs/acceptance-checklist.md)
- [验收执行与签署模板 / Acceptance Run Template](docs/acceptance-run-template.md)
- [集群验证与验收执行分工 / Cluster Verification and Acceptance Guide](docs/acceptance-execution-guide.md)

## 授权 / License

Envelope 使用 GNU Affero General Public License v3.0 or later 授权。

Envelope is licensed under GNU Affero General Public License v3.0 or later.

SPDX: `AGPL-3.0-or-later`
