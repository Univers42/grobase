# PostgreSQL

PostgreSQL 16 (Alpine) — primary relational database for all Supabase services. Stores authentication data, application schemas, and metadata.

## Quick Start

```bash
docker compose up postgres
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PASSWORD` | — | Superuser password (required) |
| `POSTGRES_DB` | `postgres` | Default database name |
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_HOST_AUTH_METHOD` | `md5` | Host authentication method |
| `POSTGRES_INITDB_ARGS` | — | Extra `initdb` arguments |

## Ports

| Port | Description |
|------|-------------|
| `5432` | PostgreSQL wire protocol |

## Volumes

| Volume | Mount Point | Description |
|--------|------------|-------------|
| `postgres-data` | `/var/lib/postgresql/data` | Persistent database storage |

## CLI Examples

```bash
# Connect interactively
docker compose exec postgres psql -U postgres

# Connect from host (if port is exposed)
psql -h localhost -p 5432 -U postgres -d postgres

# List databases
docker compose exec postgres psql -U postgres -c '\l'

# List tables in public schema
docker compose exec postgres psql -U postgres -c '\dt public.*'

# Run a SQL file
docker compose exec -T postgres psql -U postgres < scripts/db-bootstrap.psql

# Run a migration
cat scripts/migrations/postgresql/001_init.sql | \
  docker compose exec -T postgres psql -U postgres

# Backup (pg_dump)
docker compose exec postgres pg_dump -U postgres --format=custom postgres \
  > backup_$(date +%Y%m%d).dump

# Restore
docker compose exec -T postgres pg_restore -U postgres -d postgres \
  < backup_20260405.dump

# Check active connections
docker compose exec postgres psql -U postgres -c \
  "SELECT pid, usename, application_name, state FROM pg_stat_activity;"
```

## Health Check

```bash
docker compose exec postgres pg_isready -U postgres
```

Returns exit code `0` and prints `accepting connections` when healthy.

## Docker

- **Image:** `postgres:16-alpine`
- **Port:** `5432`
- **Volumes:** `postgres-data:/var/lib/postgresql/data`
- **Init scripts:** SQL files in `/docker-entrypoint-initdb.d/` run on first start
- **Networks:** Internal `baas` network
