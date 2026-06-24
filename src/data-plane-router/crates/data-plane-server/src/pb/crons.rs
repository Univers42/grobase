//! PB crons API: `GET /api/crons` lists registered jobs (`[{id, expression}]`),
//! `POST /api/crons/{id}` runs one immediately. The registry mirrors PB's
//! system jobs — the Phase I maintenance work wearing PB's names:
//! `__pbOTPCleanup__` (expired pb_codes + one_codes), `__pbDBOptimize__`
//! (PRAGMA optimize), `__pbMFACleanup__` (expired refresh rows),
//! `__pbLogsCleanup__` (logs older than the retention window). Scheduling
//! stays on the 10-minute maintenance tick; the 5-field expressions shown
//! are the cadence each job effectively runs at.

use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

use super::{pb_auth, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

const JOBS: &[(&str, &str)] = &[
    ("__pbOTPCleanup__", "*/10 * * * *"),
    ("__pbMFACleanup__", "*/10 * * * *"),
    ("__pbDBOptimize__", "0 * * * *"),
    ("__pbLogsCleanup__", "0 */6 * * *"),
];

fn require_su(state: &AppState, headers: &header::HeaderMap) -> Result<(), axum::response::Response> {
    match pb_auth(state, headers) {
        PbAuth::Superuser => Ok(()),
        _ => Err(pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.")),
    }
}

/// Execute one job NOW (also called from the maintenance loop).
pub(crate) async fn run_job(state: &AppState, id: &str) -> bool {
    let Ok(pb) = pb_of(state) else { return false };
    match id {
        "__pbOTPCleanup__" => {
            let conn = pb.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let now = chrono::Utc::now().timestamp();
            let _ = conn.execute(
                "DELETE FROM pb_codes WHERE expires_at < ?1",
                [now],
            );
            true
        }
        "__pbMFACleanup__" => {
            // expired one_refresh rows live in the one runtime's store
            if let Some(one) = state.one.as_ref() {
                let _ = one.users.maintain();
            }
            true
        }
        "__pbDBOptimize__" => {
            let conn = pb.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let _ = conn.execute_batch("PRAGMA optimize;");
            true
        }
        "__pbLogsCleanup__" => {
            let Some(path) = pb.storage_root.parent().map(|p| p.join("pb_logs.db")) else {
                return true;
            };
            let cutoff = (chrono::Utc::now() - chrono::Duration::days(7))
                .format("%Y-%m-%d %H:%M:%S%.3fZ")
                .to_string();
            let _ = tokio::task::spawn_blocking(move || {
                if let Ok(conn) = rusqlite::Connection::open(path) {
                    let _ = conn.execute("DELETE FROM pb_logs WHERE created < ?1", [cutoff]);
                }
            })
            .await;
            true
        }
        _ => false,
    }
}

/// GET /api/crons
async fn list(State(state): State<AppState>, headers: header::HeaderMap) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    let items: Vec<Value> = JOBS
        .iter()
        .map(|(id, expr)| json!({ "id": id, "expression": expr }))
        .collect();
    (StatusCode::OK, Json(Value::Array(items))).into_response()
}

/// POST /api/crons/{id}
async fn run(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(id): Path<String>,
) -> axum::response::Response {
    if let Err(r) = require_su(&state, &headers) {
        return r;
    }
    if run_job(&state, &id).await {
        StatusCode::NO_CONTENT.into_response()
    } else {
        pb_err(StatusCode::NOT_FOUND, "Missing or invalid cron job.")
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/crons", get(list))
        .route("/api/crons/:id", post(run))
}
