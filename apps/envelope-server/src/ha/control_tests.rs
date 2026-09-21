use super::*;
use envelope_core::Identity;
use envelope_server_core::ha::{BusinessNode, HaSigned};
use std::sync::atomic::AtomicU64;

fn test_config() -> ClusterConfigV2 {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let admin = Identity::generate("test-admin");
    let mut config = ClusterConfigV2 {
        protocol_version: 2,
        cluster_id: format!(
            "control-test-{stamp}-{}",
            NEXT.fetch_add(1, Ordering::Relaxed)
        ),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        business_nodes: vec![
            BusinessNode {
                node_id: "S1".into(),
                public_url: "https://s1.example.test/".into(),
                signing_public: Identity::generate("s1").public.signing_public,
                node_incarnation: "s1-disk-1".into(),
            },
            BusinessNode {
                node_id: "S2".into(),
                public_url: "https://s2.example.test/".into(),
                signing_public: Identity::generate("s2").public.signing_public,
                node_incarnation: "s2-disk-1".into(),
            },
        ],
        control_node_ids: vec!["Q".into(), "S1".into(), "S2".into()],
        issued_at: 1.into(),
        not_after: u64::MAX.into(),
        signature: String::new(),
    };
    config.sign(&admin.signing_secret).unwrap();
    config
}
fn endpoints() -> Vec<String> {
    std::env::var("ETCD_ENDPOINTS")
        .expect("set ETCD_ENDPOINTS to an isolated three-member test cluster")
        .split(',')
        .map(str::to_owned)
        .collect()
}
async fn control() -> Control {
    Control::connect(&endpoints(), &test_config(), None)
        .await
        .unwrap()
}
async fn cleanup(control: &Control) {
    control.pool.call(|mut client| {
        let prefix = control.prefix.clone();
        async move { client.delete(prefix, Some(etcd_client::DeleteOptions::new().with_prefix())).await }
    }).await.unwrap();
}

#[test]
fn heads_reject_noncanonical_or_overflow() {
    assert_eq!(parse_head(b"0").unwrap(), 0);
    assert_eq!(parse_head(b"42").unwrap(), 42);
    for bytes in [
        b"".as_slice(),
        b"01",
        b"-1",
        b"1.0",
        b"18446744073709551616",
    ] {
        assert!(parse_head(bytes).is_err());
    }
}

#[tokio::test]
async fn plaintext_remote_control_endpoints_fail_before_connect() {
    let cfg = test_config();
    assert!(
        Control::connect(&["http://example.test:2379".into()], &cfg, None)
            .await
            .is_err()
    );
    assert!(
        Control::connect(
            &["https://user:password@example.test:2379".into()],
            &cfg,
            None
        )
        .await
        .is_err()
    );
    assert!(Control::connect(&[], &cfg, None).await.is_err());
}

#[tokio::test]
#[ignore = "requires ETCD_ENDPOINTS pointing at isolated three-member etcd"]
async fn etcd_commits_are_cas_fenced_and_old_session_cannot_resume() {
    let control = control().await;
    control.initialize().await.unwrap();
    control.initialize().await.unwrap();
    let old = control
        .try_acquire("S1", "s1-disk-1", "leader-session-0000000001")
        .await
        .unwrap()
        .unwrap();
    assert!(control.check_authority(&old, true).await.is_err());
    assert!(
        !control
            .publish_ready(&old, 1, ServiceMode::Normal)
            .await
            .unwrap()
    );
    assert!(
        control
            .publish_ready(&old, 0, ServiceMode::Normal)
            .await
            .unwrap()
    );
    let guards = [
        Guard::Value("head".into(), b"0".to_vec()),
        Guard::Missing("decisions/00000000000000000001".into()),
        Guard::Missing("attempts/attempt1".into()),
    ];
    let changes = [
        Change::Put("head".into(), b"1".to_vec()),
        Change::Put(
            "decisions/00000000000000000001".into(),
            b"{\"hash\":\"metadata-only\"}".to_vec(),
        ),
        Change::Put("attempts/attempt1".into(), b"committed".to_vec()),
    ];
    assert!(
        control
            .guarded_txn(&old, true, &guards, &changes)
            .await
            .unwrap()
    );
    assert!(
        !control
            .guarded_txn(&old, true, &guards, &changes)
            .await
            .unwrap()
    );
    let snapshot = control.snapshot(&["attempts/attempt1"]).await.unwrap();
    assert_eq!(snapshot.head_index, 1);
    assert_eq!(snapshot.entries["attempts/attempt1"].value, b"committed");
    control.release(&old).await.unwrap();
    let new = control
        .try_acquire("S2", "s2-disk-1", "leader-session-0000000002")
        .await
        .unwrap()
        .unwrap();
    assert!(new.term > old.term);
    assert!(
        control
            .publish_ready(&new, 1, ServiceMode::Degraded)
            .await
            .unwrap()
    );
    assert!(
        !control
            .guarded_txn(
                &old,
                false,
                &[],
                &[Change::Put("objects/forged".into(), b"stale".to_vec())]
            )
            .await
            .unwrap()
    );
    assert!(control.check_authority(&old, false).await.is_err());
    assert!(
        !control
            .publish_ready(&old, 1, ServiceMode::Normal)
            .await
            .unwrap()
    );
    assert!(
        !control
            .snapshot(&["objects/forged"])
            .await
            .unwrap()
            .entries
            .contains_key("objects/forged")
    );
    control.release(&new).await.unwrap();
    cleanup(&control).await;
}

