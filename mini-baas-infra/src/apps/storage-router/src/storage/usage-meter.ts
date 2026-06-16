/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   usage-meter.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Track-B metering (B1d-storage) — per-tenant `storage.bytes` counter for the
// storage-router. The data plane's Rust `usage.rs` is the reference PRODUCER;
// this is its TypeScript twin for the object-storage plane. It records the byte
// size of every SUCCESSFUL object write into an in-memory per-(tenant, metric)
// aggregate and a background flusher emits the CUMULATIVE window total ONCE per
// window onto the single frozen `usage.events` Redis stream — the producer side
// of the producer/consumer boundary the Go control-plane ingest (B1b) consumes.
//
// ## Why cumulative-per-window, NOT per-event
//
// The frozen idempotency_key buckets on the WINDOW START and the consumer does
// INSERT … ON CONFLICT (idempotency_key) DO NOTHING. So every write inside one
// window shares ONE idempotency_key. Emitting per-event would make the consumer
// keep only the FIRST event of each window → massive undercount. We therefore
// SUM per (tenant, metric) and flush the running total ONCE per window, then
// reset — mirroring `UsageAggregate::drain` in usage.rs exactly.
//
// ## Frozen contract (byte-for-byte with usage.rs / migration 040 / the Go store)
//
//   • stream key      : "usage.events"  (single stream; metric is a FIELD)
//   • entry fields    : tenant_id, metric, qty (int as string), ts (unix MILLIS
//                       string), window_ms (string), idempotency_key
//   • idempotency_key : lower-hex sha256("<tenant_id>|<metric>|<window_start_ms>")
//                       window_start_ms = ts - (ts mod window_ms)
//
// ## Parity (sub-flag OFF — the default)
//
// `UsageMeter.fromConfig` returns `undefined` when STORAGE_METERING is OFF, so
// the call site never constructs the meter, never records, never spawns the
// interval, and never opens a Redis connection. Observably byte-parity with the
// pre-metering storage-router.

import { Logger } from '@nestjs/common';
import { createHash } from 'node:crypto';
import Redis from 'ioredis';

/** The single Redis stream every usage window is XADD'd to (frozen contract). */
export const USAGE_STREAM_KEY = 'usage.events';

/**
 * The metric NAME this plane emits. The storage addon meters bytes written; the
 * `<plane>.<unit>` convention matches the data plane's `query.rows` / `write.rows`
 * (usage.rs) and the Go store's documented `query.count|query.rows|write.rows|…`.
 * packages.json declares the `storage` addon (plane "storage", "Object storage
 * (MinIO/S3)") but no metric units, so the unit is bytes — hence `storage.bytes`.
 */
export const STORAGE_METRIC = 'storage.bytes';

/** The window-start the idempotency_key buckets on: largest multiple of
 *  window_ms not exceeding ts. window_ms == 0 (misconfig) degrades to the raw ts
 *  (every window distinct) rather than dividing by zero — mirrors usage.rs. */
export function windowStartMs(ts: number, windowMs: number): number {
  if (windowMs === 0) return ts;
  return ts - (ts % windowMs);
}

/** The frozen idempotency_key: lower-hex sha256 of
 *  "<tenant_id>|<metric>|<window_start_ms>". Byte-for-byte with usage.rs's
 *  `idempotency_key` and the Go consumer's key reconstruction. */
export function idempotencyKey(tenant: string, metric: string, windowStart: number): string {
  return createHash('sha256')
    .update(tenant, 'utf8')
    .update('|', 'utf8')
    .update(metric, 'utf8')
    .update('|', 'utf8')
    .update(String(windowStart), 'utf8')
    .digest('hex');
}

/** One frozen on-the-wire envelope for a single (tenant, metric) window. */
export interface UsageEnvelope {
  tenant_id: string;
  metric: string;
  qty: string;
  ts: string;
  window_ms: string;
  idempotency_key: string;
}

/** Build the frozen envelope for one drained (tenant, metric, qty) window. Pure
 *  (no I/O) so a unit test and the live XADD share one path. */
export function buildEnvelope(
  tenant: string,
  metric: string,
  qty: bigint,
  nowMs: number,
  windowMs: number,
): UsageEnvelope {
  const ws = windowStartMs(nowMs, windowMs);
  return {
    tenant_id: tenant,
    metric,
    qty: qty.toString(),
    ts: String(nowMs),
    window_ms: String(windowMs),
    idempotency_key: idempotencyKey(tenant, metric, ws),
  };
}

