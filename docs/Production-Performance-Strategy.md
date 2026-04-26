# Production Performance Strategy

This document defines the next production layer for mini-BaaS: cache, routing, failover, observability, API versioning, and Trino optimization.

## Mental model

```text
SDK
  ↓ intent only
Kong / WAF
  ↓ auth, rate limits, request IDs
Query Router
  ↓ orchestration, cache, timeout, retry
Permission Engine / Adapter Registry
  ↓ control-plane decisions
Adapter Layer
  ↓ execution
PostgreSQL / MongoDB / Trino
```

The SDK remains a UX layer. The query-router is an orchestrator, not an all-powerful monolith. Permission checks, database mapping, and execution are delegated to dedicated services/layers.

## Query-router performance controls

Implemented controls:

| Control                   | Environment variable                   | Default | Purpose                                                  |
| ------------------------- | -------------------------------------- | ------- | -------------------------------------------------------- |
| Control-plane timeout     | `CONTROL_PLANE_TIMEOUT_MS`             | `2000`  | Bound latency to permission-engine and adapter-registry  |
| Control-plane retries     | `CONTROL_PLANE_RETRY_ATTEMPTS`         | `2`     | Retry transient control-plane failures                   |
| Adapter metadata cache    | `QUERY_ROUTER_ADAPTER_CACHE_TTL_MS`    | `30000` | Avoid repeated adapter-registry lookups                  |
| Permission decision cache | `QUERY_ROUTER_PERMISSION_CACHE_TTL_MS` | `5000`  | Reduce authZ latency while keeping short-lived decisions |
| Read-result cache         | `QUERY_ROUTER_READ_CACHE_TTL_MS`       | `3000`  | Absorb repeated read bursts                              |
| Cache max entries         | `QUERY_ROUTER_CACHE_MAX_ENTRIES`       | `2000`  | Bound memory usage                                       |
| Async event queue         | `QUERY_ROUTER_ASYNC_EVENTS_ENABLED`    | `true`  | Keep logs/analytics out of the synchronous request path  |
| Async flush interval      | `QUERY_ROUTER_ASYNC_EVENT_FLUSH_MS`    | `1000`  | Batch non-critical event emission                        |
| Async batch size          | `QUERY_ROUTER_ASYNC_EVENT_BATCH_SIZE`  | `25`    | Bound each background flush                              |
| Async queue max entries   | `QUERY_ROUTER_ASYNC_EVENT_MAX_ENTRIES` | `1000`  | Drop oldest events before impacting request latency      |

These are intentionally conservative. Reads can be cached briefly; writes invalidate cached read results for the same user/database/resource prefix.

The router also coalesces identical in-flight reads. If 100 identical cache-miss reads arrive at the same time, only the first one hits the adapter/DB; the remaining callers await the same promise and receive the same result.

## Cache levels

### Level 1 — in-process cache

Current implementation. Good for single instance and low-latency bursts.

Cached data:

- adapter registry connection metadata
- permission decisions
- read query results
- table/collection listings

Stampede protection:

- adapter-registry lookups are coalesced per user/database
- permission checks are coalesced per user/resource/action
- read queries are coalesced per user/database/resource/filter/sort/page
- table listings are coalesced per user/database/engine

### Level 2 — Redis cache

Recommended next production step when multiple query-router instances run. Redis should become the shared L2 cache for:

- permission decisions
- adapter metadata
- schema/table metadata
- optionally read-through query results for safe read-only workloads

Rules:

- never cache writes
- never cache service secrets in frontend-accessible payloads
- cache permission decisions with short TTL only
- invalidate read caches on mutations

## Routing and failover

### Gateway layer

Kong is responsible for:

- route selection
- authentication plugin enforcement
- rate limiting
- correlation/request ID propagation
- upstream health visibility

### Query-router layer

Query-router is responsible for:

- translating product actions to backend action names
- calling permission-engine server-side
- resolving database engine through adapter-registry
- delegating execution to the adapter layer
- enforcing control-plane timeouts and bounded retries
- coalescing identical in-flight reads
- emitting non-critical logs/events asynchronously

The router now emits structured background events to log-service through a bounded in-memory queue. Request latency is never blocked by log ingestion; if the queue is full, oldest events are dropped and counted by metrics.

### Fly.io layer

Use multi-app Fly deployment with gateway public and all services private over `.internal` DNS. Gateway should scale before private services. Query-router can scale horizontally once Redis-backed cache is added.

## Observability

Minimum production signals:

- `X-Request-ID` from Kong through every service
- query-router latency by phase:
  - adapter-registry lookup
  - permission-engine check
  - adapter execution
  - total request time
- cache hit/miss counters
- permission denied counters
- adapter error counters by engine
- Trino query duration and failure counters

Existing stack components:

- Prometheus: metrics collection
- Grafana: dashboards
- Loki/Promtail: logs
- Kong Prometheus plugin: gateway metrics

Implemented query-router metrics:

- `query_router_phase_duration_seconds{phase,engine,action}`
- `query_router_cache_events_total{cache,result}`
- `query_router_requests_total{engine,action,status}`
- `query_router_permission_denied_total{resource_type,action}`
- `query_router_coalesced_requests_total{scope}`
- `query_router_async_events_total{status}`

## API versioning

Rules:

- Gateway paths remain versioned: `/auth/v1`, `/query/v1`, `/permissions/v1`, etc.
- SDK public methods must not expose route paths.
- Breaking backend changes require a new gateway path version and SDK compatibility layer.
- SDK should send product actions (`read`, `create`, `update`, `delete`), not engine-specific actions.

## Trino optimization rules

Trino is not the CRUD path. It is for:

- analytics
- federation
- read-heavy cross-source queries
- OLAP-style workloads

Never use Trino for:

- transactional writes
- authZ decisions
- business logic ownership
- live CRUD mutation paths

Recommended production settings:

- keep SDK `sql.query()` read-only by default
- add server-side query allowlists for public analytics endpoints
- enforce statement timeouts
- separate Trino workloads from transactional API workloads
- consider materialized views or pre-aggregated tables for repeated dashboards

Implemented safeguards:

- Kong `/sql` route is restricted to the `service_role` consumer through ACL.
- Kong applies tighter `/sql` rate limits and request-size limits.
- Trino has bounded execution/runtime/client timeouts in its local config.

## Performance roadmap

1. In-process query-router cache and control-plane timeouts/retries — implemented.
2. Query-router Prometheus phase/cache/request metrics — implemented.
3. Request coalescing for hot repeated reads/control-plane calls — implemented.
4. Non-blocking async event queue to log-service — implemented.
5. Trino gateway hardening and timeouts — implemented.
6. Redis L2 shared cache for multi-instance deployments.
7. Circuit breakers for permission-engine and adapter-registry.
8. Per-route Kong rate limits by plan/project.
9. Server-side analytics query allowlists.
10. API version compatibility tests.
