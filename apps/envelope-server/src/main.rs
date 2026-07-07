use anyhow::{Context, Result, bail};
use axum::{
    Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use clap::Parser;
use envelope_core::{Contact, DeviceEndpointUpdate};
use envelope_server_core::{
    AntiAbuseLimits, DeliveryStatusItem, DeliveryStatusRequest, DeliveryStatusResponse,
    DeviceRegistrationRequest, DeviceRegistrationResponse, EnvelopeSubmitRequest,
    EnvelopeSubmitResponse, IntroSessionPollResponse, IntroSessionPublishRequest,
    IntroSessionPublishResponse, IntroSessionRespondRequest, IntroSessionRespondResponse,
    MailboxAckRequest, MailboxAckResponse, MailboxEnvelope, MailboxPullRequest,
    MailboxPullResponse, NodeChallengeRequest, NodeChallengeResponse, NodeDescriptor,
    NodeSetManifest, RouteLookupResponse, SERVER_PROTOCOL_VERSION, STATUS_OK, ServerCoreError,
    bounded_pull_limit, validate_mailbox_capacity,
};
use serde::{Deserialize, Serialize};
use sqlx::{
    Row, SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
};
use std::{
    collections::{HashMap, HashSet},
    env,
    net::{IpAddr, SocketAddr},
    path::{Path as FsPath, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{signal, time::MissedTickBehavior};

const SUBMIT_RATE_WINDOW_MS: u128 = 60 * 1000;
const ENV_NODE_MANIFEST: &str = "ENVELOPE_SERVER_NODE_MANIFEST";
const ENV_MANIFEST_PUBLIC_KEY: &str = "ENVELOPE_SERVER_MANIFEST_PUBLIC_KEY";
const ENV_NODE_ID: &str = "ENVELOPE_SERVER_NODE_ID";
const ENV_NODE_SIGNING_SECRET_FILE: &str = "ENVELOPE_SERVER_NODE_SIGNING_SECRET_FILE";
const DEFAULT_NODE_SYNC_INTERVAL_SECONDS: u64 = 15;
const DEFAULT_NODE_SYNC_MAX_RECORDS_PER_TABLE: u32 = 500;
const EXPIRED_CLEANUP_INTERVAL_SECONDS: u64 = 5 * 60;
const NODE_SYNC_SIGNATURE_CONTEXT: &str = "envelope server node sync v1";
const NODE_SYNC_PATH: &str = "v1/nodes/sync";
const NODE_SYNC_HTTP_TIMEOUT_SECONDS: u64 = 60;

#[derive(Debug, Parser)]
#[command(name = "envelope-server")]
#[command(about = "Envelope Server MVP: signed endpoint routing and opaque mailbox storage")]
struct Args {
    #[arg(long, default_value = "127.0.0.1:19093")]
    bind: SocketAddr,
    #[arg(long, default_value = "target/envelope-server/envelope-server.sqlite3")]
    database: PathBuf,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_ENVELOPE_BYTES)]
    max_envelope_bytes: usize,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_MAILBOX_ENVELOPES)]
    max_mailbox_envelopes: usize,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_MAILBOX_BYTES)]
    max_mailbox_bytes: usize,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_GLOBAL_MAILBOX_BYTES)]
    max_global_mailbox_bytes: usize,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_SUBMIT_PER_SENDER_PER_MINUTE)]
    max_submit_per_sender_per_minute: u32,
    #[arg(long, default_value_t = envelope_server_core::DEFAULT_MAX_SUBMIT_PER_IP_PER_MINUTE)]
    max_submit_per_ip_per_minute: u32,
    #[arg(long)]
    max_http_body_bytes: Option<usize>,
    #[arg(long)]
    node_manifest: Option<PathBuf>,
    #[arg(long)]
    manifest_public_key: Option<String>,
    #[arg(long)]
    node_id: Option<String>,
    #[arg(long)]
    node_signing_secret_file: Option<PathBuf>,
    #[arg(long)]
    disable_node_sync: bool,
    #[arg(long, default_value_t = DEFAULT_NODE_SYNC_INTERVAL_SECONDS)]
    node_sync_interval_seconds: u64,
    #[arg(long, default_value_t = DEFAULT_NODE_SYNC_MAX_RECORDS_PER_TABLE)]
    node_sync_max_records_per_table: u32,
}

#[derive(Clone)]
struct AppState {
    pool: SqlitePool,
    limits: AntiAbuseLimits,
    submit_rate_limiter: Arc<Mutex<SubmitRateLimiter>>,
    node_manifest: Option<Arc<NodeSetManifest>>,
    node_identity: Option<Arc<NodeIdentity>>,
}

#[derive(Debug, Default)]
struct SubmitRateLimiter {
    by_ip: HashMap<String, RateBucket>,
    by_sender: HashMap<String, RateBucket>,
}

#[derive(Debug, Clone)]
struct RateBucket {
    window_start_unix_ms: u128,
    count: u32,
}

#[derive(Debug, Clone)]
struct NodeIdentity {
    node_id: String,
    signing_secret: String,
}

