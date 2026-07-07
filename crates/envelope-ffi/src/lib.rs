use serde::Serialize;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Serialize)]
struct ApiResponse<T: Serialize> {
    ok: bool,
    value: Option<T>,
    error: Option<String>,
}

#[derive(Debug, Serialize)]
struct IdentitySummary {
    key_id: String,
    display_name: String,
    contact_json: String,
    identity_json: String,
}

#[derive(Debug, Serialize)]
struct ContactSummary {
    key_id: String,
    display_name: String,
    contact_json: String,
}

#[derive(Debug, Serialize)]
struct IntroBundleSummary {
    key_id: String,
    display_name: String,
    contact_json: String,
    bundle_json: String,
    device_id: String,
    p2p_ticket: Option<String>,
    created_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Serialize)]
struct OutboundOpaqueTextSummary {
    envelope_id: String,
    conversation_id: String,
    sender_key_id: String,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    payload_kind: String,
    mime: String,
    filename: Option<String>,
    envelope_b64: String,
    envelope_len: usize,
    text: String,
}

#[derive(Debug, Serialize)]
struct OutboundOpaquePayloadSummary {
    envelope_id: String,
    conversation_id: String,
    sender_key_id: String,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    payload_kind: String,
    mime: String,
    filename: Option<String>,
    payload_len: usize,
    envelope_b64: String,
    envelope_len: usize,
}

#[derive(Debug, Serialize)]
struct InboundOpaqueTextSummary {
    envelope_id: String,
    conversation_id: String,
    sender_key_id: String,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    payload_kind: String,
    mime: String,
    filename: Option<String>,
    text: String,
}

#[derive(Debug, Serialize)]
struct InboundOpaquePayloadSummary {
    envelope_id: String,
    conversation_id: String,
    sender_key_id: String,
    recipient_key_id: String,
    created_at_unix_ms: u128,
    message_counter: u64,
    payload_kind: String,
    mime: String,
    filename: Option<String>,
    payload_len: usize,
    payload_b64: String,
}

#[derive(Debug, Serialize)]
struct DeviceEndpointUpdateSummary {
    owner_key_id: String,
    device_id: String,
    endpoint_json: String,
    owner_contact_json: String,
    created_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Serialize)]
struct ServerRequestSummary {
    request_json: String,
    key_id: String,
    created_at_unix_ms: u128,
}

#[derive(Debug, Serialize)]
struct SignatureSummary {
    key_id: String,
    signature: String,
}

#[derive(Debug, Serialize)]
struct SignatureVerificationSummary {
    key_id: String,
    valid: bool,
}

#[derive(Debug, Serialize)]
struct NodeSetManifestVerificationSummary {
    manifest_id: String,
    epoch: u64,
    node_count: usize,
    valid_until_unix_ms: u128,
}

#[derive(Debug, Serialize)]
struct NodeChallengeVerificationSummary {
    node_id: String,
    valid: bool,
}

