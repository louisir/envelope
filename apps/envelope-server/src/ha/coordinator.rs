use super::{business, control::{Change, Control, ControlSnapshot, Guard, LeaderSession, LeaderValue, ReadyValue}};
use crate::storage::v2::{CommitDecision, PreparedOperation, V2Store, digest};
use anyhow::{Context, Result, ensure};
use envelope_server_core::ha::*;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, sync::Arc, time::{Duration, SystemTime, UNIX_EPOCH}};
use tokio::sync::{Mutex, RwLock, Semaphore};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Decided {
    pub index: u64,
    pub attempt_id: String,
    pub payload_hash: String,
    pub logical_hash: String,
    pub actor_id: String,
    pub operation_id: String,
    pub acks: Vec<PrepareAck>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct OperationGuard { logical_hash:String, attempt_id:String, decided:Option<Decided>, #[serde(default)] staged:Option<Staged> }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Staged {
    pub object_key:String,
    pub actor_id:String,
    pub operation_id:String,
    pub logical_hash:String,
    pub payload_hash:String,
    pub attempt_id:String,
    pub node_id:String,
    pub binding:Option<EnvelopeBinding>,
    pub ack:PrepareAck,
    pub byte_len:u64,
}
pub enum Submission { Replicated(Decided), Staged(Staged,i64) }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResultInbox { result:RecipientResult, contact:envelope_core::Contact, auth:RequestAuth, body_json:String }
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ObjectGuard { version:u64, kind:String, terminal:bool }
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Usage { count:u64, bytes:u64 }

pub struct Coordinator {
    pub config: ClusterConfigV2,
    pub node_id: String,
    pub store: V2Store,
    pub control: Control,
    pub peer: reqwest::Client,
    pub peer_url: String,
    signing_secret: String,
    config_history: BTreeMap<(u64,u64),ClusterConfigV2>,
    administrator_public: Option<String>,
    pub session: RwLock<Option<Arc<LeaderSession>>>,
    commit: Mutex<()>,
    apply: Mutex<()>,
    preparations: Semaphore,
    prepare_bytes: Semaphore,
    reconcile_cursors: Mutex<(Option<String>,Option<String>)>,
    expiry_cursor: Mutex<String>,
}
impl Coordinator {
    pub fn new(config:ClusterConfigV2,node_id:String,store:V2Store,control:Control,peer:reqwest::Client,peer_url:String,signing_secret:String) -> Result<Self> {
        let node=config.node(&node_id)?;
        ensure!(envelope_core::signing_public_from_secret(&signing_secret)?==node.signing_public,"node private key mismatch");
        let config_history=BTreeMap::from([((config.control_generation.0,config.config_epoch.0),config.clone())]);
        Ok(Self {config,node_id,store,control,peer,peer_url,signing_secret,config_history,administrator_public:None,session:RwLock::new(None),commit:Mutex::new(()),apply:Mutex::new(()),
            preparations:Semaphore::new(4),prepare_bytes:Semaphore::new(32*1024*1024),reconcile_cursors:Mutex::new((None,None)),expiry_cursor:Mutex::new(String::new())})
    }
    /// Call before wrapping in Arc. Archives authenticate old decisions only;
    /// they do not alter the active control configuration or authorize writes.
    pub fn with_history(mut self,administrator_public:&str,archives:Vec<ClusterConfigV2>) -> Result<Self> {
        self.config.verify_archived(administrator_public)?;
        for archive in archives {
            archive.verify_archived(administrator_public)?;
            ensure!(archive.cluster_id==self.config.cluster_id && archive.control_generation<=self.config.control_generation
                && archive.config_epoch<=self.config.config_epoch,"history scope outside current authenticated cluster");
            let scope=(archive.control_generation.0,archive.config_epoch.0);
            if let Some(existing)=self.config_history.get(&scope) {
                ensure!(existing==&archive,"conflicting administrator configurations for one scope");
            } else { self.config_history.insert(scope,archive); }
        }
        self.administrator_public=Some(administrator_public.to_owned()); Ok(self)
    }
    pub fn sign<T:HaSigned>(&self,value:&mut T)->Result<()> { value.sign(&self.signing_secret)?; Ok(()) }

    pub fn start(self:&Arc<Self>)->tokio::task::JoinHandle<()> {
        let this=self.clone();
        tokio::spawn(async move {
            let mut interval=tokio::time::interval(Duration::from_millis(500));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                if let Err(error)=this.tick().await {
                    tracing::warn!(error=%error,"HA recovery/leadership not ready");
                    // A healthy keepalive cannot retain authority for an
                    // unusable business disk. Revoke even if requests hold Arcs.
                    let session=this.session.write().await.take();
                    if let Some(session)=session { let _=this.control.release(&session).await; }
                }
            }
        })
    }

    async fn tick(&self)->Result<()> {
        let snapshot=self.control.snapshot(&[]).await?;
        self.catch_up(snapshot.head_index).await?;
        {
            let mut slot=self.session.write().await;
            if let Some(current)=slot.as_ref() {
                if snapshot.leader.as_ref().is_none_or(|l| l.create_revision as u64 != current.term || l.lease_id != current.lease_id) {
                    *slot=None;
                }
            }
            if slot.is_none() && snapshot.leader.is_none() {
                let node=self.config.node(&self.node_id)?;
                let token=random_token();
                *slot=self.control.try_acquire(&self.node_id,&node.node_incarnation,&token).await?.map(Arc::new);
            }
        }
        if let Some(session)=self.session.read().await.clone() {
            let snapshot=self.control.check_authority(&session,false).await?;
            self.catch_up(snapshot.head_index).await?;
            let mode=match self.peer.get(format!("{}/internal/v2/health",self.peer_url)).timeout(Duration::from_secs(3)).send().await {
                Ok(response) if response.status().is_success()=>{
                    let health=response.json::<serde_json::Value>().await.unwrap_or_default();
                    let peer=self.config.business_nodes.iter().find(|n|n.node_id!=self.node_id).context("peer missing")?;
                    if health["node_id"].as_str()==Some(&peer.node_id) && health["node_incarnation"].as_str()==Some(&peer.node_incarnation) {
                        ServiceMode::Normal
                    } else {ServiceMode::Degraded}
                },
                _=>ServiceMode::Degraded,
            };
            // A ready key is fenced against the exact head it has recovered.
            let applied=self.store.applied_index().await?;
            let ready=serde_json::to_vec(&ReadyValue {leader_token:session.value.session_token.clone(),applied_index:applied.into(),mode})?;
            // Rewriting an identical ready value changes mod_revision and
            // needlessly fences in-flight WAN transactions every half second.
            if snapshot.ready.as_ref().is_none_or(|old|old.lease_id!=session.lease_id || old.value!=ready) {
                self.control.publish_ready(&session,applied,mode).await?;
            }
            if mode==ServiceMode::Normal {
                // One unavailable staged payload must not continuously revoke
                // the healthy leader or starve subsequent reconciliation work.
                if let Err(error)=self.reconcile_degraded().await {tracing::warn!(%error,"degraded reconciliation deferred");}
                let mut cursor=self.expiry_cursor.lock().await;
                match self.expire_due(&cursor,32).await {
                    Ok(next)=>*cursor=next.unwrap_or_default(),
                    Err(error)=>tracing::warn!(%error,"ordered expiry deferred"),
                }
            }
        }
        Ok(())
    }

    pub async fn catch_up(&self,target:u64)->Result<()> {
        let _application=self.apply.lock().await;
        let mut applied=self.store.applied_index().await?;
        while applied<target {
            let key=decision_key(applied+1);
            let snapshot=self.control.snapshot(&[&key]).await?;
            let entry=snapshot.entries.get(&key).context("committed decision unavailable")?;
            let decided:Decided=serde_json::from_slice(&entry.value)?;
            ensure!(decided.index==applied+1,"decision sequence mismatch");
            self.validate_decision(&decided)?;
            if self.store.prepared_bytes(&decided.payload_hash).await?.is_none() {
                let response=self.peer.get(format!("{}/internal/v2/payload/{}",self.peer_url,decided.payload_hash)).send().await?;
                ensure!(response.status().is_success(),"committed payload unavailable on surviving replicas");
                ensure!(response.content_length().unwrap_or(0)<=12*1024*1024,"oversized peer payload");
                let bytes=response.bytes().await?;
                ensure!(bytes.len()<=12*1024*1024 && digest(&bytes)==decided.payload_hash,"peer payload hash mismatch");
                let operation:PreparedOperation=serde_json::from_slice(&bytes)?;
                ensure!(operation.attempt_id==decided.attempt_id && operation.logical_hash==decided.logical_hash,"decision payload mismatch");
                self.store.prepare(&operation).await?;
            }
            self.store.apply(&CommitDecision {cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation.0,
                commit_index:decided.index,attempt_id:decided.attempt_id.clone(),payload_hash:decided.payload_hash.clone(),evidence:entry.value.clone()}).await?;
            applied+=1;
        }
        Ok(())
    }

    fn validate_decision(&self,decided:&Decided)->Result<()> {
        ensure!(decided.index>0 && decided.acks.len()==2,"decision lacks two replica proofs");
        ensure!(decided.acks[0].node_id<decided.acks[1].node_id,"decision duplicate/unordered replicas");
        let proof_config=self.decision_config(decided)?;
        for ack in &decided.acks {
            ack.verify(proof_config)?;
            ensure!(ack.attempt_id==decided.attempt_id && ack.payload_hash==decided.payload_hash && ack.logical_hash==decided.logical_hash
                && ack.actor_id==decided.actor_id && ack.operation_id==decided.operation_id
                && ack.leader_term==decided.acks[0].leader_term,"decision proof mismatch");
        }
        Ok(())
    }
    fn decision_config(&self,decided:&Decided)->Result<&ClusterConfigV2> {
        let first=decided.acks.first().context("decision has no replica evidence")?;
        self.config_history.get(&(first.control_generation.0,first.config_epoch.0))
            .context("authenticated historical configuration required for committed evidence")
    }

    pub async fn barrier(&self)->Result<(Arc<LeaderSession>,ControlSnapshot)> {
        let session=self.session.read().await.clone().context("NOT_LEADER")?;
        let snapshot=self.control.check_authority(&session,true).await?;
        self.catch_up(snapshot.head_index).await?;
        Ok((session,snapshot))
    }
    pub async fn finish_read(&self,session:&LeaderSession)->Result<()> { self.control.check_authority(session,true).await?; Ok(()) }

    pub async fn status(&self,nonce:String)->Result<ClusterStatus> {
        let issued=now_ms();
        let applied=self.store.applied_index().await?;
        let snapshot=self.control.snapshot(&[]).await?;
        let leader=snapshot.leader.as_ref().map(|e|serde_json::from_slice::<LeaderValue>(&e.value)).transpose()?;
        let ready=snapshot.ready.as_ref().map(|e|serde_json::from_slice::<ReadyValue>(&e.value)).transpose()?;
        let self_is_leader=leader.as_ref().is_some_and(|l|l.node_id==self.node_id);
        let valid_ready=ready.as_ref().zip(leader.as_ref()).is_some_and(|(r,l)|r.leader_token==l.session_token)
            && snapshot.ready.as_ref().zip(snapshot.leader.as_ref()).is_some_and(|(r,l)|r.lease_id==l.lease_id);
        let node_ready=self_is_leader && valid_ready && applied==snapshot.head_index;
        let mut status=ClusterStatus {protocol_version:2,cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation,
            config_epoch:self.config.config_epoch,node_id:self.node_id.clone(),node_incarnation:self.config.node(&self.node_id)?.node_incarnation.clone(),nonce,
            role:if self_is_leader {NodeRole::Leader} else if applied<snapshot.head_index {NodeRole::Recovering} else {NodeRole::Follower},
            mode:if node_ready {ready.as_ref().unwrap().mode} else {ServiceMode::Unavailable},leader_node_id:leader.map(|l|l.node_id),
            leader_term:DecimalU64(snapshot.leader.as_ref().map(|l|l.create_revision as u64).unwrap_or(0)),applied_index:DecimalU64(applied),
            commit_index:DecimalU64(snapshot.head_index),ready:node_ready,
            reason_code:if valid_ready {"OK"} else {"NOT_READY"}.into(),issued_at:DecimalU64(issued),expires_at:DecimalU64(issued+5000),
            capabilities:vec!["intro".into(),"mailbox".into(),"route".into()],node_signature:String::new()};
        ensure!(now_ms()<status.expires_at.0,"status read exceeded freshness window");
        // Do not restamp an old control read after a long scheduler pause.
        self.sign(&mut status)?;
        Ok(status)
    }

    pub async fn submit_or_stage(&self,request:&SignedRequest)->Result<Submission> {
        let (session,snapshot)=self.barrier().await?;
        let body=request.decoded_body(12*1024*1024)?;
        let actor=self.request_contact(&request.auth,&body).await?;
        request.auth.verify(&actor,&self.config,request.auth.request_kind,&body,now_ms(),300_000)?;
        let logical_hash=logical_request_hash(&request.auth,&body)?;
        let key=operation_key(&request.auth.actor_id,&request.auth.operation_id);
        let previous=self.control.snapshot(&[&key]).await?;
        if let Some(entry)=previous.entries.get(&key) {
            let guard:OperationGuard=serde_json::from_slice(&entry.value)?;
            if let Some(decided)=guard.decided {
                ensure!(logical_hash==guard.logical_hash,"ID_CONFLICT");
                self.catch_up(decided.index).await?;
                return Ok(Submission::Replicated(decided));
            }
        }
        let ready:ReadyValue=serde_json::from_slice(&snapshot.ready.context("NOT_READY")?.value)?;
        let can_stage=matches!(request.auth.request_kind,RequestKind::StoreEnvelope|RequestKind::RegisterRoute);
        // Client retries reuse durable staging even if the peer is now healthy.
        // The single-flight background reconciler owns replication upgrades.
        if can_stage {
            if let Some((staged,revision))=self.reusable_staged(request,&body,&logical_hash,&session).await? {
                return Ok(Submission::Staged(staged,revision));
            }
        }
        if can_stage && ready.mode==ServiceMode::Degraded {
            return self.stage(request).await.map(|(s,r)|Submission::Staged(s,r));
        }
        match self.submit(request).await {
            Ok(decided)=>Ok(Submission::Replicated(decided)),
            Err(error) if can_stage && error.to_string().contains("REPLICA_UNAVAILABLE")=>self.stage(request).await.map(|(s,r)|Submission::Staged(s,r)),
            Err(error)=>Err(error),
        }
    }

    /// Call only after authenticating the exact request body. A control guard
    /// alone does not prove this node still possesses the staged ciphertext.
    async fn reusable_staged(&self,request:&SignedRequest,body:&[u8],logical_hash:&str,session:&LeaderSession)->Result<Option<(Staged,i64)>> {
        let object=match request.auth.request_kind {
            RequestKind::StoreEnvelope=>business::mail_key(&serde_json::from_slice::<StoreEnvelopeBody>(body)?.binding)?,
            RequestKind::RegisterRoute=>{let body:RegisterRouteBody=serde_json::from_slice(body)?;business::route_key(&request.auth.actor_id,&body.endpoint.device_id)},
            _=>return Ok(None),
        };
        let key=format!("staged/{object}");
        let snapshot=self.control.snapshot(&[&key]).await?;
        let Some(entry)=snapshot.entries.get(&key) else {return Ok(None)};
        let staged:Staged=serde_json::from_slice(&entry.value)?;
        if staged.actor_id!=request.auth.actor_id || staged.operation_id!=request.auth.operation_id {return Ok(None)}
        ensure!(staged.logical_hash==logical_hash,"ID_CONFLICT: staged retry");
        let Some(operation)=self.store.prepared_operation(&staged.attempt_id).await? else {return Ok(None)};
        ensure!(digest(&operation.encoded()?)==staged.payload_hash && operation.logical_hash==logical_hash,"staged payload hash mismatch");
        self.finish_read(session).await?;
        Ok(Some((staged,entry.mod_revision)))
    }

    /// Admission preflight prevents known-full mailboxes from writing bodies.
    /// The final transaction repeats these checks to prevent concurrent oversell.
    async fn preflight_store_capacity(&self,auth:&RequestAuth,body:&[u8])->Result<()> {
        if auth.request_kind!=RequestKind::StoreEnvelope {return Ok(())}
        let body:StoreEnvelopeBody=serde_json::from_slice(body)?;
        let stage_key=format!("staged/{}",business::mail_key(&body.binding)?);
        let mailbox_key=format!("usage/{}",digest(body.binding.recipient_key_id.as_bytes()));
        let snapshot=self.control.snapshot(&[&stage_key,&mailbox_key,"usage/global"]).await?;
        if let Some(entry)=snapshot.entries.get(&stage_key) {
            let staged:Staged=serde_json::from_slice(&entry.value)?;
            ensure!(staged.binding.as_ref()==Some(&body.binding) && staged.logical_hash==body.binding.logical_hash()?,"ID_CONFLICT: staged capacity reservation");
            return Ok(());
        }
        let byte_len=envelope_core::decode_bytes(&body.envelope_b64,"envelope_b64")?.len() as u64;
        for (key,max_bytes,max_count) in [(mailbox_key.as_str(),256*1024*1024,1000),("usage/global",1024*1024*1024,u64::MAX)] {
            let usage=snapshot.entries.get(key).map(|e|serde_json::from_slice::<Usage>(&e.value)).transpose()?.unwrap_or_default();
            ensure!(usage.bytes.checked_add(byte_len).is_some_and(|v|v<=max_bytes)
                && usage.count.checked_add(1).is_some_and(|v|v<=max_count),"RATE_LIMITED: mailbox capacity");
        }
        Ok(())
    }

    pub async fn stage(&self,request:&SignedRequest)->Result<(Staged,i64)> {
        let _slot=self.preparations.acquire().await?;
        let body=request.decoded_body(12*1024*1024)?;
        let _bytes=self.prepare_bytes.acquire_many(u32::try_from(body.len().max(1))?).await?;
        let (session,_)=self.barrier().await?;
        ensure!(matches!(request.auth.request_kind,RequestKind::StoreEnvelope|RequestKind::RegisterRoute),"REPLICA_UNAVAILABLE: command requires two replicas");
        let actor=self.request_contact(&request.auth,&body).await?;
        request.auth.verify(&actor,&self.config,request.auth.request_kind,&body,now_ms(),300_000)?;
        let logical_hash=logical_request_hash(&request.auth,&body)?;
        if let Some(existing)=self.reusable_staged(request,&body,&logical_hash,&session).await? {return Ok(existing)}
        let attempt=random_token();
        let (logical_hash,changes)=business::prepare_changes(&self.store,&self.config,&request.auth,&body,&attempt,now_ms()).await?;
        self.preflight_store_capacity(&request.auth,&body).await?;
        let operation=PreparedOperation {cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation.0,config_epoch:self.config.config_epoch.0,
            leader_term:session.term,attempt_id:attempt.clone(),actor_id:request.auth.actor_id.clone(),operation_id:request.auth.operation_id.clone(),logical_hash:logical_hash.clone(),
            authorization:serde_json::to_vec(&request.auth)?,request_body:body,changes};
        let hash=self.store.prepare(&operation).await?;
        let binding=if request.auth.request_kind==RequestKind::StoreEnvelope {Some(serde_json::from_slice::<StoreEnvelopeBody>(&operation.request_body)?.binding)} else {None};
        let byte_len=if binding.is_some() {let b:StoreEnvelopeBody=serde_json::from_slice(&operation.request_body)?;envelope_core::decode_bytes(&b.envelope_b64,"envelope_b64")?.len() as u64} else {0};
        let object=operation.changes.first().context("missing primary object")?.key.clone();
        let stage_key=format!("staged/{object}");
        let object_key=format!("objects/{object}");
        let op_key=operation_key(&operation.actor_id,&operation.operation_id);
        let mailbox_key=binding.as_ref().map(|b|format!("usage/{}",digest(b.recipient_key_id.as_bytes())));
        let mut keys=vec![stage_key.clone(),object_key.clone(),op_key.clone()];
        if let Some(key)=&mailbox_key {keys.extend([key.clone(),"usage/global".into()]);}
        let _commit=self.commit.lock().await;
        let snapshot=self.control.snapshot(&keys.iter().map(String::as_str).collect::<Vec<_>>()).await?;
        if let Some(entry)=snapshot.entries.get(&op_key) {
            let prior:OperationGuard=serde_json::from_slice(&entry.value)?;
            ensure!(prior.logical_hash==logical_hash,"ID_CONFLICT");
            ensure!(prior.decided.is_none(),"ALREADY_STORED");
        }
        if let Some(entry)=snapshot.entries.get(&stage_key) {
            let prior:Staged=serde_json::from_slice(&entry.value)?;
            ensure!(prior.logical_hash==logical_hash || (binding.is_none() && prior.binding.is_none() && prior.actor_id==operation.actor_id),"ID_CONFLICT: staged object");
        }
        let mut guards=vec![Guard::Missing(format!("attempts/{attempt}")),entry_guard(&stage_key,snapshot.entries.get(&stage_key)),entry_guard(&op_key,snapshot.entries.get(&op_key)),entry_guard(&object_key,snapshot.entries.get(&object_key))];
        if binding.is_some() {ensure!(!snapshot.entries.contains_key(&object_key),"ALREADY_STORED");}
        let staged=Staged {object_key:object,actor_id:operation.actor_id.clone(),operation_id:operation.operation_id.clone(),logical_hash:logical_hash.clone(),payload_hash:hash.clone(),
            attempt_id:attempt.clone(),node_id:self.node_id.clone(),binding,ack:self.ack(&operation,&hash)?,byte_len};
        let mut writes=vec![Change::Put(stage_key.clone(),serde_json::to_vec(&staged)?),
            Change::Put(op_key,serde_json::to_vec(&OperationGuard {logical_hash,attempt_id:attempt.clone(),decided:None,staged:Some(staged.clone())})?),
            Change::Put(format!("attempts/{attempt}"),b"staged".to_vec())];
        if request.auth.request_kind==RequestKind::RegisterRoute {
            let route:RegisterRouteBody=serde_json::from_slice(&operation.request_body)?;
            writes.push(Change::Put(format!("transient_contacts/{}",digest(route.owner_contact.key_id.as_bytes())),
                serde_json::to_vec(&(route.owner_contact,session.term,route.endpoint.expires_at_unix_ms))?));
        }
        if let Some(mailbox_key)=&mailbox_key {
            // Replacing the same staged object does not reserve its bytes twice.
            if !snapshot.entries.contains_key(&stage_key) {
                for (key,max_bytes,max_count) in [(mailbox_key.as_str(),256*1024*1024,1000),("usage/global",1024*1024*1024,u64::MAX)] {
                    let entry=snapshot.entries.get(key);
                    let mut usage=entry.map(|e|serde_json::from_slice::<Usage>(&e.value)).transpose()?.unwrap_or_default();
                    usage.bytes=usage.bytes.checked_add(byte_len).context("usage overflow")?;usage.count=usage.count.checked_add(1).context("usage overflow")?;
                    ensure!(usage.bytes<=max_bytes && usage.count<=max_count,"RATE_LIMITED: mailbox capacity");
                    guards.push(entry_guard(key,entry));writes.push(Change::Put(key.into(),serde_json::to_vec(&usage)?));
                }
            }
        }
        ensure!(self.control.guarded_txn(&session,true,&guards,&writes).await?,"NOT_READY: staging fenced");
        let snapshot=self.control.snapshot(&[&stage_key]).await?;
        let entry=snapshot.entries.get(&stage_key).context("NOT_READY: stage guard changed")?;
        ensure!(entry.value==serde_json::to_vec(&staged)?,"NOT_READY: stage guard changed");
        self.finish_read(&session).await?;
        Ok((staged,entry.mod_revision))
    }

    pub async fn request_contact(&self,auth:&RequestAuth,body:&[u8])->Result<envelope_core::Contact> {
        match business::request_contact(&self.store,auth,body).await {
            Ok(contact)=>Ok(contact),
            Err(error) if error.to_string().contains("actor route is not registered")=>{
                let key=format!("transient_contacts/{}",digest(auth.actor_id.as_bytes()));
                let snapshot=self.control.snapshot(&[&key]).await?;
                let value=snapshot.entries.get(&key).context("AUTH_FAILED: actor route is not registered")?;
                let (contact,term,expires):(envelope_core::Contact,u64,u128)=serde_json::from_slice(&value.value)?;
                ensure!(contact.key_id==auth.actor_id && expires>now_ms().into()
                    && snapshot.leader.as_ref().is_some_and(|l|l.create_revision as u64==term),"AUTH_FAILED: transient identity expired");
                contact.validate()?;Ok(contact)
            },
            Err(error)=>Err(error),
        }
    }

    pub async fn record_result(&self,request:&SignedRequest)->Result<serde_json::Value> {
        let body=request.decoded_body(16*1024)?;
        let result_body:RecordResultBody=serde_json::from_slice(&body)?;
        let (session,_)=self.barrier().await?;
        request.auth.verify(&result_body.recipient_contact,&self.config,RequestKind::RecordResult,&body,now_ms(),300_000)?;
        let result=&result_body.result;
        result.validate()?;
        ensure!(result.recipient_key_id==request.auth.actor_id && result.received_at.0<=now_ms().saturating_add(300_000),"AUTH_FAILED: recipient result");
        result.verify_signature(&result_body.recipient_contact.signing_public)?;
        let object_key=business::result_key(result)?;
        let inbox_key=format!("result_inbox/{object_key}");
        let stage_key=format!("staged/{object_key}");
        let snapshot=self.control.snapshot(&[&inbox_key,&stage_key]).await?;
        let existing=snapshot.entries.get(&inbox_key).map(|e|serde_json::from_slice::<ResultInbox>(&e.value)).transpose()?;
        let formal=self.store.object(&object_key).await?.map(|object|serde_json::from_slice::<business::MailRecord>(&object.value)).transpose()?;
        let binding=if let Some(record)=&formal {record.binding.clone()}
        else if let Some(entry)=snapshot.entries.get(&stage_key) {serde_json::from_slice::<Staged>(&entry.value)?.binding.context("missing staged binding")?}
        else {business::unbound_result_binding(result)};
        result.verify(&result_body.recipient_contact,&binding)?;
        let last_result=existing.as_ref().map(|r|r.result.clone()).or_else(||formal.as_ref().and_then(|r|r.result.clone()));
        let mut state=MessageState {storage_state:StorageState::LocalPending,
            delivery_state:if formal.as_ref().is_some_and(|r|r.expired) {DeliveryState::Expired} else {last_result.as_ref().map(|r|r.outcome.into()).unwrap_or(DeliveryState::Pending)},last_result};
        state.apply_recipient_result(result,&result_body.recipient_contact,&binding)?;
        let inbox=ResultInbox {result:result.clone(),contact:result_body.recipient_contact,auth:request.auth.clone(),body_json:String::from_utf8(body)?};
        ensure!(self.control.guarded_txn(&session,true,&[entry_guard(&inbox_key,snapshot.entries.get(&inbox_key))],
            &[Change::Put(inbox_key.clone(),serde_json::to_vec(&inbox)?)]).await?,"NOT_READY: result changed concurrently");
        // Quorum persistence of this end-to-end proof is independent of body
        // replication. A failed data replica cannot erase a real delivered result.
        match self.submit(request).await {
            Ok(decided)=>Ok(serde_json::json!({"protocol_version":2,"status":"replicated","commit_index":decided.index.to_string()})),
            Err(error) if error.to_string().contains("REPLICA_UNAVAILABLE") || error.to_string().contains("PAYLOAD_UNAVAILABLE")=>{
                let snapshot=self.control.snapshot(&[&inbox_key]).await?;
                let revision=snapshot.entries.get(&inbox_key).context("NOT_READY: result guard absent")?.mod_revision;
                self.finish_read(&session).await?;
                Ok(serde_json::json!({"protocol_version":2,"status":"staged_single","commit_index":null,"guard_revision":revision.to_string()}))
            },
            Err(error)=>Err(error),
        }
    }

    pub async fn result_for(&self,binding:&EnvelopeBinding)->Result<Option<RecipientResult>> {
        let key=format!("result_inbox/{}",business::mail_key(binding)?);
        let snapshot=self.control.snapshot(&[&key]).await?;
        let Some(entry)=snapshot.entries.get(&key) else {
            let Some(object)=self.store.object(&business::detached_result_key(&business::mail_key(binding)?)).await? else {return Ok(None)};
            let proof:business::ResultRecord=serde_json::from_slice(&object.value)?;
            proof.result.verify(&proof.recipient_contact,binding)?;
            return Ok(Some(proof.result));
        };
        let inbox:ResultInbox=serde_json::from_slice(&entry.value)?;
        inbox.result.verify(&inbox.contact,binding)?;
        Ok(Some(inbox.result))
    }

    async fn reconcile_degraded(&self)->Result<()> {
        // Persist terminal results before upgrading or redelivering staged body.
        let mut cursors=self.reconcile_cursors.lock().await;
        let results=self.control.scan_prefix("result_inbox",cursors.0.as_deref(),16).await?;
        for (key,entry) in results.entries {
            cursors.0=Some(key);
            let inbox:ResultInbox=serde_json::from_slice(&entry.value)?;
            let key=business::detached_result_key(&business::result_key(&inbox.result)?);
            if let Some(object)=self.store.object(&key).await? {
                let record:business::ResultRecord=serde_json::from_slice(&object.value)?;
                if record.result.result_sequence>=inbox.result.result_sequence {continue}
            }
            let request=SignedRequest {auth:inbox.auth.clone(),body_b64:envelope_core::encode_bytes(inbox.body_json.as_bytes())};
            self.submit_with_clock(&request,inbox.auth.requested_at.0).await?;
        }
        if !results.more {cursors.0=None;}
        let stages=self.control.scan_prefix("staged",cursors.1.as_deref(),8).await?;
        for (key,entry) in stages.entries {
            cursors.1=Some(key);
            let stage:Staged=serde_json::from_slice(&entry.value)?;
            if stage.binding.as_ref().is_some_and(|b|b.not_after.0<=now_ms()) {continue}
            let Some((_,_,operation))=self.staged_object(&stage.object_key).await? else {continue};
            let auth:RequestAuth=serde_json::from_slice(&operation.authorization)?;
            let request=SignedRequest {auth:auth.clone(),body_b64:envelope_core::encode_bytes(&operation.request_body)};
            self.submit_with_clock(&request,auth.requested_at.0).await?;
        }
        if !stages.more {cursors.1=None;}
        Ok(())
    }

    pub async fn staged_object(&self,key:&str)->Result<Option<(Staged,i64,PreparedOperation)>> {
        let stage_key=format!("staged/{key}");
        let snapshot=self.control.snapshot(&[&stage_key]).await?;
        let Some(entry)=snapshot.entries.get(&stage_key) else {return Ok(None)};
        let staged:Staged=serde_json::from_slice(&entry.value)?;
        let prepared=self.store.prepared_operation(&staged.attempt_id).await?;
        let operation=if let Some(prepared)=prepared {prepared} else {
            let response=self.peer.get(format!("{}/internal/v2/payload/{}",self.peer_url,staged.payload_hash)).send().await.context("PAYLOAD_UNAVAILABLE")?;
            ensure!(response.status().is_success(),"PAYLOAD_UNAVAILABLE");
            let bytes=response.bytes().await?;
            ensure!(bytes.len()<=12*1024*1024 && digest(&bytes)==staged.payload_hash,"invalid staged payload");
            let operation:PreparedOperation=serde_json::from_slice(&bytes)?;
            self.store.prepare(&operation).await?;operation
        };
        ensure!(operation.logical_hash==staged.logical_hash && digest(&operation.encoded()?)==staged.payload_hash,"staged content mismatch");
        Ok(Some((staged,entry.mod_revision,operation)))
    }

    pub async fn submit(&self,request:&SignedRequest)->Result<Decided> {
        self.submit_with_clock(request,now_ms()).await
    }
    async fn submit_with_clock(&self,request:&SignedRequest,authorization_now:u64)->Result<Decided> {
        let _slot=self.preparations.acquire().await?;
        let body=request.decoded_body(12*1024*1024)?;
        let _bytes=self.prepare_bytes.acquire_many(u32::try_from(body.len().max(1))?).await?;
        let (session,_)=self.barrier().await?;
        let actor=business::request_contact(&self.store,&request.auth,&body).await?;
        request.auth.verify(&actor,&self.config,request.auth.request_kind,&body,authorization_now,300_000)?;
        let logical_hash=logical_request_hash(&request.auth,&body)?;
        let operation_key=operation_key(&request.auth.actor_id,&request.auth.operation_id);
        let snapshot=self.control.snapshot(&[&operation_key]).await?;
        if let Some(entry)=snapshot.entries.get(&operation_key) {
            let previous:OperationGuard=serde_json::from_slice(&entry.value)?;
            ensure!(logical_hash==previous.logical_hash,"ID_CONFLICT");
            if let Some(decided)=previous.decided {
                self.catch_up(decided.index).await?;
                return Ok(decided);
            }
            if previous.staged.is_none() {
                let attempt_key=format!("attempts/{}",previous.attempt_id);
                let attempts=self.control.snapshot(&[&attempt_key]).await?;
                if attempts.entries.get(&attempt_key).is_some_and(|e|e.value==b"open") {
                    if let Some(prepared)=self.store.prepared_operation(&previous.attempt_id).await? {
                        if prepared.leader_term==session.term && prepared.config_epoch==self.config.config_epoch.0
                            && prepared.control_generation==self.config.control_generation.0
                            && business::verify_prepared(&self.store,&self.config,&prepared,authorization_now).await.is_ok() {
                            self.preflight_store_capacity(&request.auth,&body).await?;
                            return self.commit_operation(prepared,&session).await;
                        }
                        // Sealing races safely with an in-flight commit: its
                        // attempt=open CAS can no longer succeed after sealing.
                        super::recovery::seal_and_collect(&self.control,&session,&self.store,&previous.attempt_id).await?;
                    }
                }
            }
        }
        let attempt=random_token();
        let (logical_hash,changes)=business::prepare_changes(&self.store,&self.config,&request.auth,&body,&attempt,authorization_now).await?;
        self.preflight_store_capacity(&request.auth,&body).await?;
        let operation=PreparedOperation {cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation.0,
            config_epoch:self.config.config_epoch.0,leader_term:session.term,attempt_id:attempt.clone(),actor_id:request.auth.actor_id.clone(),
            operation_id:request.auth.operation_id.clone(),logical_hash:logical_hash.clone(),authorization:serde_json::to_vec(&request.auth)?,request_body:body,changes};
        self.commit_operation(operation,&session).await
    }

    pub(super) async fn commit_operation(&self,operation:PreparedOperation,session:&LeaderSession)->Result<Decided> {
        let operation_key=operation_key(&operation.actor_id,&operation.operation_id);
        let attempt_key=format!("attempts/{}",operation.attempt_id);
        let snapshot=self.control.snapshot(&[&operation_key,&attempt_key]).await?;
        let logical_hash=operation.logical_hash.clone();
        let attempt=operation.attempt_id.clone();
        let guard=OperationGuard {logical_hash:logical_hash.clone(),attempt_id:attempt.clone(),decided:None,staged:None};
        let mut resume=false;
        if let Some(entry)=snapshot.entries.get(&operation_key) {
            let previous:OperationGuard=serde_json::from_slice(&entry.value)?;
            ensure!(previous.logical_hash==logical_hash,"ID_CONFLICT");
            if let Some(decided)=previous.decided {self.catch_up(decided.index).await?;return Ok(decided);}
            resume=previous.attempt_id==attempt && previous.staged.is_none()
                && snapshot.entries.get(&attempt_key).is_some_and(|e|e.value==b"open");
        }
        let operation_guard=entry_guard(&operation_key,snapshot.entries.get(&operation_key));
        let attempt_guard=if resume {Guard::Value(attempt_key.clone(),b"open".to_vec())} else {Guard::Missing(attempt_key.clone())};
        ensure!(self.control.guarded_txn(&session,true,&[operation_guard,attempt_guard],
            &[Change::Put(operation_key.clone(),serde_json::to_vec(&guard)?),Change::Put(attempt_key.clone(),b"open".to_vec())]).await?,"NOT_READY: prepare registration changed");
        let hash=self.store.prepare(&operation).await?;
        let local=self.ack(&operation,&hash)?;
        let response=self.peer.post(format!("{}/internal/v2/prepare",self.peer_url)).json(&operation).send().await.context("REPLICA_UNAVAILABLE")?;
        ensure!(response.status().is_success(),"REPLICA_UNAVAILABLE: peer rejected prepare");
        let other:PrepareAck=response.json().await?;
        other.verify(&self.config)?;
        ensure!(other.node_id!=self.node_id && other.attempt_id==attempt && other.payload_hash==hash && other.logical_hash==logical_hash
            && other.operation_id==operation.operation_id && other.actor_id==operation.actor_id && other.leader_term.0==session.term,"peer preparation proof mismatch");
        let mut acks=vec![local,other]; acks.sort_by(|a,b|a.node_id.cmp(&b.node_id));
        let _commit=self.commit.lock().await;
        let object_keys:Vec<String>=operation.changes.iter().map(|c|format!("objects/{}",c.key)).collect();
        let mut extra=object_keys.clone(); extra.extend([operation_key.clone(),attempt_key.clone()]);
        let stage_key=format!("staged/{}",operation.changes[0].key);
        extra.push(stage_key.clone());
        let store_body=if operation.changes[0].kind=="mailbox" && operation.changes[0].expected_version==0 {
            Some(serde_json::from_slice::<StoreEnvelopeBody>(&operation.request_body)?)
        } else {None};
        let mailbox_usage=store_body.as_ref().map(|b|format!("usage/{}",digest(b.binding.recipient_key_id.as_bytes())));
        if let Some(key)=&mailbox_usage {extra.push(key.clone());extra.push("usage/global".into());}
        let snapshot=self.control.snapshot(&extra.iter().map(String::as_str).collect::<Vec<_>>()).await?;
        let mut guards=vec![Guard::Value("head".into(),snapshot.head.value.clone()),Guard::Value(operation_key.clone(),serde_json::to_vec(&guard)?),
            Guard::Value(attempt_key.clone(),b"open".to_vec())];
        let mut writes=Vec::new();
        let prior_stage=snapshot.entries.get(&stage_key).map(|e|serde_json::from_slice::<Staged>(&e.value)).transpose()?;
        if let Some(staged)=&prior_stage {
            ensure!(staged.logical_hash==operation.logical_hash,"ID_CONFLICT: staged content");
            guards.push(entry_guard(&stage_key,snapshot.entries.get(&stage_key)));
            writes.push(Change::Delete(stage_key));
        }
        for (change,key) in operation.changes.iter().zip(&object_keys) {
            let entry=snapshot.entries.get(key);
            let current=entry.map(|e|serde_json::from_slice::<ObjectGuard>(&e.value)).transpose()?;
            ensure!(current.as_ref().map(|g|g.version).unwrap_or(0)==change.expected_version,"OBJECT_VERSION_CONFLICT");
            ensure!(current.as_ref().is_none_or(|g|!g.terminal || change.terminal),"terminal resurrection");
            guards.push(entry_guard(key,entry));
            writes.push(Change::Put(key.clone(),serde_json::to_vec(&ObjectGuard {version:change.expected_version+1,kind:change.kind.clone(),terminal:change.terminal})?));
        }
        if let (Some(body),Some(mailbox_key))=(store_body,&mailbox_usage) { if prior_stage.is_none() {
            let byte_len=envelope_core::decode_bytes(&body.envelope_b64,"envelope_b64")?.len() as u64;
            for (key,max_bytes,max_count) in [(mailbox_key.as_str(),256*1024*1024,1000),("usage/global",1024*1024*1024,u64::MAX)] {
                let entry=snapshot.entries.get(key);
                let mut usage=entry.map(|e|serde_json::from_slice::<Usage>(&e.value)).transpose()?.unwrap_or_default();
                usage.bytes=usage.bytes.checked_add(byte_len).context("usage overflow")?;
                usage.count=usage.count.checked_add(1).context("usage overflow")?;
                ensure!(usage.bytes<=max_bytes && usage.count<=max_count,"RATE_LIMITED: mailbox capacity");
                guards.push(entry_guard(key,entry)); writes.push(Change::Put(key.into(),serde_json::to_vec(&usage)?));
            }
        } }
        let decided=Decided {index:snapshot.head_index.checked_add(1).context("commit overflow")?,attempt_id:attempt,payload_hash:hash,
            logical_hash,actor_id:operation.actor_id.clone(),operation_id:operation.operation_id.clone(),acks};
        let bytes=serde_json::to_vec(&decided)?;
        ensure!(bytes.len()<=16*1024,"decision exceeds metadata limit");
        let key=decision_key(decided.index); guards.push(Guard::Missing(key.clone()));
        writes.extend([Change::Put(key,bytes),Change::Put("head".into(),decided.index.to_string().into_bytes()),
            Change::Put(operation_key,serde_json::to_vec(&OperationGuard {decided:Some(decided.clone()),..guard})?),Change::Put(attempt_key,b"committed".to_vec())]);
        ensure!(self.control.guarded_txn(&session,true,&guards,&writes).await?,"NOT_READY: commit fencing comparison failed");
        self.catch_up(decided.index).await?;
        Ok(decided)
    }

    pub async fn prepare_peer(&self,operation:PreparedOperation)->Result<PrepareAck> {
        let _slot=self.preparations.acquire().await?;
        let bytes=operation.encoded()?;
        let _bytes=self.prepare_bytes.acquire_many(u32::try_from(bytes.len())?).await?;
        let attempt_key=format!("attempts/{}",operation.attempt_id);
        let snapshot=self.control.snapshot(&[&attempt_key]).await?;
        let leader=snapshot.leader.as_ref().context("NO_QUORUM: leader absent")?;
        let leader_value:LeaderValue=serde_json::from_slice(&leader.value)?;
        ensure!(leader.create_revision as u64==operation.leader_term && leader_value.node_id!=self.node_id,"NOT_LEADER: obsolete/invalid prepare");
        ensure!(snapshot.entries.get(&attempt_key).is_some_and(|a|a.value==b"open"),"attempt is not open");
        self.catch_up(snapshot.head_index).await?;
        if operation.actor_id==expiry_actor(&self.config.cluster_id) {
            super::maintenance::verify_expiry(&self.store,&self.config,&operation,&leader_value.node_id,now_ms()).await?;
            let hash=self.store.prepare(&operation).await?;
            return self.ack(&operation,&hash);
        }
        let auth:RequestAuth=serde_json::from_slice(&operation.authorization)?;
        let mut validation_now=now_ms();
        if validation_now.abs_diff(auth.requested_at.0)>300_000 {
            let key=if auth.request_kind==RequestKind::RecordResult {
                let body:RecordResultBody=serde_json::from_slice(&operation.request_body)?;
                format!("result_inbox/{}",business::result_key(&body.result)?)
            } else {format!("staged/{}",operation.changes.first().context("missing object")?.key)};
            let historical=self.control.snapshot(&[&key]).await?;
            let entry=historical.entries.get(&key).context("AUTH_FAILED: old authorization has no retained control guard")?;
            if auth.request_kind==RequestKind::RecordResult {
                let inbox:ResultInbox=serde_json::from_slice(&entry.value)?;
                ensure!(inbox.auth.body_sha256==auth.body_sha256 && inbox.auth.actor_id==auth.actor_id,"AUTH_FAILED: replay guard mismatch");
            } else {
                let staged:Staged=serde_json::from_slice(&entry.value)?;
                ensure!(staged.logical_hash==operation.logical_hash && staged.actor_id==auth.actor_id,"AUTH_FAILED: replay guard mismatch");
            }
            validation_now=auth.requested_at.0;
        }
        business::verify_prepared(&self.store,&self.config,&operation,validation_now).await?;
        self.preflight_store_capacity(&auth,&operation.request_body).await?;
        let hash=self.store.prepare(&operation).await?;
        self.ack(&operation,&hash)
    }
    fn ack(&self,operation:&PreparedOperation,hash:&str)->Result<PrepareAck> {
        let mut ack=PrepareAck {protocol_version:2,cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation,
            config_epoch:self.config.config_epoch,leader_term:DecimalU64(operation.leader_term),attempt_id:operation.attempt_id.clone(),operation_id:operation.operation_id.clone(),
            actor_id:operation.actor_id.clone(),logical_hash:operation.logical_hash.clone(),payload_hash:hash.into(),node_id:self.node_id.clone(),
            node_incarnation:self.config.node(&self.node_id)?.node_incarnation.clone(),signature:String::new()};
        self.sign(&mut ack)?; Ok(ack)
    }
    pub fn receipt(&self,decided:&Decided,binding:&EnvelopeBinding)->Result<CommitReceipt> {
        self.validate_decision(decided)?;
        let proof_config=self.decision_config(decided)?;
        let historic=proof_config.control_generation!=self.config.control_generation || proof_config.config_epoch!=self.config.config_epoch;
        let mut receipt=CommitReceipt {protocol_version:2,cluster_id:self.config.cluster_id.clone(),control_generation:proof_config.control_generation,config_epoch:proof_config.config_epoch,
            leader_term:decided.acks[0].leader_term,commit_index:Some(DecimalU64(decided.index)),operation_id:binding.operation_id.clone(),sender_key_id:binding.sender_key_id.clone(),
            recipient_key_id:binding.recipient_key_id.clone(),envelope_id:binding.envelope_id.clone(),envelope_sha256:binding.envelope_sha256.clone(),not_after:binding.not_after,
            storage_state:StorageState::Replicated,delivery_state:DeliveryState::Pending,replica_evidence:decided.acks.clone(),staged_guard_revision:None,node_id:self.node_id.clone(),
            issuer_control_generation:self.config.control_generation,issuer_config_epoch:self.config.config_epoch,
            proof_config:historic.then(||proof_config.clone()),expiry_evidence:None,node_signature:String::new()};
        self.sign(&mut receipt)?;
        if historic { receipt.verify_with_history(&self.config,self.administrator_public.as_deref().context("administrator key required for historical proofs")?,binding)?; }
        else { receipt.verify(&self.config,binding)?; }
        Ok(receipt)
    }
    pub async fn receipt_for(&self,binding:&EnvelopeBinding)->Result<CommitReceipt> {
        let key=operation_key(&binding.sender_key_id,&binding.operation_id);
        let snapshot=self.control.snapshot(&[&key]).await?;
        let guard:OperationGuard=serde_json::from_slice(&snapshot.entries.get(&key).context("PAYLOAD_UNAVAILABLE")?.value)?;
        let mut receipt=self.receipt(&guard.decided.context("NOT_READY: storage is not committed")?,binding)?;
        if let Some(object)=self.store.object(&business::mail_key(binding)?).await? {
            let record:business::MailRecord=serde_json::from_slice(&object.value)?;
            if let Some(expiry_id)=record.expiry_operation_id {
                let expiry_key=operation_key(&expiry_actor(&self.config.cluster_id),&expiry_id);
                let snapshot=self.control.snapshot(&[&expiry_key]).await?;
                let guard:OperationGuard=serde_json::from_slice(&snapshot.entries.get(&expiry_key).context("PAYLOAD_UNAVAILABLE: expiry proof")?.value)?;
                let decided=guard.decided.context("NOT_READY: expiry not committed")?;
                self.validate_decision(&decided)?;
                let prepared=self.store.prepared_operation(&decided.attempt_id).await?.context("PAYLOAD_UNAVAILABLE: expiry command")?;
                let command:super::maintenance::ExpiryCommand=serde_json::from_slice(&prepared.authorization)?;
                let proof_config=self.decision_config(&decided)?;
                let historic=proof_config.control_generation!=self.config.control_generation || proof_config.config_epoch!=self.config.config_epoch;
                receipt.delivery_state=DeliveryState::Expired;
                receipt.expiry_evidence=Some(ExpiryEvidence {operation_id:expiry_id,expected_object_version:command.expected_object_version,
                    expired_at:command.expired_at,commit_index:decided.index.into(),replica_evidence:decided.acks.clone(),proof_config:historic.then(||proof_config.clone())});
                self.sign(&mut receipt)?;
                if let Some(admin)=&self.administrator_public {receipt.verify_with_history(&self.config,admin,binding)?;}
                else {receipt.verify(&self.config,binding)?;}
            }
        }
        Ok(receipt)
    }
    pub fn staged_receipt(&self,staged:&Staged,binding:&EnvelopeBinding,revision:i64)->Result<CommitReceipt> {
        ensure!(revision>0,"staged guard revision must be positive");
        ensure!(staged.binding.as_ref()==Some(binding),"staged binding mismatch");
        let ack=&staged.ack;
        ensure!(ack.node_id==staged.node_id && ack.attempt_id==staged.attempt_id && ack.payload_hash==staged.payload_hash
            && ack.logical_hash==staged.logical_hash && ack.actor_id==staged.actor_id && ack.operation_id==staged.operation_id,"staged acknowledgement mismatch");
        let proof_config=self.config_history.get(&(ack.control_generation.0,ack.config_epoch.0))
            .context("authenticated historical configuration required for staged evidence")?;
        ack.verify(proof_config)?;
        let historic=proof_config.control_generation!=self.config.control_generation || proof_config.config_epoch!=self.config.config_epoch;
        let mut receipt=CommitReceipt {protocol_version:2,cluster_id:self.config.cluster_id.clone(),control_generation:proof_config.control_generation,config_epoch:proof_config.config_epoch,
            leader_term:ack.leader_term,commit_index:None,operation_id:binding.operation_id.clone(),sender_key_id:binding.sender_key_id.clone(),
            recipient_key_id:binding.recipient_key_id.clone(),envelope_id:binding.envelope_id.clone(),envelope_sha256:binding.envelope_sha256.clone(),not_after:binding.not_after,
            storage_state:StorageState::StagedSingle,delivery_state:DeliveryState::Pending,replica_evidence:vec![ack.clone()],staged_guard_revision:Some(DecimalU64(revision as u64)),node_id:self.node_id.clone(),
            issuer_control_generation:self.config.control_generation,issuer_config_epoch:self.config.config_epoch,
            proof_config:historic.then(||proof_config.clone()),expiry_evidence:None,node_signature:String::new()};
        self.sign(&mut receipt)?;
        if historic { receipt.verify_with_history(&self.config,self.administrator_public.as_deref().context("administrator key required for historical proofs")?,binding)?; }
        else { receipt.verify(&self.config,binding)?; }
        Ok(receipt)
    }
}

