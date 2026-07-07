# Envelope 当前设计文档 / Current Design Document

本文是 Envelope 仓库的单一设计基线，对齐当前 Android 客户端、Rust core / FFI、Envelope Server 和部署脚本的实现状态。历史阶段文档已合并到本文，不再作为独立维护对象。

This document is the single design baseline for the Envelope repository. It reflects the current Android client, Rust core / FFI, Envelope Server, and deployment scripts. Historical phase documents have been merged here and are no longer maintained separately.

最后更新 / Last updated: 2026-07-07

## 1. 产品定位 / Product Scope

Envelope 是一个以 Android 为主的端到端加密通信项目。消息、文件和群组控制事件都被编码为 opaque 加密信封。客户端负责身份、联系人、加密、解密、本地数据库和用户确认；Envelope Server 只负责路由、mailbox 兜底、intro session、送达回执、节点清单和节点间 best-effort 同步。

Envelope is an Android-first end-to-end encrypted communication project. Messages, files, and group control events are encoded as opaque encrypted envelopes. The client owns identity, contacts, encryption, decryption, the local database, and user confirmation. Envelope Server only provides routing, mailbox fallback, intro sessions, delivery receipts, node manifests, and best-effort node sync.

服务器和外部工具或渠道不能解密消息内容。服务端不解析信封内部的明文元数据，也不应成为联系人信任或群成员身份确认的来源。

Servers and external tools or channels cannot decrypt message content. The server does not parse plaintext metadata inside envelopes and must not be the source of contact trust or group-member identity confirmation.

当前主产品形态是 Android 客户端。桌面端仍是开发验证 shell，不作为当前用户主线。

The Android client is the primary product surface. The desktop app remains a development verification shell and is not the current user-facing path.

## 2. 当前功能边界 / Current Functional Boundaries

### 已实现 / Implemented

- Android 五个主入口：关于、联系人、聊天、拆封、设置。 / Five Android entry points: About, Contacts, Chat, Open, and Settings.
- Android Keystore 保护 SQLCipher 数据库口令，本机身份存放于加密数据库。 / Android Keystore protects the SQLCipher database passphrase; the local identity is stored in the encrypted database.
- BIP39 24 词身份创建和身份恢复。 / BIP39 24-word identity creation and recovery.
- 本地锁屏：打开 App 和高风险操作可使用系统 PIN、密码或生物识别确认。 / Local lock: opening the app and sensitive actions can require system PIN, password, or biometrics.
- 本地备份：用 24 词加密导出显示名、身份 key id、同步服务入口、联系人、群组和群成员。 / Local backup: the 24-word phrase encrypts display name, identity key id, sync service entry, contacts, groups, and group members.
- 二维码联系人交换、剪贴板 contact 导入和 fingerprint 人工确认。 / QR contact exchange, clipboard contact import, and manual fingerprint confirmation.
- 联系人备注、联系人删除和端到端加密 contact-control 删除通知。 / Contact notes, contact deletion, and end-to-end encrypted contact-control deletion notices.
- 点对点文本和文件发送。 / One-to-one text and file sending.
- 图片、视频文件预览；文件点击优先调用系统默认应用打开，失败时退回保存路径。 / Image and video previews; file taps prefer the system default app and fall back to the saved location.
- 聊天记录分页、消息多选和本机删除。 / Chat history paging, multi-select, and local deletion.
- 64 MiB 内在线文件发送，客户端分片、哈希校验和逐信封加密。 / Online file sending up to 64 MiB, with client chunking, hash verification, and per-envelope encryption.
- 点对点离线密封和拆封，支持文本和本地文件。 / One-to-one offline sealing and opening for text and local files.
- 普通群、验证群、共识群。 / Normal groups, verified groups, and consensus groups.
- 群邀请以邀请者单聊消息呈现，受邀者可接受或拒绝。 / Group invitations appear in the inviter's one-to-one chat; invitees can accept or decline.
- 建群最少 3 人：群主加至少 2 名受邀者。 / Group creation requires at least 3 people: the owner plus at least 2 invitees.
- 群主改群名、更新群头像 seed、邀请成员、移除成员。 / Group owner actions: rename, update avatar seed, invite members, and remove members.
- 群成员状态：pending、accepted、active、left、removed。 / Group member states: pending, accepted, active, left, and removed.
- 群解散原因：群主退群、成员数低于最低 3 人要求。 / Group dissolution reasons: owner leaves or membership falls below the 3-person minimum.
- 群文本和群文件逐成员加密 fan-out。 / Group text and files use per-member encrypted fan-out.
- 同步服务入口由用户配置，作为中继矩阵 bootstrap。 / The sync service entry is user-configured and acts as the relay matrix bootstrap.
- 签名 NodeSetManifest、多入口节点选择、节点 challenge 校验。 / Signed `NodeSetManifest`, multi-entry node selection, and node challenge verification.
- P2P direct -> server route retry -> server mailbox -> 离线密封文件的投递阶梯。 / Delivery ladder: P2P direct -> server route retry -> server mailbox -> offline sealed file.
- mailbox 拉取、ACK tombstone、送达回执查询。 / Mailbox pull, ACK tombstones, and delivery receipt lookup.
- 服务端 route、mailbox、delivery receipt、ACK tombstone 的 best-effort 节点同步。 / Best-effort server node sync for routes, mailbox items, delivery receipts, and ACK tombstones.
- 客户端 replay / message counter 检测。 / Client replay / message counter detection.
- 客户端诊断日志导出和清空。 / Client diagnostic log export and clearing.
- 关于页显示版本、APK 签名指纹、用户手册、源代码仓库和许可证。 / About page shows version, APK signing fingerprint, user manual, source repository, and license.
- Android release APK 签名和 update manifest 生成。 / Android release APK signing and update manifest generation.

