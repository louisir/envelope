use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use bip39::{Language, Mnemonic};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

pub const ENVELOPE_PROTOCOL_VERSION: u16 = 1;
pub const RECOVERY_WORD_COUNT: usize = 24;
pub const CONTEXT_IDENTITY_SIGNING: &str = "envelope/v1/identity/signing";
pub const CONTEXT_IDENTITY_AGREEMENT: &str = "envelope/v1/identity/agreement";
pub const CONTEXT_DEVICE_AUTHORIZATION: &str = "envelope/v1/device/authorization";
pub const CONTEXT_BACKUP_ENCRYPTION: &str = "envelope/v1/backup/encryption";
pub const CONTEXT_GROUP_CONSENSUS_ENDORSEMENT: &str = "envelope/v1/group/consensus-endorsement";
pub const OPAQUE_OFFLINE_ENVELOPE_VERSION: u16 = 1;
pub const OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES: usize = 32;

const OPAQUE_OFFLINE_ENVELOPE_SCHEME: &str = "x25519+hkdf-sha256+xchacha20poly1305.opaque.v1";
const OPAQUE_OFFLINE_ENVELOPE_AAD_CONTEXT: &[u8] = b"envelope opaque offline envelope aad v1";
pub const LOCAL_BACKUP_VERSION: u16 = 1;
const LOCAL_BACKUP_SCHEME: &str = "bip39-hkdf-sha256+xchacha20poly1305.local-backup.v1";
const LOCAL_BACKUP_AAD_CONTEXT: &[u8] = b"envelope local backup aad v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Identity {
    pub version: u16,
    pub display_name: String,
    pub signing_secret: String,
    pub agreement_secret: String,
    pub public: Contact,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Contact {
    pub version: u16,
    pub display_name: String,
    pub signing_public: String,
    pub agreement_public: String,
    pub key_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthorizerType {
    MobileMain,
    HardwareRoot,
    RecoveryRoot,
    MultiAuthorizer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeviceType {
    Android,
    Desktop,
    Ios,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeviceStatus {
    Active,
    Stale,
    Revoked,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRecord {
    pub version: u16,
    pub device_id: String,
    pub device_type: DeviceType,
    pub device_display_name: String,
    pub device_public_key: String,
    pub capabilities: Vec<String>,
    pub added_at_unix_ms: u128,
    pub expires_at_unix_ms: Option<u128>,
    pub status: DeviceStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceList {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub authorizer_key_id: String,
    pub authorizer_type: AuthorizerType,
    pub device_list_version: u64,
    pub devices: Vec<DeviceRecord>,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActiveDeviceUpdate {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub authorizer_key_id: String,
    pub authorizer_type: AuthorizerType,
    pub active_device_id: String,
    pub active_device_public_key: String,
    pub device_list_version: u64,
    pub granted_at_unix_ms: u128,
    pub expires_at_unix_ms: u128,
    pub update_version: u64,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceAuthorization {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub authorizer_key_id: String,
    pub authorizer_type: AuthorizerType,
    pub device_id: String,
    pub device_public_key: String,
    pub device_type: DeviceType,
    pub device_display_name: String,
    pub capabilities: Vec<String>,
    pub granted_at_unix_ms: u128,
    pub expires_at_unix_ms: u128,
    pub device_list_version: u64,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceRevocation {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub authorizer_key_id: String,
    pub authorizer_type: AuthorizerType,
    pub revoked_device_id: String,
    pub device_list_version: u64,
    pub revoked_at_unix_ms: u128,
    pub reason: String,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceEndpointUpdate {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub device_id: String,
    pub device_list_version: u64,
    pub p2p_ticket: String,
    pub session_id: String,
    pub created_at_unix_ms: u128,
    pub expires_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize)]
struct DeviceEndpointUpdateSigningPayload<'a> {
    version: u16,
    owner_identity_key_id: &'a str,
    device_id: &'a str,
    device_list_version: u64,
    p2p_ticket: &'a str,
    session_id: &'a str,
    created_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvelopeIntroBundle {
    pub version: u16,
    pub contact: Contact,
    pub device_id: String,
    pub p2p_ticket: Option<String>,
    pub capabilities: Vec<String>,
    pub created_at_unix_ms: u128,
    pub expires_at_unix_ms: u128,
    pub nonce: String,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize)]
struct EnvelopeIntroBundleSigningPayload<'a> {
    version: u16,
    contact: &'a Contact,
    device_id: &'a str,
    p2p_ticket: &'a Option<String>,
    capabilities: &'a [String],
    created_at_unix_ms: u128,
    expires_at_unix_ms: u128,
    nonce: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageArchiveRecord {
    pub record_id: String,
    pub envelope_id: String,
    pub payload: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageArchiveSync {
    pub version: u16,
    pub owner_identity_key_id: String,
    pub active_device_id: String,
    pub sync_from_unix_ms: Option<u128>,
    pub sync_to_unix_ms: u128,
    pub records: Vec<MessageArchiveRecord>,
    pub created_at_unix_ms: u128,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DecryptedOpaquePayload {
    pub version: u16,
    pub envelope_id: String,
    pub conversation_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub created_at_unix_ms: u128,
    pub message_counter: u64,
    pub payload_kind: String,
    pub mime: String,
    pub filename: Option<String>,
    pub payload_bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncryptedOpaquePayload {
    pub version: u16,
    pub envelope_id: String,
    pub conversation_id: String,
    pub sender_key_id: String,
    pub recipient_key_id: String,
    pub created_at_unix_ms: u128,
    pub message_counter: u64,
    pub payload_kind: String,
    pub mime: String,
    pub filename: Option<String>,
    pub envelope_bytes: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EncryptedLocalBackup {
    pub version: u16,
    pub scheme: String,
    pub created_at_unix_ms: u128,
    pub nonce: String,
    pub ciphertext: String,
    pub plaintext_sha256: String,
}

#[derive(Debug, Clone)]
struct OpaqueEnvelopeBody {
    version: u16,
    scheme: String,
    envelope_id: String,
    conversation_id: String,
    sender_key_id: String,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    payload_kind: String,
    mime: String,
    filename: Option<String>,
    original_payload_len: u64,
    payload_sha256: [u8; 32],
    payload_bytes: Vec<u8>,
    padding: Vec<u8>,
    signature: [u8; 64],
}

impl Identity {
    pub fn generate(display_name: impl Into<String>) -> Self {
        let display_name = display_name.into();
        let signing_key = SigningKey::generate(&mut OsRng);
        let agreement_secret = StaticSecret::random_from_rng(OsRng);
        let signing_public = signing_key.verifying_key().to_bytes();
        let agreement_public = X25519PublicKey::from(&agreement_secret).to_bytes();

        let contact = Contact::new(display_name.clone(), signing_public, agreement_public);

        Self {
            version: ENVELOPE_PROTOCOL_VERSION,
            display_name,
            signing_secret: encode_bytes(&signing_key.to_bytes()),
            agreement_secret: encode_bytes(&agreement_secret.to_bytes()),
            public: contact,
        }
    }

    pub fn from_recovery_phrase(display_name: impl Into<String>, phrase: &str) -> Result<Self> {
        identity_from_recovery_phrase(display_name, phrase)
    }

    pub fn contact(&self) -> Contact {
        self.public.clone()
    }

    fn signing_key(&self) -> Result<SigningKey> {
        signing_key_from_secret(&self.signing_secret, "signing_secret")
    }

    fn agreement_secret(&self) -> Result<StaticSecret> {
        Ok(StaticSecret::from(decode_array::<32>(
            &self.agreement_secret,
            "agreement_secret",
        )?))
    }
}

pub fn generate_recovery_phrase() -> Result<String> {
    let mut entropy = [0u8; 32];
    OsRng.fill_bytes(&mut entropy);
    let mnemonic =
        Mnemonic::from_entropy_in(Language::English, &entropy).context("create mnemonic")?;
    Ok(mnemonic.to_string())
}

pub fn identity_from_recovery_phrase(
    display_name: impl Into<String>,
    phrase: &str,
) -> Result<Identity> {
    if phrase.split_whitespace().count() != RECOVERY_WORD_COUNT {
        bail!("recovery phrase must contain {RECOVERY_WORD_COUNT} words");
    }

    let display_name = display_name.into();
    let mnemonic =
        Mnemonic::parse_in_normalized(Language::English, phrase).context("parse mnemonic")?;
    let seed = mnemonic.to_seed_normalized("");
    let signing_secret = derive_recovery_secret(&seed, CONTEXT_IDENTITY_SIGNING)?;
    let agreement_secret_bytes = derive_recovery_secret(&seed, CONTEXT_IDENTITY_AGREEMENT)?;
    let signing_key = SigningKey::from_bytes(&signing_secret);
    let agreement_secret = StaticSecret::from(agreement_secret_bytes);
    let signing_public = signing_key.verifying_key().to_bytes();
    let agreement_public = X25519PublicKey::from(&agreement_secret).to_bytes();
    let contact = Contact::new(display_name.clone(), signing_public, agreement_public);

    Ok(Identity {
        version: ENVELOPE_PROTOCOL_VERSION,
        display_name,
        signing_secret: encode_bytes(&signing_key.to_bytes()),
        agreement_secret: encode_bytes(&agreement_secret.to_bytes()),
        public: contact,
    })
}

pub fn encrypt_local_backup(recovery_phrase: &str, plaintext: &[u8]) -> Result<String> {
    let key = derive_backup_key_from_recovery_phrase(recovery_phrase)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key).context("create backup cipher")?;
    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: LOCAL_BACKUP_AAD_CONTEXT,
            },
        )
        .map_err(|_| anyhow::anyhow!("local backup encryption failed"))?;
    let backup = EncryptedLocalBackup {
        version: LOCAL_BACKUP_VERSION,
        scheme: LOCAL_BACKUP_SCHEME.to_string(),
        created_at_unix_ms: now_unix_ms()?,
        nonce: encode_bytes(&nonce),
        ciphertext: encode_bytes(&ciphertext),
        plaintext_sha256: sha256_hex(plaintext),
    };
    to_pretty_json(&backup)
}

pub fn decrypt_local_backup(recovery_phrase: &str, backup_json: &str) -> Result<Vec<u8>> {
    let backup: EncryptedLocalBackup = from_json_slice(backup_json.as_bytes())?;
    if backup.version != LOCAL_BACKUP_VERSION {
        bail!("unsupported local backup version: {}", backup.version);
    }
    if backup.scheme != LOCAL_BACKUP_SCHEME {
        bail!("unsupported local backup scheme: {}", backup.scheme);
    }
    let nonce = decode_array::<24>(&backup.nonce, "nonce")?;
    let ciphertext = decode_bytes(&backup.ciphertext, "ciphertext")?;
    let key = derive_backup_key_from_recovery_phrase(recovery_phrase)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key).context("create backup cipher")?;
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: LOCAL_BACKUP_AAD_CONTEXT,
            },
        )
        .map_err(|_| anyhow::anyhow!("local backup authentication or decryption failed"))?;
    if sha256_hex(&plaintext) != backup.plaintext_sha256 {
        bail!("local backup plaintext hash mismatch");
    }
    Ok(plaintext)
}

fn derive_backup_key_from_recovery_phrase(phrase: &str) -> Result<[u8; 32]> {
    if phrase.split_whitespace().count() != RECOVERY_WORD_COUNT {
        bail!("recovery phrase must contain {RECOVERY_WORD_COUNT} words");
    }
    let mnemonic =
        Mnemonic::parse_in_normalized(Language::English, phrase).context("parse mnemonic")?;
    let seed = mnemonic.to_seed_normalized("");
    derive_recovery_secret(&seed, CONTEXT_BACKUP_ENCRYPTION)
}

pub fn generate_signing_keypair() -> (String, String) {
    let signing_key = SigningKey::generate(&mut OsRng);
    (
        encode_bytes(&signing_key.to_bytes()),
        encode_bytes(&signing_key.verifying_key().to_bytes()),
    )
}

impl Contact {
    pub fn new(
        display_name: impl Into<String>,
        signing_public: [u8; 32],
        agreement_public: [u8; 32],
    ) -> Self {
        let signing_public_encoded = encode_bytes(&signing_public);
        let agreement_public_encoded = encode_bytes(&agreement_public);
        let key_id = public_key_id(&signing_public, &agreement_public);

        Self {
            version: ENVELOPE_PROTOCOL_VERSION,
            display_name: display_name.into(),
            signing_public: signing_public_encoded,
            agreement_public: agreement_public_encoded,
            key_id,
        }
    }

    fn verifying_key(&self) -> Result<VerifyingKey> {
        let key = decode_array::<32>(&self.signing_public, "signing_public")?;
        VerifyingKey::from_bytes(&key).context("invalid Ed25519 verifying key")
    }

    fn agreement_public(&self) -> Result<X25519PublicKey> {
        Ok(X25519PublicKey::from(decode_array::<32>(
            &self.agreement_public,
            "agreement_public",
        )?))
    }
}

pub fn encrypt_opaque_payload(
    sender: &Identity,
    recipient: &Contact,
    payload_kind: impl Into<String>,
    mime: impl Into<String>,
    filename: Option<String>,
    payload_bytes: &[u8],
    message_counter: u64,
) -> Result<EncryptedOpaquePayload> {
    let signing_key = sender.signing_key()?;
    let recipient_public = recipient.agreement_public()?;
    let ephemeral_secret = StaticSecret::random_from_rng(OsRng);
    let ephemeral_public = X25519PublicKey::from(&ephemeral_secret);
    let ephemeral_public_bytes = *ephemeral_public.as_bytes();
    let recipient_public_bytes = *recipient_public.as_bytes();
    let shared_secret = ephemeral_secret.diffie_hellman(&recipient_public);

    let mut body = OpaqueEnvelopeBody {
        version: OPAQUE_OFFLINE_ENVELOPE_VERSION,
        scheme: OPAQUE_OFFLINE_ENVELOPE_SCHEME.to_string(),
        envelope_id: Uuid::new_v4().to_string(),
        conversation_id: conversation_id(&sender.public.key_id, &recipient.key_id),
        sender_key_id: sender.public.key_id.clone(),
        recipient_key_id: recipient.key_id.clone(),
        created_at_unix_ms: now_unix_ms()?,
        message_counter,
        payload_kind: payload_kind.into(),
        mime: mime.into(),
        filename,
        original_payload_len: payload_bytes
            .len()
            .try_into()
            .context("payload length does not fit u64")?,
        payload_sha256: sha256_array(payload_bytes),
        payload_bytes: payload_bytes.to_vec(),
        padding: Vec::new(),
        signature: [0u8; 64],
    };

    let signature_payload = opaque_signature_payload(&body)?;
    let signature = signing_key.sign(&signature_payload);
    body.signature = signature.to_bytes();
    apply_opaque_padding(&mut body)?;

    let plaintext = encode_opaque_body(&body)?;
    let key = derive_opaque_envelope_key(
        shared_secret.as_bytes(),
        &ephemeral_public_bytes,
        &recipient_public_bytes,
    )?;
    let nonce = derive_opaque_envelope_nonce(&ephemeral_public_bytes, &recipient_public_bytes);
    let aad = opaque_envelope_aad(&ephemeral_public_bytes);
    let cipher = XChaCha20Poly1305::new_from_slice(&key).context("create opaque cipher")?;
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("opaque envelope encryption failed"))?;

    let mut envelope =
        Vec::with_capacity(OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES + ciphertext.len());
    envelope.extend_from_slice(&ephemeral_public_bytes);
    envelope.extend_from_slice(&ciphertext);
    Ok(EncryptedOpaquePayload {
        version: body.version,
        envelope_id: body.envelope_id,
        conversation_id: body.conversation_id,
        sender_key_id: body.sender_key_id,
        recipient_key_id: body.recipient_key_id,
        created_at_unix_ms: body.created_at_unix_ms,
        message_counter: body.message_counter,
        payload_kind: body.payload_kind,
        mime: body.mime,
        filename: body.filename,
        envelope_bytes: envelope,
    })
}

pub fn encrypt_opaque_text(
    sender: &Identity,
    recipient: &Contact,
    text: &str,
    message_counter: u64,
) -> Result<EncryptedOpaquePayload> {
    encrypt_opaque_payload(
        sender,
        recipient,
        "file",
        "text/plain; charset=utf-8",
        Some("message.txt".to_string()),
        text.as_bytes(),
        message_counter,
    )
}

pub fn decrypt_opaque_payload(
    recipient: &Identity,
    sender: &Contact,
    envelope_bytes: &[u8],
) -> Result<DecryptedOpaquePayload> {
    if envelope_bytes.len() <= OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES {
        bail!("opaque envelope is too short");
    }

    let ephemeral_public_bytes: [u8; OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES] =
        envelope_bytes[..OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES]
            .try_into()
            .context("read opaque envelope ephemeral public key")?;
    let ciphertext = &envelope_bytes[OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES..];
    let ephemeral_public = X25519PublicKey::from(ephemeral_public_bytes);
    let recipient_secret = recipient.agreement_secret()?;
    let recipient_public = recipient.public.agreement_public()?;
    let recipient_public_bytes = *recipient_public.as_bytes();
    let shared_secret = recipient_secret.diffie_hellman(&ephemeral_public);
    let key = derive_opaque_envelope_key(
        shared_secret.as_bytes(),
        &ephemeral_public_bytes,
        &recipient_public_bytes,
    )?;
    let nonce = derive_opaque_envelope_nonce(&ephemeral_public_bytes, &recipient_public_bytes);
    let aad = opaque_envelope_aad(&ephemeral_public_bytes);
    let cipher = XChaCha20Poly1305::new_from_slice(&key).context("create opaque cipher")?;
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("opaque envelope authentication or decryption failed"))?;
    let body = decode_opaque_body(&plaintext).context("parse opaque envelope body")?;

    if body.version != OPAQUE_OFFLINE_ENVELOPE_VERSION {
        bail!("unsupported opaque envelope version {}", body.version);
    }
    if body.scheme != OPAQUE_OFFLINE_ENVELOPE_SCHEME {
        bail!("unsupported opaque envelope scheme {}", body.scheme);
    }
    if body.sender_key_id != sender.key_id {
        bail!("sender key id does not match supplied contact");
    }
    if body.recipient_key_id != recipient.public.key_id {
        bail!("recipient key id does not match local identity");
    }

    let signature_payload = opaque_signature_payload(&body)?;
    let signature = Signature::from_bytes(&body.signature);
    sender
        .verifying_key()?
        .verify(&signature_payload, &signature)
        .context("opaque envelope signature verification failed")?;

    if body.payload_bytes.len() as u64 != body.original_payload_len {
        bail!("opaque payload length does not match envelope metadata");
    }
    if sha256_array(&body.payload_bytes) != body.payload_sha256 {
        bail!("opaque payload hash does not match envelope metadata");
    }

    Ok(DecryptedOpaquePayload {
        version: body.version,
        envelope_id: body.envelope_id,
        conversation_id: body.conversation_id,
        sender_key_id: body.sender_key_id,
        recipient_key_id: body.recipient_key_id,
        created_at_unix_ms: body.created_at_unix_ms,
        message_counter: body.message_counter,
        payload_kind: body.payload_kind,
        mime: body.mime,
        filename: body.filename,
        payload_bytes: body.payload_bytes,
    })
}

pub fn decrypt_opaque_text(
    recipient: &Identity,
    sender: &Contact,
    envelope_bytes: &[u8],
) -> Result<String> {
    let payload = decrypt_opaque_payload(recipient, sender, envelope_bytes)?;
    if payload.payload_kind != "file" {
        bail!("opaque payload is not a file");
    }
    if payload.mime != "text/plain; charset=utf-8" {
        bail!("opaque payload is not utf-8 text");
    }
    String::from_utf8(payload.payload_bytes).context("opaque text payload is not utf-8")
}

pub fn create_intro_bundle(
    identity: &Identity,
    device_id: impl Into<String>,
    p2p_ticket: Option<String>,
    capabilities: Vec<String>,
    ttl_seconds: u64,
) -> Result<EnvelopeIntroBundle> {
    let created_at_unix_ms = now_unix_ms()?;
    let expires_at_unix_ms =
        created_at_unix_ms + u128::from(ttl_seconds.max(1)).saturating_mul(1000);
    let mut nonce = [0u8; 16];
    OsRng.fill_bytes(&mut nonce);

    let mut bundle = EnvelopeIntroBundle {
        version: ENVELOPE_PROTOCOL_VERSION,
        contact: identity.contact(),
        device_id: device_id.into(),
        p2p_ticket,
        capabilities,
        created_at_unix_ms,
        expires_at_unix_ms,
        nonce: encode_bytes(&nonce),
        signature: String::new(),
    };
    let payload = intro_bundle_signature_payload(&bundle)?;
    let signature = identity.signing_key()?.sign(&payload);
    bundle.signature = encode_bytes(&signature.to_bytes());
    Ok(bundle)
}

pub fn verify_intro_bundle(bundle: &EnvelopeIntroBundle) -> Result<Contact> {
    if bundle.version != ENVELOPE_PROTOCOL_VERSION {
        bail!("unsupported intro bundle version: {}", bundle.version);
    }
    if bundle.expires_at_unix_ms < now_unix_ms()? {
        bail!("intro bundle expired");
    }
    let signature_bytes = decode_array::<64>(&bundle.signature, "intro bundle signature")?;
    let signature = Signature::from_bytes(&signature_bytes);
    let payload = intro_bundle_signature_payload(bundle)?;
    bundle
        .contact
        .verifying_key()?
        .verify(&payload, &signature)
        .context("intro bundle signature verification failed")?;
    Ok(bundle.contact.clone())
}

pub fn create_device_endpoint_update(
    identity: &Identity,
    device_id: impl Into<String>,
    p2p_ticket: impl Into<String>,
    session_id: impl Into<String>,
    device_list_version: u64,
    ttl_seconds: u64,
) -> Result<DeviceEndpointUpdate> {
    let created_at_unix_ms = now_unix_ms()?;
    let expires_at_unix_ms =
        created_at_unix_ms + u128::from(ttl_seconds.max(1)).saturating_mul(1000);
    let mut update = DeviceEndpointUpdate {
        version: ENVELOPE_PROTOCOL_VERSION,
        owner_identity_key_id: identity.public.key_id.clone(),
        device_id: device_id.into(),
        device_list_version,
        p2p_ticket: p2p_ticket.into(),
        session_id: session_id.into(),
        created_at_unix_ms,
        expires_at_unix_ms,
        signature: String::new(),
    };
    sign_device_endpoint_update(identity, &mut update)?;
    Ok(update)
}

pub fn sign_device_endpoint_update(
    identity: &Identity,
    update: &mut DeviceEndpointUpdate,
) -> Result<()> {
    let payload = device_endpoint_update_signature_payload(update)?;
    let signature = identity.signing_key()?.sign(&payload);
    update.signature = encode_bytes(&signature.to_bytes());
    Ok(())
}

pub fn verify_device_endpoint_update(
    owner_contact: &Contact,
    update: &DeviceEndpointUpdate,
) -> Result<()> {
    verify_device_endpoint_update_at(owner_contact, update, now_unix_ms()?)
}

pub fn verify_device_endpoint_update_at(
    owner_contact: &Contact,
    update: &DeviceEndpointUpdate,
    now_unix_ms: u128,
) -> Result<()> {
    if update.version != ENVELOPE_PROTOCOL_VERSION {
        bail!(
            "unsupported device endpoint update version: {}",
            update.version
        );
    }
    if update.owner_identity_key_id != owner_contact.key_id {
        bail!("device endpoint update owner does not match contact");
    }
    if update.expires_at_unix_ms < now_unix_ms {
        bail!("device endpoint update expired");
    }
    let signature_bytes =
        decode_array::<64>(&update.signature, "device endpoint update signature")?;
    let signature = Signature::from_bytes(&signature_bytes);
    let payload = device_endpoint_update_signature_payload(update)?;
    owner_contact
        .verifying_key()?
        .verify(&payload, &signature)
        .context("device endpoint update signature verification failed")?;
    Ok(())
}

pub fn sign_context_payload(identity: &Identity, context: &str, payload: &[u8]) -> Result<String> {
    sign_context_payload_with_secret(&identity.signing_secret, context, payload)
}

pub fn sign_context_payload_with_secret(
    signing_secret: &str,
    context: &str,
    payload: &[u8],
) -> Result<String> {
    let signed_payload = context_bound_payload(context, payload)?;
    let signature =
        signing_key_from_secret(signing_secret, "signing_secret")?.sign(&signed_payload);
    Ok(encode_bytes(&signature.to_bytes()))
}

pub fn signing_public_from_secret(signing_secret: &str) -> Result<String> {
    let signing_key = signing_key_from_secret(signing_secret, "signing_secret")?;
    Ok(encode_bytes(&signing_key.verifying_key().to_bytes()))
}

pub fn verify_contact_signature(
    contact: &Contact,
    context: &str,
    payload: &[u8],
    signature: &str,
) -> Result<()> {
    let signature_bytes = decode_array::<64>(signature, "signature")?;
    let signature = Signature::from_bytes(&signature_bytes);
    let signed_payload = context_bound_payload(context, payload)?;
    contact
        .verifying_key()?
        .verify(&signed_payload, &signature)
        .context("signature verification failed")?;
    Ok(())
}

pub fn verify_context_payload_with_public(
    signing_public: &str,
    context: &str,
    payload: &[u8],
    signature: &str,
) -> Result<()> {
    let signature_bytes = decode_array::<64>(signature, "signature")?;
    let signature = Signature::from_bytes(&signature_bytes);
    let signed_payload = context_bound_payload(context, payload)?;
    verifying_key_from_public(signing_public, "signing_public")?
        .verify(&signed_payload, &signature)
        .context("signature verification failed")?;
    Ok(())
}

pub fn derive_zip_password(
    local_identity: &Identity,
    remote_contact: &Contact,
    bundle_id: &str,
) -> Result<String> {
    let local_secret = local_identity.agreement_secret()?;
    let remote_public = remote_contact.agreement_public()?;
    let shared_secret = local_secret.diffie_hellman(&remote_public);

    let mut salt_hasher = Sha256::new();
    salt_hasher.update(b"envelope zip bundle salt v1");
    salt_hasher.update(bundle_id.as_bytes());
    salt_hasher.update(conversation_id(
        &local_identity.public.key_id,
        &remote_contact.key_id,
    ));
    let salt = salt_hasher.finalize();

    let hk = Hkdf::<Sha256>::new(Some(&salt), shared_secret.as_bytes());
    let mut password = [0u8; 32];
    hk.expand(b"envelope zip bundle password v1", &mut password)
        .map_err(|_| anyhow::anyhow!("derive zip password"))?;
    Ok(encode_bytes(&password))
}

pub fn conversation_id(a_key_id: &str, b_key_id: &str) -> String {
    let mut ids = [a_key_id, b_key_id];
    ids.sort_unstable();

    let mut hasher = Sha256::new();
    hasher.update(b"envelope conversation v1");
    hasher.update(ids[0].as_bytes());
    hasher.update(ids[1].as_bytes());
    hex::encode(hasher.finalize())
}

pub fn to_pretty_json<T: Serialize>(value: &T) -> Result<String> {
    serde_json::to_string_pretty(value).context("serialize json")
}

pub fn to_json<T: Serialize>(value: &T) -> Result<String> {
    serde_json::to_string(value).context("serialize json")
}

pub fn from_json_slice<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T> {
    serde_json::from_slice(bytes).context("parse json")
}

pub fn encode_bytes(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub fn decode_bytes(encoded: &str, field: &str) -> Result<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(encoded)
        .with_context(|| format!("invalid base64 field {field}"))
}

fn decode_array<const N: usize>(encoded: &str, field: &str) -> Result<[u8; N]> {
    let bytes = decode_bytes(encoded, field)?;
    bytes
        .try_into()
        .map_err(|bytes: Vec<u8>| anyhow::anyhow!("{field} must be {N} bytes, got {}", bytes.len()))
}

fn signing_key_from_secret(signing_secret: &str, field: &str) -> Result<SigningKey> {
    let secret = decode_array::<32>(signing_secret, field)?;
    Ok(SigningKey::from_bytes(&secret))
}

fn verifying_key_from_public(signing_public: &str, field: &str) -> Result<VerifyingKey> {
    let key = decode_array::<32>(signing_public, field)?;
    VerifyingKey::from_bytes(&key).context("invalid Ed25519 verifying key")
}

fn public_key_id(signing_public: &[u8; 32], agreement_public: &[u8; 32]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"envelope public key id v1");
    hasher.update(signing_public);
    hasher.update(agreement_public);
    hex::encode(&hasher.finalize()[..16])
}

fn derive_opaque_envelope_key(
    shared_secret: &[u8; 32],
    ephemeral_public: &[u8; 32],
    recipient_public: &[u8; 32],
) -> Result<[u8; 32]> {
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(b"envelope opaque envelope salt v1");
    salt_hasher.update(ephemeral_public);
    salt_hasher.update(recipient_public);
    let salt = salt_hasher.finalize();

    let hk = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut key = [0u8; 32];
    hk.expand(b"envelope opaque envelope key v1", &mut key)
        .map_err(|_| anyhow::anyhow!("derive opaque envelope key"))?;
    Ok(key)
}

fn derive_opaque_envelope_nonce(
    ephemeral_public: &[u8; 32],
    recipient_public: &[u8; 32],
) -> [u8; 24] {
    let mut hasher = Sha256::new();
    hasher.update(b"envelope opaque envelope nonce v1");
    hasher.update(ephemeral_public);
    hasher.update(recipient_public);
    let digest = hasher.finalize();

    let mut nonce = [0u8; 24];
    nonce.copy_from_slice(&digest[..24]);
    nonce
}

fn derive_recovery_secret(seed: &[u8], context: &str) -> Result<[u8; 32]> {
    let hk = Hkdf::<Sha256>::new(Some(b"envelope recovery seed v1"), seed);
    let mut key = [0u8; 32];
    hk.expand(context.as_bytes(), &mut key)
        .map_err(|_| anyhow::anyhow!("derive recovery secret for {context}"))?;
    Ok(key)
}

fn opaque_signature_payload(body: &OpaqueEnvelopeBody) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(b"envelope opaque envelope signature payload v1");
    write_u16(&mut out, body.version);
    write_string(&mut out, &body.scheme)?;
    write_string(&mut out, &body.envelope_id)?;
    write_string(&mut out, &body.conversation_id)?;
    write_string(&mut out, &body.sender_key_id)?;
    write_string(&mut out, &body.recipient_key_id)?;
    write_u128(&mut out, body.created_at_unix_ms);
    write_u64(&mut out, body.message_counter);
    write_string(&mut out, &body.payload_kind)?;
    write_string(&mut out, &body.mime)?;
    write_optional_string(&mut out, &body.filename)?;
    write_u64(&mut out, body.original_payload_len);
    out.extend_from_slice(&body.payload_sha256);
    Ok(out)
}

fn apply_opaque_padding(body: &mut OpaqueEnvelopeBody) -> Result<()> {
    body.padding.clear();
    let current_len = encode_opaque_body(body)?.len();
    let target_len = opaque_padding_target_len(current_len);
    if current_len < target_len {
        body.padding.resize(target_len - current_len, 0);
        OsRng.fill_bytes(&mut body.padding);
    }
    Ok(())
}

fn encode_opaque_body(body: &OpaqueEnvelopeBody) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    write_u16(&mut out, body.version);
    write_string(&mut out, &body.scheme)?;
    write_string(&mut out, &body.envelope_id)?;
    write_string(&mut out, &body.conversation_id)?;
    write_string(&mut out, &body.sender_key_id)?;
    write_string(&mut out, &body.recipient_key_id)?;
    write_u128(&mut out, body.created_at_unix_ms);
    write_u64(&mut out, body.message_counter);
    write_string(&mut out, &body.payload_kind)?;
    write_string(&mut out, &body.mime)?;
    write_optional_string(&mut out, &body.filename)?;
    write_u64(&mut out, body.original_payload_len);
    out.extend_from_slice(&body.payload_sha256);
    write_bytes(&mut out, &body.payload_bytes)?;
    write_bytes(&mut out, &body.padding)?;
    out.extend_from_slice(&body.signature);
    Ok(out)
}

