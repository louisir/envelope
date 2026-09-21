//! Real HTTP + two SQLite databases + three disposable etcd processes. No
//! production listener or existing etcd prefix is touched by this test.
use anyhow::{Context, Result, ensure};
use envelope_core::{Identity, encode_bytes, encrypt_opaque_text, decrypt_opaque_text, create_device_endpoint_update};
use envelope_server::{ha::{control::Control, coordinator::{Coordinator, now_ms}, runtime::{ApiState, public_router, internal_router}}, storage::v2::{DatabaseIdentity,V2Store}};
use envelope_server_core::ha::*;
use serde_json::{Value,json};
use std::{path::{Path,PathBuf},process::{Child,Command,Stdio},sync::Arc,time::Duration};
use tokio::task::JoinHandle;

struct OwnedProcess(Option<Child>);
impl OwnedProcess { fn stop(&mut self) { if let Some(mut child)=self.0.take(){let _=child.kill();let _=child.wait();} } }
impl Drop for OwnedProcess { fn drop(&mut self){self.stop();} }
struct EtcdCluster { nodes:Vec<OwnedProcess>,endpoints:Vec<String>,root:PathBuf }
impl EtcdCluster {
    fn start()->Result<Self> {
        let executable=std::env::var("ETCD_BIN").context("ETCD_BIN must name an etcd executable")?;
        ensure!(Path::new(&executable).is_file(),"etcd executable missing");
        let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
        let root=Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../target/ha-runtime-test/{stamp}"));
        std::fs::create_dir_all(&root)?;
        let reserved=(0..6).map(|_|std::net::TcpListener::bind("127.0.0.1:0")).collect::<std::io::Result<Vec<_>>>()?;
        let ports=reserved.iter().map(|s|s.local_addr().unwrap().port()).collect::<Vec<_>>();
        let endpoints=(0..3).map(|i|format!("http://127.0.0.1:{}",ports[i*2])).collect::<Vec<_>>();
        let peers=(0..3).map(|i|format!("http://127.0.0.1:{}",ports[i*2+1])).collect::<Vec<_>>();
        let initial=(0..3).map(|i|format!("node{i}={}",peers[i])).collect::<Vec<_>>().join(",");
        drop(reserved);
        let mut nodes=Vec::new();
        for i in 0..3 {
            let directory=root.join(format!("etcd-{i}")); std::fs::create_dir_all(&directory)?;
            let mut command=Command::new(&executable);
            command.args(["--name",&format!("node{i}"),"--data-dir",directory.join("data").to_str().unwrap(),
                "--listen-client-urls",&endpoints[i],"--advertise-client-urls",&endpoints[i],
                "--listen-peer-urls",&peers[i],"--initial-advertise-peer-urls",&peers[i],
                "--initial-cluster",&initial,"--initial-cluster-token",&format!("runtime-{stamp}"),"--log-level","warn"])
                .stdin(Stdio::null()).stdout(std::fs::File::create(directory.join("stdout.log"))?)
                .stderr(std::fs::File::create(directory.join("stderr.log"))?);
            #[cfg(windows)] { use std::os::windows::process::CommandExt; command.creation_flags(0x08000000); }
            nodes.push(OwnedProcess(Some(command.spawn()?)));
        }
        Ok(Self{nodes,endpoints,root})
    }
}
struct HttpNode { coordinator:Arc<Coordinator>,url:String,tasks:Vec<JoinHandle<()>> }
impl Drop for HttpNode { fn drop(&mut self){for task in &self.tasks {task.abort();}} }
struct OwnedTasks(Vec<JoinHandle<()>>);
impl Drop for OwnedTasks { fn drop(&mut self){for task in &self.0 {task.abort();}} }