### 当前不承诺 / Not Currently Promised

- mailbox 跨节点强一致多副本存储。 / Strongly consistent replicated mailbox storage across nodes.
- MLS 或共享群密钥。 / MLS or shared group keys.
- 多 active messaging device 同步。 / Multiple active messaging device sync.
- 群离线密封。 / Group offline sealing.
- 在线 WebSocket relay、TURN、音视频。 / Online WebSocket relay, TURN, audio, or video.
- 服务器找回身份、联系人或消息。 / Server-side recovery of identities, contacts, or messages.
- 通过 24 词自动恢复联系人、群组或聊天记录。 / Automatic contact, group, or chat-history recovery from the 24-word phrase alone.
- 独立安全审计结论。 / Independent security audit conclusions.

## 3. Android 客户端结构 / Android Client Structure

Android 客户端由 Flutter UI、Rust FFI、Android 原生 MethodChannel 和本地加密数据库组成。

The Android client consists of Flutter UI, Rust FFI, Android native MethodChannels, and a local encrypted database.

```text
Flutter UI
  -> envelope_ffi
    -> envelope-core
  -> Android MethodChannel
    -> Android Keystore / file picker / file saving / external open / cache cleanup
  -> SQLCipher local database
  -> Envelope Server HTTP client
  -> P2P endpoint
```

底部导航 / Bottom navigation:

```text
关于 / About       版本、签名证书指纹、内置用户手册、源代码、许可证
                   Version, signing certificate fingerprint, bundled manual, source code, license
联系人 / Contacts  联系人、群组、过滤、未读角标、加好友、建群
                   Contacts, groups, filters, unread badges, add contact, create group
聊天 / Chat        点对点和群聊文本 / 文件消息
                   One-to-one and group text / file messages
拆封 / Open        导入离线信封文件或 base64
                   Import offline envelope files or base64
设置 / Settings    身份、安全、同步服务、本地备份、缓存、诊断
                   Identity, security, sync service, local backup, cache, diagnostics
```

## 4. 身份和恢复 / Identity and Recovery

身份由 Rust core 生成。BIP39 24 词恢复词派生长期身份密钥。恢复词不会直接作为私钥使用，而是通过固定 KDF 和 context 派生用途不同的密钥。

Identities are generated by Rust core. The BIP39 24-word recovery phrase derives long-term identity keys. The phrase is not used directly as a private key; fixed KDF contexts derive separate keys for separate purposes.

