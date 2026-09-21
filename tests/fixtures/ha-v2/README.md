# Envelope HA v2 cross-platform vectors

`vectors.json` freezes the six signed wire formats and historical rotation cases implemented in
`crates/envelope-server-core/src/ha.rs`. All keys and identities in this fixture
are deterministic **test material**, never deployment credentials.

Each `valid` item supplies the typed JSON document, signer public key, exact
compact fixed-order JSON array, exact domain-separated signing bytes as unpadded
base64url, and Ed25519 signature. JSON object member order does not affect those
typed arrays. Duplicate members and unknown DTO fields must be rejected before
converting input into a generic map. Sequence numbers and milliseconds use
canonical unsigned decimal strings (including values above JavaScript's safe
integer range); protocol version fields remain JSON integers.

Verification input is `ASCII("EnvelopeHA/V2/" + kind) || 0x00 || UTF8(array)`.
Nested prepare evidence in `CommitReceipt` is an array of
`[prepare_ack_unsigned_array, prepare_ack_signature]`, sorted by node ID.
All binary fields use unpadded base64url. No v1 context prefix is added.

A historical receipt retains its original commit scope and includes a separately
administrator-signed `proof_config`. `issuer_control_generation` and
`issuer_config_epoch` identify the current node signing that historical evidence.
The archived config is encoded in the receipt's signing array as
`[archived_config_unsigned_array, administrator_signature]`; discovery expiry
does not erase old proof validity. Archived node keys cannot authorize new
status responses or impersonate the current receipt signer.

The final receipt array item is `expiry_evidence` (or null), encoded as
`[operation_id, expected_object_version, expired_at, commit_index,
[[ack_unsigned_array, ack_signature], ...], proof_config_or_null]`.
An expired receipt requires this independently signed two-replica decision.
Its logical hash uses `EnvelopeHA/V2/ExpireEnvelope` and binds the original
envelope tuple, fixed TTL, prior object version and expiration time. Reusing
StoreEnvelope acknowledgments, one replica, early expiration, old commit index,
or untrusted historical keys cannot authorize expiration. The ninth valid
vector is `expired_commit_receipt`.

The signature does not replace policy checks. The Rust tests also check stale
challenges, data watermarks, configuration/term rollback, distinct replica keys,
fixed TTL/content binding, recipient identity, result ordering, and terminal
state transitions. A server receipt alone never proves recipient delivery.

Run `cargo test -p envelope-server-core --lib` to verify these fixtures. A
deliberate cross-platform schema change can regenerate them by setting
`REGENERATE_HA_VECTORS=1` for that command; review every client before accepting
the new bytes. Ordinary tests do not rewrite fixtures.
