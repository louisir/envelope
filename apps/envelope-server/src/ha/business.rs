//! Deterministic business changes prepared on both replicas before a decision.
use anyhow::{Result, ensure, bail};
use envelope_core::{Contact, DeviceEndpointUpdate, EnvelopeIntroBundle};
use envelope_server_core::{AntiAbuseLimits, DeviceRegistrationRequest, IntroSessionPublishRequest, IntroSessionRespondRequest};
use envelope_server_core::ha::*;
use serde::{Deserialize, Serialize};
use crate::storage::v2::{ObjectChange, PreparedOperation, V2Store, digest};

pub const RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MailRecord {
    pub binding: EnvelopeBinding,
    pub attempt_id: String,
    pub created_at: DecimalU64,
    pub byte_len: u64,
    pub result: Option<RecipientResult>,
    pub expired: bool,
    #[serde(default)]
    pub expiry_operation_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteRecord {
    pub owner_contact: Contact,
    pub endpoint: DeviceEndpointUpdate,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResultRecord {
    pub result: RecipientResult,
    pub recipient_contact: Contact,
}

pub fn detached_result_key(mail_key: &str) -> String { format!("result/{mail_key}") }
pub fn unbound_result_binding(result: &RecipientResult) -> EnvelopeBinding {
    EnvelopeBinding { operation_id:"unbound-result".into(),sender_key_id:result.sender_key_id.clone(),
        recipient_key_id:result.recipient_key_id.clone(),envelope_id:result.envelope_id.clone(),
        envelope_sha256:result.envelope_sha256.clone(),not_after:DecimalU64(u64::MAX) }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IntroRecord {
    pub session_id: String,
    pub owner_bundle: EnvelopeIntroBundle,
    pub responder_bundle: Option<EnvelopeIntroBundle>,
}

pub fn contact_key(actor: &str) -> String { format!("contact/{}", digest(actor.as_bytes())) }
pub fn route_key(owner: &str, device: &str) -> String {
    format!("route/{}", digest(&serde_json::to_vec(&(owner,device)).expect("string pair serializes")))
}
pub fn intro_key(session: &str) -> String { format!("intro/{}", digest(session.as_bytes())) }
pub fn mail_key(binding: &EnvelopeBinding) -> Result<String> { Ok(format!("mail/{}", binding.object_key()?)) }
pub fn result_key(result: &RecipientResult) -> Result<String> {
    mail_key(&EnvelopeBinding { operation_id: "result-key".into(), sender_key_id:result.sender_key_id.clone(),
        recipient_key_id:result.recipient_key_id.clone(),envelope_id:result.envelope_id.clone(),
        envelope_sha256:result.envelope_sha256.clone(),not_after:DecimalU64(1) })
}

pub async fn contact(store: &V2Store, actor: &str) -> Result<Contact> {
    let object = store.object(&contact_key(actor)).await?.ok_or_else(|| anyhow::anyhow!("AUTH_FAILED: actor route is not registered"))?;
    let contact: Contact = serde_json::from_slice(&object.value)?;
    contact.validate()?;
    ensure!(contact.key_id == actor, "AUTH_FAILED: contact identity mismatch");
    Ok(contact)
}

pub async fn request_contact(store: &V2Store, auth: &RequestAuth, body: &[u8]) -> Result<Contact> {
    let actor = match auth.request_kind {
        RequestKind::StoreEnvelope => serde_json::from_slice::<StoreEnvelopeBody>(body)?.sender_contact,
        RequestKind::RegisterRoute => serde_json::from_slice::<RegisterRouteBody>(body)?.owner_contact,
        RequestKind::RecordResult => serde_json::from_slice::<RecordResultBody>(body)?.recipient_contact,
        RequestKind::IntroPublish => serde_json::from_slice::<IntroPublishBody>(body)?.owner_bundle.contact,
        RequestKind::IntroRespond => serde_json::from_slice::<IntroRespondBody>(body)?.responder_bundle.contact,
        _ => contact(store, &auth.actor_id).await?,
    };
    actor.validate()?;
    ensure!(actor.key_id == auth.actor_id, "AUTH_FAILED: request identity mismatch");
    Ok(actor)
}

async fn change<T: Serialize>(store: &V2Store, key: String, kind: &str, value: &T, terminal: bool) -> Result<ObjectChange> {
    let version = store.object(&key).await?.map(|o| o.version).unwrap_or(0);
    Ok(ObjectChange { key,kind:kind.into(),expected_version:version,terminal,value:serde_json::to_vec(value)? })
}

async fn remember_contact(store: &V2Store, actor: &Contact, changes: &mut Vec<ObjectChange>) -> Result<()> {
    if let Some(existing)=store.object(&contact_key(&actor.key_id)).await? {
        let old:Contact=serde_json::from_slice(&existing.value)?;
        ensure!(old.signing_public==actor.signing_public && old.agreement_public==actor.agreement_public,"ID_CONFLICT: contact");
    } else {changes.push(change(store,contact_key(&actor.key_id),"contact",actor,false).await?);}
    Ok(())
}

pub async fn prepare_changes(store: &V2Store, config: &ClusterConfigV2, auth: &RequestAuth, body: &[u8],
    attempt_id: &str, now: u64) -> Result<(String,Vec<ObjectChange>)> {
    let actor = request_contact(store,auth,body).await?;
    auth.verify(&actor,config,auth.request_kind,body,now,300_000)?;
    let limits = AntiAbuseLimits::default();
    let logical_hash = digest(&serde_json::to_vec(&(auth.request_kind,auth.actor_id.as_str(),auth.operation_id.as_str(),auth.body_sha256.as_str()))?);
    match auth.request_kind {
        RequestKind::StoreEnvelope => {
            let request: StoreEnvelopeBody = serde_json::from_slice(body)?;
            request.binding.validate()?;
            ensure!(auth.operation_id == request.binding.operation_id && auth.actor_id == request.binding.sender_key_id, "ID_CONFLICT: envelope binding");
            ensure!(request.created_at.0 <= now.saturating_add(300_000) && request.created_at.0 < request.binding.not_after.0
                && request.binding.not_after.0 - request.created_at.0 <= RETENTION_MS, "invalid fixed retention");
            ensure!(now < request.binding.not_after.0, "EXPIRED");
            ensure!(request.envelope_b64.len() <= (limits.max_envelope_bytes * 4 / 3) + 4, "envelope size limit");
            let bytes = envelope_core::decode_bytes(&request.envelope_b64,"envelope_b64")?;
            ensure!(bytes.len() > envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES && bytes.len() <= limits.max_envelope_bytes,
                "envelope size limit");
            ensure!(envelope_core::encode_bytes(&bytes) == request.envelope_b64 && digest(&bytes) == request.binding.envelope_sha256, "ID_CONFLICT: envelope bytes/hash");
            let key = mail_key(&request.binding)?;
            if let Some(existing) = store.object(&key).await? {
                let old: MailRecord = serde_json::from_slice(&existing.value)?;
                old.binding.check_retry(&request.binding)?;
                bail!("ALREADY_STORED");
            }
            let result=store.object(&detached_result_key(&key)).await?.map(|o|serde_json::from_slice::<ResultRecord>(&o.value)).transpose()?;
            if let Some(proof)=&result {proof.result.verify(&proof.recipient_contact,&request.binding)?;}
            let terminal=result.as_ref().is_some_and(|r|DeliveryState::from(r.result.outcome).is_terminal());
            let record = MailRecord { binding:request.binding.clone(),attempt_id:attempt_id.into(),created_at:request.created_at,
                byte_len:bytes.len() as u64,result:result.map(|r|r.result),expired:false,expiry_operation_id:None };
            let mut changes=vec![change(store,key,"mailbox",&record,terminal).await?];
            remember_contact(store,&actor,&mut changes).await?;
            Ok((request.binding.logical_hash()?,changes))
        }
        RequestKind::RegisterRoute => {
            let request: RegisterRouteBody = serde_json::from_slice(body)?;
            DeviceRegistrationRequest { version:1,owner_contact:request.owner_contact.clone(),endpoint:request.endpoint.clone() }.validate(now.into(),&limits)?;
            let key = route_key(&actor.key_id,&request.endpoint.device_id);
            let route = change(store,key,"route",&RouteRecord { owner_contact:actor.clone(),endpoint:request.endpoint },false).await?;
            ensure!(route.expected_version == request.expected_version.0, "OBJECT_VERSION_CONFLICT");
            let mut changes = vec![route];
            remember_contact(store,&actor,&mut changes).await?;
            Ok((logical_hash,changes))
        }
        RequestKind::RecordResult => {
            let request: RecordResultBody = serde_json::from_slice(body)?;
            let key = result_key(&request.result)?;
            let mut record=store.object(&key).await?.map(|o|serde_json::from_slice::<MailRecord>(&o.value)).transpose()?;
            let prior=store.object(&detached_result_key(&key)).await?.map(|o|serde_json::from_slice::<ResultRecord>(&o.value)).transpose()?;
            let binding=record.as_ref().map(|r|r.binding.clone()).unwrap_or_else(||unbound_result_binding(&request.result));
            request.result.verify(&actor,&binding)?;
            ensure!(request.result.received_at.0 <= now.saturating_add(300_000), "invalid future result");
            let last=prior.map(|r|r.result).or_else(||record.as_ref().and_then(|r|r.result.clone()));
            let mut state = MessageState { storage_state:StorageState::Replicated,
                delivery_state:if record.as_ref().is_some_and(|r|r.expired) {DeliveryState::Expired} else {last.as_ref().map(|r|r.outcome.into()).unwrap_or(DeliveryState::Pending)},
                last_result:last };
            state.apply_recipient_result(&request.result,&actor,&binding)?;
            let terminal = state.delivery_state.is_terminal();
            let mut changes=vec![change(store,detached_result_key(&key),"recipient_result",&ResultRecord {result:request.result.clone(),recipient_contact:actor.clone()},terminal).await?];
            if let Some(record)=&mut record {
                record.result=Some(request.result);
                changes.push(change(store,key,"mailbox",record,terminal).await?);
            }
            remember_contact(store,&actor,&mut changes).await?;
            Ok((logical_hash,changes))
        }
        RequestKind::IntroPublish => {
            let request: IntroPublishBody = serde_json::from_slice(body)?;
            // The caller's signed body binds session_id; an HTTP path cannot
            // relocate a signed bundle to another introduction session.
            let session_id = request.session_id;
            IntroSessionPublishRequest { version:1,owner_bundle:request.owner_bundle.clone() }.validate(&session_id,now.into(),&limits)?;
            let key = intro_key(&session_id);
            ensure!(store.object(&key).await?.is_none(), "ID_CONFLICT: intro session exists");
            let record = IntroRecord { session_id,owner_bundle:request.owner_bundle,responder_bundle:None };
            let mut changes=vec![change(store,key,"intro",&record,false).await?];
            remember_contact(store,&actor,&mut changes).await?;
            Ok((logical_hash,changes))
        }
        RequestKind::IntroRespond => {
            let request: IntroRespondBody = serde_json::from_slice(body)?;
            IntroSessionRespondRequest { version:1,responder_bundle:request.responder_bundle.clone() }.validate(&request.session_id,now.into(),&limits)?;
            let key = intro_key(&request.session_id);
            let object = store.object(&key).await?.ok_or_else(||anyhow::anyhow!("EXPIRED: intro missing"))?;
            let mut record: IntroRecord = serde_json::from_slice(&object.value)?;
            ensure!(record.owner_bundle.expires_at_unix_ms > now.into(), "EXPIRED: intro");
            ensure!(record.owner_bundle.contact.key_id != actor.key_id && record.responder_bundle.is_none(), "ID_CONFLICT: intro already answered");
            record.responder_bundle = Some(request.responder_bundle);
            let mut changes=vec![change(store,key,"intro",&record,false).await?];
            remember_contact(store,&actor,&mut changes).await?;
            Ok((logical_hash,changes))
        }
        _ => bail!("read request cannot prepare a mutation"),
    }
}

pub async fn verify_prepared(store: &V2Store, config: &ClusterConfigV2, operation: &PreparedOperation, now: u64) -> Result<()> {
    let auth: RequestAuth = serde_json::from_slice(&operation.authorization)?;
    ensure!(auth.actor_id == operation.actor_id && auth.operation_id == operation.operation_id
        && operation.cluster_id == config.cluster_id && operation.control_generation == config.control_generation.0
        && operation.config_epoch == config.config_epoch.0, "prepared scope mismatch");
    let (logical_hash, changes) = prepare_changes(store,config,&auth,&operation.request_body,&operation.attempt_id,now).await?;
    ensure!(operation.logical_hash == logical_hash && operation.changes == changes, "prepared business changes mismatch");
    Ok(())
}
