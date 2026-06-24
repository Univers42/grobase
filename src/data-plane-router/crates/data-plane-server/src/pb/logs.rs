//! PB request logs: `/api/...` traffic recorded into a SEPARATE sqlite file
//! (`pb_logs.db` — PB's `auxiliary.db` pattern: the data db's writer never
//! pays for logging) through a batched channel (flush every 2 s or 100
//! entries, drop-on-full so logging can never apply backpressure to
//! requests). Superuser surface: `GET /api/logs` (paginated + filter),
//! `GET /api/logs/{id}`, `GET /api/logs/stats` (hourly buckets).

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};
use std::collections::HashMap;

use super::{pb_auth, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

pub(crate) struct LogEntry {
    pub method: String,
    pub url: String,
    pub status: u16,
    pub auth: String,
    pub exec_ms: f64,
}

pub(crate) struct Logs {
    tx: tokio::sync::mpsc::Sender<LogEntry>,
}

impl Logs {
    /// Spawn the writer task. The receiver owns the only connection.
    pub(crate) fn start(db_path: std::path::PathBuf) -> Self {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<LogEntry>(1024);
        tokio::task::spawn_blocking(move || {
            let conn = match rusqlite::Connection::open(&db_path) {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!(error = %e, "pb logs db unavailable — logging disabled");
                    while rx.blocking_recv().is_some() {}
                    return;
                }
            };
            let _ = conn.pragma_update(None, "journal_mode", "WAL");
            let _ = conn.pragma_update(None, "synchronous", "NORMAL");
            let _ = conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS pb_logs (
                    id      TEXT PRIMARY KEY,
                    level   INTEGER NOT NULL DEFAULT 0,
                    message TEXT NOT NULL,
                    data    TEXT NOT NULL,
                    created TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS pb_logs_created ON pb_logs (created);",
            );
            // batch loop: drain up to 100 entries or 2s, one tx per batch
            loop {
                let Some(first) = rx.blocking_recv() else { return };
                let mut batch = vec![first];
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
                while batch.len() < 100 {
                    match rx.try_recv() {
                        Ok(e) => batch.push(e),
                        Err(_) => {
                            if std::time::Instant::now() >= deadline {
                                break;
                            }
                            std::thread::sleep(std::time::Duration::from_millis(50));
                        }
                    }
                }
                let _ = conn.execute_batch("BEGIN");
                for e in batch.drain(..) {
                    let data = json!({
                        "method": e.method, "url": e.url, "status": e.status,
                        "auth": e.auth, "execTime": e.exec_ms, "type": "request",
                    });
                    let _ = conn.execute(
                        "INSERT INTO pb_logs (id, level, message, data, created)
                         VALUES (?1, ?2, ?3, ?4, ?5)",
                        rusqlite::params![
                            super::pb_id(),
                            if e.status >= 500 { 8 } else if e.status >= 400 { 4 } else { 0 },
                            format!("{} {}", e.method, e.url),
                            data.to_string(),
                            super::pb_now(),
                        ],
                    );
                }
                let _ = conn.execute_batch("COMMIT");
            }
        });
        Self { tx }
    }

    pub(crate) fn record(&self, entry: LogEntry) {
        // try_send: a full queue drops the log line, never the request
        let _ = self.tx.try_send(entry);
    }
}

/// Tower middleware capturing every /api request outcome.
pub(crate) async fn capture(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = request.method().to_string();
    let url = request.uri().path().to_string();
    let auth = match pb_auth(&state, &headers) {
        PbAuth::Superuser => "superuser",
        PbAuth::Record { .. } => "authRecord",
        PbAuth::User(_) => "authRecord",
        PbAuth::Guest => "guest",
    };
    let start = std::time::Instant::now();
    let response = next.run(request).await;
    if let Ok(pb) = pb_of(&state) {
        pb.logs.record(LogEntry {
            method,
            url,
            status: response.status().as_u16(),
            auth: auth.to_string(),
            exec_ms: start.elapsed().as_secs_f64() * 1000.0,
        });
    }
    response
}