#[tokio::test]
#[ignore = "requires ETCD_ENDPOINTS pointing at isolated three-member etcd"]
async fn etcd_competing_candidates_produce_one_leader_and_metadata_limits_hold() {
    let control = control().await;
    control.initialize().await.unwrap();
    let (first, second) = tokio::join!(
        control.try_acquire("S1", "s1-disk-1", "candidate-session-00000001"),
        control.try_acquire("S2", "s2-disk-1", "candidate-session-00000002")
    );
    let first = first.unwrap();
    let second = second.unwrap();
    assert_ne!(first.is_some(), second.is_some());
    let leader = first.or(second).unwrap();
    assert!(
        control
            .publish_ready(&leader, 0, ServiceMode::Normal)
            .await
            .unwrap()
    );
    for reserved in ["config", "leader", "ready"] {
        assert!(
            control
                .guarded_txn(&leader, false, &[], &[Change::Delete(reserved.into())])
                .await
                .is_err()
        );
    }
    for invalid in ["../other", "/other", "objects//x", "objects/x/"] {
        assert!(
            control
                .guarded_txn(&leader, false, &[], &[Change::Put(invalid.into(), vec![])])
                .await
                .is_err()
        );
    }
    assert!(
        control
            .guarded_txn(
                &leader,
                false,
                &[],
                &[Change::Put(
                    "objects/large".into(),
                    vec![0; MAX_CONTROL_VALUE_BYTES + 1]
                )]
            )
            .await
            .is_err()
    );
    assert!(
        control
            .guarded_txn(
                &leader,
                false,
                &[],
                &[
                    Change::Put("objects/dup".into(), b"one".to_vec()),
                    Change::Delete("objects/dup".into())
                ]
            )
            .await
            .is_err()
    );
    let changes: Vec<_> = (0..3)
        .map(|i| {
            Change::Put(
                format!("decisions/{i:020}"),
                format!("meta-{i}").into_bytes(),
            )
        })
        .collect();
    assert!(
        control
            .guarded_txn(&leader, true, &[], &changes)
            .await
            .unwrap()
    );
    let first_page = control.scan_prefix("decisions", None, 2).await.unwrap();
    assert_eq!(first_page.entries.len(), 2);
    assert!(first_page.more);
    let cursor = first_page.entries.last_key_value().unwrap().0;
    let second_page = control
        .scan_prefix("decisions", Some(cursor), 2)
        .await
        .unwrap();
    assert_eq!(second_page.entries.len(), 1);
    assert!(!second_page.more);
    assert!(
        control
            .scan_prefix("decisions", Some("objects/wrong-cursor"), 2)
            .await
            .is_err()
    );
    control.release(&leader).await.unwrap();
    cleanup(&control).await;
}

