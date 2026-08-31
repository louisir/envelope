use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
#[cfg(test)]
use envelope_core::decrypt_opaque_payload;
use envelope_core::{Contact, Identity, encrypt_opaque_payload};
use fs2::FileExt;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const PROTOCOL_VERSION: u16 = 1;
const ID_BYTES: usize = 18;
const ID_ENCODED_LEN: usize = 24;
const MAX_REQUEST_BYTES: u64 = 16 * 1024;
const MAX_FUTURE_SECONDS: u64 = 90 * 24 * 60 * 60;
const EXPECTED_ENVELOPE_BYTES: usize = 560;
const CHALLENGE_MAGIC: &[u8; 8] = b"YTCHAL1\0";

#[derive(Debug)]
struct StatePaths {
    root: PathBuf,
    identity: PathBuf,
    public_contact: PathBuf,
    counter: PathBuf,
    lock: PathBuf,
    requests: PathBuf,
}

impl StatePaths {
    fn new(root: PathBuf) -> Self {
        Self {
            identity: root.join("identity.json"),
            public_contact: root.join("public-contact.json"),
            counter: root.join("next-counter"),
            lock: root.join("state.lock"),
            requests: root.join("requests"),
            root,
        }
    }

    fn create_directories(&self) -> Result<()> {
        fs::create_dir_all(&self.requests)
            .with_context(|| format!("create {}", self.requests.display()))?;
        set_directory_mode(&self.root)?;
        set_directory_mode(&self.requests)?;
        Ok(())
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SealRequest {
    version: u16,
    request_id: String,
    challenge_session_id: String,
    recipient_contact: Contact,
    expires_at_unix: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
struct SealResponse {
    version: u16,
    request_id: String,
    envelope_id: String,
    sender_contact: Contact,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    expires_at_unix: u64,
    reply_nonce_sha256: String,
    envelope_sha256: String,
    envelope_length: usize,
    envelope_base64: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct StoredResult {
    input_sha256: String,
    response: SealResponse,
}

#[derive(Debug, Serialize)]
struct PublicStatus {
    version: u16,
    status: &'static str,
    public_contact: Contact,
    next_counter: u64,
    completed_requests: usize,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("yourturn-robot: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = env::args_os();
    let _program = args.next();
    let command = args
        .next()
        .and_then(|value| value.into_string().ok())
        .context("usage: yourturn-robot <init|seal|status> <state-dir>")?;
    let state_dir = args
        .next()
        .map(PathBuf::from)
        .context("usage: yourturn-robot <init|seal|status> <state-dir>")?;
    if args.next().is_some() {
        bail!("usage: yourturn-robot <init|seal|status> <state-dir>");
    }
    let paths = StatePaths::new(state_dir);
    match command.as_str() {
        "init" => initialize(&paths),
        "seal" => seal_from_stdin(&paths),
        "status" => status(&paths),
        _ => bail!("unknown command; expected init, seal, or status"),
    }
}

fn initialize(paths: &StatePaths) -> Result<()> {
    paths.create_directories()?;
    let lock = open_lock(paths)?;
    lock.lock_exclusive().context("lock robot state")?;

    let identity = if paths.identity.exists() {
        load_identity(paths)?
    } else {
        let identity = Identity::generate("YourTurn persistent robot");
        identity.validate()?;
        atomic_write_json(&paths.identity, &identity)?;
        atomic_write_json(&paths.public_contact, &identity.contact())?;
        identity
    };
    if !paths.counter.exists() {
        atomic_write(&paths.counter, b"1\n")?;
    }
    let next_counter = read_counter(paths)?;
    let completed_requests = completed_request_count(paths)?;
    write_json_stdout(&PublicStatus {
        version: PROTOCOL_VERSION,
        status: "ready",
        public_contact: identity.contact(),
        next_counter,
        completed_requests,
    })
}

fn status(paths: &StatePaths) -> Result<()> {
    let lock = open_lock(paths)?;
    lock.lock_shared().context("lock robot state")?;
    let identity = load_identity(paths)?;
    write_json_stdout(&PublicStatus {
        version: PROTOCOL_VERSION,
        status: "ready",
        public_contact: identity.contact(),
        next_counter: read_counter(paths)?,
        completed_requests: completed_request_count(paths)?,
    })
}

fn seal_from_stdin(paths: &StatePaths) -> Result<()> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(MAX_REQUEST_BYTES + 1)
        .read_to_end(&mut bytes)
        .context("read request")?;
    if bytes.len() as u64 > MAX_REQUEST_BYTES {
        bail!("request is too large");
    }
    let request: SealRequest = serde_json::from_slice(&bytes).context("parse request JSON")?;
    let response = seal(paths, request)?;
    write_json_stdout(&response)
}

fn seal(paths: &StatePaths, request: SealRequest) -> Result<SealResponse> {
    validate_id("request_id", &request.request_id)?;
    validate_id("challenge_session_id", &request.challenge_session_id)?;
    if request.version != PROTOCOL_VERSION {
        bail!("unsupported request version");
    }
    request.recipient_contact.validate()?;
    let request_bytes = serde_json::to_vec(&request).context("serialize canonical request")?;
    let input_sha256 = sha256_hex(&request_bytes);
    let request_path = paths.requests.join(format!(
        "{}.json",
        sha256_hex(request.request_id.as_bytes())
    ));

    let lock = open_lock(paths)?;
    lock.lock_exclusive().context("lock robot state")?;
    if request_path.exists() {
        let stored: StoredResult = read_json(&request_path)?;
        if stored.input_sha256 != input_sha256 {
            bail!("request_id was already used with different input");
        }
        return Ok(stored.response);
    }

    let now = now_unix_seconds()?;
    if request.expires_at_unix <= now {
        bail!("challenge expiry must be in the future");
    }
    if request.expires_at_unix - now > MAX_FUTURE_SECONDS {
        bail!("challenge expiry is too far in the future");
    }

    let identity = load_identity(paths)?;
    let message_counter = read_counter(paths)?;
    let next_counter = message_counter
        .checked_add(1)
        .context("message counter exhausted")?;
    atomic_write(&paths.counter, format!("{next_counter}\n").as_bytes())?;

    let mut reply_nonce = [0u8; 24];
    OsRng.fill_bytes(&mut reply_nonce);
    let payload = challenge_payload(&request, &reply_nonce)?;
    let encrypted = encrypt_opaque_payload(
        &identity,
        &request.recipient_contact,
        "challenge",
        "application/octet-stream",
        None,
        &payload,
        message_counter,
    )?;
    if encrypted.envelope_bytes.len() != EXPECTED_ENVELOPE_BYTES {
        bail!(
            "unexpected Envelope size {}; expected {EXPECTED_ENVELOPE_BYTES}",
            encrypted.envelope_bytes.len()
        );
    }
    let response = SealResponse {
        version: PROTOCOL_VERSION,
        request_id: request.request_id,
        envelope_id: encrypted.envelope_id,
        sender_contact: identity.contact(),
        recipient_key_id: encrypted.recipient_key_id,
        created_at_unix_ms: encrypted.created_at_unix_ms,
        message_counter,
        expires_at_unix: request.expires_at_unix,
        reply_nonce_sha256: sha256_hex(&reply_nonce),
        envelope_sha256: sha256_hex(&encrypted.envelope_bytes),
        envelope_length: encrypted.envelope_bytes.len(),
        envelope_base64: STANDARD.encode(&encrypted.envelope_bytes),
    };
    let stored = StoredResult {
        input_sha256,
        response: response.clone(),
    };
    atomic_write_json(&request_path, &stored)?;
    Ok(response)
}

fn challenge_payload(request: &SealRequest, reply_nonce: &[u8; 24]) -> Result<Vec<u8>> {
    let challenge_id = decode_id("challenge_session_id", &request.challenge_session_id)?;
    let mut payload = Vec::with_capacity(60);
    payload.extend_from_slice(CHALLENGE_MAGIC);
    payload.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
    payload.extend_from_slice(&challenge_id);
    payload.extend_from_slice(reply_nonce);
    payload.extend_from_slice(&request.expires_at_unix.to_be_bytes());
    Ok(payload)
}

fn validate_id(field: &str, value: &str) -> Result<()> {
    if value.len() != ID_ENCODED_LEN
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        bail!("{field} must be a {ID_ENCODED_LEN}-character base64url identifier");
    }
    let _ = decode_id(field, value)?;
    Ok(())
}

fn decode_id(field: &str, value: &str) -> Result<[u8; ID_BYTES]> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .with_context(|| format!("decode {field}"))?;
    decoded
        .try_into()
        .map_err(|bytes: Vec<u8>| anyhow::anyhow!("{field} decoded to {} bytes", bytes.len()))
}

fn open_lock(paths: &StatePaths) -> Result<File> {
    if !paths.root.is_dir() {
        bail!("robot state is not initialized: {}", paths.root.display());
    }
    open_private_file(&paths.lock, true)
}

fn load_identity(paths: &StatePaths) -> Result<Identity> {
    let identity: Identity = read_json(&paths.identity)?;
    identity
        .validate()
        .context("validate persistent identity")?;
    Ok(identity)
}

fn read_counter(paths: &StatePaths) -> Result<u64> {
    let text = fs::read_to_string(&paths.counter)
        .with_context(|| format!("read {}", paths.counter.display()))?;
    let value = text
        .trim()
        .parse::<u64>()
        .context("parse next message counter")?;
    if value == 0 {
        bail!("next message counter must be positive");
    }
    Ok(value)
}

fn completed_request_count(paths: &StatePaths) -> Result<usize> {
    Ok(fs::read_dir(&paths.requests)
        .with_context(|| format!("read {}", paths.requests.display()))?
        .filter_map(std::result::Result::ok)
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("json"))
        .count())
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))
}

