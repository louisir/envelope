# v1.0.1 HA 工程验证与产品验收记录

记录日期：2026-09-20。候选版本：`v1.0.1.20260920175310.034`。本记录区分源码/隔离环境验证、实际部署验证、真实客户端验收。发布目录为 `artifacts/releases/v1.0.1.20260920175310.034/`；不能仅凭版本字符串判断运行文件相同。

目前已完成协议、持久化、控制面、真实 HTTP 隔离集成、恢复工具和下述公网故障验证。**完整产品验收尚未完成**；真实设备/UI、完整网络分区矩阵、容量与长期运行指标仍须按 [HA 验收标准](relay-ha-acceptance.md) 执行。

## 已冻结客户端包

| 工件 | SHA-256 | 已核对 |
| --- | --- | --- |
| `Envelope-Windows-win-x64-v1.0.1.20260920175310.034-portable.zip` | `76c37e173221a36145dd41bf7b96c59ba71b30de5cd2cbca430d9dbe86719a3a` | 73,625,539 字节、477 项、自包含运行时、固定信任入口、原生 HA v2 导出、发布验证通过 |
| `envelope-v1.0.1.20260920175310.034-release.apk` | `c28e6347ad3df60283d1ccc468e0b704a784696b42a8d35474160344de9a0982` | 33,848,032 字节、ARM64、versionName 1.0.1 / versionCode 22673342、旧版本同签名、16 KiB 对齐、固定信任入口、90 项 Flutter 测试与 analyze 通过 |

Android 签名证书 SHA-256：`d2a659b5426f12cc5ca39f85b00ebe3e008f6d74cf9b08bee22a673eb5779761`。关于页显示完整构建版本。Windows InformationalVersion 的源码 SHA 后缀不会显示在关于页；SHA 后缀并不包含本次所有未提交改动，应以源快照和各工件哈希定位构建。

详细包校验在发布目录的 `windows-gates.json`、`android-gates.json`、`release-review.json` 与 `SHA256SUMS.txt`。未执行用户手机安装和双端真实 UI 验收；ARM32/x86 Android 不在此 APK 支持范围。

## 实际部署及故障发现

2026-09-20 已安装 S1 `121.199.52.175`、S2 `67.230.178.13` 两个业务副本，以及 S1/S2/Google `34.3.107.22` 三个 etcd 投票者；Oracle `150.136.55.148` 未加入当前投票集。Google 云防火墙由用户开放后，S1/S2 到 Q 的 2379/2380 均已实测连通。三台 etcd 3.6.14 同集群、无 alarm，应用进度追上日志，RBAC 已开启且业务身份不能访问无关前缀。独立证据在 `deployment/control-initial-review/`。

两业务接口为 `https://envelope.iamlouis.online/v2/`、`https://npvwxzkfdqkck.work/v2/`。业务后端只监听 loopback，跨节点内部19444要求 mTLS，并再次校验对端 CN。S2 原 YourTurn 首页和新 `/v2/health` 均返回200，Nginx 配置校验通过；没有改写其443 stream或重启其他代理。

第一封 synthetic 信封已通过真实公网 HTTPS 双副本提交、双方签名证明校验、收取和实际解密；两份业务快照均通过恢复工具验签，applied index=3、对象根与决定链根相同。业务快照留在各 VPS `/var/backups/envelope-ha/pre-failover-20260920`；离线管理机另持有控制快照，私钥与快照不加入源码/公开发布包。

首次生产故障演练发现仲裁客户端缺陷：S1 的业务与 etcd 停止后，S2/Q 多数正常，但应用仍通过 balanced channel 命中已停止的 S1，反复失去业务租约，60秒内未取得完整接管证明。第二轮原始失败记录为 `deployment/s1-loss-before-control-fix.json`；独立健康采样为 `deployment/control-fault-review/`。UTC 10:35:26、31、36 三轮中 S2/Q 共6次健康检查均成功，且都在 S1 恢复前完成。这些失败保留在验收记录中，不能用恢复后的成功覆盖。

修复后每个仲裁端点使用独立连接，记忆成功首选；单 RPC 总预算仍为5秒，失败时明确切换端点，续租也可转移连接。CAS 重试保持原比较条件，不把响应丢失后的比较失败解释为成功。另修复协议正式 `/v2/delivery/status` 路径遗漏，同时保留 Windows 使用的带发送者路径；签名和发送者绑定校验不变。实际非发送者在两个别名及伪造发送者路径均被403拒绝。