#[derive(Debug, Serialize)]
struct ProtocolInfo {
    protocol_version: u16,
    opaque_offline_envelope_version: u16,
    recovery_word_count: usize,
    contexts: Vec<&'static str>,
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_protocol_info() -> *mut c_char {
    into_response(|| {
        Ok(ProtocolInfo {
            protocol_version: envelope_core::ENVELOPE_PROTOCOL_VERSION,
            opaque_offline_envelope_version: envelope_core::OPAQUE_OFFLINE_ENVELOPE_VERSION,
            recovery_word_count: envelope_core::RECOVERY_WORD_COUNT,
            contexts: vec![
                envelope_core::CONTEXT_IDENTITY_SIGNING,
                envelope_core::CONTEXT_IDENTITY_AGREEMENT,
                envelope_core::CONTEXT_DEVICE_AUTHORIZATION,
                envelope_core::CONTEXT_BACKUP_ENCRYPTION,
                envelope_core::CONTEXT_GROUP_CONSENSUS_ENDORSEMENT,
                envelope_server_core::ENVELOPE_SUBMIT_SIGNATURE_CONTEXT,
                envelope_server_core::MAILBOX_PULL_SIGNATURE_CONTEXT,
                envelope_server_core::MAILBOX_ACK_SIGNATURE_CONTEXT,
                envelope_server_core::DELIVERY_STATUS_SIGNATURE_CONTEXT,
                envelope_server_core::NODE_SET_MANIFEST_SIGNATURE_CONTEXT,
                envelope_server_core::NODE_CHALLENGE_SIGNATURE_CONTEXT,
            ],
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_generate_recovery_phrase() -> *mut c_char {
    into_response(envelope_core::generate_recovery_phrase)
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_recover_identity(
    display_name: *const c_char,
    recovery_phrase: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let display_name = read_c_string(display_name, "display_name")?;
        let recovery_phrase = read_c_string(recovery_phrase, "recovery_phrase")?;
        let identity =
            envelope_core::Identity::from_recovery_phrase(display_name, &recovery_phrase)?;
        let contact = identity.contact();
        Ok(IdentitySummary {
            key_id: identity.public.key_id.clone(),
            display_name: identity.display_name.clone(),
            contact_json: envelope_core::to_pretty_json(&contact)?,
            identity_json: envelope_core::to_pretty_json(&identity)?,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_encrypt_local_backup(
    recovery_phrase: *const c_char,
    backup_plaintext_json: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let recovery_phrase = read_c_string(recovery_phrase, "recovery_phrase")?;
        let backup_plaintext_json = read_c_string(backup_plaintext_json, "backup_plaintext_json")?;
        envelope_core::encrypt_local_backup(&recovery_phrase, backup_plaintext_json.as_bytes())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_decrypt_local_backup(
    recovery_phrase: *const c_char,
    backup_json: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let recovery_phrase = read_c_string(recovery_phrase, "recovery_phrase")?;
        let backup_json = read_c_string(backup_json, "backup_json")?;
        let plaintext = envelope_core::decrypt_local_backup(&recovery_phrase, &backup_json)?;
        String::from_utf8(plaintext)
            .map_err(|_| anyhow::anyhow!("local backup plaintext is not valid UTF-8"))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_contact_from_identity(identity_json: *const c_char) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        envelope_core::to_pretty_json(&identity.contact())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_parse_contact(contact_json: *const c_char) -> *mut c_char {
    into_response(|| {
        let contact_json = read_c_string(contact_json, "contact_json")?;
        let contact: envelope_core::Contact =
            envelope_core::from_json_slice(contact_json.as_bytes())?;
        Ok(ContactSummary {
            key_id: contact.key_id.clone(),
            display_name: contact.display_name.clone(),
            contact_json: envelope_core::to_pretty_json(&contact)?,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_intro_bundle(
    identity_json: *const c_char,
    device_id: *const c_char,
    p2p_ticket: *const c_char,
    ttl_seconds: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let device_id = read_c_string(device_id, "device_id")?;
        let p2p_ticket = read_c_string(p2p_ticket, "p2p_ticket")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let bundle = envelope_core::create_intro_bundle(
            &identity,
            device_id,
            if p2p_ticket.trim().is_empty() {
                None
            } else {
                Some(p2p_ticket)
            },
            vec![
                "contact.v1".to_string(),
                "intro_bundle.v1".to_string(),
                "qr.v1".to_string(),
                "server_intro_session.v1".to_string(),
                "text.v1".to_string(),
            ],
            ttl_seconds,
        )?;
        intro_bundle_summary(bundle)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_verify_intro_bundle(bundle_json: *const c_char) -> *mut c_char {
    into_response(|| {
        let bundle_json = read_c_string(bundle_json, "bundle_json")?;
        let bundle: envelope_core::EnvelopeIntroBundle =
            envelope_core::from_json_slice(bundle_json.as_bytes())?;
        envelope_core::verify_intro_bundle(&bundle)?;
        intro_bundle_summary(bundle)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_sign_context_payload(
    identity_json: *const c_char,
    context: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let context = read_c_string(context, "context")?;
        let payload = read_c_string(payload, "payload")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let signature =
            envelope_core::sign_context_payload(&identity, &context, payload.as_bytes())?;
        Ok(SignatureSummary {
            key_id: identity.public.key_id,
            signature,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_verify_contact_signature(
    contact_json: *const c_char,
    context: *const c_char,
    payload: *const c_char,
    signature: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let contact_json = read_c_string(contact_json, "contact_json")?;
        let context = read_c_string(context, "context")?;
        let payload = read_c_string(payload, "payload")?;
        let signature = read_c_string(signature, "signature")?;
        let contact: envelope_core::Contact =
            envelope_core::from_json_slice(contact_json.as_bytes())?;
        envelope_core::verify_contact_signature(
            &contact,
            &context,
            payload.as_bytes(),
            &signature,
        )?;
        Ok(SignatureVerificationSummary {
            key_id: contact.key_id,
            valid: true,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_verify_node_set_manifest(
    manifest_json: *const c_char,
    manifest_signing_public: *const c_char,
    now_unix_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let manifest_json = read_c_string(manifest_json, "manifest_json")?;
        let manifest_signing_public =
            read_c_string(manifest_signing_public, "manifest_signing_public")?;
        let manifest: envelope_server_core::NodeSetManifest =
            envelope_core::from_json_slice(manifest_json.as_bytes())?;
        manifest.verify(&manifest_signing_public, timestamp_or_now(now_unix_ms)?)?;
        Ok(NodeSetManifestVerificationSummary {
            manifest_id: manifest.manifest_id,
            epoch: manifest.epoch,
            node_count: manifest.nodes.len(),
            valid_until_unix_ms: manifest.valid_until_unix_ms,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_verify_node_challenge(
    request_json: *const c_char,
    response_json: *const c_char,
    node_public_key: *const c_char,
    now_unix_ms: u64,
    max_clock_skew_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let request_json = read_c_string(request_json, "request_json")?;
        let response_json = read_c_string(response_json, "response_json")?;
        let node_public_key = read_c_string(node_public_key, "node_public_key")?;
        let request: envelope_server_core::NodeChallengeRequest =
            envelope_core::from_json_slice(request_json.as_bytes())?;
        let response: envelope_server_core::NodeChallengeResponse =
            envelope_core::from_json_slice(response_json.as_bytes())?;
        response.verify(
            &request,
            &node_public_key,
            timestamp_or_now(now_unix_ms)?,
            u128::from(max_clock_skew_ms),
        )?;
        Ok(NodeChallengeVerificationSummary {
            node_id: response.node_id,
            valid: true,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_encrypt_opaque_text(
    identity_json: *const c_char,
    recipient_contact_json: *const c_char,
    text: *const c_char,
    message_counter: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let recipient_contact_json =
            read_c_string(recipient_contact_json, "recipient_contact_json")?;
        let text = read_c_string(text, "text")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let recipient: envelope_core::Contact =
            envelope_core::from_json_slice(recipient_contact_json.as_bytes())?;
        let envelope =
            envelope_core::encrypt_opaque_text(&identity, &recipient, &text, message_counter)?;

        Ok(OutboundOpaqueTextSummary {
            envelope_id: envelope.envelope_id,
            conversation_id: envelope.conversation_id,
            sender_key_id: envelope.sender_key_id,
            recipient_key_id: envelope.recipient_key_id,
            created_at_unix_ms: envelope.created_at_unix_ms,
            message_counter: envelope.message_counter,
            payload_kind: envelope.payload_kind,
            mime: envelope.mime,
            filename: envelope.filename,
            envelope_b64: envelope_core::encode_bytes(&envelope.envelope_bytes),
            envelope_len: envelope.envelope_bytes.len(),
            text,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_encrypt_opaque_file(
    identity_json: *const c_char,
    recipient_contact_json: *const c_char,
    filename: *const c_char,
    mime: *const c_char,
    payload_bytes: *const u8,
    payload_len: usize,
    message_counter: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let recipient_contact_json =
            read_c_string(recipient_contact_json, "recipient_contact_json")?;
        let filename = read_c_string(filename, "filename")?;
        let mime = read_c_string(mime, "mime")?;
        if payload_len > 0 && payload_bytes.is_null() {
            anyhow::bail!("payload_bytes is null");
        }
        let payload = if payload_len == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(payload_bytes, payload_len) }
        };
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let recipient: envelope_core::Contact =
            envelope_core::from_json_slice(recipient_contact_json.as_bytes())?;
        let envelope = envelope_core::encrypt_opaque_payload(
            &identity,
            &recipient,
            "file",
            if mime.trim().is_empty() {
                "application/octet-stream"
            } else {
                mime.trim()
            },
            if filename.trim().is_empty() {
                None
            } else {
                Some(filename.trim().to_string())
            },
            payload,
            message_counter,
        )?;

        Ok(OutboundOpaquePayloadSummary {
            envelope_id: envelope.envelope_id,
            conversation_id: envelope.conversation_id,
            sender_key_id: envelope.sender_key_id,
            recipient_key_id: envelope.recipient_key_id,
            created_at_unix_ms: envelope.created_at_unix_ms,
            message_counter: envelope.message_counter,
            payload_kind: envelope.payload_kind,
            mime: envelope.mime,
            filename: envelope.filename,
            payload_len: payload.len(),
            envelope_b64: envelope_core::encode_bytes(&envelope.envelope_bytes),
            envelope_len: envelope.envelope_bytes.len(),
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_decrypt_opaque_text(
    identity_json: *const c_char,
    sender_contact_json: *const c_char,
    envelope_b64: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let sender_contact_json = read_c_string(sender_contact_json, "sender_contact_json")?;
        let envelope_b64 = read_c_string(envelope_b64, "envelope_b64")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let sender: envelope_core::Contact =
            envelope_core::from_json_slice(sender_contact_json.as_bytes())?;
        let envelope = envelope_core::decode_bytes(&envelope_b64, "opaque envelope")?;
        let payload = envelope_core::decrypt_opaque_payload(&identity, &sender, &envelope)?;
        if payload.payload_kind != "file" {
            anyhow::bail!("opaque payload is not a file");
        }
        if payload.mime != "text/plain; charset=utf-8" {
            anyhow::bail!("opaque payload is not utf-8 text");
        }
        let text = String::from_utf8(payload.payload_bytes)
            .map_err(|_| anyhow::anyhow!("opaque text payload is not utf-8"))?;

        Ok(InboundOpaqueTextSummary {
            envelope_id: payload.envelope_id,
            conversation_id: payload.conversation_id,
            sender_key_id: payload.sender_key_id,
            recipient_key_id: payload.recipient_key_id,
            created_at_unix_ms: payload.created_at_unix_ms,
            message_counter: payload.message_counter,
            payload_kind: payload.payload_kind,
            mime: payload.mime,
            filename: payload.filename,
            text,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_decrypt_opaque_payload(
    identity_json: *const c_char,
    sender_contact_json: *const c_char,
    envelope_b64: *const c_char,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let sender_contact_json = read_c_string(sender_contact_json, "sender_contact_json")?;
        let envelope_b64 = read_c_string(envelope_b64, "envelope_b64")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let sender: envelope_core::Contact =
            envelope_core::from_json_slice(sender_contact_json.as_bytes())?;
        let envelope = envelope_core::decode_bytes(&envelope_b64, "opaque envelope")?;
        let payload = envelope_core::decrypt_opaque_payload(&identity, &sender, &envelope)?;
        let payload_len = payload.payload_bytes.len();
        Ok(InboundOpaquePayloadSummary {
            envelope_id: payload.envelope_id,
            conversation_id: payload.conversation_id,
            sender_key_id: payload.sender_key_id,
            recipient_key_id: payload.recipient_key_id,
            created_at_unix_ms: payload.created_at_unix_ms,
            message_counter: payload.message_counter,
            payload_kind: payload.payload_kind,
            mime: payload.mime,
            filename: payload.filename,
            payload_len,
            payload_b64: envelope_core::encode_bytes(&payload.payload_bytes),
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_device_endpoint_update(
    identity_json: *const c_char,
    device_id: *const c_char,
    p2p_ticket: *const c_char,
    session_id: *const c_char,
    device_list_version: u64,
    ttl_seconds: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let device_id = read_c_string(device_id, "device_id")?;
        let p2p_ticket = read_c_string(p2p_ticket, "p2p_ticket")?;
        let session_id = read_c_string(session_id, "session_id")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let endpoint = envelope_core::create_device_endpoint_update(
            &identity,
            device_id,
            p2p_ticket,
            session_id,
            device_list_version,
            ttl_seconds,
        )?;
        Ok(DeviceEndpointUpdateSummary {
            owner_key_id: endpoint.owner_identity_key_id.clone(),
            device_id: endpoint.device_id.clone(),
            endpoint_json: envelope_core::to_json(&endpoint)?,
            owner_contact_json: envelope_core::to_pretty_json(&identity.contact())?,
            created_at_unix_ms: endpoint.created_at_unix_ms,
            expires_at_unix_ms: endpoint.expires_at_unix_ms,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_mailbox_pull_request(
    identity_json: *const c_char,
    limit: u32,
    requested_at_unix_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let created_at_unix_ms = timestamp_or_now(requested_at_unix_ms)?;
        let request = envelope_server_core::MailboxPullRequest::create(
            &identity,
            if limit == 0 { None } else { Some(limit) },
            created_at_unix_ms,
        )?;
        Ok(ServerRequestSummary {
            request_json: envelope_core::to_json(&request)?,
            key_id: request.recipient_key_id,
            created_at_unix_ms,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_envelope_submit_request(
    identity_json: *const c_char,
    recipient_key_id: *const c_char,
    envelope_id: *const c_char,
    envelope_b64: *const c_char,
    ttl_seconds: u64,
    submitted_at_unix_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let recipient_key_id = read_c_string(recipient_key_id, "recipient_key_id")?;
        let envelope_id = read_c_string(envelope_id, "envelope_id")?;
        let envelope_b64 = read_c_string(envelope_b64, "envelope_b64")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let created_at_unix_ms = timestamp_or_now(submitted_at_unix_ms)?;
        let request = envelope_server_core::EnvelopeSubmitRequest::create(
            &identity,
            recipient_key_id,
            envelope_id,
            envelope_b64,
            if ttl_seconds == 0 {
                None
            } else {
                Some(ttl_seconds)
            },
            created_at_unix_ms,
        )?;
        Ok(ServerRequestSummary {
            request_json: envelope_core::to_json(&request)?,
            key_id: request.sender_key_id,
            created_at_unix_ms,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_mailbox_ack_request(
    identity_json: *const c_char,
    envelope_ids_json: *const c_char,
    acked_at_unix_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let envelope_ids_json = read_c_string(envelope_ids_json, "envelope_ids_json")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let envelope_ids: Vec<String> = serde_json::from_str(&envelope_ids_json)?;
        let created_at_unix_ms = timestamp_or_now(acked_at_unix_ms)?;
        let request = envelope_server_core::MailboxAckRequest::create(
            &identity,
            envelope_ids,
            created_at_unix_ms,
        )?;
        Ok(ServerRequestSummary {
            request_json: envelope_core::to_json(&request)?,
            key_id: request.recipient_key_id,
            created_at_unix_ms,
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn envelope_ffi_create_delivery_status_request(
    identity_json: *const c_char,
    envelope_ids_json: *const c_char,
    requested_at_unix_ms: u64,
) -> *mut c_char {
    into_response(|| {
        let identity_json = read_c_string(identity_json, "identity_json")?;
        let envelope_ids_json = read_c_string(envelope_ids_json, "envelope_ids_json")?;
        let identity: envelope_core::Identity =
            envelope_core::from_json_slice(identity_json.as_bytes())?;
        let envelope_ids: Vec<String> = serde_json::from_str(&envelope_ids_json)?;
        let created_at_unix_ms = timestamp_or_now(requested_at_unix_ms)?;
        let request = envelope_server_core::DeliveryStatusRequest::create(
            &identity,
            envelope_ids,
            created_at_unix_ms,
        )?;
        Ok(ServerRequestSummary {
            request_json: envelope_core::to_json(&request)?,
            key_id: request.sender_key_id,
            created_at_unix_ms,
        })
    })
}

fn intro_bundle_summary(
    bundle: envelope_core::EnvelopeIntroBundle,
) -> anyhow::Result<IntroBundleSummary> {
    Ok(IntroBundleSummary {
        key_id: bundle.contact.key_id.clone(),
        display_name: bundle.contact.display_name.clone(),
        contact_json: envelope_core::to_pretty_json(&bundle.contact)?,
        bundle_json: envelope_core::to_json(&bundle)?,
        device_id: bundle.device_id.clone(),
        p2p_ticket: bundle.p2p_ticket.clone(),
        created_at_unix_ms: bundle.created_at_unix_ms,
        expires_at_unix_ms: bundle.expires_at_unix_ms,
    })
}

fn read_c_string(ptr: *const c_char, field: &str) -> anyhow::Result<String> {
    if ptr.is_null() {
        anyhow::bail!("{field} is null");
    }
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| anyhow::anyhow!("{field} must be valid UTF-8"))?;
    Ok(value.to_string())
}

fn timestamp_or_now(value: u64) -> anyhow::Result<u128> {
    if value != 0 {
        return Ok(u128::from(value));
    }
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
}

fn fallback_error_response(message: &'static str) -> *mut c_char {
    let json = format!(r#"{{"ok":false,"value":null,"error":"{message}"}}"#);
    CString::new(json)
        .expect("hard-coded FFI error response must not contain NUL")
        .into_raw()
}

fn into_response<T, F>(f: F) -> *mut c_char
where
    T: Serialize,
    F: FnOnce() -> anyhow::Result<T>,
{
    let response = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => ApiResponse {
            ok: true,
            value: Some(value),
            error: None,
        },
        Ok(Err(error)) => ApiResponse::<T> {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
        Err(_) => ApiResponse::<T> {
            ok: false,
            value: None,
            error: Some("panic across FFI boundary".to_string()),
        },
    };
    match serde_json::to_string(&response) {
        Ok(json) => match CString::new(json) {
            Ok(value) => value.into_raw(),
            Err(_) => fallback_error_response("Internal FFI string conversion error"),
        },
        Err(_) => fallback_error_response("Internal FFI serialization error"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_generates_json_response() {
        let ptr = envelope_ffi_generate_recovery_phrase();
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        envelope_ffi_free_string(ptr);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(
            value["value"].as_str().unwrap().split_whitespace().count(),
            envelope_core::RECOVERY_WORD_COUNT
        );
    }

    #[test]
    fn ffi_serialization_failure_returns_error_response() {
        struct FailingSerialize;

        impl Serialize for FailingSerialize {
            fn serialize<S>(&self, _serializer: S) -> Result<S::Ok, S::Error>
            where
                S: serde::Serializer,
            {
                Err(serde::ser::Error::custom("forced serialization failure"))
            }
        }

        let ptr = into_response(|| Ok(FailingSerialize));
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        envelope_ffi_free_string(ptr);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"], "Internal FFI serialization error");
    }

    #[test]
    fn ffi_recovers_identity() {
        let name = CString::new("Alice").unwrap();
        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art").unwrap();
        let ptr = envelope_ffi_recover_identity(name.as_ptr(), phrase.as_ptr());
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        envelope_ffi_free_string(ptr);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["ok"], true);
        assert!(value["value"]["key_id"].as_str().unwrap().len() > 16);
    }

    #[test]
    fn ffi_encrypts_and_decrypts_opaque_text() {
        let alice = envelope_core::Identity::generate("Alice");
        let bob = envelope_core::Identity::generate("Bob");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let bob_json = CString::new(envelope_core::to_pretty_json(&bob).unwrap()).unwrap();
        let bob_contact_json =
            CString::new(envelope_core::to_pretty_json(&bob.contact()).unwrap()).unwrap();
        let alice_contact_json =
            CString::new(envelope_core::to_pretty_json(&alice.contact()).unwrap()).unwrap();
        let text = CString::new("hello opaque android").unwrap();

        let encrypted_ptr = envelope_ffi_encrypt_opaque_text(
            alice_json.as_ptr(),
            bob_contact_json.as_ptr(),
            text.as_ptr(),
            9,
        );
        assert!(!encrypted_ptr.is_null());
        let encrypted_json = unsafe { CStr::from_ptr(encrypted_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(encrypted_ptr);
        let encrypted: serde_json::Value = serde_json::from_str(&encrypted_json).unwrap();
        assert_eq!(encrypted["ok"], true);
        assert_eq!(encrypted["value"]["message_counter"], 9);
        assert_eq!(encrypted["value"]["sender_key_id"], alice.public.key_id);
        assert_eq!(encrypted["value"]["recipient_key_id"], bob.public.key_id);
        assert_eq!(encrypted["value"]["payload_kind"], "file");
        assert!(
            encrypted["value"]["envelope_len"].as_u64().unwrap()
                > envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES as u64
        );
        let envelope_b64 =
            CString::new(encrypted["value"]["envelope_b64"].as_str().unwrap()).unwrap();

        let decrypted_ptr = envelope_ffi_decrypt_opaque_text(
            bob_json.as_ptr(),
            alice_contact_json.as_ptr(),
            envelope_b64.as_ptr(),
        );
        assert!(!decrypted_ptr.is_null());
        let decrypted_json = unsafe { CStr::from_ptr(decrypted_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(decrypted_ptr);
        let decrypted: serde_json::Value = serde_json::from_str(&decrypted_json).unwrap();
        assert_eq!(decrypted["ok"], true);
        assert_eq!(decrypted["value"]["text"], "hello opaque android");
        assert_eq!(decrypted["value"]["payload_kind"], "file");
        assert_eq!(decrypted["value"]["mime"], "text/plain; charset=utf-8");
    }

    #[test]
    fn ffi_encrypts_opaque_file() {
        let alice = envelope_core::Identity::generate("Alice");
        let bob = envelope_core::Identity::generate("Bob");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let bob_json = CString::new(envelope_core::to_pretty_json(&bob).unwrap()).unwrap();
        let bob_contact_json =
            CString::new(envelope_core::to_pretty_json(&bob.contact()).unwrap()).unwrap();
        let alice_contact_json =
            CString::new(envelope_core::to_pretty_json(&alice.contact()).unwrap()).unwrap();
        let filename = CString::new("photo.png").unwrap();
        let mime = CString::new("image/png").unwrap();
        let bytes = b"fake image bytes";

        let encrypted_ptr = envelope_ffi_encrypt_opaque_file(
            alice_json.as_ptr(),
            bob_contact_json.as_ptr(),
            filename.as_ptr(),
            mime.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            10,
        );
        assert!(!encrypted_ptr.is_null());
        let encrypted_json = unsafe { CStr::from_ptr(encrypted_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(encrypted_ptr);
        let encrypted: serde_json::Value = serde_json::from_str(&encrypted_json).unwrap();
        assert_eq!(encrypted["ok"], true);
        assert_eq!(encrypted["value"]["message_counter"], 10);
        assert_eq!(encrypted["value"]["sender_key_id"], alice.public.key_id);
        assert_eq!(encrypted["value"]["recipient_key_id"], bob.public.key_id);
        assert_eq!(encrypted["value"]["payload_kind"], "file");
        assert_eq!(encrypted["value"]["mime"], "image/png");
        assert_eq!(encrypted["value"]["filename"], "photo.png");
        assert_eq!(encrypted["value"]["payload_len"], bytes.len());
        assert!(
            encrypted["value"]["envelope_len"].as_u64().unwrap()
                > envelope_core::OPAQUE_OFFLINE_ENVELOPE_EPHEMERAL_PUBLIC_BYTES as u64
        );

        let envelope_b64 =
            CString::new(encrypted["value"]["envelope_b64"].as_str().unwrap()).unwrap();
        let decrypted_ptr = envelope_ffi_decrypt_opaque_payload(
            bob_json.as_ptr(),
            alice_contact_json.as_ptr(),
            envelope_b64.as_ptr(),
        );
        assert!(!decrypted_ptr.is_null());
        let decrypted_json = unsafe { CStr::from_ptr(decrypted_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(decrypted_ptr);
        let decrypted: serde_json::Value = serde_json::from_str(&decrypted_json).unwrap();
        assert_eq!(decrypted["ok"], true);
        assert_eq!(decrypted["value"]["mime"], "image/png");
        assert_eq!(decrypted["value"]["filename"], "photo.png");
        assert_eq!(decrypted["value"]["payload_len"], bytes.len());
        let payload = envelope_core::decode_bytes(
            decrypted["value"]["payload_b64"].as_str().unwrap(),
            "test payload",
        )
        .unwrap();
        assert_eq!(payload, bytes);
    }

    #[test]
    fn ffi_creates_delivery_status_request() {
        let alice = envelope_core::Identity::generate("Alice");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let ids_json = CString::new(
            serde_json::to_string(&vec!["00000000-0000-4000-8000-000000000001".to_string()])
                .unwrap(),
        )
        .unwrap();

        let request_ptr = envelope_ffi_create_delivery_status_request(
            alice_json.as_ptr(),
            ids_json.as_ptr(),
            1_700_000_000_000,
        );
        assert!(!request_ptr.is_null());
        let request_json = unsafe { CStr::from_ptr(request_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(request_ptr);
        let request: serde_json::Value = serde_json::from_str(&request_json).unwrap();
        assert_eq!(request["ok"], true);
        assert_eq!(request["value"]["key_id"], alice.public.key_id);
        assert!(
            request["value"]["request_json"]
                .as_str()
                .unwrap()
                .contains("sender_key_id")
        );
    }

    #[test]
    fn ffi_creates_and_verifies_intro_bundle() {
        let alice = envelope_core::Identity::generate("Alice");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let device_id = CString::new("android-debug-device").unwrap();
        let ticket = CString::new("").unwrap();

        let created_ptr = envelope_ffi_create_intro_bundle(
            alice_json.as_ptr(),
            device_id.as_ptr(),
            ticket.as_ptr(),
            300,
        );
        assert!(!created_ptr.is_null());
        let created_json = unsafe { CStr::from_ptr(created_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(created_ptr);
        let created: serde_json::Value = serde_json::from_str(&created_json).unwrap();
        assert_eq!(created["ok"], true);
        assert_eq!(created["value"]["key_id"], alice.public.key_id);

        let bundle_json = CString::new(created["value"]["bundle_json"].as_str().unwrap()).unwrap();
        let verified_ptr = envelope_ffi_verify_intro_bundle(bundle_json.as_ptr());
        assert!(!verified_ptr.is_null());
        let verified_json = unsafe { CStr::from_ptr(verified_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(verified_ptr);
        let verified: serde_json::Value = serde_json::from_str(&verified_json).unwrap();
        assert_eq!(verified["ok"], true);
        assert_eq!(verified["value"]["key_id"], alice.public.key_id);
    }

    #[test]
    fn ffi_signs_and_verifies_context_payload() {
        let alice = envelope_core::Identity::generate("Alice");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let alice_contact_json =
            CString::new(envelope_core::to_pretty_json(&alice.contact()).unwrap()).unwrap();
        let context = CString::new(envelope_core::CONTEXT_GROUP_CONSENSUS_ENDORSEMENT).unwrap();
        let payload = CString::new(
            r#"{"version":1,"group_id":"grp-1","candidate_key_id":"candidate","endorser_key_id":"alice"}"#,
        )
        .unwrap();

        let signed_ptr = envelope_ffi_sign_context_payload(
            alice_json.as_ptr(),
            context.as_ptr(),
            payload.as_ptr(),
        );
        assert!(!signed_ptr.is_null());
        let signed_json = unsafe { CStr::from_ptr(signed_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(signed_ptr);
        let signed: serde_json::Value = serde_json::from_str(&signed_json).unwrap();
        assert_eq!(signed["ok"], true);
        assert_eq!(signed["value"]["key_id"], alice.public.key_id);
        let signature = CString::new(signed["value"]["signature"].as_str().unwrap()).unwrap();

        let verified_ptr = envelope_ffi_verify_contact_signature(
            alice_contact_json.as_ptr(),
            context.as_ptr(),
            payload.as_ptr(),
            signature.as_ptr(),
        );
        assert!(!verified_ptr.is_null());
        let verified_json = unsafe { CStr::from_ptr(verified_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(verified_ptr);
        let verified: serde_json::Value = serde_json::from_str(&verified_json).unwrap();
        assert_eq!(verified["ok"], true);
        assert_eq!(verified["value"]["valid"], true);

        let tampered = CString::new(
            r#"{"version":1,"group_id":"grp-1","candidate_key_id":"other","endorser_key_id":"alice"}"#,
        )
        .unwrap();
        let tampered_ptr = envelope_ffi_verify_contact_signature(
            alice_contact_json.as_ptr(),
            context.as_ptr(),
            tampered.as_ptr(),
            signature.as_ptr(),
        );
        assert!(!tampered_ptr.is_null());
        let tampered_json = unsafe { CStr::from_ptr(tampered_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(tampered_ptr);
        let tampered_value: serde_json::Value = serde_json::from_str(&tampered_json).unwrap();
        assert_eq!(tampered_value["ok"], false);
    }

    #[test]
    fn ffi_creates_server_endpoint_update() {
        let alice = envelope_core::Identity::generate("Alice");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let device_id = CString::new("android-debug-device").unwrap();
        let ticket = CString::new("envelope-p2p-tcp-v1.test").unwrap();
        let session_id = CString::new("session-1").unwrap();

        let ptr = envelope_ffi_create_device_endpoint_update(
            alice_json.as_ptr(),
            device_id.as_ptr(),
            ticket.as_ptr(),
            session_id.as_ptr(),
            1,
            300,
        );
        assert!(!ptr.is_null());
        let json = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string();
        envelope_ffi_free_string(ptr);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["ok"], true);
        let endpoint_json = value["value"]["endpoint_json"].as_str().unwrap();
        let endpoint: envelope_core::DeviceEndpointUpdate =
            serde_json::from_str(endpoint_json).unwrap();
        envelope_core::verify_device_endpoint_update(&alice.contact(), &endpoint).unwrap();
    }

    #[test]
    fn ffi_creates_signed_mailbox_requests() {
        let alice = envelope_core::Identity::generate("Alice");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let now = 1_700_000_000_000u64;

        let pull_ptr = envelope_ffi_create_mailbox_pull_request(alice_json.as_ptr(), 25, now);
        assert!(!pull_ptr.is_null());
        let pull_json = unsafe { CStr::from_ptr(pull_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(pull_ptr);
        let pull_value: serde_json::Value = serde_json::from_str(&pull_json).unwrap();
        assert_eq!(pull_value["ok"], true);
        let pull_request: envelope_server_core::MailboxPullRequest =
            serde_json::from_str(pull_value["value"]["request_json"].as_str().unwrap()).unwrap();
        pull_request
            .verify(
                &alice.contact(),
                u128::from(now),
                &envelope_server_core::AntiAbuseLimits::default(),
            )
            .unwrap();

        let envelope_ids = CString::new(r#"["00000000-0000-4000-8000-000000000001"]"#).unwrap();
        let ack_ptr = envelope_ffi_create_mailbox_ack_request(
            alice_json.as_ptr(),
            envelope_ids.as_ptr(),
            now,
        );
        assert!(!ack_ptr.is_null());
        let ack_json = unsafe { CStr::from_ptr(ack_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(ack_ptr);
        let ack_value: serde_json::Value = serde_json::from_str(&ack_json).unwrap();
        assert_eq!(ack_value["ok"], true);
        let ack_request: envelope_server_core::MailboxAckRequest =
            serde_json::from_str(ack_value["value"]["request_json"].as_str().unwrap()).unwrap();
        ack_request
            .verify(
                &alice.contact(),
                u128::from(now),
                &envelope_server_core::AntiAbuseLimits::default(),
            )
            .unwrap();
    }

    #[test]
    fn ffi_creates_signed_envelope_submit_request() {
        let alice = envelope_core::Identity::generate("Alice");
        let bob = envelope_core::Identity::generate("Bob");
        let alice_json = CString::new(envelope_core::to_pretty_json(&alice).unwrap()).unwrap();
        let recipient_key_id = CString::new(bob.public.key_id.clone()).unwrap();
        let envelope_id = CString::new("00000000-0000-4000-8000-000000000001").unwrap();
        let envelope_b64 = CString::new(envelope_core::encode_bytes(&vec![7u8; 65])).unwrap();
        let now = 1_700_000_000_000u64;

        let submit_ptr = envelope_ffi_create_envelope_submit_request(
            alice_json.as_ptr(),
            recipient_key_id.as_ptr(),
            envelope_id.as_ptr(),
            envelope_b64.as_ptr(),
            60,
            now,
        );
        assert!(!submit_ptr.is_null());
        let submit_json = unsafe { CStr::from_ptr(submit_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        envelope_ffi_free_string(submit_ptr);
        let submit_value: serde_json::Value = serde_json::from_str(&submit_json).unwrap();
        assert_eq!(submit_value["ok"], true);
        let submit_request: envelope_server_core::EnvelopeSubmitRequest =
            serde_json::from_str(submit_value["value"]["request_json"].as_str().unwrap()).unwrap();
        submit_request
            .verify(
                &alice.contact(),
                u128::from(now),
                &envelope_server_core::AntiAbuseLimits::default(),
            )
            .unwrap();
    }
}