fn atomic_write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let mut bytes = serde_json::to_vec(value).context("serialize JSON")?;
    bytes.push(b'\n');
    atomic_write(path, &bytes)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("state file has no parent")?;
    let mut suffix = [0u8; 8];
    OsRng.fill_bytes(&mut suffix);
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .context("invalid state filename")?;
    let temporary = parent.join(format!(
        ".{file_name}.tmp.{}.{}",
        std::process::id(),
        hex::encode(suffix)
    ));
    let result = (|| -> Result<()> {
        let mut file = open_private_file(&temporary, false)?;
        file.write_all(bytes)
            .with_context(|| format!("write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync {}", temporary.display()))?;
        fs::rename(&temporary, path).with_context(|| format!("replace {}", path.display()))?;
        sync_directory(parent)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn open_private_file(path: &Path, allow_existing: bool) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    if !allow_existing {
        options.create_new(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .with_context(|| format!("open {}", path.display()))
}

#[cfg(unix)]
fn set_directory_mode(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("chmod {}", path.display()))
}

#[cfg(not(unix))]
fn set_directory_mode(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .with_context(|| format!("open directory {}", path.display()))?
        .sync_all()
        .with_context(|| format!("sync directory {}", path.display()))
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

fn now_unix_seconds() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time is before unix epoch")?
        .as_secs())
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn write_json_stdout<T: Serialize>(value: &T) -> Result<()> {
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, value).context("write response JSON")?;
    handle.write_all(b"\n").context("finish response JSON")?;
    handle.flush().context("flush response JSON")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_state() -> PathBuf {
        let mut suffix = [0u8; 12];
        OsRng.fill_bytes(&mut suffix);
        env::temp_dir().join(format!("yourturn-robot-test-{}", hex::encode(suffix)))
    }

    fn id(byte: u8) -> String {
        URL_SAFE_NO_PAD.encode([byte; ID_BYTES])
    }

    #[test]
    fn seal_is_idempotent_and_decryptable() {
        let root = temporary_state();
        let paths = StatePaths::new(root.clone());
        paths.create_directories().unwrap();
        let robot = Identity::generate("robot");
        atomic_write_json(&paths.identity, &robot).unwrap();
        atomic_write_json(&paths.public_contact, &robot.contact()).unwrap();
        atomic_write(&paths.counter, b"1\n").unwrap();

        let participant = Identity::generate("participant");
        let expires = now_unix_seconds().unwrap() + 3600;
        let make_request = || SealRequest {
            version: PROTOCOL_VERSION,
            request_id: id(1),
            challenge_session_id: id(2),
            recipient_contact: participant.contact(),
            expires_at_unix: expires,
        };
        let first = seal(&paths, make_request()).unwrap();
        let second = seal(&paths, make_request()).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.message_counter, 1);
        assert_eq!(first.envelope_length, EXPECTED_ENVELOPE_BYTES);
        assert_eq!(read_counter(&paths).unwrap(), 2);

        let encrypted = STANDARD.decode(&first.envelope_base64).unwrap();
        let decrypted = decrypt_opaque_payload(&participant, &robot.contact(), &encrypted).unwrap();
        assert_eq!(decrypted.payload_kind, "challenge");
        assert_eq!(decrypted.payload_bytes.len(), 60);
        assert_eq!(&decrypted.payload_bytes[..8], CHALLENGE_MAGIC);
        assert_eq!(&decrypted.payload_bytes[10..28], &[2u8; ID_BYTES]);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reused_request_id_with_different_input_is_rejected() {
        let root = temporary_state();
        let paths = StatePaths::new(root.clone());
        paths.create_directories().unwrap();
        let robot = Identity::generate("robot");
        atomic_write_json(&paths.identity, &robot).unwrap();
        atomic_write_json(&paths.public_contact, &robot.contact()).unwrap();
        atomic_write(&paths.counter, b"1\n").unwrap();
        let participant = Identity::generate("participant");
        let first = SealRequest {
            version: PROTOCOL_VERSION,
            request_id: id(3),
            challenge_session_id: id(4),
            recipient_contact: participant.contact(),
            expires_at_unix: now_unix_seconds().unwrap() + 3600,
        };
        seal(&paths, first).unwrap();
        let conflicting = SealRequest {
            version: PROTOCOL_VERSION,
            request_id: id(3),
            challenge_session_id: id(5),
            recipient_contact: participant.contact(),
            expires_at_unix: now_unix_seconds().unwrap() + 3600,
        };
        assert!(
            seal(&paths, conflicting)
                .unwrap_err()
                .to_string()
                .contains("already used")
        );
        assert_eq!(read_counter(&paths).unwrap(), 2);
        fs::remove_dir_all(root).unwrap();
    }
}
