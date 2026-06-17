# session-service

**Port interne** : `3120` · **Container** : `mini-baas-session-service` · **Profile** : `control-plane`

Gestion **explicite** des sessions utilisateur (au-delà du JWT stateless de
GoTrue). Permet revocation immédiate, listing « mes sessions actives »,
expiration server-side, et admin override.

## Ce qu'il fait

- `POST /sessions` : crée une session (au signin via auth-gateway)
- `GET /sessions/mine` : liste les sessions actives du user
- `POST /sessions/validate` : check si une session est still active (TTL non expiré, pas revoked)
- `POST /sessions/extend` : prolonge le TTL
- `DELETE /sessions/:id` : revoke une session précise
- `POST /sessions/revoke-all` : revoke toutes les sessions du user (panic button)
- `GET /sessions/admin/all` : vue admin (toutes sessions)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/sessions` | Crée une session |
| `GET` | `/sessions/mine` | Liste user |
| `POST` | `/sessions/validate` | Boolean active/expired/revoked |
| `POST` | `/sessions/extend` | Prolonge TTL |
| `DELETE` | `/sessions/:id` | Revoke single |
| `POST` | `/sessions/revoke-all` | Panic button user |
| `GET` | `/sessions/admin/all` | Vue admin |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
const sessions = await client.session.mine();
await client.session.revoke(sessions[1].id);
await client.session.revokeAll();   // panic
```

### Via Kong

```bash
curl -ksS -H "Authorization: Bearer $JWT" \
  "https://localhost:18443/sessions/mine"

curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  "https://localhost:18443/sessions/revoke-all"
```

## Dépendances

- **Postgres** : table `sessions` (id, user_id, jti, ua, ip, created_at, expires_at, revoked_at)
- **Redis** : cache des sessions actives (TTL synchronisé avec PG)
- **JWT_SECRET** : pour valider la jti

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck, AuditModule wired

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3120 |
| `DATABASE_URL` | Pool PG |
| `REDIS_URL` | Cache sessions actives |
| `JWT_SECRET` | Validation jti |
| `SESSION_DEFAULT_TTL_SECONDS` | Default 86400 (24h) |
