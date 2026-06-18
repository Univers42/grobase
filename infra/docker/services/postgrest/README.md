# PostgREST

PostgREST v12.2.3 — automatically generates a RESTful API from your PostgreSQL database schema. Every table, view, and function in the exposed schemas becomes an HTTP endpoint.

## Quick Start

```bash
docker compose up postgrest
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PGRST_DB_URI` | — | PostgreSQL connection string |
| `PGRST_DB_SCHEMAS` | `public` | Comma-separated schemas to expose |
| `PGRST_DB_ANON_ROLE` | `anon` | Database role for unauthenticated requests |
| `PGRST_JWT_SECRET` | — | JWT secret for token verification |
| `PGRST_DB_MAX_ROWS` | — | Maximum rows returned per request |
| `PGRST_DB_EXTRA_SEARCH_PATH` | `public,extensions` | Additional schemas on the search path |
| `PGRST_SERVER_PORT` | `3000` | Port PostgREST listens on |

## Endpoints

PostgREST auto-generates endpoints based on your database objects:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/<table>` | Read rows (supports filtering, ordering, pagination) |
| `POST` | `/<table>` | Insert row(s) |
| `PATCH` | `/<table>?<filter>` | Update matching rows |
| `DELETE` | `/<table>?<filter>` | Delete matching rows |
| `GET` | `/rpc/<function>` | Call a database function |
| `POST` | `/rpc/<function>` | Call a function with a request body |

## CLI Examples

```bash
# List all rows in a table
curl -s http://localhost:3000/todos \
  -H "Authorization: Bearer <jwt>" | jq .

# Get a single row by ID
curl -s 'http://localhost:3000/todos?id=eq.1' \
  -H "Authorization: Bearer <jwt>" | jq .

# Filtering: title contains "buy"
curl -s 'http://localhost:3000/todos?title=ilike.*buy*' \
  -H "Authorization: Bearer <jwt>" | jq .

# Pagination: get 10 items starting from offset 20
curl -s 'http://localhost:3000/todos?limit=10&offset=20' \
  -H "Authorization: Bearer <jwt>" | jq .

# Ordering
curl -s 'http://localhost:3000/todos?order=created_at.desc' \
  -H "Authorization: Bearer <jwt>" | jq .

# Select specific columns
curl -s 'http://localhost:3000/todos?select=id,title' \
  -H "Authorization: Bearer <jwt>" | jq .

# Insert a row
curl -s -X POST http://localhost:3000/todos \
  -H "Authorization: Bearer <jwt>" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"title": "Buy groceries", "done": false}' | jq .

# Update a row
curl -s -X PATCH 'http://localhost:3000/todos?id=eq.1' \
  -H "Authorization: Bearer <jwt>" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"done": true}' | jq .

# Delete a row
curl -s -X DELETE 'http://localhost:3000/todos?id=eq.1' \
  -H "Authorization: Bearer <jwt>"

# Call an RPC function
curl -s -X POST http://localhost:3000/rpc/my_function \
  -H "Authorization: Bearer <jwt>" \
  -H "Content-Type: application/json" \
  -d '{"arg1": "value"}' | jq .

# Get count via header
curl -s -I 'http://localhost:3000/todos' \
  -H "Authorization: Bearer <jwt>" \
  -H "Prefer: count=exact"
```

## Health Check

```bash
curl -sf http://localhost:3000/
```

Returns the OpenAPI schema (JSON) when healthy. A non-200 status indicates the service is down or the database connection failed.

## Docker

- **Image:** `postgrest/postgrest:v12.2.3`
- **Port:** `3000`
- **Depends on:** `postgres`
- **Networks:** Internal `baas` network
