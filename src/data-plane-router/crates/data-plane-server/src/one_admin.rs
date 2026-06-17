//! binocle-one admin surface — the embedded dashboard + its admin-only API.
//!
//! `GET /_/` serves a single hand-rolled HTML/JS page from `include_str!` —
//! no framework, no build step, ~30 KB raw (the ≤1.5 MB compressed budget
//! existed for a bundler SPA; ours doesn't need compressing). It drives the
//! SAME public contracts the SDK uses (`/data/v1/schema`, `/data/v1/schema/
//! ddl`, `/data/v1/query`, `/nano/v1/keys`, `/nano/v1/realtime`) plus the
//! admin-scope endpoints here (users, files, cross-user grid via
//! `/nano/v1/raw` — admin CRUD stays owner-scoped by design, raw is the
//! escape hatch).
//!
//! Auth: the dashboard logs in with an **admin API key** (first boot prints
//! one; `NANO_ADMIN_KEY` pins it). The key only ever lives in the browser's
//! localStorage. The nano image never mounts any of this — headless is its
//! SKU identity.

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Redirect};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;

use crate::one::one_of;
use crate::routes::{api_err, AppState};

const ADMIN_HTML: &str = include_str!("../ui/admin.html");

async fn ui() -> axum::response::Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        Html(ADMIN_HTML),
    )
        .into_response()
}

async fn ui_redirect() -> Redirect {
    Redirect::permanent("/_/")
}

#[derive(Deserialize)]
struct LimitQuery {
    limit: Option<u32>,
}

/// GET /one/v1/admin/users — admin scope.
async fn users_list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Query(q): Query<LimitQuery>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if let Err(r) = crate::nano::authorize(&state, &headers, "admin") {
        return r;
    }
    let users = one.users.list_users(q.limit.unwrap_or(200).min(1000));
    Json(json!({ "users": users })).into_response()
}

/// DELETE /one/v1/admin/users/:id — admin scope; cascades identities,
/// refresh tokens, TOTP and recovery codes.
async fn users_delete(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: header::HeaderMap,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if let Err(r) = crate::nano::authorize(&state, &headers, "admin") {
        return r;
    }
    if !one.users.delete_user(&user_id) {
        return api_err(StatusCode::NOT_FOUND, "not_found", "no such user");
    }
    tracing::info!(target: "audit", event = "user_deleted", user = %user_id, "account removed by admin");
    StatusCode::NO_CONTENT.into_response()
}

/// GET /one/v1/admin/files — admin scope; newest first.
async fn files_list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Query(q): Query<LimitQuery>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if let Err(r) = crate::nano::authorize(&state, &headers, "admin") {
        return r;
    }
    let files = one.users.files_all(q.limit.unwrap_or(200).min(1000));
    Json(json!({ "files": files })).into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/_/", get(ui))
        .route("/_", get(ui_redirect))
        .route("/one/v1/admin/users", get(users_list))
        .route(
            "/one/v1/admin/users/:id",
            axum::routing::delete(users_delete),
        )
        .route("/one/v1/admin/files", get(files_list))
}

#[cfg(test)]
mod tests {
    use super::ADMIN_HTML;

    #[test]
    fn embedded_ui_is_present_and_lean() {
        assert!(ADMIN_HTML.contains("binocle"), "branding present");
        assert!(ADMIN_HTML.len() > 5_000, "page looks truncated");
        assert!(
            ADMIN_HTML.len() < 200_000,
            "UI grew past the lean budget ({} bytes raw)",
            ADMIN_HTML.len()
        );
        // The dashboard must drive the public contracts, not private ones.
        for needle in ["/data/v1/schema", "/nano/v1/keys", "/one/v1/admin/users", "/nano/v1/realtime"] {
            assert!(ADMIN_HTML.contains(needle), "missing {needle}");
        }
    }
}
