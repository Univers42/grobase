/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   e2e.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#![allow(clippy::unwrap_used, clippy::expect_used)]

//! End-to-end integration tests for the realtime engine.
//!
//! These tests spin up a complete in-process server stack (event bus, registry,
//! router, fan-out, WebSocket gateway, REST API) and verify the full pipeline
//! from publish to delivery without any external databases or mocking.

use std::sync::Arc;
use std::time::Duration;

use axum::{
    routing::{get, post},
    Router,
};
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use realtime_auth::NoAuthProvider;
use realtime_bus_inprocess::InProcessBus;
use realtime_core::{AuthProvider, EventBus, EventBusPublisher, EventEnvelope, TopicPath};
use realtime_engine::{
    registry::SubscriptionRegistry, router::EventRouter, sequence::SequenceGenerator,
    PresenceTracker,
};
use realtime_gateway::{
    connection::ConnectionManager,
    fanout::FanOutWorkerPool,
    rest_api,
    ws_handler::{self, AppState},
};
use serde_json::json;
use tokio::net::TcpListener;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tower_http::cors::CorsLayer;

/// Helper: spin up a full server and return the address + shared state.
async fn start_test_server() -> (String, Arc<dyn EventBusPublisher>, Arc<dyn EventBus>) {
    let bus: Arc<dyn EventBus> = Arc::new(InProcessBus::new(16384));

    let publisher: Arc<dyn EventBusPublisher> = {
        let p = bus.publisher().await.unwrap();
        Arc::from(p)
    };

    let auth_provider: Arc<dyn AuthProvider> = Arc::new(NoAuthProvider::new());
    let registry = Arc::new(SubscriptionRegistry::new());
    let sequence_gen = Arc::new(SequenceGenerator::new());
    let conn_manager = Arc::new(ConnectionManager::new(1024));

    let fanout_pool = FanOutWorkerPool::new(Arc::clone(&conn_manager), 4);
    let dispatch_tx = fanout_pool.start();

    let router = Arc::new(EventRouter::new(
        Arc::clone(&registry),
        Arc::clone(&sequence_gen),
        dispatch_tx,
    ));

    // Start bus subscriber → router loop
    let bus_subscriber = bus.subscriber("*").await.unwrap();
    let router_clone = Arc::clone(&router);
    tokio::spawn(async move {
        router_clone.run_with_subscriber(bus_subscriber).await;
    });

    let app_state = AppState {
        conn_manager: Arc::clone(&conn_manager),
        registry: Arc::clone(&registry),
        auth_provider,
        bus_publisher: Arc::clone(&publisher),
        presence: Arc::new(PresenceTracker::new()),
        presence_shared: None,
        usage: None,
    };

    let app = Router::new()
        .route("/ws", get(ws_handler::ws_upgrade))
        .route("/v1/publish", post(rest_api::publish_event))
        .route("/v1/publish/batch", post(rest_api::publish_batch))
        .route("/v1/health", get(rest_api::health_check))
        .layer(CorsLayer::permissive())
        .with_state(app_state);

    // Bind to :0 so the OS assigns a random port
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let addr_str = format!("127.0.0.1:{}", addr.port());

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    // Give the server a moment to start
    tokio::time::sleep(Duration::from_millis(50)).await;

    (addr_str, publisher, bus)
}

/// Helper: connect a WebSocket client, authenticate, and return the stream.
async fn connect_and_auth(
    addr: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let url = format!("ws://{addr}/ws");
    let (ws_stream, _) = connect_async(&url).await.expect("Failed to connect");
    let (mut write, read) = ws_stream.split();

    // Authenticate
    let auth_msg = json!({ "type": "AUTH", "token": "test-token" });
    write
        .send(Message::Text(auth_msg.to_string()))
        .await
        .unwrap();

    // Wait for any auth response or just give a moment
    tokio::time::sleep(Duration::from_millis(50)).await;

    write.reunite(read).unwrap()
}

