use super::*;

const NOW: u64 = 1_790_000_000_000;
fn secret(n: u8) -> String {
    encode_bytes(&[n; 32])
}
fn public(n: u8) -> String {
    encode_bytes(&SigningKey::from_bytes(&[n; 32]).verifying_key().to_bytes())
}
fn contact(n: u8) -> Contact {
    Contact::new(
        format!("test-{n}"),
        SigningKey::from_bytes(&[n; 32]).verifying_key().to_bytes(),
        [n + 10; 32],
    )
}
fn config() -> ClusterConfigV2 {
    let mut config = ClusterConfigV2 {
        protocol_version: 2,
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        business_nodes: vec![
            BusinessNode {
                node_id: "S1".into(),
                public_url: "https://primary.example.test/".into(),
                signing_public: public(2),
                node_incarnation: "S1-disk-1".into(),
            },
            BusinessNode {
                node_id: "S2".into(),
                public_url: "https://backup.example.test/".into(),
                signing_public: public(3),
                node_incarnation: "S2-disk-1".into(),
            },
        ],
        control_node_ids: vec!["Q".into(), "S1".into(), "S2".into()],
        issued_at: (NOW - 1000).into(),
        not_after: (NOW + 604_800_000).into(),
        signature: String::new(),
    };
    config.sign(&secret(1)).unwrap();
    config
}
fn binding() -> EnvelopeBinding {
    EnvelopeBinding {
        operation_id: "op-1".into(),
        sender_key_id: contact(4).key_id,
        recipient_key_id: contact(5).key_id,
        envelope_id: "envelope-1".into(),
        envelope_sha256: sha256_b64(&[42; 128]),
        not_after: (NOW + 60_000).into(),
    }
}
fn status() -> ClusterStatus {
    let mut value = ClusterStatus {
        protocol_version: 2,
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        node_id: "S1".into(),
        node_incarnation: "S1-disk-1".into(),
        nonce: "client-nonce-0000000000000001".into(),
        role: NodeRole::Leader,
        mode: ServiceMode::Normal,
        leader_node_id: Some("S1".into()),
        leader_term: 9_007_199_254_740_993.into(),
        applied_index: 42.into(),
        commit_index: 42.into(),
        ready: true,
        reason_code: String::new(),
        issued_at: NOW.into(),
        expires_at: (NOW + 5_000).into(),
        capabilities: vec!["ha-v2".into(), "recipient-results".into()],
        node_signature: String::new(),
    };
    value.sign(&secret(2)).unwrap();
    value
}
fn ack(n: u8) -> PrepareAck {
    let binding = binding();
    let mut value = PrepareAck {
        protocol_version: 2,
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        leader_term: 9_007_199_254_740_993.into(),
        attempt_id: "attempt-1".into(),
        operation_id: binding.operation_id.clone(),
        actor_id: binding.sender_key_id.clone(),
        logical_hash: binding.logical_hash().unwrap(),
        payload_hash: sha256_b64(b"prepared store payload"),
        node_id: format!("S{}", n - 1),
        node_incarnation: format!("S{}-disk-1", n - 1),
        signature: String::new(),
    };
    value.sign(&secret(n)).unwrap();
    value
}
fn receipt() -> CommitReceipt {
    let b = binding();
    let mut value = CommitReceipt {
        protocol_version: 2,
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        leader_term: 9_007_199_254_740_993.into(),
        commit_index: Some(42.into()),
        operation_id: b.operation_id,
        sender_key_id: b.sender_key_id,
        recipient_key_id: b.recipient_key_id,
        envelope_id: b.envelope_id,
        envelope_sha256: b.envelope_sha256,
        not_after: b.not_after,
        storage_state: StorageState::Replicated,
        delivery_state: DeliveryState::Pending,
        replica_evidence: vec![ack(2), ack(3)],
        staged_guard_revision: None,
        node_id: "S1".into(),
        issuer_control_generation: 1.into(),
        issuer_config_epoch: 1.into(),
        proof_config: None,
        expiry_evidence: None,
        node_signature: String::new(),
    };
    value.sign(&secret(2)).unwrap();
    value
}
fn result(outcome: RecipientOutcome, sequence: u64) -> RecipientResult {
    let b = binding();
    let mut value = RecipientResult {
        version: 2,
        sender_key_id: b.sender_key_id,
        recipient_key_id: b.recipient_key_id,
        envelope_id: b.envelope_id,
        envelope_sha256: b.envelope_sha256,
        outcome,
        reason_code: match outcome {
            RecipientOutcome::Deferred => "WAITING_DEPENDENCY",
            RecipientOutcome::Rejected => "INVALID_CIPHERTEXT",
            RecipientOutcome::Delivered => "",
        }
        .into(),
        received_at: (NOW + 1000).into(),
        result_id: format!("result-{sequence}"),
        result_sequence: sequence.into(),
        signature: String::new(),
    };
    value.sign(&secret(5)).unwrap();
    value
}
fn request() -> SignedRequest {
    let body = StoreEnvelopeBody {
        binding: binding(),
        sender_contact: contact(4),
        envelope_b64: encode_bytes(&[42; 128]),
        created_at: NOW.into(),
    };
    let bytes = serde_json::to_vec(&body).unwrap();
    let mut auth = RequestAuth {
        protocol_version: 2,
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        actor_id: contact(4).key_id,
        operation_id: body.binding.operation_id,
        nonce: "request-nonce-0000000000000001".into(),
        requested_at: NOW.into(),
        request_kind: RequestKind::StoreEnvelope,
        body_sha256: sha256_b64(&bytes),
        signature: String::new(),
    };
    auth.sign(&secret(4)).unwrap();
    SignedRequest {
        auth,
        body_b64: encode_bytes(&bytes),
    }
}

