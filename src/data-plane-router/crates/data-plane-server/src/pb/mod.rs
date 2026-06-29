//! PocketBase-compatible facade (`/api/...`) — feature `pbcompat`, shipped in
//! binocle-one, NEVER in nano.
//!
//! A translation layer over the existing engine: PB wire shapes (filter DSL,
//! response envelopes, collection schemas) in, native operations out. The
//! native `/data/v1` + `/one/v1` contracts stay untouched and remain the fast
//! path; this module exists so the OFFICIAL PocketBase JS/Dart SDKs work
//! against binocle-one unchanged (gate m48 runs the real `pocketbase` npm
//! package against both us and real PB and diffs the outcomes).
//!
//! Facade data lives on its own nano mount `pb` ({data_dir}/pb_data.db,
//! isolation `tenant_owned`): PB's access model is per-collection RULES, not
//! per-row owner columns, so the platform's owner-scoping must not inject
//! `owner_id` into PB-shaped tables. Collection schemas live in
//! {data_dir}/pb_meta.db. Superuser = `ONE_SUPERUSER_EMAIL`/`_PASSWORD` env
//! (PB bootstraps its first superuser the same way), authenticated through
//! `/api/collections/_superusers/auth-with-password`.

pub mod auth;
pub mod auth_flows;
pub mod backups;
pub mod batch;
pub mod collections;
pub mod crons;
pub mod files;
pub mod filter;
#[cfg(feature = "hooks")]
pub mod hooks;
pub mod logs;
pub mod predicate;
pub mod ratelimit;
pub mod realtime;
pub mod records;
pub mod rules;
pub mod settings;

use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use data_plane_core::{
    CredentialRef, DataOperation, DataResult, DatabaseMount, PoolPolicy, PoolRegistry,
    RequestIdentity,
};
use serde_json::json;

use crate::routes::AppState;

/// The facade's dedicated mount id (see module docs).
pub(crate) const PB_MOUNT: &str = "pb";
const PB_TENANT: &str = "local";

// ─── state ───────────────────────────────────────────────────────────────────

pub struct PbState {
    /// Collections registry connection ({data_dir}/pb_meta.db). Same poison
    /// policy as the rest of the crate: recover, never brick.
    pub(crate) meta: std::sync::Mutex<rusqlite::Connection>,
    /// Connected SSE clients + their subscription sets.
    pub(crate) realtime: realtime::Realtime,
    /// Root of PB file storage ({data_dir}/pb_storage).
    pub(crate) storage_root: std::path::PathBuf,
    /// Batched request-log writer (pb_logs.db).
    pub(crate) logs: logs::Logs,
    /// Fixed-window rate-limit state (label, ip) — see pb::ratelimit.
    pub(crate) rate_windows: ratelimit::Windows,
    /// 5s-TTL settings cache: the rate limiter reads settings on EVERY /api
    /// request — a per-request sqlite query would tax the facade hot path.
    settings_cache: std::sync::RwLock<(std::time::Instant, serde_json::Value)>,
    /// Successful-verify cache for auth records (same design + rationale as
    /// `UserStore::verify_cache`: argon2id is memory-hard by design, repeat
    /// logins skip it; failures always pay full cost).
    verify_cache: std::sync::RwLock<std::collections::HashMap<String, std::time::Instant>>,
    pepper: String,
    su_email: Option<String>,
    su_pass: Option<String>,
}

