# Realtime-Agnostic — Operations & Testing Guide

> How to build, run, test, debug, and deploy the entire system.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Quick Start (5 Minutes)](#2-quick-start-5-minutes)
3. [All Makefile Commands](#3-all-makefile-commands)
4. [Building the Project](#4-building-the-project)
5. [Running Tests](#5-running-tests)
6. [Docker Compose Environment](#6-docker-compose-environment)
7. [Running Locally (Without Docker)](#7-running-locally-without-docker)
8. [Configuration Reference](#8-configuration-reference)
9. [Verifying Everything Works](#9-verifying-everything-works)
10. [Debugging Techniques](#10-debugging-techniques)
11. [Database Operations](#11-database-operations)
12. [WebSocket Testing](#12-websocket-testing)
13. [Performance Testing](#13-performance-testing)
14. [Common Issues and Fixes](#14-common-issues-and-fixes)
15. [CI/CD Integration](#15-cicd-integration)

---

## 1. Prerequisites

### Required Software

| Tool | Version | Check Command | Install |
|------|---------|---------------|---------|
| **Rust** | ≥1.75 (1.89 tested) | `rustc --version` | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| **Cargo** | (comes with Rust) | `cargo --version` | (comes with Rust) |
| **Docker** | ≥24.0 | `docker --version` | [docs.docker.com](https://docs.docker.com/get-docker/) |
| **Docker Compose** | ≥2.20 (v2 plugin) | `docker compose version` | (comes with Docker Desktop) |
| **Make** | any | `make --version` | `sudo apt install make` (Linux) or `xcode-select --install` (macOS) |

### Optional (for advanced testing)

| Tool | Purpose | Install |
|------|---------|---------|
| **websocat** | CLI WebSocket client | `cargo install websocat` |
| **python3** | JSON formatting + E2E test script | `sudo apt install python3` |
| **curl** | REST API testing | Usually pre-installed |
| **jq** | JSON parsing | `sudo apt install jq` |
| **psql** | PostgreSQL CLI | `sudo apt install postgresql-client` |
| **mongosh** | MongoDB shell | [mongodb.com/docs/mongodb-shell](https://www.mongodb.com/docs/mongodb-shell/) |

---

## 2. Quick Start (5 Minutes)

```bash
# 1. Clone and enter
cd /home/dlesieur/Documents/realtime-agnostic

# 2. Run all tests (no Docker needed)
make test
# Expected output: "test result: ok. 80 passed; 0 failed; 1 ignored"

# 3. Start the full stack (PostgreSQL + MongoDB + Rust server)
make up
# Wait ~30 seconds for containers to build and start

# 4. Check health
make health
# Expected: {"status":"ok","connections":0,"subscriptions":0,"uptime_seconds":0}

# 5. Open the SyncSpace demo
#    Open two browser tabs to: http://localhost:4002
#    Log in as "alice" in one tab and "bob" in the other
#    Try the Kanban board, chat, whiteboard, etc.

# 6. When done
make down
```

---

## 3. All Makefile Commands

Run `make help` to see all available commands:

```bash
$ make help
build           Build the Rust workspace (release)
check           Check compilation with zero warnings
clean           Stop containers AND remove volumes (fresh start)
dev             Run Rust server locally (expects PG on :5432, Mongo on :27017)
down            Stop all containers
health          Check server health endpoint
logs            Tail all container logs
logs-mongo      Tail MongoDB logs
logs-pg         Tail PostgreSQL logs
logs-server     Tail only the Rust server logs
mongo-shell     Open mongosh to the database
psql            Open psql shell to the database
restart         Restart the server (rebuild)
seed            Re-seed databases (requires running containers)
status          Show running containers
test            Run all tests (78 unit + integration)
test-publish    Publish a test event via REST API
test-ws         Quick WebSocket test (requires websocat)
up              Start databases + server via Docker Compose
```

---

## 4. Building the Project

### Debug Build (fast compile, slower runtime)

```bash
cargo build --workspace
```

### Release Build (slow compile, optimized runtime)

```bash
cargo build --release --workspace
# or
make build
```

The binary is at: `target/release/realtime-server`

### Check Without Building

```bash
cargo check --workspace
# or
make check
```

This runs type checking and borrow checking without code generation — much faster than a full build.

### Build a Single Crate

```bash
cargo build -p realtime-core
cargo build -p realtime-engine
cargo build -p realtime-server
```

---

## 5. Running Tests

### Run ALL Tests

```bash
cargo test --workspace
# or
make test
```

**Expected output:**

```
running 9 tests (realtime-core types)     ... ok
running 5 tests (realtime-core filter)    ... ok
running 6 tests (realtime-engine registry)... ok
running 4 tests (realtime-engine filter)  ... ok
running 4 tests (realtime-engine router)  ... ok
running 3 tests (realtime-engine sequence)... ok
running 2 tests (realtime-engine producer)... ok
running 4 tests (realtime-bus-inprocess)  ... ok
running 5 tests (realtime-auth)           ... ok
running 5 tests (realtime-db-postgres)    ... ok
running 4 tests (realtime-db-mongodb)     ... ok
running 5 tests (realtime-gateway)        ... ok
running 24 tests (integration e2e)        ... ok

test result: ok. 80 passed; 0 failed; 1 ignored; 0 measured
```

### Run Tests for a Single Crate

```bash
# Core types and traits
cargo test -p realtime-core

# Engine (registry, router, filter index, sequence, producer registry)
cargo test -p realtime-engine

# Gateway (connection manager, fan-out, WS handler)
cargo test -p realtime-gateway

# Event bus
cargo test -p realtime-bus-inprocess

# Auth providers
cargo test -p realtime-auth

# PostgreSQL adapter (no PG connection needed — parses mock data)
cargo test -p realtime-db-postgres

# MongoDB adapter (no MongoDB connection needed — parses mock BSON)
cargo test -p realtime-db-mongodb

# Integration tests (spins up in-process server on random port)
cargo test -p integration
```

### Run a Single Test by Name

```bash
# Run one specific test
cargo test -p realtime-core test_topic_pattern_glob

# Run all tests matching a pattern
cargo test -p realtime-engine filter
# Runs: test_unfiltered_bitmap, test_filtered_bitmap, test_in_filter_bitmap, 
#        test_filter_matching, test_remove_subscription

# Run integration tests matching a pattern
cargo test -p integration throughput
# Runs: test_high_throughput_publish
```

### Run Tests with Output (see println! and tracing)

```bash
cargo test --workspace -- --nocapture
```

### Run Tests with Verbose Output

```bash
cargo test --workspace -- --show-output
```

### Run Tests with Tracing Logs

```bash
RUST_LOG=debug cargo test --workspace -- --nocapture
```

### Test Categories Explained

| Category | What It Tests | Docker Needed? |
|----------|-------------|----------------|
| **Unit tests** (56) | Pure logic: type construction, pattern matching, filter evaluation, bitmap operations, sequence generation, connection management | No |
| **Integration tests** (24) | Full stack: spawns an in-process server on a random port, opens real WebSocket connections, sends real messages, verifies real event delivery | No |
| **Docker E2E test** (1 script) | Real PostgreSQL + MongoDB CDC: `sandbox/test_ws_cdc.py` | Yes |

### Running the Python E2E Test (Requires Docker)

```bash
# Start the full stack first
make up

# Wait for all containers to be healthy
make status

# Run the CDC test
python3 sandbox/test_ws_cdc.py
```

This test:
1. Connects two WebSocket clients (Alice and Bob)
2. Subscribes both to `pg/**` and `mongo/**`
3. Inserts a row into PostgreSQL via `docker exec psql`
4. Inserts a document into MongoDB via `docker exec mongosh`
5. Verifies both clients receive the CDC events

---

## 6. Docker Compose Environment

### Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker Compose Network: realtime-agnostic_default   │
│                                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │ postgres    │  │ mongo       │  │ realtime-  │  │
│  │ :5432       │  │ :27017      │  │ server     │  │
│  │ (PG 16)     │  │ (Mongo 7)   │  │ :4000      │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬─────┘  │
│         │                │                │         │
└─────────┼────────────────┼────────────────┼─────────┘
          │                │                │
    Host:5434        Host:27019       Host:4002
```

### Service Details

| Service | Image | Host Port | Internal Port | Volumes |
|---------|-------|-----------|---------------|---------|
| `postgres` | `postgres:16-alpine` | `5434` | `5432` | `pg_data` + init/seed SQL |
| `mongo` | `mongo:7` | `27019` | `27017` | `mongo_data` |
| `mongo-init` | `mongo:7` | — | — | Initiates replica set, then exits |
| `mongo-seed` | `mongo:7` | — | — | Runs seed script, then exits |
| `realtime-server` | Built from `sandbox/Dockerfile` | `4002` | `4000` | `sandbox/static:/app/static:ro` |

### Starting

```bash
# Start all services (detached)
make up

# Start with visible logs
docker compose -f sandbox/docker-compose.yml up --build
```

### Checking Status

```bash
make status
# Output:
# NAME              STATUS        PORTS
# postgres          Up (healthy)  0.0.0.0:5434->5432/tcp
# mongo             Up (healthy)  0.0.0.0:27019->27017/tcp
# realtime-server   Up            0.0.0.0:4002->4000/tcp
```

### Viewing Logs

```bash
# All logs
make logs

# Just the Rust server
make logs-server

# Just PostgreSQL
make logs-pg

# Just MongoDB
make logs-mongo
```

### Stopping

```bash
# Stop containers (keep data)
make down

# Stop AND delete all data (volumes)
make clean
```

### Rebuilding After Code Changes

```bash
# Rebuild only the server
make restart

# Rebuild everything
make clean && make up
```

### Static File Hot Reload

The `sandbox/static/` directory is **bind-mounted read-only** into the container:

```yaml
volumes:
  - ../sandbox/static:/app/static:ro
```

This means changes to `sandbox/static/index.html` are **immediately visible** — just refresh the browser. No rebuild needed for frontend changes.

---

## 7. Running Locally (Without Docker)

For rapid development iteration, run the Rust server directly:

```bash
# Prerequisites: PG on localhost:5432, Mongo on localhost:27017
# (You can start just the databases from Docker)
docker compose -f sandbox/docker-compose.yml up -d postgres mongo mongo-init mongo-seed

# Run the server
make dev
# Equivalent to:
RUST_LOG=info,realtime_gateway=debug,realtime_server=debug \
REALTIME_HOST=0.0.0.0 \
REALTIME_PORT=4000 \
REALTIME_STATIC_DIR=sandbox/static \
cargo run --bin realtime-server
```

**Note**: When running locally, the server will be at `http://localhost:4000` instead of `4002`.

### Run Without Any Database

If you just want to test the engine without databases:

```bash
RUST_LOG=info REALTIME_PORT=4000 cargo run --bin realtime-server
```

The server starts with no CDC producers — you can still publish events via REST or WebSocket PUBLISH.

---

## 8. Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REALTIME_CONFIG` | — | Path to JSON config file (overrides all env vars) |
| `REALTIME_HOST` | `0.0.0.0` | Listen address |
| `REALTIME_PORT` | `9090` | Listen port |
| `REALTIME_STATIC_DIR` | `sandbox/static` | Static file serving directory |
| `REALTIME_JWT_SECRET` | — | JWT HMAC secret (enables JWT auth; if unset, NoAuth) |
| `REALTIME_JWT_ISSUER` | — | Expected JWT issuer claim |
| `REALTIME_JWT_AUDIENCE` | — | Expected JWT audience claim |
| `REALTIME_PG_URL` | — | PostgreSQL connection string (enables PG CDC) |
| `REALTIME_PG_CHANNEL` | `realtime_events` | PostgreSQL LISTEN channel name |
| `REALTIME_PG_PREFIX` | `pg` | Topic prefix for PG events |
| `REALTIME_MONGO_URI` | — | MongoDB connection URI (enables Mongo CDC) |
| `REALTIME_MONGO_DB` | `syncspace` | MongoDB database name |
| `REALTIME_MONGO_PREFIX` | `mongo` | Topic prefix for Mongo events |
| `RUST_LOG` | `info` | Tracing filter (e.g., `debug`, `info,realtime_gateway=trace`) |

### JSON Config File

```json
{
  "host": "0.0.0.0",
  "port": 4000,
  "event_bus": {
    "type": "inprocess",
    "capacity": 65536
  },
  "auth": {
    "type": "jwt",
    "secret": "my-secret-key",
    "issuer": "my-app",
    "audience": "my-api"
  },
  "performance": {
    "send_queue_capacity": 256,
    "fanout_workers": 4,
    "dispatch_channel_capacity": 65536
  },
  "databases": [
    {
      "adapter": "postgresql",
      "config": {
        "connection_string": "postgresql://user:pass@localhost:5432/mydb",
        "channel": "realtime_events",
        "tables": [],
        "topic_prefix": "pg",
        "poll_interval_ms": 100
      }
    },
    {
      "adapter": "mongodb",
      "config": {
        "uri": "mongodb://localhost:27017",
        "database": "mydb",
        "collections": [],
        "topic_prefix": "mongo",
        "full_document": "updateLookup"
      }
    }
  ]
}
```

Usage:

```bash
REALTIME_CONFIG=/path/to/config.json cargo run --bin realtime-server
```

---

## 9. Verifying Everything Works

### Step 1: Health Check

```bash
curl -s http://localhost:4002/v1/health | python3 -m json.tool
```

**Expected:**

```json
{
    "status": "ok",
    "connections": 0,
    "subscriptions": 0,
    "uptime_seconds": 0
}
```

### Step 2: Publish a Test Event

```bash
curl -s -X POST http://localhost:4002/v1/publish \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "test/hello",
    "event_type": "greeting",
    "payload": {"message": "Hello, World!"}
  }' | python3 -m json.tool
```

**Expected:**

```json
{
    "event_id": "01912345-6789-7abc-def0-123456789abc",
    "sequence": 0,
    "delivered_to_bus": true
}
```

### Step 3: WebSocket Test (with websocat)

```bash
# Install websocat if not already
cargo install websocat

# Connect and authenticate
echo '{"type":"AUTH","token":"test-user"}' | timeout 3 websocat ws://localhost:4002/ws
```

**Expected:** You should see an AUTH_OK response:

```json
{"type":"AUTH_OK","conn_id":"conn-1","server_time":"2026-04-06T00:00:00Z"}
```

### Step 4: Full Round-Trip Test

Open **two terminals**:

**Terminal 1 — Subscriber:**

```bash
websocat ws://localhost:4002/ws
```

Type (line by line):

```json
{"type":"AUTH","token":"subscriber"}
{"type":"SUBSCRIBE","sub_id":"s1","topic":"test/*"}
```

**Terminal 2 — Publisher:**

```bash
curl -X POST http://localhost:4002/v1/publish \
  -H "Content-Type: application/json" \
  -d '{"topic":"test/hello","event_type":"greeting","payload":{"msg":"it works!"}}'
```

**Terminal 1** should now show the EVENT message with your payload.

### Step 5: Verify CDC (PostgreSQL)

```bash
# Open psql
make psql

# Insert a card
INSERT INTO cards (id, list_id, title, position, created_by)
VALUES ('test-card-1', 'list-backlog', 'Test Card', 99, 'user-alice');
```

If you have a WebSocket client subscribed to `pg/**`, you'll see:

```json
{
  "type": "EVENT",
  "sub_id": "...",
  "event": {
    "topic": "pg/cards/inserted",
    "event_type": "inserted",
    "payload": {
      "table": "cards",
      "operation": "INSERT",
      "data": { "id": "test-card-1", "title": "Test Card", ... }
    }
  }
}
```

### Step 6: Verify CDC (MongoDB)

```bash
# Open mongosh
make mongo-shell

# Insert a chat message
db.chat_messages.insertOne({
  channel: "general",
  user_id: "alice",
  username: "Alice",
  content: "Hello from mongo!",
  created_at: new Date()
})
```

WebSocket clients subscribed to `mongo/**` will receive:

```json
{
  "type": "EVENT",
  "sub_id": "...",
  "event": {
    "topic": "mongo/chat_messages/inserted",
    "event_type": "inserted",
    "payload": {
      "operation": "insert",
      "collection": "chat_messages",
      "fullDocument": { ... }
    }
  }
}
```

---

## 10. Debugging Techniques

### Enable Debug Logging

```bash
# All crates at debug level
RUST_LOG=debug make dev

# Specific crates
RUST_LOG=info,realtime_gateway=debug,realtime_engine=trace make dev

# Only WebSocket handler
RUST_LOG=info,realtime_gateway::ws_handler=trace make dev
```

### Log Level Reference

| Level | What You See |
|-------|-------------|
| `error` | Connection errors, publish failures, producer crashes |
| `warn` | Slow clients, authentication failures, subscribe denied, lagged subscribers |
| `info` | Connection open/close, subscriptions registered/removed, producer start/stop |
| `debug` | Every event routed, every WS message received, every send attempt |
| `trace` | Internal state details, bitmap evaluations, sequence assignments |

### Inspect Server Logs in Docker

```bash
# Last 100 lines
docker compose -f sandbox/docker-compose.yml logs --tail=100 realtime-server

# Follow in real time
make logs-server

# Filter for errors only
make logs-server 2>&1 | grep -i error
```

### Check Connection Count

```bash
# Via health endpoint
curl -s http://localhost:4002/v1/health | jq '.connections'

# Via server logs (look for "Connection registered" / "Connection removed")
make logs-server 2>&1 | grep -c "Connection registered"
```

### Debug WebSocket Frames

Use `websocat` in verbose mode:

```bash
websocat -v ws://localhost:4002/ws
# Shows raw frames sent/received
```

### Debug Event Routing

In the SyncSpace demo UI, open the **Debug Panel** (click the bug icon or the "Debug" section in the sidebar). It shows:
- All raw WebSocket messages received
- Event IDs, topics, types, and timestamps
- Connection state

---

## 11. Database Operations

### PostgreSQL

```bash
# Open interactive shell
make psql

# Common queries:
SELECT * FROM users;
SELECT * FROM boards;
SELECT * FROM cards ORDER BY created_at;
SELECT * FROM channels;

# Insert test data (triggers CDC event)
INSERT INTO cards (id, list_id, title, position, created_by)
VALUES (gen_random_uuid()::text, 'list-backlog', 'Debug Card', 99, 'user-alice');

# Check triggers are installed
SELECT trigger_name, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public';

# Test the notification manually
SELECT pg_notify('realtime_events', '{"table":"test","schema":"public","operation":"INSERT","data":{"id":"test"}}');
```

### MongoDB

```bash
# Open interactive shell
make mongo-shell

# Common queries:
db.chat_messages.find().sort({created_at: -1}).limit(10)
db.presence.find()

# Insert test data (triggers change stream event)
db.chat_messages.insertOne({
  channel: "general",
  user_id: "test",
  username: "Test User",
  content: "Debug message",
  created_at: new Date()
})

# Check replica set status (required for change streams)
rs.status()

# Check collections
db.getCollectionNames()
```

### Re-seed Databases

```bash
# Reset data to initial state
make seed
```

This re-runs `postgres-seed.sql` and `mongo-seed.js` without destroying and recreating the containers.

### Full Reset (Nuclear Option)

```bash
# Destroy everything: containers, volumes, networks
make clean

# Start from scratch
make up
```

---

## 12. WebSocket Testing

### Interactive Testing with websocat

```bash
# Connect
websocat ws://localhost:4002/ws

# Authenticate (paste this line)
{"type":"AUTH","token":"test-user"}

# Subscribe to PostgreSQL CDC events
{"type":"SUBSCRIBE","sub_id":"pg-all","topic":"pg/**"}

# Subscribe to a specific topic
{"type":"SUBSCRIBE","sub_id":"cards","topic":"pg/cards/*"}

# Subscribe with a filter
{"type":"SUBSCRIBE","sub_id":"inserts-only","topic":"pg/**","filter":{"event_type":{"eq":"inserted"}}}

# Batch subscribe
{"type":"SUBSCRIBE_BATCH","subscriptions":[{"sub_id":"s1","topic":"pg/**"},{"sub_id":"s2","topic":"mongo/**"}]}

# Publish an event
{"type":"PUBLISH","topic":"test/hello","event_type":"greeting","payload":{"msg":"hi"}}

# Ping
{"type":"PING"}

# Unsubscribe
{"type":"UNSUBSCRIBE","sub_id":"pg-all"}
```

### Scripted WebSocket Test

```bash
# Send auth + subscribe, wait for events
(echo '{"type":"AUTH","token":"test"}'; echo '{"type":"SUBSCRIBE","sub_id":"s1","topic":"**"}'; sleep 30) | websocat ws://localhost:4002/ws
```

### Two-Client Test

**Terminal 1:**

```bash
(echo '{"type":"AUTH","token":"alice"}'; echo '{"type":"SUBSCRIBE","sub_id":"s1","topic":"chat/*"}'; sleep 60) | websocat ws://localhost:4002/ws
```

**Terminal 2:**

```bash
(echo '{"type":"AUTH","token":"bob"}'; echo '{"type":"PUBLISH","topic":"chat/general","event_type":"message","payload":{"text":"Hello Alice!"}}'; sleep 1) | websocat ws://localhost:4002/ws
```

Terminal 1 should show the message from Bob.

---

## 13. Performance Testing

### Built-in Throughput Test

```bash
cargo test -p integration test_high_throughput_publish -- --nocapture
```

This publishes 100 events and measures how many are received within 5 seconds. Output includes throughput numbers.

### Stress Test with Multiple Connections

```bash
cargo test -p integration test_multiple_concurrent_connections -- --nocapture
```

This creates 10 simultaneous WebSocket connections, subscribes all to the same topic, and verifies broadcast delivery.

### Custom Load Test

```bash
# Publish 1000 events via REST
for i in $(seq 1 1000); do
  curl -s -X POST http://localhost:4002/v1/publish \
    -H "Content-Type: application/json" \
    -d "{\"topic\":\"load/test\",\"event_type\":\"test\",\"payload\":{\"idx\":$i}}" &
done
wait
echo "Done publishing 1000 events"
```

### Monitor During Load

```bash
# Watch connection/subscription count
watch -n 1 'curl -s http://localhost:4002/v1/health | python3 -m json.tool'
```

---

## 14. Common Issues and Fixes

### Issue: `make up` hangs or containers keep restarting

**Cause**: Docker build cache issue or port conflict.

**Fix**:

```bash
make clean
docker system prune -f
make up
```

### Issue: MongoDB change streams not working

**Cause**: Replica set not initialized.

**Fix**:

```bash
# Check replica set status
make mongo-shell
rs.status()

# If not initialized:
rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongo:27017"}]})
```

### Issue: PostgreSQL CDC events not arriving

**Cause**: Triggers not installed or wrong channel.

**Fix**:

```bash
make psql

-- Check triggers exist
SELECT trigger_name, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public';

-- Manually test notification
LISTEN realtime_events;
INSERT INTO cards (id, list_id, title, position, created_by)
VALUES ('test-123', 'list-backlog', 'Test', 99, 'user-alice');
-- You should see: Asynchronous notification "realtime_events" received...
```

### Issue: `cargo test` fails to compile

**Cause**: Missing system dependencies.

**Fix** (Ubuntu/Debian):

```bash
sudo apt install build-essential pkg-config libssl-dev
```

**Fix** (macOS):

```bash
xcode-select --install
```

### Issue: Port already in use

**Fix**:

```bash
# Check what's using port 4002
lsof -i :4002

# Kill it
kill -9 $(lsof -ti :4002)

# Or change the port
REALTIME_PORT=4003 make dev
```

### Issue: WebSocket connection refused

**Cause**: Server not running or wrong URL.

**Fix**:

```bash
# Check server is running
make status

# Check health
make health

# Check the correct port
# Docker: http://localhost:4002
# Local dev: http://localhost:4000
```

### Issue: Tests pass locally but fail in CI

**Cause**: CI servers may be slower — timeouts in async tests.

**Fix**: The integration tests use generous timeouts (5s for throughput test). If still failing, check that `tokio::time::timeout` values in tests are large enough.

---

## 15. CI/CD Integration

### Minimal CI Script (GitHub Actions)

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: cargo check --workspace
      - run: cargo test --workspace
      - run: cargo clippy --workspace -- -D warnings
```

### Full CI with Docker E2E

```yaml
name: Full CI
on: [push]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: cargo test --workspace

  docker-e2e:
    runs-on: ubuntu-latest
    needs: unit-tests
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f sandbox/docker-compose.yml up --build -d
      - run: sleep 30  # Wait for services
      - run: curl -sf http://localhost:4002/v1/health
      - run: python3 sandbox/test_ws_cdc.py
      - run: docker compose -f sandbox/docker-compose.yml down
```

### Pre-commit Checks

```bash
# Quick check before committing
cargo check --workspace && cargo test --workspace && echo "✓ All good"
```

### Build Release Binary

```bash
cargo build --release --bin realtime-server
# Binary at: target/release/realtime-server

# Check binary size
ls -lh target/release/realtime-server
# Typical: ~15-25MB (statically linked with most dependencies)
```

### Docker Production Build

```bash
docker build -f sandbox/Dockerfile -t realtime-server:latest .
docker run -p 4000:4000 -e REALTIME_PORT=4000 realtime-server:latest
```
