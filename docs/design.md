# Envelope 当前设计文档

本文是 Envelope 仓库的单一设计基线，对齐当前 Android 客户端、Rust core / FFI、Envelope Server 和部署脚本的实现状态。历史阶段文档已合并到本文，不再作为独立维护对象。

最后更新：2026-07-07

## 1. 产品定位

Envelope 是一个以 Android 为主的端到端加密通信项目。消息、文件和群组控制事件都被编码为 opaque 加密信封。客户端负责身份、联系人、加密、解密、本地数据库和用户确认；Envelope Server 只负责路由、mailbox 兜底、intro session、送达回执、节点清单和节点间 best-effort 同步。

服务器和外部工具或渠道不能解密消息内容。服务端不解析信封内部的明文元数据，也不应成为联系人信任或群成员身份确认的来源。

当前主产品形态是 Android 客户端。桌面端仍是开发验证 shell，不作为当前用户主线。

## 2. 当前功能边界

### 已实现

- Android 五个主入口：关于、联系人、聊天、拆封、设置。
- Android Keystore 保护 SQLCipher 数据库口令，本机身份存放于加密数据库。
- BIP39 24 词身份创建和身份恢复。
- 本地锁屏：打开 App 和高风险操作可使用系统 PIN、密码或生物识别确认。
- 本地备份：用 24 词加密导出显示名、身份 key id、同步服务入口、联系人、群组和群成员。
- 二维码联系人交换、剪贴板 contact 导入和 fingerprint 人工确认。
- 联系人备注、联系人删除和端到端加密 contact-control 删除通知。
- 点对点文本和文件发送。
- 图片、视频文件预览；文件点击优先调用系统默认应用打开，失败时退回保存路径。
- 聊天记录分页、消息多选和本机删除。
- 64 MiB 内在线文件发送，客户端分片、哈希校验和逐信封加密。
- 点对点离线密封和拆封，支持文本和本地文件。
- 普通群、验证群、共识群。
- 群邀请以邀请者单聊消息呈现，受邀者可接受或拒绝。
- 建群最少 3 人：群主加至少 2 名受邀者。
- 群主改群名、更新群头像 seed、邀请成员、移除成员。
- 群成员状态：pending、accepted、active、left、removed。
- 群解散原因：群主退群、成员数低于最低 3 人要求。
- 群文本和群文件逐成员加密 fan-out。
- 同步服务入口由用户配置，作为中继矩阵 bootstrap。
- 签名 NodeSetManifest、多入口节点选择、节点 challenge 校验。
- P2P direct -> server route retry -> server mailbox -> 离线密封文件的投递阶梯。
- mailbox 拉取、ACK tombstone、送达回执查询。
- 服务端 route、mailbox、delivery receipt、ACK tombstone 的 best-effort 节点同步。
- 客户端 replay / message counter 检测。
- 客户端诊断日志导出和清空。
- Android release APK 签名和 update manifest 生成。

### 当前不承诺

- mailbox 跨节点强一致多副本存储。
- MLS 或共享群密钥。
- 多 active messaging device 同步。
- 群离线密封。
- 在线 WebSocket relay、TURN、音视频。
- 服务器找回身份、联系人或消息。
- 通过 24 词自动恢复联系人、群组或聊天记录。
- 独立安全审计结论。

## 3. Android 客户端结构

Android 客户端由 Flutter UI、Rust FFI、Android 原生 MethodChannel 和本地加密数据库组成。

```text
Flutter UI
  -> envelope_ffi
    -> envelope-core
  -> Android MethodChannel
    -> Android Keystore / 文件选择 / 文件保存 / 外部打开 / 本地缓存清理
  -> SQLCipher local database
  -> Envelope Server HTTP client
  -> P2P endpoint
```

底部导航：

```text
关于     版本、签名证书指纹、内置用户手册入口
联系人   联系人、群组、过滤、未读角标、加好友、建群
聊天     点对点和群聊文本 / 文件消息
拆封     导入离线信封文件或 base64
设置     身份、安全、同步服务、本地备份、缓存、诊断
```

## 4. 身份和恢复

身份由 Rust core 生成。BIP39 24 词恢复词派生长期身份密钥。恢复词不会直接作为私钥使用，而是通过固定 KDF 和 context 派生用途不同的密钥。

