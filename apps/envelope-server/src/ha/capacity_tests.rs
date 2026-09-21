use super::*;
use crate::storage::v2::DatabaseIdentity;
use envelope_core::{Identity, encode_bytes};
use sqlx::{Connection, SqliteConnection, sqlite::SqliteConnectOptions};
use std::path::PathBuf;

struct Harness {
    coordinator: Coordinator,
    session: Arc<LeaderSession>,
    endpoints: Vec<String>,
    sender: Identity,
    recipient: Identity,
    peer: tokio::task::JoinHandle<()>,
}
impl Drop for Harness {
    fn drop(&mut self) {
        self.peer.abort();
    }
}
impl Harness {
    async fn new() -> Result<Self> {
        let endpoints: Vec<String> = std::env::var("ETCD_ENDPOINTS")?
            .split(',')
            .map(str::to_owned)
            .collect();
        let admin = Identity::generate("admin");
        let s1 = Identity::generate("S1");
        let s2 = Identity::generate("S2");
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let mut config = ClusterConfigV2 {
            protocol_version: 2,
            cluster_id: format!("capacity-{stamp}"),
            control_generation: 1.into(),
            config_epoch: 1.into(),
            business_nodes: vec![
                BusinessNode {
                    node_id: "S1".into(),
                    public_url: "https://s1.example.test/".into(),
                    signing_public: s1.public.signing_public.clone(),
                    node_incarnation: "s1-disk-1".into(),
                },
                BusinessNode {
                    node_id: "S2".into(),
                    public_url: "https://s2.example.test/".into(),
                    signing_public: s2.public.signing_public.clone(),
                    node_incarnation: "s2-disk-1".into(),
                },
            ],
            control_node_ids: vec!["Q".into(), "S1".into(), "S2".into()],
            issued_at: (now_ms() - 1000).into(),
            not_after: (now_ms() + 3_600_000).into(),
            signature: String::new(),
        };
        config.sign(&admin.signing_secret)?;
        let control = Control::connect(&endpoints, &config, None).await?;
        control.initialize().await?;
        let session = Arc::new(
            control
                .try_acquire("S1", "s1-disk-1", "capacity-test-session-00001")
                .await?
                .context("leader")?,
        );
        ensure!(
            control
                .publish_ready(&session, 0, ServiceMode::Degraded)
                .await?
        );
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../target/ha-capacity-tests/{stamp}/business.sqlite3"
        ));
        let store = V2Store::open(
            &path,
            DatabaseIdentity {
                cluster_id: config.cluster_id.clone(),
                control_generation: 1,
                node_id: "S1".into(),
                node_incarnation: "s1-disk-1".into(),
            },
        )
        .await?;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let peer_url = format!("http://{}", listener.local_addr()?);
        let app =
            axum::Router::new().fallback(|| async { axum::http::StatusCode::SERVICE_UNAVAILABLE });
        let peer = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let coordinator = Coordinator::new(
            config,
            "S1".into(),
            store,
            control,
            reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(10))
                .build()?,
            peer_url,
            s1.signing_secret,
        )?
        .with_history(&admin.public.signing_public, vec![])?;
        *coordinator.session.write().await = Some(session.clone());
        Ok(Self {
            coordinator,
            session,
            endpoints,
            sender: Identity::generate("sender"),
            recipient: Identity::generate("recipient"),
            peer,
        })
    }
    fn request(&self, id: &str, size: usize) -> Result<SignedRequest> {
        let bytes = vec![42; size];
        let binding = EnvelopeBinding {
            operation_id: id.into(),
            sender_key_id: self.sender.public.key_id.clone(),
            recipient_key_id: self.recipient.public.key_id.clone(),
            envelope_id: format!("envelope-{id}"),
            envelope_sha256: digest(&bytes),
            not_after: (now_ms() + 600_000).into(),
        };
        let body = StoreEnvelopeBody {
            binding,
            sender_contact: self.sender.public.clone(),
            envelope_b64: encode_bytes(&bytes),
            created_at: now_ms().into(),
        };
        let bytes = serde_json::to_vec(&body)?;
        let mut auth = RequestAuth {
            protocol_version: 2,
            cluster_id: self.coordinator.config.cluster_id.clone(),
            control_generation: 1.into(),
            config_epoch: 1.into(),
            actor_id: self.sender.public.key_id.clone(),
            operation_id: id.into(),
            nonce: format!("capacity-request-{id}"),
            requested_at: now_ms().into(),
            request_kind: RequestKind::StoreEnvelope,
            body_sha256: digest(&bytes),
            signature: String::new(),
        };
        auth.sign(&self.sender.signing_secret)?;
        Ok(SignedRequest {
            auth,
            body_b64: encode_bytes(&bytes),
        })
    }
    async fn payload_counts(&self) -> Result<(i64, i64)> {
        let mut db = SqliteConnection::connect_with(
            &SqliteConnectOptions::new()
                .filename(self.coordinator.store.path())
                .read_only(true),
        )
        .await?;
        let rows = sqlx::query_scalar("SELECT COUNT(*) FROM ha_payloads")
            .fetch_one(&mut db)
            .await?;
        let bytes = sqlx::query_scalar("SELECT COALESCE(SUM(length(bytes)),0) FROM ha_payloads")
            .fetch_one(&mut db)
            .await?;
        db.close().await?;
        Ok((rows, bytes))
    }
    async fn close(&self) -> Result<()> {
        self.coordinator.store.close().await;
        // Some cases explicitly revoke this session before electing a new one.
        let _ = self.coordinator.control.release(&self.session).await;
        let mut client = etcd_client::Client::connect(self.endpoints.clone(), None).await?;
        client
            .delete(
                self.coordinator.control.prefix(),
                Some(etcd_client::DeleteOptions::new().with_prefix()),
            )
            .await?;
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires isolated ETCD_ENDPOINTS; checks SQLite payload rows under repeated 8 MiB staging/upgrades"]
async fn repeated_stage_and_failed_background_upgrade_reuse_durable_payloads() -> Result<()> {
    let harness = Harness::new().await?;
    let c = &harness.coordinator;
    let request = harness.request("large-stage", 8 * 1024 * 1024)?;
    let (original, revision) = match c.submit_or_stage(&request).await? {
        Submission::Staged(s, r) => (s, r),
        _ => anyhow::bail!("expected staged"),
    };
    let staged_counts = harness.payload_counts().await?;
    ensure!(staged_counts.0 == 1 && staged_counts.1 > 8 * 1024 * 1024);
    let mut forged = request.clone();
    forged.auth.signature.clear();
    ensure!(
        c.submit_or_stage(&forged).await.is_err(),
        "reused proof bypassed request authentication"
    );
    let conflict = harness.request("large-stage", 1024)?;
    ensure!(
        c.submit_or_stage(&conflict).await.is_err(),
        "same ID with another body reused a proof"
    );
    for _ in 0..2 {
        let (stage, rev) = c.stage(&request).await?;
        ensure!(stage.attempt_id == original.attempt_id && rev == revision);
    }
    ensure!(
        harness.payload_counts().await? == staged_counts,
        "staging retry wrote another body"
    );
    // A healthy status may briefly precede a failed peer prepare. Clients must
    // still return the original stage and leave promotion to the reconciler.
    ensure!(
        c.control
            .publish_ready(&harness.session, 0, ServiceMode::Normal)
            .await?
    );
    for _ in 0..2 {
        match c.submit_or_stage(&request).await? {
            Submission::Staged(s, r) => {
                ensure!(s.attempt_id == original.attempt_id && r == revision)
            }
            _ => anyhow::bail!("unexpected promotion"),
        }
    }
    ensure!(harness.payload_counts().await? == staged_counts);
    ensure!(c.reconcile_degraded().await.is_err());
    let failed_upgrade = harness.payload_counts().await?;
    ensure!(
        failed_upgrade.0 == 2,
        "one failed promotion should have one durable attempt plus original stage"
    );
    for _ in 0..2 {
        c.reconcile_cursors.lock().await.1 = None;
        ensure!(c.reconcile_degraded().await.is_err());
    }
    ensure!(
        harness.payload_counts().await? == failed_upgrade,
        "failed background retry grew durable payloads"
    );
    let binding = original.binding.clone().context("binding")?;
    c.staged_receipt(&original, &binding, revision)?
        .verify_with_history(
            &c.config,
            c.administrator_public.as_deref().unwrap(),
            &binding,
        )?;
    // End the term while preserving the old stage. A new term must seal the
    // obsolete failed promotion, retain the stage, and allocate only one retry.
    c.control.release(&harness.session).await?;
    let session = Arc::new(
        c.control
            .try_acquire("S1", "s1-disk-1", "capacity-next-session-00001")
            .await?
            .context("next leader")?,
    );
    *c.session.write().await = Some(session.clone());
    ensure!(
        c.control
            .publish_ready(&session, 0, ServiceMode::Normal)
            .await?
    );
    c.reconcile_cursors.lock().await.1 = None;
    ensure!(c.reconcile_degraded().await.is_err());
    ensure!(
        harness.payload_counts().await?.0 == 2,
        "old failed attempt was not collected or stage was lost"
    );
    ensure!(
        c.store
            .prepared_operation(&original.attempt_id)
            .await?
            .is_some(),
        "staged proof payload must survive cleanup"
    );
    std::fs::write(
        c.store.path().with_file_name("capacity-verified.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
        "test_ciphertext_bytes":8*1024*1024,"stage_payload_rows":staged_counts.0,"stage_payload_bytes":staged_counts.1,
        "failed_promotion_payload_rows":failed_upgrade.0,"failed_promotion_payload_bytes":failed_upgrade.1,
        "stage_retries_no_growth":true,"normal_client_retries_no_growth":true,"failed_upgrade_retries_no_growth":true,
        "old_term_failed_attempt_collected":true,"original_stage_preserved":true,"authentication_and_content_conflict_rejected":true}))?,
    )?;
    c.control.release(&session).await?;
    harness.close().await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires isolated ETCD_ENDPOINTS; full usage rejects before any SQLite body insertion"]