/// Helper: send a subscribe message over WebSocket.
async fn ws_subscribe(
    write: &mut futures::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        Message,
    >,
    sub_id: &str,
    topic: &str,
) {
    let sub_msg = json!({
        "type": "SUBSCRIBE",
        "sub_id": sub_id,
        "topic": topic,
    });
    write
        .send(Message::Text(sub_msg.to_string()))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
}

// ═══════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════

#[tokio::test]
async fn test_health_endpoint() {
    let (addr, _pub, _bus) = start_test_server().await;

    let client = reqwest::Client::new();
    let resp = client
        .get(format!("http://{addr}/v1/health"))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");
}

#[tokio::test]
async fn test_publish_event_via_rest() {
    let (addr, _pub, _bus) = start_test_server().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://{addr}/v1/publish"))
        .json(&json!({
            "topic": "test/orders/created",
            "event_type": "created",
            "payload": { "id": 1, "name": "Test Order" }
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["delivered_to_bus"], true);
    assert!(body["event_id"].as_str().is_some());
}

#[tokio::test]
async fn test_publish_batch_via_rest() {
    let (addr, _pub, _bus) = start_test_server().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://{addr}/v1/publish/batch"))
        .json(&json!({
            "events": [
                { "topic": "test/a", "event_type": "created", "payload": {"v": 1} },
                { "topic": "test/b", "event_type": "updated", "payload": {"v": 2} },
                { "topic": "test/c", "event_type": "deleted", "payload": {"v": 3} },
            ]
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    let results = body["results"].as_array().unwrap();
    assert_eq!(results.len(), 3);
    assert!(results.iter().all(|r| r["delivered_to_bus"] == true));
}

#[tokio::test]
async fn test_publish_empty_topic_rejected() {
    let (addr, _pub, _bus) = start_test_server().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://{addr}/v1/publish"))
        .json(&json!({
            "topic": "",
            "event_type": "created",
            "payload": {}
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 400);
}

#[tokio::test]
async fn test_websocket_connect_and_auth() {
    let (addr, _pub, _bus) = start_test_server().await;

    let url = format!("ws://{addr}/ws");
    let (ws_stream, _) = connect_async(&url).await.expect("Failed to connect");
    let (mut write, _read) = ws_stream.split();

    // Send auth
    let auth_msg = json!({ "type": "AUTH", "token": "hello" });
    write
        .send(Message::Text(auth_msg.to_string()))
        .await
        .unwrap();

    // If we get here without error, auth succeeded (NoAuth mode)
    tokio::time::sleep(Duration::from_millis(50)).await;
}

#[tokio::test]
async fn test_websocket_subscribe_and_receive_event() {
    let (addr, publisher, _bus) = start_test_server().await;

    // Connect and authenticate
    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    // Subscribe to a topic
    ws_subscribe(&mut write, "sub-1", "orders/created").await;

    // Publish an event via the bus directly
    let event = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from(r#"{"id":42,"item":"widget"}"#),
    );
    publisher.publish("orders/created", &event).await.unwrap();

    // Wait for the event to be delivered
    let received = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(msg)) = read.next().await {
            if let Message::Text(text) = msg {
                let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
                if parsed.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                    return Some(parsed);
                }
            }
        }
        None
    })
    .await;

    let event_msg = received
        .expect("Timeout waiting for event")
        .expect("No event received");
    assert_eq!(event_msg["type"], "EVENT");

    let payload = &event_msg["event"];
    assert_eq!(payload["topic"], "orders/created");
    assert_eq!(payload["event_type"], "created");
}

#[tokio::test]
async fn test_websocket_unsubscribe_stops_delivery() {
    let (addr, publisher, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    // Subscribe
    ws_subscribe(&mut write, "sub-unsub", "events/test").await;

    // Unsubscribe
    let unsub_msg = json!({ "type": "UNSUBSCRIBE", "sub_id": "sub-unsub" });
    write
        .send(Message::Text(unsub_msg.to_string()))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Publish after unsubscribe
    let event = EventEnvelope::new(
        TopicPath::new("events/test"),
        "test",
        Bytes::from(r#"{"data":"should_not_receive"}"#),
    );
    publisher.publish("events/test", &event).await.unwrap();

    // Should NOT receive the event (timeout expected)
    let received = tokio::time::timeout(Duration::from_millis(500), async {
        while let Some(Ok(msg)) = read.next().await {
            if let Message::Text(text) = msg {
                let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
                if parsed.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                    return Some(parsed);
                }
            }
        }
        None
    })
    .await;

    assert!(
        received.is_err(),
        "Should not have received event after unsubscribe"
    );
}

#[tokio::test]
async fn test_multiple_subscribers_same_topic() {
    let (addr, publisher, _bus) = start_test_server().await;

    // Connect two clients
    let ws1 = connect_and_auth(&addr).await;
    let ws2 = connect_and_auth(&addr).await;
    let (mut write1, mut read1) = ws1.split();
    let (mut write2, mut read2) = ws2.split();

    // Both subscribe to the same topic
    ws_subscribe(&mut write1, "sub-a", "shared/topic").await;
    ws_subscribe(&mut write2, "sub-b", "shared/topic").await;

    // Publish once
    let event = EventEnvelope::new(
        TopicPath::new("shared/topic"),
        "shared_event",
        Bytes::from(r#"{"data":"broadcast"}"#),
    );
    publisher.publish("shared/topic", &event).await.unwrap();

    // Both should receive
    let recv1 = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(Message::Text(text))) = read1.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                return true;
            }
        }
        false
    })
    .await;

    let recv2 = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(Message::Text(text))) = read2.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                return true;
            }
        }
        false
    })
    .await;

    assert!(
        recv1.unwrap_or(false),
        "Client 1 should have received event"
    );
    assert!(
        recv2.unwrap_or(false),
        "Client 2 should have received event"
    );
}

