# Performance Analysis — Realtime-Agnostic

> Full-system benchmark & optimization audit.  
> Generated from criterion benchmarks (`make bench`) and exhaustive code review.

---

## Benchmark Baseline (criterion, 100 samples × 5 s)

### 1. Sequence Generator

| Benchmark | Latency | Throughput |
|-----------|---------|------------|
| `next` (same topic) | **36 ns** | ~27M ops/s |
| `next` (rotating 10 topics) | **37 ns** | ~27M ops/s |
| `current` (read-only) | **31 ns** | ~32M ops/s |

### 2. Topic Pattern Matching

| Pattern | Latency | vs Exact |
|---------|---------|----------|
| Exact match | **2.2 ns** | 1× |
| Prefix match | **3.2 ns** | 1.5× |
| Glob `orders/*` | **44 ns** | 20× |
| Glob `**` | **38 ns** | 17× |
| Deep glob `a/b/*/d/*/f/*` | **143 ns** | 65× |

### 3. Filter Expression Evaluation

| Filter | Cached | Uncached (re-parse) |
|--------|--------|---------------------|
| Eq (envelope field) | **12.7 ns** | — |
| Eq (payload field) | **25 ns** | **206 ns** (8.2× slower) |
| In (3 values) | **13.2 ns** | — |
| Ne | **13.6 ns** | — |
| And (2 fields) | **40.5 ns** | — |

### 4. Filter Index (bitmap) — O(1) Confirmed!

| Subscriptions | `evaluate` (unfiltered) | `evaluate` (eq filter) |
|---------------|------------------------|------------------------|
| 10 | **3.08 µs** | **6.11 µs** |
| 100 | **3.03 µs** | **6.04 µs** |
| 1,000 | **3.07 µs** | **6.02 µs** |
| 10,000 | **3.13 µs** | **6.17 µs** |

> **Key insight:** Filter index evaluation is **perfectly O(1)** — constant ~3 µs unfiltered and ~6 µs with eq filter regardless of subscription count (10 → 10K). This validates the bitmap approach.

| Operation | Latency |
|-----------|---------|
| `add_subscription` | **295 ns** |
| `remove_subscription` | **6.1 µs** |

### 5. Registry Lookup

| Subscriptions | Linear (unfiltered) | Bitmap (unfiltered) | Bitmap (eq filter) |
|---------------|--------------------|--------------------|-------------------|
| 10 | **3.50 µs** | **3.56 µs** | — |
| 100 | **5.77 µs** | **6.06 µs** | **10.7 µs** |
| 1,000 | **28.1 µs** | **30.3 µs** | **50.1 µs** |
| 10,000 | **303.5 µs** | **378.0 µs** | **551.4 µs** |

> **Note:** Registry lookup scales linearly with subscription count because it iterates all matching bitmap entries to collect results. The bitmap overhead at low counts (~2%) is negligible. At 10K, the bitmap path is ~25% slower due to RoaringTreemap iteration + post-filter overhead.

| Operation | Latency |
|-----------|---------|
| `subscribe` | **595 ns** |
| `unsubscribe` | **6.81 µs** |
| `remove_connection` (100 subs) | **63.0 µs** |

### 6. Router (End-to-End)

| Subscriptions | `route_event` (unfiltered) | `route_event` (eq filter) |
|---------------|---------------------------|--------------------------|
| 1 | **3.67 µs** | — |
| 10 | **4.24 µs** | — |
| 100 | **8.04 µs** | **12.4 µs** |
| 1,000 | **44.8 µs** | **59.2 µs** |
| 10,000 | **542.7 µs** | **643.9 µs** |

| Scenario | Latency |
|----------|---------|
| `route_event_no_match` | **3.47 µs** |

> **Throughput at 10K subscriptions:** ~1,800 route operations/sec (unfiltered), ~1,500/sec (eq filter).  
> At 1K subscriptions: ~22,300/sec unfiltered — well within production needs.

### 7. Envelope Operations

| Operation | Latency |
|-----------|---------|
| `create` | **288 ns** |
| `serialize_json` | **560 ns** |
| `deserialize_json` | **572 ns** |
| `clone_arc` | **10.9 ns** |
| `payload_parse` | **183 ns** |

### 8. Event Payload (Gateway Wire Format)

| Operation | Latency |
|-----------|---------|
| `from_envelope` | **363 ns** |
| `from_envelope_then_serialize` | **617 ns** |

> **Per-connection cost:** Each connected client receiving an event pays ~617 ns for payload construction + serialization. At 10K connections × 100 events/sec = 1M ops/sec → **617 ms/sec of CPU** just on payload serialization. This is the primary target for H1 (RawValue optimization).

---

## Already Implemented Optimizations (Previous Phase)

