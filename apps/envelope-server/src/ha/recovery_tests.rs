use super::*;
use crate::storage::v2::{CommitDecision, ObjectChange, PreparedOperation};
use envelope_server_core::ha::{PrepareAck, ServiceMode};
use std::io::{Seek, SeekFrom, Write};

fn secret(n: u8) -> String {
    envelope_core::encode_bytes(&[n; 32])
}
fn admin() -> String {
    envelope_core::signing_public_from_secret(&secret(1)).unwrap()
}
fn fixture() -> (ClusterConfigV2, u64, PathBuf) {
    let file =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/ha-v2/vectors.json");
    let data: Value = serde_json::from_slice(&std::fs::read(file).unwrap()).unwrap();
    let now = data["now_ms"].as_str().unwrap().parse().unwrap();
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let mut config: ClusterConfigV2 =
        serde_json::from_value(data["valid"][0]["document"].clone()).unwrap();
    config.cluster_id = format!("recovery-test-{stamp}");
    config.sign(&secret(1)).unwrap();
    (
        config,
        now,
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("../../target/ha-recovery-tests/{stamp}")),
    )
}
async fn store(path: &Path, config: &ClusterConfigV2, node: &str) -> Result<V2Store> {
    V2Store::open(
        path,
        DatabaseIdentity {
            cluster_id: config.cluster_id.clone(),
            control_generation: config.control_generation.0,
            node_id: node.into(),
            node_incarnation: config.node(node)?.node_incarnation.clone(),
        },
    )
    .await
}
fn operation(config: &ClusterConfigV2, index: u64) -> PreparedOperation {
    PreparedOperation {
        cluster_id: config.cluster_id.clone(),
        control_generation: config.control_generation.0,
        config_epoch: config.config_epoch.0,
        leader_term: 1,
        attempt_id: format!("attempt-{index}"),
        actor_id: "test-actor".into(),
        operation_id: format!("operation-{index}"),
        logical_hash: digest(format!("change-{index}").as_bytes()),
        authorization: b"{}".to_vec(),
        request_body: format!("{{\"value\":{index}}}").into_bytes(),
        changes: vec![ObjectChange {
            key: "mailbox/object-1".into(),
            kind: "mailbox".into(),
            expected_version: index - 1,
            terminal: index >= 3,
            value: format!("{{\"version\":{index}}}").into_bytes(),
        }],
    }
}
fn decision(
    config: &ClusterConfigV2,
    op: &PreparedOperation,
    hash: String,
    index: u64,
) -> Result<CommitDecision> {
    let mut acks = vec![];
    for (n, node) in config.business_nodes.iter().enumerate() {
        let mut ack = PrepareAck {
            protocol_version: 2,
            cluster_id: config.cluster_id.clone(),
            control_generation: config.control_generation,
            config_epoch: config.config_epoch,
            leader_term: op.leader_term.into(),
            attempt_id: op.attempt_id.clone(),
            operation_id: op.operation_id.clone(),
            actor_id: op.actor_id.clone(),
            logical_hash: op.logical_hash.clone(),
            payload_hash: hash.clone(),
            node_id: node.node_id.clone(),
            node_incarnation: node.node_incarnation.clone(),
            signature: String::new(),
        };
        ack.sign(&secret(n as u8 + 2))?;
        acks.push(ack);
    }
    let decided = Decided {
        index,
        attempt_id: op.attempt_id.clone(),
        payload_hash: hash.clone(),
        logical_hash: op.logical_hash.clone(),
        actor_id: op.actor_id.clone(),
        operation_id: op.operation_id.clone(),
        acks,
    };
    Ok(CommitDecision {
        cluster_id: config.cluster_id.clone(),
        control_generation: config.control_generation.0,
        commit_index: index,
        attempt_id: op.attempt_id.clone(),
        payload_hash: hash,
        evidence: serde_json::to_vec(&decided)?,
    })
}
async fn append(store: &V2Store, config: &ClusterConfigV2, index: u64) -> Result<()> {
    let op = operation(config, index);
    let hash = store.prepare(&op).await?;
    store.apply(&decision(config, &op, hash, index)?).await
}
fn next_config(config: &ClusterConfigV2) -> ClusterConfigV2 {
    let mut next = config.clone();
    next.config_epoch.0 += 1;
    next.business_nodes[0].node_incarnation = "S1-rebuilt-disk".into();
    next.sign(&secret(1)).unwrap();
    next
}

