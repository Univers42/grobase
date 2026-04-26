# SDK Backend Service Coverage

The frontend application talks to `@mini-baas/js`. The SDK talks to the public BaaS HTTP API. The public API is Kong locally, and Kong/WAF in hardened deployments. Microservices stay private.

```text
Frontend app
  ↓
@mini-baas/js
  ↓
HTTP API edge: WAF/Kong
  ↓
Private Docker/Fly services
```

## Coverage matrix

| Runtime service      | Gateway exposure                             | SDK surface                                                    | Notes                                                                         |
| -------------------- | -------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `waf`                | Transparent public edge                      | `platform.health()` for `/waf-health` when WAF is the base URL | Security layer, not a domain API                                              |
| `kong`               | Public API edge                              | every SDK call                                                 | Gateway routes remain private SDK implementation details                      |
| `gotrue`             | `/auth/v1`                                   | `auth.*`                                                       | Signup/signin/token/user/session auth flow                                    |
| `postgrest`          | `/rest/v1`                                   | `rest.from()`, `rest.rpc()`                                    | Relational REST API                                                           |
| `realtime`           | `/realtime/v1`, `/realtime/v1/ws`            | `realtimeUrl()`                                                | WebSocket URL builder                                                         |
| `minio`              | `/storage/v1` and storage-router signed URLs | `storage.presign()`                                            | Direct S3 credentials stay private                                            |
| `pg-meta`            | `/meta/v1`                                   | `meta.*`                                                       | Metadata API; protected by gateway policy                                     |
| `mongo-api`          | `/mongo/v1`                                  | `mongo.*`                                                      | Document API and schema/index helpers                                         |
| `adapter-registry`   | `/admin/v1`                                  | `admin.*`                                                      | Database registry helpers                                                     |
| `query-router`       | `/query/v1`                                  | `data.database(id).from()`, `query.*`                          | Normalized SQL/NoSQL resource API and advanced query API                      |
| `trino`              | `/sql`                                       | `sql.query()`                                                  | Analytics/federated SQL only; not transactional CRUD                          |
| `studio`             | `/studio`                                    | no data wrapper                                                | Browser UI route, not an SDK data API                                         |
| `email-service`      | `/email/v1`                                  | `email.send()`                                                 | Email dispatch                                                                |
| `storage-router`     | `/storage/v1/sign`                           | `storage.presign()`                                            | Signed upload/download URLs                                                   |
| `permission-engine`  | `/permissions/v1`                            | `permissions.*`                                                | RBAC/permission checks and policies                                           |
| `schema-service`     | `/schemas/v1`                                | `schemas.*`                                                    | Application schema lifecycle                                                  |
| `analytics-service`  | `/analytics/v1`                              | `analytics.track()`                                            | Event ingestion; stats endpoints can be added next                            |
| `gdpr-service`       | `/gdpr/v1`                                   | `gdpr.*`                                                       | Export, consent, deletion requests                                            |
| `newsletter-service` | `/newsletter/v1`                             | `newsletter.*`                                                 | Subscriptions and campaigns                                                   |
| `ai-service`         | `/ai/v1`                                     | `ai.*`                                                         | Chat and conversation helpers                                                 |
| `log-service`        | `/logs/v1`                                   | `logs.*`                                                       | Log ingest/query/stats                                                        |
| `session-service`    | `/sessions/v1`                               | `sessions.*`                                                   | Application session management                                                |
| `redis`              | Internal only                                | `platform.capabilities().redis === "internal"`                 | Cache/pub-sub infra; should be accessed by backend services, not frontend SDK |
| `vault`              | Internal only                                | `platform.capabilities().vault === "internal"`                 | Secret manager; never expose directly to browsers                             |
| `supavisor`          | Internal only                                | `platform.capabilities().supavisor === "internal"`             | PostgreSQL pooler; used by backend services                                   |

## Fly compatibility

The Fly deployment map in [deploy/fly/services.env](../deploy/fly/services.env) is compatible with this SDK model: each private service has an internal app, and the SDK talks only to the gateway app URL.

The Kong renderer in [deploy/fly/render-kong-config.sh](../deploy/fly/render-kong-config.sh) rewrites local Compose upstream names to Fly `.internal` DNS names without changing the SDK public API.

## Rule

If a Docker utility should be used by frontend applications, expose it through Kong and add a domain method in the SDK. If it is infrastructure-sensitive, keep it internal and consume it from backend services only.

## Normalized mutation guarantee

The SDK now has two data surfaces:

- `baas.from()` / `baas.rest.from()` for the primary PostgREST relational API.
- `baas.data.database(id).from(resource)` for registered SQL or NoSQL databases through adapter-registry + query-router.

`baas.data` keeps the product verbs stable (`select`, `insert`, `update`, `delete`) and sends those intentions to query-router. The backend resolves the registered database engine, checks permissions through permission-engine, then maps the intent to PostgreSQL or MongoDB adapter actions.

This preserves the database-normalization goal without pretending SQL and NoSQL have identical internal semantics. Frontend code gets a unified intent API; backend services keep ownership of validation, authorization, routing, engine translation, PostgreSQL RLS context, and MongoDB owner filters.

Trino remains outside the transactional mutation path. Use it for analytics and cross-source federation, not CRUD writes or authorization decisions.