身份恢复语义：

- 24 词恢复同一个身份 key id。
- 显示名是本机资料，可在恢复时重新填写。
- 联系人、群组、同步服务入口、聊天记录和文件缓存不是恢复词本身的一部分。
- 替换身份是危险操作，必须先校验恢复词，再清空当前本机身份、联系人、消息、群组和密封历史。

本地备份语义：

- 备份使用 24 词派生的本地备份密钥加密。
- 备份内容包含显示名、身份 key id、同步服务入口、联系人、群组和群成员。
- 当前备份不包含聊天记录，不包含 received / sealed 文件缓存。
- 恢复本地备份会替换当前本机使用现场。
- 恢复时必须验证 24 词恢复出的 key id 与备份身份匹配。

## 5. 本地存储

Android 生产存储使用 SQLCipher。数据库口令由 Android Keystore 保护。主要表：

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

文件保存策略：

- 接收文件保存到 `Download/Envelope/received`。
- 离线密封输出保存到 `Download/Envelope/sealed`。
- 本地备份保存到 `Download/Envelope/backups`。
- 诊断日志导出到 `Download/Envelope/diagnostics`。
- 清空文件缓存只删除 received 和 sealed，并将对应记录标记为文件已删除。

## 6. 联系人和 IntroBundle

联系人记录包含公开身份、显示名、fingerprint、设备信息、能力声明和签名。任何 contact / IntroBundle 写入本机前都必须校验签名。

联系人建立路径：

```text
二维码出示 / 扫描
剪贴板 contact 导入
Envelope Server intro session 回传对方 bundle
```

二维码是短期交换载体。面对面扫码时，用户需要核对 fingerprint。截图、复制或外部转交的 contact 只能证明签名有效，不能自动证明现实身份。

intro session 只用于短期互加回传：

- 出示方上传短期签名 bundle。
- 扫描方确认后提交自己的签名 bundle。
- 出示方轮询到扫描方 bundle 后仍需用户确认。
- 服务器不能自动添加联系人。

## 7. 消息和文件

所有消息最终都以 opaque 信封传输。服务端只看到外层 envelope id、发送方/接收方 key id、大小、TTL、hash 和必要投递状态。

点对点发送路径：

```text
P2P direct
  -> Envelope Server route retry
  -> Envelope Server mailbox
  -> 本机待重试
```

如果用户主动选择离线密封，则走独立的离线信封文件路径，不进入在线投递链路。

在线文件：

- 产品上限为 64 MiB。
- 客户端按 4 MiB 分片。
- 每个分片独立封装为加密信封。
- manifest 记录文件名、MIME、总大小、chunk size、chunk count、文件 hash 和分片 hash。
- 接收端校验分片 hash 和文件 hash 后写入 received。
- 图片和视频在聊天界面显示预览。

消息状态：

```text
sent            已通过直连路径送出
server_mailbox  已写入服务端离线邮箱
pending         当前未成功投递，保留待重试
delivered       对方已解密入库并 ACK
received        本机收到并入库
```

## 8. 离线密封和拆封

离线密封只支持点对点，不支持群组。

密封语义：

- 发送方选择一个联系人。
- 文本或文件会加密包装成只供该联系人解密的离线信封文件。
- 输出文件由用户自行通过邮箱、网盘、U 盘等外部工具或渠道转交。
- 外部工具或渠道只搬运密文。

拆封语义：

- 接收方从文件或 base64 导入离线信封。
- 本机使用已有身份尝试解密。
- 解密成功后写入聊天记录。
- 大文件拆封使用流式容器，避免一次性读入完整文件。

## 9. 群组模型

群组不使用共享群密钥。群文本、群文件和群控制事件都按成员逐一加密 fan-out。

建群规则：

- 创建者是群主。
- 至少选择 2 名受邀者。
- 群主本机立即创建并显示群。
- 受邀者在与邀请者的单聊里收到群邀请消息。
- 接受邀请后才进入对应群状态。

群策略：

```text
普通群   受邀者接受后成为 active 成员。
验证群   受邀者接受后成为 active 成员；发送时只投递给本地信任的 active 成员。
共识群   受邀者接受后为 accepted；active 成员背书达到 60% 阈值后才成为 active。
```