fn rotated_config() -> ClusterConfigV2 {
    let mut current = config();
    current.config_epoch = 2.into();
    current.business_nodes[0].signing_public = public(6);
    current.business_nodes[0].node_incarnation = "S1-disk-2".into();
    current.business_nodes[1].signing_public = public(7);
    current.business_nodes[1].node_incarnation = "S2-disk-2".into();
    current.sign(&secret(1)).unwrap();
    current
}
fn historical_receipt() -> CommitReceipt {
    let mut receipt = receipt();
    receipt.issuer_config_epoch = 2.into();
    receipt.proof_config = Some(config());
    receipt.sign(&secret(6)).unwrap();
    receipt
}

fn expired_receipt() -> CommitReceipt {
    let mut value = receipt();
    let operation_id = "expire-operation-1".to_owned();
    let expired_at = binding().not_after;
    let hash = expiry_logical_hash(&operation_id, &binding(), 1.into(), expired_at).unwrap();
    let acks = [2, 3]
        .into_iter()
        .map(|n| {
            let mut ack = ack(n);
            ack.operation_id = operation_id.clone();
            ack.attempt_id = "expire-attempt-1".into();
            ack.actor_id = expiry_actor(&value.cluster_id);
            ack.logical_hash = hash.clone();
            ack.payload_hash = sha256_b64(b"prepared expiration payload");
            ack.sign(&secret(n)).unwrap();
            ack
        })
        .collect();
    value.expiry_evidence = Some(ExpiryEvidence {
        operation_id,
        expected_object_version: 1.into(),
        expired_at,
        commit_index: 43.into(),
        replica_evidence: acks,
        proof_config: None,
    });
    value.delivery_state = DeliveryState::Expired;
    value.sign(&secret(2)).unwrap();
    value
}

