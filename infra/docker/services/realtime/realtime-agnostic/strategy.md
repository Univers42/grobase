# Realtime Engine Architecture
## Database-Agnostic, Horizontally Scalable, Rust-Native

**Version**: 1.0 — Principal Architecture Review  
**Status**: Design Specification

---

## Table of Contents

1. [Refined Problem Statement](#1-refined-problem-statement)
2. [High-Level Architecture](#2-high-level-architecture)
3. [The Realtime Model](#3-the-realtime-model)
4. [Rust-Centric Design](#4-rust-centric-design)
5. [Scalability Strategy](#5-scalability-strategy)
6. [Modularity and Plugin System](#6-modularity-and-plugin-system)
7. [Failure Handling and Resilience](#7-failure-handling-and-resilience)
8. [Performance Optimization](#8-performance-optimization)
9. [API Design and Developer Experience](#9-api-design-and-developer-experience)
10. [Step-by-Step Implementation Plan](#10-step-by-step-implementation-plan)

---

## 1. Refined Problem Statement

### The Core Insight

Existing realtime systems — Supabase Realtime, Firebase RTDB, Ably, and their kin — share a foundational assumption: the truth lives in the database, and realtime is a derived view of that truth obtained by tailing the write log. This is expedient but structurally limiting. It couples the realtime layer to a specific database's replication protocol, it forces the event schema to match the database's internal change format, and it makes it impossible to publish events that aren't database writes (business events, computed values, external webhooks).

The correct model: **realtime is a message routing problem, not a database problem.** The source of truth for *what clients should receive* is the subscription registry; the source of truth for *what events exist* is the event bus. The database is just one possible producer among many.

### Precise Problem Statement

Design and implement a horizontally-scalable, transport-agnostic, database-agnostic event routing engine that:

- Accepts events from any authenticated producer via a stable publish API (REST, gRPC, or SDK)
- Maintains a distributed subscription registry mapping topics and filter predicates to connected clients
- Routes events to matching clients with sub-10ms median end-to-end latency under normal conditions
- Sustains millions of concurrent stateful connections distributed across a cluster of commodity nodes
- Provides at-least-once delivery with idempotent client-side deduplication
- Degrades gracefully under node failure, network partition, and client-side reconnection storms
- Exposes a single, database-agnostic developer API regardless of which pub/sub backend is deployed

### Non-Goals (explicitly out of scope)

- Persistent storage of event history (this is a pub/sub engine, not an event store)
- Bi-directional RPC between clients (clients only consume; producers only publish)
- Schema enforcement or data validation beyond topic/filter structure
- Built-in authentication (delegated to a pluggable auth provider)

### Hidden Constraints and Challenges

**Fan-out amplification**: A popular topic with 500,000 subscribers receiving one event per second at 1KB payload = 500MB/s of egress from a single node. This is the primary capacity constraint. The system must handle fan-out as a first-class architectural concern, not an afterthought.

**Filter evaluation at scale**: Clients subscribe with predicate filters (`payload.user_id = 42 AND type = 'order.created'`). With 1M connections each holding 3 subscriptions, evaluating 3M predicates against every event is O(N) and must be made sublinear through indexing.

**Subscription state is distributed state**: The subscription registry is a strongly consistent, frequently-read, infrequently-written distributed data structure. It must be available during reads (event routing) and consistent during writes (subscribe/unsubscribe). This is a classic read-heavy distributed systems problem.

**The reconnect thundering herd**: When a gateway node crashes, its 50,000 connections all attempt to reconnect within a 1–3 second window. The cluster must absorb this burst without cascading. Exponential backoff with jitter is required on the client and graceful shedding on the server.

**Head-of-line blocking at the connection level**: A slow client (mobile on 3G, tab in background) that cannot consume events fast enough must not delay delivery to other clients subscribed to the same topic. Per-connection bounded queues with configurable overflow policy (drop oldest, drop newest, disconnect) are mandatory.

**Backpressure propagation boundaries**: TCP-level backpressure from a slow socket must terminate at the per-connection send buffer. It must never propagate backward into the fan-out stage, the event router, or the pub/sub bus. Violating this causes a single slow client to block thousands of others.

---

## 2. High-Level Architecture

### Component Inventory

```
┌─────────────────────────────────────────────────────────────────┐
│  CLIENT TIER                                                    │
│  Browser / Mobile / Server  ←→  WS / SSE / gRPC-stream         │
└─────────────────┬───────────────────────────────────────────────┘
                  │ millions of long-lived connections
┌─────────────────▼───────────────────────────────────────────────┐
│  GATEWAY TIER  (stateless, N nodes, L4 load balanced)           │
│                                                                 │
│  ┌─────────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Connection Mgr  │  │ Auth Middle  │  │  Sub Negotiation  │  │
│  │ tokio WS tasks  │  │ JWT / APIKey │  │  parse + validate │  │
│  └────────┬────────┘  └──────┬───────┘  └────────┬──────────┘  │
│           └─────────────────┴─────────────────────┘            │
│                              │                                  │
│  ┌───────────────────────────▼───────────────────────────────┐  │
│  │   Fan-out workers  (per-node tokio task pool)             │  │
│  │   recv(event + conn_ids) → write to per-conn send queue   │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │ internal gRPC/QUIC               │
└─────────────────┬────────────┼──────────────────────────────────┘
                  │            │
┌─────────────────▼────────────▼──────────────────────────────────┐
│  CORE ENGINE  (stateful, M nodes, Raft-coordinated)             │
│                                                                 │
│  ┌─────────────────────┐  ┌──────────────────┐                  │
│  │  Subscription       │  │  Filter          │                  │
│  │  Registry           │  │  Evaluator       │                  │
│  │  topic → [conn_id]  │  │  predicate index │                  │
│  │  DashMap + Trie     │  │  roaring bitmaps │                  │
│  └──────────┬──────────┘  └───────┬──────────┘                  │
│             └──────────┬──────────┘                             │
│                        │                                        │
│  ┌─────────────────────▼─────────────────────┐                  │
│  │  Event Router                             │                  │
│  │  deduplicate → sequence → dispatch        │                  │
│  └─────────────────────┬─────────────────────┘                  │
│                        │                                        │
│  ┌─────────────────────▼─────────────────────┐                  │
│  │  Pub/Sub Adapter  (trait object)          │                  │
│  │  NATS | Kafka | Redis Streams | in-proc   │                  │
│  └─────────────────────┬─────────────────────┘                  │
│                        │                                        │
│  ┌─────────────────────▼─────────────────────┐                  │
│  │  Event Ingestion API                      │                  │
│  │  REST /publish | gRPC PublishEvent        │                  │
│  └───────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
```

### Separation of Concerns

| Concern | Owner | Rationale |
|---|---|---|
| Connection lifecycle (accept, keepalive, close) | Connection Manager | Isolated so transport can be swapped (WS → QUIC) |
| Authentication | Auth Middleware | Pluggable; no auth logic in core engine |
| Subscription state | Subscription Registry | Single writer, many readers; read path must be lock-free |
| Filter matching | Filter Evaluator | CPU-intensive; isolated for profiling/optimization |
| Event routing | Event Router | Pure function: event + subscriptions → dispatch list |
| Message transport | Pub/Sub Adapter | Decoupled from engine; swappable at startup |
| Fan-out writes | Fan-out Workers | CPU/IO bound; isolated to prevent blocking routing |

### Data Flow (happy path)

```
Producer
  → POST /v1/publish  (EventEnvelope)
    → validate + stamp event_id, timestamp
    → idempotency key check (Redis bloom filter, TTL 24h)
    → publish to Pub/Sub bus on topic channel
      → Event Router subscribes to all topic channels
        → lookup topic in Subscription Registry → [conn_id list]
        → send (conn_id, event) to Filter Evaluator
          → evaluate per-conn predicates → matched_conn_ids
            → for each gateway node: send batch(gateway_node_id, matched_conn_ids, event)
              → Fan-out workers: for each conn_id in batch
                → acquire per-conn send queue (tokio mpsc)
                → try_send(event)
                  → success: event written to TCP send buffer
                  → full: apply overflow policy (drop/disconnect)
```

---

## 3. The Realtime Model

### 3.1 Event Structure

Every event flowing through the system is wrapped in an `EventEnvelope`. The envelope is stable and versioned; the payload is opaque bytes (producer-defined schema).

```rust
/// Canonical event representation — stable across all transport layers.
/// Serialized as MessagePack on the wire; JSON available for debugging.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope {
    /// Globally unique, producer-assigned. Format: UUIDv7 (time-sortable).
    /// Used for idempotency deduplication and client-side dedup.
    pub event_id: EventId,

    /// Logical topic this event is published to.
    /// Format: "namespace/resource" e.g. "orders/created", "users/profile-updated"
    /// Supports wildcard matching: "orders/*", "*/created"
    pub topic: TopicPath,

    /// RFC 3339 timestamp, set by the ingestion API (not the producer).
    /// Producers may include their own timestamp in the payload.
    pub timestamp: DateTime<Utc>,

    /// Logical sequence number within the topic partition.
    /// Set by the event router; monotonically increasing per topic.
    pub sequence: u64,

    /// Short semantic label for the event type, e.g. "insert", "update", "delete",
    /// or any domain event: "order.created", "payment.failed".
    pub event_type: String,

    /// Opaque bytes. Producers define their own schema.
    /// Typically JSON or MessagePack. Max 64KB enforced at ingestion.
    pub payload: Bytes,

    /// Content-type of payload bytes: "application/json", "application/msgpack".
    pub payload_encoding: PayloadEncoding,

    /// Optional: source that produced this event.
    /// Useful for tracing and filtering by producer.
    pub source: Option<EventSource>,

    /// Optional: correlation ID for distributed tracing (e.g. trace ID from parent request).
    pub trace_id: Option<TraceId>,

    /// Optional: expiry for ephemeral events. Router discards after TTL.
    pub ttl_ms: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventSource {
    pub kind: SourceKind,   // Api | Database | Scheduler | Webhook
    pub id: String,          // e.g. database name, scheduler job id
    pub metadata: HashMap<String, String>,
}
```

**Design decisions:**

- **UUIDv7 event IDs**: Time-sortable, globally unique, generated by the producer. Enables idempotency and time-range queries without a central counter.
- **Payload as opaque bytes**: The engine never parses the payload for routing decisions. Routing is based only on `topic` and filter predicates applied to the envelope's top-level fields. This keeps the engine schema-agnostic.
- **Server-stamped timestamps**: The ingestion API overwrites the timestamp with server time to ensure monotonicity within a topic. Producer time can live in the payload.
- **Sequence number per topic**: Assigned by the event router using an atomic counter per topic. Clients use this for gap detection and ordering.

### 3.2 Subscription Model

```rust
/// A subscription binds a connection to a topic with an optional filter.
#[derive(Debug, Clone)]
pub struct Subscription {
    pub sub_id: SubscriptionId,       // client-assigned, scoped to connection
    pub conn_id: ConnectionId,
    pub topic: TopicPattern,          // exact, prefix, or glob pattern
    pub filter: Option<FilterExpr>,   // optional predicate on envelope fields
    pub config: SubscriptionConfig,
}

/// Topic pattern matching rules
pub enum TopicPattern {
    Exact(TopicPath),           // "orders/created"
    Prefix(String),             // "orders/" — matches all under orders
    Glob(GlobPattern),          // "orders/*" or "*/created" or "**"
}

/// Filter expression — evaluated against EventEnvelope fields only (not payload).
/// Payload-level filtering is the producer's responsibility; keeping filters
/// envelope-level is what allows O(1) predicate evaluation at scale.
pub enum FilterExpr {
    Eq(FieldPath, Value),               // event_type == "insert"
    Ne(FieldPath, Value),
    In(FieldPath, Vec<Value>),          // source.id in ["db1", "db2"]
    And(Box<FilterExpr>, Box<FilterExpr>),
    Or(Box<FilterExpr>, Box<FilterExpr>),
    Not(Box<FilterExpr>),
}

#[derive(Debug, Clone)]
pub struct SubscriptionConfig {
    /// What to do when this connection's send queue is full.
    pub overflow: OverflowPolicy,
    /// Maximum events per second delivered to this subscription.
    pub rate_limit: Option<u32>,
    /// Last event sequence the client received (for resumption).
    pub resume_from: Option<u64>,
}

pub enum OverflowPolicy {
    DropOldest,    // discard oldest undelivered events
    DropNewest,    // discard incoming events (producer-friendly)
    Disconnect,    // close the connection (strict mode)
}
```

**Topic namespace design:**

Topics follow a hierarchical namespace: `{namespace}/{event-type}`. Examples:

- `orders/created` — specific event type
- `orders/*` — all order events
- `users/profile-updated`
- `*/deleted` — all deletion events across all namespaces (use sparingly)

Namespaces are permission boundaries. An API key can be scoped to read from specific namespaces. Producers publish to full topic paths; clients subscribe with patterns.

### 3.3 Delivery Guarantees

| Guarantee | Default | Notes |
|---|---|---|
| **At-most-once** | No | Unacceptable for BaaS; data loss not acceptable by default |
| **At-least-once** | **Yes** | Events may be delivered twice; clients deduplicate by `event_id` |
| **Exactly-once** | Optional | Expensive; requires client ack + server-side state; offered as premium config |

**At-least-once implementation:**

1. Producer sends event → ingestion API publishes to pub/sub bus
2. Bus provides at-least-once delivery to the event router (NATS JetStream / Kafka / Redis Streams all support this)
3. Event router tracks last-acked offset per topic partition; re-delivers on crash
4. Gateway fan-out uses a per-connection in-memory queue; events may be re-sent on reconnect if the client sends `resume_from: last_seq`
5. Client SDK deduplicates by `event_id` using a sliding window cache (last 1000 event IDs, ~30KB)

**Ordering strategy:**

- **Within a topic partition**: Total ordering guaranteed. The event router assigns monotonically increasing sequence numbers and dispatches in order.
- **Across partitions**: No global ordering guarantee. Clients that need cross-topic ordering must use `timestamp` or producer-assigned sequence numbers embedded in the payload.
- **Per-connection delivery**: Ordered. A connection's send queue is FIFO; events from the same topic arrive in sequence order.

### 3.4 Backpressure Handling

```
TCP recv window full (OS level)
  ↓
tokio: write_all() yields
  ↓
per-conn write task blocks on TCP send buffer
  ↓
per-conn mpsc channel fills (bounded capacity, e.g. 256 events)
  ↓
fan-out worker: try_send() → Err(Full)
  ↓
apply OverflowPolicy:
  DropOldest: pop front of queue, push new event
  DropNewest: discard new event, emit metric overflow.dropped
  Disconnect: close WebSocket, emit metric overflow.disconnected
```

**Critical invariant**: Backpressure terminates at the per-connection mpsc channel. The fan-out worker continues processing other connections. The event router is never blocked by a slow client.

---

## 4. Rust-Centric Design

### 4.1 Crate Stack

```toml
[dependencies]
# Async runtime
tokio = { version = "1", features = ["full"] }
tokio-util = "0.7"

# HTTP and WebSocket gateway
axum = "0.7"
axum-extra = "0.9"
tokio-tungstenite = "0.21"
hyper = { version = "1", features = ["full"] }

# gRPC (for internal node communication and producer API)
tonic = "0.11"
prost = "0.12"

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rmp-serde = "1"          # MessagePack — primary wire format
bytes = "1"              # zero-copy byte buffers

# Pub/Sub adapters
async-nats = "0.34"      # NATS JetStream (recommended default)
rdkafka = "0.36"         # Kafka (librdkafka binding)
redis = { version = "0.25", features = ["tokio-comp", "streams"] }

# Concurrent data structures
dashmap = "5"            # lock-free concurrent HashMap
roaring = "0.10"         # Roaring bitmap — filter evaluation
arc-swap = "1"           # lock-free atomic pointer swap

# Observability
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["json"] }
opentelemetry = "0.22"
metrics = "0.22"
metrics-exporter-prometheus = "0.13"

# Utilities
uuid = { version = "1", features = ["v7"] }
chrono = { version = "0.4", features = ["serde"] }
ahash = "0.8"            # faster HashMap hasher
smol_str = "0.2"         # small string optimization for topic paths
```

### 4.2 Concurrency Model

The system uses **structured concurrency with tokio**, organized into three categories of tasks:

**Connection tasks (one per connected client):**
```rust
// Spawned on client connect; lives for the duration of the connection.
// Owns the WebSocket split: a reader half and a writer half.
pub async fn handle_connection(
    ws: WebSocketStream<TcpStream>,
    conn_id: ConnectionId,
    registry: Arc<SubscriptionRegistry>,
    send_rx: mpsc::Receiver<EventEnvelope>,  // bounded, capacity = 256
) {
    let (ws_write, ws_read) = ws.split();

    // Writer task: drains send_rx, serializes, writes to WS
    let write_task = tokio::spawn(writer_loop(ws_write, send_rx));

    // Reader task: processes subscribe/unsubscribe/ping messages from client
    let read_task = tokio::spawn(reader_loop(ws_read, conn_id, registry));

    // Both tasks complete when the connection closes (either end)
    tokio::select! {
        _ = write_task => {},
        _ = read_task => {},
    }
    // Cleanup: remove all subscriptions for conn_id
    registry.remove_connection(conn_id).await;
}
```

**Fan-out workers (pool per gateway node):**
```rust
// Fan-out workers receive batched dispatch instructions from the event router.
// They look up the per-connection sender, then try_send.
// Worker count = num_cpus * 2; work is CPU-light but requires many lookups.
pub async fn fan_out_worker(
    mut dispatch_rx: mpsc::Receiver<DispatchBatch>,
    conn_senders: Arc<DashMap<ConnectionId, mpsc::Sender<EventEnvelope>>>,
    metrics: Arc<Metrics>,
) {
    while let Some(batch) = dispatch_rx.recv().await {
        for (conn_id, event) in batch.targets {
            if let Some(sender) = conn_senders.get(&conn_id) {
                match sender.try_send(event.clone()) {
                    Ok(()) => metrics.events_delivered.increment(1),
                    Err(TrySendError::Full(_)) => {
                        metrics.send_queue_full.increment(1);
                        // Apply overflow policy (see OverflowPolicy)
                    }
                    Err(TrySendError::Closed(_)) => {
                        // Connection already closed; remove sender
                        conn_senders.remove(&conn_id);
                    }
                }
            }
        }
    }
}
```

**Event router task (singleton per core node):**
```rust
// Runs as a single long-lived task on each core node.
// Subscribes to the pub/sub bus; routes events to gateway nodes.
pub async fn event_router_loop(
    mut bus_rx: impl EventBusSubscriber,
    registry: Arc<SubscriptionRegistry>,
    gateway_clients: Arc<DashMap<NodeId, GatewayClient>>,
) {
    while let Some(event) = bus_rx.next().await {
        // 1. Look up matching connections for this topic
        let matched = registry.lookup_and_filter(&event).await;

        // 2. Group by gateway node
        let by_node = group_by_gateway_node(matched);

        // 3. Dispatch to each gateway node concurrently
        let dispatches = by_node.into_iter().map(|(node_id, conn_ids)| {
            let client = gateway_clients.get(&node_id).cloned();
            let event = event.clone();
            async move {
                if let Some(client) = client {
                    client.dispatch(DispatchBatch { conn_ids, event }).await;
                }
            }
        });
        futures::future::join_all(dispatches).await;

        bus_rx.ack(&event.event_id).await;
    }
}
```

### 4.3 Memory Model and Zero-Copy Strategy

**`Bytes` for payload propagation:**
The `bytes::Bytes` type is a reference-counted slice. Once the ingestion API parses the HTTP body into `Bytes`, the payload is never copied again — it is cloned as a `Bytes` reference (shallow, 16-byte copy) as the `EventEnvelope` fans out to thousands of connections. Each connection serializes directly from the shared `Bytes` buffer into the TCP send buffer.

```rust
// EventEnvelope.payload is Bytes — cheap to clone, zero-copy reads.
// When fan-out sends to 10,000 connections, we clone the Bytes handle
// 10,000 times (10,000 × 16 bytes = 160KB overhead), not the payload itself.
let event = EventEnvelope {
    payload: Bytes::from(body),  // one allocation, many readers
    ..
};
// Downstream clones are reference increments, not memcpy
let event_for_conn = event.clone();  // shallow clone of Bytes
```

**`Arc<EventEnvelope>` for fan-out:**
Wrap the full envelope in `Arc` before fan-out. Each connection receives an `Arc` clone (8-byte pointer increment). The envelope is freed when the last connection's send queue drains it.

**`SmolStr` for topic paths:**
Topic paths like `"orders/created"` are typically under 23 characters and can be stored on the stack using `smol_str::SmolStr`, avoiding heap allocation for the common case.

**Connection map (`DashMap`):**
`DashMap<ConnectionId, ConnectionState>` provides lock-free concurrent reads across shards. With 1M connections, 256 shards = ~4000 connections per shard, each shard backed by a `RwLock<HashMap>`. Read operations (fan-out lookups) never contend with each other; writes (connect/disconnect) are localized to one shard.

### 4.4 Filter Evaluation with Roaring Bitmaps

The filter evaluator builds an inverted index at subscription time:

```rust
// At subscribe time:
// conn_id 42 subscribes to orders/* with filter: event_type == "insert"
//
// We add conn_id 42 to the roaring bitmap stored at:
//   predicate_index["orders/*"]["event_type"]["insert"]
//
// At event routing time for event {topic: "orders/created", event_type: "insert"}:
//   1. Get all bitmaps for topic match "orders/*"
//   2. Intersect with bitmap for event_type="insert"
//   3. Result is the set of matching conn_ids as a compressed integer set

pub struct FilterIndex {
    // topic_pattern → field_name → field_value → bitmap of conn_ids
    index: DashMap<TopicPattern, DashMap<String, DashMap<String, RoaringBitmap>>>,
}

impl FilterIndex {
    pub fn add_subscription(&self, sub: &Subscription) {
        // Index the subscription's filter predicates
        if let Some(filter) = &sub.filter {
            self.index_filter(sub.topic.clone(), sub.conn_id, filter);
        }
    }

    pub fn evaluate(&self, event: &EventEnvelope) -> RoaringBitmap {
        let topic_matches = self.matching_patterns(&event.topic);
        let mut result = RoaringBitmap::new();

        for pattern in topic_matches {
            if let Some(field_index) = self.index.get(&pattern) {
                // Intersect bitmaps for each event field value
                let candidates = self.get_all_matching(&field_index, event);
                result |= candidates;
            }
        }
        result
    }
}
```

This reduces filter evaluation from O(N subscriptions) to O(matching bitmaps intersection), typically O(log N) with roaring bitmap internals.

---

## 5. Scalability Strategy

### 5.1 Connection Capacity Planning

A single gateway node on a `c6i.4xlarge` (16 vCPU, 32GB RAM) can sustain approximately:

| Resource | Per connection | 100K connections | 1M connections (10 nodes) |
|---|---|---|---|
| Memory | ~8KB (WS buffers + state) | ~800MB | ~8GB across 10 nodes |
| File descriptors | 1 | 100K (ulimit tuning required) | 100K per node |
| Tokio tasks | 2 (read + write) | 200K tasks | 200K per node |
| CPU (idle connections) | ~0.01ms/s | ~10% | ~10% per node |
| CPU (active fan-out) | ~0.1ms/event | Depends on event rate | Primary bottleneck |

**Key scaling insight**: Connection memory is not the bottleneck. Fan-out CPU is. At 1000 events/second broadcast to 100K subscribers, a single node must execute 100M send-queue operations per second. This is solved by batching and worker pools, not by vertical scaling.

### 5.2 Gateway Tier Scaling

Gateway nodes are **fully stateless** except for the per-connection send queue (ephemeral; lost on disconnect). This means:

- Any L4 load balancer can distribute new connections (HAProxy, AWS NLB, Cloudflare)
- Use **consistent hashing with virtual nodes** for connection affinity: a reconnecting client is routed to the same gateway node where possible, avoiding subscription re-establishment overhead
- New gateway nodes can join without coordination — they register with the core engine and begin accepting connections
- Gateway nodes expose a gRPC service for the core engine to dispatch events to

```
Client reconnect flow:
  1. DNS/LB routes client to gateway-node-3 (consistent hash of client_id)
  2. Gateway-node-3 accepts WebSocket
  3. Client sends SUBSCRIBE messages (from local state or server-sent subscription snapshot)
  4. Gateway-node-3 registers subscriptions with core engine
  → Fully resumed in < 200ms
```

### 5.3 Core Engine Scaling (Raft-Coordinated)

The core engine nodes hold the subscription registry — this is stateful and must be consistent. Design:

- **3 or 5 core nodes** (Raft quorum — odd number)
- Subscription registry is replicated via Raft using `openraft` crate
- Reads are served from local state (eventual consistency acceptable for subscription lookups)
- Writes (subscribe/unsubscribe) go through the Raft leader and are linearizable
- Core nodes do NOT handle connections — they only route events and manage subscription state

**Read path optimization**: On each core node, maintain a local read replica of the subscription registry. Event routing reads from local replica without going through Raft. Subscription state is slightly stale (milliseconds) but this is acceptable — a new subscriber missing the first event is acceptable; an event routing to a stale list and finding one fewer subscriber is harmless.

### 5.4 Pub/Sub Backbone Comparison

| Backend | Throughput | Latency | Durability | Operational cost | Recommendation |
|---|---|---|---|---|---|
| **NATS JetStream** | 40M+ msgs/s | < 1ms | Configurable | Low (single binary) | **Default choice** |
| **Kafka** | 10M+ msgs/s | 5–20ms | Strong | High (ZK or KRaft) | High durability use cases |
| **Redis Streams** | 1M+ msgs/s | < 2ms | AOF/RDB | Medium | Small-to-medium scale |
| **In-process** | 100M+ msgs/s | < 0.01ms | None | Zero | Single-node dev/test only |

**Recommendation: NATS JetStream as default.** It is a single Go binary with no dependencies, supports at-least-once delivery with consumer groups, and achieves < 1ms median latency. The `async-nats` crate provides an idiomatic async Rust client.

### 5.5 Fan-Out Optimization: Hierarchical Dispatch

For topics with millions of subscribers, naive per-connection dispatch is O(N) in the event router. Optimize with hierarchical fan-out:

```
Event router → dispatches to gateway nodes in parallel
  Each gateway node → dispatches to local connections in parallel

This moves the O(N) fan-out from the event router to the gateway nodes,
allowing it to be distributed across the cluster.
```

For extremely high fan-out (e.g. a global broadcast to 5M connections):

1. Event router broadcasts to all gateway nodes (N gateway nodes = O(N) messages, typically 10–50)
2. Each gateway node receives the broadcast and fans out to its local connections (~500K connections per node if 10 nodes)
3. Each gateway node uses a worker pool to parallelize local fan-out

This reduces the event router's work from O(5M) to O(10), shifting the bottleneck to the gateway tier where it can be parallelized.

### 5.6 Load Balancing Strategy

```
Client → Anycast VIP
  → L4 Load Balancer (NLB / HAProxy)
    → Gateway nodes (consistent hashing by client_id)

Producer → REST API Gateway
  → L7 Load Balancer (Nginx / Envoy)
    → Any gateway node (stateless; published to shared bus)

Gateway nodes → Core nodes
  → Internal gRPC (direct addressing, no LB needed — client-side round-robin)
```

---

## 6. Modularity and Plugin System

### 6.1 Core Trait Definitions

The system is designed around a small set of traits that define extension points. Concrete implementations are injected at startup via a `Config`-driven factory.

```rust
/// Pub/Sub adapter: the event bus abstraction.
/// Implement this trait to add a new message broker backend.
#[async_trait]
pub trait EventBus: Send + Sync + 'static {
    type Subscriber: EventBusSubscriber;
    type Publisher: EventBusPublisher;

    async fn publisher(&self) -> Result<Self::Publisher>;
    async fn subscriber(&self, topic_pattern: &str) -> Result<Self::Subscriber>;
    async fn health_check(&self) -> Result<()>;
}

#[async_trait]
pub trait EventBusPublisher: Send + Sync {
    async fn publish(&self, topic: &str, event: &EventEnvelope) -> Result<PublishReceipt>;
    async fn publish_batch(&self, events: &[(String, EventEnvelope)]) -> Result<Vec<PublishReceipt>>;
}

#[async_trait]
pub trait EventBusSubscriber: Send + Stream<Item = EventEnvelope> + Unpin {
    async fn ack(&self, event_id: &EventId) -> Result<()>;
    async fn nack(&self, event_id: &EventId) -> Result<()>;
    async fn seek(&self, sequence: u64) -> Result<()>;
}

/// Transport adapter: how clients connect.
#[async_trait]
pub trait TransportServer: Send + Sync + 'static {
    type Connection: TransportConnection;

    async fn bind(&self, addr: SocketAddr) -> Result<()>;
    async fn accept(&self) -> Result<(Self::Connection, ConnectionMeta)>;
}

#[async_trait]
pub trait TransportConnection: Send + Sync {
    async fn recv_message(&mut self) -> Result<Option<ClientMessage>>;
    async fn send_message(&mut self, msg: ServerMessage) -> Result<()>;
    async fn close(&mut self, code: CloseCode, reason: &str) -> Result<()>;
    fn peer_addr(&self) -> SocketAddr;
}

/// Auth provider: verify connection credentials.
#[async_trait]
pub trait AuthProvider: Send + Sync + 'static {
    async fn verify(&self, token: &str, context: &AuthContext) -> Result<AuthClaims>;
    async fn authorize_subscribe(&self, claims: &AuthClaims, topic: &TopicPattern) -> Result<()>;
    async fn authorize_publish(&self, claims: &AuthClaims, topic: &TopicPath) -> Result<()>;
}
```

### 6.2 Configuration-Driven Assembly

```rust
pub struct EngineConfig {
    pub event_bus: EventBusConfig,
    pub transport: TransportConfig,
    pub auth: AuthConfig,
    pub subscription: SubscriptionConfig,
    pub performance: PerformanceConfig,
}

pub enum EventBusConfig {
    Nats(NatsConfig),
    Kafka(KafkaConfig),
    Redis(RedisConfig),
    InProcess,
}

pub enum TransportConfig {
    WebSocket(WebSocketConfig),
    Quic(QuicConfig),        // future
    ServerSentEvents(SseConfig),
}

pub enum AuthConfig {
    Jwt(JwtConfig),
    ApiKey(ApiKeyConfig),
    NoAuth,                   // development only
    Custom(Arc<dyn AuthProvider>),
}

// Engine assembly
pub async fn build_engine(config: EngineConfig) -> Result<RealtimeEngine> {
    let bus: Arc<dyn EventBus> = match config.event_bus {
        EventBusConfig::Nats(c) => Arc::new(NatsEventBus::connect(c).await?),
        EventBusConfig::Kafka(c) => Arc::new(KafkaEventBus::new(c).await?),
        EventBusConfig::Redis(c) => Arc::new(RedisEventBus::new(c).await?),
        EventBusConfig::InProcess => Arc::new(InProcessBus::new()),
    };

    let auth: Arc<dyn AuthProvider> = match config.auth {
        AuthConfig::Jwt(c) => Arc::new(JwtAuthProvider::new(c)),
        AuthConfig::Custom(p) => p,
        ..
    };

    RealtimeEngine::new(bus, auth, config.subscription, config.performance)
}
```

### 6.3 Adding a New Event Bus Adapter

1. Create a new crate: `realtime-bus-sqs` (or feature-flag in the main crate)
2. Implement `EventBus`, `EventBusPublisher`, `EventBusSubscriber` traits
3. Add `SqsConfig` variant to `EventBusConfig`
4. Wire in the factory match arm

No changes to core engine, gateway, or subscription logic. The trait boundary is the only coupling point.

### 6.4 Adding a New Transport (e.g., QUIC)

1. Implement `TransportServer` and `TransportConnection` for QUIC using `quinn` crate
2. The connection handler is transport-agnostic — it works with any `TransportConnection`
3. Add `QuicConfig` to `TransportConfig` and wire in factory

---

## 7. Failure Handling and Resilience

### 7.1 Gateway Node Failure

```
Timeline:
  t=0   Gateway node-2 crashes (OOM, kernel panic, network partition)
  t=0   L4 LB health check fails → stops routing new connections to node-2
  t=30s LB marks node-2 down (3 consecutive health check failures × 10s interval)
  t=30s Core engine detects no heartbeat from node-2 → marks all node-2 conn_ids stale
  t=30s Core engine purges node-2 subscriptions from registry
  t=30s Clients on node-2 receive TCP RST or timeout → begin reconnect

Client reconnect:
  t=31s Client connects to node-3 (consistent hash, or round-robin if node-2 was target)
  t=31s Client sends RESUME(last_seq=8421)
  t=31s Gateway registers subscriptions with core engine
  t=31s Core engine re-delivers events seq 8422..current from pub/sub bus consumer offset
  t=32s Client fully resumed
```

**The thundering herd**: 50,000 clients reconnecting simultaneously to a new node. Mitigations:

1. **Client-side jitter**: SDK reconnect delay = `min(base * 2^attempt, max_delay) + random(0, jitter_ms)` where `jitter_ms = 500ms`. This spreads the reconnect burst over ~30 seconds.
2. **Server-side rate limiting**: Each gateway node accepts a maximum of N new connections per second (configurable; default: 5000/s). Excess connections receive `503 Retry-After: 5`.
3. **Subscription batching**: Client sends all subscriptions in a single `SUBSCRIBE_BATCH` message rather than N individual `SUBSCRIBE` messages, reducing core engine write load.

### 7.2 Core Engine Node Failure (Raft)

With 3 core nodes, one can fail and the system remains available (Raft majority = 2 of 3). With 5 nodes, two can fail.

```
Raft leader fails:
  → Remaining nodes detect missing heartbeat (150–300ms election timeout)
  → New leader elected
  → Event routing resumes
  → Total outage: < 500ms
```

During this window, the pub/sub bus continues to accumulate events. Once the new leader is elected, the event router resumes processing from the last committed offset. No events are lost (guaranteed by pub/sub at-least-once delivery).

### 7.3 Pub/Sub Bus Failure

NATS JetStream in cluster mode (3 nodes) tolerates one node failure. If the entire NATS cluster is unavailable:

1. Event router enters "bus unavailable" state
2. Ingestion API returns `503 Service Unavailable` to producers
3. Gateway continues serving existing connections (no new events delivered)
4. When bus recovers, event router reconnects and resumes from last acked offset

**Circuit breaker on the ingestion path:**
```rust
// tokio-retry + circuit breaker pattern
let policy = ExponentialBackoff::default()
    .max_retries(3)
    .initial_delay(Duration::from_millis(100));

let circuit = CircuitBreaker::new()
    .failure_threshold(5)
    .success_threshold(2)
    .timeout(Duration::from_secs(30));

circuit.call(|| bus.publish(topic, &event)).await
```

### 7.4 Network Partition (Split-Brain)

The Raft-based core engine cannot split-brain — the minority partition cannot elect a leader and becomes unavailable for writes. The majority partition continues operating. This is the correct trade-off: prefer consistency over availability for subscription state.

Gateway nodes in the minority partition continue serving existing connections but cannot register new subscriptions. New connections to these nodes receive a `503` after the core engine unavailability is detected.

### 7.5 Slow Consumer Management

```rust
pub async fn writer_loop(
    mut ws_write: WsSink,
    mut recv: mpsc::Receiver<EventEnvelope>,
    slow_threshold: Duration,
) {
    let mut consecutive_slow = 0u32;

    while let Some(event) = recv.recv().await {
        let start = Instant::now();

        // Attempt to write with a timeout
        match timeout(Duration::from_millis(500), ws_write.send(serialize(&event))).await {
            Ok(Ok(())) => {
                if start.elapsed() > slow_threshold {
                    consecutive_slow += 1;
                    if consecutive_slow > 10 {
                        // Client is consistently slow — disconnect
                        ws_write.close().await.ok();
                        return;
                    }
                } else {
                    consecutive_slow = 0;
                }
            }
            Ok(Err(_)) | Err(_) => {
                // Write error or timeout — close connection
                return;
            }
        }
    }
}
```

---

## 8. Performance Optimization

### 8.1 Bottleneck Analysis

| Bottleneck | Severity | Mitigation |
|---|---|---|
| Fan-out CPU at high subscriber count | Critical | Hierarchical fan-out; worker pools |
| Filter evaluation at scale | High | Roaring bitmap inverted index |
| Serialization overhead per event copy | High | `Arc<EventEnvelope>` + zero-copy `Bytes` |
| Per-connection send queue lock contention | Medium | `DashMap` sharding; lock-free channels |
| Topic index lookup (subscribe/unsubscribe) | Low | `DashMap` + `SmolStr` keys |
| TLS handshake CPU (on connect) | Low | Session resumption (TLS 1.3 0-RTT) |

### 8.2 Serialization Strategy

**Wire format decision: MessagePack as primary, JSON as secondary.**

MessagePack is 30–50% smaller than JSON for typical event envelopes and 3–5× faster to serialize/deserialize. JSON is available for debugging and client implementations that cannot use MessagePack.

```rust
// Client negotiates encoding in the WebSocket handshake header
// Sec-WebSocket-Protocol: realtime.msgpack (or realtime.json)

// Server side: select encoder at connection time, not per-event
pub enum FrameEncoder {
    MsgPack,
    Json,
}

impl FrameEncoder {
    pub fn encode(&self, event: &EventEnvelope) -> Result<Bytes> {
        match self {
            FrameEncoder::MsgPack => rmp_serde::to_vec_named(event).map(Bytes::from),
            FrameEncoder::Json => serde_json::to_vec(event).map(Bytes::from),
        }
    }
}
```

For the payload field (already `Bytes`): if the payload is JSON and the client requests JSON framing, the payload can be embedded raw without re-serialization. If the client requests MessagePack and the payload is JSON, it must be transcoded — document this as a known overhead.

### 8.3 Connection Lifecycle Optimization

**TCP tuning:**
```toml
# sysctl settings for the gateway nodes
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
```

**WebSocket keepalive:**
Send a `PING` frame every 30 seconds. If no `PONG` received within 10 seconds, close the connection. This detects zombie connections (client gone, TCP connection not closed) before they accumulate.

**Socket send buffer tuning:**
```rust
// Set TCP send buffer to 64KB per connection.
// Default is often 87KB on Linux but can be lowered to reduce memory pressure.
let std_stream = TcpStream::from_std(std_stream)?;
std_stream.set_send_buffer_size(65536)?;
std_stream.set_recv_buffer_size(16384)?; // reads are small (subscribe/unsubscribe)
```

### 8.4 Batch Dispatch Optimization

Instead of dispatching each event individually to gateway nodes, the event router batches events per gateway node:

```rust
// Batch dispatch: collect events for up to 1ms or 100 events, whichever comes first
// Then send one gRPC call per gateway node with the full batch.
// This reduces gRPC round-trips from O(events × nodes) to O(batches × nodes).

pub async fn batching_dispatcher(
    mut event_rx: mpsc::Receiver<RoutedEvent>,
    gateway_clients: Arc<DashMap<NodeId, GatewayClient>>,
) {
    let mut batch: HashMap<NodeId, Vec<RoutedEvent>> = HashMap::new();
    let mut batch_timer = tokio::time::interval(Duration::from_millis(1));

    loop {
        tokio::select! {
            Some(event) = event_rx.recv() => {
                for (node_id, conn_ids) in &event.targets_by_node {
                    batch.entry(*node_id).or_default().push(RoutedEvent {
                        conn_ids: conn_ids.clone(),
                        event: event.event.clone(),
                    });
                }
                if batch.values().map(|v| v.len()).sum::<usize>() >= 100 {
                    flush_batch(&mut batch, &gateway_clients).await;
                }
            }
            _ = batch_timer.tick() => {
                if !batch.is_empty() {
                    flush_batch(&mut batch, &gateway_clients).await;
                }
            }
        }
    }
}
```

### 8.5 Memory Pressure Management

With 1M connections × 8KB = 8GB RAM for connection state, memory pressure is real. Mitigations:

1. **Lazy subscription registration**: Don't allocate subscription state until the client sends the first `SUBSCRIBE` message (many clients connect but subscribe slowly).
2. **Compact connection IDs**: Use `u64` connection IDs (8 bytes) rather than UUIDs (16–36 bytes) internally. UUIDs only at the API boundary.
3. **Shared event buffers**: Use `Arc<EventEnvelope>` in fan-out — the envelope is allocated once, shared across all send queues.
4. **Send queue capacity**: Default 256 events × average 1KB = 256KB per connection × 1M = 256GB if all queues are full. This never happens in practice, but bound it with a global semaphore limiting total in-flight memory.

---

## 9. API Design and Developer Experience

### 9.1 Client Protocol (WebSocket)

All client messages are JSON (or MessagePack) framed WebSocket messages.

**Connect and authenticate:**
```json
// Client → Server (immediately after WebSocket upgrade)
{
  "type": "AUTH",
  "token": "Bearer eyJhbGci..."
}

// Server → Client (success)
{
  "type": "AUTH_OK",
  "conn_id": "01HX4K...",
  "server_time": "2024-01-15T10:30:00Z"
}

// Server → Client (failure)
{
  "type": "ERROR",
  "code": "AUTH_FAILED",
  "message": "Token expired"
}
```

**Subscribe:**
```json
// Client → Server
{
  "type": "SUBSCRIBE",
  "sub_id": "sub-orders",
  "topic": "orders/*",
  "filter": {
    "event_type": { "in": ["created", "updated"] }
  },
  "options": {
    "overflow": "drop_oldest",
    "resume_from": 8421
  }
}

// Server → Client (ack)
{
  "type": "SUBSCRIBED",
  "sub_id": "sub-orders",
  "seq": 8422
}
```

**Receive event:**
```json
// Server → Client
{
  "type": "EVENT",
  "sub_id": "sub-orders",
  "event": {
    "event_id": "01HX4K9Y...",
    "topic": "orders/created",
    "event_type": "created",
    "sequence": 8422,
    "timestamp": "2024-01-15T10:30:01.234Z",
    "payload": { "order_id": "ord_123", "total": 99.99 }
  }
}
```

**Unsubscribe:**
```json
// Client → Server
{ "type": "UNSUBSCRIBE", "sub_id": "sub-orders" }

// Server → Client
{ "type": "UNSUBSCRIBED", "sub_id": "sub-orders" }
```

**Heartbeat:**
```json
// Client → Server (every 30s)
{ "type": "PING" }

// Server → Client
{ "type": "PONG", "server_time": "2024-01-15T10:30:31Z" }
```

### 9.2 Producer API (REST)

```
POST /v1/publish
Authorization: Bearer <api_key>
Content-Type: application/json

{
  "topic": "orders/created",
  "event_type": "created",
  "payload": { "order_id": "ord_123", "total": 99.99 },
  "idempotency_key": "prod-456-ord-123"
}

→ 200 OK
{
  "event_id": "01HX4K9Y...",
  "sequence": 8422,
  "delivered_to_bus": true
}
```

```
POST /v1/publish/batch
Authorization: Bearer <api_key>
Content-Type: application/json

{
  "events": [
    { "topic": "orders/created", "event_type": "created", "payload": {...} },
    { "topic": "users/updated",  "event_type": "updated", "payload": {...} }
  ]
}

→ 200 OK
{
  "results": [
    { "event_id": "01HX4K9Y...", "sequence": 8422, "status": "ok" },
    { "event_id": "01HX4K9Z...", "sequence": 1021, "status": "ok" }
  ]
}
```

### 9.3 Client SDK Design (Rust)

```rust
// Public SDK API — simple, minimal, ergonomic
let client = RealtimeClient::builder()
    .url("wss://realtime.example.com")
    .token("Bearer eyJhbGci...")
    .build()
    .await?;

// Subscribe to a topic with a filter
let mut subscription = client
    .subscribe("orders/*")
    .filter(Filter::new().eq("event_type", "created"))
    .overflow(OverflowPolicy::DropOldest)
    .resume_from(last_sequence)   // optional: resume from last known position
    .await?;

// Consume events as an async stream
while let Some(event) = subscription.next().await {
    println!("Received: {:?}", event);
}

// Unsubscribe
subscription.unsubscribe().await?;

// Publish (for server-side SDKs)
let producer = client.producer();
producer.publish("orders/created")
    .payload(json!({ "order_id": "ord_123" }))
    .idempotency_key("unique-key")
    .send()
    .await?;
```

The SDK handles:
- Automatic reconnection with exponential backoff + jitter
- Subscription re-establishment on reconnect
- Event deduplication by `event_id` (sliding window, last 1000 events)
- Gap detection using `sequence` numbers (emits a `GapDetected` event if a sequence jump is detected)
- Heartbeat management

### 9.4 JavaScript Client SDK

```typescript
const client = createRealtimeClient({
  url: 'wss://realtime.example.com',
  token: 'Bearer eyJhbGci...',
});

// Subscribe
const sub = client.subscribe('orders/*', {
  filter: { event_type: { in: ['created', 'updated'] } },
  overflow: 'drop_oldest',
});

sub.on('event', (event) => {
  console.log('Order event:', event.payload);
});

sub.on('error', (err) => console.error(err));
sub.on('reconnected', () => console.log('Reconnected'));

// Unsubscribe
sub.unsubscribe();

// Publish (server-side / Node.js only)
await client.publish('orders/created', {
  payload: { order_id: 'ord_123', total: 99.99 },
});
```

---

## 10. Step-by-Step Implementation Plan

### Phase 1: MVP (Weeks 1–6)

**Goal**: Single-node realtime engine with WebSocket transport and in-process event bus. Validate the core model.

**Week 1–2: Core data structures and traits**
- Define all core types: `EventEnvelope`, `Subscription`, `TopicPattern`, `FilterExpr`
- Define all core traits: `EventBus`, `TransportServer`, `TransportConnection`, `AuthProvider`
- Implement `InProcessBus` (tokio broadcast channel) — no external dependencies
- Write unit tests for all types
- Deliverable: `realtime-core` crate with types and traits

**Week 3: WebSocket gateway**
- Implement `tokio-tungstenite` transport adapter
- Implement connection manager: accept loop, per-connection read/write tasks
- Implement simple `NoAuth` provider (development mode)
- Implement `DashMap`-based connection registry
- Deliverable: Clients can connect, subscribe, and receive events published via in-process bus

**Week 4: Subscription registry and filter evaluation**
- Implement `SubscriptionRegistry` with `DashMap` and topic pattern matching (exact + prefix)
- Implement `FilterEvaluator` (linear scan — optimize later)
- Implement subscribe/unsubscribe protocol messages
- Deliverable: Clients can subscribe with filters; events are routed to matching connections

**Week 5: Producer API and end-to-end flow**
- Implement `POST /v1/publish` using axum
- Implement `JwtAuthProvider` (RS256 JWT verification)
- Wire everything together: publish → in-process bus → event router → fan-out → WebSocket
- Deliverable: Full end-to-end event flow; load test with `wrk` and 1000 connections

**Week 6: Observability and hardening**
- Add `tracing` instrumentation throughout
- Add `metrics` (Prometheus): connections, events/s, queue depth, latency histograms
- Add graceful shutdown (drain connections, flush queues)
- Add configuration system (TOML-based)
- Deliverable: Production-observable single-node engine

### Phase 2: Horizontally Scalable (Weeks 7–14)

**Goal**: Multi-node cluster with external pub/sub bus and distributed subscription registry.

**Week 7–8: NATS JetStream adapter**
- Implement `NatsEventBus` using `async-nats`
- Implement at-least-once delivery with consumer groups
- Implement resume-from-offset on reconnect
- Write integration tests with a NATS test container
- Deliverable: Events route through NATS; bus failure handled gracefully

**Week 9–10: Distributed subscription registry**
- Integrate `openraft` for Raft consensus on core engine nodes
- Replicate subscription state across 3 core nodes
- Implement local read replica for event routing (eventual consistency)
- Implement leader-only write path for subscribe/unsubscribe
- Deliverable: Subscription state survives core node failure

**Week 11: Gateway ↔ Core engine communication**
- Define internal gRPC protocol using `tonic` + `prost`
- Implement `DispatchService` on gateway nodes
- Implement `SubscriptionService` on core engine nodes
- Gateway registers subscriptions with core; core dispatches events to gateway
- Deliverable: Gateway and core engine are separate processes communicating via gRPC

**Week 12: Roaring bitmap filter evaluator**
- Replace linear scan filter evaluator with inverted index + roaring bitmaps
- Benchmark: linear O(N) vs. bitmap O(log N) at 100K, 1M, 10M subscriptions
- Deliverable: Filter evaluation scales to millions of subscriptions

**Week 13: Hierarchical fan-out**
- Implement batching dispatcher in event router
- Implement per-gateway-node fan-out workers
- Load test: 10 gateway nodes × 100K connections = 1M connections; broadcast 1000 events/s
- Deliverable: Fan-out scales horizontally

**Week 14: Reconnection and resilience testing**
- Implement client reconnect simulation in load test harness
- Kill gateway nodes during load test; verify reconnection and subscription recovery
- Kill core engine leader; verify election and resume within 500ms
- Implement thundering herd protection (rate-limited accept + jitter)
- Deliverable: System is resilient to single node failures

### Phase 3: Production-Grade (Weeks 15–24)

**Goal**: Production hardening, multi-backend support, client SDKs, and operational tooling.

**Week 15–16: Kafka and Redis adapters**
- Implement `KafkaEventBus` using `rdkafka`
- Implement `RedisEventBus` using `redis` streams
- Write integration tests for both
- Deliverable: Three interchangeable pub/sub backends

**Week 17–18: Client SDKs**
- Implement Rust client SDK with full reconnect/dedup/gap-detection
- Implement TypeScript/JavaScript SDK
- Implement Python SDK (asyncio-based)
- Write SDK integration test suite
- Deliverable: Production-ready client SDKs

**Week 19: Security hardening**
- Implement scope-based authorization (namespace-level permissions)
- Implement TLS with certificate rotation
- Implement rate limiting on ingestion API (per API key)
- Implement connection rate limiting per IP
- Security audit of authentication flow
- Deliverable: Security-hardened system ready for external exposure

**Week 20–21: Performance benchmarking and tuning**
- Establish benchmarks: connections, throughput (events/s), latency (p50/p99/p999)
- Profile CPU and memory under realistic load (mixed subscribe/publish/fan-out)
- Tune per the findings: buffer sizes, worker pool sizes, batch intervals
- Target: 1M connections, 10K events/s broadcast, p99 latency < 50ms
- Deliverable: Benchmark suite + tuning documentation

**Week 22: Admin API and operational tooling**
- Implement admin gRPC API: list connections, list subscriptions, force-disconnect, inspect queue depth
- Implement graceful rolling restart protocol
- Implement node health endpoint for L4 load balancer
- Deliverable: Operational tooling for production management

**Week 23–24: Documentation and launch readiness**
- Write architecture decision records (ADRs) for all major design choices
- Write runbook: common failure scenarios and remediation steps
- Write capacity planning guide
- Write deployment guide: Kubernetes manifests, Helm chart, Terraform module
- Load test with realistic production workload profile
- Deliverable: Production-ready system with full documentation

---

## Appendix A: Key Architectural Decisions

| Decision | Choice | Alternative considered | Rationale |
|---|---|---|---|
| Async runtime | tokio | async-std, smol | Ecosystem maturity; axum/tonic require tokio |
| Internal communication | gRPC (tonic) | Custom TCP protocol | Type safety, bidirectional streaming, ecosystem |
| Subscription consistency | Raft (openraft) | CRDTs, Gossip | Subscription state requires linearizable writes |
| Default pub/sub | NATS JetStream | Kafka | Operational simplicity; < 1ms latency; single binary |
| Wire format | MessagePack primary | JSON primary | 30-50% smaller; 3-5× faster; JSON available as fallback |
| Filter indexing | Roaring bitmaps | Hash maps, B-trees | Compressed; set operations O(n/64); well-studied |
| Connection IDs | u64 internal | UUID everywhere | Memory efficiency in high-cardinality maps |
| Event IDs | UUIDv7 | UUIDv4, ULID | Time-sortable; globally unique; producer-assigned |
| Fan-out backpressure | Bounded mpsc per conn | Unbounded channels | Prevents memory exhaustion from slow consumers |
| Payload handling | Opaque `Bytes` | Parsed schema | Engine remains schema-agnostic; zero-copy fan-out |

---

## Appendix B: Metrics Reference

| Metric | Type | Labels | Description |
|---|---|---|---|
| `rt_connections_active` | Gauge | node_id | Current active connections |
| `rt_connections_total` | Counter | node_id, transport | Total connections accepted |
| `rt_events_ingested_total` | Counter | topic, source | Events accepted by ingestion API |
| `rt_events_routed_total` | Counter | topic | Events dispatched by event router |
| `rt_events_delivered_total` | Counter | node_id | Events written to connection send queues |
| `rt_events_dropped_total` | Counter | node_id, reason | Events dropped (overflow, disconnect) |
| `rt_delivery_latency_ms` | Histogram | node_id | End-to-end: ingest → first send attempt |
| `rt_send_queue_depth` | Histogram | node_id | Per-connection send queue depth at sample time |
| `rt_subscriptions_active` | Gauge | topic_ns | Active subscriptions per namespace |
| `rt_filter_eval_duration_us` | Histogram | — | Time to evaluate filters for one event |
| `rt_bus_publish_duration_ms` | Histogram | bus_type | Time to publish to external pub/sub bus |
| `rt_reconnects_total` | Counter | node_id | Client reconnection events |

---

*End of architecture specification.*