身份恢复语义 / Identity recovery semantics:

- 24 词恢复同一个身份 key id。 / The 24-word phrase recovers the same identity key id.
- 显示名是本机资料，可在恢复时重新填写。 / Display name is local profile data and can be entered again during recovery.
- 联系人、群组、同步服务入口、聊天记录和文件缓存不是恢复词本身的一部分。 / Contacts, groups, sync service entry, chat history, and file cache are not part of the phrase itself.
- 替换身份是危险操作，必须先校验恢复词，再清空当前本机身份、联系人、消息、群组和密封历史。 / Replacing identity is a destructive operation: the phrase must be verified before clearing local identity, contacts, messages, groups, and sealed history.

本地备份语义 / Local backup semantics:

- 备份使用 24 词派生的本地备份密钥加密。 / Backups are encrypted with a local backup key derived from the 24-word phrase.
- 备份内容包含显示名、身份 key id、同步服务入口、联系人、群组和群成员。 / Backup content includes display name, identity key id, sync service entry, contacts, groups, and group members.
- 当前备份不包含聊天记录，不包含 received / sealed 文件缓存。 / Current backups do not include chat history or the received / sealed file cache.
- 恢复本地备份会替换当前本机使用现场。 / Restoring a local backup replaces the current local usage state.
- 恢复时必须验证 24 词恢复出的 key id 与备份身份匹配。 / Restore must verify that the phrase-derived key id matches the backup identity.

## 5. 本地存储 / Local Storage

Android 生产存储使用 SQLCipher。数据库口令由 Android Keystore 保护。主要表：

Android production storage uses SQLCipher. The database passphrase is protected by Android Keystore. Main tables:

```text
contacts
messages
metadata
file_transfers
file_transfer_chunks
sealed_envelopes
groups
group_members
group_events
received_message_counters
```

文件保存策略 / File saving policy:

- 接收文件保存到 `Download/Envelope/received`。 / Received files are saved under `Download/Envelope/received`.
- 离线密封输出保存到 `Download/Envelope/sealed`。 / Offline sealed output is saved under `Download/Envelope/sealed`.
- 本地备份保存到 `Download/Envelope/backups`。 / Local backups are saved under `Download/Envelope/backups`.
- 诊断日志导出到 `Download/Envelope/diagnostics`。 / Diagnostic logs are exported to `Download/Envelope/diagnostics`.
- 清空文件缓存只删除 received 和 sealed，并将对应记录标记为文件已删除。 / Clearing file cache only deletes received and sealed files and marks related records as file-deleted.

## 6. 联系人和 IntroBundle / Contacts and IntroBundle

联系人记录包含公开身份、显示名、fingerprint、设备信息、能力声明和签名。任何 contact / IntroBundle 写入本机前都必须校验签名。

A contact record contains public identity, display name, fingerprint, device information, capability declarations, and signature. Any contact / IntroBundle must be signature-verified before local storage.

联系人建立路径 / Contact setup paths:

```text
二维码出示 / 扫描
QR show / scan

剪贴板 contact 导入
Clipboard contact import

Envelope Server intro session 回传对方 bundle
Peer bundle returned through Envelope Server intro session
```

二维码是短期交换载体。面对面扫码时，用户需要核对 fingerprint。截图、复制或外部转交的 contact 只能证明签名有效，不能自动证明现实身份。

QR codes are short-lived exchange carriers. During in-person scanning, users should compare fingerprints. Screenshots, copied payloads, or externally transferred contacts only prove signature validity; they do not automatically prove real-world identity.

intro session 只用于短期互加回传 / Intro sessions are only for short-lived mutual-add return flow:

- 出示方上传短期签名 bundle。 / The presenter uploads a short-lived signed bundle.
- 扫描方确认后提交自己的签名 bundle。 / The scanner confirms and submits their own signed bundle.
- 出示方轮询到扫描方 bundle 后仍需用户确认。 / The presenter still needs user confirmation after polling the scanner bundle.
- 服务器不能自动添加联系人。 / The server cannot automatically add contacts.

## 7. 消息和文件 / Messages and Files