impl PbState {
    pub fn open(data_dir: &std::path::Path) -> anyhow::Result<Self> {
        let conn = rusqlite::Connection::open(data_dir.join("pb_meta.db"))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS pb_collections (
                id         TEXT PRIMARY KEY,
                name       TEXT UNIQUE NOT NULL,
                type       TEXT NOT NULL DEFAULT 'base',
                system     INTEGER NOT NULL DEFAULT 0,
                fields     TEXT NOT NULL,
                listRule   TEXT,
                viewRule   TEXT,
                createRule TEXT,
                updateRule TEXT,
                deleteRule TEXT,
                indexes    TEXT NOT NULL DEFAULT '[]',
                options    TEXT NOT NULL DEFAULT '{}',
                created    TEXT NOT NULL,
                updated    TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pb_config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pb_migrations_history (
                id         TEXT PRIMARY KEY,
                type       TEXT NOT NULL,
                collection TEXT NOT NULL,
                snapshot   TEXT NOT NULL,
                created    TEXT NOT NULL
            );",
        )?;
        let su_email = std::env::var("ONE_SUPERUSER_EMAIL")
            .ok()
            .map(|e| e.trim().to_lowercase())
            .filter(|e| !e.is_empty());
        let su_pass = std::env::var("ONE_SUPERUSER_PASSWORD")
            .ok()
            .filter(|p| !p.is_empty());
        if su_email.is_none() {
            tracing::info!(
                "pb: no ONE_SUPERUSER_EMAIL set — /api collection management is disabled until configured"
            );
        }
        Ok(Self {
            meta: std::sync::Mutex::new(conn),
            realtime: realtime::Realtime::default(),
            storage_root: data_dir.join("pb_storage"),
            logs: logs::Logs::start(data_dir.join("pb_logs.db")),
            rate_windows: ratelimit::Windows::default(),
            settings_cache: std::sync::RwLock::new((
                std::time::Instant::now() - std::time::Duration::from_secs(60),
                serde_json::Value::Null,
            )),
            verify_cache: std::sync::RwLock::new(std::collections::HashMap::new()),
            pepper: format!("{}{}", uuid::Uuid::new_v4(), uuid::Uuid::new_v4()),
            su_email,
            su_pass,
        })
    }
}

impl PbState {
    fn cache_key(&self, rid: &str, password: &str) -> String {
        crate::one::sha256_hex(&format!("{}\u{0}{}\u{0}{}", self.pepper, rid, password))
    }
    pub(crate) fn verify_cached_pb(&self, rid: &str, password: &str) -> bool {
        let key = self.cache_key(rid, password);
        self.verify_cache
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&key)
            .is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(60))
    }
    pub(crate) fn cache_verify_pb(&self, rid: &str, password: &str) {
        let key = self.cache_key(rid, password);
        let mut cache = self
            .verify_cache
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if cache.len() >= 8192 {
            cache.retain(|_, at| at.elapsed() < std::time::Duration::from_secs(60));
            if cache.len() >= 8192 {
                cache.clear();
            }
        }
        cache.insert(key, std::time::Instant::now());
    }
}

impl PbState {
    /// Settings with a 5 s TTL (hot-path reads); writers go through
    /// `settings_patch`, which refreshes within one TTL window.
    pub(crate) fn settings_cached(&self) -> serde_json::Value {
        {
            let guard = self
                .settings_cache
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if guard.0.elapsed() < std::time::Duration::from_secs(5) && !guard.1.is_null() {
                return guard.1.clone();
            }
        }
        let fresh = self.settings();
        *self
            .settings_cache
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            (std::time::Instant::now(), fresh.clone());
        fresh
    }
}

pub(crate) fn pb_of(state: &AppState) -> Result<std::sync::Arc<PbState>, axum::response::Response> {
    state.pb.clone().ok_or_else(|| {
        pb_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "pb runtime not initialised",
        )
    })
}

// ─── PB wire shapes ──────────────────────────────────────────────────────────

/// PB's error envelope: `{"status": N, "message": "...", "data": {...}}`.
pub(crate) fn pb_err(status: StatusCode, message: &str) -> axum::response::Response {
    (
        status,
        Json(json!({
            "status": status.as_u16(),
            "message": message,
            "data": {}
        })),
    )
        .into_response()
}

/// PB record ids: 15 lowercase alphanumerics.
pub(crate) fn pb_id() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut out = String::with_capacity(15);
    // Two v4 UUIDs = 32 random bytes — more than the 15 draws need.
    let raw: Vec<u8> = uuid::Uuid::new_v4()
        .into_bytes()
        .into_iter()
        .chain(uuid::Uuid::new_v4().into_bytes())
        .collect();
    for b in raw.into_iter().take(15) {
        out.push(ALPHABET[(b as usize) % ALPHABET.len()] as char);
    }
    out
}

/// PB's canonical datetime rendering (`2026-06-12 08:15:30.123Z`).
pub(crate) fn pb_now() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%d %H:%M:%S%.3fZ")
        .to_string()
}

// ─── auth ────────────────────────────────────────────────────────────────────

pub(crate) enum PbAuth {
    Superuser,
    /// An authenticated AUTH-COLLECTION record (`sub = pb:{col id}:{rid}`)
    /// — the identity `@request.auth.*` rules read.
    Record {
        collection_id: String,
        record_id: String,
    },
    /// A native binocle-one account JWT (not a PB auth record).
    #[allow(dead_code)]
    User(String),
    Guest,
}

