# log-service

**Port interne** : `3110` · **Container** : `mini-baas-log-service` · **Profile** : `background`

Réceptionne les logs applicatifs (clients front + bridges), les stocke en
PG **et** les forward vers Loki pour exploration côté Grafana. Sert aussi de
backup en cas d'indisponibilité de Loki.

## Ce qu'il fait

- `POST /logs/ingest` : reçoit un batch de log entries
- `GET /logs` : query (filter par level, service, plage de temps)
- Forward asynchrone vers Loki (`promtail`-style HTTP push)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/logs/ingest` | Batch ingest ; body `[{ ts, level, service, message, context }]` |
| `GET` | `/logs` | Query paginée |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Depuis le front (SDK)

Pas exposé en SDK applicatif — le front log côté browser via `console.*` qui
est wrappé par `apps/osionos/app/src/shared/lib/logger.ts` (et envoie batch
toutes les 5 sec à `/log/ingest`).

### Via Kong

```bash
curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/log/ingest" \
  -d '[{"ts":"'$(date -u +%FT%TZ)'","level":"info","service":"frontend","message":"page loaded"}]'
```

### Query depuis Loki (Grafana)

```bash
# Si observability profile up
curl -fsS "http://127.0.0.1:13100/loki/api/v1/query?query=%7Bservice%3D%22query-router%22%7D"
```

## Dépendances

- **Postgres** : table `app_logs` (retention 7 jours via cron)
- **Loki** (optionnel, profile observability) : forward HTTP push

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck
- **M4** : intégration Loki (soft check)

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3110 |
| `DATABASE_URL` | Pool PG |
| `LOKI_URL` | Endpoint Loki HTTP push (optionnel) |
| `LOG_RETENTION_DAYS` | Default 7 |
