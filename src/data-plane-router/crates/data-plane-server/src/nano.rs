/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   nano.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:11 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Nano edition — the single-binary, PocketBase-class runtime.
//!
//! One static process serves the whole back-end: the existing `/data/v1` data
//! plane (CRUD, schema introspection, DDL pass-through via raw SQL, graph)
//! over embedded SQLite, plus everything the cloud control plane normally
//! provides over HTTP, absorbed in-process:
//!
//! - **Auth**: API keys live in a local SQLite key store. Keys are
//!   high-entropy (256-bit) random values stored as SHA-256 digests with a
//!   constant-time compare — a memory-hard KDF (Argon2) defends low-entropy
//!   passwords, which these are not, so verification is microseconds instead
//!   of a tenant-control round-trip. The first boot mints an `admin` key and
//!   prints it ONCE (or hashes `NANO_ADMIN_KEY` if provided).
//! - **Mounts**: a static in-process map (`NANO_MOUNTS` JSON, default one
//!   SQLite file `main` under `NANO_DATA_DIR`). No adapter-registry.
//! - **Realtime**: committed mutations fan out to an in-process broadcast
//!   channel, exposed as Server-Sent Events at `GET /nano/v1/realtime` — the
//!   single-binary equivalent of the outbox → relay → websocket pipeline.
//!
//! Single-tenant semantics: every verified key maps to tenant `local` and the
//! SAME owner principal (`api-key:local`), so data written with one key stays
//! visible after key rotation — the per-key owner partitioning that protects
//! multi-tenant clouds would surprise a single-app deployment. The key that
//! acted is still recorded on the audit trail (`key` field on the verify span).

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tower_http::trace::TraceLayer;

use crate::auth::{AuthError, ResolvedMount, VerifiedIdentity};
use crate::config::ServerConfig;
use crate::routes::{api_err, AppState};
use data_plane_core::PoolRegistry;

/// The fixed tenant id every nano key verifies into.
const NANO_TENANT: &str = "local";
/// The fixed owner principal (see the module docs for why it is NOT per-key).
const NANO_KEY_PRINCIPAL: &str = "local";
/// Scopes a minted key may carry.
const VALID_SCOPES: [&str; 3] = ["admin", "read", "write"];

// ─── key store ───────────────────────────────────────────────────────────────

/// A key row as listed over the admin API (never includes the digest).
#[derive(serde::Serialize)]
struct KeyInfo {
    id: String,
    name: String,
    scopes: Vec<String>,
    created_at: String,
    revoked: bool,
}

/// SQLite-backed API-key store (`<data_dir>/nano_meta.db`). All calls are
/// sub-millisecond and never held across an await, so a std Mutex is right.
struct KeyStore {
    conn: std::sync::Mutex<rusqlite::Connection>,
    // Positive verify cache (digest -> (name, scopes)). Without it EVERY request
    // locked `conn` + ran a SELECT to authenticate, so one mutex + one connection
    // serialised all concurrent requests (the per-request tax PocketBase's
    // stateless token avoids). A repeat verify is now a lock-free RwLock read.
    // Cleared wholesale on revoke so a revoked key is rejected immediately —
    // stricter than the cloud's LRU staleness window.
    verify_cache: std::sync::RwLock<std::collections::HashMap<String, (String, Vec<String>)>>,
}