/// PB SDKs send `Authorization: <raw token>` (NO `Bearer` prefix; PB also
/// accepts the prefixed form, so both are honored here).
pub(crate) fn pb_auth(state: &AppState, headers: &header::HeaderMap) -> PbAuth {
    // The nano admin key is the deployment's ROOT credential — it acts as
    // superuser on the facade too (the embedded dashboard drives the ops
    // panels with it).
    if let Some(key) = headers.get("x-baas-api-key").and_then(|v| v.to_str().ok()) {
        if let Some(nano) = state.nano.as_ref() {
            if let Ok(id) = nano.verify_key_str(key) {
                if id.scopes.iter().any(|s| s == "admin") {
                    return PbAuth::Superuser;
                }
            }
        }
    }
    let Some(raw) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.strip_prefix("Bearer ")
                .or_else(|| v.strip_prefix("bearer "))
                .unwrap_or(v)
                .trim()
        })
        .filter(|t| !t.is_empty())
    else {
        return PbAuth::Guest;
    };
    let Some(one) = state.one.as_ref() else {
        return PbAuth::Guest;
    };
    match one.verify_jwt(raw) {
        Ok(id) if id.key_id == "pb:su" => PbAuth::Superuser,
        Ok(id) => match id
            .key_id
            .strip_prefix("pb:")
            .and_then(|r| r.split_once(':'))
        {
            Some((col, rid)) => PbAuth::Record {
                collection_id: col.to_string(),
                record_id: rid.to_string(),
            },
            None => PbAuth::User(id.key_id),
        },
        Err(_) => PbAuth::Guest,
    }
}

/// `POST /api/collections/_superusers/auth-with-password` — the door the
/// official SDK's `pb.collection("_superusers").authWithPassword()` knocks on.
async fn superuser_auth(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(req): Json<serde_json::Value>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let one = match crate::one::one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let identity = req
        .get("identity")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let password = req
        .get("password")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let (Some(su_email), Some(su_pass)) = (pb.su_email.as_deref(), pb.su_pass.as_deref()) else {
        return pb_err(
            StatusCode::BAD_REQUEST,
            "superuser login is not configured (set ONE_SUPERUSER_EMAIL / ONE_SUPERUSER_PASSWORD)",
        );
    };
    // Constant-time on the password; the email compare is not secret.
    if identity != su_email || !crate::one::ct_eq(password, su_pass) {
        return pb_err(StatusCode::BAD_REQUEST, "Failed to authenticate.");
    }
    let (token, _ttl) = match one.mint_jwt("pb:su", su_email) {
        Ok(t) => t,
        Err(e) => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    };
    (
        StatusCode::OK,
        Json(json!({
            "token": token,
            "record": {
                "id": "pbsu000000state",
                "collectionId": "pbc_superusers0",
                "collectionName": "_superusers",
                "email": su_email,
                "verified": true,
                "created": pb_now(),
                "updated": pb_now(),
            }
        })),
    )
        .into_response()
}

// ─── engine execution ────────────────────────────────────────────────────────

