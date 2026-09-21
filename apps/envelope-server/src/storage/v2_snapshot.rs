//! SQLite-consistent snapshots and stopped-node restore primitives.
use super::*;
use sha2::{Digest, Sha256};
use sqlx::{Connection, SqliteConnection};
use std::io::Read;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SnapshotContents {
    pub identity: DatabaseIdentity,
    pub schema_version: u64,
    pub applied_index: u64,
    pub prepared_count: u64,
    pub object_count: u64,
    pub applied_chain_sha256: String,
    pub object_state_sha256: String,
}

async fn read_connection(path: &Path) -> Result<SqliteConnection> {
    ensure!(path.is_file(), "database source does not exist");
    SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(path)
            .read_only(true)
            .synchronous(SqliteSynchronous::Full)
            .foreign_keys(true)
            .busy_timeout(Duration::from_secs(5)),
    )
    .await
    .context("open snapshot source")
}

/// The separate read connection sees WAL content through SQLite. VACUUM INTO
/// produces a consistent database without replacing or raw-copying the source.
/// No source watermark is sampled before the copy: inspect the finished output.
pub async fn create_sqlite_snapshot(source: &Path, destination: &Path) -> Result<SnapshotContents> {
    ensure!(!destination.exists(), "snapshot destination already exists");
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Reserve the output exclusively; SQLite allows INTO an existing empty file.
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?
        .sync_all()?;
    let mut connection = read_connection(source).await?;
    let deadline = std::time::Instant::now() + Duration::from_secs(30 * 60);
    connection
        .lock_handle()
        .await?
        .set_progress_handler(10_000, move || std::time::Instant::now() < deadline);
    let sync: i64 = sqlx::query_scalar("PRAGMA synchronous")
        .fetch_one(&mut connection)
        .await?;
    ensure!(
        sync == 2,
        "backup requires FULL synchronous output flushing"
    );
    sqlx::query("VACUUM main INTO ?")
        .bind(destination.to_str().context("snapshot path is not UTF-8")?)
        .persistent(false)
        .execute(&mut connection)
        .await
        .context("create consistent SQLite snapshot")?;
    connection.close().await?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(destination)?
        .sync_all()?;
    inspect_snapshot(destination).await
}

/// Check all referential/integrity invariants and stream deterministic business
/// roots from this exact completed artifact. Individual payload allocation is
/// bounded by the existing 12 MiB prepared-operation limit.
pub async fn inspect_snapshot(path: &Path) -> Result<SnapshotContents> {
    let mut connection = read_connection(path).await?;
    let journal: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&mut connection)
        .await?;
    ensure!(
        journal.eq_ignore_ascii_case("delete"),
        "snapshot must be a standalone DELETE-journal database, not a live WAL file"
    );
    let integrity: Vec<String> = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_all(&mut connection)
        .await?;
    ensure!(
        integrity == vec!["ok".to_owned()],
        "snapshot integrity check failed"
    );
    ensure!(
        sqlx::query("PRAGMA foreign_key_check")
            .fetch_all(&mut connection)
            .await?
            .is_empty(),
        "snapshot foreign-key check failed"
    );
    let metas = sqlx::query("SELECT schema_version,identity_json,applied_index FROM ha_meta")
        .fetch_all(&mut connection)
        .await?;
    ensure!(metas.len() == 1, "snapshot requires one metadata row");
    let meta = &metas[0];
    ensure!(
        meta.get::<i64, _>("schema_version") == SCHEMA_VERSION,
        "snapshot schema is incompatible"
    );
    let identity: DatabaseIdentity = serde_json::from_str(meta.get("identity_json"))?;
    let applied_index = u64::try_from(meta.get::<i64, _>("applied_index"))?;
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM ha_applied")
        .fetch_one(&mut connection)
        .await?;
    ensure!(
        count as u64 == applied_index,
        "snapshot applied history is incomplete"
    );
    let mut applied_chain = Sha256::new();
    applied_chain.update(b"EnvelopeHA/V2/AppliedChain\0");
    for index in 1..=applied_index {
        let row = sqlx::query(
            "SELECT decision_hash,payload_hash,decision_bytes FROM ha_applied WHERE commit_index=?",
        )
        .bind(i64::try_from(index)?)
        .fetch_optional(&mut connection)
        .await?
        .context("snapshot commit gap")?;
        let bytes: Vec<u8> = row.get("decision_bytes");
        ensure!(bytes.len() <= 128 * 1024, "oversized stored decision");
        let hash: String = row.get("decision_hash");
        ensure!(digest(&bytes) == hash, "snapshot decision hash mismatch");
        let decision: CommitDecision = serde_json::from_slice(&bytes)?;
        ensure!(
            decision.commit_index == index
                && decision.cluster_id == identity.cluster_id
                && decision.control_generation == identity.control_generation
                && decision.payload_hash == row.get::<String, _>("payload_hash"),
            "snapshot decision scope mismatch"
        );
        let item = serde_json::to_vec(&(index.to_string(), hash, decision.payload_hash))?;
        applied_chain.update((item.len() as u64).to_be_bytes());
        applied_chain.update(item);
    }
    let mut cursor = String::new();
    loop {
        let row=sqlx::query("SELECT payload_hash,length(bytes) AS size FROM ha_payloads WHERE payload_hash>? ORDER BY payload_hash LIMIT 1").bind(&cursor).fetch_optional(&mut connection).await?;
        let Some(row) = row else { break };
        let size: i64 = row.get("size");
        ensure!(
            size > 0 && size as usize <= MAX_PREPARED_BYTES,
            "snapshot payload size invalid"
        );
        cursor = row.get("payload_hash");
        let bytes: Vec<u8> =
            sqlx::query_scalar("SELECT bytes FROM ha_payloads WHERE payload_hash=?")
                .bind(&cursor)
                .fetch_one(&mut connection)
                .await?;
        ensure!(digest(&bytes) == cursor, "snapshot payload hash mismatch");
        let operation: PreparedOperation = serde_json::from_slice(&bytes)?;
        operation.encoded()?;
        ensure!(
            operation.cluster_id == identity.cluster_id
                && operation.control_generation == identity.control_generation,
            "snapshot prepared scope mismatch"
        );
    }
    let prepared_count: u64 = u64::try_from(
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM ha_prepared")
            .fetch_one(&mut connection)
            .await?,
    )?;
    let mut object_state = Sha256::new();
    object_state.update(b"EnvelopeHA/V2/ObjectState\0");
    let mut object_count = 0;
    let mut cursor = String::new();
    loop {
        let row=sqlx::query("SELECT object_key,kind,version,terminal,value FROM ha_objects WHERE object_key>? ORDER BY object_key LIMIT 1").bind(&cursor).fetch_optional(&mut connection).await?;
        let Some(row) = row else { break };
        cursor = row.get("object_key");
        let value: Vec<u8> = row.get("value");
        ensure!(
            value.len() <= MAX_PREPARED_BYTES,
            "snapshot business value too large"
        );
        let item = serde_json::to_vec(&(
            &cursor,
            row.get::<String, _>("kind"),
            row.get::<i64, _>("version").to_string(),
            row.get::<i64, _>("terminal"),
            digest(&value),
        ))?;
        object_state.update((item.len() as u64).to_be_bytes());
        object_state.update(item);
        object_count += 1;
    }
    connection.close().await?;
    Ok(SnapshotContents {
        identity,
        schema_version: SCHEMA_VERSION as u64,
        applied_index,
        prepared_count,
        object_count,
        applied_chain_sha256: envelope_core::encode_bytes(&applied_chain.finalize()),
        object_state_sha256: envelope_core::encode_bytes(&object_state.finalize()),
    })
}