impl KeyStore {
    fn open(path: &std::path::Path) -> anyhow::Result<Self> {
        let conn = rusqlite::Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS nano_keys (
                id         TEXT PRIMARY KEY,
                name       TEXT UNIQUE NOT NULL,
                digest     TEXT NOT NULL,
                scopes     TEXT NOT NULL,
                created_at TEXT NOT NULL,
                revoked    INTEGER NOT NULL DEFAULT 0
            );",
        )?;
        Ok(Self {
            conn: std::sync::Mutex::new(conn),
            verify_cache: std::sync::RwLock::new(std::collections::HashMap::new()),
        })
    }

    fn active_count(&self) -> anyhow::Result<i64> {
        let conn = self.conn.lock().expect("key store poisoned");
        Ok(conn.query_row(
            "SELECT COUNT(*) FROM nano_keys WHERE revoked = 0",
            [],
            |r| r.get(0),
        )?)
    }

    fn insert(&self, id: &str, name: &str, digest: &str, scopes: &[String]) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("key store poisoned");
        conn.execute(
            "INSERT INTO nano_keys (id, name, digest, scopes, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                id,
                name,
                digest,
                serde_json::to_string(scopes)?,
                chrono::Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    /// Mint a new key: returns the FULL key (shown exactly once) + its row id.
    fn mint(&self, name: &str, scopes: &[String]) -> anyhow::Result<(String, String)> {
        let id = uuid::Uuid::new_v4().simple().to_string()[..12].to_string();
        let secret = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let key = format!("nbk_{id}.{secret}");
        self.insert(&id, name, &sha256_hex(&key), scopes)?;
        Ok((key, id))
    }

    /// Verify a presented key → `(name, scopes)`. Keys in the `nbk_<id>.<secret>`
    /// format look up by embedded id (one row, no scan); any miss then tries the
    /// `env-admin` row so an operator-chosen `NANO_ADMIN_KEY` works regardless of
    /// its shape — the digest of the FULL key string must match either way, so
    /// the fallback can only ever match the one key it stores.
    fn verify(&self, key: &str) -> Option<(String, Vec<String>)> {
        let digest = sha256_hex(key);
        // Fast path: a previously-verified key is a lock-free RwLock read — no
        // SQLite round-trip, no exclusive lock — so concurrent requests no longer
        // serialise on the key store. (sha256 of a 160-bit key is still computed
        // every call; only the DB lookup + lock are cached.)
        if let Some(hit) = self
            .verify_cache
            .read()
            .ok()
            .and_then(|c| c.get(&digest).cloned())
        {
            return Some(hit);
        }
        let embedded_id = key
            .strip_prefix("nbk_")
            .and_then(|rest| rest.split_once('.'))
            .map(|(id, _)| id.to_string());
        let verified = {
            let conn = self.conn.lock().expect("key store poisoned");
            let lookup = |id: &str| -> Option<(String, String, String)> {
                conn.query_row(
                    "SELECT name, digest, scopes FROM nano_keys WHERE id = ?1 AND revoked = 0",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .ok()
            };
            embedded_id
                .and_then(|id| lookup(&id))
                .filter(|(_, d, _)| ct_eq(&digest, d))
                .or_else(|| lookup("env-admin").filter(|(_, d, _)| ct_eq(&digest, d)))
        }?;
        let (name, _, scopes_json) = verified;
        let scopes: Vec<String> = serde_json::from_str(&scopes_json).unwrap_or_default();
        let out = (name, scopes);
        if let Ok(mut c) = self.verify_cache.write() {
            c.insert(digest, out.clone());
        }
        Some(out)
    }

    fn list(&self) -> anyhow::Result<Vec<KeyInfo>> {
        let conn = self.conn.lock().expect("key store poisoned");
        let mut stmt = conn.prepare(
            "SELECT id, name, scopes, created_at, revoked FROM nano_keys ORDER BY created_at",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(KeyInfo {
                id: r.get(0)?,
                name: r.get(1)?,
                scopes: serde_json::from_str::<Vec<String>>(&r.get::<_, String>(2)?)
                    .unwrap_or_default(),
                created_at: r.get(3)?,
                revoked: r.get::<_, i64>(4)? != 0,
            })
        })?;
        Ok(rows.filter_map(Result::ok).collect())
    }

    fn revoke(&self, id: &str) -> anyhow::Result<bool> {
        let n = {
            let conn = self.conn.lock().expect("key store poisoned");
            conn.execute("UPDATE nano_keys SET revoked = 1 WHERE id = ?1", [id])?
        };
        if n > 0 {
            // Invalidate the positive verify cache so the revoked key is rejected
            // on its very next request (revocation is rare; a full clear is fine).
            if let Ok(mut c) = self.verify_cache.write() {
                c.clear();
            }
        }
        Ok(n > 0)
    }
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let out = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in out {
        use std::fmt::Write;
        let _ = write!(hex, "{b:02x}");
    }
    hex
}

