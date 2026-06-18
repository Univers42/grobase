# New BaaS Services — API Reference

Six generic, reusable micro-services extracted from the Back and generalized for mini-BaaS.

## Port Allocation

| Service | Port | Kong Route | DB |
|---------|------|------------|-----|
| analytics-service | 3070 | `/analytics/v1` | MongoDB |
| gdpr-service | 3080 | `/gdpr/v1` | PostgreSQL |
| newsletter-service | 3090 | `/newsletter/v1` | PostgreSQL |
| ai-service | 3100 | `/ai/v1` | MongoDB |
| log-service | 3110 | `/logs/v1` | In-memory |
| session-service | 3120 | `/sessions/v1` | PostgreSQL |

---

## 1. Analytics Service (port 3070)

Event tracking and aggregation engine backed by MongoDB with automatic TTL cleanup.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/events` | Optional | Track an event (auto-injects userId if authenticated) |
| `GET` | `/events` | service_role | Query events by type/since/limit |
| `GET` | `/events/stats` | service_role | Aggregated statistics |
| `GET` | `/events/types` | service_role | List distinct event types |
| `GET` | `/health/live` | None | Liveness probe |
| `GET` | `/health/ready` | None | Readiness (checks MongoDB) |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `ANALYTICS_RETENTION_DAYS` | 90 | TTL for events in MongoDB |
| `ANALYTICS_MONGO_DB` | mini_baas_analytics | MongoDB database name |

---

## 2. GDPR Service (port 3080)

Consent management, data deletion requests, and data export — fully generic via webhooks.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/consents` | user | Get all my consents |
| `POST` | `/consents` | user | Set a consent (upsert) |
| `PATCH` | `/consents/:type` | user | Update a consent |
| `DELETE` | `/consents/non-essential` | user | Withdraw all non-essential consents |
| `POST` | `/deletion-requests/mine` | user | Request account deletion |
| `GET` | `/deletion-requests/mine` | user | My deletion requests |
| `DELETE` | `/deletion-requests/mine/:id` | user | Cancel pending request |
| `GET` | `/deletion-requests/admin` | service_role | List all deletion requests |
| `POST` | `/deletion-requests/admin/:id/process` | service_role | Process a request |
| `GET` | `/export` | user | Export my data |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `GDPR_DELETION_WEBHOOK_URL` | — | Webhook called when deletion is completed |
| `GDPR_EXPORT_WEBHOOK_URL` | — | Webhook called to assemble user data |

### Design: Webhook Pattern

The GDPR service does **not** hardcode app-specific deletion logic. Instead:
- On deletion completion → calls `GDPR_DELETION_WEBHOOK_URL` with `{ userId, requestId }`
- On data export → calls `GDPR_EXPORT_WEBHOOK_URL` with `{ userId }` and wraps the response

Your consuming app implements these webhooks to handle domain-specific cleanup/export.

---

## 3. Newsletter Service (port 3090)

Email subscription management and campaign sending. Delegates email delivery to the existing email-service.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/subscribe` | None (public) | Subscribe an email |
| `GET` | `/confirm/:token` | None (public) | Confirm subscription |
| `GET` | `/unsubscribe/:token` | None (public) | Unsubscribe |
| `GET` | `/admin/subscribers` | service_role | List all subscribers |
| `GET` | `/admin/stats` | service_role | Subscription statistics |
| `POST` | `/admin/campaigns/send` | service_role | Send a campaign |
| `GET` | `/admin/campaigns/history` | service_role | Campaign history |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `EMAIL_SERVICE_URL` | http://email-service:3030 | Internal email-service URL |
| `NEWSLETTER_BATCH_SIZE` | 5 | Emails per batch during sends |

---

## 4. AI Service (port 3100)

Generic LLM conversation engine — multi-turn chat with configurable prompt templates.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/chat` | Optional | Send a message (starts or continues conversation) |
| `GET` | `/chat/conversations` | user | List my conversations |
| `GET` | `/chat/conversations/:id` | user | Get conversation messages |
| `DELETE` | `/chat/conversations/:id` | user | Delete a conversation |
| `GET` | `/admin/prompts` | service_role | List prompt templates |
| `GET` | `/admin/prompts/:mode` | service_role | Get a prompt template |
| `POST` | `/admin/prompts` | service_role | Create prompt template |
| `PUT` | `/admin/prompts/:mode` | service_role | Update prompt template |
| `DELETE` | `/admin/prompts/:mode` | service_role | Delete prompt template |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `LLM_API_URL` | https://api.groq.com/openai/v1 | OpenAI-compatible API URL |
| `LLM_API_KEY` | — | API key for the LLM provider |
| `LLM_MODEL` | llama-3.3-70b-versatile | Model identifier |
| `LLM_MAX_TOKENS` | 2048 | Max tokens per completion |
| `LLM_TEMPERATURE` | 0.7 | Sampling temperature |
| `AI_CONVERSATION_TTL_HOURS` | 24 | Auto-cleanup TTL for conversations |
| `AI_MONGO_DB` | mini_baas_ai | MongoDB database name |

### Design: Prompt Templates

The AI service has **no hardcoded prompts**. Consuming apps register "modes" via the admin API:

```json
POST /admin/prompts
{
  "mode": "support",
  "template": "You are a support agent for {app_name}.\n\nContext:\n{context}",
  "description": "Customer support mode"
}
```

When chatting, pass `mode` and `context` to inject domain data:

```json
POST /chat
{
  "message": "What are your hours?",
  "mode": "support",
  "context": { "app_name": "My App", "hours": "9am-5pm" }
}
```

---

## 5. Log Service (port 3110)

Centralized log ingestion with in-memory ring buffer and real-time SSE streaming.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/logs/ingest` | API key | Ingest a structured log entry |
| `GET` | `/logs` | service_role | Query buffered logs (filter by level/source/since) |
| `GET` | `/logs/stream?token=...` | Token | Real-time SSE log stream |
| `GET` | `/logs/stats` | service_role | Buffer count |
| `DELETE` | `/logs` | service_role | Clear buffer |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `LOG_BUFFER_SIZE` | 1000 | Max entries in ring buffer |
| `LOG_STREAM_TOKEN` | — | Token for SSE stream authentication |

### SSE Stream Protocol

Connect via `EventSource`:
```javascript
const es = new EventSource('/logs/v1/logs/stream?token=YOUR_TOKEN');
es.onmessage = (e) => {
  const data = JSON.parse(e.data);
  // data.type === 'initial' → { logs: [...] }
  // data.type === 'log'     → { log: {...} }
};
```

---

## 6. Session Service (port 3120)

Token-based session lifecycle management with admin controls. PostgreSQL-backed with RLS.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/sessions` | user | Create a session |
| `GET` | `/sessions/mine` | user | List my sessions |
| `POST` | `/sessions/validate` | API key | Validate a session token |
| `POST` | `/sessions/extend` | user | Extend current session |
| `DELETE` | `/sessions/:id` | user | Revoke own session |
| `POST` | `/sessions/revoke-all` | user | Revoke all other sessions |
| `GET` | `/sessions/admin/all` | service_role | List all active sessions |
| `GET` | `/sessions/admin/stats` | service_role | Session statistics |
| `DELETE` | `/sessions/admin/:id` | service_role | Force-revoke any session |
| `POST` | `/sessions/admin/users/:userId/revoke-all` | service_role | Force-revoke all for user |
| `POST` | `/sessions/admin/cleanup` | service_role | Delete expired sessions |

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `SESSION_TTL_DAYS` | 7 | Default session expiry in days |