#[tokio::test]
async fn online_wal_snapshot_captures_its_own_watermark_and_restores_all_content() -> Result<()> {
    let (config, now, dir) = fixture();
    let source = store(&dir.join("source.sqlite3"), &config, "S1").await?;
    for index in 1..=3 {
        append(&source, &config, index).await?;
    }
    let mut orphan = operation(&config, 100);
    orphan.changes[0].key = "orphan".into();
    orphan.changes[0].expected_version = 0;
    let orphan_hash = source.prepare(&orphan).await?;
    let writer_source = source.clone();
    let writer_config = config.clone();
    let writer = tokio::spawn(async move {
        for index in 4..=15 {
            append(&writer_source, &writer_config, index).await?;
            tokio::task::yield_now().await;
        }
        Ok::<_, anyhow::Error>(())
    });
    let bundle = dir.join("bundle");
    let manifest = backup(
        source.path(),
        &bundle,
        config.clone(),
        vec![],
        &admin(),
        &secret(2),
        now,
    )
    .await?;
    writer.await??;
    ensure!((3..=15).contains(&manifest.contents.applied_index));
    ensure!(source.applied_index().await? == 15);
    verify_bundle(&bundle, &admin()).await?;
    let destination = dir.join("restored.sqlite3");
    let current = next_config(&config);
    let report = restore(&bundle, &destination, &current, "S1", &admin(), now).await?;
    ensure!(report.applied_index == manifest.contents.applied_index);
    let restored = store(&destination, &current, "S1").await?;
    ensure!(restored.applied_index().await? == manifest.contents.applied_index);
    let object = restored
        .object("mailbox/object-1")
        .await?
        .context("restored object")?;
    ensure!(object.terminal && object.version == manifest.contents.applied_index);
    ensure!(restored.prepared_bytes(&orphan_hash).await? == Some(orphan.encoded()?));
    ensure!(source.identity().node_incarnation == "S1-disk-1");
    append(&source, &config, 16).await?; // Snapshot did not replace or lock out the live DB.
    restored.close().await;
    source.close().await;
    Ok(())
}

#[tokio::test]
async fn restore_rejects_tampering_identity_reuse_active_process_and_overwrite() -> Result<()> {
    let (config, now, dir) = fixture();
    let source = store(&dir.join("source.sqlite3"), &config, "S1").await?;
    append(&source, &config, 1).await?;
    let bundle = dir.join("bundle");
    backup(
        source.path(),
        &bundle,
        config.clone(),
        vec![],
        &admin(),
        &secret(2),
        now,
    )
    .await?;
    let destination = dir.join("new.sqlite3");
    ensure!(
        restore(&bundle, &destination, &config, "S1", &admin(), now)
            .await
            .is_err()
    );
    let mut reused = config.clone();
    reused.config_epoch.0 += 1;
    reused.sign(&secret(1))?;
    ensure!(
        restore(&bundle, &destination, &reused, "S1", &admin(), now)
            .await
            .is_err()
    );
    let current = next_config(&config);
    let lock = OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .open(destination.with_extension("v2.lock"))?;
    lock.try_lock_exclusive()?;
    ensure!(
        restore(&bundle, &destination, &current, "S1", &admin(), now)
            .await
            .is_err()
    );
    drop(lock);
    std::fs::write(&destination, b"must preserve existing destination")?;
    ensure!(
        restore(&bundle, &destination, &current, "S1", &admin(), now)
            .await
            .is_err()
    );
    ensure!(std::fs::read(&destination)? == b"must preserve existing destination");
    let mut manifest: SnapshotManifest =
        serde_json::from_slice(&std::fs::read(bundle.join(MANIFEST_FILE))?)?;
    manifest.contents.applied_index += 1;
    std::fs::write(bundle.join(MANIFEST_FILE), serde_json::to_vec(&manifest)?)?;
    ensure!(verify_bundle(&bundle, &admin()).await.is_err());
    manifest.sign(&secret(2))?;
    std::fs::write(bundle.join(MANIFEST_FILE), serde_json::to_vec(&manifest)?)?;
    ensure!(
        verify_bundle(&bundle, &admin()).await.is_err(),
        "even resigned metadata must match exact snapshot"
    );
    manifest.contents.applied_index -= 1;
    manifest.sign(&secret(2))?;
    std::fs::write(bundle.join(MANIFEST_FILE), serde_json::to_vec(&manifest)?)?;
    let mut db = OpenOptions::new()
        .write(true)
        .open(bundle.join(DATABASE_FILE))?;
    db.seek(SeekFrom::Start(1024))?;
    db.write_all(b"tamper")?;
    db.sync_all()?;
    drop(db);
    ensure!(verify_bundle(&bundle, &admin()).await.is_err());
    source.close().await;
    Ok(())
}

#[tokio::test]
async fn snapshot_requires_authenticated_history_for_old_commit_evidence() -> Result<()> {
    let (config, now, dir) = fixture();
    let source = store(&dir.join("source.sqlite3"), &config, "S1").await?;
    append(&source, &config, 1).await?;
    let mut current = config.clone();
    current.config_epoch = 2.into();
    current.sign(&secret(1))?;
    ensure!(
        backup(
            source.path(),
            &dir.join("missing-history"),
            current.clone(),
            vec![],
            &admin(),
            &secret(2),
            now
        )
        .await
        .is_err()
    );
    let bundle = dir.join("history");
    backup(
        source.path(),
        &bundle,
        current,
        vec![config],
        &admin(),
        &secret(2),
        now,
    )
    .await?;
    verify_bundle(&bundle, &admin()).await?;
    source.close().await;
    Ok(())
}

