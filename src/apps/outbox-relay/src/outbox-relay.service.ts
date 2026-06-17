/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   outbox-relay.service.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:40:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MongoService, PostgresService } from '@mini-baas/database';
import type { PoolClient, QueryResultRow } from 'pg';
import Redis from 'ioredis';
import { Counter, Gauge, register } from 'prom-client';
import { SagaCoordinatorService } from './saga-coordinator.service';

interface OutboxEventRow extends QueryResultRow {
  id: string;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: unknown;
  request_id: string | null;
  actor_id: string | null;
  attempts: number;
  target_engine: string | null;
  target_resource: string | null;
  op: string | null;
  compensation_payload: unknown;
  idempotency_key: string | null;
}

interface OrderProjection {
  _id: string;
  aggregate_id: string;
  [key: string]: unknown;
}

function gauge(name: string, help: string): Gauge<string> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Gauge) return existing;
  return new Gauge({ name, help });
}

function counter(name: string, help: string): Counter<string> {
  const existing = register.getSingleMetric(name);
  if (existing instanceof Counter) return existing;
  return new Counter({ name, help });
}

@Injectable()
export class OutboxRelayService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(OutboxRelayService.name);
  private readonly pollIntervalMs: number;
  private readonly batchSize: number;
  private readonly maxAttempts: number;
  private readonly dedupeTtlSeconds: number;
  private readonly realtimePublishUrl?: string;
  private readonly realtimePublishTimeoutMs: number;
  private redis!: Redis;
  private timer?: NodeJS.Timeout;
  private running = false;
  private readonly pendingGauge = gauge(
    'mini_baas_outbox_pending_events',
    'Pending or retryable outbox events waiting for relay publication.',
  );
  private readonly deadCounter = counter(
    'mini_baas_outbox_dead_events_total',
    'Outbox events marked dead by the relay.',
  );

  constructor(
    private readonly config: ConfigService,
    private readonly postgres: PostgresService,
    private readonly mongo: MongoService,
    private readonly saga: SagaCoordinatorService,
  ) {
    this.pollIntervalMs = this.config.get<number>('OUTBOX_RELAY_POLL_MS', 500);
    this.batchSize = this.config.get<number>('OUTBOX_RELAY_BATCH_SIZE', 25);
    this.maxAttempts = this.config.get<number>('OUTBOX_RELAY_MAX_ATTEMPTS', 5);
    this.dedupeTtlSeconds = this.config.get<number>('OUTBOX_RELAY_DEDUPE_TTL_SECONDS', 86_400);
    this.realtimePublishUrl = this.config.get<string>('REALTIME_PUBLISH_URL');
    this.realtimePublishTimeoutMs = this.config.get<number>('REALTIME_PUBLISH_TIMEOUT_MS', 1_000);
  }

  async onModuleInit(): Promise<void> {
    this.redis = new Redis(this.config.get<string>('REDIS_URL', 'redis://redis:6379'), {
      lazyConnect: true,
      enableOfflineQueue: false,
      maxRetriesPerRequest: 1,
    });
    await this.redis.connect();
    // Mongo is a soft dependency (lean tiers run without the container): the
    // relay's core job — pg outbox → Redis streams + realtime fan-out — must
    // not depend on the projection sink existing.
    if (this.mongo.isAvailable) {
      await this.mongo.getDb().collection<OrderProjection>('orders_view').createIndex({ aggregate_id: 1 });
    }
    this.timer = setInterval(() => void this.tick(), this.pollIntervalMs);
    this.timer.unref?.();
    await this.tick();
    this.logger.log('outbox relay started');
  }

  async onModuleDestroy(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    if (this.redis) await this.redis.quit();
  }

  isReady(): boolean {
    return this.redis?.status === 'ready';
  }

  private async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      const rows = await this.postgres.adminQuery<{ id: string }>(
        `SELECT id::text AS id
           FROM public.outbox_events
          WHERE status IN ('pending', 'failed') AND attempts < $1
          ORDER BY created_at ASC, id ASC
          LIMIT $2`,
        [this.maxAttempts, this.batchSize],
      );
      await this.updateLagMetric();
      for (const row of rows) await this.process(row.id);
    } catch (error) {
      this.logger.warn(`outbox relay tick failed: ${(error as Error).message}`);
    } finally {
      this.running = false;
    }
  }

  private async process(id: string): Promise<void> {
    const client = await this.postgres.getAdminClient();
    try {
      await client.query('BEGIN');
      const sagaColumns = await this.hasSagaColumns(client);
      const sagaSelect = sagaColumns
        ? 'target_engine, target_resource, op, compensation_payload, idempotency_key'
        : 'NULL::text AS target_engine, NULL::text AS target_resource, NULL::text AS op, NULL::jsonb AS compensation_payload, NULL::text AS idempotency_key';
      const result = await client.query<OutboxEventRow>(
        `SELECT id::text, aggregate, aggregate_id, event_type, payload, request_id::text, actor_id::text, attempts,
                ${sagaSelect}
           FROM public.outbox_events
          WHERE id = $1 AND status IN ('pending', 'failed') AND attempts < $2
          FOR UPDATE SKIP LOCKED`,
        [id, this.maxAttempts],
      );
      const event = result.rows[0];
      if (!event) {
        await client.query('COMMIT');
        return;
      }
      try {
        await this.publish(event);
        await this.project(event);
        await this.saga.dispatch(event);
        if (sagaColumns) {
          await client.query(
            `UPDATE public.outbox_events
                SET status = 'published', saga_state = 'dispatched', published_at = now(), last_error = NULL
              WHERE id = $1`,
            [event.id],
          );
        } else {
          await client.query(
            `UPDATE public.outbox_events
                SET status = 'published', published_at = now(), last_error = NULL
              WHERE id = $1`,
            [event.id],
          );
        }
      } catch (error) {
        await this.markFailed(client, event, error as Error, sagaColumns);
      }

      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      this.logger.warn(`outbox event ${id} failed: ${(error as Error).message}`);
    } finally {
      client.release();
    }
  }

  private async publish(event: OutboxEventRow): Promise<void> {
    const dedupeKey = `outbox-relay:published:${event.id}`;
    const published = await this.redis.get(dedupeKey);
    if (published) return;

    await this.redis.xadd(
      `outbox.${event.aggregate}`,
      '*',
      'id',
      event.id,
      'aggregate_id',
      event.aggregate_id,
      'event_type',
      event.event_type,
      'payload',
      JSON.stringify(this.payload(event)),
      'request_id',
      event.request_id ?? '',
      'actor_id',
      event.actor_id ?? '',
      'idempotency_key',
      event.idempotency_key ?? '',
    );
    await this.redis.set(dedupeKey, '1', 'EX', this.dedupeTtlSeconds);
    await this.publishRealtime(event).catch((error: Error) => {
      this.logger.warn(`realtime fan-out skipped for outbox event ${event.id}: ${error.message}`);
    });
  }

  private async publishRealtime(event: OutboxEventRow): Promise<void> {
    if (!this.realtimePublishUrl) return;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.realtimePublishTimeoutMs);
    try {
      const response = await fetch(this.realtimePublishUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          topic: `outbox/${event.aggregate}/${event.event_type}`,
          event_type: event.event_type,
          idempotency_key: event.idempotency_key ?? event.id,
          payload: {
            id: event.id,
            aggregate: event.aggregate,
            aggregate_id: event.aggregate_id,
            request_id: event.request_id,
            actor_id: event.actor_id,
            data: this.payload(event),
          },
        }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
    } finally {
      clearTimeout(timeout);
    }
  }

  private async project(event: OutboxEventRow): Promise<void> {
    if (event.aggregate !== 'order') return;
    const payload = this.payload(event);
    delete payload['_id'];
    await this.mongo.getDb().collection<OrderProjection>('orders_view').updateOne(
      { _id: event.aggregate_id },
      {
        $set: {
          ...payload,
          _id: event.aggregate_id,
          aggregate_id: event.aggregate_id,
          last_event_type: event.event_type,
          outbox_event_id: event.id,
          updated_at: new Date(),
        },
      },
      { upsert: true },
    );
  }

  private async markFailed(
    client: Pick<PoolClient, 'query'>,
    event: OutboxEventRow,
    error: Error,
    sagaColumns: boolean,
  ): Promise<void> {
    const nextAttempts = event.attempts + 1;
    const nextStatus = nextAttempts >= this.maxAttempts ? 'dead' : 'failed';
    if (nextStatus === 'dead') {
      this.deadCounter.inc();
      await this.saga.compensate(event);
    }
    if (!sagaColumns) {
      await client.query(
        `UPDATE public.outbox_events
            SET status = $2, attempts = $3, last_error = $4
          WHERE id = $1`,
        [event.id, nextStatus, nextAttempts, error.message.slice(0, 2000)],
      );
      return;
    }
    await client.query(
      `UPDATE public.outbox_events
          SET status = $2, saga_state = CASE WHEN $2 = 'dead' THEN 'dead' ELSE saga_state END, attempts = $3, last_error = $4
        WHERE id = $1`,
      [event.id, nextStatus, nextAttempts, error.message.slice(0, 2000)],
    );
  }

  private async hasSagaColumns(client: Pick<PoolClient, 'query'>): Promise<boolean> {
    const result = await client.query<{ count: string }>(
      `SELECT COUNT(*)::text AS count
         FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'outbox_events'
          AND column_name IN ('target_engine', 'target_resource', 'op', 'compensation_payload', 'idempotency_key', 'saga_state')`,
    );
    return result.rows[0]?.count === '6';
  }

  private payload(event: OutboxEventRow): Record<string, unknown> {
    if (event.payload && typeof event.payload === 'object' && !Array.isArray(event.payload)) {
      return { ...(event.payload as Record<string, unknown>) };
    }
    return { value: event.payload };
  }

  private async updateLagMetric(): Promise<void> {
    const rows = await this.postgres.adminQuery<{ count: string }>(
      `SELECT COUNT(*)::text AS count
         FROM public.outbox_events
        WHERE status IN ('pending', 'failed') AND attempts < $1`,
      [this.maxAttempts],
    );
    this.pendingGauge.set(Number(rows[0]?.count ?? 0));
  }
}