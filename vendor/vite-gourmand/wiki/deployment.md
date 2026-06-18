# Deployment

## Production TLS Certificates

The production website must be served through a browser-trusted CA certificate. For the Fly app configured in `infrastructure/services/fly/config/fly.toml`, use Fly managed certificates for both the apex and `www` hostnames.

Fly is run through Docker Compose, so the host does not need `flyctl`. Put `FLY_API_TOKEN` or `FLY_ACCESS_TOKEN` in local `.env.production`; the repository wrappers load that file automatically and the Fly container maps `FLY_API_TOKEN` to `FLY_ACCESS_TOKEN` for `flyctl`.

Interactive auth is still available and is stored in the `fly-data` Docker volume:

```bash
docker compose --profile tools run --rm fly bash -lc "flyctl auth login"
```

Inspect the Fly app IPs and request managed certificates:

```bash
HOSTS="vite-gourmand.fr www.vite-gourmand.fr" \
CREATE_CERTS=true \
make deploy-certs
```

Point DNS to the Fly app before certificates can become `Ready`:

- `vite-gourmand.fr`: create `A` and `AAAA` records to the IPs from `flyctl ips list -a vite-gourmand-withered-glitter-7902`.
- `www.vite-gourmand.fr`: create a `CNAME` to `vite-gourmand-withered-glitter-7902.fly.dev`, or use the same `A`/`AAAA` records if the DNS provider does not allow CNAME flattening.

After DNS propagation, verify the live site:

```bash
scripts/security/verify-production-https.sh
```

The verifier checks DNS resolution, CA trust, certificate expiry, HTTP-to-HTTPS redirects, HSTS, and the public page URLs.

Current observation from this workspace: `vite-gourmand.fr` and `www.vite-gourmand.fr` present trusted Let's Encrypt certificates and serve pages over HTTPS, but HSTS is missing and DNS resolves to `37.59.124.193` and `213.186.33.5`. Before considering production complete, DNS should point cleanly to the selected hosting layer and the verifier must pass.

## Current Host-Layer Fixes

The live check currently shows:

- `https://vite-gourmand.fr` and `https://www.vite-gourmand.fr` have trusted Let's Encrypt certificates, but no HSTS header.
- `http://www.vite-gourmand.fr` returns `200` instead of redirecting to HTTPS.
- DNS currently resolves to `37.59.124.193` and `213.186.33.5`, which does not look like the Fly app path configured in `infrastructure/services/fly/config/fly.toml`.

Repository-side host config is included for both likely serving layers:

- `View/public/.htaccess` is copied into the frontend build for Apache/OVH-style static hosting and redirects all HTTP/www traffic to `https://vite-gourmand.fr` with HSTS headers.
- `docs/nginx-vite-gourmand-https.conf` is a ready-to-apply Nginx template for the current apex-style server. Install it on the production host if Nginx remains the serving layer.

After applying either host-layer config and reloading the server, run:

```bash
scripts/security/verify-production-https.sh
```
