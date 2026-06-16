# gdpr-service

**Port interne** : `3080` · **Container** : `mini-baas-gdpr-service` · **Profile** : `control-plane`

Implémente les **droits RGPD** : droit à l'effacement, gestion des consentements,
export DSAR. Orchestre les autres services pour propager une demande d'effacement.

## Ce qu'il fait

- `POST /deletion-requests` : user demande effacement → enregistre `pending`, déclenche workflow
- `GET /deletion-requests/mine` : user voit l'avancement de sa demande
- `DELETE /deletion-requests/mine` : annule (si pas encore `processed`)
- `POST /deletion-requests/admin/:id/process` : admin valide l'effacement → cascade vers tous les services
- `/consents` : CRUD consents (analytics, marketing, third-party)
- `/export` : génère un export ZIP de toutes les données du user (DSAR)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/deletion-requests` | Crée une demande |
| `GET` | `/deletion-requests/mine` | Status user |
| `DELETE` | `/deletion-requests/mine` | Annule si pas processed |
| `GET` | `/deletion-requests/admin` | Liste toutes (admin) |
| `POST` | `/deletion-requests/admin/:id/process` | Admin valide → exécute |
| `GET` | `/consents` | Liste les consents du user |
| `GET` | `/consents/:type` | Status d'un consent (e.g. `analytics`) |
| `POST` | `/consents` | Set un consent |
| `PUT` | `/consents/:type` | Update granular |
| `DELETE` | `/consents/non-essential` | Revoke tout sauf essentiel |
| `GET` | `/export` | Génère ZIP (DSAR) |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
const req = await client.gdpr.requestDeletion();   // user
const status = await client.gdpr.deletionStatus(); // user
const zip = await client.gdpr.exportMyData();      // returns Blob
await client.gdpr.consent.set('analytics', false);
```

### Via Kong

```bash
curl -ksS -X POST -H "Authorization: Bearer $JWT" \
  "https://localhost:18443/gdpr/deletion-requests"

curl -ksS -H "Authorization: Bearer $JWT" \
  "https://localhost:18443/gdpr/export" --output my-data.zip
```

## Dépendances

- **email-service** : envoi des emails de confirmation effacement
- **Postgres** : tables `deletion_requests`, `consents`, `dsar_exports`
- **Tous les services applicatifs** : reçoivent l'event `user.deleted` via outbox → cleanup leurs rows
- **MinIO** : stocke les exports DSAR (TTL 7 jours)

## Gates qui le couvrent

- **M1** : audit interceptor wired, OpenAPI, healthcheck

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3080 |
| `DATABASE_URL` | Pool PG |
| `EMAIL_SERVICE_URL` | URL email-service |
| `S3_BUCKET_EXPORTS` | Bucket MinIO pour les ZIP DSAR |
