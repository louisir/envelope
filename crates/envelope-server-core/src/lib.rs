use anyhow::{Context, Result};
use envelope_core::{
    Contact, DeviceEndpointUpdate, ENVELOPE_PROTOCOL_VERSION, EnvelopeIntroBundle, Identity,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

pub const SERVER_PROTOCOL_VERSION: u16 = 1;
pub const STATUS_OK: &str = "ok";
pub const ENVELOPE_SUBMIT_SIGNATURE_CONTEXT: &str = "envelope server envelope submit v1";
pub const MAILBOX_PULL_SIGNATURE_CONTEXT: &str = "envelope server mailbox pull v1";
pub const MAILBOX_ACK_SIGNATURE_CONTEXT: &str = "envelope server mailbox ack v1";
pub const DELIVERY_STATUS_SIGNATURE_CONTEXT: &str = "envelope server delivery status v1";
pub const NODE_SET_MANIFEST_SIGNATURE_CONTEXT: &str = "envelope server node set manifest v1";
pub const NODE_CHALLENGE_SIGNATURE_CONTEXT: &str = "envelope server node challenge v1";

pub const DEFAULT_MAX_ENVELOPE_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_MAX_MAILBOX_ENVELOPES: usize = 1000;
pub const DEFAULT_MAX_MAILBOX_BYTES: usize = 256 * 1024 * 1024;
pub const DEFAULT_MAX_GLOBAL_MAILBOX_BYTES: usize = 1024 * 1024 * 1024;
pub const DEFAULT_MAX_ENDPOINT_TTL_SECONDS: u64 = 24 * 60 * 60;
pub const DEFAULT_ENVELOPE_TTL_SECONDS: u64 = 7 * 24 * 60 * 60;
pub const DEFAULT_MAX_ACK_ENVELOPE_IDS: usize = 100;
pub const DEFAULT_MAX_P2P_TICKET_BYTES: usize = 16 * 1024;
pub const DEFAULT_MAX_CONTROL_CLOCK_SKEW_MS: u128 = 5 * 60 * 1000;
pub const DEFAULT_MAX_INTRO_SESSION_TTL_SECONDS: u64 = 10 * 60;
pub const DEFAULT_MAX_INTRO_BUNDLE_BYTES: usize = 64 * 1024;
pub const DEFAULT_MAX_SUBMIT_PER_SENDER_PER_MINUTE: u32 = 60;
pub const DEFAULT_MAX_SUBMIT_PER_IP_PER_MINUTE: u32 = 120;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AntiAbuseLimits {
    pub max_envelope_bytes: usize,
    pub max_mailbox_envelopes: usize,
    pub max_mailbox_bytes: usize,
    pub max_global_mailbox_bytes: usize,
    pub max_endpoint_ttl_seconds: u64,
    pub default_envelope_ttl_seconds: u64,
    pub max_ack_envelope_ids: usize,
    pub max_p2p_ticket_bytes: usize,
    pub max_control_clock_skew_ms: u128,
    pub max_intro_session_ttl_seconds: u64,
    pub max_intro_bundle_bytes: usize,
    pub max_submit_per_sender_per_minute: u32,
    pub max_submit_per_ip_per_minute: u32,
}

impl Default for AntiAbuseLimits {
    fn default() -> Self {
        Self {
            max_envelope_bytes: DEFAULT_MAX_ENVELOPE_BYTES,
            max_mailbox_envelopes: DEFAULT_MAX_MAILBOX_ENVELOPES,
            max_mailbox_bytes: DEFAULT_MAX_MAILBOX_BYTES,
            max_global_mailbox_bytes: DEFAULT_MAX_GLOBAL_MAILBOX_BYTES,
            max_endpoint_ttl_seconds: DEFAULT_MAX_ENDPOINT_TTL_SECONDS,
            default_envelope_ttl_seconds: DEFAULT_ENVELOPE_TTL_SECONDS,
            max_ack_envelope_ids: DEFAULT_MAX_ACK_ENVELOPE_IDS,
            max_p2p_ticket_bytes: DEFAULT_MAX_P2P_TICKET_BYTES,
            max_control_clock_skew_ms: DEFAULT_MAX_CONTROL_CLOCK_SKEW_MS,
            max_intro_session_ttl_seconds: DEFAULT_MAX_INTRO_SESSION_TTL_SECONDS,
            max_intro_bundle_bytes: DEFAULT_MAX_INTRO_BUNDLE_BYTES,
            max_submit_per_sender_per_minute: DEFAULT_MAX_SUBMIT_PER_SENDER_PER_MINUTE,
            max_submit_per_ip_per_minute: DEFAULT_MAX_SUBMIT_PER_IP_PER_MINUTE,
        }
    }
}

#[derive(Debug, Error)]
pub enum ServerCoreError {
    #[error("invalid field {field}: {detail}")]
    InvalidField { field: &'static str, detail: String },
    #[error("invalid signature: {0}")]
    InvalidSignature(String),
    #[error("invalid envelope: {0}")]
    InvalidEnvelope(String),
    #[error("mailbox limit exceeded: {0}")]
    MailboxLimitExceeded(String),
}

pub type CoreResult<T> = std::result::Result<T, ServerCoreError>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRegistrationRequest {
    pub version: u16,
    pub owner_contact: Contact,
    pub endpoint: DeviceEndpointUpdate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRegistrationResponse {
    pub version: u16,
    pub status: String,
    pub owner_identity_key_id: String,
    pub device_id: String,
    pub expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RouteLookupResponse {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub device_id: String,
    pub endpoint: Option<DeviceEndpointUpdate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvelopeSubmitRequest {
    pub version: u16,
    pub envelope_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub envelope_b64: String,
    pub envelope_sha256: String,
    pub envelope_len: u64,
    pub ttl_seconds: Option<u64>,
    pub submitted_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvelopeSubmitResponse {
    pub version: u16,
    pub status: String,
    pub envelope_id: String,
    pub stored_until_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailboxEnvelope {
    pub envelope_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub envelope_b64: String,
    pub received_at_unix_ms: u128,
    pub expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailboxPullRequest {
    pub version: u16,
    pub recipient_key_id: String,
    pub limit: Option<u32>,
    pub requested_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailboxPullResponse {
    pub version: u16,
    pub recipient_key_id: String,
    pub envelopes: Vec<MailboxEnvelope>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailboxAckRequest {
    pub version: u16,
    pub recipient_key_id: String,
    pub envelope_ids: Vec<String>,
    pub acked_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MailboxAckResponse {
    pub version: u16,
    pub status: String,
    pub deleted_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryStatusRequest {
    pub version: u16,
    pub sender_key_id: String,
    pub envelope_ids: Vec<String>,
    pub requested_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryStatusItem {
    pub envelope_id: String,
    pub recipient_key_id: Option<String>,
    pub status: String,
    pub delivered_at_unix_ms: Option<u128>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeliveryStatusResponse {
    pub version: u16,
    pub sender_key_id: String,
    pub items: Vec<DeliveryStatusItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IntroSessionPublishRequest {
    pub version: u16,
    pub owner_bundle: EnvelopeIntroBundle,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IntroSessionPublishResponse {
    pub version: u16,
    pub status: String,
    pub session_id: String,
    pub owner_key_id: String,
    pub expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IntroSessionRespondRequest {
    pub version: u16,
    pub responder_bundle: EnvelopeIntroBundle,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IntroSessionRespondResponse {
    pub version: u16,
    pub status: String,
    pub session_id: String,
    pub responder_key_id: String,
    pub expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IntroSessionPollResponse {
    pub version: u16,
    pub session_id: String,
    pub owner_key_id: String,
    pub responder_bundle: Option<EnvelopeIntroBundle>,
    pub updated_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodeSetManifest {
    pub version: u16,
    pub manifest_id: String,
    pub epoch: u64,
    pub valid_from_unix_ms: u128,
    pub valid_until_unix_ms: u128,
    pub prev_manifest_hash: Option<String>,
    pub nodes: Vec<NodeDescriptor>,
    pub revoked_node_ids: Vec<String>,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodeDescriptor {
    pub node_id: String,
    pub base_url: String,
    pub public_key: String,
    pub capabilities: Vec<String>,
    pub weight: u32,
    pub region: Option<String>,
    pub valid_until_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodeChallengeRequest {
    pub version: u16,
    pub node_id: String,
    pub challenge_b64: String,
    pub requested_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NodeChallengeResponse {
    pub version: u16,
    pub status: String,
    pub node_id: String,
    pub challenge_b64: String,
    pub requested_at_unix_ms: u128,
    pub signed_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize)]
struct MailboxAckSigningPayload<'a> {
    version: u16,
    recipient_key_id: &'a str,
    envelope_ids: &'a [String],
    acked_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
struct MailboxPullSigningPayload<'a> {
    version: u16,
    recipient_key_id: &'a str,
    limit: Option<u32>,
    requested_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
struct DeliveryStatusSigningPayload<'a> {
    version: u16,
    sender_key_id: &'a str,
    envelope_ids: &'a [String],
    requested_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
struct EnvelopeSubmitSigningPayload<'a> {
    version: u16,
    envelope_id: &'a str,
    sender_key_id: &'a str,
    recipient_key_id: &'a str,
    envelope_sha256: &'a str,
    envelope_len: u64,
    ttl_seconds: Option<u64>,
    submitted_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize)]
struct NodeSetManifestSigningPayload<'a> {
    version: u16,
    manifest_id: &'a str,
    epoch: u64,
    valid_from_unix_ms: u128,
    valid_until_unix_ms: u128,
    prev_manifest_hash: &'a Option<String>,
    nodes: &'a [NodeDescriptor],
    revoked_node_ids: &'a [String],
}

#[derive(Debug, Clone, Serialize)]
struct NodeChallengeSigningPayload<'a> {
    version: u16,
    node_id: &'a str,
    challenge_b64: &'a str,
    requested_at_unix_ms: u128,
    signed_at_unix_ms: u128,
}

impl DeviceRegistrationRequest {
    pub fn validate(&self, now_unix_ms: u128, limits: &AntiAbuseLimits) -> CoreResult<()> {
        validate_version(self.version, "registration version")?;
        validate_contact(&self.owner_contact)?;
        if self.endpoint.owner_identity_key_id != self.owner_contact.key_id {
            return Err(ServerCoreError::InvalidField {
                field: "endpoint.owner_identity_key_id",
                detail: "must match owner_contact.key_id".to_string(),
            });
        }
        validate_key_id(
            "endpoint.owner_identity_key_id",
            &self.endpoint.owner_identity_key_id,
        )?;
        validate_bounded_string("endpoint.device_id", &self.endpoint.device_id, 1, 128)?;
        validate_bounded_string("endpoint.session_id", &self.endpoint.session_id, 1, 128)?;
        validate_bounded_string(
            "endpoint.p2p_ticket",
            &self.endpoint.p2p_ticket,
            1,
            limits.max_p2p_ticket_bytes,
        )?;
        validate_endpoint_ttl(&self.endpoint, now_unix_ms, limits)?;
        envelope_core::verify_device_endpoint_update_at(
            &self.owner_contact,
            &self.endpoint,
            now_unix_ms,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        Ok(())
    }

    pub fn accepted_response(&self) -> DeviceRegistrationResponse {
        DeviceRegistrationResponse {
            version: SERVER_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            owner_identity_key_id: self.endpoint.owner_identity_key_id.clone(),
            device_id: self.endpoint.device_id.clone(),
            expires_at_unix_ms: self.endpoint.expires_at_unix_ms,
        }
    }
}

impl EnvelopeSubmitRequest {
    pub fn create(
        identity: &Identity,
        recipient_key_id: impl Into<String>,
        envelope_id: impl Into<String>,
        envelope_b64: impl Into<String>,
        ttl_seconds: Option<u64>,
        submitted_at_unix_ms: u128,
    ) -> Result<Self> {
        let envelope_b64 = envelope_b64.into();
        let envelope_bytes = envelope_core::decode_bytes(&envelope_b64, "envelope_b64")?;
        let envelope_len =
            u64::try_from(envelope_bytes.len()).context("envelope length does not fit u64")?;
        let mut request = Self {
            version: SERVER_PROTOCOL_VERSION,
            envelope_id: envelope_id.into(),
            sender_key_id: identity.public.key_id.clone(),
            recipient_key_id: recipient_key_id.into(),
            envelope_b64,
            envelope_sha256: envelope_core::sha256_hex(&envelope_bytes),
            envelope_len,
            ttl_seconds,
            submitted_at_unix_ms,
            signature: String::new(),
        };
        let payload = envelope_submit_signature_payload(&request)?;
        request.signature = envelope_core::sign_context_payload(
            identity,
            ENVELOPE_SUBMIT_SIGNATURE_CONTEXT,
            &payload,
        )?;
        Ok(request)
    }

    pub fn envelope_bytes(&self, limits: &AntiAbuseLimits) -> CoreResult<Vec<u8>> {
        validate_version(self.version, "envelope submit version")?;
        validate_envelope_id(&self.envelope_id)?;
        validate_key_id("sender_key_id", &self.sender_key_id)?;
        validate_key_id("recipient_key_id", &self.recipient_key_id)?;
        validate_bounded_string("envelope_sha256", &self.envelope_sha256, 64, 64)?;
        if !self
            .envelope_sha256
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
        {
            return Err(ServerCoreError::InvalidField {
                field: "envelope_sha256",
                detail: "must be lowercase SHA-256 hex".to_string(),
            });
        }
        validate_bounded_string("signature", &self.signature, 1, 256)?;
        let bytes = envelope_core::decode_bytes(&self.envelope_b64, "envelope_b64")
            .map_err(|error| ServerCoreError::InvalidEnvelope(error.to_string()))?;
        if bytes.len() <= envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES {
            return Err(ServerCoreError::InvalidEnvelope(
                "opaque envelope is too short".to_string(),
            ));
        }
        if bytes.len() > limits.max_envelope_bytes {
            return Err(ServerCoreError::InvalidEnvelope(format!(
                "opaque envelope is too large: {} > {} bytes",
                bytes.len(),
                limits.max_envelope_bytes
            )));
        }
        let actual_len = u64::try_from(bytes.len()).map_err(|_| ServerCoreError::InvalidField {
            field: "envelope_len",
            detail: "does not fit u64".to_string(),
        })?;
        if self.envelope_len != actual_len {
            return Err(ServerCoreError::InvalidField {
                field: "envelope_len",
                detail: format!(
                    "does not match decoded bytes: {} != {actual_len}",
                    self.envelope_len
                ),
            });
        }
        let actual_hash = envelope_core::sha256_hex(&bytes);
        if self.envelope_sha256 != actual_hash {
            return Err(ServerCoreError::InvalidField {
                field: "envelope_sha256",
                detail: "does not match decoded bytes".to_string(),
            });
        }
        Ok(bytes)
    }

    pub fn verify(
        &self,
        sender_contact: &Contact,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<Vec<u8>> {
        let bytes = self.envelope_bytes(limits)?;
        if self.sender_key_id != sender_contact.key_id {
            return Err(ServerCoreError::InvalidField {
                field: "sender_key_id",
                detail: "must match sender contact".to_string(),
            });
        }
        validate_control_timestamp(
            "submitted_at_unix_ms",
            self.submitted_at_unix_ms,
            now_unix_ms,
            limits,
        )?;
        let payload = envelope_submit_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_contact_signature(
            sender_contact,
            ENVELOPE_SUBMIT_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        Ok(bytes)
    }

    pub fn stored_until_unix_ms(
        &self,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<u128> {
        let ttl_seconds = self
            .ttl_seconds
            .unwrap_or(limits.default_envelope_ttl_seconds)
            .clamp(1, limits.default_envelope_ttl_seconds);
        Ok(now_unix_ms + u128::from(ttl_seconds).saturating_mul(1000))
    }

    pub fn stored_response(&self, stored_until_unix_ms: u128) -> EnvelopeSubmitResponse {
        EnvelopeSubmitResponse {
            version: SERVER_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            envelope_id: self.envelope_id.clone(),
            stored_until_unix_ms,
        }
    }
}

impl MailboxEnvelope {
    pub fn from_bytes(
        envelope_id: impl Into<String>,
        sender_key_id: impl Into<String>,
        recipient_key_id: impl Into<String>,
        envelope_bytes: &[u8],
        received_at_unix_ms: u128,
        expires_at_unix_ms: u128,
    ) -> Self {
        Self {
            envelope_id: envelope_id.into(),
            sender_key_id: sender_key_id.into(),
            recipient_key_id: recipient_key_id.into(),
            envelope_b64: envelope_core::encode_bytes(envelope_bytes),
            received_at_unix_ms,
            expires_at_unix_ms,
        }
    }
}

impl MailboxPullRequest {
    pub fn create(
        identity: &Identity,
        limit: Option<u32>,
        requested_at_unix_ms: u128,
    ) -> Result<Self> {
        let mut request = Self {
            version: SERVER_PROTOCOL_VERSION,
            recipient_key_id: identity.public.key_id.clone(),
            limit,
            requested_at_unix_ms,
            signature: String::new(),
        };
        let payload = mailbox_pull_signature_payload(&request)?;
        request.signature = envelope_core::sign_context_payload(
            identity,
            MAILBOX_PULL_SIGNATURE_CONTEXT,
            &payload,
        )?;
        Ok(request)
    }

    pub fn verify(
        &self,
        recipient_contact: &Contact,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<()> {
        validate_version(self.version, "mailbox pull version")?;
        if self.recipient_key_id != recipient_contact.key_id {
            return Err(ServerCoreError::InvalidField {
                field: "recipient_key_id",
                detail: "must match recipient contact".to_string(),
            });
        }
        validate_key_id("recipient_key_id", &self.recipient_key_id)?;
        validate_control_timestamp(
            "requested_at_unix_ms",
            self.requested_at_unix_ms,
            now_unix_ms,
            limits,
        )?;
        let payload = mailbox_pull_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_contact_signature(
            recipient_contact,
            MAILBOX_PULL_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        Ok(())
    }
}

impl MailboxAckRequest {
    pub fn create(
        identity: &Identity,
        envelope_ids: Vec<String>,
        acked_at_unix_ms: u128,
    ) -> Result<Self> {
        let mut request = Self {
            version: SERVER_PROTOCOL_VERSION,
            recipient_key_id: identity.public.key_id.clone(),
            envelope_ids,
            acked_at_unix_ms,
            signature: String::new(),
        };
        let payload = mailbox_ack_signature_payload(&request)?;
        request.signature =
            envelope_core::sign_context_payload(identity, MAILBOX_ACK_SIGNATURE_CONTEXT, &payload)?;
        Ok(request)
    }

    pub fn verify(
        &self,
        recipient_contact: &Contact,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<()> {
        validate_version(self.version, "mailbox ack version")?;
        if self.recipient_key_id != recipient_contact.key_id {
            return Err(ServerCoreError::InvalidField {
                field: "recipient_key_id",
                detail: "must match recipient contact".to_string(),
            });
        }
        validate_key_id("recipient_key_id", &self.recipient_key_id)?;
        validate_envelope_id_list(&self.envelope_ids, limits)?;
        validate_control_timestamp(
            "acked_at_unix_ms",
            self.acked_at_unix_ms,
            now_unix_ms,
            limits,
        )?;
        let payload = mailbox_ack_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_contact_signature(
            recipient_contact,
            MAILBOX_ACK_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        Ok(())
    }
}

impl DeliveryStatusRequest {
    pub fn create(
        identity: &Identity,
        envelope_ids: Vec<String>,
        requested_at_unix_ms: u128,
    ) -> Result<Self> {
        let mut request = Self {
            version: SERVER_PROTOCOL_VERSION,
            sender_key_id: identity.public.key_id.clone(),
            envelope_ids,
            requested_at_unix_ms,
            signature: String::new(),
        };
        let payload = delivery_status_signature_payload(&request)?;
        request.signature = envelope_core::sign_context_payload(
            identity,
            DELIVERY_STATUS_SIGNATURE_CONTEXT,
            &payload,
        )?;
        Ok(request)
    }

    pub fn verify(
        &self,
        sender_contact: &Contact,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<()> {
        validate_version(self.version, "delivery status version")?;
        if self.sender_key_id != sender_contact.key_id {
            return Err(ServerCoreError::InvalidField {
                field: "sender_key_id",
                detail: "must match sender contact".to_string(),
            });
        }
        validate_key_id("sender_key_id", &self.sender_key_id)?;
        validate_envelope_id_list(&self.envelope_ids, limits)?;
        validate_control_timestamp(
            "requested_at_unix_ms",
            self.requested_at_unix_ms,
            now_unix_ms,
            limits,
        )?;
        let payload = delivery_status_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_contact_signature(
            sender_contact,
            DELIVERY_STATUS_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        Ok(())
    }
}

impl IntroSessionPublishRequest {
    pub fn validate(
        &self,
        session_id: &str,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<Contact> {
        validate_version(self.version, "intro session publish version")?;
        validate_bounded_string("session_id", session_id, 1, 128)?;
        validate_intro_bundle("owner_bundle", &self.owner_bundle, now_unix_ms, limits)
    }

    pub fn accepted_response(&self, session_id: impl Into<String>) -> IntroSessionPublishResponse {
        IntroSessionPublishResponse {
            version: SERVER_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            session_id: session_id.into(),
            owner_key_id: self.owner_bundle.contact.key_id.clone(),
            expires_at_unix_ms: self.owner_bundle.expires_at_unix_ms,
        }
    }
}

impl IntroSessionRespondRequest {
    pub fn validate(
        &self,
        session_id: &str,
        now_unix_ms: u128,
        limits: &AntiAbuseLimits,
    ) -> CoreResult<Contact> {
        validate_version(self.version, "intro session respond version")?;
        validate_bounded_string("session_id", session_id, 1, 128)?;
        validate_intro_bundle(
            "responder_bundle",
            &self.responder_bundle,
            now_unix_ms,
            limits,
        )
    }

    pub fn accepted_response(&self, session_id: impl Into<String>) -> IntroSessionRespondResponse {
        IntroSessionRespondResponse {
            version: SERVER_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            session_id: session_id.into(),
            responder_key_id: self.responder_bundle.contact.key_id.clone(),
            expires_at_unix_ms: self.responder_bundle.expires_at_unix_ms,
        }
    }
}

impl NodeSetManifest {
    pub fn sign(&mut self, signing_secret: &str) -> Result<()> {
        let payload = node_set_manifest_signature_payload(self)?;
        self.signature = envelope_core::sign_context_payload_with_secret(
            signing_secret,
            NODE_SET_MANIFEST_SIGNATURE_CONTEXT,
            &payload,
        )?;
        Ok(())
    }

    pub fn verify(&self, signing_public: &str, now_unix_ms: u128) -> CoreResult<()> {
        self.validate_unsigned(now_unix_ms)?;
        validate_base64_bytes("manifest_signing_public", signing_public, 32)?;
        validate_bounded_string("signature", &self.signature, 1, 256)?;
        let payload = node_set_manifest_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_context_payload_with_public(
            signing_public,
            NODE_SET_MANIFEST_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))
    }

    pub fn node(&self, node_id: &str) -> Option<&NodeDescriptor> {
        self.nodes.iter().find(|node| node.node_id == node_id)
    }

    fn validate_unsigned(&self, now_unix_ms: u128) -> CoreResult<()> {
        validate_version(self.version, "manifest version")?;
        validate_bounded_string("manifest_id", &self.manifest_id, 1, 128)?;
        if self.valid_from_unix_ms > self.valid_until_unix_ms {
            return Err(ServerCoreError::InvalidField {
                field: "valid_until_unix_ms",
                detail: "must be greater than or equal to valid_from_unix_ms".to_string(),
            });
        }
        if self.valid_from_unix_ms > now_unix_ms {
            return Err(ServerCoreError::InvalidField {
                field: "valid_from_unix_ms",
                detail: "manifest is not valid yet".to_string(),
            });
        }
        if self.valid_until_unix_ms < now_unix_ms {
            return Err(ServerCoreError::InvalidField {
                field: "valid_until_unix_ms",
                detail: "manifest expired".to_string(),
            });
        }
        if let Some(prev_manifest_hash) = &self.prev_manifest_hash {
            validate_sha256_hex("prev_manifest_hash", prev_manifest_hash)?;
        }
        if self.nodes.is_empty() {
            return Err(ServerCoreError::InvalidField {
                field: "nodes",
                detail: "must contain at least one node".to_string(),
            });
        }
        for node in &self.nodes {
            node.validate(now_unix_ms)?;
        }
        for revoked_node_id in &self.revoked_node_ids {
            validate_node_id("revoked_node_ids", revoked_node_id)?;
        }
        Ok(())
    }
}

impl NodeDescriptor {
    fn validate(&self, now_unix_ms: u128) -> CoreResult<()> {
        validate_node_id("node_id", &self.node_id)?;
        validate_bounded_string("base_url", &self.base_url, 1, 2048)?;
        if !(self.base_url.starts_with("https://") || self.base_url.starts_with("http://")) {
            return Err(ServerCoreError::InvalidField {
                field: "base_url",
                detail: "must start with http:// or https://".to_string(),
            });
        }
        validate_base64_bytes("public_key", &self.public_key, 32)?;
        if self.capabilities.len() > 64 {
            return Err(ServerCoreError::InvalidField {
                field: "capabilities",
                detail: "must contain at most 64 entries".to_string(),
            });
        }
        for capability in &self.capabilities {
            validate_bounded_string("capabilities", capability, 1, 64)?;
        }
        if let Some(region) = &self.region {
            validate_bounded_string("region", region, 1, 64)?;
        }
        if self.valid_until_unix_ms < now_unix_ms {
            return Err(ServerCoreError::InvalidField {
                field: "node.valid_until_unix_ms",
                detail: format!("node {} expired", self.node_id),
            });
        }
        Ok(())
    }
}

impl NodeChallengeRequest {
    pub fn validate(&self, now_unix_ms: u128, max_clock_skew_ms: u128) -> CoreResult<()> {
        validate_version(self.version, "challenge version")?;
        validate_node_id("node_id", &self.node_id)?;
        let challenge =
            envelope_core::decode_bytes(&self.challenge_b64, "challenge_b64").map_err(|error| {
                ServerCoreError::InvalidField {
                    field: "challenge_b64",
                    detail: error.to_string(),
                }
            })?;
        if !(16..=256).contains(&challenge.len()) {
            return Err(ServerCoreError::InvalidField {
                field: "challenge_b64",
                detail: format!(
                    "challenge must decode to 16..256 bytes, got {}",
                    challenge.len()
                ),
            });
        }
        validate_clock_skew(
            "requested_at_unix_ms",
            self.requested_at_unix_ms,
            now_unix_ms,
            max_clock_skew_ms,
        )
    }
}

impl NodeChallengeResponse {
    pub fn create(
        node_id: impl Into<String>,
        signing_secret: &str,
        request: &NodeChallengeRequest,
        signed_at_unix_ms: u128,
    ) -> Result<Self> {
        let mut response = Self {
            version: SERVER_PROTOCOL_VERSION,
            status: STATUS_OK.to_string(),
            node_id: node_id.into(),
            challenge_b64: request.challenge_b64.clone(),
            requested_at_unix_ms: request.requested_at_unix_ms,
            signed_at_unix_ms,
            signature: String::new(),
        };
        let payload = node_challenge_signature_payload(&response)?;
        response.signature = envelope_core::sign_context_payload_with_secret(
            signing_secret,
            NODE_CHALLENGE_SIGNATURE_CONTEXT,
            &payload,
        )?;
        Ok(response)
    }

    pub fn verify(
        &self,
        request: &NodeChallengeRequest,
        signing_public: &str,
        now_unix_ms: u128,
        max_clock_skew_ms: u128,
    ) -> CoreResult<()> {
        validate_version(self.version, "challenge response version")?;
        validate_node_id("node_id", &self.node_id)?;
        validate_base64_bytes("node public_key", signing_public, 32)?;
        validate_bounded_string("signature", &self.signature, 1, 256)?;
        if self.status != STATUS_OK {
            return Err(ServerCoreError::InvalidField {
                field: "status",
                detail: format!("unexpected status {}", self.status),
            });
        }
        if self.node_id != request.node_id {
            return Err(ServerCoreError::InvalidField {
                field: "node_id",
                detail: "response node_id must match request node_id".to_string(),
            });
        }
        if self.challenge_b64 != request.challenge_b64 {
            return Err(ServerCoreError::InvalidField {
                field: "challenge_b64",
                detail: "response challenge must match request challenge".to_string(),
            });
        }
        if self.requested_at_unix_ms != request.requested_at_unix_ms {
            return Err(ServerCoreError::InvalidField {
                field: "requested_at_unix_ms",
                detail: "response requested_at must match request".to_string(),
            });
        }
        validate_clock_skew(
            "signed_at_unix_ms",
            self.signed_at_unix_ms,
            now_unix_ms,
            max_clock_skew_ms,
        )?;
        let payload = node_challenge_signature_payload(self)
            .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))?;
        envelope_core::verify_context_payload_with_public(
            signing_public,
            NODE_CHALLENGE_SIGNATURE_CONTEXT,
            &payload,
            &self.signature,
        )
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))
    }
}

pub fn validate_mailbox_capacity(
    current_envelope_count: usize,
    current_mailbox_bytes: usize,
    incoming_bytes: usize,
    limits: &AntiAbuseLimits,
) -> CoreResult<()> {
    if current_envelope_count >= limits.max_mailbox_envelopes {
        return Err(ServerCoreError::MailboxLimitExceeded(format!(
            "too many queued envelopes: {current_envelope_count} >= {}",
            limits.max_mailbox_envelopes
        )));
    }
    if current_mailbox_bytes.saturating_add(incoming_bytes) > limits.max_mailbox_bytes {
        return Err(ServerCoreError::MailboxLimitExceeded(format!(
            "mailbox bytes would exceed {}",
            limits.max_mailbox_bytes
        )));
    }
    Ok(())
}

pub fn bounded_pull_limit(request: &MailboxPullRequest) -> u32 {
    request.limit.unwrap_or(50).clamp(1, 100)
}

fn mailbox_pull_signature_payload(request: &MailboxPullRequest) -> Result<Vec<u8>> {
    let payload = MailboxPullSigningPayload {
        version: request.version,
        recipient_key_id: &request.recipient_key_id,
        limit: request.limit,
        requested_at_unix_ms: request.requested_at_unix_ms,
    };
    serde_json::to_vec(&payload).context("serialize mailbox pull signature payload")
}

fn envelope_submit_signature_payload(request: &EnvelopeSubmitRequest) -> Result<Vec<u8>> {
    let payload = EnvelopeSubmitSigningPayload {
        version: request.version,
        envelope_id: &request.envelope_id,
        sender_key_id: &request.sender_key_id,
        recipient_key_id: &request.recipient_key_id,
        envelope_sha256: &request.envelope_sha256,
        envelope_len: request.envelope_len,
        ttl_seconds: request.ttl_seconds,
        submitted_at_unix_ms: request.submitted_at_unix_ms,
    };
    serde_json::to_vec(&payload).context("serialize envelope submit signature payload")
}

fn mailbox_ack_signature_payload(request: &MailboxAckRequest) -> Result<Vec<u8>> {
    let payload = MailboxAckSigningPayload {
        version: request.version,
        recipient_key_id: &request.recipient_key_id,
        envelope_ids: &request.envelope_ids,
        acked_at_unix_ms: request.acked_at_unix_ms,
    };
    serde_json::to_vec(&payload).context("serialize mailbox ack signature payload")
}

fn delivery_status_signature_payload(request: &DeliveryStatusRequest) -> Result<Vec<u8>> {
    let payload = DeliveryStatusSigningPayload {
        version: request.version,
        sender_key_id: &request.sender_key_id,
        envelope_ids: &request.envelope_ids,
        requested_at_unix_ms: request.requested_at_unix_ms,
    };
    serde_json::to_vec(&payload).context("serialize delivery status signature payload")
}

fn node_set_manifest_signature_payload(manifest: &NodeSetManifest) -> Result<Vec<u8>> {
    let payload = NodeSetManifestSigningPayload {
        version: manifest.version,
        manifest_id: &manifest.manifest_id,
        epoch: manifest.epoch,
        valid_from_unix_ms: manifest.valid_from_unix_ms,
        valid_until_unix_ms: manifest.valid_until_unix_ms,
        prev_manifest_hash: &manifest.prev_manifest_hash,
        nodes: &manifest.nodes,
        revoked_node_ids: &manifest.revoked_node_ids,
    };
    serde_json::to_vec(&payload).context("serialize node set manifest signature payload")
}

fn node_challenge_signature_payload(response: &NodeChallengeResponse) -> Result<Vec<u8>> {
    let payload = NodeChallengeSigningPayload {
        version: response.version,
        node_id: &response.node_id,
        challenge_b64: &response.challenge_b64,
        requested_at_unix_ms: response.requested_at_unix_ms,
        signed_at_unix_ms: response.signed_at_unix_ms,
    };
    serde_json::to_vec(&payload).context("serialize node challenge signature payload")
}

fn validate_version(version: u16, field: &'static str) -> CoreResult<()> {
    if version == SERVER_PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: format!("unsupported version {version}"),
        })
    }
}

fn validate_contact(contact: &Contact) -> CoreResult<()> {
    if contact.version != ENVELOPE_PROTOCOL_VERSION {
        return Err(ServerCoreError::InvalidField {
            field: "owner_contact.version",
            detail: format!("unsupported version {}", contact.version),
        });
    }
    validate_key_id("owner_contact.key_id", &contact.key_id)?;
    validate_bounded_string("owner_contact.display_name", &contact.display_name, 1, 128)?;
    if envelope_core::decode_bytes(&contact.signing_public, "signing_public").is_err() {
        return Err(ServerCoreError::InvalidField {
            field: "owner_contact.signing_public",
            detail: "invalid base64 public key".to_string(),
        });
    }
    if envelope_core::decode_bytes(&contact.agreement_public, "agreement_public").is_err() {
        return Err(ServerCoreError::InvalidField {
            field: "owner_contact.agreement_public",
            detail: "invalid base64 public key".to_string(),
        });
    }
    Ok(())
}

fn validate_intro_bundle(
    field: &'static str,
    bundle: &EnvelopeIntroBundle,
    now_unix_ms: u128,
    limits: &AntiAbuseLimits,
) -> CoreResult<Contact> {
    let bundle_json =
        serde_json::to_vec(bundle).map_err(|error| ServerCoreError::InvalidField {
            field,
            detail: format!("intro bundle is not serializable: {error}"),
        })?;
    if bundle_json.len() > limits.max_intro_bundle_bytes {
        return Err(ServerCoreError::InvalidField {
            field,
            detail: format!(
                "intro bundle is too large: {} > {} bytes",
                bundle_json.len(),
                limits.max_intro_bundle_bytes
            ),
        });
    }
    if bundle
        .expires_at_unix_ms
        .saturating_add(limits.max_control_clock_skew_ms)
        < now_unix_ms
    {
        return Err(ServerCoreError::InvalidField {
            field,
            detail: "intro bundle expired".to_string(),
        });
    }
    let max_expires_at_unix_ms = now_unix_ms
        .saturating_add(u128::from(limits.max_intro_session_ttl_seconds).saturating_mul(1000))
        .saturating_add(limits.max_control_clock_skew_ms);
    if bundle.expires_at_unix_ms > max_expires_at_unix_ms {
        return Err(ServerCoreError::InvalidField {
            field,
            detail: format!(
                "intro bundle TTL exceeds {} seconds",
                limits.max_intro_session_ttl_seconds
            ),
        });
    }
    envelope_core::verify_intro_bundle(bundle)
        .map_err(|error| ServerCoreError::InvalidSignature(error.to_string()))
}

fn validate_key_id(field: &'static str, key_id: &str) -> CoreResult<()> {
    if key_id.len() == 32 && key_id.as_bytes().iter().all(u8::is_ascii_hexdigit) {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: "must be a 32-character hex key id".to_string(),
        })
    }
}

fn validate_node_id(field: &'static str, node_id: &str) -> CoreResult<()> {
    validate_bounded_string(field, node_id, 1, 128)
}

fn validate_base64_bytes(field: &'static str, value: &str, expected_len: usize) -> CoreResult<()> {
    let bytes = envelope_core::decode_bytes(value, field).map_err(|error| {
        ServerCoreError::InvalidField {
            field,
            detail: error.to_string(),
        }
    })?;
    if bytes.len() == expected_len {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: format!("must decode to {expected_len} bytes, got {}", bytes.len()),
        })
    }
}

fn validate_sha256_hex(field: &'static str, value: &str) -> CoreResult<()> {
    if value.len() == 64
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: "must be lowercase SHA-256 hex".to_string(),
        })
    }
}

fn validate_clock_skew(
    field: &'static str,
    value_unix_ms: u128,
    now_unix_ms: u128,
    max_clock_skew_ms: u128,
) -> CoreResult<()> {
    let earliest = now_unix_ms.saturating_sub(max_clock_skew_ms);
    let latest = now_unix_ms.saturating_add(max_clock_skew_ms);
    if value_unix_ms < earliest || value_unix_ms > latest {
        return Err(ServerCoreError::InvalidField {
            field,
            detail: format!("outside allowed clock skew of {max_clock_skew_ms} ms"),
        });
    }
    Ok(())
}

fn validate_envelope_id(envelope_id: &str) -> CoreResult<()> {
    Uuid::parse_str(envelope_id).map_err(|error| ServerCoreError::InvalidField {
        field: "envelope_id",
        detail: error.to_string(),
    })?;
    Ok(())
}

fn validate_envelope_id_list(envelope_ids: &[String], limits: &AntiAbuseLimits) -> CoreResult<()> {
    if envelope_ids.is_empty() {
        return Err(ServerCoreError::InvalidField {
            field: "envelope_ids",
            detail: "must not be empty".to_string(),
        });
    }
    if envelope_ids.len() > limits.max_ack_envelope_ids {
        return Err(ServerCoreError::InvalidField {
            field: "envelope_ids",
            detail: format!("must contain at most {}", limits.max_ack_envelope_ids),
        });
    }
    for envelope_id in envelope_ids {
        validate_envelope_id(envelope_id)?;
    }
    Ok(())
}

fn validate_bounded_string(
    field: &'static str,
    value: &str,
    min_bytes: usize,
    max_bytes: usize,
) -> CoreResult<()> {
    let len = value.len();
    if (min_bytes..=max_bytes).contains(&len) {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: format!("must be {min_bytes}..={max_bytes} bytes, got {len}"),
        })
    }
}

fn validate_endpoint_ttl(
    endpoint: &DeviceEndpointUpdate,
    now_unix_ms: u128,
    limits: &AntiAbuseLimits,
) -> CoreResult<()> {
    if endpoint.created_at_unix_ms > endpoint.expires_at_unix_ms {
        return Err(ServerCoreError::InvalidField {
            field: "endpoint.expires_at_unix_ms",
            detail: "must be after created_at_unix_ms".to_string(),
        });
    }
    let max_expires_at =
        now_unix_ms + u128::from(limits.max_endpoint_ttl_seconds).saturating_mul(1000);
    if endpoint.expires_at_unix_ms > max_expires_at {
        return Err(ServerCoreError::InvalidField {
            field: "endpoint.expires_at_unix_ms",
            detail: format!(
                "must not be more than {} seconds in the future",
                limits.max_endpoint_ttl_seconds
            ),
        });
    }
    Ok(())
}

fn validate_control_timestamp(
    field: &'static str,
    value: u128,
    now_unix_ms: u128,
    limits: &AntiAbuseLimits,
) -> CoreResult<()> {
    let lower = now_unix_ms.saturating_sub(limits.max_control_clock_skew_ms);
    let upper = now_unix_ms.saturating_add(limits.max_control_clock_skew_ms);
    if (lower..=upper).contains(&value) {
        Ok(())
    } else {
        Err(ServerCoreError::InvalidField {
            field,
            detail: "outside allowed clock skew".to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_endpoint_registration_validates() {
        let alice = Identity::generate("Alice");
        let now: u128 = 1_700_000_000_000;
        let mut endpoint = DeviceEndpointUpdate {
            version: ENVELOPE_PROTOCOL_VERSION,
            owner_identity_key_id: alice.public.key_id.clone(),
            device_id: "phone-1".to_string(),
            device_list_version: 1,
            p2p_ticket: "envelope-p2p-tcp-v1:test".to_string(),
            session_id: "session-1".to_string(),
            created_at_unix_ms: now,
            expires_at_unix_ms: now + 60_000,
            signature: String::new(),
        };
        envelope_core::sign_device_endpoint_update(&alice, &mut endpoint).unwrap();

        let request = DeviceRegistrationRequest {
            version: SERVER_PROTOCOL_VERSION,
            owner_contact: alice.contact(),
            endpoint,
        };

        request.validate(now, &AntiAbuseLimits::default()).unwrap();
    }

    #[test]
    fn oversized_envelope_is_rejected() {
        let alice = Identity::generate("Alice");
        let request = EnvelopeSubmitRequest::create(
            &alice,
            "b".repeat(32),
            Uuid::new_v4().to_string(),
            envelope_core::encode_bytes(&vec![7u8; 65]),
            None,
            1_700_000_000_000,
        )
        .unwrap();
        let limits = AntiAbuseLimits {
            max_envelope_bytes: 64,
            ..AntiAbuseLimits::default()
        };

        assert!(request.envelope_bytes(&limits).is_err());
    }

    #[test]
    fn mailbox_capacity_rejects_count_and_bytes_over_limit() {
        let limits = AntiAbuseLimits {
            max_mailbox_envelopes: 2,
            max_mailbox_bytes: 10,
            ..AntiAbuseLimits::default()
        };

        validate_mailbox_capacity(1, 7, 3, &limits).unwrap();
        assert!(validate_mailbox_capacity(2, 0, 1, &limits).is_err());
        assert!(validate_mailbox_capacity(1, 8, 3, &limits).is_err());
    }

    #[test]
    fn envelope_submit_signature_round_trips() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let now: u128 = 1_700_000_000_000;
        let request = EnvelopeSubmitRequest::create(
            &alice,
            bob.public.key_id.clone(),
            Uuid::new_v4().to_string(),
            envelope_core::encode_bytes(&vec![7u8; 65]),
            Some(60),
            now,
        )
        .unwrap();

        request
            .verify(&alice.contact(), now, &AntiAbuseLimits::default())
            .unwrap();

        let mut tampered = request.clone();
        tampered.recipient_key_id = alice.public.key_id.clone();
        assert!(
            tampered
                .verify(&alice.contact(), now, &AntiAbuseLimits::default())
                .is_err()
        );
        assert!(
            request
                .verify(&bob.contact(), now, &AntiAbuseLimits::default())
                .is_err()
        );
    }

    #[test]
    fn intro_session_allows_normal_clock_skew() {
        let alice = Identity::generate("Alice");
        let client_ahead_ms = 4_000;
        let bundle = envelope_core::create_intro_bundle(
            &alice,
            "android-alice",
            None,
            vec!["contact.v1".to_string(), "qr.v1".to_string()],
            DEFAULT_MAX_INTRO_SESSION_TTL_SECONDS,
        )
        .unwrap();
        let server_now = bundle.created_at_unix_ms.saturating_sub(client_ahead_ms);
        let request = IntroSessionPublishRequest {
            version: SERVER_PROTOCOL_VERSION,
            owner_bundle: bundle,
        };

        request
            .validate(
                "session-1",
                server_now.saturating_sub(client_ahead_ms),
                &AntiAbuseLimits::default(),
            )
            .unwrap();
    }

    #[test]
    fn mailbox_ack_signature_round_trips() {
        let alice = Identity::generate("Alice");
        let now: u128 = 1_700_000_000_000;
        let request =
            MailboxAckRequest::create(&alice, vec![Uuid::new_v4().to_string()], now).unwrap();

        request
            .verify(&alice.contact(), now, &AntiAbuseLimits::default())
            .unwrap();

        let bob = Identity::generate("Bob");
        assert!(
            request
                .verify(&bob.contact(), now, &AntiAbuseLimits::default())
                .is_err()
        );
    }

    #[test]
    fn mailbox_pull_signature_round_trips() {
        let alice = Identity::generate("Alice");
        let now: u128 = 1_700_000_000_000;
        let request = MailboxPullRequest::create(&alice, Some(25), now).unwrap();

        request
            .verify(&alice.contact(), now, &AntiAbuseLimits::default())
            .unwrap();

        let bob = Identity::generate("Bob");
        assert!(
            request
                .verify(&bob.contact(), now, &AntiAbuseLimits::default())
                .is_err()
        );
    }

    #[test]
    fn delivery_status_signature_round_trips() {
        let alice = Identity::generate("Alice");
        let now: u128 = 1_700_000_000_000;
        let request =
            DeliveryStatusRequest::create(&alice, vec![Uuid::new_v4().to_string()], now).unwrap();

        request
            .verify(&alice.contact(), now, &AntiAbuseLimits::default())
            .unwrap();

        let bob = Identity::generate("Bob");
        assert!(
            request
                .verify(&bob.contact(), now, &AntiAbuseLimits::default())
                .is_err()
        );
    }

    #[test]
    fn node_set_manifest_signature_round_trips() {
        let manifest_signer = Identity::generate("manifest signer");
        let node = Identity::generate("node-a");
        let now: u128 = 1_700_000_000_000;
        let mut manifest = NodeSetManifest {
            version: SERVER_PROTOCOL_VERSION,
            manifest_id: "manifest-a".to_string(),
            epoch: 1,
            valid_from_unix_ms: now.saturating_sub(1_000),
            valid_until_unix_ms: now.saturating_add(60_000),
            prev_manifest_hash: None,
            nodes: vec![NodeDescriptor {
                node_id: "node-a".to_string(),
                base_url: "https://node-a.example.test".to_string(),
                public_key: node.public.signing_public.clone(),
                capabilities: vec!["route".to_string(), "mailbox".to_string()],
                weight: 100,
                region: Some("test".to_string()),
                valid_until_unix_ms: now.saturating_add(60_000),
            }],
            revoked_node_ids: Vec::new(),
            signature: String::new(),
        };
        manifest.sign(&manifest_signer.signing_secret).unwrap();
        manifest
            .verify(&manifest_signer.public.signing_public, now)
            .unwrap();

        let mut tampered = manifest.clone();
        tampered.nodes[0].base_url = "https://evil.example.test".to_string();
        assert!(
            tampered
                .verify(&manifest_signer.public.signing_public, now)
                .is_err()
        );
    }

    #[test]
    fn node_challenge_signature_round_trips() {
        let node = Identity::generate("node-a");
        let other = Identity::generate("node-b");
        let now: u128 = 1_700_000_000_000;
        let request = NodeChallengeRequest {
            version: SERVER_PROTOCOL_VERSION,
            node_id: "node-a".to_string(),
            challenge_b64: envelope_core::encode_bytes(&[7u8; 32]),
            requested_at_unix_ms: now,
        };
        request
            .validate(now, AntiAbuseLimits::default().max_control_clock_skew_ms)
            .unwrap();
        let response = NodeChallengeResponse::create(
            "node-a",
            &node.signing_secret,
            &request,
            now.saturating_add(1),
        )
        .unwrap();
        response
            .verify(
                &request,
                &node.public.signing_public,
                now,
                AntiAbuseLimits::default().max_control_clock_skew_ms,
            )
            .unwrap();
        assert!(
            response
                .verify(
                    &request,
                    &other.public.signing_public,
                    now,
                    AntiAbuseLimits::default().max_control_clock_skew_ms,
                )
                .is_err()
        );
    }
}