#[tokio::test]
#[ignore = "requires isolated ETCD_ENDPOINTS; exercises CAS-sealed GC and matching dual checkpoint"]
async fn gc_seals_before_delete_preserves_staged_committed_and_checkpoint_needs_two_replicas()
-> Result<()> {
    let (config, now, dir) = fixture();
    let endpoints: Vec<String> = std::env::var("ETCD_ENDPOINTS")?
        .split(',')
        .map(str::to_owned)
        .collect();
    let control = Control::connect(&endpoints, &config, None).await?;
    control.initialize().await?;
    let session = control
        .try_acquire("S1", "S1-disk-1", "recovery-test-session-00001")
        .await?
        .context("leader")?;
    ensure!(
        control
            .publish_ready(&session, 0, ServiceMode::Normal)
            .await?
    );
    let first = store(&dir.join("s1.sqlite3"), &config, "S1").await?;
    let orphan = operation(&config, 1);
    first.prepare(&orphan).await?;
    ensure!(seal_and_collect(&control, &session, &first, &orphan.attempt_id).await?);
    ensure!(
        first
            .prepared_operation(&orphan.attempt_id)
            .await?
            .is_none()
    );
    let key = format!("attempts/{}", orphan.attempt_id);
    ensure!(control.snapshot(&[&key]).await?.entries[&key].value == b"sealed");
    ensure!(
        !control
            .guarded_txn(
                &session,
                true,
                &[Guard::Missing(key.clone())],
                &[Change::Put(key, b"staged".to_vec())]
            )
            .await?,
        "late stage cannot overwrite a sealed attempt"
    );
    let staged = operation(&config, 2);
    first.prepare(&staged).await?;
    ensure!(
        control
            .guarded_txn(
                &session,
                true,
                &[],
                &[Change::Put("attempts/attempt-2".into(), b"staged".to_vec())]
            )
            .await?
    );
    ensure!(
        seal_and_collect(&control, &session, &first, &staged.attempt_id)
            .await
            .is_err()
    );
    ensure!(
        first
            .prepared_operation(&staged.attempt_id)
            .await?
            .is_some()
    );
    // Prepare a different committed attempt; the local applied FK guard remains
    // authoritative even if a damaged control namespace omits its attempt row.
    let mut committed = operation(&config, 1);
    committed.attempt_id = "committed-1".into();
    let hash = first.prepare(&committed).await?;
    first
        .apply(&decision(&config, &committed, hash, 1)?)
        .await?;
    ensure!(
        seal_and_collect(&control, &session, &first, &committed.attempt_id)
            .await
            .is_err()
    );
    ensure!(
        first
            .prepared_operation(&committed.attempt_id)
            .await?
            .is_some()
    );
    let second = store(&dir.join("s2.sqlite3"), &config, "S2").await?;
    let hash = second.prepare(&committed).await?;
    second
        .apply(&decision(&config, &committed, hash, 1)?)
        .await?;
    ensure!(
        control
            .guarded_txn(
                &session,
                false,
                &[Guard::Value("head".into(), b"0".to_vec())],
                &[Change::Put("head".into(), b"1".to_vec())]
            )
            .await?
    );
    ensure!(
        control
            .publish_ready(&session, 1, ServiceMode::Normal)
            .await?
    );
    let a = backup(
        first.path(),
        &dir.join("snapshot-s1"),
        config.clone(),
        vec![],
        &admin(),
        &secret(2),
        now,
    )
    .await?;
    let b = backup(
        second.path(),
        &dir.join("snapshot-s2"),
        config.clone(),
        vec![],
        &admin(),
        &secret(3),
        now,
    )
    .await?;
    ensure!(
        register_checkpoint(&control, &session, &config, &admin(), &a, &a)
            .await
            .is_err()
    );
    let mut mismatch = b.clone();
    mismatch.contents.object_state_sha256 = digest(b"different-state");
    mismatch.sign(&secret(3))?;
    ensure!(
        register_checkpoint(&control, &session, &config, &admin(), &a, &mismatch)
            .await
            .is_err()
    );
    register_checkpoint(&control, &session, &config, &admin(), &a, &b).await?;
    let snapshot = control.snapshot(&["checkpoint_floor", "gc_floor"]).await?;
    ensure!(snapshot.entries["checkpoint_floor"].value == b"1");
    ensure!(
        !snapshot.entries.contains_key("gc_floor"),
        "checkpoint alone must not delete committed history"
    );
    first.close().await;
    second.close().await;
    control.release(&session).await?;
    let mut client = etcd_client::Client::connect(endpoints, None).await?;
    client
        .delete(
            control.prefix(),
            Some(etcd_client::DeleteOptions::new().with_prefix()),
        )
        .await?;
    Ok(())
}
