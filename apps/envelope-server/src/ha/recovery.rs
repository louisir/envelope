//! Authenticated, consistent snapshot bundles and explicit stopped-node rebuild.
//! Committed payload/decision GC is deliberately not authorized by a local age.
use super::{
    control::{Change, Control, Guard, LeaderSession},
    coordinator::{Decided, operation_key, random_token},
};
use crate::storage::v2::{
    DatabaseIdentity, SnapshotContents, V2Store, create_sqlite_snapshot, digest, inspect_snapshot,
    read_snapshot_decisions, rewrite_restored_identity, snapshot_file_digest,
};
use anyhow::{Context, Result, ensure};
use envelope_server_core::ha::{ClusterConfigV2, DecimalU64, HaSigned};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    path::{Path, PathBuf},
};

const DATABASE_FILE: &str = "snapshot.sqlite3";
const MANIFEST_FILE: &str = "manifest.json";
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotManifest {
    pub protocol_version: u16,
    pub snapshot_id: String,
    pub created_at: DecimalU64,
    pub config: ClusterConfigV2,
    pub archived_configs: Vec<ClusterConfigV2>,
    pub contents: SnapshotContents,
    pub database_sha256: String,
    pub database_bytes: DecimalU64,
    pub node_signature: String,
}
impl HaSigned for SnapshotManifest {
    const KIND: &'static str = "SnapshotManifest";
    fn canonical_value(&self) -> Value {
        let config = json!([self.config.canonical_value(), self.config.signature]);
        let history: Vec<_> = self
            .archived_configs
            .iter()
            .map(|c| json!([c.canonical_value(), c.signature]))
            .collect();
        let meta = &self.contents;
        let identity = &meta.identity;
        json!([
            self.protocol_version,
            self.snapshot_id,
            self.created_at,
            config,
            history,
            [
                identity.cluster_id,
                identity.control_generation.to_string(),
                identity.node_id,
                identity.node_incarnation
            ],
            meta.schema_version.to_string(),
            meta.applied_index.to_string(),
            meta.prepared_count.to_string(),
            meta.object_count.to_string(),
            meta.applied_chain_sha256,
            meta.object_state_sha256,
            self.database_sha256,
            self.database_bytes
        ])
    }
    fn signature(&self) -> &str {
        &self.node_signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.node_signature
    }
}
impl SnapshotManifest {
    pub fn verify(&self, administrator_public: &str) -> Result<()> {
        ensure!(
            self.protocol_version == 2 && self.created_at.0 > 0,
            "unsupported snapshot format"
        );
        ensure!(
            !self.snapshot_id.is_empty()
                && self.snapshot_id.len() <= 128
                && self
                    .snapshot_id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')),
            "invalid snapshot ID"
        );
        ensure!(
            self.database_bytes.0 > 0 && self.contents.schema_version == 2,
            "invalid snapshot metadata"
        );
        self.config.verify_archived(administrator_public)?;
        let identity = &self.contents.identity;
        ensure!(
            identity.cluster_id == self.config.cluster_id
                && identity.control_generation == self.config.control_generation.0,
            "snapshot configuration scope mismatch"
        );
        let node = self.config.node(&identity.node_id)?;
        ensure!(
            node.node_incarnation == identity.node_incarnation,
            "snapshot signer incarnation mismatch"
        );
        let mut previous = None;
        for archive in &self.archived_configs {
            archive.verify_archived(administrator_public)?;
            let scope = (archive.control_generation.0, archive.config_epoch.0);
            ensure!(
                archive.cluster_id == self.config.cluster_id
                    && archive.control_generation <= self.config.control_generation
                    && archive.config_epoch < self.config.config_epoch
                    && previous.is_none_or(|p| p < scope),
                "invalid/duplicate snapshot config history"
            );
            previous = Some(scope);
        }
        for hash in [
            &self.database_sha256,
            &self.contents.applied_chain_sha256,
            &self.contents.object_state_sha256,
        ] {
            let bytes = envelope_core::decode_bytes(hash, "snapshot hash")?;
            ensure!(
                bytes.len() == 32 && envelope_core::encode_bytes(&bytes) == *hash,
                "invalid snapshot hash"
            );
        }
        self.verify_signature(&node.signing_public)?;
        Ok(())
    }
    fn history(&self) -> BTreeMap<(u64, u64), &ClusterConfigV2> {
        self.archived_configs
            .iter()
            .chain(std::iter::once(&self.config))
            .map(|c| ((c.control_generation.0, c.config_epoch.0), c))
            .collect()
    }
}