These 10 bottlenecks + 3 correctness bugs were fixed in the prior engine overhaul:

| # | Fix | Before → After |
|---|-----|----------------|
| 1 | FilterIndex: triple-nested DashMap → flat composite key | 3 lock acquisitions → 1 |
| 2 | FilterIndex: RoaringBitmap(u32) → RoaringTreemap(u64) | Truncation bug fixed |
| 3 | FilterIndex: O(F×V) removal → O(k) via `sub_keys` tracking | Removal from O(all) to O(predicates) |
| 4 | Registry: Vec → HashMap/HashSet | O(n) removal → O(1) |
| 5 | Registry: String key for `by_sub_id` → `(ConnectionId, SubscriptionId)` tuple | Eliminated format!() allocation |
| 6 | Lookup: Added mandatory post-filter in bitmap path | Ne/Not correctness bug fixed |
| 7 | Lookup: Pre-parse JSON payload once per event | 8× improvement for payload fields |
| 8 | Router: Switched to `lookup_matches_bitmap()` | Bitmap path for all routing |
| 9 | Getter: Added `envelope_field_getter_cached()` | Zero re-parse for filter evaluation |
| 10 | FilterIndex: `value_to_string` returns `Cow<str>` | Zero-alloc for string filter values |

---

## Remaining Performance Improvement Opportunities

### CRITICAL — Must Fix for Production

#### C1. Fan-out `Arc<Mutex<mpsc::Receiver>>` Serialization Bottleneck
**File:** `crates/realtime-gateway/src/fanout.rs`  
**Impact:** All N fan-out workers contend on a **single Mutex** to dequeue dispatch instructions.  
**Problem:**
```rust
let shared_rx = Arc::new(Mutex::new(dispatch_rx));
// N workers all lock this:
let mut rx = shared.lock().await;
let dispatch = rx.recv().await;
```
Only one worker can dequeue at a time. With 10K events/sec and 4 workers, the Mutex becomes the global bottleneck.

**Fix:** Replace with a proper MPMC pattern:
- Option A: Use `tokio::sync::broadcast` channel (clone-friendly, no Mutex)
- Option B: Use `async_channel::bounded` (true MPMC, no Mutex)
- Option C: Shard the dispatch channel into N channels, round-robin or hash-partition by `conn_id`

**Estimated gain:** 2–5× throughput at high fan-out rates.

---

#### C2. `try_send` Silently Drops Events Under Backpressure
**File:** `crates/realtime-engine/src/router.rs` (line ~152)  
**Impact:** When the dispatch channel is full, events are **silently dropped** with only a warn log.  
**Problem:**
```rust
if let Err(e) = self.dispatch_tx.try_send(dispatch) {
    warn!(conn_id = %conn_id, "Dispatch channel full or closed: {}", e);
}
```
No retry, no backpressure signal, no metric counter. Under sustained load, clients miss events with zero indication.

**Fix:**
1. Add a `metrics::counter!("dispatch_dropped_total").increment(1)` for observability
2. Consider `send().await` with a timeout instead of `try_send` for lossless delivery
3. Or implement a ring-buffer overwrite policy with gap-detection signaling

---

#### C3. `run_with_subscriber` Clones Every Event
**File:** `crates/realtime-engine/src/router.rs` (line ~171)  
**Problem:**
```rust
while let Some(event) = subscriber.next_event().await {
    let _routed = self.route_event(event.clone()); // <-- Clone EventEnvelope
```
`route_event` takes `mut event` (ownership) to assign the sequence number, so the clone is needed to ack. But `EventEnvelope` contains `Bytes` + multiple `String`s — this clone is expensive.

**Fix:** Make `route_event` take `&mut EventEnvelope` and mutate in-place, then ack from the same reference. Or move the sequence assignment earlier so ownership can be passed without clone.

**Estimated gain:** ~200 ns/event saved (serde_json::Value clone + String clones).

---

### HIGH PRIORITY

#### H1. Writer `serialize_event` Re-Parses + Re-Serializes the Payload
**File:** `crates/realtime-gateway/src/ws_handler/writer.rs`  
**Problem:** `EventPayload::from_envelope()` calls `serde_json::from_slice(&event.payload)` to parse bytes into `Value`, then `serde_json::to_string(&msg)` re-serializes. Per 10K connections × 100 events/sec = 1M parse+serialize ops/sec.

**Fix:** Since the payload is already JSON bytes, build the output frame with string interpolation or a pre-serialized payload cache on the `Arc<EventEnvelope>`. Use `serde_json::value::RawValue` to embed pre-serialized JSON without re-parsing.

**Estimated gain:** 400–800 ns/event (eliminate JSON parse + re-serialize of payload).

---

