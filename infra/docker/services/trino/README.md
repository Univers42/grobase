# Trino

Trino 467 — distributed SQL query engine. Enables federated queries across multiple data sources (PostgreSQL, MongoDB, etc.) using standard SQL syntax.

## Quick Start

```bash
docker compose up trino
```

## Configuration Files

| File | Description |
|------|-------------|
| `config.properties` | General Trino server configuration |
| `jvm.config` | JVM settings (heap size, GC options) |
| `node.properties` | Node identity and environment |
| `catalog/postgresql.properties` | PostgreSQL connector configuration |
| `catalog/mongodb.properties` | MongoDB connector configuration |

### Example `config.properties`

```properties
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
```

### Example `jvm.config`

```
-server
-Xmx1G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `JAVA_HOME` | (built-in) | JVM path |
| `TRINO_CONFIG_DIR` | `/etc/trino` | Configuration directory |

## Ports

| Port | Description |
|------|-------------|
| `8080` | HTTP API and Web UI |

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/info` | Trino server info |
| `GET` | `/v1/status` | Node status |
| `GET` | `/ui/` | Web UI dashboard |
| `POST` | `/v1/statement` | Submit a SQL query |

## CLI Examples

### Using the Trino CLI

```bash
# Install Trino CLI
# Download from https://trino.io/docs/current/client/cli.html

# Connect to Trino
trino --server http://localhost:8080 --catalog postgresql --schema public

# Run a query
trino --server http://localhost:8080 --execute "SELECT * FROM postgresql.public.todos LIMIT 10"

# Query across databases (federated query)
trino --server http://localhost:8080 --execute "
  SELECT p.id, p.title, m.metadata
  FROM postgresql.public.todos p
  JOIN mongodb.mydb.todo_meta m ON p.id = m.todo_id
"

# Show catalogs
trino --server http://localhost:8080 --execute "SHOW CATALOGS"

# Show schemas in a catalog
trino --server http://localhost:8080 --execute "SHOW SCHEMAS FROM postgresql"

# Show tables in a schema
trino --server http://localhost:8080 --execute "SHOW TABLES FROM postgresql.public"

# Describe a table
trino --server http://localhost:8080 --execute "DESCRIBE postgresql.public.todos"
```

### Using curl

```bash
# Submit a query via HTTP
curl -s -X POST http://localhost:8080/v1/statement \
  -H "X-Trino-User: admin" \
  -d "SELECT * FROM postgresql.public.todos LIMIT 5" | jq .

# Get server info
curl -s http://localhost:8080/v1/info | jq .

# Check node status
curl -s http://localhost:8080/v1/status | jq .
```

### Web UI

Open [http://localhost:8080/ui/](http://localhost:8080/ui/) to view running queries, cluster status, and query history.

## Health Check

```bash
curl -sf http://localhost:8080/v1/info
```

Returns JSON with server version and uptime when healthy.

## Docker

- **Image:** `trinodb/trino:467`
- **Port:** `8080`
- **Volumes:** Configuration files mounted to `/etc/trino`
- **Networks:** Internal `baas` network
