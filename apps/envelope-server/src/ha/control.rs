//! Prefix-scoped, linearizable control plane. A successful signature or local
//! keepalive hint never authorizes a write: every mutation fences its etcd Txn.
use anyhow::{Context, Result, bail, ensure};
use envelope_server_core::ha::{ClusterConfigV2, DecimalU64, ServiceMode};
use etcd_client::{
    Client, Compare, CompareOp, ConnectOptions, GetOptions, KeyValue, PutOptions, Txn, TxnOp,
    TxnOpResponse,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    task::JoinHandle,
    time::{MissedTickBehavior, timeout},
};

pub const LEASE_TTL_SECONDS: i64 = 15;
pub const MAX_CONTROL_VALUE_BYTES: usize = 16 * 1024;
pub const MAX_TRANSACTION_BYTES: usize = 128 * 1024;
pub const MAX_TRANSACTION_OPERATIONS: usize = 64;
const RPC_TIMEOUT: Duration = Duration::from_secs(5);
const ENDPOINT_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(2);

/// One channel per origin: tonic's balanced channel can select a disconnected
/// endpoint again after it reports a cached connection error as ready. Prefer
/// the last successful origin, and explicitly fail over within one RPC budget.
#[derive(Clone)]
struct EndpointPool {
    clients: Arc<Vec<Client>>,
    preferred: Arc<AtomicUsize>,
}
impl EndpointPool {
    async fn call<T, F, Fut>(&self, mut operation: F) -> Result<T>
    where
        F: FnMut(Client) -> Fut,
        Fut: Future<Output = std::result::Result<T, etcd_client::Error>>,
    {
        let deadline = tokio::time::Instant::now() + RPC_TIMEOUT;
        let count = self.clients.len();
        let first = self.preferred.load(Ordering::Acquire) % count;
        let mut last_error = None;
        for offset in 0..count {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let index = (first + offset) % count;
            let budget = if offset + 1 == count {
                remaining
            } else {
                remaining.min(ENDPOINT_ATTEMPT_TIMEOUT)
            };
            match timeout(budget, operation(self.clients[index].clone())).await {
                Ok(Ok(response)) => {
                    self.preferred.store(index, Ordering::Release);
                    return Ok(response);
                }
                Ok(Err(error)) if retryable_endpoint_error(&error) => {
                    last_error = Some(anyhow::Error::new(error));
                }
                Ok(Err(error)) => return Err(error.into()),
                Err(_) => last_error = Some(anyhow::anyhow!("etcd endpoint RPC timed out")),
            }
        }
        Err(last_error.unwrap_or_else(|| anyhow::anyhow!("etcd RPC deadline exceeded")))
            .context("all available etcd endpoints failed within the RPC deadline")
    }
    async fn revoke(&self, lease_id: i64) -> Result<()> {
        match self.call(|mut client| async move { client.lease_revoke(lease_id).await }).await {
            Ok(_) => Ok(()),
            // A lost response followed by a retry can observe an already revoked
            // lease. It is safe to treat only this explicit NotFound as success.
            Err(error) if error.downcast_ref::<etcd_client::Error>().is_some_and(|error|
                matches!(error, etcd_client::Error::GRpcStatus(status) if status.code() as i32 == 5)) => Ok(()),
            Err(error) => Err(error),
        }
    }
}
fn retryable_endpoint_error(error: &etcd_client::Error) -> bool {
    match error {
        etcd_client::Error::IoError(_) | etcd_client::Error::TransportError(_) => true,
        // Canonical gRPC codes: Cancelled, DeadlineExceeded, Unavailable.
        // Authorization, quota, malformed requests and other semantic errors
        // remain terminal; endpoint failover never weakens server checks.
        etcd_client::Error::GRpcStatus(status) => matches!(status.code() as i32, 1 | 4 | 14),
        // etcd-client maps EOF before the first lease response to WatchError.
        // No lease was confirmed, so retry the same ID on another origin.
        etcd_client::Error::WatchError(message) => message == "failed to create lease keeper",
        _ => false,
    }
}

