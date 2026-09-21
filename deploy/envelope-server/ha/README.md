# Envelope HA v2 部署与恢复

这是已核对目标的**分阶段安装脚本**。运行 prepare 只生成本地私密部署包；运行 apply 才修改 VPS。首次部署使用三个空 etcd 成员，已有数据节点必须使用恢复流程，不可重新 bootstrap。

| 节点 | 地址 | 角色 | 公开接口 |
| --- | --- | --- | --- |
| s1 | 121.199.52.175 | 业务副本、etcd 投票者 | https://envelope.iamlouis.online/v2/ |
| s2 | 67.230.178.13 | 业务副本、etcd 投票者 | https://npvwxzkfdqkck.work/v2/ |
| q-gcp | 34.3.107.22 | etcd 投票者，无业务正文 | 无 |

2026-09-20 的只读检查：S1 没有 Nginx；S2 的公共 443 是 Nginx stream，YourTurn HTTPS 由 `127.0.0.1:9443` 承接，另有 Xray/Hysteria；Q 另有 caddy-naive/Xray/Hysteria。脚本只向 S2 现有 YourTurn HTTPS server 加一个 include，不改 stream、现有 location 或其他服务。

## 本地准备

使用 PowerShell 7，仓库根目录运行。`cluster.json` 和 `bootstrap.json` 必须已由维护者生成并核对签名根。Linux 可执行文件必须是 `envelope-server-ha`，不是旧 v1 主程序。

```powershell
./scripts/deploy-ha-prepare.ps1 -ServerBinary ./artifacts/server/envelope-server-ha -RecoveryBinary ./artifacts/server/envelope-ha-recovery
$bundle = (Resolve-Path ./keys/ha-v2-20260920/deployment).Path
```

prepare 验证 etcd 3.6.14 Linux 压缩包 SHA256，生成两套离线 CA（客户端/服务端 CA 与独立 peer CA）和 397 天叶证书。CA 私钥、etcd `root` 管理员私钥、Envelope 管理员签名私钥不上传；节点只得到自己必需的叶私钥。私密包位于 Git 忽略的 keys 下，并限制为当前 Windows 用户 ACL。再次运行不会覆盖旧 CA。到期前须计划续签，不能删除 CA 后盲目重新生成。

若 Linux 二进制尚未构建，可省略 `-ServerBinary` 先生成证书，然后将同一已验证二进制分别放进包的 `s1/envelope-server-ha` 与 `s2/envelope-server-ha`。不重新生成证书。

## 顺序与现场门槛

1. 核对 SSH host key、DNS A/AAAA、当前服务与防火墙、磁盘空间和时钟。云安全组须允许三台 VPS 之间 TCP 2379/2380，以及 S1/S2 之间 TCP 19444；S1 公网需 80/443。主机防火墙仅新增这三个内部端口的独立规则链，不清空全局规则。
2. 安装基础包；S1 新装 Nginx/certbot 会启动新的 HTTP 服务。先完成并记录现有服务基线。
3. 启动全部三个 etcd 成员，随后启用 RBAC；在 RBAC 验证前不启动业务程序。
4. S1 用真实 ACME 证书；S2 复用现有域名证书。检查 DNS、续期定时器与证书链。
5. 安装两个业务副本，配置内部 mTLS 和公开 `/v2/` 代理；最后做协议级与故障验收。

```powershell
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase prerequisites
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase etcd
./scripts/deploy-ha-rbac.ps1 -Bundle $bundle -Action Bootstrap
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase acme -Nodes s1
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase runtime -Nodes s1,s2
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase proxy -Nodes s1,s2
./scripts/deploy-ha-apply.ps1 -Bundle $bundle -Phase verify
./scripts/deploy-ha-rbac.ps1 -Bundle $bundle -Action Verify
```

RBAC 工具仅建立本地 loopback→S1 loopback 的 SSH 隧道，管理私钥保留本机。`root` 无密码，仅允许证书 CN 身份；`envelope-s1/s2` 只能读写 `/envelope/envelope-managed-20260920/g/1/`。工具验证业务身份可读该前缀且无法读取无关前缀。Bootstrap 是一次性操作；中途失败后需检查 `user list`/`role list`，不能反复重建或关闭鉴权。

