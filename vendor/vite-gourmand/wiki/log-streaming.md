# Fly.io-Style Log Streaming System

Real-time log streaming infrastructure inspired by `fly logs`.

## Architecture

```
┌─────────────────┐    WebSocket     ┌─────────────────┐
│   NestJS App    │ ──────────────▶  │   CLI (vg logs) │
│                 │                  └─────────────────┘
│ ┌─────────────┐ │    WebSocket     ┌─────────────────┐
│ │ LogEmitter  │─┼──────────────▶   │   Web Dashboard │
│ └─────────────┘ │                  └─────────────────┘
│        ▲        │
│ ┌─────────────┐ │
│ │Interceptors │ │ ◀── Captures HTTP requests
│ └─────────────┘ │
└─────────────────┘
```

## Components

### Backend (`/backend/src/logging/`)

| File | Purpose |
|------|---------|
| `types.ts` | Structured log schema |
| `log.emitter.ts` | Event-based log distribution |
| `log.gateway.ts` | WebSocket broadcaster |
| `http-log.interceptor.ts` | HTTP request logging |
| `logging.module.ts` | NestJS module |

### CLI (`/cli/`)

```bash
# Install
cd cli && npm install && npm run build && npm link

# Usage
vg logs                    # Stream all logs
vg logs --level warn       # Only warn and above
vg logs --source api       # Only API logs
vg logs --url http://prod  # Custom backend URL
```

### Frontend (`/frontend/src/components/features/logs/`)

| Component | Purpose |
|-----------|---------|
| `LogViewer` | Terminal-style log display |
| `LogEntry` | Single log line |
| `useLogStream` | WebSocket hook |
| `useMockLogs` | Development mock data |

## Log Format

```json
{
  "timestamp": "2026-02-05T18:13:38.000Z",
  "level": "info",
  "source": "api",
  "message": "GET /api/users 200 12ms",
  "meta": {
    "method": "GET",
    "path": "/api/users",
    "statusCode": 200,
    "duration": 12,
    "userId": "user_123"
  }
}
```

## Design Decisions

### Why WebSockets?

- Real-time bidirectional communication
- Built-in reconnection support
- Works in browsers and CLI
- Low latency

### Why JSON Logs?

- Structured, parseable
- Filterable by level/source
- Extensible metadata
- Easy to persist to Loki/files

## Scaling

For multiple instances:

1. Tag logs with `instance` and `region`
2. Use Redis pub/sub for cross-instance distribution
3. Or aggregate through a log router

## Future Enhancements

- [ ] Log persistence (Loki, files)
- [ ] Advanced filtering (regex, time ranges)
- [ ] Instance/region tagging
- [ ] Log search and replay
- [ ] Alert triggers on error patterns