fn decode_opaque_body(bytes: &[u8]) -> Result<OpaqueEnvelopeBody> {
    let mut reader = ByteReader::new(bytes);
    let version = reader.read_u16()?;
    let scheme = reader.read_string()?;
    let envelope_id = reader.read_string()?;
    let conversation_id = reader.read_string()?;
    let sender_key_id = reader.read_string()?;
    let recipient_key_id = reader.read_string()?;
    let created_at_unix_ms = reader.read_u128()?;
    let message_counter = reader.read_u64()?;
    let payload_kind = reader.read_string()?;
    let mime = reader.read_string()?;
    let filename = reader.read_optional_string()?;
    let original_payload_len = reader.read_u64()?;
    let payload_sha256 = reader.read_array::<32>()?;
    let payload_bytes = reader.read_bytes()?;
    let padding = reader.read_bytes()?;
    let signature = reader.read_array::<64>()?;
    reader.finish()?;
    Ok(OpaqueEnvelopeBody {
        version,
        scheme,
        envelope_id,
        conversation_id,
        sender_key_id,
        recipient_key_id,
        created_at_unix_ms,
        message_counter,
        payload_kind,
        mime,
        filename,
        original_payload_len,
        payload_sha256,
        payload_bytes,
        padding,
        signature,
    })
}