/// Constant-time string equality (no early exit on first mismatch).
fn ct_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes()
        .zip(b.bytes())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

// ─── nano state ──────────────────────────────────────────────────────────────

/// One mount entry in `NANO_MOUNTS` (`{"main":{"engine":"sqlite","dsn":"…"}}`).
#[derive(Debug, Clone, Deserialize)]
struct NanoMountSpec {
    engine: String,
    dsn: String,
}

/// A committed mutation on the realtime bus. The envelope is pre-serialized
/// once per event; the routing fields ride beside it so subscribers filter
/// without re-parsing JSON.
#[derive(Clone)]
pub(crate) struct MutationEvent {
    pub(crate) db: String,
    pub(crate) table: String,
    /// The mutating principal (`user:<id>` / `api-key:<id>`) — drives
    /// owner-filtered delivery for user subscribers.
    pub(crate) owner: String,
    pub(crate) payload: String,
}

/// In-process state the nano runtime adds on top of [`AppState`]: the key
/// store, the static mount map, and the realtime broadcast bus.
pub struct NanoState {
    keys: KeyStore,
    mounts: HashMap<String, ResolvedMount>,
    events: tokio::sync::broadcast::Sender<MutationEvent>,
}

impl NanoState {
    /// Open (or bootstrap) the nano state under `data_dir`. First boot mints
    /// the admin key (or hashes `NANO_ADMIN_KEY`) and prints the one-time
    /// banner to stdout.
    pub fn open(data_dir: &std::path::Path) -> anyhow::Result<Self> {
        let keys = KeyStore::open(&data_dir.join("nano_meta.db"))?;
        if keys.active_count()? == 0 {
            let admin_scopes = vec!["admin".to_string()];
            match std::env::var("NANO_ADMIN_KEY")
                .ok()
                .filter(|k| !k.trim().is_empty())
            {
                Some(env_key) => {
                    keys.insert(
                        "env-admin",
                        "admin (env)",
                        &sha256_hex(&env_key),
                        &admin_scopes,
                    )?;
                    tracing::info!("nano: admin key installed from NANO_ADMIN_KEY (digest stored, value never logged)");
                }
                None => {
                    let (key, _) = keys.mint("admin", &admin_scopes)?;
                    // One-time disclosure by design: the digest is all we keep.
                    println!(
                        "┌──────────────────────────────────────────────────────────────────┐"
                    );
                    println!(
                        "│ binocle-nano first boot — ADMIN API KEY (shown once, store it):  │"
                    );
                    println!("│   {key}   │");
                    println!(
                        "└──────────────────────────────────────────────────────────────────┘"
                    );
                }
            }
        }

        let mounts = Self::load_mounts(data_dir)?;
        let (events, _) = tokio::sync::broadcast::channel(256);
        Ok(Self {
            keys,
            mounts,
            events,
        })
    }

    /// `NANO_MOUNTS` JSON, or the default single SQLite mount `main`.
    fn load_mounts(data_dir: &std::path::Path) -> anyhow::Result<HashMap<String, ResolvedMount>> {
        let specs: HashMap<String, NanoMountSpec> = match std::env::var("NANO_MOUNTS") {
            Ok(raw) if !raw.trim().is_empty() => serde_json::from_str(&raw)
                .map_err(|e| anyhow::anyhow!("NANO_MOUNTS is not valid JSON: {e}"))?,
            _ => HashMap::from([(
                "main".to_string(),
                NanoMountSpec {
                    engine: "sqlite".to_string(),
                    dsn: data_dir.join("main.db").to_string_lossy().into_owned(),
                },
            )]),
        };
        Ok(specs
            .into_iter()
            .map(|(id, s)| {
                (
                    id,
                    ResolvedMount {
                        engine: s.engine,
                        connection_string: s.dsn,
                        isolation: None,
                        capability_overrides: None,
                    },
                )
            })
            .collect())
    }