#### H2. `sub_id: String::new()` in Writer (Always Empty)
**File:** `crates/realtime-gateway/src/ws_handler/writer.rs` line 22  
**Problem:**
```rust
let msg = ServerMessage::Event {
    sub_id: String::new(), // Always empty!
    event: payload,
};
```
The `sub_id` should be the subscription ID that matched the event, but it's always empty. This is both a **bug** and a performance issue (the LocalDispatch already carries the sub_id).

**Fix:** Pass `sub_id` through the per-connection channel alongside the event.

---

#### H3. `subscribe()` Clones Subscription 3+ Times
**File:** `crates/realtime-engine/src/registry/mod.rs`  
**Problem:** `subscribe()` calls `sub.clone()` to create the entry, then inserts entry.clone() into by_connection, inserts the sub into filter_index (which clones topic + filter). Total: 3-4 full Subscription clones.

**Fix:** Use `Arc<Subscription>` and share references, or restructure to avoid clones by inserting into all maps from a single owned value.

---

#### H4. Missing Release Profile (NOW FIXED)
**File:** `Cargo.toml` — `[profile.release]` added with:
```toml
lto = "fat"
codegen-units = 1
strip = true
panic = "abort"
```
**Estimated gain:** 10–30% smaller binary, 5–15% faster execution from LTO cross-crate inlining.

---

### MEDIUM PRIORITY

#### M1. `glob_match()` Allocates Two `Vec<&str>` Per Call
**File:** `crates/realtime-core/src/types/topic_pattern.rs`  
**Benchmark:** 44 ns per call (20× slower than exact match).  
**Problem:**
```rust
let pat: Vec<&str> = pattern.split('/').collect();
let parts: Vec<&str> = topic.split('/').collect();
```
Two heap allocations per match check. Called for every pattern × every event.

**Fix:** Use iterator-based matching without collecting into Vecs:
```rust
fn glob_match(pattern: &str, topic: &str) -> bool {
    let mut pat_iter = pattern.split('/');
    let mut topic_iter = topic.split('/');
    loop {
        match (pat_iter.next(), topic_iter.next()) {
            (Some("**"), _) => return true,
            (Some(p), Some(t)) => if p != "*" && p != t { return false; },
            (None, None) => return true,
            _ => return false,
        }
    }
}
```
**Estimated gain:** ~20 ns/call (eliminate 2 Vec allocations), 2× faster glob matching.

---

#### M2. `make_index_key` Allocates on Every Insert & Lookup
**File:** `crates/realtime-engine/src/filter_index/mod.rs`  
**Problem:** `make_index_key` creates a new String for every composite key lookup.

**Fix:** Use a thread-local reusable buffer, or use a fixed concat macro. Alternatively, switch to a hash-based key (hash the 3 parts into u128) to avoid string allocation entirely.

---

#### M3. `SeqCst` Ordering in SequenceGenerator
**File:** `crates/realtime-engine/src/sequence.rs`  
**Problem:** `Ordering::SeqCst` on both `fetch_add` and `load`. SeqCst is the most expensive ordering — it requires a full memory fence on x86 (MFENCE/LOCK XCHG).

