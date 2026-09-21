//! Transport-independent HA v2 protocol. These checks authenticate claims; they
//! do not replace the server's linearizable control-plane transaction/read barrier.
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use envelope_core::{Contact, decode_bytes, encode_bytes};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const HA_PROTOCOL_VERSION: u16 = 2;
pub const MAX_STATUS_LIFETIME_MS: u64 = 5_000;
pub const MAX_RECIPIENT_RESULT_BYTES: usize = 4 * 1024;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum HaError {
    #[error("invalid field {0}: {1}")]
    InvalidField(&'static str, String),
    #[error("unsupported protocol version")]
    UpgradeRequired,
    #[error("signature verification failed")]
    InvalidSignature,
    #[error("identity, content, operation or fixed expiry conflict")]
    IdConflict,
    #[error("state transition is not permitted")]
    InvalidTransition,
    #[error("configuration or leadership rollback")]
    Rollback,
    #[error("expired or not yet valid")]
    Expired,
}
pub type HaResult<T> = Result<T, HaError>;

/// Sequence numbers and UTC milliseconds are JSON strings on every platform.
/// Parsing rejects signs, leading zeroes, floats and integer overflow.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DecimalU64(pub u64);
impl Serialize for DecimalU64 {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0.to_string())
    }
}
impl<'de> Deserialize<'de> for DecimalU64 {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        if s.is_empty()
            || (s.len() > 1 && s.starts_with('0'))
            || !s.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(de::Error::custom(
                "expected canonical unsigned decimal string",
            ));
        }
        s.parse::<u64>().map(Self).map_err(de::Error::custom)
    }
}
impl From<u64> for DecimalU64 {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StorageState {
    LocalPending,
    StagedSingle,
    Replicated,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryState {
    Pending,
    Deferred,
    Delivered,
    Rejected,
    Expired,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecipientOutcome {
    Deferred,
    Delivered,
    Rejected,
}
impl From<RecipientOutcome> for DeliveryState {
    fn from(v: RecipientOutcome) -> Self {
        match v {
            RecipientOutcome::Deferred => Self::Deferred,
            RecipientOutcome::Delivered => Self::Delivered,
            RecipientOutcome::Rejected => Self::Rejected,
        }
    }
}
impl DeliveryState {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Delivered | Self::Rejected | Self::Expired)
    }
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NodeRole {
    Leader,
    Follower,
    Recovering,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ServiceMode {
    Normal,
    Degraded,
    Unavailable,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Discovering,
    ReadyNormal,
    ReadyDegraded,
    Suspect,
    NoQuorum,
    Recovering,
    UpgradeRequired,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BusinessNode {
    pub node_id: String,
    pub public_url: String,
    pub signing_public: String,
    pub node_incarnation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterConfigV2 {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    /// Exactly two business nodes, sorted by node_id; keys must be distinct.
    pub business_nodes: Vec<BusinessNode>,
    /// Three distinct voting member IDs, sorted. Q has no business endpoint.
    pub control_node_ids: Vec<String>,
    pub issued_at: DecimalU64,
    pub not_after: DecimalU64,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClusterStatus {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub node_id: String,
    pub node_incarnation: String,
    pub nonce: String,
    pub role: NodeRole,
    pub mode: ServiceMode,
    pub leader_node_id: Option<String>,
    pub leader_term: DecimalU64,
    pub applied_index: DecimalU64,
    pub commit_index: DecimalU64,
    pub ready: bool,
    pub reason_code: String,
    pub issued_at: DecimalU64,
    pub expires_at: DecimalU64,
    /// Sorted, distinct protocol capability names.
    pub capabilities: Vec<String>,
    pub node_signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PrepareAck {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub leader_term: DecimalU64,
    pub attempt_id: String,
    pub operation_id: String,
    pub actor_id: String,
    pub logical_hash: String,
    pub payload_hash: String,
    pub node_id: String,
    pub node_incarnation: String,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EnvelopeBinding {
    pub operation_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub envelope_id: String,
    pub envelope_sha256: String,
    pub not_after: DecimalU64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommitReceipt {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub leader_term: DecimalU64,
    pub commit_index: Option<DecimalU64>,
    pub operation_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub envelope_id: String,
    pub envelope_sha256: String,
    pub not_after: DecimalU64,
    pub storage_state: StorageState,
    pub delivery_state: DeliveryState,
    /// Sorted by node_id, with each nested ack's signature included in this signature.
    pub replica_evidence: Vec<PrepareAck>,
    /// Only present for staged_single; not a business commit index.
    pub staged_guard_revision: Option<DecimalU64>,
    pub node_id: String,
    /// Current signer scope; the original commit scope above never changes.
    pub issuer_control_generation: DecimalU64,
    pub issuer_config_epoch: DecimalU64,
    /// Archived administrator-signed configuration, only for a historic scope.
    pub proof_config: Option<ClusterConfigV2>,
    /// Separate quorum decision for expiration; StoreEnvelope evidence cannot
    /// authorize a transition to expired.
    #[serde(default)]
    pub expiry_evidence: Option<ExpiryEvidence>,
    pub node_signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ExpiryEvidence {
    pub operation_id: String,
    pub expected_object_version: DecimalU64,
    pub expired_at: DecimalU64,
    pub commit_index: DecimalU64,
    pub replica_evidence: Vec<PrepareAck>,
    pub proof_config: Option<ClusterConfigV2>,
}

impl ExpiryEvidence {
    fn canonical_value(&self) -> Value {
        let evidence: Vec<Value> = self
            .replica_evidence
            .iter()
            .map(|ack| json!([ack.canonical_value(), ack.signature]))
            .collect();
        let config = self
            .proof_config
            .as_ref()
            .map(|config| json!([config.canonical_value(), config.signature]));
        json!([
            self.operation_id,
            self.expected_object_version,
            self.expired_at,
            self.commit_index,
            evidence,
            config
        ])
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RecipientResult {
    pub version: u16,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub envelope_id: String,
    pub envelope_sha256: String,
    pub outcome: RecipientOutcome,
    pub reason_code: String,
    pub received_at: DecimalU64,
    pub result_id: String,
    pub result_sequence: DecimalU64,
    pub signature: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RequestKind {
    StoreEnvelope,
    PullMailbox,
    RecordResult,
    DeliveryStatus,
    RegisterRoute,
    LookupRoute,
    IntroPublish,
    IntroRespond,
    IntroLookup,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RequestAuth {
    pub protocol_version: u16,
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub actor_id: String,
    pub operation_id: String,
    pub nonce: String,
    pub requested_at: DecimalU64,
    pub request_kind: RequestKind,
    pub body_sha256: String,
    pub signature: String,
}
/// body_b64 is exact UTF-8 typed-request JSON bytes. Verify its digest before
/// parsing. A relay may not deserialize/reserialize it and keep the old signature.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SignedRequest {
    pub auth: RequestAuth,
    pub body_b64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct StoreEnvelopeBody {
    pub binding: EnvelopeBinding,
    pub sender_contact: Contact,
    pub envelope_b64: String,
    pub created_at: DecimalU64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RegisterRouteBody {
    pub owner_contact: Contact,
    pub endpoint: envelope_core::DeviceEndpointUpdate,
    pub expected_version: DecimalU64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PullMailboxBody {
    pub limit: u32,
    #[serde(default)]
    pub cursor: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RecordResultBody {
    pub result: RecipientResult,
    pub recipient_contact: Contact,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeliveryStatusBody {
    pub bindings: Vec<EnvelopeBinding>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LookupRouteBody {
    pub owner_key_id: String,
    pub device_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct IntroPublishBody {
    pub session_id: String,
    pub owner_bundle: envelope_core::EnvelopeIntroBundle,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct IntroRespondBody {
    pub session_id: String,
    pub responder_bundle: envelope_core::EnvelopeIntroBundle,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct IntroLookupBody {
    pub session_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct MailboxItemV2 {
    pub binding: EnvelopeBinding,
    pub envelope_b64: String,
    pub receipt: CommitReceipt,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PullMailboxResponseV2 {
    pub protocol_version: u16,
    pub items: Vec<MailboxItemV2>,
    pub next_cursor: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeliveryStatusItemV2 {
    pub binding: EnvelopeBinding,
    pub receipt: Option<CommitReceipt>,
    pub result: Option<RecipientResult>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeliveryStatusResponseV2 {
    pub protocol_version: u16,
    pub items: Vec<DeliveryStatusItemV2>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    NotLeader,
    NotReady,
    NoQuorum,
    ReplicaUnavailable,
    PayloadUnavailable,
    IdConflict,
    ObjectVersionConflict,
    AuthFailed,
    Expired,
    UpgradeRequired,
    RateLimited,
}
impl ErrorCode {
    pub fn http_status(self) -> u16 {
        match self {
            Self::NotLeader | Self::IdConflict | Self::ObjectVersionConflict => 409,
            Self::NotReady
            | Self::NoQuorum
            | Self::ReplicaUnavailable
            | Self::PayloadUnavailable => 503,
            Self::AuthFailed => 403,
            Self::Expired => 410,
            Self::UpgradeRequired => 426,
            Self::RateLimited => 429,
        }
    }
    pub fn permits_retry(self) -> bool {
        matches!(
            self,
            Self::NotLeader
                | Self::NotReady
                | Self::NoQuorum
                | Self::ReplicaUnavailable
                | Self::PayloadUnavailable
                | Self::RateLimited
        )
    }
}

/// Exact Ed25519 input: ASCII domain, one NUL, compact UTF-8 JSON array.
/// No existing v1 context prefix is used. Verification is strict Ed25519.
pub trait HaSigned {
    const KIND: &'static str;
    fn canonical_value(&self) -> Value;
    fn signature(&self) -> &str;
    fn signature_mut(&mut self) -> &mut String;
    fn canonical_payload(&self) -> HaResult<Vec<u8>> {
        serde_json::to_vec(&self.canonical_value())
            .map_err(|e| invalid("canonical_payload", &e.to_string()))
    }
    fn signing_bytes(&self) -> HaResult<Vec<u8>> {
        let mut bytes = format!("EnvelopeHA/V2/{}\0", Self::KIND).into_bytes();
        bytes.extend(self.canonical_payload()?);
        Ok(bytes)
    }
    fn sign(&mut self, signing_secret: &str) -> HaResult<()> {
        let seed = fixed_bytes::<32>("signing_secret", signing_secret)?;
        *self.signature_mut() = encode_bytes(
            &SigningKey::from_bytes(&seed)
                .sign(&self.signing_bytes()?)
                .to_bytes(),
        );
        Ok(())
    }
    fn verify_signature(&self, signing_public: &str) -> HaResult<()> {
        let key = VerifyingKey::from_bytes(&fixed_bytes::<32>("signing_public", signing_public)?)
            .map_err(|_| HaError::InvalidSignature)?;
        let sig = ed25519_dalek::Signature::from_bytes(&fixed_bytes::<64>(
            "signature",
            self.signature(),
        )?);
        key.verify_strict(&self.signing_bytes()?, &sig)
            .map_err(|_| HaError::InvalidSignature)
    }
}

impl HaSigned for ClusterConfigV2 {
    const KIND: &'static str = "ClusterConfig";
    fn canonical_value(&self) -> Value {
        let nodes: Vec<Value> = self
            .business_nodes
            .iter()
            .map(|n| {
                json!([
                    n.node_id,
                    n.public_url,
                    n.signing_public,
                    n.node_incarnation
                ])
            })
            .collect();
        json!([
            self.protocol_version,
            self.cluster_id,
            self.control_generation,
            self.config_epoch,
            nodes,
            self.control_node_ids,
            self.issued_at,
            self.not_after
        ])
    }
    fn signature(&self) -> &str {
        &self.signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.signature
    }
}
impl HaSigned for ClusterStatus {
    const KIND: &'static str = "ClusterStatus";
    fn canonical_value(&self) -> Value {
        json!([
            self.protocol_version,
            self.cluster_id,
            self.control_generation,
            self.config_epoch,
            self.node_id,
            self.node_incarnation,
            self.nonce,
            self.role,
            self.mode,
            self.leader_node_id,
            self.leader_term,
            self.applied_index,
            self.commit_index,
            self.ready,
            self.reason_code,
            self.issued_at,
            self.expires_at,
            self.capabilities
        ])
    }
    fn signature(&self) -> &str {
        &self.node_signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.node_signature
    }
}
impl HaSigned for PrepareAck {
    const KIND: &'static str = "PrepareAck";
    fn canonical_value(&self) -> Value {
        json!([
            self.protocol_version,
            self.cluster_id,
            self.control_generation,
            self.config_epoch,
            self.leader_term,
            self.attempt_id,
            self.operation_id,
            self.actor_id,
            self.logical_hash,
            self.payload_hash,
            self.node_id,
            self.node_incarnation
        ])
    }
    fn signature(&self) -> &str {
        &self.signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.signature
    }
}
impl HaSigned for CommitReceipt {
    const KIND: &'static str = "CommitReceipt";
    fn canonical_value(&self) -> Value {
        let evidence: Vec<Value> = self
            .replica_evidence
            .iter()
            .map(|a| json!([a.canonical_value(), a.signature]))
            .collect();
        let proof_config = self
            .proof_config
            .as_ref()
            .map(|config| json!([config.canonical_value(), config.signature]));
        json!([
            self.protocol_version,
            self.cluster_id,
            self.control_generation,
            self.config_epoch,
            self.leader_term,
            self.commit_index,
            self.operation_id,
            self.sender_key_id,
            self.recipient_key_id,
            self.envelope_id,
            self.envelope_sha256,
            self.not_after,
            self.storage_state,
            self.delivery_state,
            evidence,
            self.staged_guard_revision,
            self.node_id,
            self.issuer_control_generation,
            self.issuer_config_epoch,
            proof_config,
            self.expiry_evidence
                .as_ref()
                .map(ExpiryEvidence::canonical_value)
        ])
    }
    fn signature(&self) -> &str {
        &self.node_signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.node_signature
    }
}
impl HaSigned for RecipientResult {
    const KIND: &'static str = "RecipientResult";
    fn canonical_value(&self) -> Value {
        json!([
            self.version,
            self.sender_key_id,
            self.recipient_key_id,
            self.envelope_id,
            self.envelope_sha256,
            self.outcome,
            self.reason_code,
            self.received_at,
            self.result_id,
            self.result_sequence
        ])
    }
    fn signature(&self) -> &str {
        &self.signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.signature
    }
}
impl HaSigned for RequestAuth {
    const KIND: &'static str = "Request";
    fn canonical_value(&self) -> Value {
        json!([
            self.protocol_version,
            self.cluster_id,
            self.control_generation,
            self.config_epoch,
            self.actor_id,
            self.operation_id,
            self.nonce,
            self.requested_at,
            self.request_kind,
            self.body_sha256
        ])
    }
    fn signature(&self) -> &str {
        &self.signature
    }
    fn signature_mut(&mut self) -> &mut String {
        &mut self.signature
    }
}

pub fn sha256_b64(bytes: &[u8]) -> String {
    encode_bytes(&Sha256::digest(bytes))
}
pub fn expiry_actor(cluster_id: &str) -> String {
    format!("system:expiry:{cluster_id}")
}
pub fn expiry_logical_hash(
    operation_id: &str,
    binding: &EnvelopeBinding,
    expected_object_version: DecimalU64,
    expired_at: DecimalU64,
) -> HaResult<String> {
    token("expiry operation_id", operation_id)?;
    binding.validate()?;
    nonzero("expected_object_version", expected_object_version)?;
    if expired_at < binding.not_after {
        return Err(HaError::InvalidTransition);
    }
    let mut bytes = b"EnvelopeHA/V2/ExpireEnvelope\0".to_vec();
    bytes.extend(
        serde_json::to_vec(&json!([
            operation_id,
            [
                binding.operation_id,
                binding.sender_key_id,
                binding.recipient_key_id,
                binding.envelope_id,
                binding.envelope_sha256,
                binding.not_after
            ],
            expected_object_version,
            expired_at
        ]))
        .map_err(|e| invalid("expiry payload", &e.to_string()))?,
    );
    Ok(sha256_b64(&bytes))
}
fn invalid(field: &'static str, reason: &str) -> HaError {
    HaError::InvalidField(field, reason.into())
}
fn version(v: u16) -> HaResult<()> {
    if v == HA_PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(HaError::UpgradeRequired)
    }
}
fn nonzero(field: &'static str, value: DecimalU64) -> HaResult<()> {
    if value.0 > 0 {
        Ok(())
    } else {
        Err(invalid(field, "must be positive"))
    }
}
fn token(field: &'static str, value: &str) -> HaResult<()> {
    if value.is_empty()
        || value.len() > 256
        || value.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err(invalid(field, "expected 1..256 non-whitespace bytes"));
    }
    Ok(())
}
fn fixed_bytes<const N: usize>(field: &'static str, value: &str) -> HaResult<[u8; N]> {
    let bytes = decode_bytes(value, field).map_err(|_| invalid(field, "invalid base64url"))?;
    if encode_bytes(&bytes) != value {
        return Err(invalid(field, "noncanonical base64url"));
    }
    bytes
        .try_into()
        .map_err(|_| invalid(field, "incorrect decoded length"))
}
fn sorted_distinct<'a>(
    field: &'static str,
    values: impl IntoIterator<Item = &'a str>,
) -> HaResult<()> {
    let mut prior: Option<&str> = None;
    for value in values {
        token(field, value)?;
        if prior.is_some_and(|p| p >= value) {
            return Err(invalid(field, "must be strictly sorted and distinct"));
        }
        prior = Some(value);
    }
    Ok(())
}

impl ClusterConfigV2 {
    pub fn validate(&self) -> HaResult<()> {
        version(self.protocol_version)?;
        token("cluster_id", &self.cluster_id)?;
        nonzero("control_generation", self.control_generation)?;
        nonzero("config_epoch", self.config_epoch)?;
        if self.not_after <= self.issued_at {
            return Err(invalid("not_after", "must follow issued_at"));
        }
        if self.business_nodes.len() != 2 || self.control_node_ids.len() != 3 {
            return Err(invalid(
                "members",
                "require two business replicas and three control voters",
            ));
        }
        sorted_distinct(
            "business_nodes",
            self.business_nodes.iter().map(|n| n.node_id.as_str()),
        )?;
        sorted_distinct(
            "control_node_ids",
            self.control_node_ids.iter().map(String::as_str),
        )?;
        for node in &self.business_nodes {
            token("node_incarnation", &node.node_incarnation)?;
            fixed_bytes::<32>("signing_public", &node.signing_public)?;
            let url = url::Url::parse(&node.public_url)
                .map_err(|_| invalid("public_url", "invalid URL"))?;
            if url.scheme() != "https"
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.query().is_some()
                || url.fragment().is_some()
                || url.path() != "/"
            {
                return Err(invalid(
                    "public_url",
                    "expected HTTPS origin without credentials, query or fragment",
                ));
            }
            if !self.control_node_ids.contains(&node.node_id) {
                return Err(invalid(
                    "control_node_ids",
                    "business nodes must also be control voters",
                ));
            }
        }
        if self.business_nodes[0].signing_public == self.business_nodes[1].signing_public
            || url::Url::parse(&self.business_nodes[0].public_url).ok()
                == url::Url::parse(&self.business_nodes[1].public_url).ok()
        {
            return Err(invalid(
                "business_nodes",
                "distinct keys and HTTPS origins required",
            ));
        }
        Ok(())
    }
    /// The administrator key is supplied by the user's trust/bootstrap policy,
    /// never learned from this untrusted config document itself.
    pub fn verify(&self, administrator_public: &str, now_ms: u64) -> HaResult<()> {
        self.verify_archived(administrator_public)?;
        if now_ms < self.issued_at.0 || now_ms >= self.not_after.0 {
            return Err(HaError::Expired);
        }
        Ok(())
    }
    /// Historic durable evidence can outlive discovery/configuration TTL. This
    /// authenticates the archived config only; it cannot authorize a new leader
    /// or new write, and callers must constrain it to the current trusted scope.
    pub fn verify_archived(&self, administrator_public: &str) -> HaResult<()> {
        self.validate()?;
        self.verify_signature(administrator_public)
    }
    pub fn node(&self, node_id: &str) -> HaResult<&BusinessNode> {
        self.business_nodes
            .iter()
            .find(|n| n.node_id == node_id)
            .ok_or_else(|| invalid("node_id", "not an authorized business member"))
    }
    fn scope(&self, cluster: &str, generation: DecimalU64, epoch: DecimalU64) -> HaResult<()> {
        self.validate()?;
        if self.cluster_id != cluster
            || self.control_generation != generation
            || self.config_epoch != epoch
        {
            return Err(HaError::IdConflict);
        }
        Ok(())
    }
}

/// Persist together with the verified signed config; generation changes only
/// arrive through a fresh administrator-signed config, never node status alone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TrustWatermark {
    pub cluster_id: String,
    pub control_generation: DecimalU64,
    pub config_epoch: DecimalU64,
    pub leader_term: DecimalU64,
}
impl TrustWatermark {
    pub fn accept_config(
        &mut self,
        config: &ClusterConfigV2,
        administrator_public: &str,
        now_ms: u64,
    ) -> HaResult<()> {
        config.verify(administrator_public, now_ms)?;
        if config.cluster_id != self.cluster_id {
            return Err(HaError::IdConflict);
        }
        if config.control_generation < self.control_generation
            || config.config_epoch < self.config_epoch
        {
            return Err(HaError::Rollback);
        }
        if config.control_generation > self.control_generation {
            if config.config_epoch <= self.config_epoch {
                return Err(HaError::Rollback);
            }
            self.leader_term = DecimalU64(0);
        }
        self.control_generation = config.control_generation;
        self.config_epoch = config.config_epoch;
        Ok(())
    }
    pub fn accept_status(
        &mut self,
        status: &ClusterStatus,
        config: &ClusterConfigV2,
        nonce: &str,
        now_ms: u64,
        future_skew_ms: u64,
    ) -> HaResult<()> {
        status.verify(config, nonce, now_ms, future_skew_ms)?;
        if self.cluster_id != status.cluster_id
            || self.control_generation != status.control_generation
            || self.config_epoch != status.config_epoch
        {
            return Err(HaError::IdConflict);
        }
        if status.leader_term < self.leader_term {
            return Err(HaError::Rollback);
        }
        self.leader_term = status.leader_term;
        Ok(())
    }
}

impl ClusterStatus {
    /// Signature plus challenge/freshness/watermark consistency. Config must
    /// already be authenticated using the pinned administrator key.
    pub fn verify(
        &self,
        config: &ClusterConfigV2,
        expected_nonce: &str,
        now_ms: u64,
        future_skew_ms: u64,
    ) -> HaResult<()> {
        version(self.protocol_version)?;
        config.scope(&self.cluster_id, self.control_generation, self.config_epoch)?;
        let node = config.node(&self.node_id)?;
        if self.node_incarnation != node.node_incarnation {
            return Err(HaError::IdConflict);
        }
        token("nonce", &self.nonce)?;
        if self.nonce != expected_nonce {
            return Err(HaError::IdConflict);
        }
        if now_ms >= config.not_after.0 || now_ms < config.issued_at.0 {
            return Err(HaError::Expired);
        }
        if self.expires_at <= self.issued_at
            || self.expires_at.0 - self.issued_at.0 > MAX_STATUS_LIFETIME_MS
            || now_ms >= self.expires_at.0
            || self.issued_at.0 > now_ms.saturating_add(future_skew_ms)
        {
            return Err(HaError::Expired);
        }
        if self.applied_index > self.commit_index {
            return Err(invalid("applied_index", "cannot exceed control head"));
        }
        if let Some(leader) = &self.leader_node_id {
            config.node(leader)?;
            nonzero("leader_term", self.leader_term)?;
        }
        if self.ready {
            if self.role != NodeRole::Leader
                || self.leader_node_id.as_deref() != Some(self.node_id.as_str())
                || self.mode == ServiceMode::Unavailable
                || self.applied_index != self.commit_index
            {
                return Err(invalid(
                    "ready",
                    "requires current leader with applied control head",
                ));
            }
        } else if self.mode != ServiceMode::Unavailable {
            return Err(invalid("mode", "nonready status must be unavailable"));
        }
        if self.role == NodeRole::Leader
            && self.leader_node_id.as_deref() != Some(self.node_id.as_str())
        {
            return Err(invalid("role", "leader identity mismatch"));
        }
        if self.reason_code.len() > 128 {
            return Err(invalid("reason_code", "too long"));
        }
        if self.capabilities.len() > 32 {
            return Err(invalid("capabilities", "too many capabilities"));
        }
        sorted_distinct("capabilities", self.capabilities.iter().map(String::as_str))?;
        self.verify_signature(&node.signing_public)
    }
}

impl EnvelopeBinding {
    pub fn validate(&self) -> HaResult<()> {
        token("operation_id", &self.operation_id)?;
        token("sender_key_id", &self.sender_key_id)?;
        token("recipient_key_id", &self.recipient_key_id)?;
        token("envelope_id", &self.envelope_id)?;
        fixed_bytes::<32>("envelope_sha256", &self.envelope_sha256)?;
        nonzero("not_after", self.not_after)
    }
    /// Immutable StoreEnvelope command identity; request timestamps/signatures
    /// and replication attempt IDs deliberately do not change it.
    pub fn logical_hash(&self) -> HaResult<String> {
        self.validate()?;
        let mut bytes = b"EnvelopeHA/V2/StoreEnvelope\0".to_vec();
        bytes.extend(
            serde_json::to_vec(&json!([
                self.operation_id,
                self.sender_key_id,
                self.recipient_key_id,
                self.envelope_id,
                self.envelope_sha256,
                self.not_after
            ]))
            .map_err(|e| invalid("binding", &e.to_string()))?,
        );
        Ok(sha256_b64(&bytes))
    }
    /// Length-tagged UTF-8 components avoid ambiguous concatenated keys.
    pub fn object_key(&self) -> HaResult<String> {
        self.validate()?;
        let mut bytes = b"EnvelopeHA/V2/ObjectKey\0envelope\0".to_vec();
        for s in [
            &self.sender_key_id,
            &self.recipient_key_id,
            &self.envelope_id,
        ] {
            bytes.extend((s.len() as u32).to_be_bytes());
            bytes.extend(s.as_bytes());
        }
        Ok(sha256_b64(&bytes))
    }
    pub fn check_retry(&self, retry: &Self) -> HaResult<()> {
        self.validate()?;
        retry.validate()?;
        if self != retry {
            return Err(HaError::IdConflict);
        }
        Ok(())
    }
}

impl PrepareAck {
    pub fn verify(&self, config: &ClusterConfigV2) -> HaResult<()> {
        version(self.protocol_version)?;
        config.scope(&self.cluster_id, self.control_generation, self.config_epoch)?;
        nonzero("leader_term", self.leader_term)?;
        token("attempt_id", &self.attempt_id)?;
        token("operation_id", &self.operation_id)?;
        token("actor_id", &self.actor_id)?;
        fixed_bytes::<32>("logical_hash", &self.logical_hash)?;
        fixed_bytes::<32>("payload_hash", &self.payload_hash)?;
        let node = config.node(&self.node_id)?;
        if self.node_incarnation != node.node_incarnation {
            return Err(HaError::IdConflict);
        }
        self.verify_signature(&node.signing_public)
    }
}

impl CommitReceipt {
    pub fn binding(&self) -> EnvelopeBinding {
        EnvelopeBinding {
            operation_id: self.operation_id.clone(),
            sender_key_id: self.sender_key_id.clone(),
            recipient_key_id: self.recipient_key_id.clone(),
            envelope_id: self.envelope_id.clone(),
            envelope_sha256: self.envelope_sha256.clone(),
            not_after: self.not_after,
        }
    }
    /// Verifies managed-cluster storage evidence, not recipient delivery or
    /// current leadership. Historic receipts remain verifiable with their saved
    /// authenticated configuration after its discovery validity expires.
    pub fn verify(&self, config: &ClusterConfigV2, expected: &EnvelopeBinding) -> HaResult<()> {
        if self.proof_config.is_some() {
            return Err(invalid(
                "proof_config",
                "historical evidence requires administrator-key verification",
            ));
        }
        self.verify_scopes(config, config, expected, None)
    }
    /// Verify an old commit after a data-node key/incarnation/config rotation.
    /// The current signer attests the original decision; archived replica keys
    /// come only from an independently administrator-authenticated config.
    pub fn verify_with_history(
        &self,
        current: &ClusterConfigV2,
        administrator_public: &str,
        expected: &EnvelopeBinding,
    ) -> HaResult<()> {
        current.verify_archived(administrator_public)?;
        if let Some(archived) = &self.proof_config {
            archived.verify_archived(administrator_public)?;
            if archived.control_generation > current.control_generation
                || archived.config_epoch > current.config_epoch
            {
                return Err(HaError::Rollback);
            }
            if archived.control_generation == current.control_generation
                && archived.config_epoch == current.config_epoch
            {
                return Err(invalid(
                    "proof_config",
                    "same-scope proof must use current authenticated configuration",
                ));
            }
            self.verify_scopes(current, archived, expected, Some(administrator_public))
        } else {
            self.verify_scopes(current, current, expected, Some(administrator_public))
        }
    }
    fn verify_scopes(
        &self,
        issuer_config: &ClusterConfigV2,
        proof_config: &ClusterConfigV2,
        expected: &EnvelopeBinding,
        administrator_public: Option<&str>,
    ) -> HaResult<()> {
        version(self.protocol_version)?;
        proof_config.scope(&self.cluster_id, self.control_generation, self.config_epoch)?;
        issuer_config.scope(
            &self.cluster_id,
            self.issuer_control_generation,
            self.issuer_config_epoch,
        )?;
        nonzero("leader_term", self.leader_term)?;
        self.binding().check_retry(expected)?;
        let count = match self.storage_state {
            StorageState::Replicated => {
                if self.commit_index.is_none_or(|i| i.0 == 0)
                    || self.staged_guard_revision.is_some()
                {
                    return Err(invalid(
                        "commit_index",
                        "replicated requires business commit and no staged guard",
                    ));
                }
                2
            }
            StorageState::StagedSingle => {
                if self.commit_index.is_some()
                    || self.staged_guard_revision.is_none_or(|i| i.0 == 0)
                {
                    return Err(invalid(
                        "staged_guard_revision",
                        "staged requires guard without business commit",
                    ));
                }
                1
            }
            StorageState::LocalPending => {
                return Err(invalid(
                    "storage_state",
                    "local pending has no server storage proof",
                ));
            }
        };
        if self.replica_evidence.len() != count {
            return Err(invalid(
                "replica_evidence",
                "wrong number of distinct durable replicas",
            ));
        }
        sorted_distinct(
            "replica_evidence",
            self.replica_evidence.iter().map(|a| a.node_id.as_str()),
        )?;
        let first = &self.replica_evidence[0];
        let logical_hash = expected.logical_hash()?;
        for ack in &self.replica_evidence {
            ack.verify(proof_config)?;
            if ack.leader_term != self.leader_term
                || ack.operation_id != self.operation_id
                || ack.actor_id != self.sender_key_id
                || ack.logical_hash != logical_hash
                || ack.attempt_id != first.attempt_id
                || ack.payload_hash != first.payload_hash
            {
                return Err(HaError::IdConflict);
            }
        }
        if self.storage_state == StorageState::Replicated
            && self.proof_config.is_none()
            && !self
                .replica_evidence
                .iter()
                .any(|a| a.node_id == self.node_id)
        {
            return Err(invalid(
                "node_id",
                "issuer must be one of the durable replicas",
            ));
        }
        self.verify_expiry(issuer_config, proof_config, expected, administrator_public)?;
        self.verify_signature(&issuer_config.node(&self.node_id)?.signing_public)
    }

    fn verify_expiry(
        &self,
        current: &ClusterConfigV2,
        storage_config: &ClusterConfigV2,
        binding: &EnvelopeBinding,
        administrator_public: Option<&str>,
    ) -> HaResult<()> {
        let Some(expiry) = &self.expiry_evidence else {
            return if self.delivery_state == DeliveryState::Expired {
                Err(invalid(
                    "expiry_evidence",
                    "expired requires a separate quorum decision",
                ))
            } else {
                Ok(())
            };
        };
        if self.delivery_state != DeliveryState::Expired
            || self.storage_state != StorageState::Replicated
        {
            return Err(invalid(
                "expiry_evidence",
                "only a replicated expired receipt carries expiration evidence",
            ));
        }
        if expiry.replica_evidence.len() != 2 {
            return Err(invalid(
                "expiry_evidence",
                "expiration requires two distinct durable replicas",
            ));
        }
        sorted_distinct(
            "expiry_evidence",
            expiry.replica_evidence.iter().map(|a| a.node_id.as_str()),
        )?;
        let first = &expiry.replica_evidence[0];
        // Generation restoration is an explicit migration; a decision from a
        // different log cannot order this object's expiration.
        if first.control_generation != self.control_generation
            || first.config_epoch < self.config_epoch
            || first.leader_term < self.leader_term
            || Some(expiry.commit_index) <= self.commit_index
        {
            return Err(HaError::Rollback);
        }
        let proof_config = if let Some(archive) = &expiry.proof_config {
            let admin = administrator_public.ok_or_else(|| {
                invalid(
                    "expiry_evidence.proof_config",
                    "historical evidence requires administrator-key verification",
                )
            })?;
            archive.verify_archived(admin)?;
            if archive.control_generation > current.control_generation
                || archive.config_epoch >= current.config_epoch
            {
                return Err(HaError::Rollback);
            }
            archive
        } else if first.control_generation == current.control_generation
            && first.config_epoch == current.config_epoch
        {
            current
        } else if first.control_generation == storage_config.control_generation
            && first.config_epoch == storage_config.config_epoch
        {
            storage_config
        } else {
            return Err(invalid(
                "expiry_evidence.proof_config",
                "missing authenticated expiration configuration",
            ));
        };
        proof_config.scope(
            &self.cluster_id,
            first.control_generation,
            first.config_epoch,
        )?;
        let expected_hash = expiry_logical_hash(
            &expiry.operation_id,
            binding,
            expiry.expected_object_version,
            expiry.expired_at,
        )?;
        let actor = expiry_actor(&self.cluster_id);
        for ack in &expiry.replica_evidence {
            ack.verify(proof_config)?;
            if ack.operation_id != expiry.operation_id
                || ack.actor_id != actor
                || ack.logical_hash != expected_hash
                || ack.leader_term != first.leader_term
                || ack.attempt_id != first.attempt_id
                || ack.payload_hash != first.payload_hash
            {
                return Err(HaError::IdConflict);
            }
        }
        Ok(())
    }
}

impl RecipientResult {
    pub fn validate(&self) -> HaResult<()> {
        version(self.version)?;
        for (field, value) in [
            ("sender_key_id", &self.sender_key_id),
            ("recipient_key_id", &self.recipient_key_id),
            ("envelope_id", &self.envelope_id),
            ("result_id", &self.result_id),
        ] {
            token(field, value)?;
        }
        fixed_bytes::<32>("envelope_sha256", &self.envelope_sha256)?;
        nonzero("received_at", self.received_at)?;
        nonzero("result_sequence", self.result_sequence)?;
        if self.reason_code.len() > 64
            || !self
                .reason_code
                .bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_')
            || (self.outcome != RecipientOutcome::Delivered && self.reason_code.is_empty())
        {
            return Err(invalid(
                "reason_code",
                "expected bounded uppercase code for deferred/rejected",
            ));
        }
        if serde_json::to_vec(self)
            .map_err(|e| invalid("result", &e.to_string()))?
            .len()
            > MAX_RECIPIENT_RESULT_BYTES
        {
            return Err(invalid("result", "exceeds 4 KiB"));
        }
        Ok(())
    }
    pub fn verify(&self, recipient: &Contact, binding: &EnvelopeBinding) -> HaResult<()> {
        self.validate()?;
        binding.validate()?;
        recipient
            .validate()
            .map_err(|_| invalid("contact", "invalid contact identity"))?;
        if self.recipient_key_id != recipient.key_id
            || self.sender_key_id != binding.sender_key_id
            || self.recipient_key_id != binding.recipient_key_id
            || self.envelope_id != binding.envelope_id
            || self.envelope_sha256 != binding.envelope_sha256
        {
            return Err(HaError::IdConflict);
        }
        self.verify_signature(&recipient.signing_public)
    }
}

impl RequestAuth {
    pub fn verify(
        &self,
        actor: &Contact,
        config: &ClusterConfigV2,
        kind: RequestKind,
        body: &[u8],
        now_ms: u64,
        max_clock_skew_ms: u64,
    ) -> HaResult<()> {
        version(self.protocol_version)?;
        config.scope(&self.cluster_id, self.control_generation, self.config_epoch)?;
        actor
            .validate()
            .map_err(|_| invalid("contact", "invalid contact identity"))?;
        token("operation_id", &self.operation_id)?;
        token("nonce", &self.nonce)?;
        if self.actor_id != actor.key_id
            || self.request_kind != kind
            || sha256_b64(body) != self.body_sha256
        {
            return Err(HaError::IdConflict);
        }
        if now_ms.abs_diff(self.requested_at.0) > max_clock_skew_ms {
            return Err(HaError::Expired);
        }
        self.verify_signature(&actor.signing_public)
    }
}
impl SignedRequest {
    pub fn decoded_body(&self, max_bytes: usize) -> HaResult<Vec<u8>> {
        // Bound before decoding as well as after to prevent unbounded allocation.
        if self.body_b64.len()
            > max_bytes
                .saturating_mul(4)
                .saturating_div(3)
                .saturating_add(4)
        {
            return Err(invalid("body_b64", "body limit exceeded"));
        }
        let bytes = decode_bytes(&self.body_b64, "body_b64")
            .map_err(|_| invalid("body_b64", "invalid base64url"))?;
        if bytes.len() > max_bytes || encode_bytes(&bytes) != self.body_b64 {
            return Err(invalid("body_b64", "noncanonical or oversized body"));
        }
        if sha256_b64(&bytes) != self.auth.body_sha256 {
            return Err(HaError::IdConflict);
        }
        Ok(bytes)
    }
}

impl StoreEnvelopeBody {
    pub fn validate(
        &self,
        max_envelope_bytes: usize,
        max_ttl_ms: u64,
        now_ms: u64,
        future_skew_ms: u64,
    ) -> HaResult<Vec<u8>> {
        self.binding.validate()?;
        self.sender_contact
            .validate()
            .map_err(|_| invalid("sender_contact", "invalid contact identity"))?;
        if self.sender_contact.key_id != self.binding.sender_key_id {
            return Err(HaError::IdConflict);
        }
        if self.created_at.0 > now_ms.saturating_add(future_skew_ms)
            || self.binding.not_after <= self.created_at
            || self.binding.not_after.0 - self.created_at.0 > max_ttl_ms
            || now_ms >= self.binding.not_after.0
        {
            return Err(HaError::Expired);
        }
        if self.envelope_b64.len()
            > max_envelope_bytes
                .saturating_mul(4)
                .saturating_div(3)
                .saturating_add(4)
        {
            return Err(invalid("envelope_b64", "body limit exceeded"));
        }
        let bytes = decode_bytes(&self.envelope_b64, "envelope_b64")
            .map_err(|_| invalid("envelope_b64", "invalid base64url"))?;
        if encode_bytes(&bytes) != self.envelope_b64
            || bytes.len() <= envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES
            || bytes.len() > max_envelope_bytes
        {
            return Err(invalid("envelope_b64", "invalid size or encoding"));
        }
        if sha256_b64(&bytes) != self.binding.envelope_sha256 {
            return Err(HaError::IdConflict);
        }
        Ok(bytes)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct MessageState {
    pub storage_state: StorageState,
    pub delivery_state: DeliveryState,
    pub last_result: Option<RecipientResult>,
}
impl Default for MessageState {
    fn default() -> Self {
        Self {
            storage_state: StorageState::LocalPending,
            delivery_state: DeliveryState::Pending,
            last_result: None,
        }
    }
}
impl MessageState {
    /// A receipt never by itself upgrades delivery to delivered. A server
    /// signature cannot stand in for the recipient's end-to-end signature.
    pub fn apply_storage_proof(
        &mut self,
        receipt: &CommitReceipt,
        config: &ClusterConfigV2,
        binding: &EnvelopeBinding,
    ) -> HaResult<()> {
        receipt.verify(config, binding)?;
        self.advance_storage(receipt.storage_state);
        Ok(())
    }
    pub fn apply_storage_proof_with_history(
        &mut self,
        receipt: &CommitReceipt,
        current: &ClusterConfigV2,
        administrator_public: &str,
        binding: &EnvelopeBinding,
    ) -> HaResult<()> {
        receipt.verify_with_history(current, administrator_public, binding)?;
        self.advance_storage(receipt.storage_state);
        Ok(())
    }
    fn advance_storage(&mut self, next: StorageState) {
        match (self.storage_state, next) {
            (StorageState::Replicated, _)
            | (StorageState::StagedSingle, StorageState::LocalPending) => {}
            (_, next) => self.storage_state = next,
        }
    }
    pub fn apply_recipient_result(
        &mut self,
        result: &RecipientResult,
        recipient: &Contact,
        binding: &EnvelopeBinding,
    ) -> HaResult<bool> {
        result.verify(recipient, binding)?;
        if let Some(previous) = &self.last_result {
            if result.result_id == previous.result_id
                || result.result_sequence == previous.result_sequence
            {
                if result == previous {
                    return Ok(false);
                }
                return Err(HaError::IdConflict);
            }
            if result.result_sequence < previous.result_sequence {
                return Err(HaError::Rollback);
            }
        }
        let next: DeliveryState = result.outcome.into();
        match self.delivery_state {
            DeliveryState::Pending | DeliveryState::Deferred => {}
            DeliveryState::Expired
                if next == DeliveryState::Delivered && result.received_at < binding.not_after => {}
            _ => return Err(HaError::InvalidTransition),
        }
        self.last_result = Some(result.clone());
        self.delivery_state = next;
        Ok(true)
    }
    pub fn apply_expiry(
        &mut self,
        receipt: &CommitReceipt,
        config: &ClusterConfigV2,
        binding: &EnvelopeBinding,
        now_ms: u64,
    ) -> HaResult<()> {
        receipt.verify(config, binding)?;
        if receipt.storage_state != StorageState::Replicated
            || receipt.delivery_state != DeliveryState::Expired
            || now_ms < binding.not_after.0
            || matches!(
                self.delivery_state,
                DeliveryState::Delivered | DeliveryState::Rejected
            )
        {
            return Err(HaError::InvalidTransition);
        }
        self.delivery_state = DeliveryState::Expired;
        self.storage_state = StorageState::Replicated;
        Ok(())
    }
    /// First release retains even replicated pending bodies until terminal
    /// delivery or their original fixed deadline.
    pub fn retain_outbox(&self, binding: &EnvelopeBinding, now_ms: u64) -> bool {
        !self.delivery_state.is_terminal() && now_ms < binding.not_after.0
    }
}

#[cfg(test)]
#[path = "ha_tests.rs"]
mod tests;
