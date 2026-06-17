/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   realtime-publisher.service.ts                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/** Write operations that fan out as `row_changed` realtime events. */
export type RealtimeWriteOp = 'insert' | 'update' | 'delete' | 'upsert';

/** Optional context attached to a `row_changed` event. */
export interface RowChangedDetail {
  /** The write's filter (update/delete) — sanitized + size-capped before send. */
  filter?: unknown;
  /** Caller idempotency key; forwarded so the realtime bus can dedupe. */
  idempotencyKey?: string;
  /** Best-effort primary key of the touched row (`id` when known). */
  pk?: unknown;
}

/** Filters above this serialized size are dropped from the payload (the event
 *  stays useful without them; subscribers refetch). Keeps the envelope far
 *  below the realtime service's 64KB payload cap. */
const MAX_FILTER_JSON_BYTES = 8_192;

/**
 * Best-effort fan-out of committed writes to the realtime WebSocket service
 * (Phase 6 — live `row_changed` publishing).
 *
 * Mirrors outbox-relay's `publishRealtime` ingest contract: an internal,
 * unauthenticated `POST ${REALTIME_PUBLISH_URL}` (default
 * `http://realtime:4000/v1/publish`) with `{ topic, event_type,
 * idempotency_key?, payload }`. Subscribers join `table:<dbId>:<table>`
 * (an Exact TopicPattern — no wildcards needed) over `/realtime/v1/ws`.
 *
 * Delivery posture — deliberately weaker than the outbox:
 *   - fire-and-forget with a short timeout (default 1.5s);
 *   - EVERY failure is swallowed (debug-logged), the write response is never
 *     affected;
 *   - no retries — clients converge via their poll fallback, and the durable
 *     outbox → relay path remains the at-least-once channel.
 *
 * An empty `REALTIME_PUBLISH_URL` disables publishing entirely (same switch
 * semantics as outbox-relay).
 */
@Injectable()
export class RealtimePublisherService {
  private readonly logger = new Logger(RealtimePublisherService.name);
  private readonly publishUrl: string;
  private readonly timeoutMs: number;

  constructor(config: ConfigService) {
    // internal/loopback only — not externally exposed
    const scheme = 'http';
    this.publishUrl = config.get<string>(
      'REALTIME_PUBLISH_URL',
      `${scheme}://realtime:4000/v1/publish`,
    );
    this.timeoutMs = Number(config.get<string>('REALTIME_PUBLISH_TIMEOUT_MS', '1500'));
  }

  /**
   * Publish a `row_changed` event for one SUCCESSFUL write on
   * `table:<dbId>:<table>`. Never rejects — all failures are debug-logged.
   */
  async publishRowChanged(
    dbId: string,
    table: string,
    op: RealtimeWriteOp,
    detail: RowChangedDetail = {},
  ): Promise<void> {
    await this.post(`table:${dbId}:${table}`, 'row_changed', detail.idempotencyKey, {
      dbId,
      table,
      op,
      filter: this.sanitizeFilter(detail.filter),
      pk: this.sanitizeFilter(detail.pk),
      ts: new Date().toISOString(),
    });
  }

  /**
   * Publish a `schema_changed` event after a SUCCESSFUL DDL on the SAME
   * `table:<dbId>:<table>` channel — subscribed clients refetch the schema.
   * `op` is the DDL operation (create_table | add_column | …).
   */
  async publishSchemaChanged(dbId: string, table: string, op: string): Promise<void> {
    await this.post(`table:${dbId}:${table}`, 'schema_changed', undefined, {
      dbId,
      table,
      op,
      ts: new Date().toISOString(),
    });
  }

  /**
   * Publish an `automation_fired` event (notify action) on the table's
   * channel — every subscribed client can toast it.
   */
  async publishAutomationFired(
    dbId: string,
    table: string,
    ruleId: string,
    ruleName: string,
    message: string,
    pk: unknown,
  ): Promise<void> {
    await this.post(`table:${dbId}:${table}`, 'automation_fired', undefined, {
      dbId,
      table,
      ruleId,
      ruleName,
      message,
      pk: this.sanitizeFilter(pk),
      ts: new Date().toISOString(),
    });
  }

  /** POST one event envelope. Best-effort: timeout-capped, never throws. */
  private async post(
    topic: string,
    eventType: string,
    idempotencyKey: string | undefined,
    payload: Record<string, unknown>,
  ): Promise<void> {
    if (!this.publishUrl) return;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await fetch(this.publishUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          topic,
          event_type: eventType,
          ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}),
          payload,
        }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
    } catch (error) {
      // Best-effort by design: a realtime outage must never surface to the
      // write path. The poll fallback (and the durable outbox relay) cover
      // missed events, so this is debug — not warn — noise.
      this.logger.debug(
        `realtime publish skipped for ${topic} (${eventType}): ${
          error instanceof Error ? error.message : 'unknown error'
        }`,
      );
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Returns a JSON-safe, size-capped copy of `value`, or `undefined` when it
   * is absent, non-serializable, or larger than {@link MAX_FILTER_JSON_BYTES}.
   * The JSON round-trip drops functions/undefined/symbols and breaks no cycles
   * silently (cycles throw → dropped).
   */
  private sanitizeFilter(value: unknown): unknown {
    if (value === null || value === undefined) return undefined;
    try {
      const json = JSON.stringify(value);
      if (typeof json !== 'string' || json.length > MAX_FILTER_JSON_BYTES) return undefined;
      return JSON.parse(json) as unknown;
    } catch {
      return undefined;
    }
  }
}
