use envelope_core::{Contact, DecryptedOpaquePayload, EncryptedOpaquePayload, Identity};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

const STORE_FILE: &str = "store.json";
const STORE_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoreState {
    pub version: u16,
    pub identity: Identity,
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub next_message_counter: u64,
    pub received_envelopes: Vec<ReceivedEnvelope>,
    #[serde(default)]
    pub sent_envelopes: Vec<SentEnvelope>,
    pub messages: Vec<StoredMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceivedEnvelope {
    pub envelope_id: String,
    pub sender_key_id: String,
    pub message_counter: u64,
    pub imported_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SentEnvelope {
    pub envelope_id: String,
    pub recipient_key_id: String,
    pub message_counter: u64,
    pub sent_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub envelope_id: String,
    pub conversation_id: String,
    pub sender_key_id: String,
    pub sender_display_name: String,
    pub recipient_key_id: String,
    pub created_at_unix_ms: u128,
    pub imported_at_unix_ms: u128,
    pub message_counter: u64,
    pub payload_type: String,
    pub text: String,
    #[serde(default = "default_incoming_direction")]
    pub direction: MessageDirection,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MessageDirection {
    #[default]
    Incoming,
    Outgoing,
}

#[derive(Debug, Clone)]
pub enum ImportOutcome {
    Imported(StoredMessage),
    Duplicate {
        envelope_id: String,
    },
    Replay {
        sender_key_id: String,
        message_counter: u64,
    },
}

#[derive(Debug, Clone)]
pub struct OutboundMessage {
    pub recipient: Contact,
    pub envelope: EncryptedOpaquePayload,
    pub message: StoredMessage,
}

#[derive(Debug)]
pub struct LocalStore {
    dir: PathBuf,
    state: StoreState,
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("store already exists at {0}")]
    AlreadyExists(PathBuf),
    #[error("store does not exist at {0}")]
    Missing(PathBuf),
    #[error("unknown sender key id {0}")]
    UnknownSender(String),
    #[error("unknown recipient {0}")]
    UnknownRecipient(String),
    #[error("opaque envelope could not be decrypted with any known contact: {0}")]
    NoDecryptingContact(String),
    #[error("invalid opaque envelope: {0}")]
    InvalidEnvelope(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("crypto error: {0}")]
    Crypto(#[from] anyhow::Error),
    #[error("system time is before unix epoch")]
    InvalidSystemTime,
}

pub type Result<T> = std::result::Result<T, StoreError>;

impl LocalStore {
    pub fn init(dir: impl AsRef<Path>, display_name: impl Into<String>) -> Result<Self> {
        Self::init_with_identity(dir, Identity::generate(display_name))
    }

    pub fn init_with_identity(dir: impl AsRef<Path>, identity: Identity) -> Result<Self> {
        let dir = dir.as_ref().to_path_buf();
        let path = store_path(&dir);
        if path.exists() {
            return Err(StoreError::AlreadyExists(path));
        }

        fs::create_dir_all(&dir)?;
        let state = StoreState {
            version: STORE_VERSION,
            identity,
            contacts: Vec::new(),
            next_message_counter: 1,
            received_envelopes: Vec::new(),
            sent_envelopes: Vec::new(),
            messages: Vec::new(),
        };
        let store = Self { dir, state };
        store.save()?;
        Ok(store)
    }

    pub fn open(dir: impl AsRef<Path>) -> Result<Self> {
        let dir = dir.as_ref().to_path_buf();
        let path = store_path(&dir);
        if !path.exists() {
            return Err(StoreError::Missing(path));
        }

        let bytes = fs::read(&path)?;
        let state = serde_json::from_slice(&bytes)?;
        Ok(Self { dir, state })
    }

    pub fn identity(&self) -> &Identity {
        &self.state.identity
    }

    pub fn contact(&self) -> Contact {
        self.state.identity.contact()
    }

    pub fn contacts(&self) -> &[Contact] {
        &self.state.contacts
    }

    pub fn messages(&self) -> &[StoredMessage] {
        &self.state.messages
    }

    pub fn find_contact(&self, query: &str) -> Option<&Contact> {
        self.state.contacts.iter().find(|contact| {
            contact.key_id == query || contact.display_name.eq_ignore_ascii_case(query)
        })
    }

    pub fn add_contact(&mut self, contact: Contact) -> Result<bool> {
        if let Some(existing) = self
            .state
            .contacts
            .iter_mut()
            .find(|item| item.key_id == contact.key_id)
        {
            *existing = contact;
            self.save()?;
            return Ok(false);
        }

        self.state.contacts.push(contact);
        self.state
            .contacts
            .sort_by(|a, b| a.display_name.cmp(&b.display_name));
        self.save()?;
        Ok(true)
    }

    pub fn import_opaque_envelope(&mut self, envelope_bytes: &[u8]) -> Result<ImportOutcome> {
        let (sender, payload) = self.decrypt_from_known_sender(envelope_bytes)?;
        if self
            .state
            .received_envelopes
            .iter()
            .any(|item| item.envelope_id == payload.envelope_id)
        {
            return Ok(ImportOutcome::Duplicate {
                envelope_id: payload.envelope_id,
            });
        }
        if self.state.received_envelopes.iter().any(|item| {
            item.sender_key_id == payload.sender_key_id
                && item.message_counter == payload.message_counter
        }) {
            return Ok(ImportOutcome::Replay {
                sender_key_id: payload.sender_key_id,
                message_counter: payload.message_counter,
            });
        }

        let text = payload_text(&payload)?;
        let imported_at_unix_ms = now_unix_ms()?;
        let message = StoredMessage {
            envelope_id: payload.envelope_id.clone(),
            conversation_id: payload.conversation_id.clone(),
            sender_key_id: payload.sender_key_id.clone(),
            sender_display_name: sender.display_name,
            recipient_key_id: payload.recipient_key_id.clone(),
            created_at_unix_ms: payload.created_at_unix_ms,
            imported_at_unix_ms,
            message_counter: payload.message_counter,
            payload_type: payload.payload_kind,
            text,
            direction: MessageDirection::Incoming,
        };

        self.state.received_envelopes.push(ReceivedEnvelope {
            envelope_id: message.envelope_id.clone(),
            sender_key_id: message.sender_key_id.clone(),
            message_counter: message.message_counter,
            imported_at_unix_ms,
        });
        self.state.messages.push(message.clone());
        self.state
            .messages
            .sort_by_key(|message| message.created_at_unix_ms);
        self.save()?;

        Ok(ImportOutcome::Imported(message))
    }

    pub fn create_outbound_text(
        &mut self,
        recipient_query: &str,
        text: &str,
    ) -> Result<OutboundMessage> {
        let recipient = self
            .find_contact(recipient_query)
            .cloned()
            .ok_or_else(|| StoreError::UnknownRecipient(recipient_query.to_string()))?;
        let counter = self.state.next_message_counter.max(1);
        let envelope =
            envelope_core::encrypt_opaque_text(&self.state.identity, &recipient, text, counter)?;
        let sent_at_unix_ms = now_unix_ms()?;
        let message = StoredMessage {
            envelope_id: envelope.envelope_id.clone(),
            conversation_id: envelope.conversation_id.clone(),
            sender_key_id: envelope.sender_key_id.clone(),
            sender_display_name: self.state.identity.display_name.clone(),
            recipient_key_id: envelope.recipient_key_id.clone(),
            created_at_unix_ms: envelope.created_at_unix_ms,
            imported_at_unix_ms: sent_at_unix_ms,
            message_counter: envelope.message_counter,
            payload_type: envelope.payload_kind.clone(),
            text: text.to_string(),
            direction: MessageDirection::Outgoing,
        };

        self.state.next_message_counter = counter + 1;
        self.state.sent_envelopes.push(SentEnvelope {
            envelope_id: message.envelope_id.clone(),
            recipient_key_id: message.recipient_key_id.clone(),
            message_counter: message.message_counter,
            sent_at_unix_ms,
        });
        self.state.messages.push(message.clone());
        self.state
            .messages
            .sort_by_key(|message| message.created_at_unix_ms);
        self.save()?;

        Ok(OutboundMessage {
            recipient,
            envelope,
            message,
        })
    }

    fn decrypt_from_known_sender(
        &self,
        envelope_bytes: &[u8],
    ) -> Result<(Contact, DecryptedOpaquePayload)> {
        let mut last_error = None;
        for contact in &self.state.contacts {
            match envelope_core::decrypt_opaque_payload(
                &self.state.identity,
                contact,
                envelope_bytes,
            ) {
                Ok(payload) => return Ok((contact.clone(), payload)),
                Err(error) => last_error = Some(error.to_string()),
            }
        }
        Err(StoreError::NoDecryptingContact(
            last_error.unwrap_or_else(|| "no contacts in store".to_string()),
        ))
    }

    pub fn save(&self) -> Result<()> {
        fs::create_dir_all(&self.dir)?;
        let json = serde_json::to_string_pretty(&self.state)?;
        fs::write(store_path(&self.dir), json)?;
        Ok(())
    }
}

pub fn store_path(dir: &Path) -> PathBuf {
    dir.join(STORE_FILE)
}

pub fn parse_opaque_envelope(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() <= envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES {
        return Err(StoreError::InvalidEnvelope("file is too short".to_string()));
    }
    Ok(bytes.to_vec())
}

fn payload_text(payload: &DecryptedOpaquePayload) -> Result<String> {
    if payload.payload_kind != "file" {
        return Err(StoreError::InvalidEnvelope(format!(
            "unsupported payload kind {}",
            payload.payload_kind
        )));
    }
    if payload.mime != "text/plain; charset=utf-8" {
        return Err(StoreError::InvalidEnvelope(format!(
            "unsupported payload mime {}",
            payload.mime
        )));
    }
    String::from_utf8(payload.payload_bytes.clone())
        .map_err(|_| StoreError::InvalidEnvelope("payload is not utf-8 text".to_string()))
}

fn default_incoming_direction() -> MessageDirection {
    MessageDirection::Incoming
}

fn now_unix_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| StoreError::InvalidSystemTime)?
        .as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_import_is_detected() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let envelope =
            envelope_core::encrypt_opaque_text(&alice, &bob.contact(), "hello", 1).unwrap();
        let dir = std::env::temp_dir().join(format!(
            "envelope-store-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut store = LocalStore {
            dir: dir.clone(),
            state: StoreState {
                version: STORE_VERSION,
                identity: bob,
                contacts: vec![alice.contact()],
                next_message_counter: 1,
                received_envelopes: Vec::new(),
                sent_envelopes: Vec::new(),
                messages: Vec::new(),
            },
        };

        assert!(matches!(
            store
                .import_opaque_envelope(&envelope.envelope_bytes)
                .unwrap(),
            ImportOutcome::Imported(_)
        ));
        assert!(matches!(
            store
                .import_opaque_envelope(&envelope.envelope_bytes)
                .unwrap(),
            ImportOutcome::Duplicate { .. }
        ));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn reused_message_counter_is_detected() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let first = envelope_core::encrypt_opaque_text(&alice, &bob.contact(), "one", 7).unwrap();
        let replay = envelope_core::encrypt_opaque_text(&alice, &bob.contact(), "two", 7).unwrap();
        let dir = std::env::temp_dir().join(format!(
            "envelope-store-replay-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut store = LocalStore {
            dir: dir.clone(),
            state: StoreState {
                version: STORE_VERSION,
                identity: bob,
                contacts: vec![alice.contact()],
                next_message_counter: 1,
                received_envelopes: Vec::new(),
                sent_envelopes: Vec::new(),
                messages: Vec::new(),
            },
        };

        assert!(matches!(
            store.import_opaque_envelope(&first.envelope_bytes).unwrap(),
            ImportOutcome::Imported(_)
        ));
        assert!(matches!(
            store.import_opaque_envelope(&replay.envelope_bytes).unwrap(),
            ImportOutcome::Replay {
                sender_key_id,
                message_counter: 7,
            } if sender_key_id == alice.public.key_id
        ));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn outbound_message_increments_counter() {
        let alice = Identity::generate("Alice");
        let bob = Identity::generate("Bob");
        let dir = std::env::temp_dir().join(format!(
            "envelope-store-send-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut store = LocalStore {
            dir: dir.clone(),
            state: StoreState {
                version: STORE_VERSION,
                identity: alice,
                contacts: vec![bob.contact()],
                next_message_counter: 1,
                received_envelopes: Vec::new(),
                sent_envelopes: Vec::new(),
                messages: Vec::new(),
            },
        };

        let first = store.create_outbound_text("Bob", "one").unwrap();
        let second = store.create_outbound_text("Bob", "two").unwrap();

        assert_eq!(first.envelope.message_counter, 1);
        assert_eq!(second.envelope.message_counter, 2);
        assert_eq!(store.messages().len(), 2);
        let _ = fs::remove_dir_all(dir);
    }
}
