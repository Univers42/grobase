# query-router

**Port interne** : `4001` · **Container** : `mini-baas-query-router` · **Profile** : `data-plane`

Le **cœur** du backend agnostique. Dispatcher unique pour toutes les opérations
de lecture / écriture, peu importe le moteur cible (PostgreSQL, MongoDB, MySQL,
Redis, HTTP). Implémente la couche `IDatabaseAdapter` documentée dans
`apps/baas/mini-baas-infra/src/libs/database/`.

## Ce qu'il fait

- Reçoit `POST /query/:dbId/tables/:table` avec un body `{ op, data?, filter?, sort?, limit?, offset? }`
- Résout `dbId` → `(engine, connection_string)` via `adapter-registry`
- Demande une décision ABAC à `permission-engine` (`POST /permissions/decide`)
- Si autorisé, dispatch vers l'adapter correspondant : `Map<string, IDatabaseAdapter>` (pas de `if/else` engine-spécifique)
- Si write : emit un row `outbox_events` dans la même transaction PG (Postgres uniquement — M3)
- Audit chaque mutation dans `audit_log` avec `request_id` propagé

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` | Liveness probe (toujours 200) |
| `GET` | `/health/ready` | Readiness (vérifie connection PG + adapter-registry + permission-engine) |
| `GET` | `/engines` | Liste les adapters enregistrés : `{"engines":["postgresql","mongodb","mysql","redis","http"]}` |
| `POST` | `/query/:dbId/tables/:table` | Exécute une op via l'adapter de la DB |
| `GET` | `/query/:dbId/tables` | Liste les resources (tables / collections / clés) |
| `GET` | `/docs` · `/docs-json` | OpenAPI Swagger |

### Opérations supportées (`op` enum)

`list`, `get`, `insert`, `update`, `delete`, `upsert` — voir
[`engines.controller.ts`](src/query/engines.controller.ts) et le contrat
[`adapter.contract.ts`](../../libs/database/src/adapter.contract.ts).

## Comment l'invoquer

### Via le SDK (recommandé pour code applicatif)

```ts
import { MiniBaasClient } from '@mini-baas/js';

const client = new MiniBaasClient({ baseUrl: 'https://localhost:18443', token: jwt });
const rows = await client.query(dbId).table('users').list({ filter: { active: true }, limit: 10 });
const inserted = await client.query(dbId).table('users').insert({ name: 'Alice' });
```

### Via Kong (production / depuis le navigateur)

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  "https://localhost:18443/query/$DB_ID/tables/users" \
  -d '{"op":"insert","data":{"name":"Alice"}}'
```

### Via `docker compose exec` (debug)

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T query-router \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:4001/query/$DB_ID/tables/users', {
      method: 'POST',
      headers: { 'Content-Type':'application/json', 'X-User-Id':'$USER_ID', 'X-User-Role':'authenticated' },
      body: JSON.stringify({ op: 'list', limit: 10 })
    });
    console.log(await r.text());
  "
```

### Via make + verify scripts

```bash
make baas-verify-m1   # vérifie statique : dispatch Map + ExecuteQueryDto + audit
make baas-verify-m2   # vérifie statique : 5 engines wired
BAAS_VERIFY_LIVE=1 make baas-verify-m2   # roundtrips insert/select mysql/redis/http
```

## Dépendances

- **Postgres** : connection pool partagé, source des migrations (`schema_migrations`)
- **adapter-registry** : résolution `dbId → (engine, connection_string)`
- **permission-engine** : décisions ABAC (fail-closed)
- **Redis** : cache idempotency (`IdempotencyMiddleware`)
- **Tous les engines** (`postgresql`, `mongodb`, `mysql`, `redis`, `http`) sont des dépendances **runtime** (uniquement contactés à la demande, pas au boot)

## Gates qui le couvrent

- **M1** : `IDatabaseAdapter` formalisé, `Map<string, IDatabaseAdapter>` dispatcher, audit wired
- **M2** : 5 engines présents, `/engines` introspection
- **M3** : outbox emit pour writes, idempotency middleware appliqué
- **M9** : `decidePermission()` appelée **avant** `adapter.execute()` (fail-closed)

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | Port d'écoute (default 4001) |
| `DATABASE_URL` | Pool PG pour audit_log + outbox_events |
| `ADAPTER_REGISTRY_URL` | URL du adapter-registry (default `http://adapter-registry:3020`) |
| `PERMISSION_ENGINE_URL` | URL du permission-engine (default `http://permission-engine:3050`) |
| `IDEMPOTENCY_REDIS_URL` | URL Redis pour le cache idempotency |
| `ADAPTER_REGISTRY_SERVICE_TOKEN` | Token partagé pour appeler permission-engine |
