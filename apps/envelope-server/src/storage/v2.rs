//! Durable preparation and ordered application for HA v2.
//!
//! A local prepare is NEVER a commit. Only the coordinator, after checking an
//! authoritative control decision and its replica evidence, may call `apply`.
//! This module deliberately has no timeout-based prepare cleanup or v1 fallback.
use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool, sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous}};
use std::{fs::{File, OpenOptions}, path::{Path, PathBuf}, sync::Arc, time::Duration};

pub const MAX_PREPARED_BYTES: usize = 12 * 1024 * 1024;
const SCHEMA_VERSION: i64 = 2;

#[path = "v2_snapshot.rs"]
mod snapshot;
pub use snapshot::{SnapshotContents, create_sqlite_snapshot, inspect_snapshot, read_snapshot_decisions, rewrite_restored_identity, snapshot_file_digest};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DatabaseIdentity {
    pub cluster_id: String,
    pub control_generation: u64,
    pub node_id: String,
    pub node_incarnation: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ObjectChange {
    pub key: String,
    pub kind: String,
    pub expected_version: u64,
    /// A compact terminal record is kept even after its body is reclaimed.
    pub terminal: bool,
    #[serde(with = "utf8_bytes")]
    pub value: Vec<u8>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PreparedOperation {
    pub cluster_id: String,
    pub control_generation: u64,
    pub config_epoch: u64,
    pub leader_term: u64,
    pub attempt_id: String,
    pub actor_id: String,
    pub operation_id: String,
    pub logical_hash: String,
    /// Original, signed authorization bytes, verified by both coordinators.
    #[serde(with = "utf8_bytes")]
    pub authorization: Vec<u8>,
    /// Exact decoded request body. Keep ciphertext once, outside etcd metadata.
    #[serde(with = "utf8_bytes")]
    pub request_body: Vec<u8>,
    pub changes: Vec<ObjectChange>,
}

impl PreparedOperation {
    pub fn encoded(&self) -> Result<Vec<u8>> {
        ensure!(!self.cluster_id.is_empty() && self.control_generation > 0
            && self.config_epoch > 0 && self.leader_term > 0, "invalid prepare scope");
        for id in [&self.attempt_id, &self.actor_id, &self.operation_id] {
            ensure!(!id.is_empty() && id.len() <= 256, "invalid prepare identifier");
        }
        let hash = envelope_core::decode_bytes(&self.logical_hash, "logical_hash")?;
        ensure!(hash.len() == 32 && envelope_core::encode_bytes(&hash) == self.logical_hash, "invalid logical hash");
        ensure!(!self.authorization.is_empty(), "missing authorization");
        ensure!(!self.changes.is_empty() && self.changes.len() <= 8, "invalid object count");
        let mut seen = std::collections::HashSet::new();
        for change in &self.changes {
            ensure!(!change.key.is_empty() && change.key.len() <= 256
                && !change.kind.is_empty() && change.kind.len() <= 64, "invalid object identity");
            ensure!(seen.insert(&change.key), "duplicate object change");
            ensure!(change.expected_version < i64::MAX as u64, "object version overflow");
        }
        let bytes = serde_json::to_vec(self)?;
        ensure!(bytes.len() <= MAX_PREPARED_BYTES, "prepare exceeds size limit");
        Ok(bytes)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommitDecision {
    pub cluster_id: String,
    pub control_generation: u64,
    pub commit_index: u64,
    pub attempt_id: String,
    pub payload_hash: String,
    /// Canonical verified control decision bytes, including both signed acks.
    pub evidence: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredObject {
    pub key: String,
    pub kind: String,
    pub version: u64,
    pub terminal: bool,
    pub value: Vec<u8>,
}

#[derive(Clone)]
pub struct V2Store {
    pool: SqlitePool,
    identity: DatabaseIdentity,
    // Closing the pool does not release the process lock while clones survive.
    _directory_lock: Arc<File>,
    path: PathBuf,
}

impl V2Store {
    pub async fn open(path: &Path, identity: DatabaseIdentity) -> Result<Self> {
        ensure!(identity.control_generation > 0 && !identity.cluster_id.is_empty()
            && !identity.node_id.is_empty() && !identity.node_incarnation.is_empty(), "invalid database identity");
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let lock = OpenOptions::new().create(true).truncate(false).read(true).write(true)
            .open(path.with_extension("v2.lock"))?;
        lock.try_lock_exclusive().context("v2 database already owned by another process")?;
        let options = SqliteConnectOptions::new().filename(path).create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal).synchronous(SqliteSynchronous::Full)
            .foreign_keys(true).busy_timeout(Duration::from_secs(5));
        let pool = SqlitePoolOptions::new().max_connections(1).connect_with(options).await?;
        let existing: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .fetch_one(&pool).await?;
        let has_meta: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ha_meta'")
            .fetch_one(&pool).await?;
        ensure!(existing == 0 || has_meta == 1, "refusing to open a non-v2 database");
        let mut tx = pool.begin().await?;
        sqlx::raw_sql(SCHEMA).execute(&mut *tx).await?;
        let identity_json = serde_json::to_string(&identity)?;
        sqlx::query("INSERT INTO ha_meta(singleton,schema_version,identity_json,applied_index) VALUES(1,?,?,0) ON CONFLICT(singleton) DO NOTHING")
            .bind(SCHEMA_VERSION).bind(&identity_json).execute(&mut *tx).await?;
        let meta = sqlx::query("SELECT schema_version,identity_json FROM ha_meta WHERE singleton=1")
            .fetch_one(&mut *tx).await?;
        ensure!(meta.get::<i64,_>("schema_version") == SCHEMA_VERSION, "unsupported v2 database schema");
        let stored: DatabaseIdentity = serde_json::from_str(meta.get("identity_json"))?;
        ensure!(stored == identity, "database scope/incarnation mismatch; explicit recovery required");
        tx.commit().await?;
        let store = Self { pool, identity, _directory_lock: Arc::new(lock), path: path.to_path_buf() };
        store.verify_durability().await?;
        Ok(store)
    }

    pub fn path(&self) -> &Path { &self.path }
    pub fn identity(&self) -> &DatabaseIdentity { &self.identity }

    pub async fn verify_durability(&self) -> Result<()> {
        let journal: String = sqlx::query_scalar("PRAGMA journal_mode").fetch_one(&self.pool).await?;
        let synchronous: i64 = sqlx::query_scalar("PRAGMA synchronous").fetch_one(&self.pool).await?;
        let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys").fetch_one(&self.pool).await?;
        ensure!(journal.eq_ignore_ascii_case("wal") && synchronous == 2 && foreign_keys == 1,
            "v2 requires WAL, synchronous=FULL, foreign_keys=ON");
        Ok(())
    }

    pub async fn applied_index(&self) -> Result<u64> {
        let value: i64 = sqlx::query_scalar("SELECT applied_index FROM ha_meta WHERE singleton=1")
            .fetch_one(&self.pool).await?;
        Ok(u64::try_from(value)?)
    }

    pub async fn prepare(&self, operation: &PreparedOperation) -> Result<String> {
        ensure!(operation.cluster_id == self.identity.cluster_id
            && operation.control_generation == self.identity.control_generation, "prepare scope mismatch");
        let bytes = operation.encoded()?;
        let hash = digest(&bytes);
        let mut tx = self.pool.begin().await?;
        let existing: Option<String> = sqlx::query_scalar("SELECT payload_hash FROM ha_prepared WHERE attempt_id=?")
            .bind(&operation.attempt_id).fetch_optional(&mut *tx).await?;
        if let Some(existing) = existing {
            ensure!(existing == hash, "attempt id conflict");
            tx.commit().await?;
            return Ok(hash);
        }
        let committed: Option<String> = sqlx::query_scalar("SELECT logical_hash FROM ha_applied WHERE actor_id=? AND operation_id=?")
            .bind(&operation.actor_id).bind(&operation.operation_id).fetch_optional(&mut *tx).await?;
        if let Some(committed) = committed { ensure!(committed == operation.logical_hash, "operation id conflict"); }
        sqlx::query("INSERT INTO ha_payloads(payload_hash,bytes) VALUES(?,?) ON CONFLICT(payload_hash) DO NOTHING")
            .bind(&hash).bind(bytes).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO ha_prepared(attempt_id,payload_hash,actor_id,operation_id,logical_hash) VALUES(?,?,?,?,?)")
            .bind(&operation.attempt_id).bind(&hash).bind(&operation.actor_id).bind(&operation.operation_id)
            .bind(&operation.logical_hash).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(hash)
    }

    pub async fn prepared_bytes(&self, payload_hash: &str) -> Result<Option<Vec<u8>>> {
        let bytes: Option<Vec<u8>> = sqlx::query_scalar("SELECT bytes FROM ha_payloads WHERE payload_hash=?")
            .bind(payload_hash).fetch_optional(&self.pool).await?;
        if let Some(bytes) = &bytes { ensure!(digest(bytes) == payload_hash, "stored prepare hash mismatch"); }
        Ok(bytes)
    }

    pub async fn prepared_operation(&self, attempt_id: &str) -> Result<Option<PreparedOperation>> {
        let hash: Option<String> = sqlx::query_scalar("SELECT payload_hash FROM ha_prepared WHERE attempt_id=?")
            .bind(attempt_id).fetch_optional(&self.pool).await?;
        match hash {
            Some(hash) => self.prepared_bytes(&hash).await?.map(|bytes| Ok(serde_json::from_slice(&bytes)?)).transpose(),
            None => Ok(None),
        }
    }

    pub async fn objects_by_kind(&self, kind: &str, after: &str, limit: u32) -> Result<Vec<StoredObject>> {
        ensure!(limit > 0 && limit <= 1000, "invalid local object page limit");
        let rows = sqlx::query("SELECT object_key,kind,version,terminal,value FROM ha_objects WHERE kind=? AND object_key>? ORDER BY object_key LIMIT ?")
            .bind(kind).bind(after).bind(limit).fetch_all(&self.pool).await?;
        rows.into_iter().map(|r| Ok(StoredObject { key:r.get("object_key"),kind:r.get("kind"),
            version:u64::try_from(r.get::<i64,_>("version"))?,terminal:r.get::<i64,_>("terminal") != 0,value:r.get("value") })).collect()
    }

    /// The caller must obtain this decision via a quorum read and validate both
    /// signed durable acks. Local possession of these fields is not authority.
    pub async fn apply(&self, decision: &CommitDecision) -> Result<()> {
        ensure!(decision.cluster_id == self.identity.cluster_id && decision.control_generation == self.identity.control_generation,
            "decision scope mismatch");
        ensure!(decision.commit_index > 0 && decision.commit_index <= i64::MAX as u64, "invalid commit index");
        ensure!(!decision.evidence.is_empty() && decision.evidence.len() <= 16 * 1024, "invalid decision evidence");
        let decision_bytes = serde_json::to_vec(decision)?;
        let decision_hash = digest(&decision_bytes);
        let index = decision.commit_index as i64;
        let mut tx = self.pool.begin().await?;
        let previous: Option<String> = sqlx::query_scalar("SELECT decision_hash FROM ha_applied WHERE commit_index=?")
            .bind(index).fetch_optional(&mut *tx).await?;
        if let Some(previous) = previous {
            ensure!(previous == decision_hash, "commit index conflict");
            tx.commit().await?;
            return Ok(());
        }
        let applied: i64 = sqlx::query_scalar("SELECT applied_index FROM ha_meta WHERE singleton=1")
            .fetch_one(&mut *tx).await?;
        ensure!(applied == index - 1, "commit gap: applied {applied}, requested {index}");
        let prepared: Option<Vec<u8>> = sqlx::query_scalar("SELECT p.bytes FROM ha_payloads p JOIN ha_prepared a ON a.payload_hash=p.payload_hash WHERE a.attempt_id=? AND a.payload_hash=?")
            .bind(&decision.attempt_id).bind(&decision.payload_hash).fetch_optional(&mut *tx).await?;
        let Some(prepared) = prepared else { bail!("committed payload unavailable") };
        ensure!(digest(&prepared) == decision.payload_hash, "prepared payload corrupted");
        let operation: PreparedOperation = serde_json::from_slice(&prepared)?;
        // Revalidate immutable structure even after recovering a local backup.
        operation.encoded()?;
        ensure!(operation.cluster_id == decision.cluster_id && operation.control_generation == decision.control_generation
            && operation.attempt_id == decision.attempt_id, "prepared decision mismatch");
        for change in &operation.changes {
            let old = sqlx::query("SELECT kind,version,terminal FROM ha_objects WHERE object_key=?")
                .bind(&change.key).fetch_optional(&mut *tx).await?;
            let old_version = old.as_ref().map(|r| r.get::<i64,_>("version")).unwrap_or(0);
            ensure!(old_version as u64 == change.expected_version, "object version conflict");
            if let Some(old) = old {
                ensure!(old.get::<String,_>("kind") == change.kind, "object kind conflict");
                ensure!(old.get::<i64,_>("terminal") == 0 || change.terminal, "terminal object resurrection");
            }
            sqlx::query("INSERT INTO ha_objects(object_key,kind,version,terminal,value) VALUES(?,?,?,?,?) ON CONFLICT(object_key) DO UPDATE SET version=excluded.version,terminal=excluded.terminal,value=excluded.value")
                .bind(&change.key).bind(&change.kind).bind(old_version + 1).bind(i64::from(change.terminal))
                .bind(&change.value).execute(&mut *tx).await?;
        }
        sqlx::query("INSERT INTO ha_applied(commit_index,actor_id,operation_id,logical_hash,decision_hash,payload_hash,decision_bytes) VALUES(?,?,?,?,?,?,?)")
            .bind(index).bind(&operation.actor_id).bind(&operation.operation_id).bind(&operation.logical_hash)
            .bind(&decision_hash).bind(&decision.payload_hash).bind(decision_bytes).execute(&mut *tx).await?;
        let affected = sqlx::query("UPDATE ha_meta SET applied_index=? WHERE singleton=1 AND applied_index=?")
            .bind(index).bind(index - 1).execute(&mut *tx).await?.rows_affected();
        ensure!(affected == 1, "application watermark conflict");
        tx.commit().await?;
        Ok(())
    }

    /// Local read only: public mailbox APIs must first enforce a quorum barrier.
    pub async fn object(&self, key: &str) -> Result<Option<StoredObject>> {
        let row = sqlx::query("SELECT object_key,kind,version,terminal,value FROM ha_objects WHERE object_key=?")
            .bind(key).fetch_optional(&self.pool).await?;
        row.map(|r| Ok(StoredObject { key: r.get("object_key"), kind: r.get("kind"),
            version: u64::try_from(r.get::<i64,_>("version"))?, terminal: r.get::<i64,_>("terminal") != 0,
            value: r.get("value") })).transpose()
    }

    pub async fn close(&self) { self.pool.close().await; }
}

pub fn digest(bytes: &[u8]) -> String { envelope_server_core::ha::sha256_b64(bytes) }

// Business values are typed JSON, with opaque ciphertext already base64url.
// Preserve those exact bytes without serializing each byte as a JSON integer.
mod utf8_bytes {
    use serde::{Deserialize, Deserializer, Serializer, ser::Error};
    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(std::str::from_utf8(bytes).map_err(S::Error::custom)?)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        Ok(String::deserialize(deserializer)?.into_bytes())
    }
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS ha_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),schema_version INTEGER NOT NULL,identity_json TEXT NOT NULL,applied_index INTEGER NOT NULL CHECK(applied_index>=0));
CREATE TABLE IF NOT EXISTS ha_payloads(payload_hash TEXT PRIMARY KEY,bytes BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS ha_prepared(attempt_id TEXT PRIMARY KEY,payload_hash TEXT NOT NULL REFERENCES ha_payloads(payload_hash),actor_id TEXT NOT NULL,operation_id TEXT NOT NULL,logical_hash TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ha_applied(commit_index INTEGER PRIMARY KEY CHECK(commit_index>0),actor_id TEXT NOT NULL,operation_id TEXT NOT NULL,logical_hash TEXT NOT NULL,decision_hash TEXT NOT NULL,payload_hash TEXT NOT NULL REFERENCES ha_payloads(payload_hash),decision_bytes BLOB NOT NULL,UNIQUE(actor_id,operation_id));
CREATE TABLE IF NOT EXISTS ha_objects(object_key TEXT PRIMARY KEY,kind TEXT NOT NULL,version INTEGER NOT NULL CHECK(version>0),terminal INTEGER NOT NULL CHECK(terminal IN(0,1)),value BLOB NOT NULL);
"#;

#[cfg(test)]
mod tests {
    use super::*;
    fn path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("envelope-ha-v2-{}-{}-{name}.sqlite3", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()))
    }
    fn identity() -> DatabaseIdentity { DatabaseIdentity { cluster_id: "cluster".into(), control_generation: 1, node_id: "s1".into(), node_incarnation: "disk-1".into() } }
    fn op(id: &str, version: u64, terminal: bool) -> PreparedOperation {
        PreparedOperation { cluster_id: "cluster".into(), control_generation: 1, config_epoch: 1, leader_term: 5,
            attempt_id: id.into(), actor_id: "alice".into(), operation_id: id.into(), logical_hash: digest(id.as_bytes()),
            authorization: b"verified-test-authorization".to_vec(), request_body: b"{}".to_vec(), changes: vec![ObjectChange { key: "message".into(),
                kind: "mailbox".into(), expected_version: version, terminal, value: id.as_bytes().to_vec() }] }
    }
    fn decision(op: &PreparedOperation, hash: String, index: u64) -> CommitDecision {
        CommitDecision { cluster_id: "cluster".into(), control_generation: 1, commit_index: index,
            attempt_id: op.attempt_id.clone(), payload_hash: hash, evidence: b"test-control-decision".to_vec() }
    }
    #[tokio::test]
    async fn prepared_survives_reopen_but_is_invisible_until_decision() -> Result<()> {
        let path = path("reopen");
        let store = V2Store::open(&path, identity()).await?;
        let operation = op("a", 0, false);
        let hash = store.prepare(&operation).await?;
        ensure!(store.object("message").await?.is_none());
        ensure!(store.applied_index().await? == 0);
        store.close().await; drop(store);
        let store = V2Store::open(&path, identity()).await?;
        ensure!(store.prepared_bytes(&hash).await?.is_some());
        let decision = decision(&operation, hash, 1);
        store.apply(&decision).await?;
        store.apply(&decision).await?;
        ensure!(store.applied_index().await? == 1);
        ensure!(store.object("message").await?.unwrap().value == b"a");
        store.close().await; Ok(())
    }
    #[tokio::test]
    async fn missing_payload_gap_conflict_and_resurrection_never_advance() -> Result<()> {
        let store = V2Store::open(&path("guards"), identity()).await?;
        let operation = op("a", 0, false);
        ensure!(store.apply(&decision(&operation, digest(b"missing"), 1)).await.is_err());
        let hash = store.prepare(&operation).await?;
        ensure!(store.apply(&decision(&operation, hash.clone(), 2)).await.is_err());
        store.apply(&decision(&operation, hash, 1)).await?;
        let mut collision = operation.clone(); collision.changes[0].value = b"different".to_vec();
        ensure!(store.prepare(&collision).await.is_err());
        let terminal = op("terminal", 1, true);
        let hash = store.prepare(&terminal).await?;
        store.apply(&decision(&terminal, hash, 2)).await?;
        let resurrect = op("resurrect", 2, false);
        let hash = store.prepare(&resurrect).await?;
        ensure!(store.apply(&decision(&resurrect, hash, 3)).await.is_err());
        ensure!(store.applied_index().await? == 2);
        ensure!(store.object("message").await?.unwrap().terminal);
        store.close().await; Ok(())
    }
    #[tokio::test]
    async fn all_object_changes_and_watermark_rollback_on_one_conflict() -> Result<()> {
        let store = V2Store::open(&path("atomic"), identity()).await?;
        let mut operation = op("a", 0, false);
        operation.changes.push(ObjectChange { key: "other".into(), kind: "route".into(), expected_version: 8, terminal: false, value: vec![1] });
        let hash = store.prepare(&operation).await?;
        ensure!(store.apply(&decision(&operation, hash, 1)).await.is_err());
        ensure!(store.object("message").await?.is_none());
        ensure!(store.applied_index().await? == 0);
        store.close().await; Ok(())
    }
    #[tokio::test]
    async fn exclusive_ownership_and_incarnation_mismatch_fail_closed() -> Result<()> {
        let path = path("identity");
        let store = V2Store::open(&path, identity()).await?;
        ensure!(V2Store::open(&path, identity()).await.is_err());
        store.close().await; drop(store);
        let mut different = identity(); different.node_incarnation = "new-disk".into();
        ensure!(V2Store::open(&path, different).await.is_err());
        let store = V2Store::open(&path, identity()).await?;
        store.verify_durability().await?;
        store.close().await; Ok(())
    }
}
