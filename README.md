# Envelope / 信封

Envelope 是一个以 Android 为主的端到端加密通信项目。

Envelope is an Android-first end-to-end encrypted communication project.

消息、文件和群组事件会被编码为 opaque 加密信封。客户端负责身份、加密、解密和本地状态；Envelope Server 负责路由、mailbox 兜底、intro 会话和节点发现，但不能解密消息内容。

Messages, files, and group events are encoded as opaque encrypted envelopes. The client owns identity, encryption, decryption, and local state. Envelope Server provides routing, mailbox fallback, intro sessions, and node discovery, but cannot decrypt message content.

当前状态：MVP / 持续开发中。Android 客户端是当前主要产品形态。项目尚未经过独立安全审计。

Status: MVP / active development. The Android client is the primary product surface. The project has not completed an independent security audit.

## 能力 / Features

- 一对一端到端加密文本和文件消息。 / One-to-one end-to-end encrypted text and file messages.
- Android Keystore 保护本地数据库密钥。 / Android Keystore protects the local database key.
- SQLCipher 本地聊天数据库。 / Local SQLCipher chat database.
- 二维码联系人交换和 fingerprint 确认。 / QR contact exchange with fingerprint confirmation.
- 投递兜底链路：P2P direct -> server route retry -> server mailbox。 / Delivery fallback path: P2P direct -> server route retry -> server mailbox.
- 基于签名 `NodeSetManifest` 的多入口服务节点池。 / Multi-entry service node pool based on signed `NodeSetManifest`.
- route、mailbox、receipt 和 ACK tombstone 的服务端 best-effort 节点同步。 / Best-effort server-side node sync for routes, mailbox items, receipts, and ACK tombstones.
- 一对一文本和文件离线密封。 / One-to-one offline sealing for text and files.
- 群组在线消息，按接收成员逐一加密 fan-out。 / Online group messages with per-recipient encrypted fan-out.
- 客户端诊断日志和 replay 检测。 / Client diagnostic logs and replay detection.
- Android release APK 签名和 update manifest 生成。 / Android release APK signing and update manifest generation.

## 当前边界 / Current Boundaries

- mailbox 层不是跨节点强一致多副本存储。 / The mailbox layer is not strongly consistent replicated storage across nodes.
- 节点同步是 best-effort，不是基于仲裁的多副本强一致存储。 / Node sync is best-effort, not quorum-based strongly consistent replication.
- Android 客户端当前采用单 active messaging device 模型。 / The Android client currently uses a single active messaging device model.
- 群消息不是 MLS，也不使用共享群密钥。 / Group messaging is not MLS and does not use shared group keys.
- 离线密封仅支持一对一投递。 / Offline sealing currently supports one-to-one delivery only.
- WebSocket relay、TURN、音视频和多设备同步尚未实现。 / WebSocket relay, TURN, audio/video, and multi-device sync are not implemented.

## 仓库结构 / Repository Layout

```text
apps/envelope_app        Flutter / Android client
apps/envelope-server     Rust Envelope Server
apps/envelope-cli        development CLI
crates/envelope-core     identity, contacts, signatures, and envelope crypto
crates/envelope-ffi      Rust FFI used by the Android client
crates/envelope-store    development local store
crates/envelope-net      P2P prototype layer
crates/envelope-server-core
                          server protocol and node manifest types
deploy/envelope-server   Linux deployment scripts
docs                     design document and Android user manual
scripts                  build, release, and test scripts
```

## 快速开始 / Quick Start

运行 CLI 演示 / Run the CLI demo:

```powershell
cargo run -p envelope-cli -- demo --out-dir target/envelope-demo
```

运行 Rust 测试 / Run Rust tests:

```powershell
cargo test
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

Android 客户端首次使用前，在设置页的“消息同步 / 中继矩阵入口”中填写同步服务域名或 IP。

Before first use, configure the sync service domain or IP in the Android client's Settings -> Message Sync / Relay Matrix Entry.

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

## 文档 / Documentation

- [设计文档 / Design Document](docs/design.md)
- [Android 用户手册 / Android User Manual](docs/android-user-manual.html)

## 授权 / License

Envelope 使用 GNU Affero General Public License v3.0 or later 授权。

Envelope is licensed under GNU Affero General Public License v3.0 or later.

SPDX: `AGPL-3.0-or-later`