etcd 心跳 500ms、选举超时 5s；Envelope 业务租约仍由协议控制。默认 etcd 配额 1GiB 是容量上限，不是已验收容量；控制平面的不可变记录会增长，须监控数据库大小、告警、内存、磁盘延迟并完成目标负载与 72 小时测试。自动 compaction 只压缩 etcd 历史版本，不删除业务需要的当前记录。不要盲目删除控制键或同时 defrag 三个成员。

## 服务和接口边界

- `/etc/envelope-ha/runtime.json`：业务配置；数据库 `/var/lib/envelope-ha/envelope.sqlite3`，WAL/FULL durability 由业务进程验证。
- `envelope-etcd.service`：2379 客户端和 2380 peer 均强制 mTLS；peer 使用独立 CA；监控只绑定 loopback2381。
- `envelope-ha.service`：只绑定 `127.0.0.1:19093/19094`；Nginx19444 强制客户端证书，并覆盖 `X-Envelope-Peer`，业务程序再核对对端 CN。
- `/v2/`：按 Nginx HTTP 层可见来源 30 请求/秒、突发60、并发8，正文16MiB；禁止缓存和代理自动重试。S1 可按公网 IP 区分；S2 现有443 stream未传递原来源，因此其额度由所有进入9443的用户共享。没有为了此功能改写原代理的 PROXY protocol；不能宣称 S2 已实现公网 IP 独立限流。
- 外部直接连接内部端口必须失败；从 S1/S2 使用正确证书访问对端内部接口必须成功；使用错误角色证书必须失败。

## 备份、失败与回滚

一致快照、显式新 incarnation 重建及 etcd 配置 CAS 激活的具体命令见 [恢复操作手册](recovery.md)。

每个阶段保留被覆盖文件到 `/var/backups/envelope-ha/<时间>-<阶段>/`，目录 root0700。运行时更新先停止 Envelope 自身服务，并用 SQLite backup API 生成一致快照；不会覆盖旧数据库。二进制按时间保留在 `/opt/envelope-ha/releases/`，`current` 原子切换。

```powershell
./scripts/deploy-ha-rbac.ps1 -Bundle $bundle -Action Snapshot -SnapshotPath ./keys/ha-v2-20260920/etcd-before-release.db
```

控制面快照和两个 SQLite 快照必须带各自 applied/commit index、配置 epoch、generation、incarnation 记录；单独快照文件不证明三份状态一致。故障恢复按协议重新验证全部证据。不得把旧 SQLite 直接接回更高控制水位，不得用 `--force-new-cluster` 隐藏丢失的控制记录。坏盘恢复必须使用恢复工具和新的 node incarnation；控制多数永久丢失需要显式灾难恢复、新 generation 和旧 generation 隔离。

代理变更先 `nginx -t`，成功才 reload。脚本在修改前登记 site、snippets、conf.d；失败或普通中断会恢复旧文件、撤销本阶段新建文件和空目录，回滚不 reload。详见 [恢复与失败处理](recovery.md)。脚本不能补救掉电或 SIGKILL，仍须保留阶段备份并在恢复后执行 `nginx -t`。不要重启所有代理来修复单个 include。

新版本已经接收写入后，只能回退到兼容 v2 协议/数据格式的二进制并保留当前数据；不能恢复旧快照抹掉已确认消息。首装失败可停止本次新增 Envelope 单元并恢复本次 Nginx 文件；保留数据库、快照、日志用于调查。防火墙撤销只删除 ENVELOPE_HA 规则链及其入口，不改其他规则。

## 验收证据

已有工程证据、容量/保留限制和待测项目汇总于 [v1.0.1 验证记录](../../../docs/ha-v1.0.1-verification.md)。

进程 healthy、TLS 正确、etcd quorum 都不是端到端交付证明。还需保存真实客户端注册→发送→双副本回执→收取→签名结果→发送者 Delivered 的证据，以及 S1 故障切换、失去两个投票者拒绝权威写入、恢复回补、64MiB 文件完整性、Windows/Android 互通和现有 YourTurn/Xray/Hysteria 无回归。正式 v1.0.1 包生成时间和各二进制 SHA256 应与这些运行实例对应。

参考：[etcd TLS](https://etcd.io/docs/v3.6/op-guide/security/)、[证书 CN 身份与 RBAC](https://etcd.io/docs/v3.6/op-guide/authentication/rbac/)、[快照与维护](https://etcd.io/docs/v3.6/op-guide/maintenance/)。
