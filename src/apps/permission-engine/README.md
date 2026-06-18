# permission-engine

**Port interne** : `3050` · **Container** : `mini-baas-permission-engine` · **Profile** : `control-plane`

**Le cerveau ABAC** (Attribute-Based Access Control). Centralise toutes les
décisions « cet utilisateur a-t-il le droit de faire cette op sur cette
ressource ? ». Appelé par `query-router`, `mongo-api`, `storage-router` et
`adapter-registry` **avant** toute mutation.

## Ce qu'il fait

- **`POST /permissions/decide`** : décision ABAC unique, fail-closed (default deny)
- **`POST /permissions/check`** : version legacy (M1-M8), gardée pour compat
- **`/policies`** : CRUD policies (admin only)
- **`/permissions/roles*`** : assignation rôles ↔ users

Toutes les décisions s'appuient sur la fonction SQL `public.has_permission()`
définie dans la migration `007_permissions_system.sql` (priority desc, deny
wins). M9 a ajouté la couche `decidePermission()` qui retourne aussi un
**field mask** (lecture filtrée) et un **why** (raison du deny pour audit).

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/permissions/decide` | Décision ABAC (M9) — body `{ user, resource_type, resource_name, op, attributes }` |
| `POST` | `/permissions/check` | Décision legacy boolean |
| `GET` | `/permissions/roles` | Liste tous les rôles |
| `GET` | `/permissions/roles/:userId` | Rôles d'un user |
| `POST` | `/permissions/roles/assign` | Assigne un rôle |
| `DELETE` | `/permissions/roles/:userId/:roleName` | Retire un rôle |
| `GET` | `/policies` | Liste toutes les policies (admin) |
| `GET` | `/policies/role/:roleId` | Policies d'un rôle |
| `POST` | `/policies` | Crée une policy |
| `DELETE` | `/policies/:id` | Supprime une policy |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Modèle de décision

```
Input  : { user: {id, ...}, resource_type, resource_name, op, attributes }
Output : { allow: bool, reason: string, mask?: string[], obligations?: {...} }
```

- `allow=false` par défaut (aucune policy matchée OU policy `deny` matchée)
- `mask`: si une policy `allow` contient `conditions.mask=['email','phone']`, ces champs sont strip côté caller (query-router fait `applyFieldMask()`)
- Priority `desc` + `deny` wins (cf. `decisions.service.ts:maskFromConditions()`)

## Comment l'invoquer

### Depuis query-router (interne — pattern attendu)

```ts
const decision = await this.permissionClient.decide({
  user: { id: userId, roles },
  resource_type: 'postgresql',
  resource_name: 'users',
  op: 'select',
  attributes: { request_id: req.id }
});
if (!decision.allow) throw new ForbiddenException(decision.reason);
// applique le mask
const safe = decision.mask?.length
  ? rows.map(r => omit(r, decision.mask))
  : rows;
```

### Via Kong (admin user)

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $ADMIN_JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/permissions/decide" \
  -d '{
    "user": { "id": "00000000-0000-4000-8000-000000000001" },
    "resource_type": "postgresql",
    "resource_name": "users",
    "op": "select"
  }'
```

### Via `docker compose exec` (debug — appel direct service-to-service)

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T permission-engine \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:3050/permissions/decide', {
      method: 'POST',
      headers: {
        'Content-Type':'application/json',
        'X-Service-Token': process.env.ADAPTER_REGISTRY_SERVICE_TOKEN ?? 'dev-service-token'
      },
      body: JSON.stringify({
        user:{id:'$USER_ID'},
        resource_type:'postgresql',
        resource_name:'users',
        op:'select'
      })
    });
    console.log(await r.text());
  "
```

## Dépendances

- **Postgres** : tables `roles`, `user_roles`, `resource_policies` (migration 007), fonction `public.has_permission(user_id, type, name, op)`
- **Vault** : `PERMISSION_ENGINE_SERVICE_TOKEN` (partagé avec query-router, mongo-api, storage-router)

## Gates qui le couvrent

- **M9** : `POST /permissions/decide` existe, fail-closed (deny par défaut), `DecisionsService` invoque `public.has_permission`, `applyFieldMask()` côté caller

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3050 |
| `DATABASE_URL` | Pool PG |
| `PERMISSION_ENGINE_SERVICE_TOKEN` | Vérifié sur `/permissions/decide` (header `X-Service-Token`) |
| `ADAPTER_REGISTRY_SERVICE_TOKEN` | Idem (rétro-compat) |