async fn open_control(endpoints:&[String],config:&ClusterConfigV2)->Result<Control> {
    let deadline=tokio::time::Instant::now()+Duration::from_secs(30);
    loop {
        if let Ok(control)=Control::connect(endpoints,config,Some(etcd_client::ConnectOptions::default().with_timeout(Duration::from_secs(3)))).await {
            if control.initialize().await.is_ok(){return Ok(control)}
        }
        ensure!(tokio::time::Instant::now()<deadline,"isolated etcd did not become ready");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
async fn serve_node(root:&Path,config:&ClusterConfigV2,node_id:&str,key:&Identity,admin:&Identity,control:Control,
    public:tokio::net::TcpListener,internal:tokio::net::TcpListener,peer_url:String)->Result<HttpNode> {
    let store=V2Store::open(&root.join(format!("{node_id}.sqlite3")),DatabaseIdentity{cluster_id:config.cluster_id.clone(),
        control_generation:1,node_id:node_id.into(),node_incarnation:format!("{node_id}-disk-1")}).await?;
    let client=reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(10)).build()?;
    let coordinator=Arc::new(Coordinator::new(config.clone(),node_id.into(),store,control,client,peer_url,key.signing_secret.clone())?
        .with_history(&admin.public.signing_public,vec![])?);
    let state=ApiState{coordinator:coordinator.clone(),development_loopback:true};
    let url=format!("http://{}",public.local_addr()?);
    let public_app=public_router(state.clone()); let internal_app=internal_router(state);
    let tasks=vec![tokio::spawn(async move{axum::serve(public,public_app).await.unwrap()}),
        tokio::spawn(async move{axum::serve(internal,internal_app).await.unwrap()})];
    Ok(HttpNode{coordinator,url,tasks})
}
fn request(config:&ClusterConfigV2,actor:&Identity,kind:RequestKind,operation:&str,body:Value)->Result<SignedRequest> {
    let bytes=serde_json::to_vec(&body)?;
    let mut auth=RequestAuth{protocol_version:2,cluster_id:config.cluster_id.clone(),control_generation:config.control_generation,
        config_epoch:config.config_epoch,actor_id:actor.public.key_id.clone(),operation_id:operation.into(),nonce:format!("runtime-request-{operation}-{}",now_ms()),
        requested_at:now_ms().into(),request_kind:kind,body_sha256:sha256_b64(&bytes),signature:String::new()};
    auth.sign(&actor.signing_secret)?;
    Ok(SignedRequest{auth,body_b64:encode_bytes(&bytes)})
}
async fn post(client:&reqwest::Client,node:&HttpNode,path:&str,request:&SignedRequest)->Result<Value> {
    let response=client.post(format!("{}/v2/{path}",node.url)).json(request).send().await?;
    let status=response.status(); let body=response.text().await?;
    ensure!(status.is_success(),"HTTP {status} for {path}: {body}");
    Ok(serde_json::from_str(&body)?)
}
async fn register(client:&reqwest::Client,node:&HttpNode,config:&ClusterConfigV2,actor:&Identity)->Result<()> {
    let endpoint=create_device_endpoint_update(actor,"test-device","test-ticket","test-session",1,1800)?;
    let auth=request(config,actor,RequestKind::RegisterRoute,"register",json!({"owner_contact":actor.public,"endpoint":endpoint,"expected_version":"0"}))?;
    let result=post(client,node,"devices/register",&auth).await?;
    ensure!(result["status"]=="replicated","route not replicated"); Ok(())
}
fn store_request(config:&ClusterConfigV2,sender:&Identity,recipient:&Identity,counter:u64)->Result<(SignedRequest,EnvelopeBinding,Vec<u8>)> {
    let encrypted=encrypt_opaque_text(sender,&recipient.public,"durable runtime payload",counter)?;
    let binding=EnvelopeBinding{operation_id:format!("store-{counter}"),sender_key_id:sender.public.key_id.clone(),recipient_key_id:recipient.public.key_id.clone(),
        envelope_id:encrypted.envelope_id,envelope_sha256:sha256_b64(&encrypted.envelope_bytes),not_after:(now_ms()+60_000).into()};
    let body=json!({"binding":binding,"sender_contact":sender.public,"envelope_b64":encode_bytes(&encrypted.envelope_bytes),"created_at":now_ms().to_string()});
    Ok((request(config,sender,RequestKind::StoreEnvelope,&binding.operation_id,body)?,binding,encrypted.envelope_bytes))
}

#[tokio::test(flavor="multi_thread",worker_threads=4)]
#[ignore="requires ETCD_BIN; owns three isolated etcd processes and two HTTP/SQLite nodes"]
async fn full_runtime_commit_results_switch_and_no_quorum()->Result<()> {
    let mut etcd=EtcdCluster::start()?;
    let admin=Identity::generate("administrator"); let key1=Identity::generate("node1"); let key2=Identity::generate("node2");
    let mut config=ClusterConfigV2{protocol_version:2,cluster_id:format!("runtime-{}",etcd.root.file_name().unwrap().to_string_lossy()),
        control_generation:1.into(),config_epoch:1.into(),business_nodes:vec![
            BusinessNode{node_id:"S1".into(),public_url:"https://s1.example.test/".into(),signing_public:key1.public.signing_public.clone(),node_incarnation:"S1-disk-1".into()},
            BusinessNode{node_id:"S2".into(),public_url:"https://s2.example.test/".into(),signing_public:key2.public.signing_public.clone(),node_incarnation:"S2-disk-1".into()}],
        control_node_ids:vec!["Q".into(),"S1".into(),"S2".into()],issued_at:(now_ms()-1000).into(),not_after:(now_ms()+3_600_000).into(),signature:String::new()};
    config.sign(&admin.signing_secret)?;
    let control1=open_control(&etcd.endpoints,&config).await?; let control2=open_control(&etcd.endpoints,&config).await?;
    let public1=tokio::net::TcpListener::bind("127.0.0.1:0").await?; let public2=tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let internal1=tokio::net::TcpListener::bind("127.0.0.1:0").await?; let internal2=tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let peer1=format!("http://{}",internal1.local_addr()?); let peer2=format!("http://{}",internal2.local_addr()?);
    let s1=serve_node(&etcd.root,&config,"S1",&key1,&admin,control1,public1,internal1,peer2).await?;
    let s2=serve_node(&etcd.root,&config,"S2",&key2,&admin,control2,public2,internal2,peer1).await?;
    let old=Arc::new(s1.coordinator.control.try_acquire("S1","S1-disk-1","runtime-session-one-000001").await?.context("initial leader missing")?);
    *s1.coordinator.session.write().await=Some(old.clone());
    ensure!(s1.coordinator.control.publish_ready(&old,0,ServiceMode::Normal).await?,"initial readiness");
    let http=reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(12)).build()?;
    let alice=Identity::generate("Alice"); let bob=Identity::generate("Bob");
    register(&http,&s1,&config,&alice).await?; register(&http,&s1,&config,&bob).await?;
    let (store,binding,ciphertext)=store_request(&config,&alice,&bob,1)?;
    let original:CommitReceipt=serde_json::from_value(post(&http,&s1,"envelopes",&store).await?)?;
    original.verify_with_history(&config,&admin.public.signing_public,&binding)?;
    ensure!(original.storage_state==StorageState::Replicated,"no two-copy proof");
    let retry:CommitReceipt=serde_json::from_value(post(&http,&s1,"envelopes",&store).await?)?;
    ensure!(retry.commit_index==original.commit_index,"retry allocated a second commit");
    let mut changed:Value=serde_json::from_slice(&store.decoded_body(12*1024*1024)?)?;
    changed["binding"]["envelope_sha256"]=json!(sha256_b64(b"different body"));
    let conflict=request(&config,&alice,RequestKind::StoreEnvelope,&binding.operation_id,changed)?;
    let rejected=http.post(format!("{}/v2/envelopes",s1.url)).json(&conflict).send().await?;
    ensure!(rejected.status()==reqwest::StatusCode::CONFLICT,"same ID changed body was not rejected");
    let pull=request(&config,&bob,RequestKind::PullMailbox,"pull-one",json!({"limit":50,"cursor":null}))?;
    let pulled:PullMailboxResponseV2=serde_json::from_value(post(&http,&s1,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(pulled.items.len()==1,"wrong mailbox size");
    ensure!(pulled.items[0].envelope_b64==encode_bytes(&ciphertext),"body differs after two-copy apply");
    let plain=decrypt_opaque_text(&bob,&alice.public,&ciphertext)?;
    ensure!(plain=="durable runtime payload","recipient could not decrypt original body");
    let mut result=RecipientResult{version:2,sender_key_id:alice.public.key_id.clone(),recipient_key_id:bob.public.key_id.clone(),envelope_id:binding.envelope_id.clone(),
        envelope_sha256:binding.envelope_sha256.clone(),outcome:RecipientOutcome::Delivered,reason_code:String::new(),received_at:now_ms().into(),result_id:"result-one".into(),result_sequence:1.into(),signature:String::new()};
    result.sign(&bob.signing_secret)?;
    let record=request(&config,&bob,RequestKind::RecordResult,"result-one",json!({"result":result,"recipient_contact":bob.public}))?;
    post(&http,&s1,&format!("mailbox/{}/results",bob.public.key_id),&record).await?;
    let status=request(&config,&alice,RequestKind::DeliveryStatus,"status-one",json!({"bindings":[binding]}))?;
    let statuses:DeliveryStatusResponseV2=serde_json::from_value(post(&http,&s1,&format!("delivery/{}/status",alice.public.key_id),&status).await?)?;
    statuses.items[0].result.as_ref().context("missing recipient result")?.verify(&bob.public,&binding)?;
    let canonical:DeliveryStatusResponseV2=serde_json::from_value(post(&http,&s1,"delivery/status",&status).await?)?;
    ensure!(canonical.items.len()==statuses.items.len() && canonical.items[0].binding==statuses.items[0].binding,
        "canonical delivery/status differs from the actor-qualified alias");
    ensure!(serde_json::to_value(&canonical.items[0].result)?==serde_json::to_value(&statuses.items[0].result)?,
        "delivery/status alias returned another recipient result");
    canonical.items[0].receipt.as_ref().context("missing canonical status receipt")?.verify_with_history(&config,&admin.public.signing_public,&binding)?;
    // Bob is registered and has a valid signature, but is not this envelope's
    // sender. Neither the canonical endpoint nor either actor path grants access.
    let other_status=request(&config,&bob,RequestKind::DeliveryStatus,"status-other-sender",json!({"bindings":[binding]}))?;
    for path in ["delivery/status".to_string(),format!("delivery/{}/status",bob.public.key_id),format!("delivery/{}/status",alice.public.key_id)] {
        let denied=http.post(format!("{}/v2/{path}",s1.url)).json(&other_status).send().await?;
        ensure!(denied.status()==reqwest::StatusCode::FORBIDDEN,"non-sender status was not forbidden at {path}");
        let error:Value=denied.json().await?;
        ensure!(error["code"]=="AUTH_FAILED","non-sender rejection was not authorization failure: {error}");
    }
    // A P2P-only result is a replicated business record even when neither VPS
    // ever received the original ciphertext. A later relay retry stays terminal.
    let (p2p_store,p2p_binding,_)=store_request(&config,&alice,&bob,4)?;
    let mut p2p_result=result.clone();
    p2p_result.envelope_id=p2p_binding.envelope_id.clone();p2p_result.envelope_sha256=p2p_binding.envelope_sha256.clone();
    p2p_result.result_id="p2p-result-only".into();p2p_result.sign(&bob.signing_secret)?;
    let p2p_record=request(&config,&bob,RequestKind::RecordResult,"p2p-result-only",json!({"result":p2p_result,"recipient_contact":bob.public}))?;
    let persisted=post(&http,&s1,&format!("mailbox/{}/results",bob.public.key_id),&p2p_record).await?;
    ensure!(persisted["status"]=="replicated","standalone P2P proof was not replicated");
    post(&http,&s1,"envelopes",&p2p_store).await?;
    let hidden:PullMailboxResponseV2=serde_json::from_value(post(&http,&s1,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(hidden.items.is_empty(),"late relay upload resurrected P2P delivered mail");
    let (expiry_store,mut expiry_binding,_)=store_request(&config,&alice,&bob,6)?;
    expiry_binding.not_after=(now_ms()+1800).into();
    let mut expiry_body:Value=serde_json::from_slice(&expiry_store.decoded_body(12*1024*1024)?)?;
    expiry_body["binding"]=serde_json::to_value(&expiry_binding)?;
    let expiry_store=request(&config,&alice,RequestKind::StoreEnvelope,&expiry_binding.operation_id,expiry_body)?;
    post(&http,&s1,"envelopes",&expiry_store).await?;
    tokio::time::sleep(Duration::from_millis(1900)).await;
    s1.coordinator.expire_due("",100).await?;
    let expiry_receipt=s1.coordinator.receipt_for(&expiry_binding).await?;
    expiry_receipt.verify_with_history(&config,&admin.public.signing_public,&expiry_binding)?;
    ensure!(expiry_receipt.delivery_state==DeliveryState::Expired && expiry_receipt.expiry_evidence.is_some(),"expiry lacks a two-replica decision");
    let mut late=result.clone();late.envelope_id=expiry_binding.envelope_id.clone();late.envelope_sha256=expiry_binding.envelope_sha256.clone();
    late.result_id="late-preexpiry-result".into();late.received_at=(expiry_binding.not_after.0-1).into();late.sign(&bob.signing_secret)?;
    let late_request=request(&config,&bob,RequestKind::RecordResult,"late-preexpiry-result",json!({"result":late,"recipient_contact":bob.public}))?;
    post(&http,&s1,&format!("mailbox/{}/results",bob.public.key_id),&late_request).await?;
    let verified_late=s1.coordinator.result_for(&expiry_binding).await?.context("late valid proof was lost")?;
    verified_late.verify(&bob.public,&expiry_binding)?;
    // Data-peer loss retains only an explicitly staged body and independently
    // quorum-persisted recipient proof. Restore must replicate proof first.
    s2.tasks[1].abort();tokio::time::sleep(Duration::from_millis(100)).await;
    let before_stage=s1.coordinator.store.applied_index().await?;
    ensure!(s1.coordinator.control.publish_ready(&old,before_stage,ServiceMode::Degraded).await?,"degraded readiness");
    let (staged_store,staged_binding,_)=store_request(&config,&alice,&bob,5)?;
    let staged:CommitReceipt=serde_json::from_value(post(&http,&s1,"envelopes",&staged_store).await?)?;
    staged.verify_with_history(&config,&admin.public.signing_public,&staged_binding)?;
    ensure!(staged.storage_state==StorageState::StagedSingle && staged.commit_index.is_none(),"degraded write claimed two copies");
    let mut staged_result=result.clone();staged_result.envelope_id=staged_binding.envelope_id.clone();
    staged_result.envelope_sha256=staged_binding.envelope_sha256.clone();staged_result.result_id="staged-result-only".into();staged_result.sign(&bob.signing_secret)?;
    let staged_record=request(&config,&bob,RequestKind::RecordResult,"staged-result-only",json!({"result":staged_result,"recipient_contact":bob.public}))?;
    let stored_result=post(&http,&s1,&format!("mailbox/{}/results",bob.public.key_id),&staged_record).await?;
    ensure!(stored_result["status"]=="staged_single","result failed to persist during data-peer outage");
    let hidden:PullMailboxResponseV2=serde_json::from_value(post(&http,&s1,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(hidden.items.is_empty(),"staged delivered body was redelivered");
    let recovered_listener=tokio::net::TcpListener::bind(s1.coordinator.peer_url.trim_start_matches("http://")).await?;
    let recovered_app=internal_router(ApiState {coordinator:s2.coordinator.clone(),development_loopback:true});
    let recovery_tasks=OwnedTasks(vec![tokio::spawn(async move{axum::serve(recovered_listener,recovered_app).await.unwrap()}),s1.coordinator.start()]);
    let deadline=tokio::time::Instant::now()+Duration::from_secs(20);
    loop {
        if s1.coordinator.receipt_for(&staged_binding).await.is_ok() {break}
        ensure!(tokio::time::Instant::now()<deadline,"staged body did not reconcile after peer restoration");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    recovery_tasks.0[1].abort();
    let hidden:PullMailboxResponseV2=serde_json::from_value(post(&http,&s1,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(hidden.items.is_empty(),"staged terminal resurrected after normal replication");
    let (offline,offline_binding,_)=store_request(&config,&alice,&bob,2)?;
    post(&http,&s1,"envelopes",&offline).await?;
    let head=s1.coordinator.control.snapshot(&[]).await?.head_index;
    s2.coordinator.catch_up(head).await?;
    s1.coordinator.control.release(&old).await?;
    let next=Arc::new(s2.coordinator.control.try_acquire("S2","S2-disk-1","runtime-session-two-000001").await?.context("new leader missing")?);
    ensure!(next.term>old.term,"new term did not advance");
    *s2.coordinator.session.write().await=Some(next.clone());
    ensure!(s2.coordinator.control.publish_ready(&next,head,ServiceMode::Normal).await?,"new readiness");
    let after:PullMailboxResponseV2=serde_json::from_value(post(&http,&s2,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(after.items.len()==1 && after.items[0].binding==offline_binding,"handover lost pending body or resurrected terminal body");
    after.items[0].receipt.verify_with_history(&config,&admin.public.signing_public,&offline_binding)?;
    let old_response=http.post(format!("{}/v2/envelopes",s1.url)).json(&offline).send().await?;
    ensure!(!old_response.status().is_success(),"old leader continued serving writes");
    etcd.nodes[1].stop(); etcd.nodes[2].stop();
    let unavailable=http.post(format!("{}/v2/mailbox/{}/pull",s2.url,bob.public.key_id)).json(&pull).send().await?;
    ensure!(!unavailable.status().is_success(),"minority served authoritative mailbox");
    let (minority_write,_,_)=store_request(&config,&alice,&bob,3)?;
    let refused=http.post(format!("{}/v2/envelopes",s2.url)).json(&minority_write).send().await?;
    ensure!(!refused.status().is_success(),"minority accepted a new envelope");
    ensure!(s2.coordinator.store.applied_index().await?==head,"minority advanced committed business state");
    std::fs::write(etcd.root.join("verified.json"),serde_json::to_vec_pretty(&json!({"cluster_id":config.cluster_id,"head":head,
        "old_term":old.term,"new_term":next.term,"two_copy_commit":true,"same_id_retry":true,"recipient_result":true,
        "controlled_handover":true,"no_quorum_read_rejected":true,"no_quorum_write_rejected":true,
        "p2p_result_without_body":true,"degraded_single_stage":true,"staged_result_no_redelivery":true,"stage_recovery":true,
        "canonical_delivery_status_alias":true,"other_sender_status_denied_both_paths":true,
        "dual_commit_expiry":true,"late_preexpiry_delivery_proof":true}))?)?;
    println!("Runtime evidence: {}",etcd.root.display());
    Ok(())
}

#[tokio::test(flavor="multi_thread",worker_threads=4)]
#[ignore="requires ETCD_BIN; owns isolated etcd and simulates leader session shutdown"]
async fn automatic_runtime_election_after_session_shutdown_recovers_mailbox()->Result<()> {
    let etcd=EtcdCluster::start()?;
    let admin=Identity::generate("administrator"); let keys=[Identity::generate("node1"),Identity::generate("node2")];
    let mut config=ClusterConfigV2{protocol_version:2,cluster_id:format!("automatic-{}",etcd.root.file_name().unwrap().to_string_lossy()),
        control_generation:1.into(),config_epoch:1.into(),business_nodes:keys.iter().enumerate().map(|(i,key)|BusinessNode{
            node_id:format!("S{}",i+1),public_url:format!("https://s{}.example.test/",i+1),signing_public:key.public.signing_public.clone(),
            node_incarnation:format!("S{}-disk-1",i+1)}).collect(),control_node_ids:vec!["Q".into(),"S1".into(),"S2".into()],
        issued_at:(now_ms()-1000).into(),not_after:(now_ms()+3_600_000).into(),signature:String::new()};
    config.sign(&admin.signing_secret)?;
    let control1=open_control(&etcd.endpoints,&config).await?; let control2=open_control(&etcd.endpoints,&config).await?;
    let public1=tokio::net::TcpListener::bind("127.0.0.1:0").await?; let public2=tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let internal1=tokio::net::TcpListener::bind("127.0.0.1:0").await?; let internal2=tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let peer1=format!("http://{}",internal1.local_addr()?); let peer2=format!("http://{}",internal2.local_addr()?);
    let nodes=[serve_node(&etcd.root,&config,"S1",&keys[0],&admin,control1,public1,internal1,peer2).await?,
        serve_node(&etcd.root,&config,"S2",&keys[1],&admin,control2,public2,internal2,peer1).await?];
    let loops=OwnedTasks(nodes.iter().map(|node|node.coordinator.start()).collect());
    let deadline=tokio::time::Instant::now()+Duration::from_secs(20);
    let (leader_index,term)=loop {
        let mut leader=None;
        for (index,node) in nodes.iter().enumerate() {
            if let Ok(status)=node.coordinator.status("initial-election-challenge".into()).await {
                if status.role==NodeRole::Leader && status.ready && status.mode==ServiceMode::Normal {leader=Some((index,status.leader_term.0));}
            }
        }
        if let Some(leader)=leader {break leader}
        ensure!(tokio::time::Instant::now()<deadline,"automatic initial election not ready");
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    let http=reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(12)).build()?;
    let alice=Identity::generate("Alice");let bob=Identity::generate("Bob");
    register(&http,&nodes[leader_index],&config,&alice).await?;register(&http,&nodes[leader_index],&config,&bob).await?;
    let (store,binding,_)=store_request(&config,&alice,&bob,1)?;
    let receipt:CommitReceipt=serde_json::from_value(post(&http,&nodes[leader_index],"envelopes",&store).await?)?;
    receipt.verify_with_history(&config,&admin.public.signing_public,&binding)?;
    let failed_at=tokio::time::Instant::now();
    loops.0[leader_index].abort();
    for task in &nodes[leader_index].tasks {task.abort();}
    // Session Drop stops renewal and attempts lease revocation. This exercises
    // automatic election after graceful runtime/session loss, not SIGKILL or
    // the full lease-expiration delay of an abruptly lost host.
    *nodes[leader_index].coordinator.session.write().await=None;
    let survivor=&nodes[1-leader_index];
    let elected=loop {
        if let Ok(status)=survivor.coordinator.status("automatic-switch-challenge".into()).await {
            if status.role==NodeRole::Leader && status.ready && status.leader_term.0>term {break status}
        }
        ensure!(failed_at.elapsed()<Duration::from_secs(60),"automatic failover exceeded 60 seconds");
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    let pull=request(&config,&bob,RequestKind::PullMailbox,"recover-mail",json!({"limit":50,"cursor":null}))?;
    let after:PullMailboxResponseV2=serde_json::from_value(post(&http,survivor,&format!("mailbox/{}/pull",bob.public.key_id),&pull).await?)?;
    ensure!(after.items.len()==1 && after.items[0].binding==binding,"automatic switch lost committed mailbox");
    after.items[0].receipt.verify_with_history(&config,&admin.public.signing_public,&binding)?;
    std::fs::write(etcd.root.join("automatic-verified.json"),serde_json::to_vec_pretty(&json!({"old_leader":leader_index,
        "old_term":term,"new_term":elected.leader_term,"rto_ms":failed_at.elapsed().as_millis(),"mode":elected.mode,
        "replicated_body_preserved":true,"session_drop_revokes_lease":true,"fault":"runtime_session_shutdown"}))?)?;
    println!("Automatic runtime evidence: {}",etcd.root.display()); Ok(())
}
