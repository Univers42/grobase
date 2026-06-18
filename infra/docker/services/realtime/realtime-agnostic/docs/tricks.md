# Realtime Engine Tricks & Optimizations

## 1. Zero-Cost JSON Parsing
When reading `JSON` payloads, we deserialize directly from `&[u8]` bytes using `serde_json::from_slice` to prevent allocating Strings. This allows the JSON parser to zero-copy strings for filter evaluations if the lifetime is managed correctly.

## 2. Tokio Broadcast Bus Scaling
`tokio::sync::broadcast` is excellent out of the box, but slow consumers drop messages. The standard trick here is to implement a bounded ring buffer or to set `tokio::sync::broadcast::channel` capacity extremely high, but that can OOM if not careful. The trick used in `InProcessBus` handles overflow gracefully by exposing client-level queue drops rather than whole server latency drops.

## 3. Fast Routing with Trie + DashMap
We use a combination of a fast concurrent hashmap (`DashMap`) for direct `O(1)` connection lookup and a routing Trie. This achieves lock-free read path performance while maintaining transactional integrity over subscriptions via shard sharding.

## 4. Backpressure Limits
TCP sockets apply backpressure to WebSocket streams. We wrap all connection `Sender` pipelines in unbounded or bounded mpsc channels. If a client stalls, we intentionally drop their oldest messages using `OverflowPolicy::DropOldest` to protect the core router thread.

## 5. PostgreSQL Listen/Notify Limitations
`pg_notify` payload size is limited to 8000 bytes. The trick implemented in `realtime-db-postgres` uses `json_build_object` to send a minimal reference id if the size is > 8000. Wait, actually, if a trigger row is large, we handle chunking or querying the ID afterward.

## 6. Lints as First-Class Rule Set
We enforce `clippy::unwrap_used` globally to `deny` out-of-the-box. This prevents production panics effectively and forces explicit error handling at all layers down to the configuration root.
