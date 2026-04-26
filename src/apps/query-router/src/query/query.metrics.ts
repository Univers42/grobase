import { Injectable } from '@nestjs/common';
import { InjectMetric } from '@willsoto/nestjs-prometheus';
import { Counter, Histogram } from 'prom-client';

type CacheEvent = 'hit' | 'miss' | 'set' | 'invalidate';
type RequestStatus = 'success' | 'error';
type AsyncEventStatus = 'queued' | 'flushed' | 'failed' | 'dropped';

@Injectable()
export class QueryMetricsService {
  constructor(
    @InjectMetric('query_router_cache_events_total')
    private readonly cacheEvents: Counter<string>,
    @InjectMetric('query_router_phase_duration_seconds')
    private readonly phaseDuration: Histogram<string>,
    @InjectMetric('query_router_requests_total')
    private readonly requests: Counter<string>,
    @InjectMetric('query_router_permission_denied_total')
    private readonly permissionDenied: Counter<string>,
    @InjectMetric('query_router_coalesced_requests_total')
    private readonly coalescedRequests: Counter<string>,
    @InjectMetric('query_router_async_events_total')
    private readonly asyncEvents: Counter<string>,
  ) {}

  recordCache(cache: string, result: CacheEvent): void {
    this.cacheEvents.inc({ cache, result });
  }

  recordRequest(engine: string, action: string, status: RequestStatus): void {
    this.requests.inc({ engine, action, status });
  }

  recordPermissionDenied(resourceType: string, action: string): void {
    this.permissionDenied.inc({ resource_type: resourceType, action });
  }

  recordCoalesced(scope: string): void {
    this.coalescedRequests.inc({ scope });
  }

  recordAsyncEvent(status: AsyncEventStatus): void {
    this.asyncEvents.inc({ status });
  }

  async observe<T>(phase: string, engine: string, action: string, operation: () => Promise<T>): Promise<T> {
    const end = this.phaseDuration.startTimer({ phase, engine, action });
    try {
      return await operation();
    } finally {
      end();
    }
  }
}