fn opaque_padding_target_len(len: usize) -> usize {
    const KIB: usize = 1024;
    const MIB: usize = 1024 * KIB;

    if len <= 512 {
        512
    } else if len <= 4 * KIB {
        4 * KIB
    } else if len <= 64 * KIB {
        64 * KIB
    } else if len <= MIB {
        round_up_to(len, 64 * KIB)
    } else {
        round_up_to(len, MIB)
    }
}

fn round_up_to(len: usize, block: usize) -> usize {
    len.checked_add(block - 1)
        .map(|value| value / block * block)
        .unwrap_or(usize::MAX)
}

fn write_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn write_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn write_u128(out: &mut Vec<u8>, value: u128) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn write_string(out: &mut Vec<u8>, value: &str) -> Result<()> {
    write_bytes(out, value.as_bytes())
}

fn write_optional_string(out: &mut Vec<u8>, value: &Option<String>) -> Result<()> {
    match value {
        Some(value) => {
            out.push(1);
            write_string(out, value)?;
        }
        None => out.push(0),
    }
    Ok(())
}

fn write_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u64::try_from(value.len()).context("field length does not fit u64")?;
    write_u64(out, len);
    out.extend_from_slice(value);
    Ok(())
}

struct ByteReader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> ByteReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, cursor: 0 }
    }

    fn read_u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.read_array::<2>()?))
    }

    fn read_u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.read_array::<8>()?))
    }

    fn read_u128(&mut self) -> Result<u128> {
        Ok(u128::from_be_bytes(self.read_array::<16>()?))
    }

    fn read_string(&mut self) -> Result<String> {
        String::from_utf8(self.read_bytes()?).context("opaque envelope string field is not utf-8")
    }

    fn read_optional_string(&mut self) -> Result<Option<String>> {
        let tag = self.read_exact(1)?[0];
        match tag {
            0 => Ok(None),
            1 => Ok(Some(self.read_string()?)),
            _ => bail!("invalid optional string tag {tag}"),
        }
    }

    fn read_bytes(&mut self) -> Result<Vec<u8>> {
        let len = self.read_u64()?;
        let len: usize = len
            .try_into()
            .context("opaque envelope field length does not fit usize")?;
        Ok(self.read_exact(len)?.to_vec())
    }

    fn read_array<const N: usize>(&mut self) -> Result<[u8; N]> {
        let bytes = self.read_exact(N)?;
        let mut out = [0u8; N];
        out.copy_from_slice(bytes);
        Ok(out)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .cursor
            .checked_add(len)
            .context("opaque envelope field length overflow")?;
        if end > self.bytes.len() {
            bail!("opaque envelope body ended unexpectedly");
        }
        let bytes = &self.bytes[self.cursor..end];
        self.cursor = end;
        Ok(bytes)
    }

    fn finish(&self) -> Result<()> {
        if self.cursor != self.bytes.len() {
            bail!("opaque envelope body has trailing bytes");
        }
        Ok(())
    }
}

