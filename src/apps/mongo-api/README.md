# mongo-api

**Port interne** : `3010` · **Container** : `mini-baas-mongo-api` · **Profile** : `data-plane`

REST API au-dessus de MongoDB. Mêmes contrats que `query-router` mais natif
Mongo : collections au lieu de tables, ObjectId, schémas optionnels. Le
`query-router` peut aussi adresser Mongo via le `MongoEngine`, mais
`mongo-api` est plus efficace pour les collections **partagées** par le BaaS
(orders_view, sessions, ai_messages).

## Ce qu'il fait

- CRUD documents sur n'importe quelle collection : `/collections/:name/documents`
- Admin : déclarer/valider schemas, créer indexes
- Toutes les insertions injectent `owner_id = X-User-Id` automatiquement (isolation tenant)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` · `/health` | Probes |
| `POST` | `/collections/:name/documents` | Insert document |
| `GET` | `/collections/:name/documents` | List avec filter/sort/limit, `fields=a,b` (projection, `id` toujours rendu) |
| `GET` | `/collections/:name/documents/:id` | Get par id |
| `PATCH` | `/collections/:name/documents/:id` | Update partial ; `fields=` ; `if_field=rev&if_value=3` → 409 si le champ a bougé (garde : chaîne ou nombre exact seulement, voir plus bas) ; les autres clés de query sont ignorées |
| `DELETE` | `/collections/:name/documents/:id` | Delete |
| `GET` | `/admin/collections` | Liste les collections du DB |
| `GET` | `/admin/schemas/:name` | Voir un JSON Schema enregistré |
| `PUT` | `/admin/schemas/:name` | Set/update JSON Schema |
| `DELETE` | `/admin/schemas/:name` | Supprime le schema (les writes futures ne sont plus validées) |
| `POST` | `/admin/indexes/:name` | Crée un index |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

### Garde compare-and-swap (`if_field` / `if_value`)

La query string porte du texte : `if_value` égale un champ chaîne, ou un champ nombre
qu'il écrit exactement (`3` égale 3, `03`, `3.0` ou `1e3` jamais). Un booléen, une date,
`null` ou un tableau ne se gardent pas : un booléen ou une date répond toujours 409
(`updated_at` aussi, le PATCH le réécrit), et un tableau égale dès qu'il *contient* la
valeur, donc la garde laisse passer une écriture concurrente. Garder un compteur
(`rev`) que chaque écriture incrémente. Gate : `scripts/verify/m239-mongo-api-body-limits-cas.sh`.

## Sécurité

- `owner_id` est **systématiquement** injecté côté server à l'insert (le client ne peut pas le set)
- À la lecture, un filtre `{ owner_id: X-User-Id }` est mergé avec le filter du caller
- Schémas validés côté `mongo-api` (Zod) **et** côté Mongo (JSON Schema validator)
- `AuditInterceptor` enregistre chaque mutation dans `audit_log` (PG)

## Comment l'invoquer

### Via le SDK

```ts
const doc = await client.mongo.collection('orders').insert({ amount: 42 });
const list = await client.mongo.collection('orders').list({ filter: { amount: { $gte: 10 } } });
```

### Via Kong

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  "https://localhost:18443/mongo/collections/orders/documents" \
  -d '{"amount": 42, "item": "widget"}'
```

### Via `docker compose exec` (debug)

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T mongo-api \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:3010/admin/collections', {
      headers: { 'X-User-Id':'$USER_ID', 'X-User-Role':'authenticated' }
    });
    console.log(await r.text());
  "
```

### Smoke test dédié

```bash
# Phase 14 = mongo-api MVP end-to-end
BASE_URL=http://localhost:18000 bash apps/baas/mini-baas-infra/scripts/phase14-mongo-mvp-test.sh
# Variant Python
python3 apps/baas/mini-baas-infra/scripts/phase15-mongo-mvp-test.py
```

## Dépendances

- **Mongo replica set** (`mongo-init` initialise le RS au boot)
- **Postgres** : pour `audit_log` (cross-engine traceability)
- **adapter-registry** : pour les collections rattachées à une DB externe enregistrée
- **permission-engine** : ABAC

## Gates qui le couvrent

- **M1** : `implements IDatabaseAdapter` (via `MongoEngine` du query-router)
- **M3** : `orders_view` projection (outbox-relay y publie)

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3010 |
| `MONGO_URL` | DSN Mongo (replica set requis) |
| `MONGO_DB_NAME` | DB cible (default `mini_baas`) |
| `MONGO_API_BIG_COLLECTIONS` | Collections (liste `,`) dont le corps JSON va jusqu'à `MONGO_API_BIG_JSON_LIMIT`, pour un appelant à l'identité vérifiée seulement (un anonyme reste à 100 KB) ; les autres restent à 100 KB (default vide ; un nom invalide est ignoré avec un warn au boot) |
| `MONGO_API_BIG_JSON_LIMIT` | Limite de ces collections (default `8mb`, aussi si vide ou invalide) ; prévoir `MONGO_API_MEM_LIMIT=256m` + `MONGO_API_HEAP_MB=192` (compose) |
| `DATABASE_URL` | Pool PG pour audit_log |