    /// The in-process replacement for the tenant-control verify: header →
    /// identity. Mirrors `bypass_verify`'s error envelopes so handlers reusing
    /// it are byte-compatible.
    pub(crate) fn verify_headers(
        &self,
        headers: &header::HeaderMap,
    ) -> Result<VerifiedIdentity, axum::response::Response> {
        let key = headers
            .get("x-baas-api-key")
            .and_then(|v| v.to_str().ok())
            .filter(|k| !k.trim().is_empty());
        let Some(key) = key else {
            return Err(api_err(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "X-Baas-Api-Key header is required",
            ));
        };
        self.verify_key_str(key)
    }

    /// Verify a raw key string (shared by the header path and the SSE `?key=`
    /// query path — EventSource cannot set headers).
    pub(crate) fn verify_key_str(
        &self,
        key: &str,
    ) -> Result<VerifiedIdentity, axum::response::Response> {
        match self.keys.verify(key) {
            Some((name, scopes)) => {
                tracing::debug!(target: "audit", key = %name, "nano key verified");
                Ok(VerifiedIdentity {
                    tenant_id: NANO_TENANT.to_string(),
                    // Stable owner principal — see module docs.
                    key_id: NANO_KEY_PRINCIPAL.to_string(),
                    scopes,
                    principal: format!("api-key:{NANO_KEY_PRINCIPAL}"),
                    source: data_plane_core::IdentitySource::ServiceToken,
                })
            }
            None => Err(api_err(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "invalid api key",
            )),
        }
    }

    /// The in-process replacement for adapter-registry `/connect`.
    pub(crate) fn resolve_mount(&self, db_id: &str) -> Result<ResolvedMount, AuthError> {
        self.mounts
            .get(db_id)
            .cloned()
            .ok_or_else(|| AuthError::NotFound(format!("mount '{db_id}' not found")))
    }

    /// Fan a committed mutation out to SSE subscribers. Best-effort: no
    /// subscriber (or a lagging one) never affects the write.
    pub(crate) fn publish_mutation(
        &self,
        db_id: &str,
        table: &str,
        op: &str,
        pk: Option<&serde_json::Value>,
        affected: u64,
        owner: &str,
    ) {
        let payload = json!({
            "db_id": db_id,
            "table": table,
            "op": op,
            "pk": pk,
            "affected": affected,
            "owner": owner,
            "ts": chrono::Utc::now().to_rfc3339(),
        });
        let _ = self.events.send(MutationEvent {
            db: db_id.to_string(),
            table: table.to_string(),
            owner: owner.to_string(),
            payload: payload.to_string(),
        });
    }
}

// ─── handlers ────────────────────────────────────────────────────────────────

/// The nano state is always present in handlers mounted by [`router`]; the 503
/// is an unreachable belt-and-braces (e.g. someone wiring the route manually).
fn nano_of(state: &AppState) -> Result<Arc<NanoState>, axum::response::Response> {
    state.nano.clone().ok_or_else(|| {
        api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "nano_unavailable",
            "nano runtime not initialised",
        )
    })
}

/// Verify + require a scope, in one step (admin satisfies everything).
pub(crate) fn authorize(
    state: &AppState,
    headers: &header::HeaderMap,
    needed: &'static str,
) -> Result<VerifiedIdentity, axum::response::Response> {
    let nano = nano_of(state)?;
    let id = nano.verify_headers(headers)?;
    if let Err(missing) = crate::routes::require_scope(&id.scopes, needed) {
        return Err(crate::routes::scope_denied(&id, "nano", missing));
    }
    Ok(id)
}

async fn info(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    if let Err(resp) = authorize(&state, &headers, "read") {
        return resp;
    }
    let mut mounts: Vec<&String> = nano.mounts.keys().collect();
    mounts.sort();
    Json(json!({
        "edition": "nano",
        "version": env!("CARGO_PKG_VERSION"),
        "mounts": mounts,
        "realtime": "/nano/v1/realtime (SSE)",
    }))
    .into_response()
}

#[derive(Deserialize)]
struct MintRequest {
    name: String,
    #[serde(default)]
    scopes: Vec<String>,
}

