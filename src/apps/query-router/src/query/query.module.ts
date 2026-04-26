import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { makeCounterProvider, makeHistogramProvider } from '@willsoto/nestjs-prometheus';
import { QueryController } from './query.controller';
import { QueryService } from './query.service';
import { AdapterRegistryClient } from './adapter-registry.client';
import { PermissionClient } from './permission.client';
import { QueryCacheService } from './query-cache.service';
import { QueryMetricsService } from './query.metrics';
import { AsyncEventService } from './async-event.service';
import { PostgresqlEngine } from '../engines/postgresql.engine';
import { MongodbEngine } from '../engines/mongodb.engine';

@Module({
  imports: [ConfigModule, HttpModule],
  controllers: [QueryController],
  providers: [
    QueryService,
    AdapterRegistryClient,
    PermissionClient,
    QueryCacheService,
    QueryMetricsService,
    AsyncEventService,
    PostgresqlEngine,
    MongodbEngine,
    makeCounterProvider({
      name: 'query_router_cache_events_total',
      help: 'Query router cache events grouped by cache tier and result',
      labelNames: ['cache', 'result'],
    }),
    makeHistogramProvider({
      name: 'query_router_phase_duration_seconds',
      help: 'Query router latency by execution phase',
      labelNames: ['phase', 'engine', 'action'],
      buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    }),
    makeCounterProvider({
      name: 'query_router_requests_total',
      help: 'Query router requests grouped by engine, action, and status',
      labelNames: ['engine', 'action', 'status'],
    }),
    makeCounterProvider({
      name: 'query_router_permission_denied_total',
      help: 'Permission denials enforced by the query router',
      labelNames: ['resource_type', 'action'],
    }),
    makeCounterProvider({
      name: 'query_router_coalesced_requests_total',
      help: 'Requests served by in-flight request coalescing',
      labelNames: ['scope'],
    }),
    makeCounterProvider({
      name: 'query_router_async_events_total',
      help: 'Non-blocking query-router async event queue outcomes',
      labelNames: ['status'],
    }),
  ],
})
export class QueryModule {}