#[tokio::test]
async fn test_prefix_pattern_subscription() {
    let (addr, publisher, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    // Subscribe with prefix pattern
    ws_subscribe(&mut write, "sub-prefix", "orders/*").await;

    // Publish to matching topics
    let event1 = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from(r#"{"id":1}"#),
    );
    publisher.publish("orders/created", &event1).await.unwrap();

    let event2 = EventEnvelope::new(
        TopicPath::new("orders/updated"),
        "updated",
        Bytes::from(r#"{"id":2}"#),
    );
    publisher.publish("orders/updated", &event2).await.unwrap();

    // Should receive at least one event
    let received = tokio::time::timeout(Duration::from_secs(3), async {
        let mut count = 0;
        while let Some(Ok(Message::Text(text))) = read.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                count += 1;
                if count >= 2 {
                    return count;
                }
            }
        }
        count
    })
    .await;

    assert!(
        received.unwrap_or(0) >= 1,
        "Should have received events from prefix subscription"
    );
}

#[tokio::test]
async fn test_publish_via_rest_delivered_to_websocket() {
    let (addr, _pub, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    // Subscribe
    ws_subscribe(&mut write, "sub-rest", "api/events").await;

    // Publish via REST
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://{addr}/v1/publish"))
        .json(&json!({
            "topic": "api/events",
            "event_type": "rest_published",
            "payload": { "source": "REST API" }
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);

    // Should receive via WebSocket
    let received = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(Message::Text(text))) = read.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                return Some(p);
            }
        }
        None
    })
    .await;

    let event = received.expect("Timeout").expect("No event");
    assert_eq!(event["event"]["topic"], "api/events");
    assert_eq!(event["event"]["event_type"], "rest_published");
}