#[tokio::test]
#[ignore = "requires ETCD_ENDPOINTS pointing at isolated three-member etcd"]
async fn etcd_partial_namespace_never_resets_head_or_accepts_mismatched_config() {
    let control = control().await;
    let mut client = control.pool.clients[0].clone();
    client
        .put(control.key("objects/orphan").unwrap(), "orphan", None)
        .await
        .unwrap();
    assert!(control.initialize().await.is_err());
    assert!(
        client
            .get(control.key("head").unwrap(), None)
            .await
            .unwrap()
            .kvs()
            .is_empty()
    );
    cleanup(&control).await;
    control.initialize().await.unwrap();
    client
        .delete(control.key("head").unwrap(), None)
        .await
        .unwrap();
    assert!(control.initialize().await.is_err());
    assert!(
        client
            .get(control.key("head").unwrap(), None)
            .await
            .unwrap()
            .kvs()
            .is_empty()
    );
    client
        .put(control.key("head").unwrap(), "00", None)
        .await
        .unwrap();
    assert!(control.snapshot(&[]).await.is_err());
    client
        .put(control.key("head").unwrap(), "0", None)
        .await
        .unwrap();
    client
        .put(control.key("config").unwrap(), "unauthorized-config", None)
        .await
        .unwrap();
    assert!(control.snapshot(&[]).await.is_err());
    cleanup(&control).await;
}

