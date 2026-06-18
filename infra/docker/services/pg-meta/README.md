# Supabase pg-meta

Supabase pg-meta — PostgreSQL metadata REST API. Exposes database structure (tables, columns, schemas, roles, policies, extensions, etc.) as JSON endpoints, used by Supabase Studio and other management tools.

## Quick Start

```bash
docker compose up pg-meta
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_META_DB_HOST` | `postgres` | PostgreSQL hostname |
| `PG_META_DB_PORT` | `5432` | PostgreSQL port |
| `PG_META_DB_NAME` | `postgres` | Database name |
| `PG_META_DB_USER` | `postgres` | Database user |
| `PG_META_DB_PASSWORD` | — | Database password |
| `PG_META_PORT` | `8080` | HTTP server port |

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/tables` | List all tables |
| `GET` | `/columns` | List all columns |
| `GET` | `/schemas` | List all schemas |
| `GET` | `/roles` | List database roles |
| `GET` | `/policies` | List RLS policies |
| `GET` | `/extensions` | List installed extensions |
| `GET` | `/types` | List data types |
| `GET` | `/functions` | List functions |
| `GET` | `/triggers` | List triggers |
| `GET` | `/publications` | List publications |
| `GET` | `/health` | Health check |

## CLI Examples

```bash
# List all tables
curl -s http://localhost:8080/tables | jq .

# List tables in a specific schema
curl -s 'http://localhost:8080/tables?included_schemas=public' | jq .

# Get all columns
curl -s http://localhost:8080/columns | jq .

# List schemas
curl -s http://localhost:8080/schemas | jq .

# List roles
curl -s http://localhost:8080/roles | jq .

# List RLS policies
curl -s http://localhost:8080/policies | jq .

# List installed extensions
curl -s http://localhost:8080/extensions | jq .

# List functions
curl -s http://localhost:8080/functions | jq .
```

## Health Check

```bash
curl -sf http://localhost:8080/health
```

Returns `200 OK` when the service can reach PostgreSQL.

## Docker

- **Image:** `supabase/postgres-meta`
- **Port:** `8080`
- **Depends on:** `postgres`
- **Networks:** Internal `baas` network
