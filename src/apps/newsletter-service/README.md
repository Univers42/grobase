# newsletter-service

**Port interne** : `3090` · **Container** : `mini-baas-newsletter-service` · **Profile** : `background`

Gestion **double-opt-in** des abonnements newsletter + envoi de campagnes.
Le confirm/unsubscribe sont publics (pas d'auth JWT) pour pouvoir être cliqués
depuis un email reçu hors session.

## Ce qu'il fait

- `POST /subscribe` : crée un row `pending`, envoie un email avec un token signé
- `GET /confirm/:token` : flip à `confirmed` (public)
- `GET /unsubscribe/:token` : opt-out (public, idempotent)
- `POST /admin/campaigns/send` : envoie une campagne à tous les `confirmed` (admin only)
- `GET /admin/subscribers`, `GET /admin/stats` : admin metrics

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/subscribe` | Body `{ email, source? }` — public |
| `GET` | `/confirm/:token` | Public, idempotent |
| `GET` | `/unsubscribe/:token` | Public, idempotent |
| `GET` | `/admin/subscribers` | Pagination, filter par status |
| `GET` | `/admin/stats` | Counts par status / source |
| `POST` | `/admin/campaigns/send` | Body `{ template_id, segment? }` |
| `GET` | `/admin/campaigns/history` | Historique des campagnes |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Côté public (front)

```ts
await fetch('https://localhost:18443/newsletter/subscribe', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ email: 'user@example.com', source: 'footer' })
});
```

### Côté admin

```ts
await client.newsletter.admin.sendCampaign({
  template_id: 'q2-newsletter',
  segment: { source: 'footer' }
});
```

## Dépendances

- **email-service** : pour les emails confirm/unsubscribe/campaigns
- **Postgres** : tables `newsletter_subscribers`, `newsletter_campaigns`
- **JWT_SECRET** : signe les tokens confirm/unsubscribe (HS256)

## Gates qui le couvrent

- **M1** : audit, OpenAPI, healthcheck, AuditModule wired

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3090 |
| `DATABASE_URL` | Pool PG |
| `EMAIL_SERVICE_URL` | URL interne `http://email-service:3030` |
| `JWT_SECRET` | Signe les tokens confirm/unsubscribe (depuis Vault) |
| `NEWSLETTER_PUBLIC_BASE_URL` | URL publique inclue dans les emails |