#[test]
fn expiration_requires_its_own_ordered_quorum_decision() {
    let valid = expired_receipt();
    valid.verify(&config(), &binding()).unwrap();
    let mut invalid = Vec::new();
    let mut value = valid.clone();
    value.expiry_evidence = None;
    invalid.push(value);
    let mut value = valid.clone();
    value.expiry_evidence.as_mut().unwrap().replica_evidence = receipt().replica_evidence;
    invalid.push(value);
    let mut value = valid.clone();
    value
        .expiry_evidence
        .as_mut()
        .unwrap()
        .replica_evidence
        .pop();
    invalid.push(value);
    let mut value = valid.clone();
    value.expiry_evidence.as_mut().unwrap().commit_index = 42.into();
    invalid.push(value);
    let mut value = valid.clone();
    value
        .expiry_evidence
        .as_mut()
        .unwrap()
        .expected_object_version = 2.into();
    invalid.push(value);
    let mut value = valid.clone();
    value.expiry_evidence.as_mut().unwrap().expired_at.0 -= 1;
    invalid.push(value);
    let mut value = valid.clone();
    value.delivery_state = DeliveryState::Pending;
    invalid.push(value);
    for mut value in invalid {
        value.sign(&secret(2)).unwrap();
        assert!(
            value.verify(&config(), &binding()).is_err(),
            "issuer signature cannot fabricate expiration"
        );
    }
    assert!(
        expiry_logical_hash(
            "expire-operation-1",
            &binding(),
            0.into(),
            binding().not_after
        )
        .is_err()
    );
}

#[test]
fn expiry_and_storage_history_are_independently_authenticated() {
    let mut value = expired_receipt();
    value.issuer_config_epoch = 2.into();
    value.proof_config = Some(config());
    value.sign(&secret(6)).unwrap();
    value
        .verify_with_history(&rotated_config(), &public(1), &binding())
        .unwrap();
    // Storage was written with epoch 1 keys, but expiration happened at epoch 2.
    for (i, ack) in value
        .expiry_evidence
        .as_mut()
        .unwrap()
        .replica_evidence
        .iter_mut()
        .enumerate()
    {
        ack.config_epoch = 2.into();
        ack.node_incarnation = format!("S{}-disk-2", i + 1);
        ack.sign(&secret(i as u8 + 6)).unwrap();
    }
    value.sign(&secret(6)).unwrap();
    value
        .verify_with_history(&rotated_config(), &public(1), &binding())
        .unwrap();
    let mut current = rotated_config();
    current.config_epoch = 3.into();
    current.sign(&secret(1)).unwrap();
    value.issuer_config_epoch = 3.into();
    value.sign(&secret(6)).unwrap();
    assert!(
        value
            .verify_with_history(&current, &public(1), &binding())
            .is_err()
    );
    value.expiry_evidence.as_mut().unwrap().proof_config = Some(rotated_config());
    value.sign(&secret(6)).unwrap();
    value
        .verify_with_history(&current, &public(1), &binding())
        .unwrap();
    value
        .expiry_evidence
        .as_mut()
        .unwrap()
        .proof_config
        .as_mut()
        .unwrap()
        .business_nodes[0]
        .signing_public = public(8);
    value.sign(&secret(6)).unwrap();
    assert!(
        value
            .verify_with_history(&current, &public(1), &binding())
            .is_err()
    );
}

