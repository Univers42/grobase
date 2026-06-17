# Supavisor

Supavisor — Elixir-based PostgreSQL connection pooler built by Supabase. Efficiently multiplexes client connections to PostgreSQL, reducing connection overhead and improving scalability.

## Quick Start

```bash
docker compose up supavisor
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | PostgreSQL connection string for the pooler to connect to |
| `PORT` | `6543` | Port the pooler listens on |
| `POOL_SIZE` | `20` | Default connection pool size |
| `SECRET_KEY_BASE` | — | Phoenix secret key base |
| `VAULT_ENC_KEY` | — | Encryption key for stored credentials |
| `API_JWT_SECRET` | — | JWT secret for API authentication |
| `METRICS_JWT_SECRET` | — | JWT secret for metrics endpoint |
| `REGION` | `local` | Deployment region identifier |
| `FLY_ALLOC_ID` | — | Fly.io allocation ID (can be any unique string locally) |

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| `6543` | PostgreSQL | Connection pooler (use like a normal PG connection) |

## CLI Examples

```bash
# Connect through Supavisor (acts like a PostgreSQL proxy)
psql -h localhost -p 6543 -U postgres -d postgres

# Test from application code — just change the port from 5432 to 6543
# Connection string: postgres://postgres:<password>@localhost:6543/postgres

# Check active connections on the upstream PostgreSQL
docker compose exec postgres psql -U postgres -c \
  "SELECT count(*) FROM pg_stat_activity WHERE usename = 'postgres';"

# Monitor pooler logs
docker compose logs -f supavisor
```

## Health Check

```bash
# Verify the pooler is accepting connections
psql -h localhost -p 6543 -U postgres -d postgres -c "SELECT 1;"
```

Returns a single row with value `1` when the pooler and upstream database are healthy.

## Docker

- **Image:** `supabase/supavisor`
- **Port:** `6543`
- **Depends on:** `postgres`
- **Networks:** Internal `baas` network
