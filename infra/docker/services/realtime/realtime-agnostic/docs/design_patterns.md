# Realtime Engine Design Patterns

## Overview
This document outlines the core design patterns implemented throughout the `realtime-agnostic` engine. We leverage robust distributed systems and Rust-centric patterns to achieve maximum performance and maintainability.

## 1. Composition Root (Server Crate)
We use the **Composition Root** pattern in the `realtime-server` crate. The core logic of the application does not know about its dependencies. Instead, `server.rs` explicitly instantiates:
- Event Bus (`InProcessBus` or external)
- Database Producers (PostgreSQL, MongoDB)
- WebSocket Handlers
This allows total decoupling of `realtime-core` from specific implementations.

## 2. Actor Model (Fan-out Workers)
The **Actor Model** is used for fan-out dispatching. The `FanOutWorkerPool` spawns discrete worker tasks. Each worker receives events via an mpsc channel and handles dispatching them to individual WebSocket connections. State is fully isolated per connection.

## 3. Pluggable Adapters (Database Providers)
We implement the **Adapter Pattern** for database CDC (Change Data Capture). `DatabaseProducer` is a trait that allows `PostgresProducer` and `MongoProducer` to hook into the system without the `realtime-engine` being aware of database specifics.

## 4. Publisher-Subscriber (Pub/Sub)
The overarching architecture uses a decoupled **Pub/Sub** structure at several levels:
- Inter-node bus (`EventBus`)
- Client connections mapping (Subscription Registry)

## 5. Bitmap Indexing (Filter Evaluation)
To efficiently scale filter evaluations across millions of subscriptions, we use **Roaring Bitmaps**. This acts as an inverted index over subscription predicates, turning O(N) evaluation time into O(1) bitwise operations.