最终两台运行的 `envelope-server-ha` SHA-256 为 `68789fe8c4dd13f30c58c219dcde667aaebc8539b40c4f1ed033e9cabc77d672`；`envelope-ha-recovery` 为 `b2dc6b002e098d751816024f17a1a17214dcc84b6ec85c5113b7fcd1b0a0492d`。二进制和实际服务器编译输入归档在发布目录 `server/`。两个客户端包未因这些服务端修复而更改。

| 公网验证 | 结果与范围 | 发布目录内证据 |
| --- | --- | --- |
| 主/备交替丢失，共10轮 | 每轮停止当前 leader 的 Envelope业务与本机etcd；另一业务节点和Q维持多数。10/10均在恢复故障节点前读回、验签并解密同一原始信封，5秒后的第二次读取仍成功。接管14.136–27.414秒，平均19.801秒，全部小于60秒 | `deployment/failover-after-control-fix/` |
| Windows实际发布库持续运行 | 同一个 `EnvelopeHaServerClient` 完成5次入口切换；与故障时间对齐后恢复16.586–21.800秒。180秒78次尝试中38次成功验签解密，40次注入故障期间失败完整保留；没有ACK | `windows-live-failover/` |
| Android生产实现正常闭环 | 10项源码哈希与候选包记录匹配，使用实际发布FFI和独立宿主SQLite，真实HTTPS发现→双副本存储→收取解密→本地持久化→收件签名→发送者验证Delivered通过 | `android-live-normal.json`；初次路径遗漏失败另存 |
| 单副本暂存与恢复 | 停止S1业务时S2仅返回 `staged_single`、commit index为空；恢复后同一ID/密文提升为 `replicated`、index8，并验证收件方签名Delivered | `deployment/staged-upgrade-delivery.json` |
| 丢失仲裁多数 | 同时停止S2/Q etcd，保留两业务进程；两公开入口的签名拉取、状态查询和新存储请求共6次全部409 `NOT_LEADER`，无成功确认；随后恢复所有进程 | `deployment/majority-loss.json` |
| 最终对账与备份 | 原信封最后也取得签名Delivered。两业务 applied=head=10、对象数12、决定链根和对象根相同；两份最终业务快照验签通过，并与控制快照一起保存到离线管理机私密目录 | `deployment/original-signed-delivery.json`、`s1-final-backup.txt`、`s2-final-backup.txt` |

接管计时从执行停止命令开始，到完整证明校验与解密成功结束，包含SSH及探针耗时。上述为真实VPS上的进程故障，不是物理断电、单向网络分区或磁盘损坏。Windows使用最终portable的实际程序集与原生库，但未启动WPF UI；Android使用生产Dart实现与宿主FFI，未在ARM64手机执行。不能据此将“10次双端前台UI接管”或全部产品父用例标为通过。

最终业务快照在两台 `/var/backups/envelope-ha/verified-release-20260920`；离线副本和控制快照在管理机私密 `keys/ha-v2-20260920/final-backups/`。不把运行中的WAL文件直接复制为备份，不把这些私密快照加入源码包。

最后只读复核（UTC 11:01:52–11:03:54）确认三仲裁健康、无alarm、revision188；两业务证书自有前缀允许/越界拒绝。S2 YourTurn公网HTTPS返回200，S2/Q原有服务仍active；这不等于原代理认证业务和YourTurn交互已全面回归。结果见 `deployment/final-readonly-review/assessment.json`。故障演练后活动业务主为S2、term183，S1已同步作为备用；恢复节点按设计不会立即抢回主角色。

完整dirty源码快照 `source-snapshot-v1.0.1.20260920175310.034.tar.gz` 包含273个文件，SHA-256 `fa096981458c5941e57af5d49b69616961880a42a329d68f86e092af507ebb5b`。捕获时间 UTC 10:54:10；归档条目、逐文件哈希及捕获后的源文件稳定性均通过。当前HEAD为 `d39ef4e26203a2a126106d324766e9f9027f71ec`，工作树dirty；HEAD不是这些未提交源码的替代标识。本报告在该快照之后补入最终验收结果。

## 已执行的工程验证