#[tokio::test]
async fn test_event_bus_publish_subscribe_flow() {
    // Test the event bus directly without the server
    let bus = InProcessBus::new(1024);
    let publisher = bus.publisher().await.unwrap();
    let mut subscriber = bus.subscriber("*").await.unwrap();

    let event = EventEnvelope::new(
        TopicPath::new("test/direct"),
        "direct_test",
        Bytes::from(r#"{"key":"value"}"#),
    );

    publisher.publish("test/direct", &event).await.unwrap();

    let received = tokio::time::timeout(Duration::from_secs(1), subscriber.next_event()).await;
    assert!(received.is_ok(), "Should have received event from bus");
    let received_event = received.unwrap().unwrap();
    assert_eq!(received_event.topic.as_str(), "test/direct");
}

#[tokio::test]
async fn test_subscription_registry_operations() {
    use realtime_core::{ConnectionId, SubConfig, Subscription, SubscriptionId, TopicPattern};
    use smol_str::SmolStr;

    let registry = SubscriptionRegistry::new();

    let sub = Subscription {
        sub_id: SubscriptionId(SmolStr::new("test-sub")),
        conn_id: ConnectionId(1),
        topic: TopicPattern::parse("orders/*"),
        filter: None,
        config: SubConfig::default(),
    };

    registry.subscribe(sub, None).unwrap();

    let sub_event = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from(r#"{"status":"pending"}"#),
    );
    let matches = registry.lookup_matches(&sub_event);
    assert!(
        !matches.is_empty(),
        "Should find subscription for orders/created"
    );

    let sub_event2 = EventEnvelope::new(
        TopicPath::new("users/created"),
        "created",
        Bytes::from(r"{}"),
    );
    let matches2 = registry.lookup_matches(&sub_event2);
    assert!(
        matches2.is_empty(),
        "Should NOT find subscription for users/created"
    );

    // Verify remove
    registry.unsubscribe(ConnectionId(1), "test-sub");
    let matches3 = registry.lookup_matches(&sub_event);
    assert!(matches3.is_empty(), "Should be empty after unsubscribe");
}

#[tokio::test]
async fn test_filter_evaluation() {
    use realtime_core::filter::{FieldPath, FilterValue};
    use realtime_core::{
        filter::FilterExpr, ConnectionId, SubConfig, Subscription, SubscriptionId, TopicPattern,
    };
    use smol_str::SmolStr;

    let registry = SubscriptionRegistry::new();

    let filter = FilterExpr::Eq(
        FieldPath::new("event_type"),
        FilterValue::String("created".into()),
    );

    let sub = Subscription {
        sub_id: SubscriptionId(SmolStr::new("filtered-sub")),
        conn_id: ConnectionId(1),
        topic: TopicPattern::parse("orders/*"),
        filter: Some(filter),
        config: SubConfig::default(),
    };

    registry.subscribe(sub, None).unwrap();

    // Verify the subscription matches an event with event_type="created"
    let event = EventEnvelope::new(
        TopicPath::new("orders/created"),
        "created",
        Bytes::from(r#"{"status":"pending"}"#),
    );
    let matches = registry.lookup_matches(&event);
    assert!(!matches.is_empty(), "Should find filtered subscription");

    // Verify the filter rejects a non-matching event_type
    let event_no_match = EventEnvelope::new(
        TopicPath::new("orders/deleted"),
        "deleted",
        Bytes::from(r#"{"status":"pending"}"#),
    );
    let matches_no = registry.lookup_matches(&event_no_match);
    assert!(
        matches_no.is_empty(),
        "Filter should reject event with wrong event_type"
    );
}

#[tokio::test]
async fn test_connection_manager_lifecycle() {
    use chrono::Utc;
    use realtime_core::{ConnectionId, ConnectionMeta, OverflowPolicy};

    let mgr = ConnectionManager::new(64);

    let meta = ConnectionMeta {
        conn_id: ConnectionId(42),
        peer_addr: "127.0.0.1:8080".parse().unwrap(),
        connected_at: Utc::now(),
        user_id: None,
        claims: None,
    };

    let (_conn_id, _rx) = mgr.register(meta, OverflowPolicy::DropNewest);
    assert_eq!(mgr.connection_count(), 1);

    // Remove
    mgr.remove(ConnectionId(42));
    assert_eq!(mgr.connection_count(), 0);
}

#[tokio::test]
async fn test_sequence_generator_monotonic() {
    let gen = SequenceGenerator::new();

    let seq1 = gen.next("topic-a");
    let seq2 = gen.next("topic-a");
    let seq3 = gen.next("topic-a");

    assert!(seq2 > seq1);
    assert!(seq3 > seq2);

    // Different topics have independent sequences
    let other_seq = gen.next("topic-b");
    assert_eq!(other_seq, 1, "New topic should start at 1");
}

#[tokio::test]
async fn test_event_envelope_serialization() {
    let event = EventEnvelope::new(
        TopicPath::new("test/serde"),
        "serialization_test",
        Bytes::from(r#"{"hello":"world"}"#),
    );

    let json = serde_json::to_string(&event).unwrap();
    let deserialized: EventEnvelope = serde_json::from_str(&json).unwrap();

    assert_eq!(deserialized.topic.as_str(), "test/serde");
    assert_eq!(deserialized.event_type, "serialization_test");
    assert_eq!(deserialized.payload.as_ref(), event.payload.as_ref());
}

#[tokio::test]
async fn test_jwt_auth_provider() {
    use jsonwebtoken::{encode, EncodingKey, Header};
    use realtime_auth::{JwtAuthProvider, JwtConfig};
    use realtime_core::{AuthContext, AuthProvider};

    let secret = "test-secret-key-for-jwt-testing-2024";
    let config = JwtConfig::hmac(secret);
    let provider = JwtAuthProvider::new(&config).unwrap();

    // Create a valid JWT token
    let claims = json!({
        "sub": "user-123",
        "exp": chrono::Utc::now().timestamp() + 3600,
        "iat": chrono::Utc::now().timestamp(),
        "can_subscribe": true,
        "namespaces": ["*"]
    });

    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap();

    let ctx = AuthContext {
        peer_addr: "127.0.0.1:0".parse().unwrap(),
        transport: "websocket".to_string(),
    };

    let result = provider.verify(&token, &ctx).await;
    assert!(
        result.is_ok(),
        "Valid JWT should verify: {:?}",
        result.err()
    );

    let auth_claims = result.unwrap();
    assert_eq!(auth_claims.sub, "user-123");
}

/// Regression for the rc.3 authz fix: a token scoped to one namespace must be
/// DENIED publish to another namespace. `handle_publish`/`handle_broadcast`/
/// `handle_track` all gate on `authorize_publish`, so this is the primitive that
/// keeps a tenant from broadcasting / injecting presence into another tenant's
/// topics. (Before the fix those handlers checked only authentication.)
#[tokio::test]
async fn test_jwt_authorize_publish_is_namespace_scoped() {
    use jsonwebtoken::{encode, EncodingKey, Header};
    use realtime_auth::{JwtAuthProvider, JwtConfig};
    use realtime_core::{AuthContext, AuthProvider};

    let secret = "test-secret-key-for-jwt-testing-2024";
    let config = JwtConfig::hmac(secret);
    let provider = JwtAuthProvider::new(&config).unwrap();

    let claims = json!({
        "sub": "user-a",
        "exp": chrono::Utc::now().timestamp() + 3600,
        "iat": chrono::Utc::now().timestamp(),
        "can_publish": true,
        "namespaces": ["tenant_a"]
    });
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap();
    let ctx = AuthContext {
        peer_addr: "127.0.0.1:0".parse().unwrap(),
        transport: "websocket".to_string(),
    };
    let auth_claims = provider.verify(&token, &ctx).await.unwrap();

    // Allowed inside its own namespace …
    assert!(
        provider
            .authorize_publish(&auth_claims, &TopicPath::new("tenant_a/orders"))
            .await
            .is_ok(),
        "publish to own namespace must be allowed"
    );
    // … denied to another tenant's namespace (the isolation guarantee).
    assert!(
        provider
            .authorize_publish(&auth_claims, &TopicPath::new("tenant_b/orders"))
            .await
            .is_err(),
        "publish to another namespace must be DENIED"
    );
}

#[tokio::test]
async fn test_jwt_auth_rejects_invalid_token() {
    use realtime_auth::{JwtAuthProvider, JwtConfig};
    use realtime_core::{AuthContext, AuthProvider};

    let config = JwtConfig::hmac("correct-secret");
    let provider = JwtAuthProvider::new(&config).unwrap();

    let ctx = AuthContext {
        peer_addr: "127.0.0.1:0".parse().unwrap(),
        transport: "websocket".to_string(),
    };

    // Invalid token
    let result = provider.verify("not.a.valid.token", &ctx).await;
    assert!(result.is_err(), "Invalid token should fail verification");
}

#[tokio::test]
async fn test_noauth_allows_everything() {
    use realtime_auth::NoAuthProvider;
    use realtime_core::{AuthContext, AuthProvider, TopicPattern};

    let provider = NoAuthProvider::new();

    let ctx = AuthContext {
        peer_addr: "127.0.0.1:0".parse().unwrap(),
        transport: "websocket".to_string(),
    };

    // Any token should work
    let result = provider.verify("literally-anything", &ctx).await;
    assert!(result.is_ok());

    let claims = result.unwrap();
    let pattern = TopicPattern::parse("any/topic/here");
    let sub_result = provider.authorize_subscribe(&claims, &pattern).await;
    assert!(sub_result.is_ok(), "NoAuth should allow all subscriptions");
}

#[tokio::test]
async fn test_high_throughput_publish() {
    let (addr, publisher, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    ws_subscribe(&mut write, "sub-throughput", "perf/*").await;

    let event_count = 100;
    let start = std::time::Instant::now();

    // Publish many events
    for i in 0..event_count {
        let event = EventEnvelope::new(
            TopicPath::new("perf/test"),
            "throughput",
            Bytes::from(format!(r#"{{"seq":{i}}}"#)),
        );
        publisher.publish("perf/test", &event).await.unwrap();
    }

    // Count received events (with timeout)
    let mut received = 0;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);

    while tokio::time::Instant::now() < deadline && received < event_count {
        match tokio::time::timeout(Duration::from_millis(500), read.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                let p: serde_json::Value = serde_json::from_str(&text).unwrap();
                if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                    received += 1;
                }
            }
            _ => break,
        }
    }

    let elapsed = start.elapsed();

    println!(
        "Throughput test: {}/{} events in {:?} ({:.0} evt/s)",
        received,
        event_count,
        elapsed,
        f64::from(received) / elapsed.as_secs_f64()
    );

    assert!(
        received >= event_count / 2,
        "Should have received at least half of {event_count} events, got {received}"
    );
}

#[tokio::test]
async fn test_websocket_ping() {
    let (addr, _pub, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, _read) = ws.split();

    // Send ping
    let ping_msg = json!({ "type": "PING" });
    let result = write.send(Message::Text(ping_msg.to_string())).await;
    assert!(result.is_ok(), "Ping should succeed");
}

#[tokio::test]
async fn test_subscribe_batch() {
    let (addr, publisher, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();

    // Subscribe to multiple topics at once
    let batch_msg = json!({
        "type": "SUBSCRIBE_BATCH",
        "subscriptions": [
            { "sub_id": "batch-1", "topic": "topic-a" },
            { "sub_id": "batch-2", "topic": "topic-b" },
        ]
    });
    write
        .send(Message::Text(batch_msg.to_string()))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Publish to topic-b
    let event = EventEnvelope::new(
        TopicPath::new("topic-b"),
        "test",
        Bytes::from(r#"{"from":"batch"}"#),
    );
    publisher.publish("topic-b", &event).await.unwrap();

    let received = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(Ok(Message::Text(text))) = read.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                return true;
            }
        }
        false
    })
    .await;

    assert!(
        received.unwrap_or(false),
        "Should receive event from batch subscription"
    );
}

#[tokio::test]
async fn test_topic_path_operations() {
    let tp1 = TopicPath::new("orders/created");
    assert_eq!(tp1.as_str(), "orders/created");

    let tp2 = TopicPath::new("db/users/updated");
    assert_eq!(tp2.as_str(), "db/users/updated");

    // TopicPath should be clonable
    let tp3 = tp1.clone();
    assert_eq!(tp1.as_str(), tp3.as_str());
}

#[tokio::test]
async fn test_multiple_concurrent_connections() {
    let (addr, publisher, _bus) = start_test_server().await;

    let num_clients = 10;
    let mut handles = vec![];

    for i in 0..num_clients {
        let addr = addr.clone();

        let handle = tokio::spawn(async move {
            let ws = connect_and_auth(&addr).await;
            let (mut write, mut read) = ws.split();

            ws_subscribe(&mut write, &format!("sub-{i}"), "concurrent/test").await;

            // Wait for an event
            let received = tokio::time::timeout(Duration::from_secs(5), async {
                while let Some(Ok(Message::Text(text))) = read.next().await {
                    let p: serde_json::Value = serde_json::from_str(&text).unwrap();
                    if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                        return true;
                    }
                }
                false
            })
            .await;

            received.unwrap_or(false)
        });

        handles.push(handle);
    }

    // Give connections time to subscribe
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Publish once
    let event = EventEnvelope::new(
        TopicPath::new("concurrent/test"),
        "broadcast",
        Bytes::from(r#"{"all":"clients"}"#),
    );
    publisher.publish("concurrent/test", &event).await.unwrap();

    // Check that most clients received the event
    let mut received_count = 0;
    for handle in handles {
        if handle.await.unwrap_or(false) {
            received_count += 1;
        }
    }

    println!("Concurrent test: {received_count}/{num_clients} clients received event");
    assert!(
        received_count >= num_clients / 2,
        "At least half of {num_clients} clients should receive event, got {received_count}"
    );
}

// ═══════════════════════════════════════════════════════════
// A5 — broadcast (client→client) + presence (who's online)
// ═══════════════════════════════════════════════════════════

/// Read the next `EVENT` frame (parsed) off a split WS read half, or `None`
/// on timeout. Optionally require a specific inner `event_type`.
async fn next_event(
    read: &mut futures::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    want_event_type: Option<&str>,
    timeout: Duration,
) -> Option<serde_json::Value> {
    tokio::time::timeout(timeout, async {
        while let Some(Ok(Message::Text(text))) = read.next().await {
            let p: serde_json::Value = serde_json::from_str(&text).unwrap();
            if p.get("type").and_then(|t| t.as_str()) == Some("EVENT") {
                let et = p["event"]["event_type"].as_str();
                if want_event_type.is_none() || et == want_event_type {
                    return Some(p);
                }
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
}

#[tokio::test]
async fn test_broadcast_client_to_client() {
    // Two clients subscribe to a topic; one BROADCASTs; the other receives it
    // as a normal EVENT with event_type "broadcast". No DB involved — the
    // message flows over the EventBus, which makes it multi-node-capable.
    let (addr, _pub, _bus) = start_test_server().await;

    let ws1 = connect_and_auth(&addr).await;
    let ws2 = connect_and_auth(&addr).await;
    let (mut write1, mut read1) = ws1.split();
    let (mut write2, mut read2) = ws2.split();

    ws_subscribe(&mut write1, "b-sub-1", "room/lobby").await;
    ws_subscribe(&mut write2, "b-sub-2", "room/lobby").await;

    // Client 1 broadcasts a cursor move.
    let bcast = json!({
        "type": "BROADCAST",
        "topic": "room/lobby",
        "event": "cursor_move",
        "payload": { "x": 12, "y": 34 }
    });
    write1.send(Message::Text(bcast.to_string())).await.unwrap();

    // Client 2 must receive it as an EVENT with event_type "broadcast".
    let got = next_event(&mut read2, Some("broadcast"), Duration::from_secs(3)).await;
    let ev = got.expect("client 2 should receive the broadcast");
    assert_eq!(ev["event"]["topic"], "room/lobby");
    assert_eq!(ev["event"]["event_type"], "broadcast");
    assert_eq!(ev["event"]["payload"]["event"], "cursor_move");
    assert_eq!(ev["event"]["payload"]["payload"]["x"], 12);

    // The broadcaster itself is also a subscriber, so it sees its own message
    // (Supabase `self: true` semantics). Drain to prove no panic.
    let _self_echo = next_event(&mut read1, Some("broadcast"), Duration::from_secs(1)).await;
}

#[tokio::test]
async fn test_presence_join_then_leave() {
    // A subscribes to a topic and TRACKs presence; B subscribes and observes
    // A in a presence snapshot; A disconnects → B observes A leave.
    let (addr, _pub, _bus) = start_test_server().await;

    let ws_a = connect_and_auth(&addr).await;
    let (mut write_a, mut read_a) = ws_a.split();
    let ws_b = connect_and_auth(&addr).await;
    let (mut write_b, mut read_b) = ws_b.split();

    // Both watch the same topic for presence EVENTs.
    ws_subscribe(&mut write_a, "p-sub-a", "doc/42").await;
    ws_subscribe(&mut write_b, "p-sub-b", "doc/42").await;

    // A joins presence.
    let track_a = json!({
        "type": "TRACK",
        "topic": "doc/42",
        "meta": { "name": "alice", "color": "blue" }
    });
    write_a
        .send(Message::Text(track_a.to_string()))
        .await
        .unwrap();

    // B should receive a presence snapshot listing at least one member.
    let join = next_event(&mut read_b, Some("presence"), Duration::from_secs(3)).await;
    let join = join.expect("B should see A join presence");
    let members = join["event"]["payload"]["members"].as_array().unwrap();
    assert_eq!(members.len(), 1, "exactly A is present");
    assert_eq!(members[0]["meta"]["name"], "alice");

    // Drain A's own join echo so its read half is clear.
    let _ = next_event(&mut read_a, Some("presence"), Duration::from_secs(1)).await;

    // A disconnects → its connection cleanup emits a LEAVE snapshot.
    drop(write_a);
    drop(read_a);

    let leave = next_event(&mut read_b, Some("presence"), Duration::from_secs(3)).await;
    let leave = leave.expect("B should see A leave presence");
    let members_after = leave["event"]["payload"]["members"].as_array().unwrap();
    assert_eq!(members_after.len(), 0, "no members remain after A leaves");
}

#[tokio::test]
async fn test_untrack_emits_leave() {
    // Explicit UNTRACK (not just disconnect) emits a presence LEAVE.
    let (addr, _pub, _bus) = start_test_server().await;

    let ws = connect_and_auth(&addr).await;
    let (mut write, mut read) = ws.split();
    ws_subscribe(&mut write, "u-sub", "team/eng").await;

    write
        .send(Message::Text(
            json!({ "type": "TRACK", "topic": "team/eng", "meta": { "name": "bob" } }).to_string(),
        ))
        .await
        .unwrap();
    let join = next_event(&mut read, Some("presence"), Duration::from_secs(3)).await;
    assert_eq!(
        join.expect("join")["event"]["payload"]["members"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    write
        .send(Message::Text(
            json!({ "type": "UNTRACK", "topic": "team/eng" }).to_string(),
        ))
        .await
        .unwrap();
    let leave = next_event(&mut read, Some("presence"), Duration::from_secs(3)).await;
    assert_eq!(
        leave.expect("leave")["event"]["payload"]["members"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}