async fn full_quota_rejects_normal_and_degraded_before_body_prepare() -> Result<()> {
    let harness = Harness::new().await?;
    let c = &harness.coordinator;
    let request = harness.request("quota-full", 1024 * 1024)?;
    let global = serde_json::to_vec(&Usage {
        count: 1,
        bytes: 1024 * 1024 * 1024,
    })?;
    ensure!(
        c.control
            .guarded_txn(
                &harness.session,
                true,
                &[],
                &[Change::Put("usage/global".into(), global)]
            )
            .await?
    );
    for mode in [ServiceMode::Degraded, ServiceMode::Normal] {
        ensure!(c.control.publish_ready(&harness.session, 0, mode).await?);
        for _ in 0..3 {
            let error = c
                .submit_or_stage(&request)
                .await
                .err()
                .context("full quota unexpectedly accepted")?;
            ensure!(
                error.to_string().contains("RATE_LIMITED"),
                "wrong refusal: {error}"
            );
            ensure!(
                harness.payload_counts().await? == (0, 0),
                "quota refusal persisted a body"
            );
        }
    }
    let key = format!(
        "usage/{}",
        digest(harness.recipient.public.key_id.as_bytes())
    );
    ensure!(
        c.control
            .guarded_txn(
                &harness.session,
                true,
                &[],
                &[
                    Change::Put(
                        "usage/global".into(),
                        serde_json::to_vec(&Usage::default())?
                    ),
                    Change::Put(
                        key,
                        serde_json::to_vec(&Usage {
                            count: 1000,
                            bytes: 0
                        })?
                    )
                ]
            )
            .await?
    );
    ensure!(c.submit_or_stage(&request).await.is_err());
    ensure!(harness.payload_counts().await? == (0, 0));
    harness.close().await
}
