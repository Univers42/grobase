/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   outbox.service.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:35:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool, PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import type { AdapterOp, QueryResult } from '@mini-baas/database';

interface OutboxEventInput {
  aggregate: string;
  aggregateId: string;
  eventType: string;
  payload: Record<string, unknown>;
  requestId?: string;
  actorId?: string;
  targetEngine?: string;
  targetResource?: string;
  op?: AdapterOp;
  compensationPayload?: Record<string, unknown>;
  idempotencyKey?: string;
}

interface QueryOutboxInput {
  engine: string;
  resource: string;
  op: AdapterOp;
  result: QueryResult;
  data?: Record<string, unknown>;
  filter?: Record<string, unknown>;
  requestId?: string;
  actorId?: string;
  /**
   * The AUTHORITATIVE tenant (slug) of the write, taken from the verified
   * request identity — NOT from any user-writable row column. Stamped as a
   * top-level `tenant_id` on the payload so the function-trigger / webhook
   * dispatchers can scope delivery to the owning tenant (cross-tenant safe).
   */
  tenantId?: string;
  idempotencyKey?: string;
}

const MUTATING_OPS = new Set<AdapterOp>(['insert', 'update', 'delete', 'upsert', 'batch']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

@Injectable()
export class OutboxService implements OnModuleDestroy {
  private readonly logger = new Logger(OutboxService.name);
  private readonly enabled: boolean;
  private pool?: Pool;

  constructor(private readonly config: ConfigService) {
    this.enabled = this.config.get<string>('OUTBOX_ENABLED', 'true') !== 'false';
  }

  async onModuleDestroy(): Promise<void> {
    if (this.pool) await this.pool.end();
  }

  async emitForQuery(input: QueryOutboxInput): Promise<void> {
    if (!MUTATING_OPS.has(input.op) || input.resource === 'outbox_events') return;

    await this.emit({
      aggregate: input.resource,
      aggregateId: this.aggregateId(input),
      eventType: `${input.resource}.${input.op}`,
      requestId: input.requestId,
      actorId: input.actorId,
      targetEngine: this.targetValue(input.data, 'target_engine'),
      targetResource: this.targetValue(input.data, 'target_resource'),
      op: input.op,
      compensationPayload: this.compensationPayload(input.data),
      idempotencyKey: input.idempotencyKey,
      payload: {
        // Top-level authoritative tenant (slug) so the outbox consumers
        // (function-trigger + webhook dispatchers) can tenant-scope delivery.
        // Server-derived; never read from a user-writable row column.
        tenant_id: input.tenantId ?? null,
        engine: input.engine,
        resource: input.resource,
        op: input.op,
        data: input.data ?? null,
        filter: input.filter ?? null,
        rowCount: input.result.rowCount,
        rows: input.result.rows.slice(0, 10),
      },
    });
  }

  async emit(event: OutboxEventInput): Promise<void> {
    if (!this.enabled) return;
    const pool = this.getPool();
    await pool.query(
      `INSERT INTO public.outbox_events
        (aggregate, aggregate_id, event_type, payload, request_id, actor_id, target_engine, target_resource, op, compensation_payload, idempotency_key)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, $9, $10::jsonb, $11)`,
      [
        event.aggregate,
        event.aggregateId,
        event.eventType,
        JSON.stringify(event.payload),
        this.uuidOrNull(event.requestId),
        this.uuidOrNull(event.actorId),
        event.targetEngine ?? null,
        event.targetResource ?? null,
        event.op ?? null,
        event.compensationPayload ? JSON.stringify(event.compensationPayload) : null,
        event.idempotencyKey ?? null,
      ],
    ).catch(async (error: unknown) => {
      if ((error as { code?: string }).code !== '42703') throw error;
      await pool.query(
        `INSERT INTO public.outbox_events
          (aggregate, aggregate_id, event_type, payload, request_id, actor_id)
         VALUES ($1, $2, $3, $4::jsonb, $5, $6)`,
        [
          event.aggregate,
          event.aggregateId,
          event.eventType,
          JSON.stringify(event.payload),
          this.uuidOrNull(event.requestId),
          this.uuidOrNull(event.actorId),
        ],
      );
    });
  }

  async emitWithClient(client: Pick<PoolClient, 'query'>, event: OutboxEventInput): Promise<void> {
    await client.query(
      `INSERT INTO public.outbox_events
        (aggregate, aggregate_id, event_type, payload, request_id, actor_id, target_engine, target_resource, op, compensation_payload, idempotency_key)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, $9, $10::jsonb, $11)`,
      [
        event.aggregate,
        event.aggregateId,
        event.eventType,
        JSON.stringify(event.payload),
        this.uuidOrNull(event.requestId),
        this.uuidOrNull(event.actorId),
        event.targetEngine ?? null,
        event.targetResource ?? null,
        event.op ?? null,
        event.compensationPayload ? JSON.stringify(event.compensationPayload) : null,
        event.idempotencyKey ?? null,
      ],
    ).catch(async (error: unknown) => {
      if ((error as { code?: string }).code !== '42703') throw error;
      await client.query(
        `INSERT INTO public.outbox_events
          (aggregate, aggregate_id, event_type, payload, request_id, actor_id)
         VALUES ($1, $2, $3, $4::jsonb, $5, $6)`,
        [
          event.aggregate,
          event.aggregateId,
          event.eventType,
          JSON.stringify(event.payload),
          this.uuidOrNull(event.requestId),
          this.uuidOrNull(event.actorId),
        ],
      );
    });
  }

  private getPool(): Pool {
    if (!this.pool) {
      const connectionString = this.config.get<string>('DATABASE_URL');
      if (!connectionString) {
        this.logger.warn('DATABASE_URL missing; outbox emission disabled for this process');
        throw new Error('DATABASE_URL missing for outbox emission');
      }
      this.pool = new Pool({ connectionString, max: 2, idleTimeoutMillis: 30_000 });
    }
    return this.pool;
  }

  private aggregateId(input: QueryOutboxInput): string {
    const rowId = this.stringValue(input.result.rows[0]?.['id']);
    const dataId = this.stringValue(input.data?.['id']);
    const filterId = this.stringValue(input.filter?.['id']);
    return rowId ?? dataId ?? filterId ?? randomUUID();
  }

  private stringValue(value: unknown): string | undefined {
    if (typeof value === 'string' && value.length > 0) return value;
    if (typeof value === 'number' || typeof value === 'bigint') return value.toString();
    return undefined;
  }

  private targetValue(data: Record<string, unknown> | undefined, key: string): string | undefined {
    const value = data?.[key];
    if (typeof value === 'string' && value.length > 0) return value;
    const metadata = data?.['__baas'];
    if (metadata && typeof metadata === 'object' && !Array.isArray(metadata)) {
      const nested = (metadata as Record<string, unknown>)[key];
      if (typeof nested === 'string' && nested.length > 0) return nested;
    }
    return undefined;
  }

  private compensationPayload(data: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
    const value = data?.['compensation_payload'];
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
    return undefined;
  }

  private uuidOrNull(value?: string): string | null {
    return value && UUID_RE.test(value) ? value : null;
  }
}