#[derive(Clone)]
pub struct Control {
    pool: EndpointPool,
    prefix: String,
    config_bytes: Vec<u8>,
    config: ClusterConfigV2,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlEntry {
    pub value: Vec<u8>,
    pub create_revision: i64,
    pub mod_revision: i64,
    pub lease_id: i64,
}
impl From<&KeyValue> for ControlEntry {
    fn from(kv: &KeyValue) -> Self {
        Self {
            value: kv.value().to_vec(),
            create_revision: kv.create_revision(),
            mod_revision: kv.mod_revision(),
            lease_id: kv.lease(),
        }
    }
}
#[derive(Debug, Clone)]
pub struct ControlSnapshot {
    pub revision: i64,
    pub config: ControlEntry,
    pub leader: Option<ControlEntry>,
    pub ready: Option<ControlEntry>,
    pub head: ControlEntry,
    pub head_index: u64,
    pub entries: BTreeMap<String, ControlEntry>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LeaderValue {
    pub node_id: String,
    pub node_incarnation: String,
    pub session_token: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ReadyValue {
    pub leader_token: String,
    pub applied_index: DecimalU64,
    pub mode: ServiceMode,
}

pub struct LeaderSession {
    pub value: LeaderValue,
    pub term: u64,
    pub lease_id: i64,
    value_bytes: Vec<u8>,
    alive: Arc<AtomicBool>,
    keepalive_task: JoinHandle<()>,
    revoke_pool: EndpointPool,
}
impl LeaderSession {
    /// A negative hint may avoid wasted work. A positive hint is never authority.
    pub fn keepalive_healthy(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }
}
impl Drop for LeaderSession {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
        self.keepalive_task.abort();
        let pool = self.revoke_pool.clone();
        let id = self.lease_id;
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = pool.revoke(id).await;
            });
        }
        // If no runtime/network survives, etcd expiry still fences the session.
    }
}

#[derive(Debug, Clone)]
pub enum Guard {
    Missing(String),
    Value(String, Vec<u8>),
    ModRevision(String, i64),
}
#[derive(Debug, Clone)]
pub enum Change {
    Put(String, Vec<u8>),
    Delete(String),
}
#[derive(Debug, Clone)]
pub struct ScanPage {
    pub entries: BTreeMap<String, ControlEntry>,
    pub more: bool,
    pub revision: i64,
}

