use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;
use uuid::Uuid;
use zip::write::SimpleFileOptions;
use zip::{AesMode, CompressionMethod, ZipArchive, ZipWriter};

const BUNDLE_ID_FILE: &str = "envelope-bundle-id.txt";
const PAYLOAD_FILE: &str = "payload.bin";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BundleManifest {
    pub bundle_version: u16,
    pub bundle_id: String,
    pub created_at_unix_ms: u128,
    pub carriers: Vec<CarrierEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CarrierEntry {
    pub file_name: String,
    pub sha256: String,
    pub byte_len: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BundlePayload {
    manifest: BundleManifest,
    carriers: Vec<CarrierPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CarrierPayload {
    file_name: String,
    bytes: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ExtractedBundle {
    pub manifest: BundleManifest,
    pub carrier_paths: Vec<PathBuf>,
}

#[derive(Debug, Error)]
pub enum BundleError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid carrier file name")]
    InvalidCarrierName,
    #[error("carrier hash mismatch for {file_name}")]
    HashMismatch { file_name: String },
    #[error("payload is missing carrier {file_name}")]
    MissingCarrier { file_name: String },
    #[error("system time is before unix epoch")]
    InvalidSystemTime,
}

pub type Result<T> = std::result::Result<T, BundleError>;

pub fn create_encrypted_zip(
    carrier_path: impl AsRef<Path>,
    output_zip_path: impl AsRef<Path>,
    password: &str,
    bundle_id: Option<String>,
) -> Result<BundleManifest> {
    let carrier_path = carrier_path.as_ref();
    let file_name = safe_file_name(carrier_path)?;
    let carrier_bytes = fs::read(carrier_path)?;
    let bundle_id = bundle_id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let manifest = BundleManifest {
        bundle_version: 1,
        bundle_id: bundle_id.clone(),
        created_at_unix_ms: now_unix_ms()?,
        carriers: vec![CarrierEntry {
            file_name: file_name.clone(),
            sha256: sha256_hex(&carrier_bytes),
            byte_len: carrier_bytes.len() as u64,
        }],
    };

    let output = File::create(output_zip_path)?;
    let mut writer = ZipWriter::new(output);

    let id_options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    writer.start_file(BUNDLE_ID_FILE, id_options)?;
    writer.write_all(bundle_id.as_bytes())?;

    let encrypted_options = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .with_aes_encryption(AesMode::Aes256, password);

    let payload = BundlePayload {
        manifest: manifest.clone(),
        carriers: vec![CarrierPayload {
            file_name,
            bytes: carrier_bytes,
        }],
    };
    writer.start_file(PAYLOAD_FILE, encrypted_options)?;
    writer.write_all(&serde_json::to_vec(&payload)?)?;

    writer.finish()?;
    Ok(manifest)
}

pub fn read_bundle_id(zip_path: impl AsRef<Path>) -> Result<String> {
    let input = File::open(zip_path)?;
    let mut archive = ZipArchive::new(input)?;
    let mut file = archive.by_name(BUNDLE_ID_FILE)?;
    let mut bundle_id = String::new();
    file.read_to_string(&mut bundle_id)?;
    Ok(bundle_id.trim().to_string())
}

pub fn extract_encrypted_zip(
    zip_path: impl AsRef<Path>,
    output_dir: impl AsRef<Path>,
    password: &str,
) -> Result<ExtractedBundle> {
    fs::create_dir_all(output_dir.as_ref())?;
    let input = File::open(zip_path)?;
    let mut archive = ZipArchive::new(input)?;

    let payload: BundlePayload = {
        let mut file = archive.by_name_decrypt(PAYLOAD_FILE, password.as_bytes())?;
        let mut payload_json = Vec::new();
        file.read_to_end(&mut payload_json)?;
        serde_json::from_slice(&payload_json)?
    };

    let mut carrier_paths = Vec::new();
    for carrier in &payload.manifest.carriers {
        validate_plain_file_name(&carrier.file_name)?;
        let payload_carrier = payload
            .carriers
            .iter()
            .find(|item| item.file_name == carrier.file_name)
            .ok_or_else(|| BundleError::MissingCarrier {
                file_name: carrier.file_name.clone(),
            })?;

        let actual_hash = sha256_hex(&payload_carrier.bytes);
        if actual_hash != carrier.sha256 {
            return Err(BundleError::HashMismatch {
                file_name: carrier.file_name.clone(),
            });
        }

        let out_path = output_dir.as_ref().join(&carrier.file_name);
        fs::write(&out_path, &payload_carrier.bytes)?;
        carrier_paths.push(out_path);
    }

    Ok(ExtractedBundle {
        manifest: payload.manifest,
        carrier_paths,
    })
}

fn safe_file_name(path: &Path) -> Result<String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(BundleError::InvalidCarrierName)?;
    validate_plain_file_name(file_name)?;
    Ok(file_name.to_string())
}

fn validate_plain_file_name(file_name: &str) -> Result<()> {
    if file_name.is_empty()
        || file_name.contains('/')
        || file_name.contains('\\')
        || file_name == "."
        || file_name == ".."
    {
        return Err(BundleError::InvalidCarrierName);
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn now_unix_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| BundleError::InvalidSystemTime)?
        .as_millis())
}
