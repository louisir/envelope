# HA v2 快照、坏盘重建与配置激活

`envelope-ha-recovery` 使用 SQLite `VACUUM INTO` 生成一致快照，再读取成品自己的 applied index、全部 decision/payload 哈希和对象状态根。源库可以继续写入；不要直接复制运行中的 `.sqlite3` 或 WAL 文件。快照包含签名 manifest、对应管理员签名配置和完整历史配置。实现依据 [SQLite VACUUM INTO](https://www.sqlite.org/lang_vacuum.html)。

## 备份和校验

以下是 Linux 部署示例；路径必须替换为实际的配置、数据库和全新备份目录。管理员公钥从已固定的 runtime 配置读取，不能从收到的快照自行取信。

```bash
RECOVERY=/opt/envelope-ha/current/envelope-ha-recovery
ADMIN_PUBLIC=$(python3 -c 'import json; print(json.load(open("/etc/envelope-ha/runtime.json"))["administrator_public"])')
SNAPSHOT=/var/backups/envelope-ha/snapshot-20260920-S2
"$RECOVERY" backup \
  --source-db /var/lib/envelope-ha/envelope.sqlite3 \
  --snapshot-dir "$SNAPSHOT" \
  --cluster-config /etc/envelope-ha/cluster.json \
  --administrator-public "$ADMIN_PUBLIC" \
  --signing-secret-file /etc/envelope-ha/signing-secret
"$RECOVERY" verify --snapshot-dir "$SNAPSHOT" --administrator-public "$ADMIN_PUBLIC"
```

有历史提交时，每份旧配置加一个 `--archived-config /etc/envelope-ha/history/cluster-epoch-N.json`。即使旧配置的发现有效期已经结束，旧签名仍须验证。缺少历史配置的快照不能通过校验。备份目录必须不存在；失败留下的无 manifest/不完整目录不能当成有效备份。签名私钥只通过文件读取，不放入命令行或日志。

## 同一 control generation 内重建

1. 保留当前控制面快照、签名配置历史和至少一个已校验业务快照。先生成业务快照，再签署新配置。
2. 停止 **S1 和 S2 的 `envelope-ha.service`**，保留三台 etcd 运行。排除旧进程自动重启，并确认 leader/ready 的租约键消失。不能只等待一个固定秒数就假定安全。
3. 在离线管理机创建新的管理员签名 `ClusterConfigV2`：cluster ID、control generation、两个业务节点 ID 和三个投票者不变；config epoch 严格增加；被重建节点使用全新 `node_incarnation`。换签名密钥时同时更新其公钥。保存旧配置到两台 runtime 的 `archived_configs`。
4. 将快照复制到目标机，使用固定管理员公钥执行 `verify`，然后恢复到**不存在的新数据库路径**：

```bash
"$RECOVERY" restore \
  --snapshot-dir /var/backups/envelope-ha/snapshot-20260920-S2 \
  --destination-db /var/lib/envelope-ha/rebuilt-epoch-2.sqlite3 \
  --cluster-config /etc/envelope-ha/cluster-epoch-2.json \
  --administrator-public "$ADMIN_PUBLIC" \
  --target-node-id s1
```

工具保留原 applied index、terminal 状态、所有 prepare/decision，仅重写新节点身份；已运行的目标锁、已有目标文件、复用 incarnation、未增加 epoch 或跨 generation 恢复全部拒绝。跨 generation 灾难恢复尚须单独设计/执行控制记录迁移，不能靠这个命令或 `--force-new-cluster` 绕过。

## 原子激活新配置（维护窗口）

只替换磁盘 `cluster.json` 不会激活配置：运行时会检查 etcd 中的配置字节，并拒绝不同版本。下列步骤只适用于上面的、已通过恢复工具验签的同 generation 重建。不得用应用节点证书修改保留的 `config` 键。

管理机使用 etcd **管理身份**和 gRPC `etcdctl`，保持 CA/主机名验证；不使用 HTTP gateway 代替证书 CN 身份验证。设置实际 `ETCDCTL_ENDPOINTS`、`ETCDCTL_CACERT`、`ETCDCTL_CERT`、`ETCDCTL_KEY`，不在输出中记录私钥内容。例如，通过有授权的 SSH 隧道访问证书允许的 `https://127.0.0.1:<端口>`。下面的 Python 步骤只读控制面并写一个待审核事务文件，尚不提交：

```bash
python3 - old-cluster.json new-cluster.json activation.txn <<'PY'
import base64, json, pathlib, subprocess, sys
old = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
new = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8'))
assert old['cluster_id'] == new['cluster_id']
assert old['control_generation'] == new['control_generation']
assert int(new['config_epoch']) > int(old['config_epoch'])
assert old['control_node_ids'] == new['control_node_ids']
assert [n['node_id'] for n in old['business_nodes']] == [n['node_id'] for n in new['business_nodes']]
assert any(a['node_incarnation'] != b['node_incarnation'] for a,b in zip(old['business_nodes'],new['business_nodes']))
prefix = '/envelope/' + old['cluster_id'] + '/g/' + old['control_generation'] + '/'
def get(key):
    result = subprocess.run(['etcdctl','--write-out=json','get',prefix+key],check=True,capture_output=True,text=True)
    rows = json.loads(result.stdout).get('kvs',[])
    assert len(rows) == 1, 'missing/ambiguous control key: '+key
    return rows[0]
config, head = get('config'), get('head')
assert json.loads(base64.b64decode(config['value'])) == old, 'old config does not match control'
assert base64.b64decode(head['value']).decode('ascii').isdigit(), 'bad control head'
# Match Rust typed DTO serialization exactly; input JSON member order is irrelevant.
fields = ['protocol_version','cluster_id','control_generation','config_epoch','business_nodes','control_node_ids','issued_at','not_after','signature']
node_fields = ['node_id','public_url','signing_public','node_incarnation']
assert set(new) == set(fields)
assert all(set(n) == set(node_fields) for n in new['business_nodes'])
new = {k:new[k] for k in fields}
new['business_nodes'] = [{k:n[k] for k in node_fields} for n in new['business_nodes']]
wire = json.dumps(new,ensure_ascii=False,separators=(',',':'))
assert len(wire.encode()) <= 16384
q = lambda s: json.dumps(s,ensure_ascii=False)
checks = [
    'mod('+q(prefix+'config')+') = '+q(str(config['mod_revision'])),
    'mod('+q(prefix+'head')+') = '+q(str(head['mod_revision'])),
    'version('+q(prefix+'leader')+') = "0"',
    'version('+q(prefix+'ready')+') = "0"',
]
transaction = '\n'.join(checks)+'\n\nput '+q(prefix+'config')+' '+q(wire)+'\n\n\n'
with open(sys.argv[3],'x',encoding='utf-8',newline='\n') as output:
    output.write(transaction)
print('Prepared config-only CAS transaction; head and decision records are unchanged.')
PY
```

审核 `activation.txn` 中的 cluster ID、epoch、两个新旧身份和唯一 `put .../config` 后，用同一管理员环境提交：

```bash
etcdctl --write-out=json txn < activation.txn > activation-result.json
python3 -c 'import json; assert json.load(open("activation-result.json")).get("succeeded") is True, "Activation failed: inspect live state before retrying"'
```

该事务同时比较旧 config 修改 revision、head 修改 revision、leader/ready 不存在；任一变化会使事务失败而不写入。不会修改/归零 head、decision、object、attempt、lease 或 gc floor。CAS 原理及命令语法见 [etcd 事务 API](https://etcd.io/docs/v3.6/learning/api/) 和 [etcdctl txn](https://github.com/etcd-io/etcd/blob/v3.6.14/etcdctl/README.md#txn-options)。本地三节点测试验证了事务成功写入的确切 JSON 字节，以及 leader 存在和旧 revision 重放被拒绝。

5. 两台业务 runtime 都指向相同的新签名配置，包含完整 `archived_configs`；重建节点的 `database` 指向刚生成的新路径。更新所需文件权限为服务账户可读写，并保留旧数据目录。
6. 启动两台业务服务，核对返回的新 config epoch/incarnation；落后的节点必须从保留的 decision 和 payload 回补到线性一致 head，才允许 ready。再次执行存储→双副本 receipt→收取→收件人签名结果→发送者终态验收。

## 代理配置回滚与备用入口限流

`install-node.sh` 的 proxy 阶段会在写入前逐一记录目标 site、include 和 conf.d 文件；原有文件保留内容、权限和符号链接，新建文件记录为本阶段所有。任何失败或正常可捕获的中断都会恢复记录中的原文件，并只移除本阶段登记的新文件及仍为空的新目录。验证失败不会 reload，回滚也不会 reload；成功验证并 reload 后才解除回滚 trap。备份保留在该阶段的 `proxy-journal` 目录。SIGKILL、断电以及回滚过程中出现的磁盘故障仍需根据该目录人工恢复，不能当作自动恢复完成。

S2 的公共 443 经现有 Nginx stream 转发到 `127.0.0.1:9443`，未传递 PROXY protocol，HTTP 层看到的是本地代理地址。因此当前 `/v2/` 的 30 请求/秒、突发 60、8 并发限制在 S2 上是共享额度，不是真实公网 IP 的独立额度。现有 YourTurn/Xray stream 协议保持原样，不能直接全局启用 PROXY protocol 来改变此行为。

## 当前 GC 边界

`seal_and_collect` 只回收被当前 leader 通过控制面 CAS 封存、未被 staged/committed 引用的 prepare；本地时间或本地文件年龄不是授权。`register_checkpoint` 只有在两个当前业务身份签名的快照具有相同 applied index、decision chain 根和 object state 根时，才推进 `checkpoint_floor`。

**本版本不删除 committed payload、decision 或 terminal tombstone，也不推进 `gc_floor`。** checkpoint 注册本身不等于允许裁剪；需要后续完成经验证的检查点存储、恢复覆盖范围和客户端重试保留策略后才能开启。这意味着磁盘使用会持续增长，应按实际负载监测容量。控制多数丢失期间拒绝权威写入；不能为了 GC 或恢复而绕过多数证明。

## 已执行验证

- core 协议 28 项：包含签名域、严格整数/重复字段、配置历史、独立过期双 ack、TTL 与终态规则。
- recovery 4 项：在线 WAL 与并发写入一致快照、成品水位/terminal/孤立 prepare 恢复，篡改和身份/运行锁/覆盖拒绝，历史配置证明，真实三节点 etcd CAS GC 与双快照 checkpoint。
- recovery CLI 已构建并对含历史配置的实际测试快照执行 `verify` 成功；被篡改快照实际返回 hash/length mismatch。
- 控制面已有真实三节点 fencing/租约/多数丢失测试；这些工程证据不替代生产磁盘故障和双端客户端验收。
