import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MongoService, PostgresService } from '@mini-baas/database';
import Redis from 'ioredis';

export interface SagaEvent {
  id: string;
  aggregate: string;
  aggregate_id: string;
  event_type: string;
  payload: unknown;
  request_id: string | null;
  actor_id: string | null;
  target_engine: string | null;
  target_resource: string | null;
  op: string | null;
  compensation_payload: unknown;
  idempotency_key: string | null;
}

interface MongoProjectionDoc {
  _id: string;
  [key: string]: unknown;
}

@Injectable()
export class SagaCoordinatorService implements OnModuleDestroy {
  private readonly logger = new Logger(SagaCoordinatorService.name);
  private redis?: Redis;

  constructor(
    private readonly config: ConfigService,
    private readonly mongo: MongoService,
    private readonly postgres: PostgresService,
  ) {}

  async onModuleDestroy(): Promise<void> {
    if (this.redis) await this.redis.quit();
  }

  async dispatch(event: SagaEvent): Promise<void> {
    if (!event.target_engine || !event.target_resource) return;
    switch (event.target_engine) {
      case 'mongodb':
        await this.dispatchMongo(event);
        return;
      case 'redis':
      case 'cassandra':
      case 'elasticsearch':
      case 'qdrant':
      case 'influx':
      case 'http':
      case 'jdbc':
      case 'neo4j':
        await this.dispatchStream(event);
        return;
      default:
        throw new Error(`Unsupported saga target engine: ${event.target_engine}`);
    }
  }

  async compensate(event: SagaEvent): Promise<void> {
    const compensation = this.objectPayload(event.compensation_payload);
    if (!compensation) return;
    await this.postgres.adminQuery(
      `INSERT INTO public.outbox_events
        (aggregate, aggregate_id, event_type, payload, request_id, actor_id, status, saga_state)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6, 'pending', 'compensating')`,
      [
        event.aggregate,
        event.aggregate_id,
        `${event.event_type}.compensate`,
        JSON.stringify(compensation),
        event.request_id,
        event.actor_id,
      ],
    );
    this.logger.warn(`scheduled compensation for outbox event ${event.id}`);
  }

  private async dispatchMongo(event: SagaEvent): Promise<void> {
    if (!this.mongo.isAvailable) {
      // Deployment has no mongo (lean tier): the canonical pg write is already
      // committed and there is no projection target to fulfil. Skip loudly —
      // throwing would mark the event failed and eventually COMPENSATE a
      // perfectly good write.
      this.logger.warn(
        `mongo projection skipped for outbox event ${event.id} (${event.target_resource ?? event.aggregate}): MongoDB unavailable`,
      );
      return;
    }
    const payload = this.objectPayload(event.payload);
    if (!payload) return;
    const data = this.objectPayload(payload['data']) ?? payload;
    const collection = this.mongo.getDb().collection<MongoProjectionDoc>(event.target_resource ?? event.aggregate);
    if (event.op === 'delete') {
      await collection.deleteOne({ _id: event.aggregate_id });
      return;
    }
    await collection.updateOne(
      { _id: event.aggregate_id },
      {
        $set: {
          ...data,
          aggregate_id: event.aggregate_id,
          outbox_event_id: event.id,
          request_id: event.request_id,
          updated_at: new Date(),
        },
      },
      { upsert: true },
    );
  }

  private async dispatchStream(event: SagaEvent): Promise<void> {
    const redis = await this.getRedis();
    await redis.xadd(
      `saga.${event.target_engine}.${event.target_resource}`,
      '*',
      'id',
      event.id,
      'aggregate_id',
      event.aggregate_id,
      'op',
      event.op ?? '',
      'payload',
      JSON.stringify(event.payload ?? {}),
      'request_id',
      event.request_id ?? '',
      'actor_id',
      event.actor_id ?? '',
      'idempotency_key',
      event.idempotency_key ?? '',
    );
  }

  private async getRedis(): Promise<Redis> {
    if (!this.redis) {
      this.redis = new Redis(this.config.get<string>('OUTBOX_REDIS_URL', 'redis://redis:6379'), {
        lazyConnect: true,
        enableOfflineQueue: false,
        maxRetriesPerRequest: 1,
      });
      await this.redis.connect();
    }
    return this.redis;
  }

  private objectPayload(value: unknown): Record<string, unknown> | undefined {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
    return undefined;
  }
}