#[derive(Debug, Clone)]
struct NodeSyncConfig {
    interval: Duration,
    max_records_per_table: u32,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    version: u16,
    status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeSyncPushRequest {
    version: u16,
    source_node_id: String,
    manifest_id: String,
    manifest_epoch: u64,
    pushed_at_unix_ms: u128,
    device_routes: Vec<NodeSyncDeviceRoute>,
    mailbox_envelopes: Vec<NodeSyncMailboxEnvelope>,
    delivery_receipts: Vec<NodeSyncDeliveryReceipt>,
    mailbox_ack_tombstones: Vec<NodeSyncMailboxAckTombstone>,
    signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeSyncDeviceRoute {
    owner_key_id: String,
    device_id: String,
    owner_contact_json: String,
    endpoint_json: String,
    expires_at_unix_ms: u128,
    updated_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeSyncMailboxEnvelope {
    recipient_key_id: String,
    envelope_id: String,
    sender_key_id: String,
    envelope_sha256: Option<String>,
    envelope_b64: String,
    received_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeSyncDeliveryReceipt {
    sender_key_id: String,
    envelope_id: String,
    recipient_key_id: String,
    delivered_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NodeSyncMailboxAckTombstone {
    recipient_key_id: String,
    envelope_id: String,
    sender_key_id: Option<String>,
    acked_at_unix_ms: u128,
    expires_at_unix_ms: u128,
}

#[derive(Debug, Serialize)]
struct NodeSyncSigningPayload<'a> {
    version: u16,
    source_node_id: &'a str,
    manifest_id: &'a str,
    manifest_epoch: u64,
    pushed_at_unix_ms: u128,
    device_routes: &'a [NodeSyncDeviceRoute],
    mailbox_envelopes: &'a [NodeSyncMailboxEnvelope],
    delivery_receipts: &'a [NodeSyncDeliveryReceipt],
    mailbox_ack_tombstones: &'a [NodeSyncMailboxAckTombstone],
}

#[derive(Debug, Serialize, Deserialize)]
struct NodeSyncPushResponse {
    version: u16,
    status: String,
    applied: NodeSyncAppliedCounts,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct NodeSyncAppliedCounts {
    device_routes: u64,
    mailbox_envelopes: u64,
    delivery_receipts: u64,
    mailbox_ack_tombstones: u64,
    mailbox_deleted_by_tombstone: u64,
}

#[derive(Debug, Default, Clone)]
struct NodeSyncCursor {
    device_routes_after_unix_ms: u128,
    device_routes_after_owner_key_id: String,
    device_routes_after_device_id: String,
    mailbox_envelopes_after_unix_ms: u128,
    mailbox_envelopes_after_recipient_key_id: String,
    mailbox_envelopes_after_envelope_id: String,
    delivery_receipts_after_unix_ms: u128,
    delivery_receipts_after_sender_key_id: String,
    delivery_receipts_after_envelope_id: String,
    mailbox_ack_tombstones_after_unix_ms: u128,
    mailbox_ack_tombstones_after_recipient_key_id: String,
    mailbox_ack_tombstones_after_envelope_id: String,
}

impl NodeSyncCursor {
    fn advance_device_routes(
        &mut self,
        updated_at_unix_ms: u128,
        owner_key_id: String,
        device_id: String,
    ) {
        self.device_routes_after_unix_ms = updated_at_unix_ms;
        self.device_routes_after_owner_key_id = owner_key_id;
        self.device_routes_after_device_id = device_id;
    }

    fn advance_mailbox_envelopes(
        &mut self,
        received_at_unix_ms: u128,
        recipient_key_id: String,
        envelope_id: String,
    ) {
        self.mailbox_envelopes_after_unix_ms = received_at_unix_ms;
        self.mailbox_envelopes_after_recipient_key_id = recipient_key_id;
        self.mailbox_envelopes_after_envelope_id = envelope_id;
    }

    fn advance_delivery_receipts(
        &mut self,
        delivered_at_unix_ms: u128,
        sender_key_id: String,
        envelope_id: String,
    ) {
        self.delivery_receipts_after_unix_ms = delivered_at_unix_ms;
        self.delivery_receipts_after_sender_key_id = sender_key_id;
        self.delivery_receipts_after_envelope_id = envelope_id;
    }

    fn advance_mailbox_ack_tombstones(
        &mut self,
        acked_at_unix_ms: u128,
        recipient_key_id: String,
        envelope_id: String,
    ) {
        self.mailbox_ack_tombstones_after_unix_ms = acked_at_unix_ms;
        self.mailbox_ack_tombstones_after_recipient_key_id = recipient_key_id;
        self.mailbox_ack_tombstones_after_envelope_id = envelope_id;
    }
}

#[derive(Debug, Clone)]
struct NodeSyncSnapshot {
    device_routes: Vec<NodeSyncDeviceRoute>,
    mailbox_envelopes: Vec<NodeSyncMailboxEnvelope>,
    delivery_receipts: Vec<NodeSyncDeliveryReceipt>,
    mailbox_ack_tombstones: Vec<NodeSyncMailboxAckTombstone>,
    next_cursor: NodeSyncCursor,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

#[derive(Debug)]
enum AppError {
    BadRequest(String),
    Conflict(String),
    NotFound(String),
    PayloadTooLarge(String),
    TooManyRequests(String),
    Internal(anyhow::Error),
}

type AppResult<T> = std::result::Result<T, AppError>;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "envelope_server=info,tower_http=info".into()),
        )
        .init();

    let args = Args::parse();
    let limits = AntiAbuseLimits {
        max_envelope_bytes: args.max_envelope_bytes,
        max_mailbox_envelopes: args.max_mailbox_envelopes,
        max_mailbox_bytes: args.max_mailbox_bytes,
        max_global_mailbox_bytes: args.max_global_mailbox_bytes,
        max_submit_per_sender_per_minute: args.max_submit_per_sender_per_minute,
        max_submit_per_ip_per_minute: args.max_submit_per_ip_per_minute,
        ..AntiAbuseLimits::default()
    };
    let max_http_body_bytes = args.max_http_body_bytes.unwrap_or_else(|| {
        args.max_envelope_bytes
            .saturating_mul(2)
            .saturating_add(64 * 1024)
    });
    let pool = open_database(&args.database).await?;
    migrate(&pool).await?;
    let node_manifest_path = path_arg_or_env(args.node_manifest, ENV_NODE_MANIFEST);
    let manifest_public_key = string_arg_or_env(args.manifest_public_key, ENV_MANIFEST_PUBLIC_KEY);
    let node_id = string_arg_or_env(args.node_id, ENV_NODE_ID);
    let node_signing_secret_file =
        path_arg_or_env(args.node_signing_secret_file, ENV_NODE_SIGNING_SECRET_FILE);
    let node_manifest =
        load_configured_node_manifest(node_manifest_path, manifest_public_key).await?;
    let node_identity =
        load_configured_node_identity(node_id, node_signing_secret_file, node_manifest.as_ref())
            .await?;
    let node_sync_config = node_sync_config_from_args(
        args.disable_node_sync,
        args.node_sync_interval_seconds,
        args.node_sync_max_records_per_table,
    )?;

    let state = AppState {
        pool,
        limits,
        submit_rate_limiter: Arc::new(Mutex::new(SubmitRateLimiter::default())),
        node_manifest: node_manifest.map(Arc::new),
        node_identity: node_identity.map(Arc::new),
    };
    start_expired_cleanup_worker(state.clone());
    if let Some(config) = node_sync_config {
        start_node_sync_worker(state.clone(), config);
    } else {
        tracing::info!("node sync disabled by configuration");
    }
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/devices/register", put(register_device))
        .route("/v1/routes/{owner_key_id}/{device_id}", get(lookup_route))
        .route("/v1/envelopes", post(submit_envelope))
        .route("/v1/mailbox/{recipient_key_id}/pull", post(pull_mailbox))
        .route("/v1/mailbox/{recipient_key_id}/ack", post(ack_mailbox))
        .route("/v1/delivery/{sender_key_id}/status", post(delivery_status))
        .route("/v1/nodes/manifest", get(get_node_manifest))
        .route("/v1/nodes/sync", post(node_sync_push))
        .route("/v1/node/challenge", post(node_challenge))
        .route(
            "/v1/intro-sessions/{session_id}",
            put(publish_intro_session),
        )
        .route(
            "/v1/intro-sessions/{session_id}/response",
            post(respond_intro_session).get(poll_intro_session),
        )
        .layer(DefaultBodyLimit::max(max_http_body_bytes))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(args.bind)
        .await
        .with_context(|| format!("bind {}", args.bind))?;
    tracing::info!("envelope-server listening on http://{}", args.bind);
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await
    .context("serve envelope-server")?;
    Ok(())
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        version: SERVER_PROTOCOL_VERSION,
        status: STATUS_OK.to_string(),
    })
}

async fn get_node_manifest(State(state): State<AppState>) -> AppResult<Json<NodeSetManifest>> {
    let manifest = state
        .node_manifest
        .as_ref()
        .ok_or_else(|| AppError::NotFound("node manifest is not configured".to_string()))?;
    Ok(Json((**manifest).clone()))
}

async fn node_challenge(
    State(state): State<AppState>,
    Json(request): Json<NodeChallengeRequest>,
) -> AppResult<Json<NodeChallengeResponse>> {
    let now = now_unix_ms()?;
    let node_identity = state
        .node_identity
        .as_ref()
        .ok_or_else(|| AppError::NotFound("node identity is not configured".to_string()))?;
    if request.node_id != node_identity.node_id {
        return Err(AppError::BadRequest(
            "challenge node_id does not match this node".to_string(),
        ));
    }
    request
        .validate(now, state.limits.max_control_clock_skew_ms)
        .map_err(AppError::from_core)?;
    let response = NodeChallengeResponse::create(
        &node_identity.node_id,
        &node_identity.signing_secret,
        &request,
        now,
    )
    .context("sign node challenge")
    .map_err(AppError::Internal)?;
    Ok(Json(response))
}

async fn node_sync_push(
    State(state): State<AppState>,
    Json(request): Json<NodeSyncPushRequest>,
) -> AppResult<Json<NodeSyncPushResponse>> {
    let now = now_unix_ms()?;
    validate_node_sync_push(&state, &request, now)?;
    let applied = apply_node_sync_push(&state, &request, now).await?;
    Ok(Json(NodeSyncPushResponse {
        version: SERVER_PROTOCOL_VERSION,
        status: STATUS_OK.to_string(),
        applied,
    }))
}

fn validate_node_sync_push(
    state: &AppState,
    request: &NodeSyncPushRequest,
    now_unix_ms: u128,
) -> AppResult<()> {
    if request.version != SERVER_PROTOCOL_VERSION {
        return Err(AppError::BadRequest(format!(
            "unsupported node sync version {}",
            request.version
        )));
    }
    let manifest = state
        .node_manifest
        .as_ref()
        .ok_or_else(|| AppError::NotFound("node manifest is not configured".to_string()))?;
    if request.manifest_id != manifest.manifest_id {
        return Err(AppError::BadRequest(
            "node sync manifest_id does not match this node".to_string(),
        ));
    }
    if request.manifest_epoch != manifest.epoch {
        return Err(AppError::BadRequest(
            "node sync manifest_epoch does not match this node".to_string(),
        ));
    }
    if let Some(identity) = &state.node_identity {
        if request.source_node_id == identity.node_id {
            return Err(AppError::BadRequest(
                "node sync source_node_id must not be this node".to_string(),
            ));
        }
    }
    if manifest
        .revoked_node_ids
        .iter()
        .any(|node_id| node_id == &request.source_node_id)
    {
        return Err(AppError::BadRequest(
            "node sync source_node_id is revoked".to_string(),
        ));
    }
    let source_node = manifest
        .node(&request.source_node_id)
        .ok_or_else(|| AppError::BadRequest("node sync source_node_id is unknown".to_string()))?;
    if source_node.valid_until_unix_ms < now_unix_ms {
        return Err(AppError::BadRequest(
            "node sync source node is expired".to_string(),
        ));
    }
    if !node_supports_sync(source_node) {
        return Err(AppError::BadRequest(
            "node sync source node does not advertise sync capabilities".to_string(),
        ));
    }
    validate_control_timestamp(
        "pushed_at_unix_ms",
        request.pushed_at_unix_ms,
        now_unix_ms,
        state.limits.max_control_clock_skew_ms,
    )?;
    if request.signature.trim().is_empty() {
        return Err(AppError::BadRequest(
            "node sync signature is required".to_string(),
        ));
    }
    let payload = node_sync_signature_payload(request)
        .context("serialize node sync signature payload")
        .map_err(AppError::Internal)?;
    envelope_core::verify_context_payload_with_public(
        &source_node.public_key,
        NODE_SYNC_SIGNATURE_CONTEXT,
        &payload,
        &request.signature,
    )
    .map_err(|error| AppError::BadRequest(format!("invalid node sync signature: {error}")))?;
    Ok(())
}

fn validate_control_timestamp(
    field: &'static str,
    timestamp_unix_ms: u128,
    now_unix_ms: u128,
    max_clock_skew_ms: u128,
) -> AppResult<()> {
    let lower_bound = now_unix_ms.saturating_sub(max_clock_skew_ms);
    let upper_bound = now_unix_ms.saturating_add(max_clock_skew_ms);
    if timestamp_unix_ms < lower_bound || timestamp_unix_ms > upper_bound {
        return Err(AppError::BadRequest(format!(
            "{field} is outside allowed clock skew"
        )));
    }
    Ok(())
}

async fn apply_node_sync_push(
    state: &AppState,
    request: &NodeSyncPushRequest,
    now_unix_ms: u128,
) -> AppResult<NodeSyncAppliedCounts> {
    let mut transaction = state.pool.begin().await?;
    let mut applied = NodeSyncAppliedCounts::default();
    let now = to_i64_ms(now_unix_ms, "now_unix_ms")?;

    for tombstone in &request.mailbox_ack_tombstones {
        if tombstone.expires_at_unix_ms < now_unix_ms {
            continue;
        }
        let result = sqlx::query(
            r#"
            INSERT INTO mailbox_ack_tombstones (
                recipient_key_id,
                envelope_id,
                sender_key_id,
                acked_at_unix_ms,
                expires_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recipient_key_id, envelope_id) DO UPDATE SET
                sender_key_id = COALESCE(excluded.sender_key_id, mailbox_ack_tombstones.sender_key_id),
                acked_at_unix_ms = excluded.acked_at_unix_ms,
                expires_at_unix_ms = excluded.expires_at_unix_ms
            WHERE excluded.acked_at_unix_ms >= mailbox_ack_tombstones.acked_at_unix_ms
            "#,
        )
        .bind(&tombstone.recipient_key_id)
        .bind(&tombstone.envelope_id)
        .bind(tombstone.sender_key_id.as_deref())
        .bind(to_i64_ms(tombstone.acked_at_unix_ms, "acked_at_unix_ms")?)
        .bind(to_i64_ms(tombstone.expires_at_unix_ms, "expires_at_unix_ms")?)
        .execute(&mut *transaction)
        .await?;
        applied.mailbox_ack_tombstones = applied
            .mailbox_ack_tombstones
            .saturating_add(result.rows_affected());
        let result = sqlx::query(
            r#"
            DELETE FROM mailbox_envelopes
            WHERE recipient_key_id = ? AND envelope_id = ?
            "#,
        )
        .bind(&tombstone.recipient_key_id)
        .bind(&tombstone.envelope_id)
        .execute(&mut *transaction)
        .await?;
        applied.mailbox_deleted_by_tombstone = applied
            .mailbox_deleted_by_tombstone
            .saturating_add(result.rows_affected());
    }

    for route in &request.device_routes {
        if route.expires_at_unix_ms < now_unix_ms {
            continue;
        }
        serde_json::from_str::<Contact>(&route.owner_contact_json)
            .context("parse synced owner contact")
            .map_err(AppError::Internal)?;
        serde_json::from_str::<DeviceEndpointUpdate>(&route.endpoint_json)
            .context("parse synced endpoint")
            .map_err(AppError::Internal)?;
        let result = sqlx::query(
            r#"
            INSERT INTO device_routes (
                owner_key_id,
                device_id,
                owner_contact_json,
                endpoint_json,
                expires_at_unix_ms,
                updated_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(owner_key_id, device_id) DO UPDATE SET
                owner_contact_json = excluded.owner_contact_json,
                endpoint_json = excluded.endpoint_json,
                expires_at_unix_ms = excluded.expires_at_unix_ms,
                updated_at_unix_ms = excluded.updated_at_unix_ms
            WHERE excluded.updated_at_unix_ms >= device_routes.updated_at_unix_ms
            "#,
        )
        .bind(&route.owner_key_id)
        .bind(&route.device_id)
        .bind(&route.owner_contact_json)
        .bind(&route.endpoint_json)
        .bind(to_i64_ms(route.expires_at_unix_ms, "expires_at_unix_ms")?)
        .bind(to_i64_ms(route.updated_at_unix_ms, "updated_at_unix_ms")?)
        .execute(&mut *transaction)
        .await?;
        applied.device_routes = applied.device_routes.saturating_add(result.rows_affected());
    }

    for envelope in &request.mailbox_envelopes {
        if envelope.expires_at_unix_ms < now_unix_ms {
            continue;
        }
        let acked = sqlx::query(
            r#"
            SELECT 1
            FROM mailbox_ack_tombstones
            WHERE recipient_key_id = ? AND envelope_id = ? AND expires_at_unix_ms >= ?
            "#,
        )
        .bind(&envelope.recipient_key_id)
        .bind(&envelope.envelope_id)
        .bind(now)
        .fetch_optional(&mut *transaction)
        .await?;
        if acked.is_some() {
            continue;
        }
        let envelope_bytes = envelope_core::decode_bytes(&envelope.envelope_b64, "envelope_b64")
            .context("decode synced mailbox envelope")
            .map_err(AppError::Internal)?;
        if envelope_bytes.len() > state.limits.max_envelope_bytes {
            return Err(AppError::PayloadTooLarge(format!(
                "synced envelope is too large: {} > {} bytes",
                envelope_bytes.len(),
                state.limits.max_envelope_bytes
            )));
        }
        if let Some(expected_hash) = &envelope.envelope_sha256 {
            let actual_hash = envelope_core::sha256_hex(&envelope_bytes);
            if expected_hash != &actual_hash {
                return Err(AppError::BadRequest(
                    "synced envelope_sha256 does not match envelope bytes".to_string(),
                ));
            }
        }
        let result = sqlx::query(
            r#"
            INSERT INTO mailbox_envelopes (
                recipient_key_id,
                envelope_id,
                sender_key_id,
                envelope_sha256,
                envelope_bytes,
                received_at_unix_ms,
                expires_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(recipient_key_id, envelope_id) DO NOTHING
            "#,
        )
        .bind(&envelope.recipient_key_id)
        .bind(&envelope.envelope_id)
        .bind(&envelope.sender_key_id)
        .bind(envelope.envelope_sha256.as_deref())
        .bind(envelope_bytes)
        .bind(to_i64_ms(
            envelope.received_at_unix_ms,
            "received_at_unix_ms",
        )?)
        .bind(to_i64_ms(
            envelope.expires_at_unix_ms,
            "expires_at_unix_ms",
        )?)
        .execute(&mut *transaction)
        .await?;
        applied.mailbox_envelopes = applied
            .mailbox_envelopes
            .saturating_add(result.rows_affected());
    }

    for receipt in &request.delivery_receipts {
        if receipt.expires_at_unix_ms < now_unix_ms {
            continue;
        }
        let result = sqlx::query(
            r#"
            INSERT INTO delivery_receipts (
                sender_key_id,
                envelope_id,
                recipient_key_id,
                delivered_at_unix_ms,
                expires_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(sender_key_id, envelope_id) DO UPDATE SET
                recipient_key_id = excluded.recipient_key_id,
                delivered_at_unix_ms = excluded.delivered_at_unix_ms,
                expires_at_unix_ms = excluded.expires_at_unix_ms
            WHERE excluded.delivered_at_unix_ms >= delivery_receipts.delivered_at_unix_ms
            "#,
        )
        .bind(&receipt.sender_key_id)
        .bind(&receipt.envelope_id)
        .bind(&receipt.recipient_key_id)
        .bind(to_i64_ms(
            receipt.delivered_at_unix_ms,
            "delivered_at_unix_ms",
        )?)
        .bind(to_i64_ms(receipt.expires_at_unix_ms, "expires_at_unix_ms")?)
        .execute(&mut *transaction)
        .await?;
        applied.delivery_receipts = applied
            .delivery_receipts
            .saturating_add(result.rows_affected());
    }

    transaction.commit().await?;
    Ok(applied)
}

async fn register_device(
    State(state): State<AppState>,
    Json(request): Json<DeviceRegistrationRequest>,
) -> AppResult<Json<DeviceRegistrationResponse>> {
    let now = now_unix_ms()?;
    request
        .validate(now, &state.limits)
        .map_err(AppError::from_core)?;

    let owner_contact_json = serde_json::to_string(&request.owner_contact)
        .context("serialize owner contact")
        .map_err(AppError::Internal)?;
    let endpoint_json = serde_json::to_string(&request.endpoint)
        .context("serialize endpoint")
        .map_err(AppError::Internal)?;
    sqlx::query(
        r#"
        INSERT INTO device_routes (
            owner_key_id,
            device_id,
            owner_contact_json,
            endpoint_json,
            expires_at_unix_ms,
            updated_at_unix_ms
        )
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_key_id, device_id) DO UPDATE SET
            owner_contact_json = excluded.owner_contact_json,
            endpoint_json = excluded.endpoint_json,
            expires_at_unix_ms = excluded.expires_at_unix_ms,
            updated_at_unix_ms = excluded.updated_at_unix_ms
        "#,
    )
    .bind(&request.endpoint.owner_identity_key_id)
    .bind(&request.endpoint.device_id)
    .bind(owner_contact_json)
    .bind(endpoint_json)
    .bind(to_i64_ms(
        request.endpoint.expires_at_unix_ms,
        "expires_at_unix_ms",
    )?)
    .bind(to_i64_ms(now, "updated_at_unix_ms")?)
    .execute(&state.pool)
    .await?;

    Ok(Json(request.accepted_response()))
}

async fn lookup_route(
    State(state): State<AppState>,
    Path((owner_key_id, device_id)): Path<(String, String)>,
) -> AppResult<Json<RouteLookupResponse>> {
    let now = now_unix_ms()?;
    let row = sqlx::query(
        r#"
        SELECT endpoint_json
        FROM device_routes
        WHERE owner_key_id = ? AND device_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&owner_key_id)
    .bind(&device_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_optional(&state.pool)
    .await?;
    let endpoint = row
        .map(|row| {
            let endpoint_json: String = row.get("endpoint_json");
            serde_json::from_str::<DeviceEndpointUpdate>(&endpoint_json)
        })
        .transpose()
        .context("parse stored endpoint")
        .map_err(AppError::Internal)?;

    Ok(Json(RouteLookupResponse {
        version: SERVER_PROTOCOL_VERSION,
        owner_identity_key_id: owner_key_id,
        device_id,
        endpoint,
    }))
}

async fn submit_envelope(
    State(state): State<AppState>,
    ConnectInfo(remote_addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<EnvelopeSubmitRequest>,
) -> AppResult<Json<EnvelopeSubmitResponse>> {
    let now = now_unix_ms()?;
    let client_ip = rate_limit_client_ip(remote_addr, &headers);
    check_submit_rate_limits(&state, &client_ip, &request.sender_key_id, now)?;
    let sender_contact = load_contact(&state.pool, &request.sender_key_id).await?;
    let envelope_bytes = request
        .verify(&sender_contact, now, &state.limits)
        .map_err(AppError::from_core)?;
    let stored_until = request
        .stored_until_unix_ms(now, &state.limits)
        .map_err(AppError::from_core)?;

    let acked = sqlx::query(
        r#"
        SELECT 1
        FROM mailbox_ack_tombstones
        WHERE recipient_key_id = ? AND envelope_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&request.recipient_key_id)
    .bind(&request.envelope_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_optional(&state.pool)
    .await?;
    if acked.is_some() {
        return Ok(Json(request.stored_response(stored_until)));
    }

    let duplicate = sqlx::query(
        r#"
        SELECT sender_key_id, envelope_sha256
        FROM mailbox_envelopes
        WHERE recipient_key_id = ? AND envelope_id = ?
        "#,
    )
    .bind(&request.recipient_key_id)
    .bind(&request.envelope_id)
    .fetch_optional(&state.pool)
    .await?;
    if let Some(row) = duplicate {
        let existing_sender: String = row.get("sender_key_id");
        let existing_hash: Option<String> = row.get("envelope_sha256");
        let same_submitter = existing_sender == request.sender_key_id;
        let same_hash = existing_hash
            .as_deref()
            .map(|hash| hash == request.envelope_sha256)
            .unwrap_or(true);
        if same_submitter && same_hash {
            return Ok(Json(request.stored_response(stored_until)));
        }
        return Err(AppError::Conflict(
            "envelope_id already exists for this recipient with different submit metadata"
                .to_string(),
        ));
    }

    let stats = sqlx::query(
        r#"
        SELECT COUNT(*) AS envelope_count, COALESCE(SUM(LENGTH(envelope_bytes)), 0) AS mailbox_bytes
        FROM mailbox_envelopes
        WHERE recipient_key_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&request.recipient_key_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_one(&state.pool)
    .await?;
    let envelope_count: i64 = stats.get("envelope_count");
    let mailbox_bytes: i64 = stats.get("mailbox_bytes");
    validate_mailbox_capacity(
        usize::try_from(envelope_count).unwrap_or(usize::MAX),
        usize::try_from(mailbox_bytes).unwrap_or(usize::MAX),
        envelope_bytes.len(),
        &state.limits,
    )
    .map_err(AppError::from_core)?;

    let global_mailbox_bytes: i64 = sqlx::query_scalar(
        r#"
        SELECT COALESCE(SUM(LENGTH(envelope_bytes)), 0)
        FROM mailbox_envelopes
        WHERE expires_at_unix_ms >= ?
        "#,
    )
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_one(&state.pool)
    .await?;
    let global_mailbox_bytes = usize::try_from(global_mailbox_bytes).unwrap_or(usize::MAX);
    if global_mailbox_bytes.saturating_add(envelope_bytes.len())
        > state.limits.max_global_mailbox_bytes
    {
        return Err(AppError::TooManyRequests(format!(
            "global mailbox bytes would exceed {}",
            state.limits.max_global_mailbox_bytes
        )));
    }

    sqlx::query(
        r#"
        INSERT INTO mailbox_envelopes (
            recipient_key_id,
            envelope_id,
            sender_key_id,
            envelope_sha256,
            envelope_bytes,
            received_at_unix_ms,
            expires_at_unix_ms
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        "#,
    )
    .bind(&request.recipient_key_id)
    .bind(&request.envelope_id)
    .bind(&request.sender_key_id)
    .bind(&request.envelope_sha256)
    .bind(envelope_bytes)
    .bind(to_i64_ms(now, "received_at_unix_ms")?)
    .bind(to_i64_ms(stored_until, "expires_at_unix_ms")?)
    .execute(&state.pool)
    .await?;

    Ok(Json(request.stored_response(stored_until)))
}

async fn pull_mailbox(
    State(state): State<AppState>,
    Path(recipient_key_id): Path<String>,
    Json(request): Json<MailboxPullRequest>,
) -> AppResult<Json<MailboxPullResponse>> {
    if request.recipient_key_id != recipient_key_id {
        return Err(AppError::BadRequest(
            "path recipient_key_id does not match pull body".to_string(),
        ));
    }
    let now = now_unix_ms()?;
    let recipient_contact = load_contact(&state.pool, &recipient_key_id).await?;
    request
        .verify(&recipient_contact, now, &state.limits)
        .map_err(AppError::from_core)?;
    let limit = bounded_pull_limit(&request);
    let rows = sqlx::query(
        r#"
        SELECT envelope_id, sender_key_id, recipient_key_id, envelope_bytes, received_at_unix_ms, expires_at_unix_ms
        FROM mailbox_envelopes
        WHERE recipient_key_id = ? AND expires_at_unix_ms >= ?
        ORDER BY received_at_unix_ms ASC
        LIMIT ?
        "#,
    )
    .bind(&recipient_key_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .bind(i64::from(limit))
    .fetch_all(&state.pool)
    .await?;

    let envelopes = rows
        .into_iter()
        .map(|row| {
            let envelope_bytes: Vec<u8> = row.get("envelope_bytes");
            MailboxEnvelope::from_bytes(
                row.get::<String, _>("envelope_id"),
                row.get::<String, _>("sender_key_id"),
                row.get::<String, _>("recipient_key_id"),
                &envelope_bytes,
                from_i64_ms(row.get("received_at_unix_ms")),
                from_i64_ms(row.get("expires_at_unix_ms")),
            )
        })
        .collect();

    Ok(Json(MailboxPullResponse {
        version: SERVER_PROTOCOL_VERSION,
        recipient_key_id,
        envelopes,
    }))
}

async fn ack_mailbox(
    State(state): State<AppState>,
    Path(recipient_key_id): Path<String>,
    Json(request): Json<MailboxAckRequest>,
) -> AppResult<Json<MailboxAckResponse>> {
    if request.recipient_key_id != recipient_key_id {
        return Err(AppError::BadRequest(
            "path recipient_key_id does not match ack body".to_string(),
        ));
    }
    let now = now_unix_ms()?;
    let recipient_contact = load_contact(&state.pool, &recipient_key_id).await?;
    request
        .verify(&recipient_contact, now, &state.limits)
        .map_err(AppError::from_core)?;

    let mut transaction = state.pool.begin().await?;
    let mut deleted_count = 0;
    let receipt_expires_at = now
        .saturating_add(u128::from(state.limits.default_envelope_ttl_seconds).saturating_mul(1000));
    let tombstone_expires_at = receipt_expires_at;
    for envelope_id in &request.envelope_ids {
        let row = sqlx::query(
            r#"
            SELECT sender_key_id, recipient_key_id
            FROM mailbox_envelopes
            WHERE recipient_key_id = ? AND envelope_id = ?
            "#,
        )
        .bind(&recipient_key_id)
        .bind(envelope_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let sender_key_id = row
            .as_ref()
            .map(|row| row.get::<String, _>("sender_key_id"));
        if let Some(row) = row {
            sqlx::query(
                r#"
                INSERT INTO delivery_receipts (
                    sender_key_id,
                    envelope_id,
                    recipient_key_id,
                    delivered_at_unix_ms,
                    expires_at_unix_ms
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(sender_key_id, envelope_id) DO UPDATE SET
                    recipient_key_id = excluded.recipient_key_id,
                    delivered_at_unix_ms = excluded.delivered_at_unix_ms,
                    expires_at_unix_ms = excluded.expires_at_unix_ms
                "#,
            )
            .bind(row.get::<String, _>("sender_key_id"))
            .bind(envelope_id)
            .bind(row.get::<String, _>("recipient_key_id"))
            .bind(to_i64_ms(now, "delivered_at_unix_ms")?)
            .bind(to_i64_ms(receipt_expires_at, "expires_at_unix_ms")?)
            .execute(&mut *transaction)
            .await?;
        }
        sqlx::query(
            r#"
            INSERT INTO mailbox_ack_tombstones (
                recipient_key_id,
                envelope_id,
                sender_key_id,
                acked_at_unix_ms,
                expires_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(recipient_key_id, envelope_id) DO UPDATE SET
                sender_key_id = COALESCE(excluded.sender_key_id, mailbox_ack_tombstones.sender_key_id),
                acked_at_unix_ms = excluded.acked_at_unix_ms,
                expires_at_unix_ms = excluded.expires_at_unix_ms
            "#,
        )
        .bind(&recipient_key_id)
        .bind(envelope_id)
        .bind(sender_key_id.as_deref())
        .bind(to_i64_ms(request.acked_at_unix_ms, "acked_at_unix_ms")?)
        .bind(to_i64_ms(tombstone_expires_at, "expires_at_unix_ms")?)
        .execute(&mut *transaction)
        .await?;
        let result = sqlx::query(
            r#"
            DELETE FROM mailbox_envelopes
            WHERE recipient_key_id = ? AND envelope_id = ?
            "#,
        )
        .bind(&recipient_key_id)
        .bind(envelope_id)
        .execute(&mut *transaction)
        .await?;
        deleted_count += result.rows_affected();
    }
    transaction.commit().await?;

    Ok(Json(MailboxAckResponse {
        version: SERVER_PROTOCOL_VERSION,
        status: STATUS_OK.to_string(),
        deleted_count,
    }))
}

async fn delivery_status(
    State(state): State<AppState>,
    Path(sender_key_id): Path<String>,
    Json(request): Json<DeliveryStatusRequest>,
) -> AppResult<Json<DeliveryStatusResponse>> {
    if request.sender_key_id != sender_key_id {
        return Err(AppError::BadRequest(
            "path sender_key_id does not match status body".to_string(),
        ));
    }
    let now = now_unix_ms()?;
    let sender_contact = load_contact(&state.pool, &sender_key_id).await?;
    request
        .verify(&sender_contact, now, &state.limits)
        .map_err(AppError::from_core)?;

    let mut items = Vec::with_capacity(request.envelope_ids.len());
    for envelope_id in &request.envelope_ids {
        let receipt = sqlx::query(
            r#"
            SELECT recipient_key_id, delivered_at_unix_ms
            FROM delivery_receipts
            WHERE sender_key_id = ? AND envelope_id = ? AND expires_at_unix_ms >= ?
            "#,
        )
        .bind(&sender_key_id)
        .bind(envelope_id)
        .bind(to_i64_ms(now, "now_unix_ms")?)
        .fetch_optional(&state.pool)
        .await?;
        if let Some(row) = receipt {
            items.push(DeliveryStatusItem {
                envelope_id: envelope_id.clone(),
                recipient_key_id: Some(row.get("recipient_key_id")),
                status: "delivered".to_string(),
                delivered_at_unix_ms: Some(from_i64_ms(row.get("delivered_at_unix_ms"))),
            });
            continue;
        }

        let queued = sqlx::query(
            r#"
            SELECT recipient_key_id
            FROM mailbox_envelopes
            WHERE sender_key_id = ? AND envelope_id = ? AND expires_at_unix_ms >= ?
            "#,
        )
        .bind(&sender_key_id)
        .bind(envelope_id)
        .bind(to_i64_ms(now, "now_unix_ms")?)
        .fetch_optional(&state.pool)
        .await?;
        if let Some(row) = queued {
            items.push(DeliveryStatusItem {
                envelope_id: envelope_id.clone(),
                recipient_key_id: Some(row.get("recipient_key_id")),
                status: "queued".to_string(),
                delivered_at_unix_ms: None,
            });
        } else {
            items.push(DeliveryStatusItem {
                envelope_id: envelope_id.clone(),
                recipient_key_id: None,
                status: "unknown".to_string(),
                delivered_at_unix_ms: None,
            });
        }
    }

    Ok(Json(DeliveryStatusResponse {
        version: SERVER_PROTOCOL_VERSION,
        sender_key_id,
        items,
    }))
}

async fn publish_intro_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<IntroSessionPublishRequest>,
) -> AppResult<Json<IntroSessionPublishResponse>> {
    let now = now_unix_ms()?;
    request
        .validate(&session_id, now, &state.limits)
        .map_err(AppError::from_core)?;
    let owner_bundle_json = serde_json::to_string(&request.owner_bundle)
        .context("serialize owner intro bundle")
        .map_err(AppError::Internal)?;
    sqlx::query(
        r#"
        INSERT INTO intro_sessions (
            session_id,
            owner_key_id,
            owner_bundle_json,
            responder_key_id,
            responder_bundle_json,
            expires_at_unix_ms,
            updated_at_unix_ms
        )
        VALUES (?, ?, ?, NULL, NULL, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            owner_key_id = excluded.owner_key_id,
            owner_bundle_json = excluded.owner_bundle_json,
            responder_key_id = NULL,
            responder_bundle_json = NULL,
            expires_at_unix_ms = excluded.expires_at_unix_ms,
            updated_at_unix_ms = excluded.updated_at_unix_ms
        "#,
    )
    .bind(&session_id)
    .bind(&request.owner_bundle.contact.key_id)
    .bind(owner_bundle_json)
    .bind(to_i64_ms(
        request.owner_bundle.expires_at_unix_ms,
        "expires_at_unix_ms",
    )?)
    .bind(to_i64_ms(now, "updated_at_unix_ms")?)
    .execute(&state.pool)
    .await?;

    Ok(Json(request.accepted_response(session_id)))
}

async fn respond_intro_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    Json(request): Json<IntroSessionRespondRequest>,
) -> AppResult<Json<IntroSessionRespondResponse>> {
    let now = now_unix_ms()?;
    let responder = request
        .validate(&session_id, now, &state.limits)
        .map_err(AppError::from_core)?;
    let owner_key_id: Option<String> = sqlx::query_scalar(
        r#"
        SELECT owner_key_id
        FROM intro_sessions
        WHERE session_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&session_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_optional(&state.pool)
    .await?;
    let owner_key_id =
        owner_key_id.ok_or_else(|| AppError::NotFound("intro session not found".to_string()))?;
    if owner_key_id == responder.key_id {
        return Err(AppError::BadRequest(
            "responder must be different from intro session owner".to_string(),
        ));
    }
    let responder_bundle_json = serde_json::to_string(&request.responder_bundle)
        .context("serialize responder intro bundle")
        .map_err(AppError::Internal)?;
    sqlx::query(
        r#"
        UPDATE intro_sessions
        SET responder_key_id = ?,
            responder_bundle_json = ?,
            updated_at_unix_ms = ?
        WHERE session_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&responder.key_id)
    .bind(responder_bundle_json)
    .bind(to_i64_ms(now, "updated_at_unix_ms")?)
    .bind(&session_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .execute(&state.pool)
    .await?;

    Ok(Json(request.accepted_response(session_id)))
}

async fn poll_intro_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> AppResult<Json<IntroSessionPollResponse>> {
    let now = now_unix_ms()?;
    let row = sqlx::query(
        r#"
        SELECT owner_key_id, responder_bundle_json, updated_at_unix_ms
        FROM intro_sessions
        WHERE session_id = ? AND expires_at_unix_ms >= ?
        "#,
    )
    .bind(&session_id)
    .bind(to_i64_ms(now, "now_unix_ms")?)
    .fetch_optional(&state.pool)
    .await?;
    let row = row.ok_or_else(|| AppError::NotFound("intro session not found".to_string()))?;
    let responder_bundle = row
        .get::<Option<String>, _>("responder_bundle_json")
        .map(|bundle_json| serde_json::from_str(&bundle_json))
        .transpose()
        .context("parse responder intro bundle")
        .map_err(AppError::Internal)?;

    Ok(Json(IntroSessionPollResponse {
        version: SERVER_PROTOCOL_VERSION,
        session_id,
        owner_key_id: row.get("owner_key_id"),
        responder_bundle,
        updated_at_unix_ms: from_i64_ms(row.get("updated_at_unix_ms")),
    }))
}

fn node_sync_config_from_args(
    disabled: bool,
    interval_seconds: u64,
    max_records_per_table: u32,
) -> Result<Option<NodeSyncConfig>> {
    if disabled {
        return Ok(None);
    }
    if interval_seconds == 0 {
        bail!("--node-sync-interval-seconds must be greater than zero");
    }
    if max_records_per_table == 0 {
        bail!("--node-sync-max-records-per-table must be greater than zero");
    }
    Ok(Some(NodeSyncConfig {
        interval: Duration::from_secs(interval_seconds),
        max_records_per_table,
    }))
}

fn start_node_sync_worker(state: AppState, config: NodeSyncConfig) {
    if state.node_manifest.is_none() {
        tracing::info!("node sync not started because no node manifest is configured");
        return;
    }
    if state.node_identity.is_none() {
        tracing::info!("node sync not started because no node identity is configured");
        return;
    }
    tokio::spawn(async move {
        if let Err(error) = run_node_sync_worker(state, config).await {
            tracing::warn!("node sync worker stopped: {error:#}");
        }
    });
}

fn start_expired_cleanup_worker(state: AppState) {
    tokio::spawn(async move {
        loop {
            match now_unix_ms() {
                Ok(now) => {
                    if let Err(error) = cleanup_expired(&state.pool, now).await {
                        tracing::warn!("expired cleanup failed: {}", error.message());
                    }
                }
                Err(error) => tracing::warn!("expired cleanup clock failed: {}", error.message()),
            }
            tokio::time::sleep(Duration::from_secs(EXPIRED_CLEANUP_INTERVAL_SECONDS)).await;
        }
    });
}

async fn run_node_sync_worker(state: AppState, config: NodeSyncConfig) -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(NODE_SYNC_HTTP_TIMEOUT_SECONDS))
        .build()
        .context("build node sync HTTP client")?;
    let mut interval = tokio::time::interval(config.interval);
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
    tracing::info!(
        "node sync worker started, interval={}s, max_records_per_table={}",
        config.interval.as_secs(),
        config.max_records_per_table
    );
    loop {
        interval.tick().await;
        if let Err(error) = push_node_sync_once(&state, &client, &config).await {
            tracing::warn!("node sync push failed: {}", error.message());
        }
    }
}

async fn push_node_sync_once(
    state: &AppState,
    client: &reqwest::Client,
    config: &NodeSyncConfig,
) -> AppResult<()> {
    let now = now_unix_ms()?;
    let manifest = state
        .node_manifest
        .as_ref()
        .ok_or_else(|| AppError::NotFound("node manifest is not configured".to_string()))?;
    let identity = state
        .node_identity
        .as_ref()
        .ok_or_else(|| AppError::NotFound("node identity is not configured".to_string()))?;
    let peers = node_sync_peers(manifest, &identity.node_id, now);
    if peers.is_empty() {
        return Ok(());
    }
    for peer in peers {
        let cursor = load_node_sync_cursor(state, &peer.node_id).await?;
        let snapshot =
            load_node_sync_snapshot(state, now, config.max_records_per_table, &cursor).await?;
        if snapshot.is_empty() {
            continue;
        }
        let next_cursor = snapshot.next_cursor.clone();
        let request = build_node_sync_push_request(manifest, identity, now, snapshot)?;
        if let Err(error) = push_node_sync_to_peer(client, &peer, &request).await {
            tracing::warn!(
                "node sync push to {} ({}) failed: {error:#}",
                peer.node_id,
                peer.base_url
            );
            continue;
        }
        store_node_sync_cursor(state, &peer.node_id, &next_cursor, now).await?;
    }
    Ok(())
}

fn build_node_sync_push_request(
    manifest: &NodeSetManifest,
    identity: &NodeIdentity,
    now_unix_ms: u128,
    snapshot: NodeSyncSnapshot,
) -> AppResult<NodeSyncPushRequest> {
    let mut request = NodeSyncPushRequest {
        version: SERVER_PROTOCOL_VERSION,
        source_node_id: identity.node_id.clone(),
        manifest_id: manifest.manifest_id.clone(),
        manifest_epoch: manifest.epoch,
        pushed_at_unix_ms: now_unix_ms,
        device_routes: snapshot.device_routes,
        mailbox_envelopes: snapshot.mailbox_envelopes,
        delivery_receipts: snapshot.delivery_receipts,
        mailbox_ack_tombstones: snapshot.mailbox_ack_tombstones,
        signature: String::new(),
    };
    let payload = node_sync_signature_payload(&request)
        .context("serialize node sync signature payload")
        .map_err(AppError::Internal)?;
    request.signature = envelope_core::sign_context_payload_with_secret(
        &identity.signing_secret,
        NODE_SYNC_SIGNATURE_CONTEXT,
        &payload,
    )
    .context("sign node sync payload")
    .map_err(AppError::Internal)?;
    Ok(request)
}

async fn push_node_sync_to_peer(
    client: &reqwest::Client,
    peer: &NodeDescriptor,
    request: &NodeSyncPushRequest,
) -> Result<()> {
    let endpoint = format!("{}/{}", peer.base_url.trim_end_matches('/'), NODE_SYNC_PATH);
    let response = client
        .post(&endpoint)
        .json(request)
        .send()
        .await
        .with_context(|| format!("POST {endpoint}"))?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        bail!("POST {endpoint} returned {status}: {body}");
    }
    let response: NodeSyncPushResponse = response
        .json()
        .await
        .with_context(|| format!("parse node sync response from {endpoint}"))?;
    tracing::debug!(
        "node sync pushed to {}: route={}, mailbox={}, receipt={}, tombstone={}, deleted={}",
        peer.node_id,
        response.applied.device_routes,
        response.applied.mailbox_envelopes,
        response.applied.delivery_receipts,
        response.applied.mailbox_ack_tombstones,
        response.applied.mailbox_deleted_by_tombstone
    );
    Ok(())
}

async fn load_node_sync_snapshot(
    state: &AppState,
    now_unix_ms: u128,
    max_records_per_table: u32,
    cursor: &NodeSyncCursor,
) -> AppResult<NodeSyncSnapshot> {
    let now = to_i64_ms(now_unix_ms, "now_unix_ms")?;
    let limit = i64::from(max_records_per_table);
    let mut next_cursor = cursor.clone();
    let device_routes = sqlx::query(
        r#"
        SELECT owner_key_id, device_id, owner_contact_json, endpoint_json, expires_at_unix_ms, updated_at_unix_ms
        FROM device_routes
        WHERE expires_at_unix_ms >= ?
          AND (
            updated_at_unix_ms > ?
            OR (
              updated_at_unix_ms = ?
              AND (
                owner_key_id > ?
                OR (owner_key_id = ? AND device_id > ?)
              )
            )
          )
        ORDER BY updated_at_unix_ms ASC, owner_key_id ASC, device_id ASC
        LIMIT ?
        "#,
    )
    .bind(now)
    .bind(to_i64_ms(
        cursor.device_routes_after_unix_ms,
        "device_routes_after_unix_ms",
    )?)
    .bind(to_i64_ms(
        cursor.device_routes_after_unix_ms,
        "device_routes_after_unix_ms",
    )?)
    .bind(&cursor.device_routes_after_owner_key_id)
    .bind(&cursor.device_routes_after_owner_key_id)
    .bind(&cursor.device_routes_after_device_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?
    .into_iter()
    .map(|row| {
        let updated_at_unix_ms = from_i64_ms(row.get("updated_at_unix_ms"));
        let owner_key_id = row.get::<String, _>("owner_key_id");
        let device_id = row.get::<String, _>("device_id");
        next_cursor.advance_device_routes(
            updated_at_unix_ms,
            owner_key_id.clone(),
            device_id.clone(),
        );
        NodeSyncDeviceRoute {
            owner_key_id,
            device_id,
            owner_contact_json: row.get("owner_contact_json"),
            endpoint_json: row.get("endpoint_json"),
            expires_at_unix_ms: from_i64_ms(row.get("expires_at_unix_ms")),
            updated_at_unix_ms,
        }
    })
    .collect();

    let mailbox_envelopes = sqlx::query(
        r#"
        SELECT recipient_key_id, envelope_id, sender_key_id, envelope_sha256, envelope_bytes, received_at_unix_ms, expires_at_unix_ms
        FROM mailbox_envelopes
        WHERE expires_at_unix_ms >= ?
          AND (
            received_at_unix_ms > ?
            OR (
              received_at_unix_ms = ?
              AND (
                recipient_key_id > ?
                OR (recipient_key_id = ? AND envelope_id > ?)
              )
            )
          )
        ORDER BY received_at_unix_ms ASC, recipient_key_id ASC, envelope_id ASC
        LIMIT ?
        "#,
    )
    .bind(now)
    .bind(to_i64_ms(
        cursor.mailbox_envelopes_after_unix_ms,
        "mailbox_envelopes_after_unix_ms",
    )?)
    .bind(to_i64_ms(
        cursor.mailbox_envelopes_after_unix_ms,
        "mailbox_envelopes_after_unix_ms",
    )?)
    .bind(&cursor.mailbox_envelopes_after_recipient_key_id)
    .bind(&cursor.mailbox_envelopes_after_recipient_key_id)
    .bind(&cursor.mailbox_envelopes_after_envelope_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?
    .into_iter()
    .map(|row| {
        let envelope_bytes: Vec<u8> = row.get("envelope_bytes");
        let received_at_unix_ms = from_i64_ms(row.get("received_at_unix_ms"));
        let recipient_key_id = row.get::<String, _>("recipient_key_id");
        let envelope_id = row.get::<String, _>("envelope_id");
        next_cursor.advance_mailbox_envelopes(
            received_at_unix_ms,
            recipient_key_id.clone(),
            envelope_id.clone(),
        );
        NodeSyncMailboxEnvelope {
            recipient_key_id,
            envelope_id,
            sender_key_id: row.get("sender_key_id"),
            envelope_sha256: row.get("envelope_sha256"),
            envelope_b64: envelope_core::encode_bytes(&envelope_bytes),
            received_at_unix_ms,
            expires_at_unix_ms: from_i64_ms(row.get("expires_at_unix_ms")),
        }
    })
    .collect();

    let delivery_receipts = sqlx::query(
        r#"
        SELECT sender_key_id, envelope_id, recipient_key_id, delivered_at_unix_ms, expires_at_unix_ms
        FROM delivery_receipts
        WHERE expires_at_unix_ms >= ?
          AND (
            delivered_at_unix_ms > ?
            OR (
              delivered_at_unix_ms = ?
              AND (
                sender_key_id > ?
                OR (sender_key_id = ? AND envelope_id > ?)
              )
            )
          )
        ORDER BY delivered_at_unix_ms ASC, sender_key_id ASC, envelope_id ASC
        LIMIT ?
        "#,
    )
    .bind(now)
    .bind(to_i64_ms(
        cursor.delivery_receipts_after_unix_ms,
        "delivery_receipts_after_unix_ms",
    )?)
    .bind(to_i64_ms(
        cursor.delivery_receipts_after_unix_ms,
        "delivery_receipts_after_unix_ms",
    )?)
    .bind(&cursor.delivery_receipts_after_sender_key_id)
    .bind(&cursor.delivery_receipts_after_sender_key_id)
    .bind(&cursor.delivery_receipts_after_envelope_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?
    .into_iter()
    .map(|row| {
        let delivered_at_unix_ms = from_i64_ms(row.get("delivered_at_unix_ms"));
        let sender_key_id = row.get::<String, _>("sender_key_id");
        let envelope_id = row.get::<String, _>("envelope_id");
        next_cursor.advance_delivery_receipts(
            delivered_at_unix_ms,
            sender_key_id.clone(),
            envelope_id.clone(),
        );
        NodeSyncDeliveryReceipt {
            sender_key_id,
            envelope_id,
            recipient_key_id: row.get("recipient_key_id"),
            delivered_at_unix_ms,
            expires_at_unix_ms: from_i64_ms(row.get("expires_at_unix_ms")),
        }
    })
    .collect();

    let mailbox_ack_tombstones = sqlx::query(
        r#"
        SELECT recipient_key_id, envelope_id, sender_key_id, acked_at_unix_ms, expires_at_unix_ms
        FROM mailbox_ack_tombstones
        WHERE expires_at_unix_ms >= ?
          AND (
            acked_at_unix_ms > ?
            OR (
              acked_at_unix_ms = ?
              AND (
                recipient_key_id > ?
                OR (recipient_key_id = ? AND envelope_id > ?)
              )
            )
          )
        ORDER BY acked_at_unix_ms ASC, recipient_key_id ASC, envelope_id ASC
        LIMIT ?
        "#,
    )
    .bind(now)
    .bind(to_i64_ms(
        cursor.mailbox_ack_tombstones_after_unix_ms,
        "mailbox_ack_tombstones_after_unix_ms",
    )?)
    .bind(to_i64_ms(
        cursor.mailbox_ack_tombstones_after_unix_ms,
        "mailbox_ack_tombstones_after_unix_ms",
    )?)
    .bind(&cursor.mailbox_ack_tombstones_after_recipient_key_id)
    .bind(&cursor.mailbox_ack_tombstones_after_recipient_key_id)
    .bind(&cursor.mailbox_ack_tombstones_after_envelope_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?
    .into_iter()
    .map(|row| {
        let acked_at_unix_ms = from_i64_ms(row.get("acked_at_unix_ms"));
        let recipient_key_id = row.get::<String, _>("recipient_key_id");
        let envelope_id = row.get::<String, _>("envelope_id");
        next_cursor.advance_mailbox_ack_tombstones(
            acked_at_unix_ms,
            recipient_key_id.clone(),
            envelope_id.clone(),
        );
        NodeSyncMailboxAckTombstone {
            recipient_key_id,
            envelope_id,
            sender_key_id: row.get("sender_key_id"),
            acked_at_unix_ms,
            expires_at_unix_ms: from_i64_ms(row.get("expires_at_unix_ms")),
        }
    })
    .collect();

    Ok(NodeSyncSnapshot {
        device_routes,
        mailbox_envelopes,
        delivery_receipts,
        mailbox_ack_tombstones,
        next_cursor,
    })
}

impl NodeSyncSnapshot {
    fn is_empty(&self) -> bool {
        self.device_routes.is_empty()
            && self.mailbox_envelopes.is_empty()
            && self.delivery_receipts.is_empty()
            && self.mailbox_ack_tombstones.is_empty()
    }
}

async fn load_node_sync_cursor(state: &AppState, peer_node_id: &str) -> AppResult<NodeSyncCursor> {
    let row = sqlx::query(
        r#"
        SELECT
            device_routes_after_unix_ms,
            device_routes_after_owner_key_id,
            device_routes_after_device_id,
            mailbox_envelopes_after_unix_ms,
            mailbox_envelopes_after_recipient_key_id,
            mailbox_envelopes_after_envelope_id,
            delivery_receipts_after_unix_ms,
            delivery_receipts_after_sender_key_id,
            delivery_receipts_after_envelope_id,
            mailbox_ack_tombstones_after_unix_ms,
            mailbox_ack_tombstones_after_recipient_key_id,
            mailbox_ack_tombstones_after_envelope_id
        FROM node_sync_peer_state
        WHERE peer_node_id = ?
        "#,
    )
    .bind(peer_node_id)
    .fetch_optional(&state.pool)
    .await?;
    Ok(row
        .map(|row| NodeSyncCursor {
            device_routes_after_unix_ms: from_i64_ms(row.get("device_routes_after_unix_ms")),
            device_routes_after_owner_key_id: row.get("device_routes_after_owner_key_id"),
            device_routes_after_device_id: row.get("device_routes_after_device_id"),
            mailbox_envelopes_after_unix_ms: from_i64_ms(
                row.get("mailbox_envelopes_after_unix_ms"),
            ),
            mailbox_envelopes_after_recipient_key_id: row
                .get("mailbox_envelopes_after_recipient_key_id"),
            mailbox_envelopes_after_envelope_id: row.get("mailbox_envelopes_after_envelope_id"),
            delivery_receipts_after_unix_ms: from_i64_ms(
                row.get("delivery_receipts_after_unix_ms"),
            ),
            delivery_receipts_after_sender_key_id: row.get("delivery_receipts_after_sender_key_id"),
            delivery_receipts_after_envelope_id: row.get("delivery_receipts_after_envelope_id"),
            mailbox_ack_tombstones_after_unix_ms: from_i64_ms(
                row.get("mailbox_ack_tombstones_after_unix_ms"),
            ),
            mailbox_ack_tombstones_after_recipient_key_id: row
                .get("mailbox_ack_tombstones_after_recipient_key_id"),
            mailbox_ack_tombstones_after_envelope_id: row
                .get("mailbox_ack_tombstones_after_envelope_id"),
        })
        .unwrap_or_default())
}

async fn store_node_sync_cursor(
    state: &AppState,
    peer_node_id: &str,
    cursor: &NodeSyncCursor,
    now_unix_ms: u128,
) -> AppResult<()> {
    sqlx::query(
        r#"
        INSERT INTO node_sync_peer_state (
            peer_node_id,
            device_routes_after_unix_ms,
            device_routes_after_owner_key_id,
            device_routes_after_device_id,
            mailbox_envelopes_after_unix_ms,
            mailbox_envelopes_after_recipient_key_id,
            mailbox_envelopes_after_envelope_id,
            delivery_receipts_after_unix_ms,
            delivery_receipts_after_sender_key_id,
            delivery_receipts_after_envelope_id,
            mailbox_ack_tombstones_after_unix_ms,
            mailbox_ack_tombstones_after_recipient_key_id,
            mailbox_ack_tombstones_after_envelope_id,
            updated_at_unix_ms
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(peer_node_id) DO UPDATE SET
            device_routes_after_unix_ms = excluded.device_routes_after_unix_ms,
            device_routes_after_owner_key_id = excluded.device_routes_after_owner_key_id,
            device_routes_after_device_id = excluded.device_routes_after_device_id,
            mailbox_envelopes_after_unix_ms = excluded.mailbox_envelopes_after_unix_ms,
            mailbox_envelopes_after_recipient_key_id = excluded.mailbox_envelopes_after_recipient_key_id,
            mailbox_envelopes_after_envelope_id = excluded.mailbox_envelopes_after_envelope_id,
            delivery_receipts_after_unix_ms = excluded.delivery_receipts_after_unix_ms,
            delivery_receipts_after_sender_key_id = excluded.delivery_receipts_after_sender_key_id,
            delivery_receipts_after_envelope_id = excluded.delivery_receipts_after_envelope_id,
            mailbox_ack_tombstones_after_unix_ms = excluded.mailbox_ack_tombstones_after_unix_ms,
            mailbox_ack_tombstones_after_recipient_key_id = excluded.mailbox_ack_tombstones_after_recipient_key_id,
            mailbox_ack_tombstones_after_envelope_id = excluded.mailbox_ack_tombstones_after_envelope_id,
            updated_at_unix_ms = excluded.updated_at_unix_ms
        "#,
    )
    .bind(peer_node_id)
    .bind(to_i64_ms(
        cursor.device_routes_after_unix_ms,
        "device_routes_after_unix_ms",
    )?)
    .bind(&cursor.device_routes_after_owner_key_id)
    .bind(&cursor.device_routes_after_device_id)
    .bind(to_i64_ms(
        cursor.mailbox_envelopes_after_unix_ms,
        "mailbox_envelopes_after_unix_ms",
    )?)
    .bind(&cursor.mailbox_envelopes_after_recipient_key_id)
    .bind(&cursor.mailbox_envelopes_after_envelope_id)
    .bind(to_i64_ms(
        cursor.delivery_receipts_after_unix_ms,
        "delivery_receipts_after_unix_ms",
    )?)
    .bind(&cursor.delivery_receipts_after_sender_key_id)
    .bind(&cursor.delivery_receipts_after_envelope_id)
    .bind(to_i64_ms(
        cursor.mailbox_ack_tombstones_after_unix_ms,
        "mailbox_ack_tombstones_after_unix_ms",
    )?)
    .bind(&cursor.mailbox_ack_tombstones_after_recipient_key_id)
    .bind(&cursor.mailbox_ack_tombstones_after_envelope_id)
    .bind(to_i64_ms(now_unix_ms, "updated_at_unix_ms")?)
    .execute(&state.pool)
    .await?;
    Ok(())
}

fn node_sync_signature_payload(request: &NodeSyncPushRequest) -> Result<Vec<u8>> {
    let payload = NodeSyncSigningPayload {
        version: request.version,
        source_node_id: &request.source_node_id,
        manifest_id: &request.manifest_id,
        manifest_epoch: request.manifest_epoch,
        pushed_at_unix_ms: request.pushed_at_unix_ms,
        device_routes: &request.device_routes,
        mailbox_envelopes: &request.mailbox_envelopes,
        delivery_receipts: &request.delivery_receipts,
        mailbox_ack_tombstones: &request.mailbox_ack_tombstones,
    };
    serde_json::to_vec(&payload).context("serialize node sync signature payload")
}

fn node_sync_peers(
    manifest: &NodeSetManifest,
    self_node_id: &str,
    now_unix_ms: u128,
) -> Vec<NodeDescriptor> {
    let revoked: HashSet<&str> = manifest
        .revoked_node_ids
        .iter()
        .map(String::as_str)
        .collect();
    manifest
        .nodes
        .iter()
        .filter(|node| node.node_id != self_node_id)
        .filter(|node| !revoked.contains(node.node_id.as_str()))
        .filter(|node| node.valid_until_unix_ms >= now_unix_ms)
        .filter(|node| node_supports_sync(node))
        .cloned()
        .collect()
}

fn node_supports_sync(node: &NodeDescriptor) -> bool {
    node.capabilities
        .iter()
        .any(|capability| capability == "mailbox" || capability == "route")
}

fn path_arg_or_env(arg: Option<PathBuf>, env_name: &str) -> Option<PathBuf> {
    arg.or_else(|| env::var_os(env_name).map(PathBuf::from))
}

fn string_arg_or_env(arg: Option<String>, env_name: &str) -> Option<String> {
    arg.or_else(|| env::var(env_name).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

async fn load_configured_node_manifest(
    manifest_path: Option<PathBuf>,
    manifest_public_key: Option<String>,
) -> Result<Option<NodeSetManifest>> {
    match (manifest_path, manifest_public_key) {
        (None, None) => Ok(None),
        (Some(_), None) => {
            bail!("node manifest requires --manifest-public-key or {ENV_MANIFEST_PUBLIC_KEY}")
        }
        (None, Some(_)) => {
            bail!("manifest public key requires --node-manifest or {ENV_NODE_MANIFEST}")
        }
        (Some(path), Some(public_key)) => {
            let content = tokio::fs::read_to_string(&path)
                .await
                .with_context(|| format!("read node manifest {}", path.display()))?;
            let manifest: NodeSetManifest = serde_json::from_str(&content)
                .with_context(|| format!("parse node manifest {}", path.display()))?;
            let now = system_now_unix_ms()?;
            manifest
                .verify(&public_key, now)
                .with_context(|| format!("verify node manifest {}", path.display()))?;
            tracing::info!(
                "loaded node manifest {} epoch {} with {} nodes",
                manifest.manifest_id,
                manifest.epoch,
                manifest.nodes.len()
            );
            Ok(Some(manifest))
        }
    }
}

async fn load_configured_node_identity(
    node_id: Option<String>,
    signing_secret_file: Option<PathBuf>,
    manifest: Option<&NodeSetManifest>,
) -> Result<Option<NodeIdentity>> {
    match (node_id, signing_secret_file) {
        (None, None) => Ok(None),
        (Some(_), None) => {
            bail!("node id requires --node-signing-secret-file or {ENV_NODE_SIGNING_SECRET_FILE}")
        }
        (None, Some(_)) => bail!("node signing secret file requires --node-id or {ENV_NODE_ID}"),
        (Some(node_id), Some(path)) => {
            let manifest =
                manifest.ok_or_else(|| anyhow::anyhow!("node identity requires node manifest"))?;
            let signing_secret = tokio::fs::read_to_string(&path)
                .await
                .with_context(|| format!("read node signing secret {}", path.display()))?
                .trim()
                .to_string();
            if signing_secret.is_empty() {
                bail!("node signing secret file is empty: {}", path.display());
            }
            let signing_public = envelope_core::signing_public_from_secret(&signing_secret)
                .context("derive node public key from signing secret")?;
            let descriptor = manifest
                .node(&node_id)
                .ok_or_else(|| anyhow::anyhow!("node_id {node_id} is not present in manifest"))?;
            if descriptor.public_key != signing_public {
                bail!(
                    "node signing secret public key does not match manifest public_key for {node_id}"
                );
            }
            tracing::info!("loaded node signing identity for {node_id}");
            Ok(Some(NodeIdentity {
                node_id,
                signing_secret,
            }))
        }
    }
}

async fn open_database(path: &FsPath) -> Result<SqlitePool> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("create {}", parent.display()))?;
    }
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(5));
    SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await
        .with_context(|| format!("open sqlite database {}", path.display()))
}

async fn migrate(pool: &SqlitePool) -> Result<()> {
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS device_routes (
            owner_key_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            owner_contact_json TEXT NOT NULL,
            endpoint_json TEXT NOT NULL,
            expires_at_unix_ms INTEGER NOT NULL,
            updated_at_unix_ms INTEGER NOT NULL,
            PRIMARY KEY (owner_key_id, device_id)
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create device_routes table")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_device_routes_expires
        ON device_routes(expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create device_routes expiry index")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_device_routes_sync
        ON device_routes(updated_at_unix_ms, owner_key_id, device_id, expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create device routes sync index")?;
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS mailbox_envelopes (
            recipient_key_id TEXT NOT NULL,
            envelope_id TEXT NOT NULL,
            sender_key_id TEXT NOT NULL,
            envelope_sha256 TEXT,
            envelope_bytes BLOB NOT NULL,
            received_at_unix_ms INTEGER NOT NULL,
            expires_at_unix_ms INTEGER NOT NULL,
            PRIMARY KEY (recipient_key_id, envelope_id)
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox_envelopes table")?;
    add_column_if_missing(pool, "mailbox_envelopes", "envelope_sha256", "TEXT").await?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_mailbox_expiry
        ON mailbox_envelopes(expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox expiry index")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_mailbox_envelopes_sync
        ON mailbox_envelopes(received_at_unix_ms, recipient_key_id, envelope_id, expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox envelopes sync index")?;
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS delivery_receipts (
            sender_key_id TEXT NOT NULL,
            envelope_id TEXT NOT NULL,
            recipient_key_id TEXT NOT NULL,
            delivered_at_unix_ms INTEGER NOT NULL,
            expires_at_unix_ms INTEGER NOT NULL,
            PRIMARY KEY (sender_key_id, envelope_id)
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create delivery_receipts table")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_delivery_receipts_expiry
        ON delivery_receipts(expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create delivery receipts expiry index")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_delivery_receipts_sync
        ON delivery_receipts(delivered_at_unix_ms, sender_key_id, envelope_id, expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create delivery receipts sync index")?;
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS mailbox_ack_tombstones (
            recipient_key_id TEXT NOT NULL,
            envelope_id TEXT NOT NULL,
            sender_key_id TEXT,
            acked_at_unix_ms INTEGER NOT NULL,
            expires_at_unix_ms INTEGER NOT NULL,
            PRIMARY KEY (recipient_key_id, envelope_id)
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox ack tombstones table")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_mailbox_ack_tombstones_expiry
        ON mailbox_ack_tombstones(expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox ack tombstones expiry index")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_mailbox_ack_tombstones_sync
        ON mailbox_ack_tombstones(acked_at_unix_ms, recipient_key_id, envelope_id, expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create mailbox ack tombstones sync index")?;
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS node_sync_peer_state (
            peer_node_id TEXT NOT NULL PRIMARY KEY,
            device_routes_after_unix_ms INTEGER NOT NULL DEFAULT 0,
            device_routes_after_owner_key_id TEXT NOT NULL DEFAULT '',
            device_routes_after_device_id TEXT NOT NULL DEFAULT '',
            mailbox_envelopes_after_unix_ms INTEGER NOT NULL DEFAULT 0,
            mailbox_envelopes_after_recipient_key_id TEXT NOT NULL DEFAULT '',
            mailbox_envelopes_after_envelope_id TEXT NOT NULL DEFAULT '',
            delivery_receipts_after_unix_ms INTEGER NOT NULL DEFAULT 0,
            delivery_receipts_after_sender_key_id TEXT NOT NULL DEFAULT '',
            delivery_receipts_after_envelope_id TEXT NOT NULL DEFAULT '',
            mailbox_ack_tombstones_after_unix_ms INTEGER NOT NULL DEFAULT 0,
            mailbox_ack_tombstones_after_recipient_key_id TEXT NOT NULL DEFAULT '',
            mailbox_ack_tombstones_after_envelope_id TEXT NOT NULL DEFAULT '',
            updated_at_unix_ms INTEGER NOT NULL
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create node sync peer state table")?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "device_routes_after_owner_key_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "device_routes_after_device_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "mailbox_envelopes_after_recipient_key_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "mailbox_envelopes_after_envelope_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "delivery_receipts_after_sender_key_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "delivery_receipts_after_envelope_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "mailbox_ack_tombstones_after_recipient_key_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    add_column_if_missing(
        pool,
        "node_sync_peer_state",
        "mailbox_ack_tombstones_after_envelope_id",
        "TEXT NOT NULL DEFAULT ''",
    )
    .await?;
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS intro_sessions (
            session_id TEXT NOT NULL PRIMARY KEY,
            owner_key_id TEXT NOT NULL,
            owner_bundle_json TEXT NOT NULL,
            responder_key_id TEXT,
            responder_bundle_json TEXT,
            expires_at_unix_ms INTEGER NOT NULL,
            updated_at_unix_ms INTEGER NOT NULL
        )
        "#,
    )
    .execute(pool)
    .await
    .context("create intro_sessions table")?;
    sqlx::query(
        r#"
        CREATE INDEX IF NOT EXISTS idx_intro_sessions_expires
        ON intro_sessions(expires_at_unix_ms)
        "#,
    )
    .execute(pool)
    .await
    .context("create intro_sessions expiry index")?;
    Ok(())
}

async fn add_column_if_missing(
    pool: &SqlitePool,
    table: &'static str,
    column: &'static str,
    column_type: &'static str,
) -> Result<()> {
    let pragma = format!("PRAGMA table_info({table})");
    let rows = sqlx::query(&pragma)
        .fetch_all(pool)
        .await
        .with_context(|| format!("inspect {table} columns"))?;
    let has_column = rows
        .iter()
        .any(|row| row.get::<String, _>("name") == column);
    if !has_column {
        let statement = format!("ALTER TABLE {table} ADD COLUMN {column} {column_type}");
        sqlx::query(&statement)
            .execute(pool)
            .await
            .with_context(|| format!("add {table}.{column} column"))?;
    }
    Ok(())
}

async fn cleanup_expired(pool: &SqlitePool, now_unix_ms: u128) -> AppResult<()> {
    let now = to_i64_ms(now_unix_ms, "now_unix_ms")?;
    sqlx::query("DELETE FROM device_routes WHERE expires_at_unix_ms < ?")
        .bind(now)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM mailbox_envelopes WHERE expires_at_unix_ms < ?")
        .bind(now)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM delivery_receipts WHERE expires_at_unix_ms < ?")
        .bind(now)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM mailbox_ack_tombstones WHERE expires_at_unix_ms < ?")
        .bind(now)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM intro_sessions WHERE expires_at_unix_ms < ?")
        .bind(now)
        .execute(pool)
        .await?;
    Ok(())
}

fn rate_limit_client_ip(remote_addr: SocketAddr, headers: &HeaderMap) -> String {
    let remote_ip = remote_addr.ip();
    if remote_ip.is_loopback() {
        if let Some(forwarded_ip) = trusted_forwarded_client_ip(headers) {
            return forwarded_ip.to_string();
        }
    }
    remote_ip.to_string()
}

fn trusted_forwarded_client_ip(headers: &HeaderMap) -> Option<IpAddr> {
    for header_name in ["cf-connecting-ip", "x-real-ip", "x-forwarded-for"] {
        if let Some(value) = headers.get(header_name) {
            let text = value.to_str().ok()?;
            if header_name == "x-forwarded-for" {
                if let Some(ip) = text.split(',').find_map(parse_forwarded_ip) {
                    return Some(ip);
                }
                continue;
            }
            if let Some(ip) = parse_forwarded_ip(text) {
                return Some(ip);
            }
        }
    }
    None
}

fn parse_forwarded_ip(value: &str) -> Option<IpAddr> {
    let trimmed = value.trim();
    let without_brackets = trimmed
        .strip_prefix('[')
        .and_then(|value| value.split_once(']').map(|(ip, _)| ip))
        .unwrap_or(trimmed);
    without_brackets.parse().ok()
}

fn check_submit_rate_limits(
    state: &AppState,
    client_ip: &str,
    sender_key_id: &str,
    now_unix_ms: u128,
) -> AppResult<()> {
    let mut limiter = state
        .submit_rate_limiter
        .lock()
        .map_err(|_| AppError::Internal(anyhow::anyhow!("submit rate limiter poisoned")))?;
    check_rate_bucket(
        &mut limiter.by_ip,
        client_ip,
        now_unix_ms,
        state.limits.max_submit_per_ip_per_minute,
        "source IP",
    )?;
    check_rate_bucket(
        &mut limiter.by_sender,
        sender_key_id,
        now_unix_ms,
        state.limits.max_submit_per_sender_per_minute,
        "sender",
    )?;
    Ok(())
}

fn check_rate_bucket(
    buckets: &mut HashMap<String, RateBucket>,
    key: &str,
    now_unix_ms: u128,
    max_per_window: u32,
    label: &'static str,
) -> AppResult<()> {
    if max_per_window == 0 {
        return Err(AppError::TooManyRequests(format!(
            "{label} envelope submit is disabled"
        )));
    }
    buckets.retain(|_, bucket| {
        now_unix_ms.saturating_sub(bucket.window_start_unix_ms) < SUBMIT_RATE_WINDOW_MS
    });
    let bucket = buckets.entry(key.to_string()).or_insert(RateBucket {
        window_start_unix_ms: now_unix_ms,
        count: 0,
    });
    if now_unix_ms.saturating_sub(bucket.window_start_unix_ms) >= SUBMIT_RATE_WINDOW_MS {
        bucket.window_start_unix_ms = now_unix_ms;
        bucket.count = 0;
    }
    if bucket.count >= max_per_window {
        return Err(AppError::TooManyRequests(format!(
            "{label} envelope submit rate exceeded: {max_per_window}/minute"
        )));
    }
    bucket.count = bucket.count.saturating_add(1);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_bucket_rejects_after_limit_and_resets_next_window() {
        let mut buckets = HashMap::new();

        check_rate_bucket(&mut buckets, "sender-a", 1_000, 2, "sender").unwrap();
        check_rate_bucket(&mut buckets, "sender-a", 2_000, 2, "sender").unwrap();
        let error = check_rate_bucket(&mut buckets, "sender-a", 3_000, 2, "sender").unwrap_err();
        assert!(
            matches!(error, AppError::TooManyRequests(message) if message.contains("sender envelope submit rate exceeded: 2/minute"))
        );

        check_rate_bucket(
            &mut buckets,
            "sender-a",
            1_000 + SUBMIT_RATE_WINDOW_MS,
            2,
            "sender",
        )
        .unwrap();
    }

    #[test]
    fn rate_bucket_zero_limit_disables_submit() {
        let mut buckets = HashMap::new();

        let error = check_rate_bucket(&mut buckets, "ip-a", 1_000, 0, "source IP").unwrap_err();
        assert!(
            matches!(error, AppError::TooManyRequests(message) if message.contains("source IP envelope submit is disabled"))
        );
    }

    #[test]
    fn rate_limit_client_ip_trusts_forwarded_header_only_from_loopback() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "203.0.113.10, 10.0.0.1".parse().unwrap());

        let loopback_remote: SocketAddr = "127.0.0.1:4321".parse().unwrap();
        assert_eq!(
            rate_limit_client_ip(loopback_remote, &headers),
            "203.0.113.10"
        );

        let public_remote: SocketAddr = "198.51.100.2:4321".parse().unwrap();
        assert_eq!(
            rate_limit_client_ip(public_remote, &headers),
            "198.51.100.2"
        );
    }

    #[test]
    fn node_sync_signature_rejects_tampered_payload() {
        let (signing_secret, signing_public) = envelope_core::generate_signing_keypair();
        let mut request = NodeSyncPushRequest {
            version: SERVER_PROTOCOL_VERSION,
            source_node_id: "node-a".to_string(),
            manifest_id: "manifest-test".to_string(),
            manifest_epoch: 1,
            pushed_at_unix_ms: 1_000,
            device_routes: Vec::new(),
            mailbox_envelopes: Vec::new(),
            delivery_receipts: Vec::new(),
            mailbox_ack_tombstones: Vec::new(),
            signature: String::new(),
        };
        let payload = node_sync_signature_payload(&request).unwrap();
        request.signature = envelope_core::sign_context_payload_with_secret(
            &signing_secret,
            NODE_SYNC_SIGNATURE_CONTEXT,
            &payload,
        )
        .unwrap();

        envelope_core::verify_context_payload_with_public(
            &signing_public,
            NODE_SYNC_SIGNATURE_CONTEXT,
            &payload,
            &request.signature,
        )
        .unwrap();

        request.manifest_epoch = 2;
        let tampered_payload = node_sync_signature_payload(&request).unwrap();
        envelope_core::verify_context_payload_with_public(
            &signing_public,
            NODE_SYNC_SIGNATURE_CONTEXT,
            &tampered_payload,
            &request.signature,
        )
        .unwrap_err();
    }

    #[tokio::test]
    async fn node_sync_tombstone_deletes_existing_mailbox_envelope() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        migrate(&pool).await.unwrap();
        let state = AppState {
            pool,
            limits: AntiAbuseLimits::default(),
            submit_rate_limiter: Arc::new(Mutex::new(SubmitRateLimiter::default())),
            node_manifest: None,
            node_identity: None,
        };
        sqlx::query(
            r#"
            INSERT INTO mailbox_envelopes (
                recipient_key_id,
                envelope_id,
                sender_key_id,
                envelope_sha256,
                envelope_bytes,
                received_at_unix_ms,
                expires_at_unix_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind("recipient-a")
        .bind("envelope-a")
        .bind("sender-a")
        .bind("hash-a")
        .bind(vec![1_u8, 2, 3])
        .bind(900_i64)
        .bind(10_000_i64)
        .execute(&state.pool)
        .await
        .unwrap();
        let request = NodeSyncPushRequest {
            version: SERVER_PROTOCOL_VERSION,
            source_node_id: "node-a".to_string(),
            manifest_id: "manifest-test".to_string(),
            manifest_epoch: 1,
            pushed_at_unix_ms: 1_000,
            device_routes: Vec::new(),
            mailbox_envelopes: Vec::new(),
            delivery_receipts: Vec::new(),
            mailbox_ack_tombstones: vec![NodeSyncMailboxAckTombstone {
                recipient_key_id: "recipient-a".to_string(),
                envelope_id: "envelope-a".to_string(),
                sender_key_id: Some("sender-a".to_string()),
                acked_at_unix_ms: 1_000,
                expires_at_unix_ms: 10_000,
            }],
            signature: String::new(),
        };

        let applied = apply_node_sync_push(&state, &request, 1_100).await.unwrap();
        assert_eq!(applied.mailbox_ack_tombstones, 1);
        assert_eq!(applied.mailbox_deleted_by_tombstone, 1);

        let mailbox_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM mailbox_envelopes")
            .fetch_one(&state.pool)
            .await
            .unwrap();
        let tombstone_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM mailbox_ack_tombstones")
                .fetch_one(&state.pool)
                .await
                .unwrap();
        assert_eq!(mailbox_count, 0);
        assert_eq!(tombstone_count, 1);
    }

    #[tokio::test]
    async fn node_sync_cursor_paginates_equal_timestamp_device_routes() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        migrate(&pool).await.unwrap();
        let state = AppState {
            pool,
            limits: AntiAbuseLimits::default(),
            submit_rate_limiter: Arc::new(Mutex::new(SubmitRateLimiter::default())),
            node_manifest: None,
            node_identity: None,
        };

        for suffix in ["a", "b", "c"] {
            sqlx::query(
                r#"
                INSERT INTO device_routes (
                    owner_key_id,
                    device_id,
                    owner_contact_json,
                    endpoint_json,
                    expires_at_unix_ms,
                    updated_at_unix_ms
                )
                VALUES (?, ?, ?, ?, ?, ?)
                "#,
            )
            .bind(format!("owner-{suffix}"))
            .bind(format!("device-{suffix}"))
            .bind("{}")
            .bind("{}")
            .bind(10_000_i64)
            .bind(1_000_i64)
            .execute(&state.pool)
            .await
            .unwrap();
        }

        let first_page = load_node_sync_snapshot(&state, 2_000, 2, &NodeSyncCursor::default())
            .await
            .unwrap();
        assert_eq!(first_page.device_routes.len(), 2);
        assert_eq!(first_page.device_routes[0].owner_key_id, "owner-a");
        assert_eq!(first_page.device_routes[1].owner_key_id, "owner-b");
        assert_eq!(first_page.next_cursor.device_routes_after_unix_ms, 1_000);
        assert_eq!(
            first_page.next_cursor.device_routes_after_owner_key_id,
            "owner-b"
        );
        assert_eq!(
            first_page.next_cursor.device_routes_after_device_id,
            "device-b"
        );

        let second_page = load_node_sync_snapshot(&state, 2_000, 2, &first_page.next_cursor)
            .await
            .unwrap();
        assert_eq!(second_page.device_routes.len(), 1);
        assert_eq!(second_page.device_routes[0].owner_key_id, "owner-c");

        let third_page = load_node_sync_snapshot(&state, 2_000, 2, &second_page.next_cursor)
            .await
            .unwrap();
        assert!(third_page.device_routes.is_empty());
    }
}

async fn load_contact(pool: &SqlitePool, key_id: &str) -> AppResult<Contact> {
    let row = sqlx::query(
        r#"
        SELECT owner_contact_json
        FROM device_routes
        WHERE owner_key_id = ?
        ORDER BY updated_at_unix_ms DESC
        LIMIT 1
        "#,
    )
    .bind(key_id)
    .fetch_optional(pool)
    .await?;
    let row = row
        .ok_or_else(|| AppError::NotFound("identity has no registered device route".to_string()))?;
    let contact_json: String = row.get("owner_contact_json");
    serde_json::from_str(&contact_json)
        .context("parse stored contact")
        .map_err(AppError::Internal)
}

fn now_unix_ms() -> AppResult<u128> {
    system_now_unix_ms().map_err(AppError::Internal)
}

fn system_now_unix_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time is before unix epoch")?
        .as_millis())
}

fn to_i64_ms(value: u128, field: &'static str) -> AppResult<i64> {
    i64::try_from(value).map_err(|_| AppError::BadRequest(format!("{field} does not fit i64")))
}

fn from_i64_ms(value: i64) -> u128 {
    u128::try_from(value).unwrap_or(0)
}

async fn shutdown_signal() {
    if let Err(error) = signal::ctrl_c().await {
        tracing::warn!("failed to install Ctrl+C handler: {error}");
    }
}

impl AppError {
    fn from_core(error: ServerCoreError) -> Self {
        match error {
            ServerCoreError::InvalidEnvelope(detail) if detail.contains("too large") => {
                Self::PayloadTooLarge(detail)
            }
            ServerCoreError::MailboxLimitExceeded(detail) => Self::TooManyRequests(detail),
            other => Self::BadRequest(other.to_string()),
        }
    }

    fn status(&self) -> StatusCode {
        match self {
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::PayloadTooLarge(_) => StatusCode::PAYLOAD_TOO_LARGE,
            Self::TooManyRequests(_) => StatusCode::TOO_MANY_REQUESTS,
            Self::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn message(&self) -> String {
        match self {
            Self::BadRequest(message)
            | Self::Conflict(message)
            | Self::NotFound(message)
            | Self::PayloadTooLarge(message)
            | Self::TooManyRequests(message) => message.clone(),
            Self::Internal(error) => error.to_string(),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = self.status();
        let body = Json(ErrorResponse {
            error: self.message(),
        });
        (status, body).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(error: sqlx::Error) -> Self {
        Self::Internal(error.into())
    }
}
