//! Opt-in deployment acceptance probe. Uses fresh synthetic identities only.
use anyhow::{Context,Result,ensure};
use clap::Parser;
use envelope_core::{Identity,encode_bytes,encrypt_opaque_text,decrypt_opaque_text,create_device_endpoint_update};
use envelope_server::ha::coordinator::{now_ms,random_token};
use envelope_server_core::ha::*;
use serde::{Deserialize,Serialize};
use serde_json::{Value,json};
use std::{path::PathBuf,time::Duration};
#[derive(Parser)]
struct Args {
    #[arg(long)] bootstrap:PathBuf,
    #[arg(long)] state:PathBuf,
    #[arg(long,value_parser=["seed","stage","verify","deliver","deny"])] mode:String,
}
async fn denied_without_quorum(http:&reqwest::Client,bootstrap:&Bootstrap,saved:&ProbeState)->Result<()> {
    let mut checks=Vec::new();
    for origin in &bootstrap.bootstrap_urls {
        let origin=origin.trim_end_matches('/');
        let config=http.get(format!("{origin}/v2/cluster/config")).send().await?.error_for_status()?.json::<ClusterConfigV2>().await?;
        config.verify(&bootstrap.admin_public,now_ms())?;
        ensure!(config.cluster_id==bootstrap.cluster_id,"bootstrap cluster mismatch");
        let encrypted=encrypt_opaque_text(&saved.alice,&saved.bob.public,"Must be rejected while control quorum is unavailable",2)?;
        let binding=EnvelopeBinding {operation_id:random_token(),sender_key_id:saved.alice.public.key_id.clone(),recipient_key_id:saved.bob.public.key_id.clone(),
            envelope_id:encrypted.envelope_id,envelope_sha256:sha256_b64(&encrypted.envelope_bytes),not_after:(now_ms()+86_400_000).into()};
        let requests=[
            (format!("mailbox/{}/pull",saved.bob.public.key_id),signed(&config,&saved.bob,RequestKind::PullMailbox,&random_token(),json!({"limit":50,"cursor":null}))?),
            (format!("delivery/{}/status",saved.alice.public.key_id),signed(&config,&saved.alice,RequestKind::DeliveryStatus,&random_token(),json!({"bindings":[saved.binding]}))?),
            ("envelopes".into(),signed(&config,&saved.alice,RequestKind::StoreEnvelope,&binding.operation_id,json!({"binding":binding,"sender_contact":saved.alice.public,"envelope_b64":encode_bytes(&encrypted.envelope_bytes),"created_at":now_ms().to_string()}))?),
        ];
        for (path,request) in requests {
            let response=http.post(format!("{origin}/v2/{path}")).json(&request).send().await?;
            let status=response.status();let body:Value=response.json().await?;
            ensure!((status.as_u16()==503 && body["code"]=="NO_QUORUM") || (status.as_u16()==409 && body["code"]=="NOT_LEADER"),
                "expected authority denial from {origin}/{path}, got {status}: {body}");
            checks.push(json!({"origin":origin,"path":path,"http_status":status.as_u16(),"code":body["code"]}));
        }
    }
    println!("{}",serde_json::to_string_pretty(&json!({"mode":"deny","verified":true,"checks":checks}))?);
    Ok(())
}
#[derive(Deserialize)]
struct Bootstrap {admin_public:String,cluster_id:String,bootstrap_urls:Vec<String>}
#[derive(Serialize,Deserialize)]
struct ProbeState {alice:Identity,bob:Identity,binding:EnvelopeBinding,ciphertext:Vec<u8>,original_receipt:CommitReceipt,watermark:TrustWatermark}
fn signed(config:&ClusterConfigV2,actor:&Identity,kind:RequestKind,operation:&str,body:Value)->Result<SignedRequest> {
    let bytes=serde_json::to_vec(&body)?;
    let mut auth=RequestAuth {protocol_version:2,cluster_id:config.cluster_id.clone(),control_generation:config.control_generation,config_epoch:config.config_epoch,
        actor_id:actor.public.key_id.clone(),operation_id:operation.into(),nonce:random_token(),requested_at:now_ms().into(),request_kind:kind,body_sha256:sha256_b64(&bytes),signature:String::new()};
    auth.sign(&actor.signing_secret)?;
    Ok(SignedRequest {auth,body_b64:encode_bytes(&bytes)})
}
async fn post(http:&reqwest::Client,url:&str,path:&str,request:&SignedRequest)->Result<Value> {
    let response=http.post(format!("{url}/v2/{path}")).json(request).send().await?;
    let status=response.status();let text=response.text().await?;
    ensure!(status.is_success(),"{path}: {status} {text}");
    Ok(serde_json::from_str(&text)?)
}
async fn leader(http:&reqwest::Client,bootstrap:&Bootstrap,watermark:&mut TrustWatermark)->Result<(String,ClusterConfigV2,ClusterStatus)> {
    for url in &bootstrap.bootstrap_urls {
        // An unavailable bootstrap is not a trust failure: try the remaining
        // configured origins. Successful responses still fail closed on JSON,
        // administrator signature, cluster binding, and watermark validation.
        let config=match http.get(format!("{}/v2/cluster/config",url.trim_end_matches('/'))).send().await {
            Ok(r) if r.status().is_success()=>r.json::<ClusterConfigV2>().await?,
            _=>continue,
        };
        config.verify(&bootstrap.admin_public,now_ms())?;
        ensure!(config.cluster_id==bootstrap.cluster_id,"bootstrap cluster mismatch");
        watermark.accept_config(&config,&bootstrap.admin_public,now_ms())?;
        for node in &config.business_nodes {
            let nonce=random_token();
            let url=node.public_url.trim_end_matches('/');
            let status=match http.get(format!("{url}/v2/cluster/status")).query(&[("nonce",&nonce)]).send().await {
                Ok(r) if r.status().is_success()=>r.json::<ClusterStatus>().await?,_=>continue};
            status.verify(&config,&nonce,now_ms(),1000)?;
            if status.ready && status.role==NodeRole::Leader {watermark.accept_status(&status,&config,&nonce,now_ms(),1000)?;return Ok((url.into(),config,status));}
        }
    }
    anyhow::bail!("no verified ready leader")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc,atomic::{AtomicUsize,Ordering}};

    struct Origin {url:String,hits:Arc<AtomicUsize>,task:tokio::task::JoinHandle<()>}
    impl Drop for Origin {fn drop(&mut self){self.task.abort();}}
    async fn origin(status:axum::http::StatusCode,body:String)->Origin {
        let listener=tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url=format!("http://{}",listener.local_addr().unwrap());
        let hits=Arc::new(AtomicUsize::new(0));let count=hits.clone();
        let app=axum::Router::new().route("/v2/cluster/config",axum::routing::get(move || {
            count.fetch_add(1,Ordering::SeqCst);let body=body.clone();async move {(status,body)}
        }));
        let task=tokio::spawn(async move {axum::serve(listener,app).await.unwrap();});
        Origin {url,hits,task}
    }
    fn config()->ClusterConfigV2 {
        let fixture:Value=serde_json::from_slice(&std::fs::read(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/ha-v2/vectors.json")).unwrap()).unwrap();
        let mut config:ClusterConfigV2=serde_json::from_value(fixture["valid"][0]["document"].clone()).unwrap();
        config.issued_at=(now_ms()-1000).into();config.not_after=(now_ms()+60_000).into();
        config.sign(&encode_bytes(&[1;32])).unwrap();config
    }
    fn watermark()->TrustWatermark {
        TrustWatermark {cluster_id:"test-cluster".into(),control_generation:0.into(),config_epoch:0.into(),leader_term:0.into()}
    }
    fn bootstrap(urls:Vec<String>)->Bootstrap {
        Bootstrap {admin_public:envelope_core::signing_public_from_secret(&encode_bytes(&[1;32])).unwrap(),cluster_id:"test-cluster".into(),bootstrap_urls:urls}
    }
    #[tokio::test]
    async fn unavailable_bootstrap_tries_next_but_valid_signature_wrong_cluster_still_fails() {
        let http=reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(2)).build().unwrap();
        for code in [axum::http::StatusCode::BAD_GATEWAY,axum::http::StatusCode::SERVICE_UNAVAILABLE] {
            let first=origin(code,"temporarily unavailable".into()).await;
            let mut other=config();other.cluster_id="different-cluster".into();other.sign(&encode_bytes(&[1;32])).unwrap();
            let second=origin(axum::http::StatusCode::OK,serde_json::to_string(&other).unwrap()).await;
            let third=origin(axum::http::StatusCode::OK,serde_json::to_string(&config()).unwrap()).await;
            let bootstrap=bootstrap(vec![format!("{}/",first.url),second.url.clone(),third.url.clone()]);
            let mut watermark=watermark();
            let error=leader(&http,&bootstrap,&mut watermark).await.err().expect("cluster mismatch must fail closed");
            assert!(error.to_string().contains("bootstrap cluster mismatch"));
            assert_eq!(first.hits.load(Ordering::SeqCst),1);
            assert_eq!(second.hits.load(Ordering::SeqCst),1,"HTTP error must not stop discovery");
            assert_eq!(third.hits.load(Ordering::SeqCst),0,"trust failure must not be masked by another origin");
            assert_eq!(watermark.config_epoch,0.into());
        }
    }
    #[tokio::test]
    async fn invalid_administrator_signature_does_not_fall_through() {
        let mut invalid=config();invalid.sign(&encode_bytes(&[2;32])).unwrap();
        let first=origin(axum::http::StatusCode::OK,serde_json::to_string(&invalid).unwrap()).await;
        let second=origin(axum::http::StatusCode::OK,serde_json::to_string(&config()).unwrap()).await;
        let http=reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(2)).build().unwrap();
        let mut watermark=watermark();
        let error=leader(&http,&bootstrap(vec![first.url.clone(),second.url.clone()]),&mut watermark).await.err().expect("invalid signature must fail closed");
        assert_eq!(error.downcast_ref::<HaError>(),Some(&HaError::InvalidSignature));
        assert_eq!(second.hits.load(Ordering::SeqCst),0);
        assert_eq!(watermark.config_epoch,0.into());
    }
}
#[tokio::main]
async fn main()->Result<()> {
    let args=Args::parse();let bootstrap:Bootstrap=serde_json::from_slice(&std::fs::read(&args.bootstrap)?)?;
    let http=reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none()).connect_timeout(Duration::from_secs(3)).timeout(Duration::from_secs(20)).build()?;
    let mut saved=if args.mode=="seed" {ensure!(!args.state.exists(),"refusing to replace probe identity state");None}
        else {Some(serde_json::from_slice::<ProbeState>(&std::fs::read(&args.state)?)?)};
    if args.mode=="deny" {return denied_without_quorum(&http,&bootstrap,saved.as_ref().context("probe state")?).await;}
    let mut watermark=saved.as_ref().map(|s|s.watermark.clone()).unwrap_or(TrustWatermark {cluster_id:bootstrap.cluster_id.clone(),control_generation:0.into(),config_epoch:0.into(),leader_term:0.into()});
    let (url,config,status)=leader(&http,&bootstrap,&mut watermark).await?;
    if saved.is_none() {
        let alice=Identity::generate("HA acceptance sender");let bob=Identity::generate("HA acceptance receiver");
        for actor in [&alice,&bob] {
            let endpoint=create_device_endpoint_update(actor,"acceptance-probe","probe-ticket","probe-session",1,1800)?;
            let request=signed(&config,actor,RequestKind::RegisterRoute,"register",json!({"owner_contact":actor.public,"endpoint":endpoint,"expected_version":"0"}))?;
            let result=post(&http,&url,"devices/register",&request).await?;
            ensure!(result["status"]=="replicated","initial route must be dual replicated");
        }
        let encrypted=encrypt_opaque_text(&alice,&bob.public,"Envelope HA deployment acceptance: exact ciphertext survives primary loss.",1)?;
        let binding=EnvelopeBinding {operation_id:random_token(),sender_key_id:alice.public.key_id.clone(),recipient_key_id:bob.public.key_id.clone(),
            envelope_id:encrypted.envelope_id,envelope_sha256:sha256_b64(&encrypted.envelope_bytes),not_after:(now_ms()+86_400_000).into()};
        let request=signed(&config,&alice,RequestKind::StoreEnvelope,&binding.operation_id,
            json!({"binding":binding,"sender_contact":alice.public,"envelope_b64":encode_bytes(&encrypted.envelope_bytes),"created_at":now_ms().to_string()}))?;
        let receipt:CommitReceipt=serde_json::from_value(post(&http,&url,"envelopes",&request).await?)?;
        receipt.verify_with_history(&config,&bootstrap.admin_public,&binding)?;
        ensure!(receipt.storage_state==StorageState::Replicated,"probe seed was not dual replicated");
        saved=Some(ProbeState {alice,bob,binding,ciphertext:encrypted.envelope_bytes,original_receipt:receipt,watermark:watermark.clone()});
    }
    let mut saved=saved.context("probe state")?;
    if args.mode=="stage" {
        ensure!(status.mode==ServiceMode::Degraded,"stage probe requires one business replica unavailable");
        let encrypted=encrypt_opaque_text(&saved.alice,&saved.bob.public,"Envelope HA deployment acceptance: exact ciphertext survives primary loss.",3)?;
        let binding=EnvelopeBinding {operation_id:random_token(),sender_key_id:saved.alice.public.key_id.clone(),recipient_key_id:saved.bob.public.key_id.clone(),
            envelope_id:encrypted.envelope_id,envelope_sha256:sha256_b64(&encrypted.envelope_bytes),not_after:(now_ms()+86_400_000).into()};
        let request=signed(&config,&saved.alice,RequestKind::StoreEnvelope,&binding.operation_id,
            json!({"binding":binding,"sender_contact":saved.alice.public,"envelope_b64":encode_bytes(&encrypted.envelope_bytes),"created_at":now_ms().to_string()}))?;
        let receipt:CommitReceipt=serde_json::from_value(post(&http,&url,"envelopes",&request).await?)?;
        receipt.verify_with_history(&config,&bootstrap.admin_public,&binding)?;
        ensure!(receipt.storage_state==StorageState::StagedSingle,"unavailable peer must not produce replicated acknowledgement");
        saved.binding=binding;saved.ciphertext=encrypted.envelope_bytes;saved.original_receipt=receipt;
    }
    let mut decrypted=false;let mut delivered=false;
    let mut current_receipt=saved.original_receipt.clone();
    if matches!(args.mode.as_str(),"verify"|"deliver") {
        let request=signed(&config,&saved.bob,RequestKind::PullMailbox,&random_token(),json!({"limit":50,"cursor":null}))?;
        let pulled:PullMailboxResponseV2=serde_json::from_value(post(&http,&url,&format!("mailbox/{}/pull",saved.bob.public.key_id),&request).await?)?;
        let item=pulled.items.iter().find(|i|i.binding==saved.binding).context("committed envelope missing after failover")?;
        item.receipt.verify_with_history(&config,&bootstrap.admin_public,&saved.binding)?;
        current_receipt=item.receipt.clone();
        ensure!(item.envelope_b64==encode_bytes(&saved.ciphertext),"ciphertext changed");
        let plain=decrypt_opaque_text(&saved.bob,&saved.alice.public,&saved.ciphertext)?;
        ensure!(plain=="Envelope HA deployment acceptance: exact ciphertext survives primary loss.","decrypted text differs");decrypted=true;
        if args.mode=="deliver" {
            let mut result=RecipientResult {version:2,sender_key_id:saved.alice.public.key_id.clone(),recipient_key_id:saved.bob.public.key_id.clone(),
                envelope_id:saved.binding.envelope_id.clone(),envelope_sha256:saved.binding.envelope_sha256.clone(),outcome:RecipientOutcome::Delivered,
                reason_code:String::new(),received_at:now_ms().into(),result_id:random_token(),result_sequence:1.into(),signature:String::new()};
            result.sign(&saved.bob.signing_secret)?;
            let request=signed(&config,&saved.bob,RequestKind::RecordResult,&result.result_id,json!({"result":result,"recipient_contact":saved.bob.public}))?;
            post(&http,&url,&format!("mailbox/{}/results",saved.bob.public.key_id),&request).await?;
            let request=signed(&config,&saved.alice,RequestKind::DeliveryStatus,&random_token(),json!({"bindings":[saved.binding]}))?;
            let response:DeliveryStatusResponseV2=serde_json::from_value(post(&http,&url,&format!("delivery/{}/status",saved.alice.public.key_id),&request).await?)?;
            response.items[0].result.as_ref().context("recipient proof missing")?.verify(&saved.bob.public,&saved.binding)?;delivered=true;
        }
    }
    saved.watermark=watermark;
    if let Some(parent)=args.state.parent() {std::fs::create_dir_all(parent)?;}
    std::fs::write(&args.state,serde_json::to_vec_pretty(&saved)?)?;
    println!("{}",serde_json::to_string_pretty(&json!({"mode":args.mode,"leader":status.node_id,"leader_term":status.leader_term,"service_mode":status.mode,
        "commit_index":saved.original_receipt.commit_index,"current_commit_index":current_receipt.commit_index,"current_storage_state":current_receipt.storage_state,
        "envelope_id":saved.binding.envelope_id,"decrypted":decrypted,"signed_delivery_verified":delivered}))?);
    Ok(())
}
