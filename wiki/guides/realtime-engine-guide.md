# Realtime Engine — Integration Guide

> **mini-BaaS Realtime** is a high-performance WebSocket event engine written in
> Rust. It provides real-time pub/sub, database change-data-capture (CDC) for
> both PostgreSQL and MongoDB, server-side filtering, and a REST API for
> publishing events.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How It Runs in mini-BaaS](#how-it-runs-in-mini-baas)
3. [Endpoints](#endpoints)
4. [WebSocket Protocol](#websocket-protocol)
5. [Authentication](#authentication)
6. [Subscribing to Events](#subscribing-to-events)
7. [Publishing Events](#publishing-events)
8. [Server-Side Filters](#server-side-filters)
9. [Database CDC (Change Data Capture)](#database-cdc-change-data-capture)
10. [Frontend Integration (JavaScript)](#frontend-integration-javascript)
11. [Backend Integration (Node.js / NestJS)](#backend-integration-nodejs--nestjs)
12. [REST API Reference](#rest-api-reference)
13. [Configuration Reference](#configuration-reference)
14. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────┐  WS   ┌─────────────────────────────────────────────────┐
│  Browser /  │───────►│            Realtime Engine (Rust)               │
│  Mobile App │◄───────│                                                 │
└─────────────┘        │  ┌──────────┐  ┌─────────┐  ┌──────────────┐  │
                       │  │ Gateway  │  │ Engine  │  │  Event Bus   │  │
┌─────────────┐  REST  │  │ (axum)   │  │ (router │  │ (broadcast)  │  │
│  Backend    │───────►│  │          │  │  +index)│  │              │  │
│  Service    │◄───────│  └──────────┘  └─────────┘  └──────┬───────┘  │
└─────────────┘        │                                     │          │
                       │  ┌──────────────────────────────────┘          │
                       │  │                                             │
                       │  ▼               ▼                             │
                       │  ┌──────────┐  ┌──────────┐                   │
                       │  │ PG CDC   │  │Mongo CDC │                   │
                       │  │(LISTEN/  │  │(Change   │                   │
                       │  │ NOTIFY)  │  │ Streams) │                   │
                       │  └────┬─────┘  └────┬─────┘                   │
                       └───────┼──────────────┼────────────────────────┘
                               ▼              ▼
                          PostgreSQL       MongoDB
```

**Crates** (all compiled into one binary):

| Crate                    | Purpose                                           |
| ------------------------ | ------------------------------------------------- |
| `realtime-core`          | Shared types, traits, protocol definitions        |
| `realtime-engine`        | Subscription registry, event router, filter index |
| `realtime-gateway`       | WebSocket handler, REST API, connection manager   |
| `realtime-bus-inprocess` | In-process event bus (broadcast channels)         |
| `realtime-auth`          | JWT and no-auth providers                         |
| `realtime-db-postgres`   | PostgreSQL CDC via LISTEN/NOTIFY                  |
| `realtime-db-mongodb`    | MongoDB CDC via Change Streams                    |
| `realtime-server`        | Binary entrypoint, wires everything together      |
| `realtime-client`        | Rust client SDK (for backend services)            |

---

## How It Runs in mini-BaaS

The realtime engine runs as the `realtime` service in `docker-compose.yml`:

```yaml
realtime:
  image: dlesieur/realtime-agnostic:latest
  environment:
    REALTIME_HOST: 0.0.0.0
    REALTIME_PORT: 4000
    REALTIME_JWT_SECRET: ${JWT_SECRET}
    REALTIME_PG_URL: postgres://postgres:postgres@postgres:5432/postgres
    REALTIME_PG_CHANNEL: realtime_events
    REALTIME_MONGO_URI: mongodb://mongo:mongo@mongo:27017
    REALTIME_MONGO_DB: syncspace
    RUST_LOG: info
```

**Internal port**: `4000` (no host port mapping — accessed through Kong)

**Kong routes**:

- `http://localhost:8000/realtime/v1/*` → REST API (health, publish)
- `ws://localhost:8000/realtime/ws` → WebSocket endpoint

---

## Endpoints

| Method | Path                | Description                                     |
| ------ | ------------------- | ----------------------------------------------- |
| `GET`  | `/v1/health`        | Health check with connection/subscription stats |
| `POST` | `/v1/publish`       | Publish a single event                          |
| `POST` | `/v1/publish/batch` | Publish up to 1000 events in one request        |
| `GET`  | `/ws`               | WebSocket upgrade endpoint                      |

Through **Kong** (add your API key / JWT):

- `GET http://localhost:8000/realtime/v1/health`
- `POST http://localhost:8000/realtime/v1/publish`
- `WS ws://localhost:8000/realtime/ws`

---

## WebSocket Protocol

All messages are JSON with a `"type"` discriminator field.

### Message Flow

```
Client                              Server
  │── AUTH { token }  ────────────► │
  │◄── AUTH_OK { conn_id }  ─────── │
  │── SUBSCRIBE { sub_id, topic } ► │
  │◄── SUBSCRIBED { sub_id, seq } ─ │
  │                                  │  (events flow as they occur)
  │◄── EVENT { sub_id, event }  ──── │
  │◄── EVENT { sub_id, event }  ──── │
  │── PUBLISH { topic, payload } ─► │  (broadcast to all subscribers)
  │── UNSUBSCRIBE { sub_id }  ────► │
  │◄── UNSUBSCRIBED { sub_id }  ─── │
  │── PING  ──────────────────────► │
  │◄── PONG  ──────────────────────  │
```

### Client → Server Messages

#### AUTH (must be first message)

```json
{
  "type": "AUTH",
  "token": "<jwt-token>"
}
```

#### SUBSCRIBE

```json
{
  "type": "SUBSCRIBE",
  "sub_id": "my-sub-1",
  "topic": "orders/*",
  "filter": { "event_type": { "eq": "created" } },
  "options": {
    "overflow": "drop_oldest",
    "resume_from": 42,
    "rate_limit": 100
  }
}
```

- `sub_id` — Client-chosen ID, scoped to this connection
- `topic` — Topic pattern (see [Topic Patterns](#topic-patterns))
- `filter` — Optional server-side filter (see [Filters](#server-side-filters))
- `options` — Optional: `overflow` (`drop_oldest` | `drop_newest` | `disconnect`), `resume_from` (sequence), `rate_limit` (events/sec)

#### SUBSCRIBE_BATCH

```json
{
  "type": "SUBSCRIBE_BATCH",
  "subscriptions": [
    { "sub_id": "pg-changes", "topic": "pg/**" },
    { "sub_id": "mongo-changes", "topic": "mongo/**" },
    { "sub_id": "chat", "topic": "channel:general:chat/*" }
  ]
}
```

#### PUBLISH (over WebSocket)

```json
{
  "type": "PUBLISH",
  "topic": "chat/general",
  "event_type": "message.sent",
  "payload": {
    "userId": "user-123",
    "text": "Hello world!"
  }
}
```

#### UNSUBSCRIBE

```json
{
  "type": "UNSUBSCRIBE",
  "sub_id": "my-sub-1"
}
```

#### PING

```json
{ "type": "PING" }
```

### Server → Client Messages

#### AUTH_OK

```json
{
  "type": "AUTH_OK",
  "conn_id": "42",
  "server_time": "2026-04-11T15:30:00.000Z"
}
```

#### SUBSCRIBED

```json
{
  "type": "SUBSCRIBED",
  "sub_id": "my-sub-1",
  "seq": 0
}
```

#### EVENT

```json
{
  "type": "EVENT",
  "sub_id": "pg-changes",
  "event": {
    "event_id": "01965abc-1234-7def-8901-234567890abc",
    "topic": "pg/public/orders",
    "event_type": "INSERT",
    "sequence": 7,
    "timestamp": "2026-04-11T15:30:01.123Z",
    "payload": {
      "id": 42,
      "customer": "alice",
      "total": 99.99
    }
  }
}
```

#### ERROR

```json
{
  "type": "ERROR",
  "code": "AUTH_FAILED",
  "message": "Invalid or expired token"
}
```

Error codes: `AUTH_FAILED`, `CAPACITY_EXCEEDED`, `PAYLOAD_TOO_LARGE`

---

## Authentication

The realtime server supports two auth modes:

### JWT Mode (production — default in mini-BaaS)

When `REALTIME_JWT_SECRET` is set, the server validates HMAC-SHA256 JWTs.

1. Client opens WebSocket to `/ws`
2. Client sends `AUTH` message with a valid JWT token
3. Server verifies the signature, checks `exp` claim
4. Server responds with `AUTH_OK` or `ERROR { code: "AUTH_FAILED" }`

The JWT is the same one issued by GoTrue (`/auth/v1/token`).

**Getting a token for the realtime server**:

```bash
# 1. Sign up / sign in via GoTrue
TOKEN=$(curl -s http://localhost:8000/auth/v1/signup \
  -H "Content-Type: application/json" \
  -H "apikey: <ANON_KEY>" \
  -d '{"email":"user@example.com","password":"secret123"}' \
  | jq -r '.access_token')

# 2. Use the token for WebSocket AUTH
```

### No-Auth Mode (development only)

When `REALTIME_JWT_SECRET` is **not** set, the server accepts any token string.
Useful for local development and testing.

---

## Subscribing to Events

### Topic Patterns

Topics are hierarchical paths separated by `/`:

| Pattern          | Type                  | Matches                                |
| ---------------- | --------------------- | -------------------------------------- |
| `orders/created` | Exact                 | Only `orders/created`                  |
| `orders/*`       | Prefix (single level) | `orders/created`, `orders/updated`     |
| `orders/**`      | Prefix (recursive)    | `orders/created`, `orders/us/west/new` |
| `pg/**`          | Prefix (recursive)    | All PostgreSQL CDC events              |
| `mongo/**`       | Prefix (recursive)    | All MongoDB CDC events                 |

### Common Subscription Patterns

```javascript
// PostgreSQL table changes (all tables)
{ sub_id: "pg-all", topic: "pg/**" }

// PostgreSQL specific table
{ sub_id: "pg-orders", topic: "pg/public/orders/*" }

// MongoDB collection changes (all collections)
{ sub_id: "mongo-all", topic: "mongo/**" }

// MongoDB specific collection
{ sub_id: "mongo-users", topic: "mongo/syncspace/users/*" }

// Custom application events
{ sub_id: "chat-general", topic: "chat/general/*" }
{ sub_id: "presence", topic: "presence/*" }
```

---

## Publishing Events

### Via WebSocket (low latency — ephemeral events)

Best for cursor positions, typing indicators, presence updates:

```javascript
ws.send(
  JSON.stringify({
    type: "PUBLISH",
    topic: "cursors/board-1",
    event_type: "cursor.move",
    payload: { x: 150, y: 320, userId: "user-123" },
  }),
);
```

### Via REST API (reliable — from backend services)

Best for business events, notifications, data mutations:

```bash
# Single event
curl -X POST http://localhost:8000/realtime/v1/publish \
  -H "Content-Type: application/json" \
  -H "apikey: <API_KEY>" \
  -H "Authorization: Bearer <JWT>" \
  -d '{
    "topic": "notifications/user-123",
    "event_type": "order.shipped",
    "payload": { "orderId": 42, "trackingUrl": "https://..." }
  }'

# Response:
# { "event_id": "01965abc-...", "sequence": 1, "delivered_to_bus": true }
```

```bash
# Batch (up to 1000 events)
curl -X POST http://localhost:8000/realtime/v1/publish/batch \
  -H "Content-Type: application/json" \
  -H "apikey: <API_KEY>" \
  -H "Authorization: Bearer <JWT>" \
  -d '{
    "events": [
      { "topic": "alerts/sys", "event_type": "cpu.high", "payload": { "pct": 95 } },
      { "topic": "alerts/sys", "event_type": "mem.high", "payload": { "pct": 88 } }
    ]
  }'
```

---

## Server-Side Filters

Filters are evaluated on the server so only matching events are delivered,
saving bandwidth and client CPU.

### Supported Operators

| Operator | Syntax                            | Description            |
| -------- | --------------------------------- | ---------------------- |
| `eq`     | `{ "field": { "eq": value } }`    | Field equals value     |
| `ne`     | `{ "field": { "ne": value } }`    | Field not equal        |
| `in`     | `{ "field": { "in": [v1, v2] } }` | Field is one of values |

Multiple conditions are implicitly **ANDed**.

### Filter Examples

```javascript
// Only INSERT events
ws.send(
  JSON.stringify({
    type: "SUBSCRIBE",
    sub_id: "pg-inserts",
    topic: "pg/**",
    filter: { event_type: { eq: "INSERT" } },
  }),
);

// Only events for a specific user
ws.send(
  JSON.stringify({
    type: "SUBSCRIBE",
    sub_id: "my-orders",
    topic: "pg/public/orders/*",
    filter: { "payload.customer_id": { eq: "user-123" } },
  }),
);

// Events matching multiple event types
ws.send(
  JSON.stringify({
    type: "SUBSCRIBE",
    sub_id: "mutations",
    topic: "pg/**",
    filter: { event_type: { in: ["INSERT", "UPDATE"] } },
  }),
);
```

### Filterable Fields

| Field         | Type   | Description                                    |
| ------------- | ------ | ---------------------------------------------- |
| `event_type`  | string | Event type (e.g. `INSERT`, `UPDATE`, `DELETE`) |
| `topic`       | string | Full topic path                                |
| `source.kind` | string | Source kind (`cdc`, `api`, `websocket`)        |
| `payload.*`   | any    | Any field inside the JSON payload              |

---

## Database CDC (Change Data Capture)

### PostgreSQL CDC

The engine uses `LISTEN/NOTIFY` to capture changes. When a row is
inserted, updated, or deleted in a watched table, a JSON notification
is sent over the `realtime_events` channel.

**Topic format**: `pg/<schema>/<table>/<event_type>`

**Example events**:

```
pg/public/orders/INSERT
pg/public/orders/UPDATE
pg/public/users/DELETE
```

**Setup**: The PostgreSQL CDC producer automatically creates the
`realtime_notify()` trigger function. For each table you want to watch,
create a trigger:

```sql
-- Enable CDC for the 'orders' table
CREATE OR REPLACE TRIGGER orders_realtime_trigger
  AFTER INSERT OR UPDATE OR DELETE ON orders
  FOR EACH ROW
  EXECUTE FUNCTION realtime_notify();
```

**Event payload** (delivered to subscribers):

```json
{
  "event_id": "01965abc-...",
  "topic": "pg/public/orders",
  "event_type": "INSERT",
  "sequence": 12,
  "timestamp": "2026-04-11T15:30:00Z",
  "payload": {
    "schema": "public",
    "table": "orders",
    "old": null,
    "new": { "id": 42, "customer": "alice", "total": 99.99 }
  }
}
```

### MongoDB CDC

The engine uses MongoDB **Change Streams** (requires replica set) to
capture insert/update/replace/delete operations.

**Topic format**: `mongo/<database>/<collection>/<operation>`

**Example events**:

```
mongo/syncspace/chat_messages/insert
mongo/syncspace/users/update
mongo/syncspace/orders/delete
```

**Event payload**:

```json
{
  "event_id": "01965def-...",
  "topic": "mongo/syncspace/chat_messages",
  "event_type": "insert",
  "sequence": 5,
  "timestamp": "2026-04-11T15:31:00Z",
  "payload": {
    "operationType": "insert",
    "ns": { "db": "syncspace", "coll": "chat_messages" },
    "fullDocument": {
      "_id": "663...",
      "channelId": "ch-general",
      "userId": "user-bob",
      "content": "Hello from Mongo!",
      "createdAt": "2026-04-11T15:31:00Z"
    }
  }
}
```

**No setup needed** — MongoDB Change Streams watch all collections
automatically. The MongoDB instance must be a replica set (the
mini-BaaS `mongo` service is pre-configured as `rs0`).

---

## Frontend Integration (JavaScript)

### Minimal WebSocket Client

```javascript
class RealtimeClient {
  constructor(url, token) {
    this.url = url;
    this.token = token;
    this.ws = null;
    this.authenticated = false;
    this.handlers = new Map(); // sub_id → callback
    this.pendingSubs = [];
    this.reconnectDelay = 1000;
  }

  connect() {
    this.ws = new WebSocket(this.url);

    this.ws.onopen = () => {
      this.ws.send(JSON.stringify({ type: "AUTH", token: this.token }));
    };

    this.ws.onmessage = (evt) => {
      const msg = JSON.parse(evt.data);
      this._handleMessage(msg);
    };

    this.ws.onclose = () => {
      this.authenticated = false;
      // Auto-reconnect with exponential backoff
      setTimeout(() => this.connect(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
    };

    this.ws.onerror = () => this.ws.close();
  }

  subscribe(subId, topic, callback, filter = null) {
    this.handlers.set(subId, callback);
    const msg = { type: "SUBSCRIBE", sub_id: subId, topic };
    if (filter) msg.filter = filter;

    if (this.authenticated) {
      this.ws.send(JSON.stringify(msg));
    } else {
      this.pendingSubs.push(msg);
    }
  }

  unsubscribe(subId) {
    this.handlers.delete(subId);
    if (this.authenticated) {
      this.ws.send(JSON.stringify({ type: "UNSUBSCRIBE", sub_id: subId }));
    }
  }

  publish(topic, eventType, payload) {
    if (this.authenticated) {
      this.ws.send(
        JSON.stringify({
          type: "PUBLISH",
          topic,
          event_type: eventType,
          payload,
        }),
      );
    }
  }

  _handleMessage(msg) {
    switch (msg.type) {
      case "AUTH_OK":
        this.authenticated = true;
        this.reconnectDelay = 1000;
        // Replay pending subscriptions
        for (const sub of this.pendingSubs) {
          this.ws.send(JSON.stringify(sub));
        }
        this.pendingSubs = [];
        break;

      case "EVENT":
        const handler = this.handlers.get(msg.sub_id);
        if (handler) handler(msg.event);
        break;

      case "ERROR":
        console.error(`[Realtime] ${msg.code}: ${msg.message}`);
        break;
    }
  }
}
```

### Usage: React / Vanilla JS

```javascript
// 1. Create client (through Kong gateway)
const rt = new RealtimeClient("ws://localhost:8000/realtime/ws", "<jwt-token>");
rt.connect();

// 2. Subscribe to PostgreSQL changes on the "orders" table
rt.subscribe("orders", "pg/public/orders/*", (event) => {
  console.log("Order changed:", event.event_type, event.payload);
  // event.event_type = "INSERT" | "UPDATE" | "DELETE"
  // event.payload = { old: {...}, new: {...} }
});

// 3. Subscribe to MongoDB changes with a filter
rt.subscribe(
  "chat-msgs",
  "mongo/**",
  (event) => {
    console.log("New chat:", event.payload.fullDocument);
  },
  { event_type: { eq: "insert" } },
);

// 4. Subscribe to real-time presence
rt.subscribe("presence", "presence/*", (event) => {
  updatePresenceUI(event.payload);
});

// 5. Publish a cursor position (ephemeral, low-latency)
document.addEventListener("mousemove", (e) => {
  rt.publish("cursors/board-1", "cursor.move", {
    x: e.clientX,
    y: e.clientY,
    userId: "me",
  });
});

// 6. Unsubscribe when done
rt.unsubscribe("orders");
```

### Usage: React Hook

```typescript
import { useEffect, useRef, useCallback } from 'react';

function useRealtime(url: string, token: string) {
  const clientRef = useRef<RealtimeClient | null>(null);

  useEffect(() => {
    const client = new RealtimeClient(url, token);
    client.connect();
    clientRef.current = client;
    return () => client.ws?.close();
  }, [url, token]);

  const subscribe = useCallback((
    subId: string,
    topic: string,
    callback: (event: any) => void,
    filter?: object
  ) => {
    clientRef.current?.subscribe(subId, topic, callback, filter);
    return () => clientRef.current?.unsubscribe(subId);
  }, []);

  const publish = useCallback((topic: string, eventType: string, payload: any) => {
    clientRef.current?.publish(topic, eventType, payload);
  }, []);

  return { subscribe, publish };
}

// Usage in a component:
function OrderList() {
  const [orders, setOrders] = useState([]);
  const { subscribe } = useRealtime(
    'ws://localhost:8000/realtime/ws',
    authToken
  );

  useEffect(() => {
    return subscribe('orders', 'pg/public/orders/*', (event) => {
      if (event.event_type === 'INSERT') {
        setOrders(prev => [...prev, event.payload.new]);
      }
    });
  }, [subscribe]);

  return <ul>{orders.map(o => <li key={o.id}>{o.customer}</li>)}</ul>;
}
```

---

## Backend Integration (Node.js / NestJS)

### Publishing Events from NestJS Services

```typescript
// src/realtime/realtime.service.ts
import { Injectable, HttpService } from "@nestjs/common";

@Injectable()
export class RealtimeService {
  private readonly baseUrl = "http://realtime:4000";

  constructor(private readonly http: HttpService) {}

  /** Publish a single event to the realtime bus. */
  async publish(topic: string, eventType: string, payload: any): Promise<void> {
    await this.http.axiosRef.post(`${this.baseUrl}/v1/publish`, {
      topic,
      event_type: eventType,
      payload,
    });
  }

  /** Publish multiple events in one request (up to 1000). */
  async publishBatch(
    events: Array<{
      topic: string;
      event_type: string;
      payload: any;
    }>,
  ): Promise<void> {
    await this.http.axiosRef.post(`${this.baseUrl}/v1/publish/batch`, {
      events,
    });
  }

  /** Check realtime engine health. */
  async health(): Promise<{
    status: string;
    connections: number;
    subscriptions: number;
  }> {
    const { data } = await this.http.axiosRef.get(`${this.baseUrl}/v1/health`);
    return data;
  }
}
```

### WebSocket Client from Node.js

```typescript
// src/realtime/realtime-ws.client.ts
import WebSocket from "ws";

export class RealtimeWsClient {
  private ws: WebSocket | null = null;
  private authenticated = false;
  private handlers = new Map<string, (event: any) => void>();

  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);

      this.ws.on("open", () => {
        this.ws!.send(JSON.stringify({ type: "AUTH", token: this.token }));
      });

      this.ws.on("message", (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.type === "AUTH_OK") {
          this.authenticated = true;
          resolve();
        } else if (msg.type === "EVENT") {
          this.handlers.get(msg.sub_id)?.(msg.event);
        } else if (msg.type === "ERROR") {
          console.error(`Realtime error: ${msg.code} — ${msg.message}`);
          if (msg.code === "AUTH_FAILED") reject(new Error(msg.message));
        }
      });

      this.ws.on("error", reject);
    });
  }

  subscribe(subId: string, topic: string, handler: (event: any) => void) {
    this.handlers.set(subId, handler);
    this.ws?.send(
      JSON.stringify({
        type: "SUBSCRIBE",
        sub_id: subId,
        topic,
      }),
    );
  }

  publish(topic: string, eventType: string, payload: any) {
    this.ws?.send(
      JSON.stringify({
        type: "PUBLISH",
        topic,
        event_type: eventType,
        payload,
      }),
    );
  }

  close() {
    this.ws?.close();
  }
}

// Usage:
const client = new RealtimeWsClient("ws://realtime:4000/ws", jwtToken);
await client.connect();

client.subscribe("pg-orders", "pg/public/orders/**", (event) => {
  console.log("Order event:", event.event_type, event.payload);
});
```

### NestJS Gateway (WebSocket Bridge)

```typescript
// src/realtime/realtime.gateway.ts
import {
  WebSocketGateway,
  OnGatewayInit,
  OnGatewayConnection,
} from "@nestjs/websockets";
import { RealtimeWsClient } from "./realtime-ws.client";

@WebSocketGateway({ path: "/ws/relay" })
export class RealtimeGateway implements OnGatewayInit, OnGatewayConnection {
  private rtClient: RealtimeWsClient;

  async afterInit() {
    // Connect to the Rust realtime engine as a backend subscriber
    this.rtClient = new RealtimeWsClient(
      "ws://realtime:4000/ws",
      process.env.SERVICE_JWT_TOKEN!,
    );
    await this.rtClient.connect();

    // Subscribe to all events and relay to NestJS WebSocket clients
    this.rtClient.subscribe("all", "**", (event) => {
      // Broadcast to connected NestJS WS clients
      this.server.emit("realtime-event", event);
    });
  }
}
```

---

## REST API Reference

### `GET /v1/health`

Returns server health and telemetry.

**Response** `200`:

```json
{
  "status": "ok",
  "connections": 12,
  "subscriptions": 48,
  "uptime_seconds": 3600,
  "filter_index": {
    "slots_active": 48,
    "evaluations_total": 15230,
    "matches_total": 8920,
    "last_eval_us": 12,
    "peak_eval_us": 45,
    "circuit_trips": 0
  }
}
```

`status` is `"ok"` normally, `"degraded"` if the circuit breaker has tripped.

### `POST /v1/publish`

Publish a single event.

**Request**:

```json
{
  "topic": "orders/created",
  "event_type": "order.created",
  "payload": { "orderId": 42 },
  "idempotency_key": "abc-123",
  "ttl_ms": 60000
}
```

**Response** `200`:

```json
{
  "event_id": "01965abc-1234-7def-8901-234567890abc",
  "sequence": 7,
  "delivered_to_bus": true
}
```

### `POST /v1/publish/batch`

Publish up to 1000 events atomically.

**Request**:

```json
{
  "events": [
    { "topic": "t1", "event_type": "e1", "payload": {} },
    { "topic": "t2", "event_type": "e2", "payload": {} }
  ]
}
```

**Response** `200`:

```json
{
  "results": [
    { "event_id": "...", "sequence": 1, "delivered_to_bus": true },
    { "event_id": "...", "sequence": 1, "delivered_to_bus": true }
  ]
}
```

---

## Configuration Reference

### Environment Variables

| Variable                | Default           | Description                           |
| ----------------------- | ----------------- | ------------------------------------- |
| `REALTIME_HOST`         | `0.0.0.0`         | Bind address                          |
| `REALTIME_PORT`         | `9090`            | Bind port (set to `4000` in compose)  |
| `REALTIME_STATIC_DIR`   | `/app/static`     | Static file serving directory         |
| `REALTIME_CONFIG`       | —                 | Path to TOML/JSON config file         |
| `REALTIME_JWT_SECRET`   | —                 | HMAC-SHA256 secret (enables JWT auth) |
| `REALTIME_JWT_ISSUER`   | —                 | Expected JWT issuer claim             |
| `REALTIME_JWT_AUDIENCE` | —                 | Expected JWT audience claim           |
| `REALTIME_PG_URL`       | —                 | PostgreSQL connection string          |
| `REALTIME_PG_CHANNEL`   | `realtime_events` | LISTEN channel name                   |
| `REALTIME_PG_PREFIX`    | `pg`              | Topic prefix for PG events            |
| `REALTIME_MONGO_URI`    | —                 | MongoDB connection URI                |
| `REALTIME_MONGO_DB`     | `syncspace`       | MongoDB database name                 |
| `REALTIME_MONGO_PREFIX` | `mongo`           | Topic prefix for Mongo events         |
| `RUST_LOG`              | `info`            | Log level filter                      |

### TOML Configuration File

```toml
host       = "0.0.0.0"
port       = 4000
static_dir = "/app/static"

[auth]
type = "jwt"
secret = "your-32-char-secret-here"
# issuer = "mini-baas"
# audience = "mini-baas"

[event_bus]
type = "InProcess"
capacity = 65536

[performance]
send_queue_capacity = 256
fanout_workers = 4
dispatch_channel_capacity = 65536

[engine.limits]
max_patterns = 100000
max_total_subscriptions = 500000
max_subscriptions_per_connection = 1000
```

---

## Troubleshooting

### Container is healthy but no CDC events

**Check**: Is `REALTIME_MONGO_URI` set (not `REALTIME_MONGO_URL`)?

```bash
docker exec mini-baas-realtime env | grep REALTIME_MONGO
# Should show: REALTIME_MONGO_URI=mongodb://...
```

Look for `"MongoDB Change Streams configured from env"` in the logs:

```bash
docker logs mini-baas-realtime 2>&1 | grep -i "configured"
```

### PostgreSQL CDC not firing

1. Ensure the `realtime_events` NOTIFY channel is being listened to:

   ```bash
   docker logs mini-baas-realtime 2>&1 | grep "CDC producer started"
   ```

2. Ensure triggers exist on your tables:
   ```sql
   SELECT tgname, tgrelid::regclass
   FROM pg_trigger
   WHERE tgfoid = 'realtime_notify'::regproc;
   ```

### WebSocket connection refused

- Through Kong: `ws://localhost:8000/realtime/ws`
- Direct (dev only): `ws://localhost:4000/ws` (requires port mapping)

### AUTH_FAILED errors

The JWT secret must match between GoTrue and realtime:

```bash
docker exec mini-baas-realtime env | grep JWT_SECRET
docker exec mini-baas-gotrue env | grep JWT_SECRET
```

### "PostgreSQL connection error: db error" in logs

This is a **transient** error that occurs when PostgreSQL restarts. The
CDC producer automatically reconnects. Check if Postgres is healthy:

```bash
docker exec mini-baas-postgres pg_isready
```
