# schema-service

**Port interne** : `3060` · **Container** : `mini-baas-schema-service` · **Profile** : `control-plane`

Catalogue de schémas (JSON Schema / Zod-compatible) déclarés par les apps
front. Permet au front d'enregistrer ses contrats de données puis de les
réutiliser pour `mongo-api` (JSON Schema validator), `query-router`
(validation des payloads), et la génération de formulaires côté UI Bridge.

## Ce qu'il fait

- `POST /schemas` : enregistre un schema (versionné)
- `GET /schemas` : liste les schemas accessibles à `X-User-Id`
- `DELETE /schemas/:id` : supprime (et tag les rows existantes comme orphelines)
- Pour M11 : introspection automatique des schemas d'une DB externe enregistrée (par tenant)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/schemas` | Crée ; body `{ name, version, json_schema, target? }` |
| `GET` | `/schemas` | Liste |
| `DELETE` | `/schemas/:id` | Supprime |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
await client.schemas.create({
  name: 'block.paragraph',
  version: 1,
  json_schema: { type: 'object', properties: { text: { type: 'string' } } }
});
```

### Via Kong

```bash
curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/schemas" \
  -d '{"name":"block.paragraph","version":1,"json_schema":{"type":"object"}}'
```

## Dépendances

- **Postgres** : table `schemas` (name, version, json_schema jsonb, owner_id, target)
- **mongo-api** : consomme les JSON Schema pour les validators Mongo

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck
- **M11** : endpoint `/schemas/by-tenant/:tenant_id` introspection multi-tenant

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3060 |
| `DATABASE_URL` | Pool PG |