async fn mint_key(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<MintRequest>,
) -> axum::response::Response {
    if let Err(resp) = authorize(&state, &headers, "admin") {
        return resp;
    }
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    if req.name.trim().is_empty() {
        return api_err(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "name is required",
        );
    }
    let scopes: Vec<String> = if req.scopes.is_empty() {
        vec!["read".to_string(), "write".to_string()]
    } else {
        req.scopes
    };
    if let Some(bad) = scopes.iter().find(|s| !VALID_SCOPES.contains(&s.as_str())) {
        return api_err(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            &format!("unknown scope '{bad}' (valid: admin, read, write)"),
        );
    }
    match nano.keys.mint(req.name.trim(), &scopes) {
        Ok((key, id)) => (
            StatusCode::CREATED,
            Json(json!({ "id": id, "name": req.name.trim(), "scopes": scopes, "key": key })),
        )
            .into_response(),
        Err(e) => api_err(
            StatusCode::CONFLICT,
            "key_mint_failed",
            &format!("could not mint key (name taken?): {e}"),
        ),
    }
}

async fn list_keys(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    if let Err(resp) = authorize(&state, &headers, "admin") {
        return resp;
    }
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    match nano.keys.list() {
        Ok(keys) => Json(json!({ "keys": keys })).into_response(),
        Err(e) => api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "key_list_failed",
            &e.to_string(),
        ),
    }
}

async fn revoke_key(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id): Path<String>,
) -> axum::response::Response {
    if let Err(resp) = authorize(&state, &headers, "admin") {
        return resp;
    }
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    match nano.keys.revoke(&id) {
        Ok(true) => Json(json!({ "revoked": id })).into_response(),
        Ok(false) => api_err(StatusCode::NOT_FOUND, "not_found", "no such key id"),
        Err(e) => api_err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "key_revoke_failed",
            &e.to_string(),
        ),
    }
}

#[derive(Deserialize)]
struct RawRequest {
    #[serde(alias = "databaseId", alias = "dbId")]
    db_id: String,
    statement: String,
    #[serde(default)]
    params: Vec<serde_json::Value>,
    #[serde(default)]
    expect_rows: bool,
}

/// Admin-scoped raw SQL against a nano mount — the migration/DDL escape hatch
/// (the SQLite adapter is honest about `schema_ddl: false`, so table creation
/// goes through SQL, like a PocketBase migration would).
async fn raw(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<RawRequest>,
) -> axum::response::Response {
    let id = match authorize(&state, &headers, "admin") {
        Ok(id) => id,
        Err(resp) => return resp,
    };
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    if req.statement.trim().is_empty() {
        return api_err(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "statement is required",
        );
    }
    let mount_info = match nano.resolve_mount(&req.db_id) {
        Ok(m) => m,
        Err(AuthError::NotFound(m)) => return api_err(StatusCode::NOT_FOUND, "not_found", &m),
        Err(_) => {
            return api_err(
                StatusCode::BAD_GATEWAY,
                "upstream_unavailable",
                "mount resolve failed",
            )
        }
    };
    let (identity, mount) = crate::routes::bypass_envelope(&id, &req.db_id, mount_info);
    let pool = match state.registry().get_or_create(mount).await {
        Ok(p) => p,
        Err(e) => return crate::routes::map_data_plane_error(&e),
    };
    let statement = data_plane_core::RawStatement {
        statement: req.statement,
        params: req.params,
        expect_rows: req.expect_rows,
    };
    match pool.execute_raw(statement, identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(e) => crate::routes::map_data_plane_error(&e),
    }
}

#[derive(Deserialize)]
struct RealtimeQuery {
    #[serde(default)]
    key: Option<String>,
    /// binocle-one: a user JWT via query param (EventSource cannot set the
    /// Authorization header).
    #[cfg(feature = "one")]
    #[serde(default)]
    token: Option<String>,
    /// Server-side topic filter: comma-separated `table:<name>` / `db:<id>`
    /// tokens (a bare token means `table:`). Empty/absent = everything.
    #[serde(default)]
    topics: Option<String>,
}

/// One parsed subscription token.
enum Topic {
    Table(String),
    Db(String),
}

