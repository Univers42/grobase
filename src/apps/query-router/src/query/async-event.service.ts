import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { QueryMetricsService } from './query.metrics';

type AsyncEventLevel = 'debug' | 'info' | 'warn' | 'error';

export interface AsyncQueryEvent {
  type: string;
  level?: AsyncEventLevel;
  message: string;
  metadata: Record<string, unknown>;
}

@Injectable()
export class AsyncEventService implements OnModuleDestroy {
  private readonly logger = new Logger(AsyncEventService.name);
  private readonly queue: AsyncQueryEvent[] = [];
  private readonly enabled: boolean;
  private readonly logServiceUrl: string;
  private readonly flushIntervalMs: number;
  private readonly batchSize: number;
  private readonly maxEntries: number;
  private readonly timer: NodeJS.Timeout;
  private flushing = false;

  constructor(
    private readonly config: ConfigService,
    private readonly http: HttpService,
    private readonly metrics: QueryMetricsService,
  ) {
    this.enabled = this.config.get<string>('QUERY_ROUTER_ASYNC_EVENTS_ENABLED', 'true') !== 'false';
    this.logServiceUrl = this.config.get<string>('LOG_SERVICE_URL', 'http://log-service:3110');
    this.flushIntervalMs = this.config.get<number>('QUERY_ROUTER_ASYNC_EVENT_FLUSH_MS', 1_000);
    this.batchSize = this.config.get<number>('QUERY_ROUTER_ASYNC_EVENT_BATCH_SIZE', 25);
    this.maxEntries = this.config.get<number>('QUERY_ROUTER_ASYNC_EVENT_MAX_ENTRIES', 1_000);
    this.timer = setInterval(() => void this.flush(), this.flushIntervalMs);
    this.timer.unref?.();
  }

  enqueue(event: AsyncQueryEvent): void {
    if (!this.enabled) return;

    if (this.queue.length >= this.maxEntries) {
      this.queue.shift();
      this.metrics.recordAsyncEvent('dropped');
    }

    this.queue.push(event);
    this.metrics.recordAsyncEvent('queued');
  }

  async flush(): Promise<void> {
    if (!this.enabled || this.flushing || this.queue.length === 0) return;

    this.flushing = true;
    const batch = this.queue.splice(0, this.batchSize);

    try {
      await Promise.all(
        batch.map((event) =>
          firstValueFrom(
            this.http.post(
              `${this.logServiceUrl}/logs/ingest`,
              {
                level: event.level ?? 'info',
                source: 'query-router',
                message: event.message,
                metadata: {
                  type: event.type,
                  emitted_at: new Date().toISOString(),
                  ...event.metadata,
                },
              },
              { timeout: 1_000 },
            ),
          ),
        ),
      );
      this.metrics.recordAsyncEvent('flushed');
    } catch (error) {
      this.metrics.recordAsyncEvent('failed');
      this.logger.debug(`Async event flush failed: ${error instanceof Error ? error.message : String(error)}`);
      this.queue.unshift(...batch.slice(0, Math.max(0, this.maxEntries - this.queue.length)));
    } finally {
      this.flushing = false;
    }
  }

  async onModuleDestroy(): Promise<void> {
    clearInterval(this.timer);
    await this.flush();
  }
}
