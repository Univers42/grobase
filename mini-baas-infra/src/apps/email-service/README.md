# email-service

**Port interne** : `3030` · **Container** : `mini-baas-email-service` · **Profile** : `background`

Envoi d'emails **transactionnels** (templated). Wrappe SMTP / SendGrid / SES
derrière un seul `POST /send`. Les templates sont resolved à l'envoi via
`@nestjs/event-emitter`.

## Ce qu'il fait

- `POST /send` : envoie un email à partir d'un template (`template_id`, `variables`)
- Logs chaque envoi dans `audit_log` + dans `email_logs` (PG)
- Backoff exponentiel en cas d'échec SMTP (jusqu'à 5 retries)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/send` | Envoie ; body `{ to, template_id, variables, reply_to? }` |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
await client.email.send({
  to: 'user@example.com',
  template_id: 'welcome',
  variables: { name: 'Alice', activation_url: 'https://…' }
});
```

### Via Kong

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/email/send" \
  -d '{"to":"user@example.com","template_id":"welcome","variables":{"name":"Alice"}}'
```

### En dev — récupérer les mails (Mailpit)

En local, SMTP pointe vers le container `mailpit` :

```bash
# UI Mailpit
open http://localhost:8025

# API JSON
curl http://localhost:8025/api/v1/messages
```

## Dépendances

- **SMTP backend** : `mailpit` (dev), SendGrid / AWS SES / Mailgun (prod via Vault `SMTP_URL`)
- **Postgres** : table `email_logs` + `audit_log`
- **Vault** : `SMTP_URL`, `SMTP_USERNAME`, `SMTP_PASSWORD`

## Gates qui le couvrent

- **M1** : audit interceptor, OpenAPI, healthcheck

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3030 |
| `SMTP_URL` | DSN SMTP (depuis Vault) |
| `EMAIL_FROM` | Adresse expéditeur par défaut |
| `EMAIL_FROM_NAME` | Nom expéditeur (default `Osionos`) |
| `DATABASE_URL` | Pool PG (audit + email_logs) |