impl Control {
    /// `config` must already be administrator-authenticated. Remote endpoints
    /// require HTTPS; plaintext is permitted only on explicit loopback test IPs.
    pub async fn connect(
        endpoints: &[String],
        config: &ClusterConfigV2,
        options: Option<ConnectOptions>,
    ) -> Result<Self> {
        config.validate()?;
        ensure!(
            !endpoints.is_empty(),
            "at least one etcd endpoint is required"
        );
        for endpoint in endpoints {
            let parsed = reqwest::Url::parse(endpoint).context("invalid etcd endpoint")?;
            let loopback = parsed.host_str().is_some_and(|h| {
                h.parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
            });
            ensure!(
                parsed.scheme() == "https" || (parsed.scheme() == "http" && loopback),
                "remote etcd requires mTLS HTTPS"
            );
            ensure!(
                parsed.username().is_empty()
                    && parsed.password().is_none()
                    && parsed.query().is_none()
                    && parsed.fragment().is_none()
                    && parsed.path() == "/",
                "etcd endpoint must be an origin"
            );
        }
        ensure!(
            config
                .cluster_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')),
            "cluster_id must be a safe prefix segment"
        );
        let config_bytes = serde_json::to_vec(config)?;
        ensure!(
            config_bytes.len() <= MAX_CONTROL_VALUE_BYTES,
            "configuration exceeds metadata limit"
        );
        let options = options
            .unwrap_or_default()
            .with_connect_timeout(ENDPOINT_ATTEMPT_TIMEOUT);
        let mut clients = Vec::with_capacity(endpoints.len());
        for endpoint in endpoints {
            clients.push(
                timeout(
                    RPC_TIMEOUT,
                    Client::connect(&[endpoint], Some(options.clone())),
                )
                .await
                .context("etcd connect timed out")??,
            );
        }
        Ok(Self {
            pool: EndpointPool {
                clients: Arc::new(clients),
                preferred: Arc::new(AtomicUsize::new(0)),
            },
            prefix: format!(
                "/envelope/{}/g/{}/",
                config.cluster_id, config.control_generation.0
            ),
            config_bytes,
            config: config.clone(),
        })
    }
    pub fn prefix(&self) -> &str {
        &self.prefix
    }
    fn key(&self, relative: &str) -> Result<String> {
        ensure!(
            !relative.is_empty()
                && relative.len() <= 512
                && !relative.starts_with('/')
                && !relative.ends_with('/')
                && relative
                    .split('/')
                    .all(|s| !s.is_empty() && s != "." && s != "..")
                && relative
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.')),
            "invalid control key"
        );
        Ok(format!("{}{relative}", self.prefix))
    }
    fn mutable_key(&self, relative: &str) -> Result<String> {
        ensure!(
            !matches!(relative, "config" | "leader" | "ready"),
            "reserved control key"
        );
        self.key(relative)
    }
    async fn txn(&self, txn: Txn) -> Result<etcd_client::TxnResponse> {
        // Retry the EXACT transaction. An ambiguous first attempt may have
        // committed: a subsequent false CAS stays false, never a fabricated
        // success. Operation/head guards make the decision recoverable later.
        self.pool
            .call(|mut client| {
                let txn = txn.clone();
                async move { client.txn(txn).await }
            })
            .await
            .context("etcd transaction failed")
    }
    /// New namespaces initialize only while completely empty. Existing partial
    /// or mismatched namespaces fail closed; this never resets a missing head.
    pub async fn initialize(&self) -> Result<()> {
        let range = self
            .pool
            .call(|mut client| {
                let prefix = self.prefix.clone();
                async move {
                    client
                        .get(prefix, Some(GetOptions::new().with_prefix().with_limit(1)))
                        .await
                }
            })
            .await
            .context("initial namespace read failed")?;
        if !range.kvs().is_empty() {
            self.snapshot(&[])
                .await
                .context("existing namespace is incomplete or incompatible")?;
            return Ok(());
        }
        let response = self
            .txn(
                Txn::new()
                    .when(vec![
                        Compare::version(self.key("config")?, CompareOp::Equal, 0),
                        Compare::version(self.key("head")?, CompareOp::Equal, 0),
                        Compare::version(self.key("leader")?, CompareOp::Equal, 0),
                        // Range compare prevents accidental initialization over orphaned
                        // operations written between the read and this transaction.
                        Compare::version(self.prefix.clone(), CompareOp::Equal, 0).with_prefix(),
                    ])
                    .and_then(vec![
                        TxnOp::put(self.key("config")?, self.config_bytes.clone(), None),
                        TxnOp::put(self.key("head")?, b"0".to_vec(), None),
                    ]),
            )
            .await?;
        if !response.succeeded() {
            self.snapshot(&[])
                .await
                .context("concurrent/incomplete namespace initialization")?;
        }
        Ok(())
    }
    /// Every Get in this read-only transaction is linearizable (never
    /// serializable), and all entries come from one control revision.
    pub async fn snapshot(&self, extra_keys: &[&str]) -> Result<ControlSnapshot> {
        ensure!(
            extra_keys.len() + 4 <= MAX_TRANSACTION_OPERATIONS,
            "too many snapshot keys"
        );
        let mut keys: Vec<String> = vec![
            "config".into(),
            "leader".into(),
            "ready".into(),
            "head".into(),
        ];
        for key in extra_keys {
            self.key(key)?;
            ensure!(!keys.iter().any(|v| v == key), "duplicate snapshot key");
            keys.push((*key).into());
        }
        let ops = keys
            .iter()
            .map(|k| Ok(TxnOp::get(self.key(k)?, None)))
            .collect::<Result<Vec<_>>>()?;
        let response = self.txn(Txn::new().and_then(ops)).await?;
        let revision = response
            .header()
            .context("missing etcd revision")?
            .revision();
        let mut entries = BTreeMap::new();
        for (key, response) in keys.into_iter().zip(response.op_responses()) {
            let TxnOpResponse::Get(get) = response else {
                bail!("unexpected snapshot operation");
            };
            if let Some(kv) = get.kvs().first() {
                entries.insert(key, ControlEntry::from(kv));
            }
        }
        let config = entries
            .remove("config")
            .context("missing cluster configuration")?;
        ensure!(
            config.value == self.config_bytes,
            "control configuration changed; reload authenticated config"
        );
        let head = entries
            .remove("head")
            .context("missing head; refusing reset")?;
        let head_index = parse_head(&head.value)?;
        Ok(ControlSnapshot {
            revision,
            config,
            leader: entries.remove("leader"),
            ready: entries.remove("ready"),
            head,
            head_index,
            entries,
        })
    }
    fn session_guards(&self, session: &LeaderSession) -> Result<Vec<Compare>> {
        ensure!(
            session.term > 0 && session.term <= i64::MAX as u64,
            "invalid leader term"
        );
        Ok(vec![
            Compare::value(
                self.key("config")?,
                CompareOp::Equal,
                self.config_bytes.clone(),
            ),
            Compare::create_revision(self.key("leader")?, CompareOp::Equal, session.term as i64),
            Compare::value(
                self.key("leader")?,
                CompareOp::Equal,
                session.value_bytes.clone(),
            ),
            Compare::lease(self.key("leader")?, CompareOp::Equal, session.lease_id),
        ])
    }
    pub async fn try_acquire(
        &self,
        node_id: &str,
        node_incarnation: &str,
        session_token: &str,
    ) -> Result<Option<LeaderSession>> {
        let member = self.config.node(node_id)?;
        ensure!(
            member.node_incarnation == node_incarnation,
            "node incarnation not authorized"
        );
        ensure!(
            session_token.len() >= 16
                && session_token.len() <= 256
                && session_token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')),
            "session token must be an unpredictable bounded token"
        );
        // Read verifies head presence before election. Readiness remains absent
        // until the caller has actually recovered/applied this head.
        self.snapshot(&[]).await?;
        // A lost grant response can leave an unattached lease; its bounded TTL
        // expires it. Only the returned lease is attached to the election CAS.
        let grant = self
            .pool
            .call(|mut client| async move { client.lease_grant(LEASE_TTL_SECONDS, None).await })
            .await
            .context("lease grant failed")?;
        let lease_id = grant.id();
        ensure!(
            grant.ttl() >= LEASE_TTL_SECONDS,
            "etcd granted insufficient lease TTL"
        );
        let value = LeaderValue {
            node_id: node_id.into(),
            node_incarnation: node_incarnation.into(),
            session_token: session_token.into(),
        };
        let value_bytes = serde_json::to_vec(&value)?;
        let acquired = self
            .txn(
                Txn::new()
                    .when(vec![
                        Compare::value(
                            self.key("config")?,
                            CompareOp::Equal,
                            self.config_bytes.clone(),
                        ),
                        Compare::version(self.key("leader")?, CompareOp::Equal, 0),
                        Compare::version(self.key("ready")?, CompareOp::Equal, 0),
                    ])
                    .and_then(vec![TxnOp::put(
                        self.key("leader")?,
                        value_bytes.clone(),
                        Some(PutOptions::new().with_lease(lease_id)),
                    )]),
            )
            .await;
        let response = match acquired {
            Ok(r) => r,
            Err(e) => {
                let _ = self.pool.revoke(lease_id).await;
                return Err(e);
            }
        };
        if !response.succeeded() {
            let _ = self.pool.revoke(lease_id).await;
            return Ok(None);
        }
        let term = u64::try_from(
            response
                .header()
                .context("missing election revision")?
                .revision(),
        )
        .context("invalid election revision")?;
        let alive = Arc::new(AtomicBool::new(true));
        let alive_task = alive.clone();
        let keepalive_pool = self.pool.clone();
        let keepalive_task = tokio::spawn(async move {
            let work = async {
                let mut interval = tokio::time::interval(Duration::from_secs(5));
                interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
                loop {
                    interval.tick().await;
                    // etcd-client consumes and validates the first response
                    // (TTL > 0) before returning. A fresh bounded stream each
                    // renewal can move to a surviving origin; keeping one old
                    // stream pins renewals to a dead endpoint. Dropping these
                    // handles ends that stream, not the renewed lease.
                    let (keeper, _stream) = keepalive_pool
                        .call(|mut client| async move { client.lease_keep_alive(lease_id).await })
                        .await
                        .context("keepalive renewal failed")?;
                    ensure!(keeper.id() == lease_id, "unexpected renewed lease identity");
                }
                #[allow(unreachable_code)]
                Ok::<(), anyhow::Error>(())
            }
            .await;
            alive_task.store(false, Ordering::Release);
            if let Err(error) = work {
                tracing::warn!(%error,"Envelope leader keepalive stopped; authority must be reacquired");
            }
        });
        Ok(Some(LeaderSession {
            value,
            term,
            lease_id,
            value_bytes,
            alive,
            keepalive_task,
            revoke_pool: self.pool.clone(),
        }))
    }
    pub async fn publish_ready(
        &self,
        session: &LeaderSession,
        applied_index: u64,
        mode: ServiceMode,
    ) -> Result<bool> {
        ensure!(
            mode != ServiceMode::Unavailable,
            "cannot publish unavailable readiness"
        );
        let value = ReadyValue {
            leader_token: session.value.session_token.clone(),
            applied_index: applied_index.into(),
            mode,
        };
        let mut guards = self.session_guards(session)?;
        guards.push(Compare::value(
            self.key("head")?,
            CompareOp::Equal,
            applied_index.to_string().into_bytes(),
        ));
        Ok(self
            .txn(Txn::new().when(guards).and_then(vec![TxnOp::put(
                self.key("ready")?,
                serde_json::to_vec(&value)?,
                Some(PutOptions::new().with_lease(session.lease_id)),
            )]))
            .await?
            .succeeded())
    }
    pub async fn withdraw_ready(&self, session: &LeaderSession) -> Result<bool> {
        Ok(self
            .txn(
                Txn::new()
                    .when(self.session_guards(session)?)
                    .and_then(vec![TxnOp::delete(self.key("ready")?, None)]),
            )
            .await?
            .succeeded())
    }
    /// Fresh barrier useful before reads; a second check after reading SQLite
    /// is still required. Successful return is not reusable authorization.
    pub async fn check_authority(
        &self,
        session: &LeaderSession,
        require_ready: bool,
    ) -> Result<ControlSnapshot> {
        let snapshot = self.snapshot(&[]).await?;
        self.validate_session_snapshot(session, &snapshot, require_ready)?;
        Ok(snapshot)
    }
    fn validate_session_snapshot(
        &self,
        session: &LeaderSession,
        snapshot: &ControlSnapshot,
        require_ready: bool,
    ) -> Result<()> {
        let leader = snapshot
            .leader
            .as_ref()
            .context("NOT_LEADER: no active leader")?;
        ensure!(
            leader.value == session.value_bytes
                && leader.create_revision == session.term as i64
                && leader.lease_id == session.lease_id,
            "NOT_LEADER: expired or replaced session"
        );
        if require_ready {
            let ready = snapshot.ready.as_ref().context("NOT_READY")?;
            let value: ReadyValue = serde_json::from_slice(&ready.value)?;
            ensure!(
                value.leader_token == session.value.session_token
                    && ready.lease_id == session.lease_id
                    && value.mode != ServiceMode::Unavailable
                    && value.applied_index.0 <= snapshot.head_index,
                "NOT_READY: invalid ready session"
            );
        }
        Ok(())
    }
    /// Only metadata goes here. The coordinator must validate two durable
    /// preparations before requesting a business decision. No raw client Txn
    /// operations are accepted and leader/config/ready mutations are reserved.
    pub async fn guarded_txn(
        &self,
        session: &LeaderSession,
        require_ready: bool,
        guards: &[Guard],
        changes: &[Change],
    ) -> Result<bool> {
        ensure!(!changes.is_empty(), "empty mutation transaction");
        ensure!(
            guards.len() + changes.len() + 6 <= MAX_TRANSACTION_OPERATIONS,
            "control transaction exceeds operation limit"
        );
        let mut compares = self.session_guards(session)?;
        // Include conservative protobuf/key overhead so guards count toward
        // the cap as well as values. Bound keys before any network request.
        let mut bytes =
            self.config_bytes.len() + session.value_bytes.len() + 6 * (self.prefix.len() + 64);
        if require_ready {
            let snapshot = self.check_authority(session, true).await?;
            let ready = snapshot.ready.context("NOT_READY")?;
            compares.push(Compare::mod_revision(
                self.key("ready")?,
                CompareOp::Equal,
                ready.mod_revision,
            ));
            compares.push(Compare::value(
                self.key("ready")?,
                CompareOp::Equal,
                ready.value.clone(),
            ));
            bytes += ready.value.len() + 2 * (self.prefix.len() + 64);
        }
        for guard in guards {
            match guard {
                Guard::Missing(key) => {
                    let key = self.key(key)?;
                    bytes += key.len() + 64;
                    compares.push(Compare::version(key, CompareOp::Equal, 0));
                }
                Guard::Value(key, value) => {
                    ensure!(
                        value.len() <= MAX_CONTROL_VALUE_BYTES,
                        "guard value too large"
                    );
                    let key = self.key(key)?;
                    bytes += key.len() + value.len() + 64;
                    compares.push(Compare::value(key, CompareOp::Equal, value.clone()));
                }
                Guard::ModRevision(key, revision) => {
                    ensure!(*revision > 0, "invalid guard revision");
                    let key = self.key(key)?;
                    bytes += key.len() + 64;
                    compares.push(Compare::mod_revision(key, CompareOp::Equal, *revision));
                }
            }
        }
        let mut unique = BTreeSet::new();
        let mut operations = Vec::new();
        for change in changes {
            match change {
                Change::Put(key, value) => {
                    ensure!(unique.insert(key), "duplicate mutation key");
                    let key = self.mutable_key(key)?;
                    ensure!(
                        value.len() <= MAX_CONTROL_VALUE_BYTES,
                        "control value exceeds 16 KiB"
                    );
                    bytes += key.len() + value.len() + 64;
                    operations.push(TxnOp::put(key, value.clone(), None));
                }
                Change::Delete(key) => {
                    ensure!(unique.insert(key), "duplicate mutation key");
                    let key = self.mutable_key(key)?;
                    bytes += key.len() + 64;
                    operations.push(TxnOp::delete(key, None));
                }
            }
        }
        ensure!(
            bytes <= MAX_TRANSACTION_BYTES,
            "control transaction exceeds byte limit"
        );
        Ok(self
            .txn(Txn::new().when(compares).and_then(operations))
            .await?
            .succeeded())
    }
    pub async fn release(&self, session: &LeaderSession) -> Result<()> {
        session.alive.store(false, Ordering::Release);
        session.keepalive_task.abort();
        self.pool.revoke(session.lease_id).await?;
        Ok(())
    }
    pub async fn scan_prefix(
        &self,
        relative: &str,
        after: Option<&str>,
        limit: u32,
    ) -> Result<ScanPage> {
        ensure!((1..=1000).contains(&limit), "scan limit must be 1..1000");
        let prefix = format!("{}/", self.key(relative)?);
        let (start, options) = if let Some(after) = after {
            let mut key = self.key(after)?.into_bytes();
            ensure!(
                key.starts_with(prefix.as_bytes()),
                "scan cursor outside prefix"
            );
            key.push(0);
            let mut end = prefix.as_bytes().to_vec();
            *end.last_mut().context("empty prefix")? += 1;
            (
                key,
                GetOptions::new()
                    .with_range(end)
                    .with_limit(i64::from(limit)),
            )
        } else {
            (
                prefix.as_bytes().to_vec(),
                GetOptions::new().with_prefix().with_limit(i64::from(limit)),
            )
        };
        let response = self
            .pool
            .call(|mut client| {
                let start = start.clone();
                let options = options.clone();
                async move { client.get(start, Some(options)).await }
            })
            .await
            .context("control scan failed")?;
        let mut entries = BTreeMap::new();
        for kv in response.kvs() {
            let key = kv
                .key_str()?
                .strip_prefix(&self.prefix)
                .context("returned key outside namespace")?;
            entries.insert(key.to_owned(), ControlEntry::from(kv));
        }
        Ok(ScanPage {
            entries,
            more: response.more(),
            revision: response
                .header()
                .context("missing scan revision")?
                .revision(),
        })
    }
    pub async fn read_prefix(&self, relative: &str) -> Result<BTreeMap<String, ControlEntry>> {
        let page = self.scan_prefix(relative, None, 1000).await?;
        ensure!(!page.more, "control prefix requires pagination");
        Ok(page.entries)
    }
}
fn parse_head(bytes: &[u8]) -> Result<u64> {
    let text = std::str::from_utf8(bytes)?;
    ensure!(
        !text.is_empty()
            && (text.len() == 1 || !text.starts_with('0'))
            && text.bytes().all(|b| b.is_ascii_digit()),
        "invalid control head encoding"
    );
    text.parse().context("control head overflow")
}

#[cfg(test)]
#[path = "control_tests.rs"]
mod tests;
