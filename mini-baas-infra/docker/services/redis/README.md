# Redis

Redis 7 (Alpine) — in-memory data store used for caching, session management, and pub/sub messaging.

## Quick Start

```bash
docker compose up redis
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_PASSWORD` | — | Authentication password (optional) |
| `REDIS_ARGS` | — | Extra CLI arguments passed to `redis-server` |

## Ports

| Port | Description |
|------|-------------|
| `6379` | Redis wire protocol |

## Volumes

| Volume | Mount Point | Description |
|--------|------------|-------------|
| `redis-data` | `/data` | Persistent data (RDB/AOF snapshots) |

## CLI Examples

```bash
# Connect with redis-cli (inside container)
docker compose exec redis redis-cli

# Connect with password
docker compose exec redis redis-cli -a <password>

# Ping
docker compose exec redis redis-cli PING
# → PONG

# Set a key
docker compose exec redis redis-cli SET mykey "hello"

# Get a key
docker compose exec redis redis-cli GET mykey

# Set with TTL (60 seconds)
docker compose exec redis redis-cli SET session:abc123 '{"user":"alice"}' EX 60

# List all keys (use with care in production)
docker compose exec redis redis-cli KEYS '*'

# Check TTL
docker compose exec redis redis-cli TTL session:abc123

# Delete a key
docker compose exec redis redis-cli DEL mykey

# Hash operations
docker compose exec redis redis-cli HSET user:1 name "Alice" email "alice@example.com"
docker compose exec redis redis-cli HGETALL user:1

# Pub/Sub — subscribe
docker compose exec redis redis-cli SUBSCRIBE mychannel

# Pub/Sub — publish (in another terminal)
docker compose exec redis redis-cli PUBLISH mychannel "hello world"

# Get server info
docker compose exec redis redis-cli INFO server

# Monitor commands in real time
docker compose exec redis redis-cli MONITOR

# Flush all data (DANGER)
docker compose exec redis redis-cli FLUSHALL
```

## Health Check

```bash
docker compose exec redis redis-cli PING
```

Returns `PONG` when Redis is healthy and accepting connections.

## Docker

- **Image:** `redis:7-alpine`
- **Port:** `6379`
- **Volumes:** `redis-data:/data`
- **Networks:** Internal `baas` network