所有消息最终都以 opaque 信封传输。服务端只看到外层 envelope id、发送方/接收方 key id、大小、TTL、hash 和必要投递状态。

All messages are ultimately transported as opaque envelopes. The server only sees outer envelope id, sender / recipient key ids, size, TTL, hash, and required delivery state.

点对点发送路径 / One-to-one delivery path:

```text
P2P direct
  -> Envelope Server route retry
  -> Envelope Server mailbox
  -> local pending retry
```

如果用户主动选择离线密封，则走独立的离线信封文件路径，不进入在线投递链路。

If the user explicitly chooses offline sealing, delivery uses a separate offline envelope file path and does not enter the online delivery chain.

在线文件 / Online files:

- 产品上限为 64 MiB。 / Product limit is 64 MiB.
- 客户端按 4 MiB 分片。 / The client chunks files in 4 MiB pieces.
- 每个分片独立封装为加密信封。 / Each chunk is independently wrapped as an encrypted envelope.
- manifest 记录文件名、MIME、总大小、chunk size、chunk count、文件 hash 和分片 hash。 / The manifest records file name, MIME, total size, chunk size, chunk count, file hash, and chunk hashes.
- 接收端校验分片 hash 和文件 hash 后写入 received。 / The receiver verifies chunk hashes and file hash before writing to received.
- 图片和视频在聊天界面显示预览。 / Images and videos show previews in chat.

消息状态 / Message states:

```text
sent            已通过直连路径送出 / sent through direct path
server_mailbox  已写入服务端离线邮箱 / written to server mailbox
pending         当前未成功投递，保留待重试 / not delivered yet, kept for retry
delivered       对方已解密入库并 ACK / peer decrypted, stored, and ACKed
received        本机收到并入库 / received and stored locally
```

## 8. 离线密封和拆封 / Offline Sealing and Opening

离线密封只支持点对点，不支持群组。

Offline sealing only supports one-to-one delivery, not groups.

密封语义 / Sealing semantics:

- 发送方选择一个联系人。 / The sender selects one contact.
- 文本或文件会加密包装成只供该联系人解密的离线信封文件。 / Text or file content is encrypted into an offline envelope file that only the selected contact can decrypt.
- 输出文件由用户自行通过邮箱、网盘、U 盘等外部工具或渠道转交。 / The output file is transferred by the user through external tools or channels such as email, cloud drive, or USB drive.
- 外部工具或渠道只搬运密文。 / External tools or channels only carry ciphertext.

拆封语义 / Opening semantics:

- 接收方从文件或 base64 导入离线信封。 / The receiver imports an offline envelope from file or base64.
- 本机使用已有身份尝试解密。 / The local device attempts decryption with the existing identity.
- 解密成功后写入聊天记录。 / On successful decryption, the result is written to chat history.
- 大文件拆封使用流式容器，避免一次性读入完整文件。 / Large-file opening uses a streaming container to avoid loading the full file at once.

## 9. 群组模型 / Group Model

群组不使用共享群密钥。群文本、群文件和群控制事件都按成员逐一加密 fan-out。

Groups do not use shared group keys. Group text, files, and control events are encrypted per member with fan-out.

建群规则 / Group creation rules:

- 创建者是群主。 / The creator is the group owner.
- 至少选择 2 名受邀者。 / At least 2 invitees must be selected.
- 群主本机立即创建并显示群。 / The owner creates and sees the group locally immediately.
- 受邀者在与邀请者的单聊里收到群邀请消息。 / Invitees receive the group invitation inside the inviter's one-to-one chat.
- 接受邀请后才进入对应群状态。 / Invitees enter the group state only after accepting.

群策略 / Group policies:

```text
普通群 / Normal
  受邀者接受后成为 active 成员。
  Invitees become active members after accepting.

验证群 / Verified
  受邀者接受后成为 active 成员；发送时只投递给本地信任的 active 成员。
  Invitees become active after accepting; sending only targets locally trusted active members.

共识群 / Consensus
  受邀者接受后为 accepted；active 成员背书达到 60% 阈值后才成为 active。
  Invitees become accepted after accepting; they become active only after active-member endorsements reach the 60% threshold.
```

群成员状态 / Group member states:

