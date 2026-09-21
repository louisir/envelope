use super::{business::{self, IntroRecord, MailRecord, RouteRecord}, control::Control, coordinator::{Coordinator, Submission, Staged, now_ms}};
use crate::storage::v2::{DatabaseIdentity, PreparedOperation, V2Store};
use anyhow::{Context, Result, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, Path, Query, State,Request}, middleware::{self,Next}, http::{HeaderMap, StatusCode}, response::{IntoResponse,Response}, routing::{get,post}};
use envelope_server_core::ha::*;
use serde::Deserialize;
use serde_json::{Value,json};
use std::{net::SocketAddr,path::PathBuf,sync::Arc,time::Duration};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeConfig {
    pub cluster_config:PathBuf,
    pub administrator_public:String,
    pub node_id:String,
    pub signing_secret_file:PathBuf,
    pub database:PathBuf,
    pub public_bind:SocketAddr,
    pub internal_bind:SocketAddr,
    pub peer_url:String,
    pub etcd_endpoints:Vec<String>,
    pub tls_ca:Option<PathBuf>,
    pub tls_cert:Option<PathBuf>,
    pub tls_key:Option<PathBuf>,
    #[serde(default)]
    pub archived_configs:Vec<PathBuf>,
    /// Only for isolated loopback integration tests; never public listeners.
    #[serde(default)]
    pub development_loopback:bool,
}

#[derive(Clone)]
pub struct ApiState { pub coordinator:Arc<Coordinator>, pub development_loopback:bool }

pub async fn run(config:RuntimeConfig)->Result<()> {
    ensure!(config.public_bind.ip().is_loopback() && config.internal_bind.ip().is_loopback(),"both backends must bind loopback behind TLS proxies");
    let cluster:ClusterConfigV2=serde_json::from_slice(&std::fs::read(&config.cluster_config)?)?;
    cluster.verify(&config.administrator_public,now_ms())?;
    let node=cluster.node(&config.node_id)?.clone();
    let peer_url=reqwest::Url::parse(&config.peer_url)?;
    let mut client=reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(3)).timeout(Duration::from_secs(60));
    let mut options=etcd_client::ConnectOptions::default().with_timeout(Duration::from_secs(5));
    if config.development_loopback {
        ensure!(peer_url.scheme()=="http" && peer_url.host_str().is_some_and(|h|h.parse::<std::net::IpAddr>().is_ok_and(|ip|ip.is_loopback())),"development peer must be loopback");
    } else {
        ensure!(peer_url.scheme()=="https","replica peer must use mTLS");
        let ca=std::fs::read(config.tls_ca.as_ref().context("missing TLS CA")?)?;
        let cert=std::fs::read(config.tls_cert.as_ref().context("missing TLS certificate")?)?;
        let key=std::fs::read(config.tls_key.as_ref().context("missing TLS key")?)?;
        let mut identity=cert.clone(); identity.extend(&key);
        client=client.add_root_certificate(reqwest::Certificate::from_pem(&ca)?).identity(reqwest::Identity::from_pem(&identity)?);
        options=options.with_tls(etcd_client::TlsOptions::new().ca_certificate(etcd_client::Certificate::from_pem(ca))
            .identity(etcd_client::Identity::from_pem(cert,key)));
    }
    let control=Control::connect(&config.etcd_endpoints,&cluster,Some(options)).await?;
    control.initialize().await?;
    let existed=config.database.exists();
    let head=control.snapshot(&[]).await?.head_index;
    ensure!(existed || head==0,"empty business disk requires explicit recovery and a new node incarnation");
    let store=V2Store::open(&config.database,DatabaseIdentity {cluster_id:cluster.cluster_id.clone(),control_generation:cluster.control_generation.0,
        node_id:node.node_id.clone(),node_incarnation:node.node_incarnation.clone()}).await?;
    let secret=std::fs::read_to_string(&config.signing_secret_file)?.trim().to_string();
    let archives=config.archived_configs.iter().map(|p|Ok(serde_json::from_slice(&std::fs::read(p)?)?)).collect::<Result<Vec<ClusterConfigV2>>>()?;
    let coordinator=Arc::new(Coordinator::new(cluster,config.node_id,store,control,client.build()?,config.peer_url.trim_end_matches('/').into(),secret)?
        .with_history(&config.administrator_public,archives)?);
    let state=ApiState {coordinator:coordinator.clone(),development_loopback:config.development_loopback};
    let public_listener=tokio::net::TcpListener::bind(config.public_bind).await?;
    let internal_listener=tokio::net::TcpListener::bind(config.internal_bind).await?;
    coordinator.start();
    tracing::info!(node=%coordinator.node_id,public=%config.public_bind,internal=%config.internal_bind,"HA v2 backends started");
    tokio::try_join!(axum::serve(public_listener,public_router(state.clone())),axum::serve(internal_listener,internal_router(state)))?;
    Ok(())
}

