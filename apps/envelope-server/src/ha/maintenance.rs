//! Only the currently fenced business leader can authorize ordered expiry.
//! This is not a public RequestKind and no recipient/sender key can sign it.
use super::{business::{self, MailRecord}, coordinator::{Coordinator,now_ms,random_token}};
use crate::storage::v2::{ObjectChange,PreparedOperation,V2Store};
use anyhow::{Context,Result,ensure};
use envelope_server_core::ha::*;
use serde::{Serialize,Deserialize};
use serde_json::{Value,json};

#[derive(Clone,Serialize,Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExpiryCommand {
    pub cluster_id:String,
    pub control_generation:DecimalU64,
    pub config_epoch:DecimalU64,
    pub leader_term:DecimalU64,
    pub node_id:String,
    pub operation_id:String,
    pub binding:EnvelopeBinding,
    pub expected_object_version:DecimalU64,
    pub expired_at:DecimalU64,
    pub signature:String,
}
impl HaSigned for ExpiryCommand {
    const KIND:&'static str="ExpiryAuthorization";
    fn canonical_value(&self)->Value {json!([self.cluster_id,self.control_generation,self.config_epoch,self.leader_term,
        self.node_id,self.operation_id,[self.binding.operation_id,self.binding.sender_key_id,self.binding.recipient_key_id,
        self.binding.envelope_id,self.binding.envelope_sha256,self.binding.not_after],self.expected_object_version,self.expired_at])}
    fn signature(&self)->&str {&self.signature}
    fn signature_mut(&mut self)->&mut String {&mut self.signature}
}
async fn expiry_change(store:&V2Store,command:&ExpiryCommand,now:u64)->Result<ObjectChange> {
    ensure!(command.expired_at>=command.binding.not_after && command.expired_at.0<=now,"EXPIRED: expiry clock not reached");
    let key=business::mail_key(&command.binding)?;
    let object=store.object(&key).await?.context("PAYLOAD_UNAVAILABLE: expiry object")?;
    ensure!(object.version==command.expected_object_version.0 && !object.terminal,"OBJECT_VERSION_CONFLICT: expiry");
    let mut record:MailRecord=serde_json::from_slice(&object.value)?;
    record.binding.check_retry(&command.binding)?;
    ensure!(!record.expired && record.result.as_ref().is_none_or(|r|r.outcome==RecipientOutcome::Deferred),"terminal result cannot expire");
    record.expired=true;record.expiry_operation_id=Some(command.operation_id.clone());
    Ok(ObjectChange {key,kind:"mailbox".into(),expected_version:object.version,terminal:true,value:serde_json::to_vec(&record)?})
}
pub async fn verify_expiry(store:&V2Store,config:&ClusterConfigV2,operation:&PreparedOperation,leader_node:&str,now:u64)->Result<()> {
    let command:ExpiryCommand=serde_json::from_slice(&operation.authorization)?;
    ensure!(command.cluster_id==config.cluster_id && command.control_generation==config.control_generation && command.config_epoch==config.config_epoch
        && command.leader_term.0==operation.leader_term && command.node_id==leader_node && command.operation_id==operation.operation_id
        && operation.actor_id==expiry_actor(&config.cluster_id) && operation.request_body==operation.authorization,"AUTH_FAILED: expiry scope");
    command.verify_signature(&config.node(&command.node_id)?.signing_public)?;
    let expected=expiry_change(store,&command,now).await?;
    ensure!(operation.changes==vec![expected] && operation.logical_hash==expiry_logical_hash(&command.operation_id,&command.binding,
        command.expected_object_version,command.expired_at)?,"AUTH_FAILED: expiry mutation mismatch");
    Ok(())
}
impl Coordinator {
    pub async fn expire_due(&self,after:&str,limit:u32)->Result<Option<String>> {
        let objects=self.store.objects_by_kind("mailbox",after,limit).await?;
        let mut cursor=None;
        for object in objects {
            cursor=Some(object.key);
            if object.terminal {continue}
            let record:MailRecord=serde_json::from_slice(&object.value)?;
            if record.binding.not_after.0>now_ms() {continue}
            if self.result_for(&record.binding).await?.is_some_and(|r|DeliveryState::from(r.outcome).is_terminal()) {continue}
            let (session,_)=self.barrier().await?;
            let mut command=ExpiryCommand {cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation,
                config_epoch:self.config.config_epoch,leader_term:session.term.into(),node_id:self.node_id.clone(),
                operation_id:format!("expire-{}-{}",record.binding.object_key()?,object.version),
                expected_object_version:object.version.into(),expired_at:record.binding.not_after,binding:record.binding,signature:String::new()};
            self.sign(&mut command)?;
            let change=expiry_change(&self.store,&command,now_ms()).await?;
            let bytes=serde_json::to_vec(&command)?;
            let operation=PreparedOperation {cluster_id:self.config.cluster_id.clone(),control_generation:self.config.control_generation.0,
                config_epoch:self.config.config_epoch.0,leader_term:session.term,attempt_id:random_token(),actor_id:expiry_actor(&self.config.cluster_id),
                operation_id:command.operation_id.clone(),logical_hash:expiry_logical_hash(&command.operation_id,&command.binding,command.expected_object_version,command.expired_at)?,
                authorization:bytes.clone(),request_body:bytes,changes:vec![change]};
            self.commit_operation(operation,&session).await?;
        }
        Ok(cursor)
    }
}
