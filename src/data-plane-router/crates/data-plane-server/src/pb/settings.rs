//! Minimal `/api/settings` (GET/PATCH, superuser) — enough for clients to
//! toggle PB's batch switch (DISABLED by default, exactly like PB) ahead of
//! the full Phase L settings surface. Stored as one JSON blob in pb_meta.db
//! (`pb_config.settings`), deep-merged over defaults on read.

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};

use super::{pb_auth, pb_err, pb_of, PbAuth};
use crate::routes::AppState;

fn defaults() -> Value {
    json!({
        "meta": { "appName": "binocle-one", "appURL": "" },
        "batch": { "enabled": false, "maxRequests": 50, "timeout": 3, "maxBodySize": 0 },
    })
}

fn deep_merge(base: &mut Value, patch: &Value) {
    match (base, patch) {
        (Value::Object(b), Value::Object(p)) => {
            for (k, v) in p {
                deep_merge(b.entry(k.clone()).or_insert(Value::Null), v);
            }
        }
        (slot, v) => *slot = v.clone(),
    }
}

impl super::PbState {
    pub(crate) fn settings(&self) -> Value {
        let mut out = defaults();
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let stored: Option<String> = conn
            .query_row(
                "SELECT value FROM pb_config WHERE key = 'settings'",
                [],
                |r| r.get(0),
            )
            .ok();
        drop(conn);
        if let Some(raw) = stored {
            if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                deep_merge(&mut out, &v);
            }
        }
        out
    }

    fn settings_patch(&self, patch: &Value) -> Value {
        let conn = self
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let stored: String = conn
            .query_row(
                "SELECT value FROM pb_config WHERE key = 'settings'",
                [],
                |r| r.get(0),
            )
            .unwrap_or_else(|_| "{}".to_string());
        let mut merged = serde_json::from_str::<Value>(&stored).unwrap_or_else(|_| json!({}));
        deep_merge(&mut merged, patch);
        let _ = conn.execute(
            "INSERT INTO pb_config (key, value) VALUES ('settings', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [merged.to_string()],
        );
        drop(conn);
        self.settings()
    }
}

async fn view(
    State(state): State<AppState>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    if !matches!(pb_auth(&state, &headers), PbAuth::Superuser) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        );
    }
    match pb_of(&state) {
        Ok(pb) => (StatusCode::OK, Json(pb.settings())).into_response(),
        Err(r) => r,
    }
}

async fn update(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(patch): Json<Value>,
) -> axum::response::Response {
    if !matches!(pb_auth(&state, &headers), PbAuth::Superuser) {
        return pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        );
    }
    match pb_of(&state) {
        Ok(pb) => (StatusCode::OK, Json(pb.settings_patch(&patch))).into_response(),
        Err(r) => r,
    }
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/settings", get(view).patch(update))
}