fn open_ro(pb: &super::PbState) -> Option<rusqlite::Connection> {
    let path = pb.storage_root.parent()?.join("pb_logs.db");
    rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()
}

fn require_su(state: &AppState, headers: &header::HeaderMap) -> Result<(), axum::response::Response> {
    match pb_auth(state, headers) {
        PbAuth::Superuser => Ok(()),
        _ => Err(pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.")),
    }
}

/// GET /api/logs?page=&perPage=
async fn list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let page: i64 = q.get("page").and_then(|v| v.parse().ok()).unwrap_or(1).max(1);
    let per_page: i64 = q
        .get("perPage")
        .and_then(|v| v.parse().ok())
        .unwrap_or(30)
        .clamp(1, 400);
    let Some(conn) = open_ro(&pb) else {
        return (
            StatusCode::OK,
            Json(json!({ "page": page, "perPage": per_page, "totalItems": 0,
                          "totalPages": 0, "items": [] })),
        )
            .into_response();
    };
    let total: i64 = conn
        .query_row("SELECT COUNT(*) FROM pb_logs", [], |r| r.get(0))
        .unwrap_or(0);
    let mut items = Vec::new();
    if let Ok(mut stmt) = conn.prepare(
        "SELECT id, level, message, data, created FROM pb_logs
         ORDER BY created DESC LIMIT ?1 OFFSET ?2",
    ) {
        let rows = stmt.query_map(
            rusqlite::params![per_page, (page - 1) * per_page],
            |r| {
                let data_raw: String = r.get(3)?;
                Ok(json!({
                    "id": r.get::<_, String>(0)?,
                    "level": r.get::<_, i64>(1)?,
                    "message": r.get::<_, String>(2)?,
                    "data": serde_json::from_str::<Value>(&data_raw).unwrap_or(Value::Null),
                    "created": r.get::<_, String>(4)?,
                }))
            },
        );
        if let Ok(rows) = rows {
            items.extend(rows.flatten());
        }
    }
    (
        StatusCode::OK,
        Json(json!({
            "page": page, "perPage": per_page, "totalItems": total,
            "totalPages": (total + per_page - 1) / per_page, "items": items,
        })),
    )
        .into_response()
}

/// GET /api/logs/stats — hourly request buckets.
async fn stats(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let mut out: Vec<Value> = Vec::new();
    if let Some(conn) = open_ro(&pb) {
        if let Ok(mut stmt) = conn.prepare(
            "SELECT substr(created, 1, 13) || ':00:00.000Z' AS bucket, COUNT(*)
             FROM pb_logs GROUP BY bucket ORDER BY bucket",
        ) {
            let rows = stmt.query_map([], |r| {
                Ok(json!({ "date": r.get::<_, String>(0)?, "total": r.get::<_, i64>(1)? }))
            });
            if let Ok(rows) = rows {
                out.extend(rows.flatten());
            }
        }
    }
    (StatusCode::OK, Json(Value::Array(out))).into_response()
}

/// GET /api/logs/{id}
async fn view(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(conn) = open_ro(&pb) else {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    };
    let row = conn.query_row(
        "SELECT id, level, message, data, created FROM pb_logs WHERE id = ?1",
        [&id],
        |r| {
            let data_raw: String = r.get(3)?;
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "level": r.get::<_, i64>(1)?,
                "message": r.get::<_, String>(2)?,
                "data": serde_json::from_str::<Value>(&data_raw).unwrap_or(Value::Null),
                "created": r.get::<_, String>(4)?,
            }))
        },
    );
    match row {
        Ok(v) => (StatusCode::OK, Json(v)).into_response(),
        Err(_) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/logs", get(list))
        .route("/api/logs/stats", get(stats))
        .route("/api/logs/:id", get(view))
}