| 范围 | 证据与结果 | 能证明的边界 |
| --- | --- | --- |
| 协议与状态 | `cargo test -p envelope-server-core --lib`，28/28 通过；共享向量 `tests/fixtures/ha-v2/vectors.json` 共 9 个有效向量 | Ed25519 独立签名域、严格十进制字符串与重复字段拒绝、配置/任期水位、双副本证明、历史配置与换钥、独立 expiry 双 ack、结果顺序与 TTL 终态规则 |
| etcd 控制面 | `cargo test -p envelope-server --lib ha::control::tests -- --include-ignored`，最终10/10通过；真实三成员etcd | 原有fencing/多数保护，加停一端点120次读写扫描、同一租约跨TTL续期、新会话选举和撤销；响应丢失后CAS不重复提交 |
| 历史恢复证明 | `ha::coordinator::history_tests` 通过 | 显式新 incarnation/新签名键重建后，旧 decision 依赖管理员签名历史配置验签；新签名者不能自行批准伪造旧配置 |
| 运行时端到端隔离集成 | 最新 `ha_runtime` 2/2回归通过；`target/ha-runtime-test/1789901164517191000/verified.json` | 两个HTTP、两个SQLite、真实三etcd：双副本、幂等重试、解密、收件证明、P2P结果、暂存恢复、独立过期、迟到结果、换主、少数拒绝；新增delivery/status别名与跨发送者403拒绝 |
| 自动接管隔离集成 | `target/ha-runtime-test/1789901164517108200/automatic-verified.json`：会话关闭后RTO `2534 ms` | 仅为本机runtime会话关闭场景；公网结果见上表，不能混用两种计时 |
| 容量 P1 修复回归 | `ha::coordinator::capacity_tests` 2/2 通过；`target/ha-capacity-tests/1789899565954997500/capacity-verified.json` | 真实三 etcd/SQLite：8 MiB 相同 stage/Normal 客户端重试不增长，失败后台升级复用 prepare，换 term 封存旧失败 attempt 并保留原 stage；全局/收件人额度用尽时拒绝且 0 条新正文；伪签名和同 ID 不同正文拒绝 |
| 业务快照与重建 | `cargo test -p envelope-server --lib ha::recovery::tests -- --include-ignored`，4/4 通过 | 并发写入中的 WAL 一致快照、成品自己的水位、terminal/prepare/decision 保留，篡改拒绝、新 incarnation/epoch、运行锁和覆盖保护、历史证据、CAS GC 与双快照 checkpoint |
| 恢复 CLI | `envelope-ha-recovery` 构建成功，对实际历史快照执行 `verify` 成功；篡改快照实际返回 hash/length mismatch | CLI 可用性与本地工件校验；不等于生产坏盘恢复或 1 GiB/30 分钟性能通过 |
| 管理配置激活 | `target/ha-activation-test-1789898428463312000` | 从运行手册抽取的 etcdctl CAS 事务已实际验证：leader 存在拒绝、配置成功更新、旧 revision 重放拒绝、head 保持为 7 |

`target/` 下证据是本地测试产物，正式签署前应复制到受控验收目录并登记哈希。运行手册见 [恢复和配置激活](../deploy/envelope-server/ha/recovery.md)。

## 最后一次源码审查

审查范围：`ha/business.rs`、`coordinator.rs`、`runtime.rs`、`maintenance.rs`，以及关联 control/recovery 边界。下列容量修复没有改变 core/FFI 线协议。

已核对：客户端命令签名绑定 kind、actor、operation、cluster/config 和精确 body；HTTP 路径与签名业务体一致；内部 prepare 需要对端身份并检查当前 leader/attempt；正式提交比较当前配置、leader create revision/value/lease、ready、head、operation、对象版本和双持久 ack。公开 mailbox/status/route 读有当前领导者屏障。RecipientResult 使用收件身份的独立签名；服务器存储证明不替代已送达证明；Expired 要求独立双节点过期决定；旧配置仅用于验证历史证明。

本轮没有发现能够直接绕过这些条件制造“双主正式提交”或伪造收件人 Delivered 的确定路径。这是有限源码审查结论，不替代完整网络分区、暂停恢复及真实双端测试。

### 已修复的容量 P1

原 `stage()` 在检查既有相同 staged guard 之前生成新 attempt 并持久化 prepare，普通重试不断留下旧 payload；正式提交在双方 prepare 之后才检查已满配额，拒绝也可能消耗磁盘。修复后，已鉴权同 operation/hash 且本地正文完整的暂存重试直接复用原 proof，Normal 模式客户端也由后台单飞协调器负责升级；prepare 前增加线性一致 usage 预检，最终 CAS 配额检查仍保留。

失败后台升级在相同 term/config/对象版本下复用同一 open prepare，仍通过 exact operation guard 与 attempt=open CAS。旧 term 或失效版本的未提交 attempt 先通过 `seal_and_collect` 封存，使任何并发旧提交的 CAS 失败，再回收；原 staged proof 引用的正文不动。实际 8 MiB 用例 stage 恒为 1 行/11187214 字节 prepared payload，首次失败升级后恒为 2 行/22374428 字节，后续重试不增长；新 term 清理旧升级后仍为 2 行。这里是 payload 内容字节，不是 SQLite 文件/WAL/整机占用上限。P1 的源码修复和隔离回归已通过，生产容量曲线仍待实测。