#[test]
fn historic_replica_proofs_survive_node_key_rotation_with_independent_admin_trust() {
    let current = rotated_config();
    let old = historical_receipt();
    old.verify_with_history(&current, &public(1), &binding())
        .unwrap();
    assert!(
        old.verify(&current, &binding()).is_err(),
        "current node signature cannot approve an untrusted archive"
    );
    assert!(
        old.verify_with_history(&current, &public(9), &binding())
            .is_err()
    );
    let mut wrong = old.clone();
    wrong.proof_config.as_mut().unwrap().business_nodes[0].signing_public = public(8);
    wrong.sign(&secret(6)).unwrap();
    assert!(
        wrong
            .verify_with_history(&current, &public(1), &binding())
            .is_err(),
        "issuer cannot alter administrator history"
    );
    let mut wrong = old.clone();
    wrong.sign(&secret(2)).unwrap();
    assert!(
        wrong
            .verify_with_history(&current, &public(1), &binding())
            .is_err(),
        "retired private key cannot impersonate current issuer"
    );
    let mut wrong = old.clone();
    wrong.proof_config = None;
    wrong.sign(&secret(6)).unwrap();
    assert!(
        wrong
            .verify_with_history(&current, &public(1), &binding())
            .is_err(),
        "history cannot be inferred from unverified keys"
    );
    let mut expired = old.clone();
    let archive = expired.proof_config.as_mut().unwrap();
    archive.not_after = (NOW - 1).into();
    archive.sign(&secret(1)).unwrap();
    expired.sign(&secret(6)).unwrap();
    assert!(
        expired
            .proof_config
            .as_ref()
            .unwrap()
            .verify(&public(1), NOW)
            .is_err()
    );
    expired
        .verify_with_history(&current, &public(1), &binding())
        .unwrap();
    assert_eq!(expired.control_generation, DecimalU64(1));
    assert_eq!(expired.config_epoch, DecimalU64(1));
    assert_eq!(expired.issuer_config_epoch, DecimalU64(2));
    assert_eq!(expired.commit_index, Some(DecimalU64(42)));
}

#[test]
fn historical_config_cannot_authorize_status_or_future_commit_scope() {
    let current = rotated_config();
    let old = status();
    assert!(old.verify(&current, &old.nonce, NOW, 0).is_err());
    let mut future = historical_receipt();
    let config = future.proof_config.as_mut().unwrap();
    config.control_generation = 2.into();
    config.config_epoch = 3.into();
    config.sign(&secret(1)).unwrap();
    future.sign(&secret(6)).unwrap();
    assert_eq!(
        future.verify_with_history(&current, &public(1), &binding()),
        Err(HaError::Rollback)
    );
    let mut wrong_cluster = historical_receipt();
    wrong_cluster.proof_config.as_mut().unwrap().cluster_id = "unrelated-cluster".into();
    wrong_cluster
        .proof_config
        .as_mut()
        .unwrap()
        .sign(&secret(1))
        .unwrap();
    wrong_cluster.sign(&secret(6)).unwrap();
    assert!(
        wrong_cluster
            .verify_with_history(&current, &public(1), &binding())
            .is_err()
    );
}

#[test]
fn decimal_numbers_are_portable_and_strict() {
    for n in [0, u64::MAX, 9_007_199_254_740_993] {
        let encoded = serde_json::to_string(&DecimalU64(n)).unwrap();
        assert_eq!(
            serde_json::from_str::<DecimalU64>(&encoded).unwrap(),
            DecimalU64(n)
        );
    }
    for bad in [
        "0",
        "1.0",
        "null",
        "true",
        "\"\"",
        "\"01\"",
        "\"-1\"",
        "\"+1\"",
        "\" 1\"",
        "\"1e2\"",
        "\"18446744073709551616\"",
    ] {
        assert!(serde_json::from_str::<DecimalU64>(bad).is_err(), "{bad}");
    }
}

#[test]
fn typed_json_rejects_duplicates_and_unknown_fields_but_field_order_is_irrelevant() {
    let value = result(RecipientOutcome::Delivered, 1);
    let raw = serde_json::to_string(&value).unwrap();
    let duplicate = raw.replacen("\"version\":2", "\"version\":2,\"version\":2", 1);
    assert!(serde_json::from_str::<RecipientResult>(&duplicate).is_err());
    let unknown = raw.replacen('{', "{\"unreviewed_field\":true,", 1);
    assert!(serde_json::from_str::<RecipientResult>(&unknown).is_err());
    let reordered = serde_json::to_string(&serde_json::to_value(&value).unwrap()).unwrap();
    let parsed: RecipientResult = serde_json::from_str(&reordered).unwrap();
    assert_eq!(
        value.signing_bytes().unwrap(),
        parsed.signing_bytes().unwrap()
    );
    parsed.verify(&contact(5), &binding()).unwrap();
}

