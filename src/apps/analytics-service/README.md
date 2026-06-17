# analytics-service

**Port interne** : `3070` · **Container** : `mini-baas-analytics-service` · **Profile** : `background`

Ingestion d'événements applicatifs (page views, clicks, custom events) +
agrégations (stats par type, par jour, par user). Pas un analytics complet
type Mixpanel — un noyau minimal qui suffit pour dashboards internes.

## Ce qu'il fait

- `POST /events` : ingest un event `{ type, payload, ts? }` (batch-friendly)
- `GET /events` : liste paginée (filter par type, user, plage de temps)
- `GET /events/stats` : agrégations (count par type, par jour)
- `GET /events/types` : liste les types distincts

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/events` | Ingest un ou plusieurs events |
| `GET` | `/events` | Pagination + filter |
| `GET` | `/events/stats` | Counts agrégés |
| `GET` | `/events/types` | Liste les types |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
await client.analytics.track('block.created', { block_type: 'paragraph', page_id: 'abc' });
const stats = await client.analytics.stats({ from: '2026-05-01' });
```

### Via Kong

```bash
curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/analytics/events" \
  -d '{"type":"page.view","payload":{"path":"/dashboard"}}'
```

## Dépendances

- **Postgres** : table `analytics_events` (TimescaleDB extension recommandée mais pas obligatoire)
- **Audit** : agnostique — chaque event est aussi auditée

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3070 |
| `DATABASE_URL` | Pool PG |
| `ANALYTICS_RETENTION_DAYS` | Suppression auto au-delà (default 90) |