```text
pending   已被邀请，尚未接受 / invited, not accepted yet
accepted  已接受，等待共识 / accepted, waiting for consensus
active    可收发后续群消息 / can send and receive later group messages
left      已退出 / left
removed   已移除 / removed
```

群信任状态 / Group trust states:

```text
verified             已核对 fingerprint / fingerprint verified
inviter              邀请者背书 / endorsed by inviter
unverified           未验证 / unverified
consensus_pending    等待共识 / waiting for consensus
consensus_admitted   共识通过 / admitted by consensus
```

群控制事件 / Group control events:

- group_invite
- member_accepted
- member_endorsed
- group_renamed
- group_avatar_updated
- member_left
- member_removed
- group_message
- group_file manifest / chunks

群解散 / Group dissolution:

- 群主退出且群无法继续满足规则时解散。 / Dissolves when the owner leaves and the group can no longer satisfy the rules.
- active + pending + accepted 的有效成员少于 3 人时解散。 / Dissolves when active + pending + accepted effective members fall below 3.
- 解散通知包含原因。 / Dissolution notices include the reason.
- 本机退群先立即隐藏群并返回联系人页，再后台通知其他成员。 / Local leave hides the group and returns to Contacts immediately, then notifies other members in the background.

## 10. 消息同步和中继矩阵 / Message Sync and Relay Matrix

同步服务入口由用户在设置页输入。该入口是中继矩阵的 bootstrap 地址，客户端用它刷新签名 NodeSetManifest。

The sync service entry is entered by the user in Settings. It is the relay matrix bootstrap address, and the client uses it to refresh the signed `NodeSetManifest`.

客户端节点选择流程 / Client node selection flow:

```text
读取用户配置的同步服务入口 / read user-configured sync service entry
请求 /v1/nodes/manifest / request /v1/nodes/manifest
用内置 manifest public key 验签 / verify with bundled manifest public key
校验 epoch、有效期和节点列表 / validate epoch, validity window, and node list
对候选节点执行 node challenge / run node challenge for candidates
按健康状态、失败次数和权重选择节点 / select by health, failure count, and weight
请求失败时切换到同一 manifest 中的其他节点 / switch to another node from the same manifest on request failure
```

客户端同步内容 / Client sync work:

- 注册当前设备 route。 / Register current device route.
- 拉取 mailbox。 / Pull mailbox.
- 导入并解密 mailbox 信封。 / Import and decrypt mailbox envelopes.
- 对已解密入库的信封发送 ACK。 / ACK envelopes that were decrypted and stored.
- 查询送达回执。 / Query delivery receipts.
- 重试 pending 消息。 / Retry pending messages.

前台运行时，客户端会更积极地拉取 mailbox，以改善消息到达体感延迟。

When running in the foreground, the client pulls mailbox more actively to improve perceived message arrival latency.

## 11. Envelope Server

服务端是 Rust + Axum + SQLite。当前接口：

The server is Rust + Axum + SQLite. Current endpoints:

```text
GET  /health
PUT  /v1/devices/register
GET  /v1/routes/{owner_key_id}/{device_id}
POST /v1/envelopes
POST /v1/mailbox/{recipient_key_id}/pull
POST /v1/mailbox/{recipient_key_id}/ack
POST /v1/delivery/{sender_key_id}/status
PUT  /v1/intro-sessions/{session_id}
POST /v1/intro-sessions/{session_id}/response
GET  /v1/intro-sessions/{session_id}/response
GET  /v1/nodes/manifest
POST /v1/node/challenge
POST /v1/node/sync
```

服务端存储 / Server storage:

```text
device_routes
mailbox_envelopes
delivery_receipts
mailbox_ack_tombstones
node_sync_peer_state
```

服务端安全边界 / Server security boundaries:

