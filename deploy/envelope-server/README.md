# Envelope Server 部署说明

状态说明（2026-09-20）：下文对应现有 v1/MVP。首版主备目标及 etcd + 双 SQLite 的选型见 [主设计第 16 节](../../docs/design.md#16-首版主备实现设计--first-release-ha-implementation-design) 和 [主备协议](../../docs/relay-ha-protocol.md)，尚未实现。执行本文件的现有脚本不会自动获得双副本确认、仲裁或 v2 自动接管；新部署脚本与故障验证须随实现交付。

目标环境：可公网访问的 VPS，Ubuntu / Debian 系发行版。

当前部署的是 Envelope Server MVP：HTTPS 入口后面挂一个本机 `envelope-server` 服务，SQLite 数据保存在 `/var/lib/envelope-server/envelope-server.sqlite3`。服务器只保存签名 endpoint 和 opaque envelope bytes，不解密消息。

默认启用最小反滥用保护：`/v1/envelopes` 必须由已注册过 device route 的 sender 签名提交；服务端限制单 envelope 大小、单邮箱容量、全局 mailbox 容量、单 sender / 单源 IP 每分钟提交数量，并显式设置 HTTP body limit。

## 1. VPS 准备

VPS 控制台安全组 / 防火墙需要放行：

```text
TCP 80
TCP 443
```

VPS 系统内如果启用 `ufw`：

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

如果要走公网 HTTPS，先把域名 A 记录指向 VPS 公网 IP，并安装 Caddy：

```bash
sudo apt install -y caddy
```

安装基础依赖：

```bash
sudo apt update
sudo apt install -y ca-certificates curl build-essential pkg-config libssl-dev sqlite3
```

安装 Rust：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
```

## 2. 构建服务端

在 VPS 上拉取仓库后执行：

```bash
cargo build --release -p envelope-server
```

确认二进制存在：

```bash
./target/release/envelope-server --help
./target/release/envelope-server-admin --help
```

常用反滥用参数可按需覆盖：

```bash
./target/release/envelope-server \
  --bind 127.0.0.1:19093 \
  --database target/envelope-server/envelope-server.sqlite3 \
  --max-envelope-bytes 8388608 \
  --max-mailbox-envelopes 1000 \
  --max-mailbox-bytes 268435456 \
  --max-global-mailbox-bytes 1073741824 \
  --max-submit-per-sender-per-minute 60 \
  --max-submit-per-ip-per-minute 120
```

这些限制是单实例基础保护；公网 HTTPS 前面仍建议让 Caddy / 防火墙承担基础连接限速和异常流量过滤。

### 2.1 多入口节点池配置

服务端现在可以加载签名 `NodeSetManifest` 并提供节点身份 challenge。该能力用于多入口 MVP：客户端连上任意入口节点后可拉取节点池，并验证当前 URL 背后的服务确实持有 manifest 中声明的节点密钥。

运行时配置项：

```text
ENVELOPE_SERVER_NODE_MANIFEST=/etc/envelope-server/nodes.manifest.json
ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY=<base64url Ed25519 manifest signing public key>
ENVELOPE_SERVER_NODE_ID=<manifest 中当前 VPS 的 node_id>
ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE=/etc/envelope-server/node-signing-secret
```

对应命令行参数：

```bash
./target/release/envelope-server \
  --bind 127.0.0.1:19093 \
  --database target/envelope-server/envelope-server.sqlite3 \
  --node-manifest /etc/envelope-server/nodes.manifest.json \
  --manifest-public-key '<base64url Ed25519 manifest signing public key>' \
  --node-id node-a-primary \
  --node-signing-secret-file /etc/envelope-server/node-signing-secret
```

启动时会执行这些检查：

```text
nodes.manifest.json 必须能被 ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY 验签
manifest 必须未过期，且至少包含一个节点
如果配置了 node_id 和节点私钥，node_id 必须存在于 manifest
节点私钥推导出的 public key 必须等于 manifest 中该 node_id 的 public_key
检查失败时服务拒绝启动
```

`nodes.manifest.json` 格式：

```json
{
  "version": 1,
  "manifest_id": "manifest-20260705-001",
  "epoch": 1,
  "valid_from_unix_ms": 1783180800000,
  "valid_until_unix_ms": 1785782800000,
  "prev_manifest_hash": null,
  "nodes": [
    {
      "node_id": "node-a-primary",
      "base_url": "https://node-a.example.com",
      "public_key": "<base64url Ed25519 node public key>",
      "capabilities": ["route", "mailbox", "intro"],
      "weight": 100,
      "region": "primary",
      "valid_until_unix_ms": 1785782800000
    },
    {
      "node_id": "node-b-fallback",
      "base_url": "https://node-b.example.com",
      "public_key": "<base64url Ed25519 node public key>",
      "capabilities": ["route", "mailbox", "intro"],
      "weight": 50,
      "region": "fallback",
      "valid_until_unix_ms": 1785782800000
    }
  ],
  "revoked_node_ids": [],
  "signature": "<base64url Ed25519 manifest signature>"
}
```

生成 manifest signing key 和节点 signing key：

```bash
./target/release/envelope-server-admin generate-signing-key \
  --secret-out ./secrets/manifest-signing-secret

./target/release/envelope-server-admin generate-signing-key \
  --secret-out ./secrets/node-a-signing-secret

./target/release/envelope-server-admin generate-signing-key \
  --secret-out ./secrets/node-b-signing-secret

./target/release/envelope-server-admin public-key \
  --signing-secret-file ./secrets/manifest-signing-secret

./target/release/envelope-server-admin public-key \
  --signing-secret-file ./secrets/node-a-signing-secret

./target/release/envelope-server-admin public-key \
  --signing-secret-file ./secrets/node-b-signing-secret
```

先把上面得到的 node public key 写入 unsigned manifest，再签名：

```bash
./target/release/envelope-server-admin sign-manifest \
  --manifest ./nodes.manifest.unsigned.json \
  --signing-secret-file ./secrets/manifest-signing-secret \
  --out ./nodes.manifest.json
```

节点私钥文件只放 base64url Ed25519 32 字节 signing secret，不写 JSON，不放进环境变量。建议权限：

```bash
sudo install -o root -g envelope-server -m 0640 node-signing-secret /etc/envelope-server/node-signing-secret
```

## 3. 安装 systemd 服务

只安装本机 HTTP 服务，不配置公网域名：

```bash
sudo bash ./deploy/envelope-server/install-ubuntu.sh
```

带 Caddy 域名反代：

```bash
# A: primary 入口
sudo ENVELOPE_SERVER_DOMAIN=node-a.example.com bash ./deploy/envelope-server/install-ubuntu.sh

# B: fallback 入口
sudo ENVELOPE_SERVER_DOMAIN=node-b.example.com bash ./deploy/envelope-server/install-ubuntu.sh
```

可覆盖变量：

```bash
sudo \
  ENVELOPE_SERVER_BIND=127.0.0.1:19093 \
  ENVELOPE_SERVER_DATABASE=/var/lib/envelope-server/envelope-server.sqlite3 \
  ENVELOPE_SERVER_DOMAIN=node-a.example.com \
  ENVELOPE_SERVER_NODE_MANIFEST=/etc/envelope-server/nodes.manifest.json \
  ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY='<base64url Ed25519 manifest signing public key>' \
  ENVELOPE_SERVER_NODE_ID=node-a-primary \
  ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE=/etc/envelope-server/node-signing-secret \
  bash ./deploy/envelope-server/install-ubuntu.sh
```

B 节点使用同一 manifest 和 manifest public key，但把 `ENVELOPE_SERVER_DOMAIN` 改为 `node-b.example.com`，`ENVELOPE_SERVER_NODE_ID` 改为 `node-b-fallback`，并安装 B 节点自己的 signing secret。

脚本会：

```text
创建 envelope-server 系统用户
安装 /opt/envelope-server/envelope-server
写入 /etc/envelope-server/envelope-server.env
安装 /etc/systemd/system/envelope-server.service
启动并 enable envelope-server
如果设置 ENVELOPE_SERVER_DOMAIN 且系统已有 Caddy，则写入 /etc/caddy/conf.d/envelope-server.caddy 并 reload Caddy
```

## 4. 验证

本机服务：

```bash
curl http://127.0.0.1:19093/health
curl http://127.0.0.1:19093/v1/nodes/manifest
```

公网 HTTPS：

```bash
curl https://node-a.example.com/health
curl https://node-a.example.com/v1/nodes/manifest

curl https://node-b.example.com/health
curl https://node-b.example.com/v1/nodes/manifest
```

节点身份 challenge：

```bash
now_ms="$(date +%s%3N)"
challenge="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
curl -sS https://node-a.example.com/v1/node/challenge \
  -H 'content-type: application/json' \
  -d "{\"version\":1,\"node_id\":\"node-a-primary\",\"challenge_b64\":\"$challenge\",\"requested_at_unix_ms\":$now_ms}"

now_ms="$(date +%s%3N)"
challenge="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
curl -sS https://node-b.example.com/v1/node/challenge \
  -H 'content-type: application/json' \
  -d "{\"version\":1,\"node_id\":\"node-b-fallback\",\"challenge_b64\":\"$challenge\",\"requested_at_unix_ms\":$now_ms}"
```

查看日志：

```bash
sudo systemctl status envelope-server --no-pager
sudo journalctl -u envelope-server -f
```

## 5. Android 集成测试入口

如果先用本机 Windows 开发机跑 `envelope-server`，真机调试可用：

```powershell
adb reverse tcp:19093 tcp:19093
```

然后 App 或 ADB bridge 使用：

```text
http://127.0.0.1:19093
```

VPS 部署完成后，App 或 ADB bridge 使用：

```text
https://node-a.example.com
https://node-b.example.com
```

当前 Android 客户端内置 `https://node-a.example.com` 和 `https://node-b.example.com` 两个 bootstrap URL；客户端会从可达入口刷新同一份 signed manifest，并按节点健康状态和权重自动切换。

推荐集成测试顺序：

```text
A 端 serverRegister
B 端 serverRegister
A 端 serverSendText
B 端 serverPullMailbox
B 端确认消息解密入库
B 端再次 serverPullMailbox，确认 ACK 后不重复拉取
```

ADB bridge 命令可带 `server_url` 参数覆盖 UI 里的服务器地址。

## 6. 更新服务端

重新构建后再次运行安装脚本即可：

```bash
cargo build --release -p envelope-server

# A 节点上运行
sudo ENVELOPE_SERVER_DOMAIN=node-a.example.com bash ./deploy/envelope-server/install-ubuntu.sh

# B 节点上运行
sudo ENVELOPE_SERVER_DOMAIN=node-b.example.com bash ./deploy/envelope-server/install-ubuntu.sh
```

脚本会替换 `/opt/envelope-server/envelope-server` 并重启服务。