/**
 * Windowed cumulative per-(tenant, metric) usage meter. `record` does a cheap
 * saturating bigint `+=`; a `setInterval` flusher drains the non-zero entries
 * once per window and XADDs the CUMULATIVE total — then the entry is removed,
 * so each emitted window is a discrete total (not a running sum) and idle pairs
 * never accumulate. Constructed ONLY when the sub-flag is ON (see `fromConfig`).
 */
export class UsageMeter {
  private readonly logger = new Logger(UsageMeter.name);
  private readonly counters = new Map<string, bigint>();
  private readonly redis: Redis;
  private timer?: NodeJS.Timeout;

  private constructor(
    private readonly metric: string,
    private readonly flushMs: number,
    redisUrl: string,
  ) {
    // lazyConnect: the socket opens on the first command (the first flush), so an
    // unreachable Redis at boot never blocks startup. The offline queue is LEFT
    // ON (the ioredis default) so that first command waits for the connection to
    // come up rather than being rejected with "Stream isn't writeable"; a flush
    // error is still logged + dropped (best-effort, OFF the request path —
    // identical posture to usage.rs's UsageStream). maxRetriesPerRequest bounds
    // how long a flush blocks before it gives up and drops the window.
    this.redis = new Redis(redisUrl, {
      lazyConnect: true,
      maxRetriesPerRequest: 2,
    });
  }

  /**
   * Construct + start the meter IFF the STORAGE_METERING sub-flag is ON. Returns
   * `undefined` when OFF (default) so the call site stays byte-parity: no map, no
   * interval, no Redis client. `flushMs` from STORAGE_METERING_FLUSH_MS (default
   * 60000), clamped ≥1 so a misconfigured 0 can't busy-spin.
   */
  static fromConfig(env: NodeJS.ProcessEnv = process.env): UsageMeter | undefined {
    if (!isTruthy(env['STORAGE_METERING'])) return undefined;
    const flushMs = Math.max(1, Number(env['STORAGE_METERING_FLUSH_MS'] ?? 60000) || 60000);
    const redisUrl =
      (env['STORAGE_METERING_REDIS_URL'] || env['REDIS_URL'] || 'redis://redis:6379').trim();
    const meter = new UsageMeter(STORAGE_METRIC, flushMs, redisUrl);
    meter.start();
    return meter;
  }

  /** Cheap, non-blocking saturating add of `bytes` for `tenant`. A zero/negative
   *  size (a failed/empty write) is a no-op — no entry, no window. */
  record(tenant: string, bytes: number): void {
    if (!tenant || !Number.isFinite(bytes) || bytes <= 0) return;
    const key = tenant;
    const prev = this.counters.get(key) ?? 0n;
    this.counters.set(key, prev + BigInt(Math.trunc(bytes)));
  }

  /** (tenant, metric) pairs currently tracked — the gauge a gate reads to prove
   *  OFF == 0 entries (and a flush reset to 0). */
  tracked(): number {
    return this.counters.size;
  }

  private start(): void {
    this.timer = setInterval(() => {
      void this.flush();
    }, this.flushMs);
    // Don't keep the event loop alive solely for the flusher.
    this.timer.unref?.();
    this.logger.log(`storage metering ON (metric=${this.metric}, flush=${this.flushMs}ms)`);
  }

  /** Drain the non-zero counters and XADD the CUMULATIVE window total per tenant,
   *  then reset. Best-effort: a Redis error is logged + dropped, never throws. */
  async flush(): Promise<void> {
    if (this.counters.size === 0) return;
    // Snapshot-and-reset in one synchronous step so a concurrent record() lands
    // in the fresh map (next window), never lost mid-flush.
    const drained = [...this.counters.entries()];
    this.counters.clear();
    const nowMs = Date.now();
    for (const [tenant, qty] of drained) {
      if (qty <= 0n) continue;
      const env = buildEnvelope(tenant, this.metric, qty, nowMs, this.flushMs);
      try {
        await this.redis.xadd(
          USAGE_STREAM_KEY,
          '*',
          'tenant_id', env.tenant_id,
          'metric', env.metric,
          'qty', env.qty,
          'ts', env.ts,
          'window_ms', env.window_ms,
          'idempotency_key', env.idempotency_key,
        );
      } catch (err) {
        this.logger.warn(
          `metering XADD failed for tenant=${tenant} — usage window dropped (best-effort): ${
            (err as Error).message
          }`,
        );
      }
    }
  }

  /** Flush the last partial window + close the Redis client on shutdown. */
  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    await this.flush().catch(() => undefined);
    await this.redis.quit().catch(() => undefined);
  }
}

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return ['1', 'true', 'yes', 'on'].includes(value.trim().toLowerCase());
}