pub fn public_router(state:ApiState)->Router {
    let capacity=Arc::new(tokio::sync::Semaphore::new(4));
    Router::new().route("/v2/cluster/config",get(cluster_config)).route("/v2/cluster/status",get(cluster_status))
        .route("/v2/health",get(health)).route("/v2/{*path}",post(command).put(command))
        .fallback(||async{(StatusCode::UPGRADE_REQUIRED,Json(json!({"code":"UPGRADE_REQUIRED","protocol_version":2})))})
        .layer(DefaultBodyLimit::max(16*1024*1024))
        .layer(middleware::from_fn(move |request:Request,next:Next| {
            let capacity=capacity.clone();
            async move {
                let Ok(_permit)=capacity.try_acquire_owned() else {
                    return (StatusCode::TOO_MANY_REQUESTS,Json(json!({"protocol_version":2,"code":"RATE_LIMITED"}))).into_response();
                };
                next.run(request).await
            }
        })).with_state(state)
}
pub fn internal_router(state:ApiState)->Router {
    Router::new().route("/internal/v2/health",get(internal_health)).route("/internal/v2/prepare",post(prepare))
        .route("/internal/v2/payload/{hash}",get(payload)).layer(DefaultBodyLimit::max(12*1024*1024)).with_state(state)
}

async fn cluster_config(State(state):State<ApiState>)->Json<ClusterConfigV2> {Json(state.coordinator.config.clone())}
#[derive(Deserialize)]
struct StatusQuery {nonce:String}
async fn cluster_status(State(state):State<ApiState>,Query(query):Query<StatusQuery>)->ApiResult<Json<ClusterStatus>> {
    if !(16..=128).contains(&query.nonce.len()) { return Err(anyhow::anyhow!("AUTH_FAILED: invalid nonce").into()); }
    Ok(Json(state.coordinator.status(query.nonce).await?))
}
async fn health(State(state):State<ApiState>)->Json<Value> {
    let c=&state.coordinator;
    let durability=c.store.verify_durability().await.is_ok();
    let snapshot=c.control.snapshot(&[]).await;
    let applied=c.store.applied_index().await.ok();
    Json(json!({"protocol_version":2,"live":true,"build_version":option_env!("ENVELOPE_BUILD_VERSION").unwrap_or("v1.0.1.dev"),
        "node_id":c.node_id,"durable_storage":durability,"control_reachable":snapshot.is_ok(),"applied_index":applied.map(|v|v.to_string()),
        "commit_index":snapshot.ok().map(|v|v.head_index.to_string())}))
}

type ApiResult<T>=std::result::Result<T,ApiError>;
pub struct ApiError(anyhow::Error);
impl From<anyhow::Error> for ApiError {fn from(error:anyhow::Error)->Self{Self(error)}}
impl From<serde_json::Error> for ApiError {fn from(error:serde_json::Error)->Self{Self(error.into())}}
impl From<HaError> for ApiError {fn from(error:HaError)->Self{Self(error.into())}}
impl IntoResponse for ApiError {
    fn into_response(self)->Response {
        let message=self.0.to_string();
        let code=if let Some(error)=self.0.downcast_ref::<HaError>() {
            match error {
                HaError::IdConflict|HaError::InvalidTransition=>ErrorCode::IdConflict,
                HaError::Expired=>ErrorCode::Expired,
                HaError::UpgradeRequired=>ErrorCode::UpgradeRequired,
                HaError::Rollback=>ErrorCode::NotReady,
                HaError::InvalidSignature|HaError::InvalidField(..)=>ErrorCode::AuthFailed,
            }
        } else if self.0.downcast_ref::<serde_json::Error>().is_some() {ErrorCode::AuthFailed}
        else if message.contains("OBJECT_VERSION_CONFLICT") {ErrorCode::ObjectVersionConflict}
        else if message.contains("ID_CONFLICT") || message.contains("conflict") {ErrorCode::IdConflict}
        else if message.contains("AUTH_FAILED") || message.contains("signature") || message.contains("identity mismatch") {ErrorCode::AuthFailed}
        else if message.contains("NOT_LEADER") || message.contains("not current leader") {ErrorCode::NotLeader}
        else if message.contains("REPLICA_UNAVAILABLE") {ErrorCode::ReplicaUnavailable}
        else if message.contains("PAYLOAD_UNAVAILABLE") {ErrorCode::PayloadUnavailable}
        else if message.contains("RATE_LIMITED") || message.contains("size limit") {ErrorCode::RateLimited}
        else if message.contains("EXPIRED") {ErrorCode::Expired}
        else if message.contains("NOT_READY") || message.contains("watermark") {ErrorCode::NotReady}
        else {ErrorCode::NoQuorum};
        tracing::warn!(error=%message,code=?code,"HA request rejected");
        let mut body=json!({"code":code,"protocol_version":2});
        if message.contains("actor route is not registered") {body["reason"]=json!("NOT_REGISTERED");}
        (StatusCode::from_u16(code.http_status()).unwrap(),Json(body)).into_response()
    }
}