fn parse_topics(raw: Option<&str>) -> Vec<Topic> {
    raw.unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(|t| match t.split_once(':') {
            Some(("db", id)) => Topic::Db(id.to_string()),
            Some(("table", name)) => Topic::Table(name.to_string()),
            _ => Topic::Table(t.to_string()),
        })
        .collect()
}

fn topics_match(topics: &[Topic], ev: &MutationEvent) -> bool {
    topics.is_empty()
        || topics.iter().any(|t| match t {
            Topic::Table(name) => *name == ev.table,
            Topic::Db(id) => *id == ev.db,
        })
}

/// SSE stream of committed mutations. Auth: `X-Baas-Api-Key` header or `?key=`
/// for machine keys; Bearer / `?token=` for binocle-one user JWTs (EventSource
/// cannot set headers); requires the `read` scope.
async fn realtime(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Query(q): Query<RealtimeQuery>,
) -> axum::response::Response {
    let nano = match nano_of(&state) {
        Ok(n) => n,
        Err(r) => return r,
    };
    let key = headers
        .get("x-baas-api-key")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
        .or_else(|| q.key.clone())
        .filter(|k| !k.trim().is_empty());
    let id = match key {
        Some(k) => nano.verify_key_str(&k),
        None => {
            #[cfg(feature = "one")]
            {
                let token = crate::one::bearer_token(&headers)
                    .or_else(|| q.token.clone())
                    .filter(|t| !t.trim().is_empty());
                match (state.one.as_ref(), token) {
                    (Some(one), Some(t)) => one.verify_jwt(&t),
                    _ => Err(api_err(
                        StatusCode::UNAUTHORIZED,
                        "unauthorized",
                        "X-Baas-Api-Key / ?key= or Bearer / ?token= is required",
                    )),
                }
            }
            #[cfg(not(feature = "one"))]
            Err(api_err(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "X-Baas-Api-Key header or ?key= is required",
            ))
        }
    };
    let id = match id {
        Ok(id) => id,
        Err(resp) => return resp,
    };
    if let Err(missing) = crate::routes::require_scope(&id.scopes, "read") {
        return crate::routes::scope_denied(&id, "realtime", missing);
    }

    // Server-side delivery filter: requested topics, and — for user (JWT)
    // identities — only the subscriber's OWN mutations, mirroring the
    // owner-scoping their reads get on /data/v1. Machine keys see the bus.
    let topics = parse_topics(q.topics.as_deref());
    let owner_filter = (!matches!(id.source, data_plane_core::IdentitySource::ServiceToken))
        .then(|| id.principal.clone());

    let rx = nano.events.subscribe();
    let stream = futures::stream::unfold(
        (rx, topics, owner_filter),
        |(mut rx, topics, owner_filter)| async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        if !topics_match(&topics, &ev) {
                            continue;
                        }
                        if let Some(owner) = owner_filter.as_deref() {
                            if ev.owner != owner {
                                continue;
                            }
                        }
                        let event = Event::default().event("mutation").data(ev.payload);
                        return Some((
                            Ok::<_, std::convert::Infallible>(event),
                            (rx, topics, owner_filter),
                        ));
                    }
                    // A slow consumer skips missed events rather than erroring out.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return None,
                }
            }
        },
    );
    Sse::new(stream)
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("ping"),
        )
        .into_response()
}

// ─── runtime ─────────────────────────────────────────────────────────────────

/// The nano route set, unfinished (no state/layers) so binocle-one can merge
/// its own routes on top: the `/data/v1` plane (always on — nano IS the
/// bypass) + the in-process control surface. The trusted-envelope `/v1/query`
/// family is deliberately NOT mounted: there is no query-router in front to
/// be trusted.
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/health", get(crate::routes::health))
        .route("/v1/capabilities", get(crate::routes::capabilities))
        .route("/data/v1/query", post(crate::routes::data_query))
        .route("/data/v1/schema", post(crate::routes::data_describe_schema))
        .route(
            "/data/v1/schema/ddl",
            post(crate::routes::data_apply_schema_ddl),
        )
        .route("/data/v1/graph", post(crate::graph::data_graph))
        .route(
            "/data/v1/graph/overview",
            post(crate::graph::data_graph_overview),
        )
        .route("/nano/v1/info", get(info))
        .route("/nano/v1/keys", post(mint_key).get(list_keys))
        .route("/nano/v1/keys/:id", axum::routing::delete(revoke_key))
        .route("/nano/v1/raw", post(raw))
        .route("/nano/v1/realtime", get(realtime))
}

