# Environment Configuration

## Production HTTPS Requirement

Production must be served only through a publicly trusted CA-backed `https://` origin. Do not use self-signed certificates or plain `http://` public URLs for the website, API, OAuth callbacks, canonical URLs, cookies, or CORS origins.

Required production values:

```properties
NODE_ENV=production
COOKIE_SECURE=true
FRONTEND_URL=https://vite-gourmand.fr
PUBLIC_SITE_URL=https://vite-gourmand.fr
VITE_PUBLIC_SITE_URL=https://vite-gourmand.fr
```

Use `VITE_API_URL=` when the frontend and API share the same HTTPS origin. If the API is hosted on a separate origin, set it to an HTTPS URL:

```properties
VITE_API_URL=https://api.vite-gourmand.fr
```

Local development and CI are the only places where `http://localhost`, `http://127.0.0.1`, or `http://[::1]` are allowed.

## Certificate Authority Policy

The public TLS certificate must be issued by a trusted CA such as Let's Encrypt, Fly managed certificates, Cloudflare, or another browser-trusted authority. Production must not rely on self-signed certificates because browsers cannot trust them consistently and HSTS would make recovery painful.

For the Fly deployment, request and inspect managed certificates with:

```bash
HOSTS="vite-gourmand.fr www.vite-gourmand.fr" \
CREATE_CERTS=true \
make deploy-certs
```

Then verify the live site with:

```bash
scripts/security/verify-production-https.sh
```

## Runtime Enforcement

- `Back/src/main.ts` validates production public origins and rejects `http://` values.
- Production traffic is redirected to HTTPS with a permanent `308` redirect when the proxy reports `X-Forwarded-Proto: http`.
- Helmet sends `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` in production.
- Secure cookies are required with `COOKIE_SECURE=true`.
- CI checks `infrastructure/services/fly/config/fly.toml`, backend HTTPS enforcement, HSTS, production URL values, and the certificate verification scripts.