**Fix:** Use `Ordering::Relaxed` for `fetch_add` (it's already atomic) and `Ordering::Acquire` for `load`. Monotonicity is guaranteed by the atomic operation itself.

**Estimated gain:** ~5-10 ns on ARM, negligible on x86 (already fast at 36 ns).

---

#### M4. `event_type` is `String` not `SmolStr`
**File:** `crates/realtime-core/src/types/envelope.rs`  
**Problem:** `EventEnvelope.event_type` is a heap-allocated `String`. Typical event types ("created", "updated", "deleted") are ≤23 bytes and would fit in SmolStr's inline buffer.

**Fix:** Change to `SmolStr` — eliminates one heap allocation per event.

---

#### M5. `TraceId(pub String)` — Always Heap-Allocated
**File:** `crates/realtime-core/src/types/identifiers.rs`  
**Fix:** Change to `SmolStr` (trace IDs like UUIDs are 36 chars, but could use compact representations).

---

#### M6. REST `validate_and_create_envelope` Serializes Just to Check Size
**File:** `crates/realtime-gateway/src/rest_api.rs`  
**Problem:**
```rust
let bytes = serde_json::to_vec(&req.payload).map_err(|e| { ... })?;
if bytes.len() > 65_536 { ... }
```
Serializes the payload to Vec<u8> just to check size, then passes ownership to EventEnvelope. This is actually OK (the bytes are needed), but could be optimized by checking `req.payload.to_string().len()` as an upper-bound estimate before serializing.

---

#### M7. `bytes_serde` Double-Parse on Deserialization
**File:** `crates/realtime-core/src/types/envelope.rs`  
**Problem:** The custom deserializer parses JSON into `Value`, then re-serializes to `Vec<u8>`:
```rust
let v = serde_json::Value::deserialize(deserializer)?;
let b = serde_json::to_vec(&v).map_err(serde::de::Error::custom)?;
```
Two allocations + two JSON passes on every envelope deserialization.

**Fix:** Use `serde_json::value::RawValue` to capture the raw JSON bytes without parsing.

---

#### M8. `ConnectionManager::next_connection_id` uses `SeqCst`
**File:** `crates/realtime-gateway/src/connection/mod.rs`  
**Fix:** Use `Ordering::Relaxed` — connection IDs only need uniqueness, not cross-thread visibility ordering.

---

#### M9. Five Separate `DashMap`s in SubscriptionRegistry
**File:** `crates/realtime-engine/src/registry/mod.rs`  
**Problem:** `by_connection`, `by_topic`, `by_sub_id`, `patterns`, plus `filter_index` has 5 more. Each DashMap has 64 shards by default. That's 640 `RwLock`s for the registry alone.

**Fix:** Consider a single `DashMap<ConnectionId, ConnectionSubscriptions>` struct that holds all per-connection data in one shard, reducing lock contention and cache-line bouncing.

---

#### M10. Router `dispatch_tx.try_send` — Channel Capacity Tuning
**File:** Already at 65,536 capacity. Consider dynamic sizing or bounded ring buffer.

---

### LOW PRIORITY (Polish)

| # | Issue | Location | Fix |
|---|-------|----------|-----|
| L1 | `FieldPath(pub String)` — heap alloc | `filter/mod.rs` | → `SmolStr` |
| L2 | `FilterValue::String(String)` — heap alloc | `filter/mod.rs` | → `SmolStr` or `Cow<'static, str>` |
| L3 | `format!("{:?}", s.kind)` in source getter | `filter/getter.rs` | → `as_str()` method |
| L4 | Default DashMap hasher (SipHash) | All DashMaps | → `ahash::RandomState` (already a dep) |
| L5 | `event.event_type.clone()` in getter | `filter/getter.rs` | → return `&str` from SmolStr |
| L6 | `topic.as_str().to_string()` in getter | `filter/getter.rs` | → return `Cow<str>` |
| L7 | `SmolStr::new(topic)` per sequence call | `sequence.rs` | → accept `SmolStr` directly |
| L8 | `ctrl_tx` channel capacity only 64 | `connection.rs` | → increase to 256 or dynamic |

---

## Release Profile Impact

Added to workspace `Cargo.toml`:
```toml
[profile.release]
lto = "fat"           # Cross-crate inlining (critical for trait dispatch)
codegen-units = 1     # Single codegen unit = better optimization
strip = true          # Remove debug symbols from binary
panic = "abort"       # No unwinding overhead
opt-level = 3         # Maximum optimization

[profile.bench]
lto = "thin"          # Faster bench compilation with good optimization
codegen-units = 1
```

**Expected impact:**
- Binary size: 30-50% smaller
- Throughput: 5-15% faster (LTO enables cross-crate inlining of DashMap, serde, etc.)
- Startup: Faster (smaller binary, less to load)

---

## Priority Fix Order (Effort vs Impact)

| Priority | Fix | Effort | Impact |
|----------|-----|--------|--------|
| 1 | **C1** Fan-out Mutex → MPMC | Medium | 2-5× fan-out throughput |
| 2 | **H1** Writer: RawValue for payload | Low | 400-800 ns/event |
| 3 | **M1** glob_match iterator (no Vec alloc) | Low | 2× glob matching |
| 4 | **C3** Eliminate event clone in router | Low | ~200 ns/event |
| 5 | **H2** Fix empty sub_id bug in writer | Trivial | Correctness |
| 6 | **C2** Add drop counter / backpressure for try_send | Low | Observability |
| 7 | **M4** event_type → SmolStr | Low | 1 heap alloc saved/event |
| 8 | **M7** bytes_serde → RawValue | Medium | 2 JSON passes saved/deser |
| 9 | **M3** SeqCst → Relaxed | Trivial | ~5 ns/op (ARM) |
| 10 | **L4** DashMap → ahash hasher | Low | ~10-20% faster lookups |

---

## How to Run Benchmarks

```bash
# Run all engine benchmarks
make bench

# Run a specific benchmark group
cargo bench -p realtime-engine -- "router"
cargo bench -p realtime-engine -- "filter_index"
cargo bench -p realtime-engine -- "topic_pattern"

# Compare against baseline (after making changes)
cargo bench -p realtime-engine -- --save-baseline before
# ... make changes ...
cargo bench -p realtime-engine -- --baseline before
```

HTML reports are saved to `target/criterion/report/index.html`.
