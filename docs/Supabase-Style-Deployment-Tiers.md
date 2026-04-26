# Supabase-Style Deployment Tiers

This guide defines how mini-BaaS should be run and deployed now that the stack is split by criticality instead of treating every container as equally hot-path.

## Rule

Everything can run in Docker, but not every service belongs to the same runtime tier.

The default Compose stack now starts only the critical BaaS path. Optional planes are enabled with Compose profiles.

## Tier model

```text
                 WAF
                  ↓
             Kong Gateway
                  ↓
        ┌─────────┼─────────┐
        ↓                   ↓
   BaaS CORE           CONTROL / ADAPTER PLANE
(Postgres, PostgREST,   (Vault, pg-meta, Supavisor,
 GoTrue, Realtime,       Adapter Registry, Permission Engine,
 Redis)                  Schema Service, Query Router)
        ↓
   DATA / ANALYTICS PLANE
 (Mongo, MinIO, Trino, analytics, AI)
        ↓
   BACKGROUND / OBSERVABILITY
 (email, newsletter, GDPR, logs, Prometheus, Grafana, Loki)
```

## Compose profiles

| Profile | Purpose | Typical services |
| ------- | ------- | ---------------- |
| default | Critical BaaS hot path | `waf`, `kong`, `postgres`, `postgrest`, `gotrue`, `realtime`, `redis` |
| `adapter-plane` | Normalized SQL/NoSQL API path | `query-router`, `adapter-registry`, `permission-engine` |
| `control-plane` | Rare/admin/platform operations | `vault`, `pg-meta`, `supavisor`, `schema-service`, `studio` |
| `data-plane` | Secondary data stores/adapters | `mongo`, `mongo-api`, `minio`, `storage-router`, `trino` |
| `analytics` | OLAP/reporting only | `trino`, `analytics-service` |
| `storage` | Object storage | `minio`, `storage-router` |
| `background` | Async/non-critical product services | `email-service`, `newsletter-service`, `gdpr-service`, `ai-service`, `log-service`, `session-service` |
| `observability` | Metrics/log dashboards | `prometheus`, `grafana`, `loki`, `promtail`, `log-service` |

## Startup modes

### Minimal Supabase-like core

```sh
docker compose up -d
```

Starts only:

- WAF
- Kong
- PostgreSQL
- PostgREST
- GoTrue
- Realtime PostgreSQL CDC
- Redis

This is the latency-critical path.

### Core + normalized data API

```sh
docker compose --profile adapter-plane up -d
```

Adds:

- `query-router`
- `adapter-registry`
- `permission-engine`

Use this when the SDK normalized data API is needed. The query-router remains an adapter-plane orchestrator with cache, coalescing, and circuit breakers.

### Core + secondary data plane

```sh
docker compose --profile data-plane up -d
```

Adds MongoDB, MinIO/storage router, Trino, analytics, and AI data-plane services. This should not be required for the default BaaS request path.

### Full local platform

```sh
docker compose \
  --profile adapter-plane \
  --profile control-plane \
  --profile data-plane \
  --profile analytics \
  --profile storage \
  --profile background \
  --profile observability \
  up -d
```

Use this for local integration testing, demos, or platform development. Do not treat this mode as the production critical path.

## Runtime placement rules

### Hot path

Keep close and simple:

```text
WAF → Kong → GoTrue/PostgREST/Realtime → PostgreSQL/Redis
```

Rules:

- Keep Kong as the only public entrypoint.
- Keep PostgREST and GoTrue close to PostgreSQL.
- Keep Realtime PostgreSQL CDC in the core path.
- Do not route core CRUD through Trino.
- Do not require Vault, pg-meta, MongoDB, MinIO, or analytics services for basic CRUD/auth/realtime.

### Adapter plane

Use only for normalized multi-engine data access:

```text
Kong → query-router → permission-engine / adapter-registry → DB adapter
```

Rules:

- `permission-engine` is server-authoritative.
- `adapter-registry` remains control-plane metadata, not a hot execution service.
- Query-router uses L1 cache, optional Redis L2, coalescing, and circuit breakers.
- If the adapter plane is down, core PostgREST CRUD can still stay alive.

### Control plane

Use rarely:

- Vault at boot/CI/secret provisioning, not every request.
- pg-meta and schema-service for admin/DDL flows.
- Supavisor physically/logically close to PostgreSQL.
- Studio only for admin UI.

### Data and analytics plane

Keep isolated:

- MongoDB is secondary data-plane storage.
- MinIO/storage is object storage, not relational CRUD.
- Trino is analytics/federation only.
- Analytics/AI/background services should not block auth or CRUD.

## Redis usage split

Redis is core infrastructure, but usage must stay separated by key namespace:

| Usage | Prefix | Notes |
| ----- | ------ | ----- |
| Query-router cache | `query-router:` | L2 read-through/shared cache |
| Realtime/events | `realtime:` | Future pub/sub or stream usage |
| Background queues | `queue:` | Future worker queue namespace |
| Sessions/rate limit | `session:` / `rate:` | Short TTL only |

Do not turn Redis into an unstructured shared bucket.

## Production scaling order

1. Scale Kong/WAF first for ingress.
2. Scale PostgREST/GoTrue with PostgreSQL pooling.
3. Place Supavisor near PostgreSQL before aggressive API scaling.
4. Scale query-router horizontally only with Redis L2 enabled.
5. Scale Mongo/MinIO/Trino independently from the core BaaS path.
6. Scale observability/background workers separately.

## What changed in Compose

- Default stack is no longer flat.
- `docker compose up -d` starts only the core BaaS path.
- Query-router and its dependencies moved behind `adapter-plane`.
- Mongo/MinIO/Trino moved behind data/analytics/storage profiles.
- Vault/pg-meta/Supavisor/schema-service moved behind `control-plane`.
- Background and observability services are opt-in.
- Realtime no longer requires MongoDB by default; PostgreSQL realtime remains core.
- Kong no longer waits for every optional upstream before becoming healthy.
