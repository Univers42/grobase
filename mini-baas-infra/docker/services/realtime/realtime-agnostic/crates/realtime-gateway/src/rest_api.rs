/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rest_api.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! REST API handlers for event publishing and health checks.
//!
//! | Method | Path                | Description                       |
//! |--------|---------------------|-----------------------------------|
//! | `POST` | `/v1/publish`       | Publish a single event            |
//! | `POST` | `/v1/publish/batch` | Publish up to 1000 events         |
//! | `GET`  | `/v1/health`        | Health check + connection stats   |
//! | `GET`  | `/v1/presence`      | List a topic's presence members   |

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use bytes::Bytes;
use realtime_core::{
    BatchPublishRequest, BatchPublishResponse, EventEnvelope, HealthResponse, PresenceMember,
    PublishRequest, PublishResponse, TopicPath,
};
use serde::Deserialize;
use tracing::{debug, error};

use crate::ws_handler::AppState;

type ApiError = (StatusCode, Json<serde_json::Value>);

fn validate_and_create_envelope(req: &PublishRequest) -> Result<EventEnvelope, ApiError> {
    if req.topic.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "Topic is required" })),
        ));
    }
    let bytes = serde_json::to_vec(&req.payload).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": format!("Invalid payload: {e}") })),
        )
    })?;
    if bytes.len() > 65_536 {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(serde_json::json!({ "error": "Payload exceeds 64KB limit" })),
        ));
    }
    Ok(EventEnvelope::new(
        TopicPath::new(&req.topic),
        &req.event_type,
        Bytes::from(bytes),
    ))
}

fn validate_batch(req: &BatchPublishRequest) -> Result<Vec<(String, EventEnvelope)>, ApiError> {
    if req.events.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "At least one event is required" })),
        ));
    }
    if req.events.len() > 1000 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "Maximum 1000 events per batch" })),
        ));
    }
    let mut events = Vec::with_capacity(req.events.len());
    for item in &req.events {
        let bytes = serde_json::to_vec(&item.payload).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({ "error": format!("Invalid payload: {e}") })),
            )
        })?;
        if bytes.len() > 65_536 {
            return Err((
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(serde_json::json!({ "error": "Payload exceeds 64KB" })),
            ));
        }
        let ev = EventEnvelope::new(
            TopicPath::new(&item.topic),
            &item.event_type,
            Bytes::from(bytes),
        );
        events.push((item.topic.clone(), ev));
    }
    Ok(events)
}

pub async fn publish_event(
    State(state): State<AppState>,
    Json(req): Json<PublishRequest>,
) -> impl IntoResponse {
    let event = match validate_and_create_envelope(&req) {
        Ok(e) => e,
        Err(resp) => return resp,
    };
    match state.bus_publisher.publish(&req.topic, &event).await {
        Ok(receipt) => {
            debug!(event_id = %receipt.event_id, topic = %req.topic, "Event published");
            (
                StatusCode::OK,
                Json(serde_json::json!(PublishResponse {
                    event_id: receipt.event_id.to_string(),
                    sequence: receipt.sequence,
                    delivered_to_bus: receipt.delivered_to_bus,
                })),
            )
        }
        Err(e) => {
            error!("Failed to publish event: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": format!("Publish failed: {e}") })),
            )
        }
    }
}

pub async fn publish_batch(
    State(state): State<AppState>,
    Json(req): Json<BatchPublishRequest>,
) -> impl IntoResponse {
    let events = match validate_batch(&req) {
        Ok(e) => e,
        Err(resp) => return resp,
    };
    match state.bus_publisher.publish_batch(&events).await {
        Ok(receipts) => {
            let results: Vec<PublishResponse> = receipts
                .iter()
                .map(|r| PublishResponse {
                    event_id: r.event_id.to_string(),
                    sequence: r.sequence,
                    delivered_to_bus: r.delivered_to_bus,
                })
                .collect();
            (
                StatusCode::OK,
                Json(serde_json::json!(BatchPublishResponse { results })),
            )
        }
        Err(e) => {
            error!("Failed to publish batch: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": format!("Batch failed: {e}") })),
            )
        }
    }
}

#[allow(clippy::unused_async)]
pub async fn health_check(State(state): State<AppState>) -> impl IntoResponse {
    let filter_snapshot = state.registry.filter_index_snapshot();

    // Status is "degraded" if the circuit breaker has recently bypassed evaluations.
    let status = if filter_snapshot.circuit_bypassed > 0 {
        "degraded"
    } else {
        "ok"
    };

    let resp = HealthResponse {
        status: status.to_string(),
        connections: state.conn_manager.connection_count() as u64,
        subscriptions: state.registry.subscription_count() as u64,
        uptime_seconds: 0,
        filter_index: serde_json::to_value(&filter_snapshot).ok(),
        dispatch: None,
    };
    (StatusCode::OK, Json(resp))
}

/// `GET /metrics` — Prometheus exposition of fan-out drop/dispatch counters.
///
/// Track-2 C4. No state: the counters are a process-global singleton the
/// fan-out workers bump. Scraped by the suite's Prometheus (job `realtime`).
#[allow(clippy::unused_async)] // axum handlers must be async to satisfy Handler
pub async fn prometheus() -> impl IntoResponse {
    (
        StatusCode::OK,
        [("content-type", "text/plain; version=0.0.4; charset=utf-8")],
        crate::metrics::render_prometheus(),
    )
}

/// Query string for `GET /v1/presence?topic=<topic>`.
#[derive(Debug, Deserialize)]
pub struct PresenceQuery {
    /// The topic whose presence set is requested.
    pub topic: String,
}

/// The presence query response: the topic and its current member list.
#[derive(Debug, serde::Serialize)]
pub struct PresenceResponse {
    pub topic: String,
    pub members: Vec<PresenceMember>,
}

/// `GET /v1/presence?topic=<topic>` — list a topic's presence members.
///
/// A5 cross-node merge: when the shared store is ON (`presence_shared` is
/// `Some`, set by `REALTIME_PRESENCE_SHARED`) the list is read from Redis, so a
/// member that joined on ANOTHER node is included — node B answers for a member
/// that tracked on node A. When OFF (`None`, the parity default) it answers from
/// this node's LOCAL in-process tracker exactly as a single node always has — so
/// a second node simply does not see the first.
///
/// A topic only ever reads back its OWN key, so a member in channel X can never
/// appear in a query for channel Y (no cross-channel leak by construction).
pub async fn presence_query(
    State(state): State<AppState>,
    Query(q): Query<PresenceQuery>,
) -> impl IntoResponse {
    if q.topic.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "topic query parameter is required" })),
        );
    }
    let members = match state.presence_shared.as_ref() {
        // Cross-node: the MERGED set across all nodes (read from Redis).
        Some(shared) => shared.members(&q.topic).await,
        // Parity: this node's local view only — single-node behaviour.
        None => state.presence.members(&q.topic),
    };
    debug!(topic = %q.topic, count = members.len(), "presence query");
    (
        StatusCode::OK,
        Json(serde_json::json!(PresenceResponse {
            topic: q.topic,
            members,
        })),
    )
}
