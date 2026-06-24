# Transport Security Contract

## Production Origins

Production public traffic must use browser-trusted CA-backed HTTPS only.

Canonical hosts:

- `https://vite-gourmand.fr`
- `https://www.vite-gourmand.fr` must redirect permanently to `https://vite-gourmand.fr`

Required production variables:

```properties
NODE_ENV=production
COOKIE_SECURE=true
FRONTEND_URL=https://vite-gourmand.fr
PUBLIC_SITE_URL=https://vite-gourmand.fr
VITE_PUBLIC_SITE_URL=https://vite-gourmand.fr
```

`VITE_API_URL` should be empty when the API is served from the same origin. If a separate API host is introduced, it must use `https://`.

## Required Controls

- HTTP must redirect to HTTPS with `301` or `308`.
- Production responses must include `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`.
- Public TLS certificates must come from a browser-trusted CA, such as Fly managed certificates, Let's Encrypt, or Cloudflare.
- Self-signed certificates are forbidden in production.
- Plain HTTP is allowed only for `localhost`, `127.0.0.1`, and `::1` in development and CI.

## Verification

Run:

```bash
scripts/security/verify-production-https.sh
```

The script validates DNS, certificate trust, certificate age, HTTP redirects, HSTS, and public pages.