//! HTTP surface: the streaming + health routes and their handlers.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{header, HeaderMap};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use reqwest::Client;
use serde_json::json;

use crate::error::Result;
use crate::proxy::proxy;
use crate::resolve::SharedResolver;

/// AppState is the injected dependency set: the pooled client + the resolver.
#[derive(Clone)]
pub struct AppState {
    pub http: Client,
    pub resolver: SharedResolver,
}

/// router builds the stream engine's route table over the shared app state.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/stream/v1/health", get(health))
        .route("/stream/v1/movies/:id", get(stream))
        .with_state(Arc::new(state))
}

/// health is the liveness probe.
async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

/// stream resolves id to its upstream media URL and range-proxies it to the
/// player; resolution + proxy errors map to their client-safe status.
async fn stream(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Response> {
    let resolved = state.resolver.resolve(&id).await?;
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    Ok(proxy(&state.http, &resolved, range).await?.into_response())
}