#[test]
fn domains_are_exact_and_v1_context_signatures_are_rejected() {
    let mut result = result(RecipientOutcome::Delivered, 1);
    let bytes = result.signing_bytes().unwrap();
    assert!(bytes.starts_with(b"EnvelopeHA/V2/RecipientResult\0[2,"));
    result.signature = envelope_core::sign_context_payload_with_secret(
        &secret(5),
        "EnvelopeHA/V2/RecipientResult",
        &result.canonical_payload().unwrap(),
    )
    .unwrap();
    assert_eq!(
        result.verify_signature(&public(5)),
        Err(HaError::InvalidSignature)
    );
    let mut wrong_domain = b"EnvelopeHA/V2/CommitReceipt\0".to_vec();
    wrong_domain.extend(result.canonical_payload().unwrap());
    result.signature = encode_bytes(
        &SigningKey::from_bytes(&[5; 32])
            .sign(&wrong_domain)
            .to_bytes(),
    );
    assert_eq!(
        result.verify_signature(&public(5)),
        Err(HaError::InvalidSignature)
    );
}

#[test]
fn config_requires_distinct_business_failure_domains_and_three_voters() {
    config().verify(&public(1), NOW).unwrap();
    let mut cfg = config();
    cfg.control_node_ids.push("Q2".into());
    assert!(cfg.validate().is_err());
    let mut cfg = config();
    cfg.business_nodes[1].signing_public = cfg.business_nodes[0].signing_public.clone();
    assert!(cfg.validate().is_err());
    for bad in [
        "http://primary.example.test",
        "https://user:secret@primary.example.test/",
        "https://primary.example.test/path",
        "https://primary.example.test/?to=evil",
        "https://primary.example.test/#redirect",
    ] {
        let mut cfg = config();
        cfg.business_nodes[0].public_url = bad.into();
        assert!(cfg.validate().is_err(), "{bad}");
    }
    let mut cfg = config();
    cfg.control_node_ids = vec!["Q".into(), "R".into(), "S1".into()];
    assert!(cfg.validate().is_err());
}

#[test]
fn status_requires_challenge_freshness_readiness_and_incarnation() {
    let cfg = config();
    let good = status();
    good.verify(&cfg, &good.nonce, NOW, 0).unwrap();
    assert!(good.verify(&cfg, "wrong-nonce", NOW, 0).is_err());
    assert!(good.verify(&cfg, &good.nonce, NOW + 5_000, 0).is_err());
    let mut bad = good.clone();
    bad.applied_index = 41.into();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &bad.nonce, NOW, 0).is_err());
    let mut bad = good.clone();
    bad.node_incarnation = "erased-disk".into();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &bad.nonce, NOW, 0).is_err());
    let mut bad = good.clone();
    bad.role = NodeRole::Follower;
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &bad.nonce, NOW, 0).is_err());
    let mut bad = good.clone();
    bad.expires_at = (NOW + 5_001).into();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &bad.nonce, NOW, 0).is_err());
}

#[test]
fn watermark_rejects_old_terms_and_only_admin_generation_resets_term() {
    let mut watermark = TrustWatermark {
        cluster_id: "test-cluster".into(),
        control_generation: 1.into(),
        config_epoch: 1.into(),
        leader_term: 0.into(),
    };
    let cfg = config();
    let good = status();
    watermark
        .accept_status(&good, &cfg, &good.nonce, NOW, 0)
        .unwrap();
    let mut old = good.clone();
    old.leader_term = 5.into();
    old.sign(&secret(2)).unwrap();
    assert_eq!(
        watermark.accept_status(&old, &cfg, &old.nonce, NOW, 0),
        Err(HaError::Rollback)
    );
    let mut recovered = cfg.clone();
    recovered.control_generation = 2.into();
    recovered.sign(&secret(1)).unwrap();
    assert_eq!(
        watermark.accept_config(&recovered, &public(1), NOW),
        Err(HaError::Rollback)
    );
    recovered.config_epoch = 2.into();
    recovered.sign(&secret(1)).unwrap();
    watermark
        .accept_config(&recovered, &public(1), NOW)
        .unwrap();
    assert_eq!(watermark.leader_term, DecimalU64(0));
    assert_eq!(
        watermark.accept_config(&cfg, &public(1), NOW),
        Err(HaError::Rollback)
    );
}

