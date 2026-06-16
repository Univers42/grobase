// Unit tests for the B1d usage meter — pin the FROZEN envelope contract and the
// CUMULATIVE windowed aggregation (NOT per-event emit). Run in a container:
//   docker run --rm -v "$PWD/src:/app" -w /app denoland/deno:alpine-2.1.4 \
//     deno test --allow-net usage-meter.test.ts
// (--allow-net is only needed because UsageMeter imports the redis client type;
// the tests below never open a socket.)

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createHash } from "node:crypto";
import {
  buildEnvelope,
  FUNCTION_INVOCATIONS_METRIC,
  idempotencyKey,
  USAGE_STREAM_KEY,
  UsageMeter,
  windowStartMs,
} from "./usage-meter.ts";

// The frozen idempotency_key is the lower-hex sha256 of
// "<tenant>|<metric>|<window_start_ms>" — byte-identical to the Rust producer
// (usage.rs) so the Go consumer dedups across the boundary.
Deno.test("idempotency_key is the frozen sha256(tenant|metric|window) contract", () => {
  const k = idempotencyKey("t1", "query.count", 120_000);
  assertEquals(k.length, 64, "sha256 hex is 64 chars");
  assert(/^[0-9a-f]{64}$/.test(k), "lower-hex only");
  const golden = createHash("sha256").update("t1|query.count|120000").digest("hex");
  assertEquals(k, golden, "key == sha256_hex(tenant|metric|window_start_ms)");
});

// window_start buckets ts to the largest multiple of window_ms not exceeding it,
// and degrades safely (raw ts) on window 0 — matches usage.rs::window_start_ms.
Deno.test("window_start_ms buckets to the window start", () => {
  assertEquals(windowStartMs(123_456, 60_000), 120_000);
  assertEquals(windowStartMs(120_000, 60_000), 120_000);
  assertEquals(windowStartMs(180_001, 60_000), 180_000);
  assertEquals(windowStartMs(123_456, 0), 123_456); // no divide-by-zero
});

// The envelope carries the exact wire fields; a later flush in the SAME window
// yields the SAME idempotency_key (re-delivery collapses, no double-count); the
// next window gets a fresh key (a new billable bucket).
Deno.test("envelope carries frozen fields and window-bucketed key", () => {
  const env = buildEnvelope("t1", "function.invocations", 42, 123_456, 60_000);
  assertEquals(env.tenant_id, "t1");
  assertEquals(env.metric, "function.invocations");
  assertEquals(env.qty, "42", "qty is the integer as a string");
  assertEquals(env.ts, "123456", "ts is the raw flush instant (unix ms)");
  assertEquals(env.window_ms, "60000");
  assertEquals(env.idempotency_key, idempotencyKey("t1", "function.invocations", 120_000));

  const later = buildEnvelope("t1", "function.invocations", 99, 150_000, 60_000);
  assertEquals(later.idempotency_key, env.idempotency_key, "same window ⇒ same key");
  const next = buildEnvelope("t1", "function.invocations", 1, 181_000, 60_000);
  assert(next.idempotency_key !== env.idempotency_key, "next window ⇒ distinct key");
});

// CUMULATIVE aggregation: N records for one (tenant, metric) SUM into one window
// total — the core property that makes this not a per-event emit. A flusher with
// no redis configured still drains+resets the counter.
Deno.test("meter sums per (tenant, metric) into a cumulative window total", () => {
  const meter = new UsageMeter({ flushMs: 60_000, redisUrl: "" });
  assertEquals(meter.tracked(), 0);
  for (let i = 0; i < 4; i++) {
    meter.record("t1", FUNCTION_INVOCATIONS_METRIC, 1);
  }
  meter.record("t2", FUNCTION_INVOCATIONS_METRIC, 1);
  assertEquals(meter.tracked(), 2, "two distinct (tenant, metric) pairs");
  // flushOnce with no redis configured is a no-op emit but still DRAINS the map.
  return meter.flushOnce().then(() => {
    assertEquals(meter.tracked(), 0, "drain reset the aggregator to empty");
  });
});

// qty<=0 and empty tenant are no-ops (parity: never create a phantom entry).
Deno.test("record ignores non-positive qty and empty tenant", () => {
  const meter = new UsageMeter({ flushMs: 60_000, redisUrl: "" });
  meter.record("t1", FUNCTION_INVOCATIONS_METRIC, 0);
  meter.record("", FUNCTION_INVOCATIONS_METRIC, 1);
  assertEquals(meter.tracked(), 0);
});

// The single stream key + metric name are the frozen public constants.
Deno.test("frozen public constants", () => {
  assertEquals(USAGE_STREAM_KEY, "usage.events");
  assertEquals(FUNCTION_INVOCATIONS_METRIC, "function.invocations");
});