pub async fn backup(
    source: &Path,
    destination: &Path,
    config: ClusterConfigV2,
    mut archives: Vec<ClusterConfigV2>,
    administrator_public: &str,
    node_secret: &str,
    now_ms: u64,
) -> Result<SnapshotManifest> {
    config.verify(administrator_public, now_ms)?;
    ensure!(
        !destination.exists(),
        "snapshot bundle directory already exists"
    );
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::create_dir(destination)?;
    let database = destination.join(DATABASE_FILE);
    let contents = create_sqlite_snapshot(source, &database).await?;
    let (database_sha256, database_bytes) = snapshot_file_digest(&database)?;
    archives.sort_by_key(|c| (c.control_generation.0, c.config_epoch.0));
    let mut manifest = SnapshotManifest {
        protocol_version: 2,
        snapshot_id: random_token(),
        created_at: DecimalU64(now_ms),
        config,
        archived_configs: archives,
        contents,
        database_sha256,
        database_bytes: DecimalU64(database_bytes),
        node_signature: String::new(),
    };
    manifest.sign(node_secret)?;
    manifest.verify(administrator_public)?;
    verify_decisions(&database, &manifest).await?;
    let bytes = serde_json::to_vec_pretty(&manifest)?;
    ensure!(
        bytes.len() as u64 <= MAX_MANIFEST_BYTES,
        "snapshot manifest exceeds limit"
    );
    durable_new_file(&destination.join(MANIFEST_FILE), &bytes)?;
    sync_directory(destination)?;
    Ok(manifest)
}

pub async fn verify_bundle(
    directory: &Path,
    administrator_public: &str,
) -> Result<SnapshotManifest> {
    let manifest_path = directory.join(MANIFEST_FILE);
    ensure!(
        std::fs::metadata(&manifest_path)?.len() <= MAX_MANIFEST_BYTES,
        "snapshot manifest exceeds limit"
    );
    let manifest: SnapshotManifest = serde_json::from_slice(&std::fs::read(manifest_path)?)?;
    manifest.verify(administrator_public)?;
    let database = directory.join(DATABASE_FILE);
    let (hash, bytes) = snapshot_file_digest(&database)?;
    ensure!(
        hash == manifest.database_sha256 && bytes == manifest.database_bytes.0,
        "snapshot database hash/length mismatch"
    );
    let contents = inspect_snapshot(&database).await?;
    ensure!(
        contents == manifest.contents,
        "snapshot metadata differs from signed artifact"
    );
    verify_decisions(&database, &manifest).await?;
    Ok(manifest)
}