fn internal_authorized(state:&ApiState,headers:&HeaderMap)->Result<()> {
    if state.development_loopback {return Ok(())}
    let subject=headers.get("x-envelope-peer").and_then(|v|v.to_str().ok()).unwrap_or("");
    ensure!(state.coordinator.config.business_nodes.iter().any(|n|n.node_id!=state.coordinator.node_id && subject==format!("CN=envelope-{}",n.node_id)),
        "AUTH_FAILED: replica client certificate role");
    Ok(())
}
async fn internal_health(State(state):State<ApiState>,headers:HeaderMap)->ApiResult<Json<Value>> {
    internal_authorized(&state,&headers)?;
    state.coordinator.store.verify_durability().await?;
    Ok(Json(json!({"node_id":state.coordinator.node_id,"node_incarnation":state.coordinator.config.node(&state.coordinator.node_id)?.node_incarnation,
        "applied_index":state.coordinator.store.applied_index().await?.to_string()})))
}
async fn prepare(State(state):State<ApiState>,headers:HeaderMap,Json(operation):Json<PreparedOperation>)->ApiResult<Json<PrepareAck>> {
    internal_authorized(&state,&headers)?;
    Ok(Json(state.coordinator.prepare_peer(operation).await?))
}
async fn payload(State(state):State<ApiState>,headers:HeaderMap,Path(hash):Path<String>)->ApiResult<Response> {
    internal_authorized(&state,&headers)?;
    let bytes=state.coordinator.store.prepared_bytes(&hash).await?.context("PAYLOAD_UNAVAILABLE")?;
    Ok(([("content-type","application/json")],bytes).into_response())
}