- 设备 route 必须由 owner identity 签名。 / Device routes must be signed by the owner identity.
- mailbox pull 必须由收件 identity 签名。 / Mailbox pull must be signed by the recipient identity.
- mailbox ACK 必须由收件 identity 签名。 / Mailbox ACK must be signed by the recipient identity.
- delivery status 查询必须由发送 identity 签名。 / Delivery status lookup must be signed by the sender identity.
- envelope submit 只校验外层资源占用、hash、大小和提交身份。 / Envelope submit only validates outer resource usage, hash, size, and submitter identity.
- 节点清单必须由 manifest signing key 签名。 / Node manifests must be signed by the manifest signing key.
- node challenge 必须由节点 signing key 签名。 / Node challenges must be signed by the node signing key.
- 节点间同步必须带节点签名。 / Node-to-node sync must carry a node signature.

服务端当前是 mailbox 高可用和路由可用性的 best-effort 设计，不提供跨节点强一致写入仲裁。节点间同步覆盖 route、mailbox、delivery receipt 和 ACK tombstone；ACK tombstone 会删除已确认的 mailbox envelope。

The current server design is best-effort for mailbox availability and route availability. It does not provide strongly consistent cross-node write quorum. Node sync covers routes, mailbox items, delivery receipts, and ACK tombstones. ACK tombstones delete confirmed mailbox envelopes.

## 12. 诊断和日志 / Diagnostics and Logs

客户端诊断日志记录 / Client diagnostic logs record:

- 操作名称和结果。 / Operation name and result.
- 网络路径和节点选择。 / Network path and node selection.
- 同步耗时和错误。 / Sync timing and errors.
- 发送、拉取、ACK、重试状态。 / Send, pull, ACK, and retry status.

诊断日志不记录 / Diagnostic logs do not record:

- 消息正文。 / Message body.
- 文件内容。 / File content.
- 私钥。 / Private keys.
- 24 词恢复词。 / 24-word recovery phrase.
- SQLCipher 数据库口令。 / SQLCipher database passphrase.

## 13. 发布和更新 / Release and Update

Android release APK 使用正式 release signing key。构建脚本会生成：

Android release APKs use the release signing key. The build script generates:

```text
release APK
release update manifest
update manifest public key
APK SHA-256
```

update manifest 使用 RSA-PSS-SHA256 签名，包含 APK 下载信息、versionCode、versionName、SHA-256 和签名元数据。

The update manifest is signed with RSA-PSS-SHA256 and contains APK download information, versionCode, versionName, SHA-256, and signing metadata.

## 14. 实现约束 / Implementation Constraints

- 不自研底层密码算法，只组合成熟算法和协议封装。 / Do not implement low-level cryptographic algorithms; compose mature algorithms and protocol wrappers.
- 不让服务器看到明文消息、文件名以外的内部业务内容或群控制事件明文。 / Do not expose plaintext messages, internal business content beyond file names, or plaintext group control events to the server.
- 群组第一版使用逐成员加密，不引入共享群密钥。 / The first group implementation uses per-member encryption and does not introduce shared group keys.
- 24 词是身份恢复凭据，不是使用现场同步机制。 / The 24-word phrase is an identity recovery credential, not a usage-state sync mechanism.
- 本地备份是当前恢复使用现场的主路径，但不包含聊天记录和文件缓存。 / Local backup is the current primary path for restoring usage state, but it does not include chat history or file cache.
- 外部工具或渠道只用于离线密文搬运。 / External tools or channels are only used to carry offline ciphertext.
- Android 厂商和版本差异会影响文件打开、目录打开和系统授权行为，相关操作必须走系统 Intent / SAF / FileProvider 等标准接口，并通过真机矩阵验证。 / Android vendor and version differences affect file opening, directory opening, and system authorization behavior; related operations must use standard Intent / SAF / FileProvider interfaces and be verified on real devices.

## 15. 文档维护规则 / Documentation Rules

仓库 `docs/` 目录只保留：

The repository `docs/` directory keeps only:

```text
docs/design.md
docs/android-user-manual.html
```

新增设计内容先合并进本文。面向用户的操作变化同步更新 Android 用户手册。阶段计划、调试记录和部署过程不再放入 `docs/`，避免公开文档出现过期功能或内部运维细节。

New design content should be merged into this document first. User-facing behavior changes should also update the Android user manual. Phase plans, debug notes, and deployment process notes should not be placed under `docs/`, keeping public documentation free of stale behavior and internal operations details.