#[tokio::test]
#[ignore = "requires ETCD_ENDPOINTS; exercises renew beyond lease TTL and Drop"]
async fn etcd_keepalive_is_independent_and_drop_stops_renewing() {
    // Match runtime unary timeout options as well as the long-lived stream.
    let control = Control::connect(
        &endpoints(),
        &test_config(),
        Some(ConnectOptions::default().with_timeout(Duration::from_secs(5))),
    )
    .await
    .unwrap();
    control.initialize().await.unwrap();
    let session = control
        .try_acquire("S1", "s1-disk-1", "renew-session-000000000001")
        .await
        .unwrap()
        .unwrap();
    assert!(
        control
            .publish_ready(&session, 0, ServiceMode::Normal)
            .await
            .unwrap()
    );
    tokio::time::sleep(Duration::from_secs(LEASE_TTL_SECONDS as u64 + 3)).await;
    control.check_authority(&session, true).await.unwrap();
    assert!(session.keepalive_healthy());
    drop(session);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if control.snapshot(&[]).await.unwrap().leader.is_none() {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "dropped owner continued renewing lease"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let replacement = control
        .try_acquire("S2", "s2-disk-1", "renew-session-000000000002")
        .await
        .unwrap()
        .unwrap();
    control.release(&replacement).await.unwrap();
    cleanup(&control).await;
}

/// Own processes and data paths: never stop or reconfigure the user's cluster.
struct FaultNode {
    executable: std::path::PathBuf,
    arguments: Vec<String>,
    log_root: std::path::PathBuf,
    process: Option<std::process::Child>,
}
impl FaultNode {
    fn start(&mut self) {
        let mut command = std::process::Command::new(&self.executable);
        command
            .args(&self.arguments)
            .stdin(std::process::Stdio::null())
            .stdout(
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(self.log_root.join("stdout.log"))
                    .unwrap(),
            )
            .stderr(
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(self.log_root.join("stderr.log"))
                    .unwrap(),
            );
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        self.process = Some(command.spawn().expect("start isolated etcd process"));
    }
    fn stop(&mut self) {
        if let Some(mut process) = self.process.take() {
            let _ = process.kill();
            let _ = process.wait();
        }
    }
}
impl Drop for FaultNode {
    fn drop(&mut self) {
        self.stop();
    }
}
struct FaultCluster {
    nodes: Vec<FaultNode>,
    endpoints: Vec<String>,
}

#[tokio::test(flavor="multi_thread",worker_threads=4)]
#[ignore="requires ETCD_BIN; proves one failed client endpoint must not disrupt the surviving majority"]
async fn etcd_one_dead_endpoint_preserves_continuous_majority_reads_and_transactions() {
    let mut cluster=FaultCluster::start();
    let config=test_config();
    let options=Some(ConnectOptions::default().with_timeout(Duration::from_secs(5)));
    let balanced=Control::connect(&cluster.endpoints,&config,options.clone()).await.unwrap();
    let deadline=tokio::time::Instant::now()+Duration::from_secs(25);
    loop {
        if balanced.initialize().await.is_ok() {break}
        assert!(tokio::time::Instant::now()<deadline,"cluster startup");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    // Warm every configured member before the fault, excluding startup races.
    for endpoint in &cluster.endpoints {
        let direct=Control::connect(&[endpoint.clone()],&config,options.clone()).await.unwrap();
        loop {
            if direct.snapshot(&[]).await.is_ok() {break}
            assert!(tokio::time::Instant::now()<deadline,"member did not warm up");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    let survivor=Control::connect(&cluster.endpoints[1..],&config,options).await.unwrap();
    // Election and renewal initially use the endpoint that is about to die.
    let session=balanced.try_acquire("S2","s2-disk-1","majority-fault-session-00001").await.unwrap().unwrap();
    assert!(balanced.publish_ready(&session,0,ServiceMode::Degraded).await.unwrap());
    for _ in 0..10 {balanced.snapshot(&[]).await.unwrap();}
    cluster.nodes[0].stop();
    // Allow the remaining Raft members to elect; failures after this window are
    // not attributed to ordinary leader election convergence.
    let recovery_deadline=tokio::time::Instant::now()+Duration::from_secs(15);
    loop {
        if survivor.snapshot(&[]).await.is_ok() {break}
        assert!(tokio::time::Instant::now()<recovery_deadline,"surviving majority unavailable");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let fault_started=tokio::time::Instant::now();
    let mut failures=Vec::new();let mut direct_successes=0;let mut balanced_successes=0;
    for step in 0..40 {
        survivor.snapshot(&[]).await.expect("two surviving members must serve linearizable reads");
        assert!(survivor.guarded_txn(&session,false,&[],&[Change::Put("objects/direct-majority".into(),step.to_string().into_bytes())]).await.unwrap());
        direct_successes+=1;
        match balanced.snapshot(&[]).await {Ok(_)=>balanced_successes+=1,Err(error)=>failures.push(format!("read {step}: {error:#}"))};
        match balanced.guarded_txn(&session,false,&[],&[Change::Put("objects/balanced-majority".into(),step.to_string().into_bytes())]).await {
            Ok(true)=>balanced_successes+=1,Ok(false)=>failures.push(format!("write {step}: false comparison")),Err(error)=>failures.push(format!("write {step}: {error:#}")),
        }
        match balanced.scan_prefix("objects",None,10).await {
            Ok(page) if page.entries.len()==2 => balanced_successes+=1,
            Ok(page) => failures.push(format!("scan {step}: unexpected {} entries",page.entries.len())),
            Err(error) => failures.push(format!("scan {step}: {error:#}")),
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(fault_started.elapsed()>Duration::from_secs(LEASE_TTL_SECONDS as u64));
    assert!(session.keepalive_healthy(),"renewals must fail over without losing a still valid lease");
    let current=balanced.check_authority(&session,true).await.unwrap();
    assert_eq!(current.leader.unwrap().create_revision,session.term as i64,"no leadership churn while quorum survives");
    balanced.release(&session).await.unwrap();
    assert!(balanced.snapshot(&[]).await.unwrap().leader.is_none(),"revoke must reach the surviving majority");
    // A fresh process can grant/acquire with its first configured origin down.
    let fresh=Control::connect(&cluster.endpoints,&config,None).await.unwrap();
    let next=fresh.try_acquire("S2","s2-disk-1","majority-fault-session-00002").await.unwrap().unwrap();
    assert!(next.term>session.term);
    assert!(fresh.publish_ready(&next,0,ServiceMode::Degraded).await.unwrap());
    drop(next);
    let dropped_deadline=tokio::time::Instant::now()+Duration::from_secs(5);
    while fresh.snapshot(&[]).await.unwrap().leader.is_some() {
        assert!(tokio::time::Instant::now()<dropped_deadline,"Drop did not revoke through a surviving endpoint");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let evidence=serde_json::json!({"stopped_endpoint":cluster.endpoints[0],"survivor_linearizable_read_and_txn_pairs":direct_successes,
        "pooled_successful_rpcs":balanced_successes,"pooled_failed_rpcs":failures.len(),"errors":failures,
        "continued_millis":fault_started.elapsed().as_millis(),"lease_survived_original_ttl":true,"same_leader_term":session.term,
        "fresh_grant_with_first_endpoint_down":true,"explicit_and_drop_revoke_verified":true});
    let path=cluster.nodes[0].log_root.parent().unwrap().join("one-endpoint-fault.json");
    std::fs::write(&path,serde_json::to_vec_pretty(&evidence).unwrap()).unwrap();
    println!("Single endpoint fault evidence: {}",path.display());
    cleanup(&survivor).await;
    assert!(failures.is_empty(),"healthy majority disrupted by a dead configured endpoint: {}/120 RPCs failed; first={:?}",failures.len(),failures.first());
}

#[tokio::test]
#[ignore="requires ETCD_ENDPOINTS; response loss must never turn a failed CAS into success"]
async fn etcd_ambiguous_commit_retry_preserves_exact_cas_and_head() {
    let control=control().await;
    control.initialize().await.unwrap();
    let calls=Arc::new(AtomicUsize::new(0));
    let txn=Txn::new().when(vec![Compare::value(control.key("head").unwrap(),CompareOp::Equal,b"0".to_vec())])
        .and_then(vec![TxnOp::put(control.key("head").unwrap(),b"1".to_vec(),None)]);
    let response=control.pool.call(|mut client| {
        let txn=txn.clone();let calls=calls.clone();
        async move {
            let response=client.txn(txn).await?;
            if calls.fetch_add(1,Ordering::SeqCst)==0 {
                assert!(response.succeeded());
                return Err(etcd_client::Error::IoError(std::io::Error::new(std::io::ErrorKind::ConnectionReset,"injected response loss AFTER actual commit")));
            }
            Ok(response)
        }
    }).await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst),2);
    assert!(!response.succeeded(),"lost response is ambiguous, never invent success from a false retry CAS");
    assert_eq!(control.snapshot(&[]).await.unwrap().head_index,1,"one commit only");
    cleanup(&control).await;
}
impl FaultCluster {
    fn start() -> Self {
        let executable = std::path::PathBuf::from(
            std::env::var("ETCD_BIN")
                .expect("set ETCD_BIN to the etcd executable for isolated fault testing"),
        );
        assert!(executable.is_file());
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(format!("../../target/ha-control-fault/{stamp}"));
        std::fs::create_dir_all(&root).unwrap();
        let listeners: Vec<_> = (0..6)
            .map(|_| std::net::TcpListener::bind("127.0.0.1:0").unwrap())
            .collect();
        let ports: Vec<_> = listeners
            .iter()
            .map(|l| l.local_addr().unwrap().port())
            .collect();
        let endpoints: Vec<_> = (0..3)
            .map(|i| format!("http://127.0.0.1:{}", ports[i * 2]))
            .collect();
        let peers: Vec<_> = (0..3)
            .map(|i| format!("http://127.0.0.1:{}", ports[i * 2 + 1]))
            .collect();
        let initial = (0..3)
            .map(|i| format!("node{i}={}", peers[i]))
            .collect::<Vec<_>>()
            .join(",");
        let mut nodes = Vec::new();
        for i in 0..3 {
            let node_root = root.join(format!("node{i}"));
            std::fs::create_dir_all(&node_root).unwrap();
            let arguments = vec![
                "--name".into(),
                format!("node{i}"),
                "--data-dir".into(),
                node_root.join("data").to_string_lossy().into_owned(),
                "--listen-client-urls".into(),
                endpoints[i].clone(),
                "--advertise-client-urls".into(),
                endpoints[i].clone(),
                "--listen-peer-urls".into(),
                peers[i].clone(),
                "--initial-advertise-peer-urls".into(),
                peers[i].clone(),
                "--initial-cluster".into(),
                initial.clone(),
                "--initial-cluster-token".into(),
                format!("isolated-fault-{stamp}"),
                "--initial-cluster-state".into(),
                "new".into(),
                "--log-level".into(),
                "warn".into(),
            ];
            nodes.push(FaultNode {
                executable: executable.clone(),
                arguments,
                log_root: node_root,
                process: None,
            });
        }
        drop(listeners);
        for node in &mut nodes {
            node.start();
        }
        Self { nodes, endpoints }
    }
}

#[tokio::test]
#[ignore = "requires ETCD_BIN; starts and kills only its own isolated etcd processes"]
async fn etcd_lost_majority_rejects_cached_leader_reads_and_writes() {
    let mut cluster = FaultCluster::start();
    let control = Control::connect(&cluster.endpoints, &test_config(), None)
        .await
        .unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if control.initialize().await.is_ok() {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "isolated cluster failed to start"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let old = control
        .try_acquire("S1", "s1-disk-1", "fault-old-session-000000001")
        .await
        .unwrap()
        .unwrap();
    assert!(
        control
            .publish_ready(&old, 0, ServiceMode::Normal)
            .await
            .unwrap()
    );
    assert!(old.keepalive_healthy());
    cluster.nodes[1].stop();
    cluster.nodes[2].stop();
    let lost_at = tokio::time::Instant::now();
    let read_started=tokio::time::Instant::now();
    assert!(
        control.check_authority(&old, true).await.is_err(),
        "cached leader must not satisfy a linearizable read without quorum"
    );
    let read_ms=read_started.elapsed().as_millis();
    assert!(read_ms<5500,"read did not honor the shared RPC deadline");
    let write_started=tokio::time::Instant::now();
    assert!(
        control
            .guarded_txn(
                &old,
                false,
                &[],
                &[Change::Put(
                    "objects/minority-write".into(),
                    b"must-not-commit".to_vec()
                )]
            )
            .await
            .is_err(),
        "cached lease must not authorize a minority write"
    );
    let write_ms=write_started.elapsed().as_millis();
    assert!(write_ms<5500,"transaction did not honor the shared RPC deadline");
    assert!(control.scan_prefix("objects",None,10).await.is_err(),"minority served a linearizable scan");
    assert!(control.pool.call(|mut client| async move {client.lease_grant(LEASE_TTL_SECONDS,None).await}).await.is_err(),
        "minority granted a new lease");
    // The renewal worker must give up; ordinary requests do not keep it alive.
    tokio::time::sleep_until(lost_at + Duration::from_secs(18)).await;
    assert!(!old.keepalive_healthy());
    cluster.nodes[1].start();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
    let new = loop {
        match control
            .try_acquire("S2", "s2-disk-1", "fault-new-session-000000001")
            .await
        {
            Ok(Some(session)) => break session,
            _ => {}
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "majority restored but expired owner still blocked election"
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
    };
    assert!(new.term > old.term);
    assert!(
        control
            .publish_ready(&new, 0, ServiceMode::Degraded)
            .await
            .unwrap()
    );
    assert!(
        !control
            .guarded_txn(
                &old,
                false,
                &[],
                &[Change::Put(
                    "objects/resumed-old-write".into(),
                    b"must-not-commit".to_vec()
                )]
            )
            .await
            .unwrap()
    );
    let snapshot = control
        .snapshot(&["objects/minority-write", "objects/resumed-old-write"])
        .await
        .unwrap();
    assert!(snapshot.entries.is_empty());
    assert_eq!(snapshot.head_index, 0);
    let evidence=serde_json::json!({"linearizable_read_rejected":true,"write_rejected":true,"scan_rejected":true,
        "lease_grant_rejected":true,"keepalive_stopped":true,"read_millis":read_ms,"write_millis":write_ms,
        "old_term":old.term,"new_term":new.term,"old_owner_fenced_after_majority_restore":true,"head_unchanged":true});
    let path=cluster.nodes[0].log_root.parent().unwrap().join("majority-loss-fenced.json");
    std::fs::write(&path,serde_json::to_vec_pretty(&evidence).unwrap()).unwrap();
    println!("Majority-loss evidence: {}",path.display());
    control.release(&new).await.unwrap();
    cleanup(&control).await;
}

#[tokio::test]
#[ignore = "requires ETCD_ENDPOINTS pointing at isolated three-member etcd"]
async fn etcd_attempt_sealing_and_late_commit_are_mutually_exclusive() {
    let control = control().await;
    control.initialize().await.unwrap();
    let leader = control
        .try_acquire("S1", "s1-disk-1", "attempt-race-session-000001")
        .await
        .unwrap()
        .unwrap();
    assert!(
        control
            .publish_ready(&leader, 0, ServiceMode::Normal)
            .await
            .unwrap()
    );
    assert!(
        control
            .guarded_txn(
                &leader,
                true,
                &[Guard::Missing("attempts/race".into())],
                &[Change::Put("attempts/race".into(), b"open".to_vec())]
            )
            .await
            .unwrap()
    );
    let guards = [Guard::Value("attempts/race".into(), b"open".to_vec())];
    let commit = [
        Change::Put("attempts/race".into(), b"committed".to_vec()),
        Change::Put("head".into(), b"1".to_vec()),
    ];
    let seal = [Change::Put("attempts/race".into(), b"sealed".to_vec())];
    let (committed, sealed) = tokio::join!(
        control.guarded_txn(&leader, true, &guards, &commit),
        control.guarded_txn(&leader, true, &guards, &seal)
    );
    let committed = committed.unwrap();
    let sealed = sealed.unwrap();
    assert_ne!(committed, sealed);
    let snapshot = control.snapshot(&["attempts/race"]).await.unwrap();
    assert_eq!(snapshot.head_index, if committed { 1 } else { 0 });
    assert_eq!(
        snapshot.entries["attempts/race"].value,
        if committed {
            b"committed".to_vec()
        } else {
            b"sealed".to_vec()
        }
    );
    assert!(
        !control
            .guarded_txn(&leader, true, &guards, &commit)
            .await
            .unwrap()
    );
    control.release(&leader).await.unwrap();
    cleanup(&control).await;
}