/// Run one operation against the facade mount. The identity is the facade
/// itself — PB access control is per-collection rules evaluated in the pb
/// layer, NOT engine-level owner scoping (the `pb` mount is `tenant_owned`).
pub(crate) async fn exec(
    state: &AppState,
    op: DataOperation,
) -> Result<DataResult, axum::response::Response> {
    let Some(nano) = state.nano.as_ref() else {
        return Err(pb_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "engine unavailable",
        ));
    };
    let mount_info = nano
        .resolve_mount(PB_MOUNT)
        .map_err(|_| pb_err(StatusCode::SERVICE_UNAVAILABLE, "pb mount missing"))?;
    let identity = RequestIdentity {
        tenant_id: PB_TENANT.to_string(),
        project_id: None,
        app_id: None,
        user_id: Some("pb-facade".to_string()),
        roles: vec![],
        scopes: vec!["admin".to_string()],
        source: data_plane_core::IdentitySource::ServiceToken,
    };
    let mount = DatabaseMount {
        id: PB_MOUNT.to_string(),
        tenant_id: PB_TENANT.to_string(),
        project_id: None,
        engine: mount_info.engine,
        name: "pb-facade".to_string(),
        credential_ref: CredentialRef {
            provider: "nano".to_string(),
            reference: PB_MOUNT.to_string(),
            version: "live".to_string(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: mount_info.capability_overrides,
        inline_dsn: Some(mount_info.connection_string),
        isolation: mount_info.isolation,
        replica_inline_dsn: None,
        read_replica_route: false,
    };
    let pool = state
        .registry()
        .get_or_create(mount)
        .await
        .map_err(|e| pb_err(StatusCode::BAD_GATEWAY, &format!("engine: {e}")))?;
    let table = op.resource.clone();
    let kind = op.op.wire_name();
    let is_mutation = matches!(
        op.op,
        data_plane_core::DataOperationKind::Insert
            | data_plane_core::DataOperationKind::Update
            | data_plane_core::DataOperationKind::Delete
            | data_plane_core::DataOperationKind::Upsert
            | data_plane_core::DataOperationKind::Batch
    );
    let pk = op
        .filter
        .as_ref()
        .and_then(|f| f.get("id"))
        .cloned()
        .or_else(|| op.data.as_ref().and_then(|d| d.get("id")).cloned());
    let result = pool
        .execute(op, identity)
        .await
        .map_err(|e| map_engine_error(&e))?;
    // Same post-commit fan-out the native door does (control-pg paths are
    // compiled out of the one build): nano SSE bus, best-effort.
    if is_mutation {
        nano.publish_mutation(
            PB_MOUNT,
            &table,
            kind,
            pk.as_ref(),
            result.affected_rows,
            "pb",
        );
    }
    Ok(result)
}

/// Raw SQL (DDL) through the same mount — writer-thread serialized.
pub(crate) async fn exec_raw(
    state: &AppState,
    statement: data_plane_core::RawStatement,
) -> Result<DataResult, axum::response::Response> {
    let Some(nano) = state.nano.as_ref() else {
        return Err(pb_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "engine unavailable",
        ));
    };
    let mount_info = nano
        .resolve_mount(PB_MOUNT)
        .map_err(|_| pb_err(StatusCode::SERVICE_UNAVAILABLE, "pb mount missing"))?;
    let identity = RequestIdentity {
        tenant_id: PB_TENANT.to_string(),
        project_id: None,
        app_id: None,
        user_id: Some("pb-facade".to_string()),
        roles: vec![],
        scopes: vec!["admin".to_string()],
        source: data_plane_core::IdentitySource::ServiceToken,
    };
    let mount = DatabaseMount {
        id: PB_MOUNT.to_string(),
        tenant_id: PB_TENANT.to_string(),
        project_id: None,
        engine: mount_info.engine,
        name: "pb-facade".to_string(),
        credential_ref: CredentialRef {
            provider: "nano".to_string(),
            reference: PB_MOUNT.to_string(),
            version: "live".to_string(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: mount_info.capability_overrides,
        inline_dsn: Some(mount_info.connection_string),
        isolation: mount_info.isolation,
        replica_inline_dsn: None,
        read_replica_route: false,
    };
    let pool = state
        .registry()
        .get_or_create(mount)
        .await
        .map_err(|e| pb_err(StatusCode::BAD_GATEWAY, &format!("engine: {e}")))?;
    pool.execute_raw(statement, identity)
        .await
        .map_err(|e| map_engine_error(&e))
}

/// Engine errors → PB-shaped envelopes with PB-faithful status codes.
fn map_engine_error(err: &data_plane_core::DataPlaneError) -> axum::response::Response {
    use data_plane_core::DataPlaneError as E;
    match err {
        E::InvalidRequest { message } => pb_err(StatusCode::BAD_REQUEST, message),
        E::Conflict { message } => pb_err(StatusCode::BAD_REQUEST, message),
        E::NotImplemented { feature } => {
            pb_err(StatusCode::BAD_REQUEST, &format!("unsupported: {feature}"))
        }
        other => pb_err(StatusCode::BAD_REQUEST, &other.to_string()),
    }
}

// ─── router ──────────────────────────────────────────────────────────────────

async fn health() -> axum::response::Response {
    (
        StatusCode::OK,
        Json(json!({
            "status": 200,
            "message": "API is healthy.",
            "data": { "canBackup": true }
        })),
    )
        .into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health))
        .route(
            "/api/collections/_superusers/auth-with-password",
            post(superuser_auth),
        )
        .merge(collections::routes())
        .merge(records::routes())
        .merge(realtime::routes())
        .merge(batch::routes())
        .merge(settings::routes())
        .merge(files::routes())
        .merge(auth::routes())
        .merge(auth_flows::routes())
        .merge(backups::routes())
        .merge(crons::routes())
        .merge(logs::routes())
}
