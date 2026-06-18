# outbox-relay

**Port interne** : `3130` · **Container** : `mini-baas-outbox-relay` · **Profile** : `background`

**Worker** (pas une API métier). Implémente le **Transactional Outbox Pattern** :
poll la table `public.outbox_events` côté Postgres, publie chaque event sur
Redis Streams, projette certains events dans Mongo (vue dénormalisée), puis
marque l'event `status = 'published'`.

## Ce qu'il fait

- Boucle de poll toutes les 250ms (`OUTBOX_POLL_INTERVAL_MS`)
- Pour chaque row `status = 'pending'`, ordered by `id` :
  1. `XADD outbox.<aggregate> * payload <json>` (Redis Streams)
  2. Si l'aggregate est `order` : `db.orders_view.replaceOne({_id}, payload)` (Mongo)
  3. `UPDATE outbox_events SET status='published', published_at=now()`
- Si erreur : `status='failed'`, retry exponential backoff (jusqu'à 5 fois → `dead`)
- `GET /health/live` + `/health/ready`

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `GET` | `/docs` · `/docs-json` | OpenAPI minimal |

(Pas d'endpoint métier — c'est un worker.)

## Cycle de vie d'un event

```
1.  query-router insert dans Postgres (USER tx)
    INSERT INTO public.orders (id, name) VALUES (...);
    INSERT INTO public.outbox_events (aggregate, aggregate_id, event_type, payload) VALUES (...);
    COMMIT;
                       │
                       ▼
2.  outbox-relay poll       SELECT * FROM outbox_events WHERE status='pending' ORDER BY id;
                       │
                       ▼
3.  Redis Streams           XADD outbox.order * payload {...}
                       │
                       ▼
4.  Mongo projection        db.orders_view.replaceOne({_id: <id>}, {...})
                       │
                       ▼
5.  Marqué publié           UPDATE outbox_events SET status='published';
```

Tout abonné Redis Streams (`XREAD outbox.order`) reçoit l'event en temps réel —
peut servir pour realtime WebSocket, pour CDC vers une autre DB, pour audit
asynchrone, etc.

## Comment vérifier

```bash
# Liveness
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T outbox-relay \
  wget -qO- http://127.0.0.1:3130/health/live

# Voir la file PG en attente
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT id, aggregate, status, created_at FROM public.outbox_events ORDER BY id DESC LIMIT 10"

# Voir la file Redis Streams (events déjà publiés)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli XRANGE outbox.order - + COUNT 10

# Voir la projection Mongo
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T mongo \
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin --quiet --eval \
    "db.getSiblingDB('mini_baas').orders_view.find().limit(10)"

# Verify gate live (roundtrip complet)
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-m3
```

## Dépendances

- **Postgres** : tables `outbox_events`, `audit_log`
- **Redis** : Streams (`outbox.*`)
- **Mongo** : projection `orders_view`

## Gates qui le couvrent

- **M3** : outbox migration appliquée, relay polle PG → Redis Streams → Mongo, `status` flip

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3130 |
| `DATABASE_URL` | Pool PG (pour poll outbox_events) |
| `REDIS_URL` | Streams destination |
| `MONGO_URL` | Projection orders_view |
| `OUTBOX_POLL_INTERVAL_MS` | Default 250 |
| `OUTBOX_BATCH_SIZE` | Default 100 events par tick |
| `OUTBOX_MAX_RETRIES` | Default 5 avant `dead` |