群成员状态：

```text
pending   已被邀请，尚未接受
accepted  已接受，等待共识
active    可收发后续群消息
left      已退出
removed   已移除
```

群信任状态：

```text
verified             已核对 fingerprint
inviter              邀请者背书
unverified           未验证
consensus_pending    等待共识
consensus_admitted   共识通过
```

群控制事件：

- group_invite
- member_accepted
- member_endorsed
- group_renamed
- group_avatar_updated
- member_left
- member_removed
- group_message
- group_file manifest / chunks

群解散：

- 群主退出且群无法继续满足规则时解散。
- active + pending + accepted 的有效成员少于 3 人时解散。
- 解散通知包含原因。
- 本机退群先立即隐藏群并返回联系人页，再后台通知其他成员。

## 10. 消息同步和中继矩阵

同步服务入口由用户在设置页输入。该入口是中继矩阵的 bootstrap 地址，客户端用它刷新签名 NodeSetManifest。

客户端节点选择流程：

```text
读取用户配置的同步服务入口
请求 /v1/nodes/manifest
用内置 manifest public key 验签
校验 epoch、有效期和节点列表
对候选节点执行 node challenge
按健康状态、失败次数和权重选择节点
请求失败时切换到同一 manifest 中的其他节点
```

客户端同步内容：

- 注册当前设备 route。
- 拉取 mailbox。
- 导入并解密 mailbox 信封。
- 对已解密入库的信封发送 ACK。
- 查询送达回执。
- 重试 pending 消息。

前台运行时，客户端会更积极地拉取 mailbox，以改善消息到达体感延迟。

## 11. Envelope Server

服务端是 Rust + Axum + SQLite。当前接口：

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

服务端存储：

```text
device_routes
mailbox_envelopes
delivery_receipts
mailbox_ack_tombstones
node_sync_peer_state
```

服务端安全边界：

- 设备 route 必须由 owner identity 签名。
- mailbox pull 必须由收件 identity 签名。
- mailbox ACK 必须由收件 identity 签名。
- delivery status 查询必须由发送 identity 签名。
- envelope submit 只校验外层资源占用、hash、大小和提交身份。
- 节点清单必须由 manifest signing key 签名。
- node challenge 必须由节点 signing key 签名。
- 节点间同步必须带节点签名。

服务端当前是 mailbox 高可用和路由可用性的 best-effort 设计，不提供跨节点强一致写入仲裁。节点间同步覆盖 route、mailbox、delivery receipt 和 ACK tombstone；ACK tombstone 会删除已确认的 mailbox envelope。

## 12. 诊断和日志

客户端诊断日志记录：

- 操作名称和结果。
- 网络路径和节点选择。
- 同步耗时和错误。
- 发送、拉取、ACK、重试状态。

诊断日志不记录：

- 消息正文。
- 文件内容。
- 私钥。
- 24 词恢复词。
- SQLCipher 数据库口令。

## 13. 发布和更新

Android release APK 使用正式 release signing key。构建脚本会生成：

```text
release APK
release update manifest
update manifest public key
APK SHA-256
```

update manifest 使用 RSA-PSS-SHA256 签名，包含 APK 下载信息、versionCode、versionName、SHA-256 和签名元数据。

## 14. 实现约束

- 不自研底层密码算法，只组合成熟算法和协议封装。
- 不让服务器看到明文消息、文件名以外的内部业务内容或群控制事件明文。
- 群组第一版使用逐成员加密，不引入共享群密钥。
- 24 词是身份恢复凭据，不是使用现场同步机制。
- 本地备份是当前恢复使用现场的主路径，但不包含聊天记录和文件缓存。
- 外部工具或渠道只用于离线密文搬运。
- Android 厂商和版本差异会影响文件打开、目录打开和系统授权行为，相关操作必须走系统 Intent / SAF / FileProvider 等标准接口，并通过真机矩阵验证。

## 15. 文档维护规则

仓库 `docs/` 目录只保留：

```text
docs/design.md
docs/android-user-manual.html
```

新增设计内容先合并进本文。面向用户的操作变化同步更新 Android 用户手册。阶段计划、调试记录和部署过程不再放入 `docs/`，避免公开文档出现过期功能或内部运维细节。