fn opaque_envelope_aad(ephemeral_public: &[u8; 32]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(OPAQUE_OFFLINE_ENVELOPE_AAD_CONTEXT.len() + 32);
    aad.extend_from_slice(OPAQUE_OFFLINE_ENVELOPE_AAD_CONTEXT);
    aad.extend_from_slice(ephemeral_public);
    aad
}

fn device_endpoint_update_signature_payload(update: &DeviceEndpointUpdate) -> Result<Vec<u8>> {
    let payload = DeviceEndpointUpdateSigningPayload {
        version: update.version,
        owner_identity_key_id: &update.owner_identity_key_id,
        device_id: &update.device_id,
        device_list_version: update.device_list_version,
        p2p_ticket: &update.p2p_ticket,
        session_id: &update.session_id,
        created_at_unix_ms: update.created_at_unix_ms,
        expires_at_unix_ms: update.expires_at_unix_ms,
    };
    let mut out = b"envelope device endpoint update signature payload v1".to_vec();
    out.extend_from_slice(
        &serde_json::to_vec(&payload).context("serialize device endpoint update payload")?,
    );
    Ok(out)
}

fn context_bound_payload(context: &str, payload: &[u8]) -> Result<Vec<u8>> {
    if context.is_empty() {
        bail!("signature context must not be empty");
    }
    let mut out = b"envelope context-bound signature payload v1".to_vec();
    write_string(&mut out, context)?;
    write_bytes(&mut out, payload)?;
    Ok(out)
}