async fn verify_decisions(database: &Path, manifest: &SnapshotManifest) -> Result<()> {
    let history = manifest.history();
    let mut after = 0;
    loop {
        let page = read_snapshot_decisions(database, after, 100).await?;
        if page.is_empty() {
            break;
        }
        for decision in page {
            ensure!(
                decision.commit_index == after + 1,
                "snapshot decision sequence gap"
            );
            let decided: Decided = serde_json::from_slice(&decision.evidence)
                .context("snapshot decision evidence is not HA v2")?;
            ensure!(
                decided.index == decision.commit_index
                    && decided.attempt_id == decision.attempt_id
                    && decided.payload_hash == decision.payload_hash
                    && decided.acks.len() == 2
                    && decided.acks[0].node_id < decided.acks[1].node_id,
                "snapshot decision evidence mismatch"
            );
            let first = &decided.acks[0];
            let config = history
                .get(&(first.control_generation.0, first.config_epoch.0))
                .context("snapshot is missing authenticated historical configuration")?;
            for ack in &decided.acks {
                ack.verify(config)?;
                ensure!(
                    ack.attempt_id == decided.attempt_id
                        && ack.payload_hash == decided.payload_hash
                        && ack.logical_hash == decided.logical_hash
                        && ack.actor_id == decided.actor_id
                        && ack.operation_id == decided.operation_id
                        && ack.leader_term == first.leader_term,
                    "snapshot replica evidence mismatch"
                );
            }
            after = decision.commit_index;
        }
    }
    ensure!(
        after == manifest.contents.applied_index,
        "snapshot applied watermark mismatch"
    );
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct RestoreReport {
    pub destination: PathBuf,
    pub identity: DatabaseIdentity,
    pub applied_index: u64,
    pub source_snapshot_id: String,
    pub source_database_sha256: String,
}

/// Restore into a NEW database path only. The caller stops the target service,
/// retains its old files for rollback and supplies a newly signed incarnation.
/// Backup must precede the administrator's config epoch/incarnation advance.
pub async fn restore(
    directory: &Path,
    destination: &Path,
    current: &ClusterConfigV2,
    target_node_id: &str,
    administrator_public: &str,
    now_ms: u64,
) -> Result<RestoreReport> {
    current.verify(administrator_public, now_ms)?;
    let manifest = verify_bundle(directory, administrator_public).await?;
    ensure!(
        current.cluster_id == manifest.config.cluster_id
            && current.control_generation == manifest.config.control_generation,
        "control-generation DR requires separate explicit migration"
    );
    ensure!(
        current.config_epoch > manifest.config.config_epoch,
        "restore requires a new administrator-approved config epoch after this snapshot"
    );
    let target = current.node(target_node_id)?;
    if let Ok(previous) = manifest.config.node(target_node_id) {
        ensure!(
            target.node_incarnation != previous.node_incarnation,
            "restore must use a new data incarnation"
        );
    }
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(destination.with_extension("v2.lock"))?;
    lock.try_lock_exclusive()
        .context("target node is still running; refusing restore")?;
    ensure!(
        !destination.exists(),
        "restore destination exists; preserve it and select a new path"
    );
    let replacement = DatabaseIdentity {
        cluster_id: current.cluster_id.clone(),
        control_generation: current.control_generation.0,
        node_id: target.node_id.clone(),
        node_incarnation: target.node_incarnation.clone(),
    };
    let staged = destination.with_extension(format!("restore-{}.sqlite3", manifest.snapshot_id));
    let mut input = File::open(directory.join(DATABASE_FILE))?;
    let mut output = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&staged)?;
    std::io::copy(&mut input, &mut output)?;
    output.sync_all()?;
    drop(output);
    let (copied_hash, copied_bytes) = snapshot_file_digest(&staged)?;
    ensure!(
        copied_hash == manifest.database_sha256 && copied_bytes == manifest.database_bytes.0,
        "snapshot changed during restore copy"
    );
    rewrite_restored_identity(&staged, &manifest.contents.identity, &replacement).await?;
    let restored = inspect_snapshot(&staged).await?;
    ensure!(
        restored.identity == replacement
            && restored.applied_index == manifest.contents.applied_index
            && restored.applied_chain_sha256 == manifest.contents.applied_chain_sha256
            && restored.object_state_sha256 == manifest.contents.object_state_sha256
            && restored.prepared_count == manifest.contents.prepared_count
            && restored.object_count == manifest.contents.object_count,
        "restore changed business content or watermark"
    );
    // Same-directory hard-link publication is atomic and fails if destination
    // appeared. Unlike rename on Unix, it can never overwrite an existing DB.
    std::fs::hard_link(&staged, destination)
        .context("publish restored database without overwriting")?;
    std::fs::remove_file(&staged)?;
    if let Some(parent) = destination.parent() {
        sync_directory(parent)?;
    }
    let report = RestoreReport {
        destination: destination.to_owned(),
        identity: replacement,
        applied_index: restored.applied_index,
        source_snapshot_id: manifest.snapshot_id,
        source_database_sha256: manifest.database_sha256,
    };
    durable_new_file(
        &destination.with_extension("recovery.json"),
        &serde_json::to_vec_pretty(&report)?,
    )?;
    drop(lock);
    Ok(report)
}

/// Cancel an uncommitted attempt through control CAS before removing its local
/// payload. Staged and committed attempts are always preserved by this method.
pub async fn seal_and_collect(
    control: &Control,
    session: &LeaderSession,
    store: &V2Store,
    attempt_id: &str,
) -> Result<bool> {
    let Some(operation) = store.prepared_operation(attempt_id).await? else {
        return Ok(false);
    };
    let payload_hash = digest(&operation.encoded()?);
    let attempt_key = format!("attempts/{attempt_id}");
    let operation_key = operation_key(&operation.actor_id, &operation.operation_id);
    let stage_keys: Vec<_> = operation
        .changes
        .iter()
        .map(|c| format!("staged/{}", c.key))
        .collect();
    let mut keys = vec![attempt_key.as_str(), operation_key.as_str()];
    keys.extend(stage_keys.iter().map(String::as_str));
    let snapshot = control.snapshot(&keys).await?;
    let attempt = snapshot.entries.get(&attempt_key);
    ensure!(
        attempt.is_none_or(|a| a.value == b"open" || a.value == b"sealed"),
        "staged/committed attempt cannot be collected"
    );
    let mut guards = Vec::new();
    for key in &keys {
        if let Some(entry) = snapshot.entries.get(*key) {
            if *key != attempt_key {
                let value: Value = serde_json::from_slice(&entry.value)?;
                if *key == operation_key {
                    for field in ["decided", "staged"] {
                        ensure!(
                            value
                                .get(field)
                                .and_then(|v| v.get("attempt_id"))
                                .and_then(Value::as_str)
                                != Some(attempt_id),
                            "attempt still referenced by operation result"
                        );
                    }
                } else {
                    ensure!(
                        value.get("attempt_id").and_then(Value::as_str) != Some(attempt_id)
                            && value.get("payload_hash").and_then(Value::as_str)
                                != Some(payload_hash.as_str()),
                        "attempt still referenced by staged body"
                    );
                }
            }
            guards.push(Guard::Value((*key).to_owned(), entry.value.clone()));
        } else {
            guards.push(Guard::Missing((*key).to_owned()));
        }
    }
    ensure!(
        control
            .guarded_txn(
                session,
                true,
                &guards,
                &[Change::Put(attempt_key, b"sealed".to_vec())]
            )
            .await?,
        "attempt changed while sealing; no data removed"
    );
    store
        .delete_uncommitted_prepare(attempt_id, &payload_hash)
        .await
}