pub async fn read_snapshot_decisions(
    path: &Path,
    after: u64,
    limit: u32,
) -> Result<Vec<CommitDecision>> {
    ensure!(
        (1..=1000).contains(&limit),
        "snapshot decision page limit invalid"
    );
    let mut connection = read_connection(path).await?;
    let rows: Vec<Vec<u8>> = sqlx::query_scalar(
        "SELECT decision_bytes FROM ha_applied WHERE commit_index>? ORDER BY commit_index LIMIT ?",
    )
    .bind(i64::try_from(after)?)
    .bind(limit)
    .fetch_all(&mut connection)
    .await?;
    let results = rows
        .into_iter()
        .map(|bytes| Ok(serde_json::from_slice(&bytes)?))
        .collect();
    connection.close().await?;
    results
}

pub fn snapshot_file_digest(path: &Path) -> Result<(String, u64)> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    let mut size = 0u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        };
        hasher.update(&buffer[..read]);
        size = size
            .checked_add(read as u64)
            .context("snapshot length overflow")?;
    }
    Ok((envelope_core::encode_bytes(&hasher.finalize()), size))
}

/// Called only on a privately staged, verified standalone snapshot copy while
/// the destination node's process lock is held. Cross-generation DR is refused.
pub async fn rewrite_restored_identity(
    path: &Path,
    expected: &DatabaseIdentity,
    replacement: &DatabaseIdentity,
) -> Result<()> {
    ensure!(
        expected.cluster_id == replacement.cluster_id
            && expected.control_generation == replacement.control_generation,
        "cross-generation restore requires an explicit DR migration"
    );
    let mut connection = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(false)
            .journal_mode(SqliteJournalMode::Delete)
            .synchronous(SqliteSynchronous::Full)
            .foreign_keys(true),
    )
    .await?;
    let mut tx = connection.begin().await?;
    let actual: String = sqlx::query_scalar("SELECT identity_json FROM ha_meta WHERE singleton=1")
        .fetch_one(&mut *tx)
        .await?;
    ensure!(
        serde_json::from_str::<DatabaseIdentity>(&actual)? == *expected,
        "restore source identity changed"
    );
    sqlx::query("UPDATE ha_meta SET identity_json=? WHERE singleton=1")
        .bind(serde_json::to_string(replacement)?)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    connection.close().await?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)?
        .sync_all()?;
    Ok(())
}

impl V2Store {
    pub async fn consistent_snapshot(&self, destination: &Path) -> Result<SnapshotContents> {
        create_sqlite_snapshot(&self.path, destination).await
    }
    /// Recovery module must first CAS-seal the control attempt and prove no
    /// active staged reference. No timeout or local age is an authorization.
    pub(crate) async fn delete_uncommitted_prepare(
        &self,
        attempt_id: &str,
        payload_hash: &str,
    ) -> Result<bool> {
        let mut tx = self.pool.begin().await?;
        let referenced: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM ha_applied WHERE payload_hash=?")
                .bind(payload_hash)
                .fetch_one(&mut *tx)
                .await?;
        ensure!(
            referenced == 0,
            "cannot garbage-collect a committed payload"
        );
        let deleted = sqlx::query("DELETE FROM ha_prepared WHERE attempt_id=? AND payload_hash=?")
            .bind(attempt_id)
            .bind(payload_hash)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        sqlx::query("DELETE FROM ha_payloads WHERE payload_hash=? AND NOT EXISTS(SELECT 1 FROM ha_prepared WHERE payload_hash=?) AND NOT EXISTS(SELECT 1 FROM ha_applied WHERE payload_hash=?)")
            .bind(payload_hash).bind(payload_hash).bind(payload_hash).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(deleted == 1)
    }
}
