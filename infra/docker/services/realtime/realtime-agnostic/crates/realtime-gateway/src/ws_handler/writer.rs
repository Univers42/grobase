/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   writer.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures::stream::SplitSink;
use futures::SinkExt;
use realtime_core::{ConnectionId, EventEnvelope};
use tokio::sync::mpsc;
use tracing::{debug, error, warn};

enum SendStatus {
    Ok,
    SlowClient,
    Failed,
}

/// Render a `ServerMessage::Event` frame for one subscriber.
///
/// D2-realtime H1: the heavy `event` payload is serialized exactly ONCE per
/// event (cached on the shared `Arc<EventEnvelope>` — see
/// [`EventEnvelope::rendered_payload_json`]); here we only escape the small
/// per-connection `sub_id` and concatenate. The output is byte-identical to
/// `serde_json::to_string(&ServerMessage::Event { sub_id, event })` — the
/// internally-tagged enum emits `type` then `sub_id` then `event` in that order.
fn serialize_event(sub_id: &str, event: &EventEnvelope) -> Option<String> {
    let fragment = event.rendered_payload_json();
    let sub = serde_json::to_string(sub_id).ok()?; // quoted + JSON-escaped
    Some(format!(
        r#"{{"type":"EVENT","sub_id":{sub},"event":{fragment}}}"#
    ))
}

fn check_slow_client(elapsed: Duration, slow_count: &mut u32, conn_id: ConnectionId) -> SendStatus {
    if elapsed > Duration::from_millis(100) {
        *slow_count += 1;
    } else {
        *slow_count = 0;
    }
    if *slow_count > 10 {
        warn!(conn_id = %conn_id, "Client consistently slow, disconnecting");
        return SendStatus::SlowClient;
    }
    SendStatus::Ok
}

async fn send_frame(
    ws_sink: &mut SplitSink<WebSocket, Message>,
    json: String,
    conn_id: ConnectionId,
    slow_count: &mut u32,
) -> SendStatus {
    let start = Instant::now();
    let result = tokio::time::timeout(
        Duration::from_millis(500),
        ws_sink.send(Message::Text(json)),
    )
    .await;
    match result {
        Ok(Ok(())) => check_slow_client(start.elapsed(), slow_count, conn_id),
        Ok(Err(e)) => {
            debug!(conn_id = %conn_id, "WebSocket write error: {}", e);
            SendStatus::Failed
        }
        Err(_) => {
            warn!(conn_id = %conn_id, "WebSocket write timeout");
            SendStatus::Failed
        }
    }
}

pub(super) async fn writer_loop(
    mut ws_sink: SplitSink<WebSocket, Message>,
    mut send_rx: mpsc::Receiver<(String, Arc<EventEnvelope>)>,
    mut ctrl_rx: mpsc::Receiver<String>,
    conn_id: ConnectionId,
) {
    let mut slow_count = 0u32;
    loop {
        let json = tokio::select! {
            Some((sub_id, ev)) = send_rx.recv() => if let Some(j) = serialize_event(&sub_id, &ev) { j } else {
                error!(conn_id = %conn_id, "Failed to serialize event");
                continue;
            },
            Some(ctrl) = ctrl_rx.recv() => ctrl,
            else => break,
        };
        match send_frame(&mut ws_sink, json, conn_id, &mut slow_count).await {
            SendStatus::Ok => {}
            SendStatus::SlowClient | SendStatus::Failed => return,
        }
    }
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
#[cfg(test)]
mod tests {
    use super::*;
    use realtime_core::{EventPayload, ServerMessage, TopicPath};

    fn envelope(payload: &str) -> EventEnvelope {
        EventEnvelope::new(
            TopicPath::new("orders"),
            "inserted",
            bytes::Bytes::from(payload.to_owned()),
        )
    }

    /// The serialize-once frame must be byte-identical to the previous
    /// full-struct serde output, for every `sub_id` (including ones needing JSON
    /// escaping) — otherwise the wire protocol silently changes.
    #[test]
    fn serialize_once_is_byte_identical_to_serde() {
        let cases = [
            ("sub-1", r#"{"id":1,"status":"pending"}"#),
            ("sub/with\"quote", r#"{"nested":{"a":[1,2,3]},"t":"x"}"#),
            ("s", "null"),
            ("unicode-\u{00e9}", r#"{"v":"café"}"#),
        ];
        for (sub_id, payload) in cases {
            let ev = envelope(payload);
            let want = serde_json::to_string(&ServerMessage::Event {
                sub_id: sub_id.to_owned(),
                event: EventPayload::from_envelope(&ev),
            })
            .unwrap();
            let got = serialize_event(sub_id, &ev).unwrap();
            assert_eq!(got, want, "sub_id={sub_id:?} payload={payload}");
        }
    }

    /// The payload fragment is computed once and cached: a second render of the
    /// SAME envelope returns the exact same backing string (pointer-identical).
    #[test]
    fn payload_fragment_is_cached_once() {
        let ev = envelope(r#"{"a":1}"#);
        let first = ev.rendered_payload_json();
        let second = ev.rendered_payload_json();
        assert!(
            std::ptr::eq(first, second),
            "fragment must be memoized, not re-serialized"
        );
    }

    /// Cloning the envelope's Arc shares the cache, so two subscribers holding
    /// clones reuse one serialization (the cross-connection serialize-once).
    #[test]
    fn cache_is_shared_across_arc_clones() {
        let ev = std::sync::Arc::new(envelope(r#"{"a":1}"#));
        let a = std::sync::Arc::clone(&ev);
        let b = std::sync::Arc::clone(&ev);
        // Prime via one clone, then the other must return the same backing str.
        let pa = a.rendered_payload_json();
        let pb = b.rendered_payload_json();
        assert!(
            std::ptr::eq(pa, pb),
            "Arc clones must share the rendered cache"
        );
    }
}
