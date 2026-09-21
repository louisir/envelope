use anyhow::{Result, ensure};
use envelope_core::{Contact, Identity, decode_bytes, encode_bytes};
use envelope_server_core::ha::{ClusterConfigV2, ClusterStatus, CommitReceipt, DecimalU64,
    EnvelopeBinding, HaSigned, RecipientResult, RequestAuth, SignedRequest, TrustWatermark, sha256_b64};
use serde::Deserialize;
use serde_json::{Value, json};

// Deliberately no Debug: signing variants contain serialized private identities.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    VerifyConfig { config: ClusterConfigV2, admin_public: String, now: DecimalU64 },
    VerifyStatus { config: ClusterConfigV2, status: ClusterStatus, nonce: String, now: DecimalU64, watermark: Option<TrustWatermark> },
    VerifyReceipt { config: ClusterConfigV2, receipt: CommitReceipt, binding: EnvelopeBinding, #[serde(default)] admin_public: Option<String> },
    VerifyResult { result: RecipientResult, contact: Contact, binding: EnvelopeBinding },
    SignResult { identity_json: String, result: RecipientResult },
    SignRequest { identity_json: String, auth: RequestAuth, body_b64: String },
    Hash { body_b64: String },
}

pub(super) fn dispatch(input: &str) -> Result<Value> {
    let command: Command = serde_json::from_str(input)?;
    match command {
        Command::VerifyConfig { config, admin_public, now } => {
            config.verify(&admin_public, now.0)?;
            Ok(serde_json::to_value(config)?)
        }
        Command::VerifyStatus { config, status, nonce, now, watermark } => {
            config.validate()?;
            // Fresh status proof does not authenticate a replacement config.
            // Callers must first verify_config against their pinned admin key.
            let mut watermark = watermark.unwrap_or(TrustWatermark {
                cluster_id: config.cluster_id.clone(), control_generation: config.control_generation,
                config_epoch: config.config_epoch, leader_term: DecimalU64(0),
            });
            watermark.accept_status(&status, &config, &nonce, now.0, 1_000)?;
            Ok(json!({"status": status, "watermark": watermark}))
        }
        Command::VerifyReceipt { config, receipt, binding, admin_public } => {
            config.validate()?;
            if let Some(admin_public) = admin_public {
                receipt.verify_with_history(&config, &admin_public, &binding)?;
            } else {
                receipt.verify(&config, &binding)?;
            }
            Ok(serde_json::to_value(receipt)?)
        }
        Command::VerifyResult { result, contact, binding } => {
            result.verify(&contact, &binding)?;
            Ok(serde_json::to_value(result)?)
        }
        Command::SignResult { identity_json, mut result } => {
            let identity = signing_identity(&identity_json)?;
            ensure!(result.recipient_key_id == identity.public.key_id, "recipient signing identity mismatch");
            result.validate()?;
            result.sign(&identity.signing_secret)?;
            result.validate()?;
            Ok(serde_json::to_value(result)?)
        }
        Command::SignRequest { identity_json, mut auth, body_b64 } => {
            let identity = signing_identity(&identity_json)?;
            ensure!(auth.actor_id == identity.public.key_id, "request signing identity mismatch");
            let bytes = bounded_bytes(&body_b64)?;
            ensure!(auth.protocol_version == 2 && auth.control_generation.0 > 0 && auth.config_epoch.0 > 0
                && !auth.cluster_id.is_empty() && !auth.operation_id.is_empty() && !auth.nonce.is_empty()
                && auth.requested_at.0 > 0, "invalid request authorization");
            ensure!(auth.body_sha256 == sha256_b64(&bytes), "request body hash mismatch");
            auth.sign(&identity.signing_secret)?;
            Ok(serde_json::to_value(SignedRequest { auth, body_b64 })?)
        }
        Command::Hash { body_b64 } => {
            Ok(json!({"sha256": sha256_b64(&bounded_bytes(&body_b64)?)}))
        }
    }
}

fn bounded_bytes(encoded: &str) -> Result<Vec<u8>> {
    ensure!(encoded.len() <= 16 * 1024 * 1024, "HA body exceeds limit");
    let bytes = decode_bytes(encoded, "body_b64")?;
    ensure!(encode_bytes(&bytes) == encoded, "noncanonical body encoding");
    Ok(bytes)
}

fn signing_identity(json: &str) -> Result<Identity> {
    let identity: Identity = serde_json::from_str(json)?;
    identity.public.validate()?;
    ensure!(envelope_core::signing_public_from_secret(&identity.signing_secret)? == identity.public.signing_public,
        "private signing key does not match identity");
    Ok(identity)
}

#[cfg(test)]
mod tests {
    use super::*;
    use envelope_server_core::ha::RecipientOutcome;
    #[test]
    fn signing_roundtrip_binds_recipient_and_rejects_changed_ciphertext() -> Result<()> {
        let recipient = Identity::generate("Recipient");
        let binding = EnvelopeBinding { operation_id: "operation".into(), sender_key_id: "sender".into(),
            recipient_key_id: recipient.public.key_id.clone(), envelope_id: "envelope".into(),
            envelope_sha256: sha256_b64(b"ciphertext"), not_after: DecimalU64(100) };
        let result = RecipientResult { version: 2, sender_key_id: binding.sender_key_id.clone(),
            recipient_key_id: binding.recipient_key_id.clone(), envelope_id: binding.envelope_id.clone(),
            envelope_sha256: binding.envelope_sha256.clone(), outcome: RecipientOutcome::Delivered,
            reason_code: String::new(), received_at: DecimalU64(10), result_id: "result".into(),
            result_sequence: DecimalU64(1), signature: String::new() };
        let signed = dispatch(&json!({"op":"sign_result","identity_json":serde_json::to_string(&recipient)?,"result":result}).to_string())?;
        dispatch(&json!({"op":"verify_result","result":signed,"contact":recipient.public,"binding":binding}).to_string())?;
        let mut wrong = binding; wrong.envelope_sha256 = sha256_b64(b"changed");
        ensure!(dispatch(&json!({"op":"verify_result","result":signed,"contact":recipient.public,"binding":wrong}).to_string()).is_err());
        Ok(())
    }
    #[test]
    fn strict_schema_and_canonical_decimal_are_required() {
        assert!(dispatch(r#"{"op":"hash","body_b64":"YQ=="}"#).is_err());
        assert!(dispatch(r#"{"op":"hash","body_b64":"YQ","unknown":1}"#).is_err());
        assert!(dispatch(r#"{"op":"hash","body_b64":"YQ","body_b64":"Yg"}"#).is_err());
    }
}