本次运行时回归曾出现本机隔离 etcd 启动连接拒绝，单独重跑成功；最终最新源码的两项串行回归均通过。容量夹具初轮固定期限/扫描游标和重复 revoke 的清理断言已修正，最终两项均通过；没有将失败轮计作通过证据。

## 配额和保留策略的准确声明

当前代码中的接入基线为：单信封 8 MiB；每收件人 1000 条及 256 MiB；全局正文 1 GiB。usage 在第一次 staged/replicated 接入时增加，暂存升级为 replicated 不重复计数。**当前终态和 TTL 不减少 usage，这些数字是累计接入预算，不是会随领取自动释放的活跃积压上限。** 它们目前是代码固定值，不能写成“已验证可动态调节的生产配置”。

逻辑剩余额度应通过同一次线性一致读取获得当前收件人 `usage/<recipient-digest>` 和 `usage/global`，分别计算 `max(0,1000-count)`、`max(0,256 MiB-mailbox_bytes)`、`max(0,1 GiB-global_bytes)`；新消息必须同时满足三个维度。不能只根据 SQLite 中未读条数报告“剩余容量”。目前没有经过产品验收的 remaining-quota 客户端界面/API。

物理容量另计：两台各自 prepare/decision、孤立 prepare、结果/终态/去重元数据、WAL、快照、etcd 当前键和 MVCC 历史。1 GiB 逻辑正文预算不是数据库或整机磁盘上限；实际剩余磁盘、增长速率、告警和拒绝策略需要独立记录。

TTL 基线最多 7 天，使用固定绝对 `not_after`，重试不续期。到期后停止新的投递/拉取；权威 Expired 证明由有双业务副本的 leader 提交，degraded 时可能延后。**TTL 不承诺 7 天后物理删除，不承诺释放已占用配额。**

当前 `seal_and_collect` 用于替换过时的失败升级 attempt，另提供 `register_checkpoint`；没有周期全库孤立 prepare 清理/周期 checkpoint 调度。committed payload、decision、terminal tombstone、去重证据均保留，`gc_floor` 不推进。checkpoint 通过本身不授权裁剪。该选择保护恢复/幂等证据，但需要容量预算；不能将“未删除数据”解释为已通过容量回收验收。

原 L5 72 小时、至少 2 条/秒会产生至少 518400 条消息，4 KiB 明文已约 1.98 GiB，尚未计协议和日志开销；当前固定累计预算无法支撑该负载。必须先解决容量/配额配置与恢复保留方案，再按冻结负载执行，不能降低实际负载后沿用原指标的“通过”。

## 待产品验收与远程记录

| 项目 | 当前状态 | 发布负责人补录 |
| --- | --- | --- |
| S1/S2/Q 身份、配置、运行hash、TLS/mTLS/RBAC | 已完成上述部署和快照证据；最终只读复核见deployment目录 | 持续服务与容量监控另列运维任务 |
| Windows portable 与 Android APK 版本、哈希、签名、实际安装启动 | 包验证通过；真实安装/UI待验收 | 实际设备/系统、升级与数据保留 |
| 双端互加联系人→P2P/VPS 收发→离线恢复→真实 Delivered | 实际客户端代码公网链路已通过；双端真实UI/P2P和设备数据库对账仍待验收 | 每消息ID/hash/签名结果/路径 |
| 节点故障、网络分区、旧主暂停恢复、少数派拒绝；至少10次前台接管 | VPS进程故障10轮及Windows实库5次切换通过；完整网络/磁盘/UI矩阵待做 | 已执行与未执行场景分别签署 |
| L1 20 身份、10 条/秒、30 分钟 p95/成功率 | 待固定负载测试 | 完整时延样本及 CPU/内存/磁盘曲线 |
| L3 1 GiB 恢复数据、≥10 Mbit/s、≤30 分钟 | 待性能/坏盘演练 | 数据集哈希、传输实测、全量对账 |
| L4 64 MiB 文件、4 MiB 分片、5 人混群 | 待双端真实完整性验收 | 全文件 hash、各接收者结果 |
| 配额边界、重复重试实际磁盘增长、磁盘/etcd NOSPACE | 重试放大 P1 隔离回归已通过；生产故障/容量测试待完成 | 修复构建哈希、容量曲线、拒绝与恢复证据 |
| L5 72 小时稳定性与 7 天真实试点 | 待容量问题关闭后执行 | 不得以短时本地测试代替 |

所有故障注入均需保留原控制面、业务快照、配置历史和管理通道；正式已接收数据不得回退旧快照。当前结论是“核心工程链路已有验证，产品级验收待完成”，不是正式通过签署。