#[test]
fn replicated_requires_two_distinct_matching_signed_preparations() {
    let cfg = config();
    let b = binding();
    receipt().verify(&cfg, &b).unwrap();
    let mut bad = receipt();
    bad.replica_evidence.pop();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
    let mut bad = receipt();
    bad.replica_evidence[1] = bad.replica_evidence[0].clone();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
    let mut bad = receipt();
    bad.replica_evidence[1].attempt_id = "other-attempt".into();
    bad.replica_evidence[1].sign(&secret(3)).unwrap();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
    let mut bad = receipt();
    bad.replica_evidence[1].payload_hash = sha256_b64(b"different body");
    bad.replica_evidence[1].sign(&secret(3)).unwrap();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
    let mut bad = receipt();
    bad.commit_index = None;
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
    let mut bad = receipt();
    bad.replica_evidence[1].node_incarnation = "S2-empty".into();
    bad.replica_evidence[1].sign(&secret(3)).unwrap();
    bad.sign(&secret(2)).unwrap();
    assert!(bad.verify(&cfg, &b).is_err());
}

#[test]
fn staged_proof_has_one_actual_replica_and_never_regresses_storage() {
    let mut staged = receipt();
    staged.storage_state = StorageState::StagedSingle;
    staged.commit_index = None;
    staged.staged_guard_revision = Some(91.into());
    staged.replica_evidence.pop();
    staged.sign(&secret(2)).unwrap();
    staged.verify(&config(), &binding()).unwrap();
    let mut state = MessageState::default();
    state
        .apply_storage_proof(&receipt(), &config(), &binding())
        .unwrap();
    state
        .apply_storage_proof(&staged, &config(), &binding())
        .unwrap();
    assert_eq!(state.storage_state, StorageState::Replicated);
    assert!(state.retain_outbox(&binding(), NOW));
    staged.staged_guard_revision = None;
    staged.sign(&secret(2)).unwrap();
    assert!(staged.verify(&config(), &binding()).is_err());
}

#[test]
fn server_receipt_cannot_invent_delivery_and_bad_ack_cannot_turn_delivered() {
    let mut state = MessageState::default();
    let mut r = receipt();
    r.delivery_state = DeliveryState::Delivered;
    r.sign(&secret(2)).unwrap();
    state
        .apply_storage_proof(&r, &config(), &binding())
        .unwrap();
    assert_eq!(state.delivery_state, DeliveryState::Pending);
    let rejected = result(RecipientOutcome::Rejected, 1);
    state
        .apply_recipient_result(&rejected, &contact(5), &binding())
        .unwrap();
    assert_eq!(state.delivery_state, DeliveryState::Rejected);
    assert!(!state.retain_outbox(&binding(), NOW));
    assert_eq!(
        state.apply_recipient_result(
            &result(RecipientOutcome::Delivered, 2),
            &contact(5),
            &binding()
        ),
        Err(HaError::InvalidTransition)
    );
}