fn sha256_array(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn intro_bundle_signature_payload(bundle: &EnvelopeIntroBundle) -> Result<Vec<u8>> {
    let payload = EnvelopeIntroBundleSigningPayload {
        version: bundle.version,
        contact: &bundle.contact,
        device_id: &bundle.device_id,
        p2p_ticket: &bundle.p2p_ticket,
        capabilities: &bundle.capabilities,
        created_at_unix_ms: bundle.created_at_unix_ms,
        expires_at_unix_ms: bundle.expires_at_unix_ms,
        nonce: &bundle.nonce,
    };
    serde_json::to_vec(&payload).context("serialize intro bundle signature payload")
}

fn now_unix_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time is before unix epoch")?
        .as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opaque_text_round_trip() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");

        let envelope = encrypt_opaque_text(&alice, &bob.contact(), "hello opaque", 7).unwrap();
        let text = decrypt_opaque_text(&bob, &alice.contact(), &envelope.envelope_bytes).unwrap();

        assert_eq!(text, "hello opaque");
        assert_eq!(envelope.version, OPAQUE_OFFLINE_ENVELOPE_VERSION);
        assert_eq!(envelope.sender_key_id, alice.public.key_id);
        assert_eq!(envelope.recipient_key_id, bob.public.key_id);
        assert_eq!(
            envelope.envelope_bytes.len(),
            OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES + 512 + 16
        );
    }

    #[test]
    fn opaque_payload_round_trip_with_file_metadata() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let bytes = b"fake image bytes";

        let envelope = encrypt_opaque_payload(
            &alice,
            &bob.contact(),
            "file",
            "image/png",
            Some("photo.png".to_string()),
            bytes,
            8,
        )
        .unwrap();
        let payload =
            decrypt_opaque_payload(&bob, &alice.contact(), &envelope.envelope_bytes).unwrap();

        assert_eq!(payload.payload_kind, "file");
        assert_eq!(payload.mime, "image/png");
        assert_eq!(payload.filename.as_deref(), Some("photo.png"));
        assert_eq!(payload.payload_bytes.as_slice(), bytes);
        assert_eq!(payload.sender_key_id, alice.public.key_id);
        assert_eq!(payload.recipient_key_id, bob.public.key_id);
    }

    #[test]
    fn opaque_envelope_does_not_expose_key_ids_as_plaintext() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");

        let envelope = encrypt_opaque_text(&alice, &bob.contact(), "hidden metadata", 1).unwrap();
        let lossy = String::from_utf8_lossy(&envelope.envelope_bytes);

        assert!(!lossy.contains(&alice.public.key_id));
        assert!(!lossy.contains(&bob.public.key_id));
    }

    #[test]
    fn opaque_envelope_rejects_tampering() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let mut envelope = encrypt_opaque_text(&alice, &bob.contact(), "tamper me", 1)
            .unwrap()
            .envelope_bytes;
        let last = envelope.len() - 1;
        envelope[last] ^= 0x01;

        assert!(decrypt_opaque_text(&bob, &alice.contact(), &envelope).is_err());
    }

    #[test]
    fn opaque_envelope_rejects_wrong_recipient() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let charlie = Identity::generate("Charlie");

        let envelope = encrypt_opaque_text(&alice, &bob.contact(), "for Bob only", 1).unwrap();

        assert!(decrypt_opaque_text(&charlie, &alice.contact(), &envelope.envelope_bytes).is_err());
    }

    #[test]
    fn opaque_padding_target_len_uses_documented_buckets() {
        assert_eq!(opaque_padding_target_len(1), 512);
        assert_eq!(opaque_padding_target_len(512), 512);
        assert_eq!(opaque_padding_target_len(513), 4 * 1024);
        assert_eq!(opaque_padding_target_len(4 * 1024), 4 * 1024);
        assert_eq!(opaque_padding_target_len(4 * 1024 + 1), 64 * 1024);
        assert_eq!(opaque_padding_target_len(64 * 1024), 64 * 1024);
        assert_eq!(opaque_padding_target_len(64 * 1024 + 1), 128 * 1024);
        assert_eq!(opaque_padding_target_len(1024 * 1024 + 1), 2 * 1024 * 1024);
    }

    #[test]
    fn intro_bundle_signature_round_trip() {
        let alice = Identity::generate("Alice");
        let bundle = create_intro_bundle(
            &alice,
            "android-test-device",
            Some("ticket-test".to_string()),
            vec!["contact.v1".to_string(), "qr.v1".to_string()],
            300,
        )
        .unwrap();
        let contact = verify_intro_bundle(&bundle).unwrap();
        assert_eq!(contact.key_id, alice.public.key_id);
        assert_eq!(bundle.p2p_ticket.as_deref(), Some("ticket-test"));
    }

    #[test]
    fn zip_password_is_symmetric() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let bundle_id = Uuid::new_v4().to_string();

        let alice_password = derive_zip_password(&alice, &bob.contact(), &bundle_id).unwrap();
        let bob_password = derive_zip_password(&bob, &alice.contact(), &bundle_id).unwrap();

        assert_eq!(alice_password, bob_password);
    }

    #[test]
    fn recovery_phrase_has_24_words() {
        let phrase = generate_recovery_phrase().unwrap();
        assert_eq!(phrase.split_whitespace().count(), RECOVERY_WORD_COUNT);
    }

    #[test]
    fn recovery_phrase_derives_stable_identity() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";

        let first = identity_from_recovery_phrase("Alice", phrase).unwrap();
        let second = identity_from_recovery_phrase("Alice Again", phrase).unwrap();

        assert_eq!(first.public.key_id, second.public.key_id);
        assert_eq!(first.signing_secret, second.signing_secret);
        assert_eq!(first.agreement_secret, second.agreement_secret);
        assert_eq!(first.display_name, "Alice");
        assert_eq!(second.display_name, "Alice Again");
    }

    #[test]
    fn local_backup_round_trip_uses_recovery_phrase() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";
        let other_phrase = "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title";
        let plaintext = br#"{"version":1,"display_name":"Alice"}"#;

        let encrypted = encrypt_local_backup(phrase, plaintext).unwrap();
        assert!(encrypted.contains(LOCAL_BACKUP_SCHEME));

        let decrypted = decrypt_local_backup(phrase, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
        assert!(decrypt_local_backup(other_phrase, &encrypted).is_err());
    }

    #[test]
    fn protocol_control_records_serialize() {
        let record = DeviceRecord {
            version: ENVELOPE_PROTOCOL_VERSION,
            device_id: "device-1".to_string(),
            device_type: DeviceType::Android,
            device_display_name: "Alice phone".to_string(),
            device_public_key: "pub".to_string(),
            capabilities: vec!["p2p.v1".to_string()],
            added_at_unix_ms: 1,
            expires_at_unix_ms: None,
            status: DeviceStatus::Active,
        };
        let list = DeviceList {
            version: ENVELOPE_PROTOCOL_VERSION,
            owner_identity_key_id: "owner".to_string(),
            authorizer_key_id: "owner".to_string(),
            authorizer_type: AuthorizerType::MobileMain,
            device_list_version: 1,
            devices: vec![record],
            signature: "sig".to_string(),
        };

        let json = serde_json::to_string(&list).unwrap();
        assert!(json.contains("mobile_main"));
        assert!(json.contains("android"));
    }

    #[test]
    fn device_endpoint_update_signature_round_trip() {
        let alice = Identity::generate("Alice");
        let update =
            create_device_endpoint_update(&alice, "phone-1", "ticket", "session-1", 1, 60).unwrap();

        verify_device_endpoint_update(&alice.contact(), &update).unwrap();

        let bob = Identity::generate("Bob");
        assert!(verify_device_endpoint_update(&bob.contact(), &update).is_err());
    }

    #[test]
    fn context_signature_is_bound_to_context() {
        let alice = Identity::generate("Alice");
        let payload = br#"{"hello":"server"}"#;
        let signature = sign_context_payload(&alice, "envelope test context v1", payload).unwrap();

        verify_contact_signature(
            &alice.contact(),
            "envelope test context v1",
            payload,
            &signature,
        )
        .unwrap();
        assert!(
            verify_contact_signature(&alice.contact(), "other context", payload, &signature)
                .is_err()
        );
    }

    #[test]
    fn raw_context_signature_round_trips() {
        let identity = Identity::generate("node-a");
        let payload = br#"{"node_id":"node-a","challenge":"abc"}"#;
        let signing_public = signing_public_from_secret(&identity.signing_secret).unwrap();
        assert_eq!(signing_public, identity.public.signing_public);

        let signature = sign_context_payload_with_secret(
            &identity.signing_secret,
            "envelope test raw context v1",
            payload,
        )
        .unwrap();

        verify_context_payload_with_public(
            &signing_public,
            "envelope test raw context v1",
            payload,
            &signature,
        )
        .unwrap();
        assert!(
            verify_context_payload_with_public(
                &signing_public,
                "other context",
                payload,
                &signature
            )
            .is_err()
        );
    }
}
