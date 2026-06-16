# Kong API Gateway

Kong 3.8 API Gateway running in **declarative mode** (no database). Acts as the single entry point for all BaaS services, routing requests to the appropriate upstream based on path prefix.

## Quick Start

```bash
docker compose up kong
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KONG_DATABASE` | `off` | Disables database; uses declarative config |
| `KONG_DECLARATIVE_CONFIG` | `/var/lib/kong/kong.yml` | Path to the declarative YAML config |
| `KONG_DNS_ORDER` | `LAST,A,SRV` | DNS resolution order for service discovery |
| `KONG_PROXY_ACCESS_LOG` | `/dev/stdout` | Access log output |
| `KONG_PROXY_ERROR_LOG` | `/dev/stderr` | Error log output |
| `KONG_ADMIN_ACCESS_LOG` | `/dev/stdout` | Admin API access log |
| `KONG_ADMIN_ERROR_LOG` | `/dev/stderr` | Admin API error log |
| `KONG_ADMIN_LISTEN` | `0.0.0.0:8001` | Admin API listen address |

## Routes

| Path | Upstream | Description |
|------|----------|-------------|
| `/auth/v1` | GoTrue | Authentication service |
| `/rest/v1` | PostgREST | PostgreSQL REST API |
| `/realtime/v1` | Realtime | WebSocket server |
| `/storage/v1` | MinIO | Object storage |
| `/meta/v1` | pg-meta | PostgreSQL metadata |
| `/mongo/v1` | mongo-api | MongoDB REST API |
| `/admin/v1/databases` | adapter-registry | Database credential management |
| `/query/v1` | query-router | Universal query gateway |
| `/sql` | Trino | Distributed SQL engine |
| `/studio` | Studio | Admin dashboard |

## Plugins

- **cors** — Cross-origin resource sharing headers
- **correlation-id** — Adds a unique request ID to each request
- **response-transformer** — Modifies response headers
- **key-auth** — API key authentication via `apikey` header
- **rate-limiting** — Request rate limiting per consumer/IP

## Endpoints

| Port | Protocol | Description |
|------|----------|-------------|
| `8000` | HTTP | Proxy (client-facing) |
| `8443` | HTTPS | SSL proxy |
| `8001` | HTTP | Admin API |

## CLI Examples

**Check gateway status:**

```bash
curl http://localhost:8001/status
```

**List all configured routes:**

```bash
curl http://localhost:8001/routes
```

**Query PostgREST through Kong (anonymous):**

```bash
curl http://localhost:8000/rest/v1/todos \
  -H "apikey: YOUR_ANON_KEY"
```

**Sign up via GoTrue through Kong:**

```bash
curl -X POST http://localhost:8000/auth/v1/signup \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"secret123"}'
```

**Query MongoDB through Kong:**

```bash
curl http://localhost:8000/mongo/v1/collections/items/documents \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_JWT"
```

**Query through the universal router:**

```bash
curl http://localhost:8000/query/v1/DB_ID/tables/users \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_JWT"
```

## Health Check

```bash
curl http://localhost:8001/status
```

Expected response includes `database.reachable` and `server` status fields.

## Docker

- **Image:** `kong:3.8`
- **Mode:** Declarative (DB-less)
- **Config mount:** `./docker/services/kong/kong.yml:/var/lib/kong/kong.yml`
- **Ports:** `8000:8000`, `8443:8443`, `8001:8001`