pub fn now_ms()->u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().try_into().unwrap_or(u64::MAX) }
pub fn random_token()->String { let (_,public)=envelope_core::generate_signing_keypair(); public }
pub fn operation_key(actor:&str,operation:&str)->String {format!("operations/{}/{}",digest(actor.as_bytes()),digest(operation.as_bytes()))}
fn decision_key(index:u64)->String {format!("decisions/{index:020}")}
fn entry_guard(key:&str,entry:Option<&super::control::ControlEntry>)->Guard {match entry {Some(e)=>Guard::Value(key.into(),e.value.clone()),None=>Guard::Missing(key.into())}}
fn logical_request_hash(auth:&RequestAuth,body:&[u8])->Result<String> {
    if auth.request_kind==RequestKind::StoreEnvelope {
        let b:StoreEnvelopeBody=serde_json::from_slice(body)?;
        let bytes=envelope_core::decode_bytes(&b.envelope_b64,"envelope_b64")?;
        ensure!(digest(&bytes)==b.binding.envelope_sha256 && envelope_core::encode_bytes(&bytes)==b.envelope_b64,"ID_CONFLICT: retried ciphertext mismatch");
        ensure!(auth.operation_id==b.binding.operation_id && auth.actor_id==b.binding.sender_key_id,"ID_CONFLICT: retried binding mismatch");
        Ok(b.binding.logical_hash()?)
    }
    else {Ok(digest(&serde_json::to_vec(&(auth.request_kind,auth.actor_id.as_str(),auth.operation_id.as_str(),auth.body_sha256.as_str()))?))}
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod history_tests;

#[cfg(test)]
#[path = "capacity_tests.rs"]
mod capacity_tests;
