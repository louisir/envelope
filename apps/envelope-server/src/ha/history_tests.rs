use super::*;
use crate::storage::v2::DatabaseIdentity;

fn secret(byte: u8) -> String {
    envelope_core::encode_bytes(&[byte; 32])
}

#[tokio::test]
#[ignore = "requires isolated ETCD_ENDPOINTS; tests replay after explicit node key/incarnation rotation"]
async fn archived_decision_replays_and_new_key_attests_original_scope() -> Result<()> {
    let endpoints: Vec<String> = std::env::var("ETCD_ENDPOINTS")?
        .split(',')
        .map(str::to_owned)
        .collect();
    let fixture: serde_json::Value = serde_json::from_slice(&std::fs::read(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/ha-v2/vectors.json"),
    )?)?;
    let now: u64 = fixture["now_ms"]
        .as_str()
        .context("fixture clock")?
        .parse()?;
    let admin = envelope_core::signing_public_from_secret(&secret(1))?;
    let mut old: ClusterConfigV2 = serde_json::from_value(fixture["valid"][0]["document"].clone())?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    old.cluster_id = format!("history-replay-test-{stamp}");
    old.sign(&secret(1))?;
    let mut current = old.clone();
    current.config_epoch = DecimalU64(2);
    for (index, node) in current.business_nodes.iter_mut().enumerate() {
        node.signing_public = envelope_core::signing_public_from_secret(&secret(index as u8 + 6))?;
        node.node_incarnation = format!("{}-disk-2", node.node_id);
    }
    current.sign(&secret(1))?;
    let control = Control::connect(&endpoints, &current, None).await?;
    control.initialize().await?;
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../target/ha-history-tests/{stamp}/v2.sqlite3"));
    let store = V2Store::open(
        &path,
        DatabaseIdentity {
            cluster_id: current.cluster_id.clone(),
            control_generation: 1,
            node_id: "S1".into(),
            node_incarnation: "S1-disk-2".into(),
        },
    )
    .await?;
    let mut request: SignedRequest = serde_json::from_value(fixture["signed_request"].clone())?;
    request.auth.cluster_id = old.cluster_id.clone();
    request.auth.sign(&secret(4))?;
    let body = request.decoded_body(4096)?;
    let binding = serde_json::from_slice::<StoreEnvelopeBody>(&body)?.binding;
    let attempt = "historical-attempt";
    let (logical_hash, changes) =
        business::prepare_changes(&store, &old, &request.auth, &body, attempt, now).await?;
    let mut ack: PrepareAck = serde_json::from_value(fixture["valid"][2]["document"].clone())?;
    let operation = PreparedOperation {
        cluster_id: old.cluster_id.clone(),
        control_generation: 1,
        config_epoch: 1,
        leader_term: ack.leader_term.0,
        attempt_id: attempt.into(),
        actor_id: binding.sender_key_id.clone(),
        operation_id: binding.operation_id.clone(),
        logical_hash: logical_hash.clone(),
        authorization: serde_json::to_vec(&request.auth)?,
        request_body: body,
        changes,
    };
    let payload_hash = store.prepare(&operation).await?;
    ack.cluster_id = old.cluster_id.clone();
    ack.attempt_id = attempt.into();
    ack.payload_hash = payload_hash.clone();
    ack.sign(&secret(2))?;
    let mut second = ack.clone();
    second.node_id = "S2".into();
    second.node_incarnation = "S2-disk-1".into();
    second.sign(&secret(3))?;
    let decided = Decided {
        index: 1,
        attempt_id: attempt.into(),
        payload_hash: payload_hash.clone(),
        logical_hash: logical_hash.clone(),
        actor_id: binding.sender_key_id.clone(),
        operation_id: binding.operation_id.clone(),
        acks: vec![ack.clone(), second],
    };
    let coordinator = Coordinator::new(
        current.clone(),
        "S1".into(),
        store.clone(),
        control.clone(),
        reqwest::Client::new(),
        "http://127.0.0.1:1".into(),
        secret(6),
    )?;
    ensure!(
        coordinator.validate_decision(&decided).is_err(),
        "unknown old keys must not be implicitly authorized"
    );
    let coordinator = coordinator.with_history(&admin, vec![old.clone()])?;
    coordinator.validate_decision(&decided)?;
    let session = control
        .try_acquire("S1", "S1-disk-2", "history-replay-session-000001")
        .await?
        .context("test leader")?;
    // Represents control data preserved through the administrator's explicit
    // config update. Never overwrite a live namespace in this test.
    ensure!(
        control
            .guarded_txn(
                &session,
                false,
                &[Guard::Value("head".into(), b"0".to_vec())],
                &[
                    Change::Put(decision_key(1), serde_json::to_vec(&decided)?),
                    Change::Put("head".into(), b"1".to_vec()),
                ]
            )
            .await?
    );
    coordinator.catch_up(1).await?;
    ensure!(
        store.applied_index().await? == 1
            && store
                .object(&business::mail_key(&binding)?)
                .await?
                .is_some()
    );
    let receipt = coordinator.receipt(&decided, &binding)?;
    receipt.verify_with_history(&current, &admin, &binding)?;
    ensure!(
        receipt.config_epoch.0 == 1
            && receipt.issuer_config_epoch.0 == 2
            && receipt.commit_index == Some(DecimalU64(1))
    );
    ensure!(
        receipt
            .verify_signature(&old.business_nodes[0].signing_public)
            .is_err(),
        "retired issuer key must not verify the fresh attestation"
    );
    let staged = Staged {
        object_key: business::mail_key(&binding)?,
        actor_id: binding.sender_key_id.clone(),
        operation_id: binding.operation_id.clone(),
        logical_hash,
        payload_hash,
        attempt_id: attempt.into(),
        node_id: "S1".into(),
        binding: Some(binding.clone()),
        ack,
        byte_len: 128,
    };
    let staged_receipt = coordinator.staged_receipt(&staged, &binding, 100)?;
    staged_receipt.verify_with_history(&current, &admin, &binding)?;
    ensure!(staged_receipt.commit_index.is_none() && staged_receipt.replica_evidence.len() == 1);
    control.release(&session).await?;
    let mut client = etcd_client::Client::connect(&endpoints, None).await?;
    client
        .delete(
            control.prefix().to_owned(),
            Some(etcd_client::DeleteOptions::new().with_prefix()),
        )
        .await?;
    store.close().await;
    Ok(())
}