#[test]
fn recipient_results_bind_contact_content_sequence_and_persisted_id() {
    let cfg = config();
    let b = binding();
    let deferred = result(RecipientOutcome::Deferred, 1);
    let delivered = result(RecipientOutcome::Delivered, 2);
    let mut state = MessageState::default();
    assert!(
        state
            .apply_recipient_result(&deferred, &contact(5), &b)
            .unwrap()
    );
    assert!(
        !state
            .apply_recipient_result(&deferred, &contact(5), &b)
            .unwrap()
    );
    assert!(state.retain_outbox(&b, NOW));
    assert!(
        state
            .apply_recipient_result(&delivered, &contact(5), &b)
            .unwrap()
    );
    assert!(!state.retain_outbox(&b, NOW));
    assert_eq!(
        state.apply_recipient_result(&deferred, &contact(5), &b),
        Err(HaError::Rollback)
    );
    assert!(delivered.verify(&contact(4), &b).is_err());
    let mut tampered = delivered.clone();
    tampered.envelope_sha256 = sha256_b64(b"wrong");
    tampered.sign(&secret(5)).unwrap();
    assert!(tampered.verify(&contact(5), &b).is_err());
    let mut conflict = delivered.clone();
    conflict.result_id = "new-id-same-sequence".into();
    conflict.sign(&secret(5)).unwrap();
    assert_eq!(
        state.apply_recipient_result(&conflict, &contact(5), &b),
        Err(HaError::IdConflict)
    );
    // Delivery proof is transport/cluster independent, unlike storage evidence.
    assert!(
        !String::from_utf8(delivered.canonical_payload().unwrap())
            .unwrap()
            .contains(&cfg.cluster_id)
    );
}

#[test]
fn late_delivery_after_expiry_requires_actual_receipt_before_fixed_deadline() {
    let expiration = expired_receipt();
    let mut state = MessageState::default();
    state
        .apply_expiry(&expiration, &config(), &binding(), binding().not_after.0)
        .unwrap();
    let mut late = result(RecipientOutcome::Delivered, 1);
    late.received_at = binding().not_after;
    late.sign(&secret(5)).unwrap();
    assert_eq!(
        state.apply_recipient_result(&late, &contact(5), &binding()),
        Err(HaError::InvalidTransition)
    );
    assert!(
        state
            .apply_recipient_result(
                &result(RecipientOutcome::Delivered, 1),
                &contact(5),
                &binding()
            )
            .unwrap()
    );
    assert_eq!(state.delivery_state, DeliveryState::Delivered);
}

#[test]
fn retry_never_changes_content_recipient_or_deadline() {
    let b = binding();
    b.check_retry(&b).unwrap();
    let mut changed = b.clone();
    changed.not_after.0 += 1;
    assert_eq!(b.check_retry(&changed), Err(HaError::IdConflict));
    assert_eq!(b.object_key().unwrap(), changed.object_key().unwrap());
    assert_ne!(b.logical_hash().unwrap(), changed.logical_hash().unwrap());
    let mut ambiguous1 = b.clone();
    ambiguous1.sender_key_id = "ab".into();
    ambiguous1.recipient_key_id = "c".into();
    let mut ambiguous2 = b;
    ambiguous2.sender_key_id = "a".into();
    ambiguous2.recipient_key_id = "bc".into();
    assert_ne!(
        ambiguous1.object_key().unwrap(),
        ambiguous2.object_key().unwrap()
    );
}

#[test]
fn request_auth_binds_exact_body_actor_cluster_kind_and_time() {
    let request = request();
    let bytes = request.decoded_body(4096).unwrap();
    request
        .auth
        .verify(
            &contact(4),
            &config(),
            RequestKind::StoreEnvelope,
            &bytes,
            NOW,
            5000,
        )
        .unwrap();
    assert!(
        request
            .auth
            .verify(
                &contact(5),
                &config(),
                RequestKind::StoreEnvelope,
                &bytes,
                NOW,
                5000
            )
            .is_err()
    );
    assert!(
        request
            .auth
            .verify(
                &contact(4),
                &config(),
                RequestKind::PullMailbox,
                &bytes,
                NOW,
                5000
            )
            .is_err()
    );
    assert!(
        request
            .auth
            .verify(
                &contact(4),
                &config(),
                RequestKind::StoreEnvelope,
                b"other",
                NOW,
                5000
            )
            .is_err()
    );
    assert!(
        request
            .auth
            .verify(
                &contact(4),
                &config(),
                RequestKind::StoreEnvelope,
                &bytes,
                NOW + 5001,
                5000
            )
            .is_err()
    );
    assert!(request.decoded_body(10).is_err());
    let body: StoreEnvelopeBody = serde_json::from_slice(&bytes).unwrap();
    body.validate(1024, 7 * 24 * 60 * 60 * 1000, NOW, 5000)
        .unwrap();
    let mut bad = body;
    bad.binding.not_after = (NOW + 700_000_000).into();
    assert!(
        bad.validate(1024, 7 * 24 * 60 * 60 * 1000, NOW, 5000)
            .is_err()
    );
}