async fn command(State(state):State<ApiState>,Path(path):Path<String>,Json(request):Json<SignedRequest>)->ApiResult<Response> {
    let value=command_inner(&state.coordinator,&path,request).await?;
    let staged=value["status"]=="staged_single" || value["storage_state"]=="staged_single";
    Ok((if staged {StatusCode::ACCEPTED} else {StatusCode::OK},Json(value)).into_response())
}
async fn command_inner(c:&Coordinator,path:&str,request:SignedRequest)->Result<Value> {
    let body=request.decoded_body(12*1024*1024)?;
    let kind=request.auth.request_kind;
    let actor_id=&request.auth.actor_id;
    let valid_path=match kind {
        RequestKind::StoreEnvelope=>path=="envelopes",
        RequestKind::RegisterRoute=>path=="devices/register",
        RequestKind::PullMailbox=>path==format!("mailbox/{actor_id}/pull"),
        RequestKind::RecordResult=>path==format!("mailbox/{actor_id}/results"),
        RequestKind::DeliveryStatus=>path=="delivery/status" || path==format!("delivery/{actor_id}/status"),
        RequestKind::LookupRoute=>{let b:LookupRouteBody=serde_json::from_slice(&body)?;path=="routes/lookup"||path==format!("routes/{}/{}",b.owner_key_id,b.device_id)},
        RequestKind::IntroPublish=>{let b:IntroPublishBody=serde_json::from_slice(&body)?;path==format!("intro-sessions/{}",b.session_id)},
        RequestKind::IntroRespond=>{let b:IntroRespondBody=serde_json::from_slice(&body)?;path==format!("intro-sessions/{}/response",b.session_id)},
        RequestKind::IntroLookup=>{let b:IntroLookupBody=serde_json::from_slice(&body)?;path==format!("intro-sessions/{}/response",b.session_id)},
    };
    ensure!(valid_path,"AUTH_FAILED: request kind/path mismatch");
    if kind==RequestKind::RecordResult {return c.record_result(&request).await;}
    if matches!(kind,RequestKind::StoreEnvelope|RequestKind::RegisterRoute|RequestKind::RecordResult|RequestKind::IntroPublish|RequestKind::IntroRespond) {
        let submission=c.submit_or_stage(&request).await?;
        let decided=match submission {
            Submission::Replicated(decided)=>decided,
            Submission::Staged(staged,revision)=>{
                if let Some(binding)=&staged.binding {return Ok(serde_json::to_value(c.staged_receipt(&staged,binding,revision)?)?)}
                return Ok(json!({"protocol_version":2,"status":"staged_single","commit_index":null,"guard_revision":revision.to_string()}));
            }
        };
        if kind==RequestKind::StoreEnvelope {
            let body:StoreEnvelopeBody=serde_json::from_slice(&body)?;
            return Ok(serde_json::to_value(c.receipt_for(&body.binding).await?)?);
        }
        let operation=c.store.prepared_operation(&decided.attempt_id).await?.context("PAYLOAD_UNAVAILABLE")?;
        let version=operation.changes.first().map(|c|c.expected_version+1).unwrap_or(0);
        return Ok(json!({"protocol_version":2,"status":"replicated","commit_index":decided.index.to_string(),"object_version":version.to_string()}));
    }
    let (session,_)=c.barrier().await?;
    let contact=c.request_contact(&request.auth,&body).await?;
    request.auth.verify(&contact,&c.config,kind,&body,now_ms(),300_000)?;
    let response=match kind {
        RequestKind::LookupRoute=>{
            let b:LookupRouteBody=serde_json::from_slice(&body)?;
            let object=c.store.object(&business::route_key(&b.owner_key_id,&b.device_id)).await?;
            let mut record=object.as_ref().map(|o|serde_json::from_slice::<RouteRecord>(&o.value)).transpose()?;
            if let Some((staged,_,operation))=c.staged_object(&business::route_key(&b.owner_key_id,&b.device_id)).await? {
                if staged.ack.leader_term.0==session.term {
                    record=operation.changes.first().map(|change|serde_json::from_slice::<RouteRecord>(&change.value)).transpose()?;
                }
            }
            let endpoint=record.map(|r|r.endpoint).filter(|e|e.expires_at_unix_ms>now_ms().into());
            json!({"endpoint":endpoint,"object_version":object.map(|o|o.version).unwrap_or(0).to_string()})
        },
        RequestKind::IntroLookup=>{
            let b:IntroLookupBody=serde_json::from_slice(&body)?;
            let object=c.store.object(&business::intro_key(&b.session_id)).await?.context("EXPIRED: intro missing")?;
            let record:IntroRecord=serde_json::from_slice(&object.value)?;
            ensure!(record.owner_bundle.expires_at_unix_ms>now_ms().into(),"EXPIRED: intro");
            ensure!(record.owner_bundle.contact.key_id==*actor_id,"AUTH_FAILED: intro owner");
            json!({"session_id":record.session_id,"owner_key_id":record.owner_bundle.contact.key_id,"responder_bundle":record.responder_bundle,"object_version":object.version.to_string()})
        },
        RequestKind::DeliveryStatus=>{
            let b:DeliveryStatusBody=serde_json::from_slice(&body)?;
            ensure!(b.bindings.len()<=100,"RATE_LIMITED: status count");
            let mut items=Vec::new();
            for binding in b.bindings {
                ensure!(binding.sender_key_id==*actor_id,"AUTH_FAILED: delivery sender");
                let object=c.store.object(&business::mail_key(&binding)?).await?;
                let (receipt,mut result)=if let Some(object)=object {
                    let record:MailRecord=serde_json::from_slice(&object.value)?;
                    record.binding.check_retry(&binding)?;
                    (Some(c.receipt_for(&binding).await?),record.result)
                } else if let Some((staged,revision,_))=c.staged_object(&business::mail_key(&binding)?).await? {
                    if let Some(expected)=&staged.binding {expected.check_retry(&binding)?;}
                    (Some(c.staged_receipt(&staged,&binding,revision)?),None)
                } else {(None,None)};
                if let Some(proof)=c.result_for(&binding).await? {
                    if result.as_ref().is_none_or(|old|old.result_sequence<proof.result_sequence) {result=Some(proof);}
                }
                items.push(DeliveryStatusItemV2 {binding,receipt,result});
            }
            serde_json::to_value(DeliveryStatusResponseV2 {protocol_version:2,items})?
        },
        RequestKind::PullMailbox=>{
            let b:PullMailboxBody=serde_json::from_slice(&body)?;
            ensure!(b.limit>0 && b.limit<=50,"RATE_LIMITED: mailbox limit");
            let mut cursor=b.cursor.unwrap_or_default();
            ensure!(cursor.len()<=256,"AUTH_FAILED: cursor length");
            let stage_cursor=cursor.strip_prefix("stage:").map(str::to_owned);
            let mut items=Vec::new();let mut budget=0;let mut next=None;
            'pages: for _ in 0..if stage_cursor.is_some(){0}else{100} {
                let objects=c.store.objects_by_kind("mailbox",&cursor,100).await?;
                if objects.is_empty(){next=None;break}
                for object in objects {
                    if object.terminal {cursor=object.key;continue}
                    let record:MailRecord=serde_json::from_slice(&object.value)?;
                    if record.binding.recipient_key_id!=*actor_id || record.binding.not_after.0<=now_ms() {cursor=object.key;continue}
                    if c.result_for(&record.binding).await?.is_some_and(|r|DeliveryState::from(r.outcome).is_terminal()) {cursor=object.key;continue}
                    let prepared=c.store.prepared_operation(&record.attempt_id).await?.context("PAYLOAD_UNAVAILABLE")?;
                    let submitted:StoreEnvelopeBody=serde_json::from_slice(&prepared.request_body)?;
                    if !items.is_empty() && (items.len()>=b.limit as usize || budget+submitted.envelope_b64.len()>12*1024*1024) {
                        next=Some(cursor.clone());break 'pages
                    }
                    let receipt=c.receipt_for(&record.binding).await?;
                    budget+=submitted.envelope_b64.len();
                    items.push(MailboxItemV2 {binding:record.binding,envelope_b64:submitted.envelope_b64,receipt});
                    cursor=object.key;
                }
                next=Some(cursor.clone());
            }
            if next.is_none() {
                let mut after=stage_cursor.filter(|s|!s.is_empty());
                'stages: for _ in 0..100 {
                    let page=c.control.scan_prefix("staged/mail",after.as_deref(),100).await?;
                    for (key,entry) in page.entries {
                        let staged:Staged=serde_json::from_slice(&entry.value)?;
                        let Some(binding)=staged.binding else {after=Some(key);continue};
                        if binding.recipient_key_id!=*actor_id || binding.not_after.0<=now_ms() {after=Some(key);continue}
                        if c.result_for(&binding).await?.is_some_and(|r|DeliveryState::from(r.outcome).is_terminal()) {after=Some(key);continue}
                        if c.store.object(&staged.object_key).await?.is_some() {after=Some(key);continue}
                        let Some((staged,revision,operation))=c.staged_object(&staged.object_key).await? else {after=Some(key);continue};
                        let submitted:StoreEnvelopeBody=serde_json::from_slice(&operation.request_body)?;
                        if !items.is_empty() && (items.len()>=b.limit as usize || budget+submitted.envelope_b64.len()>12*1024*1024) {
                            next=Some(format!("stage:{}",after.unwrap_or_default()));break 'stages
                        }
                        budget+=submitted.envelope_b64.len();
                        let receipt=c.staged_receipt(&staged,&binding,revision)?;
                        items.push(MailboxItemV2 {binding,envelope_b64:submitted.envelope_b64,receipt});
                        after=Some(key);
                    }
                    if !page.more {next=None;break}
                    next=Some(format!("stage:{}",after.clone().unwrap_or_default()));
                }
            }
            serde_json::to_value(PullMailboxResponseV2 {protocol_version:2,items,next_cursor:next})?
        },
        _=>unreachable!(),
    };
    c.finish_read(&session).await?;
    Ok(response)
}
