# ai-service

**Port interne** : `3100` · **Container** : `mini-baas-ai-service` · **Profile** : `extras`

Proxy LLM (Anthropic / OpenAI / local) avec gestion des conversations,
des prompts admin (templates server-side), et rate-limiting per-user.

## Ce qu'il fait

- `POST /chat` : envoie un message (streaming SSE ou full response)
- `GET /chat/conversations` : liste les conversations du user
- `GET /chat/conversations/:id` : récupère l'historique
- `DELETE /chat/conversations/:id` : supprime
- `/admin/prompts/*` : CRUD templates de prompts (admin only)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/chat` | Body `{ mode, message, conversation_id? }` |
| `GET` | `/chat/conversations` | Liste user |
| `GET` | `/chat/conversations/:id` | Historique |
| `DELETE` | `/chat/conversations/:id` | Supprime |
| `GET` | `/admin/prompts` | Liste templates |
| `GET` | `/admin/prompts/:mode` | Un template |
| `POST` | `/admin/prompts` | Crée |
| `PUT` | `/admin/prompts/:mode` | Update |
| `DELETE` | `/admin/prompts/:mode` | Delete |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
const stream = await client.ai.chat({ mode: 'assistant', message: 'Hello' });
for await (const chunk of stream) console.log(chunk.text);
```

### Via Kong

```bash
curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/ai/chat" \
  -d '{"mode":"assistant","message":"Hello"}'
```

## Dépendances

- **Anthropic API** (default) / OpenAI / Ollama selon `AI_PROVIDER`
- **Postgres** : tables `ai_conversations`, `ai_messages`, `ai_prompts`
- **Vault** : `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
- **Redis** : rate-limit per-user

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3100 |
| `AI_PROVIDER` | `anthropic`, `openai`, `ollama` |
| `ANTHROPIC_API_KEY` | Si provider=anthropic (Vault) |
| `OPENAI_API_KEY` | Si provider=openai (Vault) |
| `AI_DEFAULT_MODEL` | `claude-opus-4-7`, `gpt-4`, etc. |
| `AI_RATE_LIMIT_PER_HOUR` | Default 100 |