#[derive(Debug, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Checkpoint {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub applied_index: DecimalU64,
    pub applied_chain_sha256: String,
    pub object_state_sha256: String,
    pub replicas: Vec<Value>,
}
/// Registers matching signed, complete snapshots from both current incarnations.
/// This advances a recovery checkpoint only; it does not delete committed logs.
pub async fn register_checkpoint(
    control: &Control,
    session: &LeaderSession,
    current: &ClusterConfigV2,
    administrator_public: &str,
    first: &SnapshotManifest,
    second: &SnapshotManifest,
) -> Result<Checkpoint> {
    first.verify(administrator_public)?;
    second.verify(administrator_public)?;
    ensure!(
        first.config == *current && second.config == *current,
        "checkpoint snapshots must use the current authenticated config"
    );
    ensure!(
        first.contents.identity.node_id != second.contents.identity.node_id
            && first.contents.applied_index == second.contents.applied_index
            && first.contents.applied_chain_sha256 == second.contents.applied_chain_sha256
            && first.contents.object_state_sha256 == second.contents.object_state_sha256,
        "checkpoint requires two matching business snapshots"
    );
    let mut manifests = [first, second];
    manifests.sort_by_key(|m| m.contents.identity.node_id.as_str());
    let checkpoint = Checkpoint {
        protocol_version: 2,
        cluster_id: current.cluster_id.clone(),
        control_generation: current.control_generation,
        config_epoch: current.config_epoch,
        applied_index: DecimalU64(first.contents.applied_index),
        applied_chain_sha256: first.contents.applied_chain_sha256.clone(),
        object_state_sha256: first.contents.object_state_sha256.clone(),
        replicas: manifests
            .iter()
            .map(|m| {
                json!([
                    m.contents.identity.node_id,
                    m.contents.identity.node_incarnation,
                    m.snapshot_id,
                    m.database_sha256,
                    digest(&m.signing_bytes().expect("validated manifest serializes")),
                    m.node_signature
                ])
            })
            .collect(),
    };
    let snapshot = control.snapshot(&["checkpoint_floor"]).await?;
    ensure!(
        checkpoint.applied_index.0 <= snapshot.head_index,
        "checkpoint ahead of control head"
    );
    let mut guards = vec![Guard::Value("head".into(), snapshot.head.value.clone())];
    if let Some(previous) = snapshot.entries.get("checkpoint_floor") {
        let floor: u64 = std::str::from_utf8(&previous.value)?.parse()?;
        ensure!(checkpoint.applied_index.0 >= floor, "checkpoint rollback");
        guards.push(Guard::Value(
            "checkpoint_floor".into(),
            previous.value.clone(),
        ));
    } else {
        guards.push(Guard::Missing("checkpoint_floor".into()));
    }
    let bytes = serde_json::to_vec(&checkpoint)?;
    let key = format!("checkpoints/{}", digest(&bytes));
    guards.push(Guard::Missing(key.clone()));
    ensure!(
        control
            .guarded_txn(
                session,
                true,
                &guards,
                &[
                    Change::Put(key, bytes),
                    Change::Put(
                        "checkpoint_floor".into(),
                        checkpoint.applied_index.0.to_string().into_bytes()
                    )
                ]
            )
            .await?,
        "checkpoint control comparison failed"
    );
    Ok(checkpoint)
}

fn durable_new_file(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut file = OpenOptions::new().create_new(true).write(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(test)]
#[path = "recovery_tests.rs"]
mod tests;