pub fn router(state: AppState) -> Router {
    routes().layer(TraceLayer::new_for_http()).with_state(state)
}

/// Boot the nano runtime: open the key store + mounts, attach them to the
/// shared [`AppState`], spawn the pool reaper, serve.
pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let data_dir = std::path::PathBuf::from(
        std::env::var("NANO_DATA_DIR").unwrap_or_else(|_| "./nano_data".to_string()),
    );
    std::fs::create_dir_all(&data_dir)?;

    let addr = format!("{}:{}", config.host, config.port);
    let mut state = AppState::new(config);
    let nano = Arc::new(NanoState::open(&data_dir)?);
    state.nano = Some(nano);

    // Same background reaper as the full server: idle pools + expired txs.
    let reaper_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(15));
        loop {
            interval.tick().await;
            reaper_state.reap_once().await;
        }
    });

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(address = %addr, data_dir = %data_dir.display(), "binocle-nano listening (single-binary edition)");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(crate::signal::shutdown_signal())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn topics_parse_and_match() {
        use super::{parse_topics, topics_match, MutationEvent};
        let ev = |db: &str, table: &str| MutationEvent {
            db: db.into(),
            table: table.into(),
            owner: "user:u1".into(),
            payload: String::new(),
        };
        // Empty filter matches everything.
        assert!(topics_match(&parse_topics(None), &ev("main", "notes")));
        assert!(topics_match(&parse_topics(Some("")), &ev("main", "notes")));
        // Bare token == table filter; explicit forms work; commas + spaces ok.
        let t = parse_topics(Some("notes, table:posts ,db:other"));
        assert!(topics_match(&t, &ev("main", "notes")));
        assert!(topics_match(&t, &ev("main", "posts")));
        assert!(topics_match(&t, &ev("other", "anything")));
        assert!(!topics_match(&t, &ev("main", "todos")));
    }

    use super::*;

    #[test]
    fn ct_eq_basic() {
        assert!(ct_eq("abc", "abc"));
        assert!(!ct_eq("abc", "abd"));
        assert!(!ct_eq("abc", "abcd"));
    }

    #[test]
    fn sha256_hex_golden() {
        // printf 'nbk_test' | sha256sum
        assert_eq!(
            sha256_hex("nbk_test"),
            "5275d4aae8b7c7ac1985401092fd1391b85c5df5035c8a64b8fe51230f6a9e91"
        );
    }

    #[test]
    fn keystore_mint_verify_revoke_roundtrip() {
        let dir = std::env::temp_dir().join(format!("nano-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = KeyStore::open(&dir.join("meta.db")).unwrap();

        let (key, id) = store.mint("ci", &["read".to_string()]).unwrap();
        assert!(key.starts_with("nbk_"), "key format: {key}");

        let (name, scopes) = store.verify(&key).expect("freshly minted key verifies");
        assert_eq!(name, "ci");
        assert_eq!(scopes, vec!["read".to_string()]);

        // Wrong secret with the right id must fail (digest mismatch).
        let forged = format!("nbk_{id}.{}", "0".repeat(64));
        assert!(store.verify(&forged).is_none(), "forged key rejected");

        assert!(store.revoke(&id).unwrap());
        assert!(store.verify(&key).is_none(), "revoked key rejected");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn env_admin_fallback_lookup() {
        let dir = std::env::temp_dir().join(format!("nano-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = KeyStore::open(&dir.join("meta.db")).unwrap();
        // An operator-chosen key (no nbk_ format) lands on the env-admin row.
        store
            .insert(
                "env-admin",
                "admin (env)",
                &sha256_hex("hunter2-but-long"),
                &["admin".to_string()],
            )
            .unwrap();
        assert!(store.verify("hunter2-but-long").is_some());
        assert!(store.verify("wrong").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