fn vector<T: HaSigned + Serialize>(name: &str, value: &T, public: &str) -> Value {
    json!({"name":name,"kind":T::KIND,"public_key":public,"document":value,"canonical_json":String::from_utf8(value.canonical_payload().unwrap()).unwrap(),"signing_bytes_b64":encode_bytes(&value.signing_bytes().unwrap()),"signature":value.signature()})
}
#[test]
fn shared_vectors_match_exact_wire_bytes() {
    let req = request();
    let fixture = json!({
        "format":"EnvelopeHA/V2 test vectors 1",
        "warning":"Deterministic test identities only. Never use these keys in production.",
        "now_ms":NOW.to_string(),
        "administrator_public":public(1),"sender_contact":contact(4),"recipient_contact":contact(5),"binding":binding(),"signed_request":req,
        "valid":[vector("cluster_config",&config(),&public(1)),vector("cluster_status",&status(),&public(2)),vector("prepare_ack",&ack(2),&public(2)),vector("commit_receipt",&receipt(),&public(2)),vector("recipient_delivered",&result(RecipientOutcome::Delivered,1),&public(5)),vector("request_auth",&req.auth,&public(4)),vector("rotated_cluster_config",&rotated_config(),&public(1)),vector("historical_commit_receipt",&historical_receipt(),&public(6)),vector("expired_commit_receipt",&expired_receipt(),&public(2))],
        "invalid_decimal_json":["0","\"01\"","\"-1\"","\"18446744073709551616\""],
        "duplicate_recipient_result_json":serde_json::to_string(&result(RecipientOutcome::Delivered,1)).unwrap().replacen("\"version\":2","\"version\":2,\"version\":2",1),
        "invalid_cases":[
          {"source":"cluster_status","mutation":"nonce","replacement":"another-client-nonce","reason":"signature and challenge binding"},
          {"source":"cluster_status","mutation":"applied_index","replacement":"41","reason":"ready requires applied control head even after valid resign"},
          {"source":"commit_receipt","mutation":"replica_evidence","replacement":"duplicate first ack as second ack","reason":"distinct business replicas required even after valid resign"},
          {"source":"recipient_delivered","mutation":"envelope_sha256","replacement":sha256_b64(b"tampered"),"reason":"content binding"}
        ]
    });
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/ha-v2/vectors.json");
    if std::env::var_os("REGENERATE_HA_VECTORS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            format!("{}\n", serde_json::to_string_pretty(&fixture).unwrap()),
        )
        .unwrap();
    }
    let persisted: Value = serde_json::from_slice(
        &std::fs::read(path)
            .expect("missing HA vectors; explicitly regenerate with REGENERATE_HA_VECTORS=1"),
    )
    .unwrap();
    assert_eq!(
        persisted, fixture,
        "wire contract changed; review all platforms before regenerating fixtures"
    );
    for v in persisted["valid"].as_array().unwrap() {
        let input = decode_bytes(v["signing_bytes_b64"].as_str().unwrap(), "vector").unwrap();
        let key = VerifyingKey::from_bytes(
            &fixed_bytes::<32>("key", v["public_key"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        let sig = ed25519_dalek::Signature::from_bytes(
            &fixed_bytes::<64>("sig", v["signature"].as_str().unwrap()).unwrap(),
        );
        key.verify_strict(&input, &sig).unwrap();
    }
}
