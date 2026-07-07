# Envelope / 信封

Envelope 是一个以 Android 为主的端到端加密通信项目。

消息、文件和群组事件会被编码为 opaque 加密信封。客户端负责身份、加密、解密和本地状态；Envelope Server 负责路由、mailbox 兜底、intro 会话和节点发现，但不能解密消息内容。

当前状态：MVP / 持续开发中。Android 客户端是当前主要产品形态。项目尚未经过独立安全审计。

## 能力

- 一对一端到端加密文本和文件消息。
- Android Keystore 保护本地数据库密钥。
- SQLCipher 本地聊天数据库。
- 二维码联系人交换和 fingerprint 确认。
- 投递兜底链路：P2P direct -> server route retry -> server mailbox。
- 基于签名 `NodeSetManifest` 的多入口服务节点池。
- route、mailbox、receipt 和 ACK tombstone 的服务端 best-effort 节点同步。
- 一对一文本和文件离线密封。
- 群组在线消息，按接收成员逐一加密 fan-out。
- 客户端诊断日志和 replay 检测。
- Android release APK 签名和 update manifest 生成。

## 当前边界

- mailbox 层不是跨节点强一致多副本存储。
- 节点同步是 best-effort，不是基于仲裁的多副本强一致存储。
- Android 客户端当前采用单 active messaging device 模型。
- 群消息不是 MLS，也不使用共享群密钥。
- 离线密封仅支持一对一投递。
- WebSocket relay、TURN、音视频和多设备同步尚未实现。

## 仓库结构

```text
apps/envelope_app        Flutter / Android 客户端
apps/envelope-server     Rust Envelope Server
apps/envelope-cli        开发调试 CLI
crates/envelope-core     身份、联系人、签名和信封加密核心
crates/envelope-ffi      Android 客户端使用的 Rust FFI
crates/envelope-store    开发版本地 store
crates/envelope-net      P2P 原型层
crates/envelope-server-core
                          服务端协议和节点清单类型
deploy/envelope-server   Linux 部署脚本
docs                     设计文档和 Android 用户手册
scripts                  构建、发布和测试脚本
```

## 快速开始

运行 CLI 演示：

```powershell
cargo run -p envelope-cli -- demo --out-dir target/envelope-demo
```

运行 Rust 测试：

```powershell
cargo test
```

本地启动 Envelope Server：

```powershell
cargo run -p envelope-server -- --bind 127.0.0.1:19093 --database target/envelope-server/envelope-server.sqlite3
```

构建 Android FFI：

```powershell
.\scripts\build-android-ffi.ps1
```

构建 Android APK：

```powershell
.\scripts\build-android-apk.ps1
```

构建 release APK：

```powershell
.\scripts\build-android-apk.ps1 -Mode release
```

Android 客户端首次使用前，在设置页的“消息同步 / 中继矩阵入口”中填写同步服务域名或 IP。

运行 Android 检查：

```powershell
cd apps/envelope_app
flutter analyze
flutter test
```

## 服务端部署

Envelope Server 是 Rust + Axum 服务。Linux 部署脚本位于 [deploy/envelope-server](deploy/envelope-server)。

主要服务端功能：

- 设备 route 注册和查询。
- mailbox 提交、拉取和 ACK。
- delivery receipt 状态查询。
- intro session 交换。
- 签名节点清单和节点 challenge。
- best-effort 节点同步。
- 基础反滥用限制。

## 文档

- [设计文档](docs/design.md)
- [Android 用户手册](docs/android-user-manual.html)

## 授权

Envelope 使用 GNU Affero General Public License v3.0 or later 授权。

SPDX: `AGPL-3.0-or-later`
