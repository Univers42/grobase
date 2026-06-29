//! PB realtime: `GET /api/realtime` (SSE) + `POST /api/realtime`
//! (subscription set updates) — the protocol the official SDK's
//! `pb.collection(x).subscribe(...)` speaks:
//!
//! 1. the SDK opens the SSE stream and waits for a `PB_CONNECT` event whose
//!    payload carries the server-assigned `clientId`;
//! 2. it POSTs `{clientId, subscriptions: ["col", "col/*", "col/<rid>"]}`
//!    (full replacement set, topics may carry `?options=` suffixes);
//! 3. every mutation event is emitted under the EXACT topic string the
//!    client subscribed with, payload `{action, record}`.
//!
//! Rule gating at this phase mirrors records: public (`""`) collections
//! stream to anyone, locked/expression rules stream to superusers only
//! (fail closed until the Phase K rules engine).

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{json, Value};
use std::collections::HashMap;

use super::{pb_auth, pb_err, pb_id, pb_of, PbAuth};
use crate::routes::AppState;

/// One connected SSE client: its replacement-set of topics + its pipe.
pub(crate) struct Client {
    topics: Vec<String>,
    superuser: bool,
    tx: tokio::sync::mpsc::UnboundedSender<(String, String)>,
}

#[derive(Default)]
pub(crate) struct Realtime {
    clients: std::sync::Mutex<HashMap<String, Client>>,
}

impl Realtime {
    /// Fan a committed mutation out. `topic_keys` are the collection's name
    /// and id; a client subscription matches if — stripped of `?options` —
    /// it equals `key`, `key/*`, or `key/<record id>`.
    pub(crate) fn publish(
        &self,
        topic_keys: &[&str],
        record_id: &str,
        action: &str,
        record: &Value,
        public: bool,
    ) {
        let payload = json!({ "action": action, "record": record }).to_string();
        let mut clients = self
            .clients
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        clients.retain(|_, c| {
            for raw in &c.topics {
                let topic = raw.split('?').next().unwrap_or(raw);
                let hit = topic_keys.iter().any(|k| {
                    topic == *k || topic == format!("{k}/*") || topic == format!("{k}/{record_id}")
                });
                if hit && (public || c.superuser) {
                    // a dead pipe = a disconnected client → drop it
                    if c.tx.send((raw.clone(), payload.clone())).is_err() {
                        return false;
                    }
                }
            }
            true
        });
    }
}

/// GET /api/realtime — the SSE stream.
async fn stream(State(state): State<AppState>) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let client_id = pb_id();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(String, String)>();
    pb.realtime
        .clients
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(
            client_id.clone(),
            Client {
                topics: vec![],
                superuser: false,
                tx,
            },
        );

    let connect = json!({ "clientId": client_id }).to_string();
    let pb_for_drop = pb.clone();
    let drop_id = client_id.clone();
    let stream = async_stream(move |yield_tx| async move {
        let _ = yield_tx.send(Ok::<Event, std::convert::Infallible>(
            Event::default()
                .id(&client_id)
                .event("PB_CONNECT")
                .data(&connect),
        ));
        while let Some((topic, payload)) = rx.recv().await {
            if yield_tx
                .send(Ok(Event::default()
                    .id(&client_id)
                    .event(&topic)
                    .data(&payload)))
                .is_err()
            {
                break;
            }
        }
        // sender side closed → deregister
        pb_for_drop
            .realtime
            .clients
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&drop_id);
    });
    Sse::new(stream)
        .keep_alive(
            KeepAlive::new()
                .interval(std::time::Duration::from_secs(15))
                .text("keepalive"),
        )
        .into_response()
}

/// Bridge an async producer into a Stream (mpsc-backed; avoids a direct
/// dependency on the async-stream macro crate).
fn async_stream<F, Fut, T>(f: F) -> impl futures::Stream<Item = T>
where
    F: FnOnce(tokio::sync::mpsc::UnboundedSender<T>) -> Fut,
    Fut: std::future::Future<Output = ()> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(f(tx));
    futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    })
}

/// POST /api/realtime — replace a client's subscription set.
async fn subscribe(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Json(req): Json<Value>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(client_id) = req.get("clientId").and_then(|v| v.as_str()) else {
        return pb_err(StatusCode::BAD_REQUEST, "missing clientId");
    };
    let topics: Vec<String> = req
        .get("subscriptions")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|t| t.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    let superuser = matches!(pb_auth(&state, &headers), PbAuth::Superuser);
    let mut clients = pb
        .realtime
        .clients
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(client) = clients.get_mut(client_id) else {
        return pb_err(StatusCode::NOT_FOUND, "missing or invalid client id");
    };
    client.topics = topics;
    client.superuser = superuser;
    StatusCode::NO_CONTENT.into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/realtime", get(stream).post(subscribe))
}
