# mini-baas-infra configuration

`mini-baas-infra.conf` is the tracked, TOML-style runtime configuration copied into the BaaS wrapper image at `/etc/mini-baas/mini-baas-infra.conf`.

## SMTP secrets architecture

SMTP credentials are never stored in the image or in tracked source files. The canonical local secret source is `opposite-osiris/.env.local`, which is ignored by Git. Runtime containers receive SMTP values from the host environment, typically with:

```bash
docker compose --env-file opposite-osiris/.env.local up -d baas
```

This is the project envelope-encryption boundary: any production secret manager or CI system decrypts the secret outside the image and injects only the runtime value into the container environment or mounted secret file. The Docker image contains only variable names and template paths.

The root `docker-compose.yml` forwards these variables to the BaaS container through `environment:` variable expansion:

- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_ENCRYPTION`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `SMTP_FROM_NAME`
- `SMTP_FROM_ADDRESS`

The tracked TOML bridge uses placeholders such as `${SMTP_HOST}` and never stores the SMTP password literal. The runtime process resolves those placeholders from environment variables.

### Docker secrets fallback

For Docker Swarm or Kubernetes production deployments, inject the SMTP password as a mounted secret instead of an environment variable. With Docker Swarm:

```bash
printf '%s' "$SMTP_PASSWORD" | docker secret create smtp_password -
```

Mount it read-only at `/run/secrets/smtp_password`, set file permissions equivalent to `chmod 400`, and configure the TOML key:

```toml
[smtp]
password_secret_path = "/run/secrets/smtp_password"
```

This mirrors SSH private-key handling: the secret file exists only at runtime and is readable only by the process that needs it.

## GoTrue SMTP mapping

The Supabase-compatible GoTrue service reads SMTP configuration from environment variables. The compose layer maps the generic project variables to GoTrue-specific names:

- `GOTRUE_SMTP_HOST` ← `SMTP_HOST`
- `GOTRUE_SMTP_PORT` ← `SMTP_PORT`
- `GOTRUE_SMTP_USER` ← `SMTP_USERNAME`
- `GOTRUE_SMTP_PASS` ← `SMTP_PASSWORD`
- `GOTRUE_SMTP_ADMIN_EMAIL` ← `SMTP_FROM_ADDRESS`
- `GOTRUE_SMTP_SENDER_NAME` ← `SMTP_FROM_NAME`
- `GOTRUE_MAILER_AUTOCONFIRM` ← `false`
- `GOTRUE_MAILER_URLPATHS_CONFIRMATION` ← `/auth/v1/verify`
- `GOTRUE_MAILER_URLPATHS_RECOVERY` ← `/auth/v1/verify`
- `SITE_URL` / `GOTRUE_SITE_URL` ← `PUBLIC_SITE_URL`

The local track-binocle compose profile also mounts `opposite-osiris/src/email-templates` to `/etc/gotrue/templates:ro` and points GoTrue confirmation/recovery templates at those files.

## Local CORS

The local `track-binocle` profile exposes the public API through Kong at `https://localhost:8000`. Astro dev servers may run on multiple ports, so the Kong CORS plugin allows these local HTTPS origins:

- `https://localhost:4322`
- `https://localhost:4321`
- `https://localhost:5173`
- `https://localhost:3000`
- `https://localhost:3001`
- `https://localhost:3100`

The active Kong template is:

- `apps/baas/mini-baas-infra/docker/services/kong/conf/kong.track-binocle.yml`

It allows these methods:

- `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`

It allows these browser request headers:

- `Authorization`
- `apikey`
- `Content-Type`
- `X-Client-Info`
- `X-Supabase-Api-Version`

Credentials are enabled and preflight responses are cached for `3600` seconds.

After editing the Kong template, restart Kong from the repository root:

```bash
docker compose up -d --force-recreate kong
```

Then verify the Docker services:

```bash
docker compose ps
CA=apps/baas/certs/track-binocle-local-ca.pem
curl --cacert "$CA" -fsS https://localhost:4322 >/dev/null
curl --cacert "$CA" -sS -o /dev/null -w 'auth-gateway-https-%{http_code}\n' https://localhost:8787/api/auth/availability
```

## Astro local proxy fallback

`apps/opposite-osiris/astro.config.mjs` defines a Vite dev proxy from `/api` to the Docker Kong service. Production frontend code should still call the public BaaS gateway URL and never connect directly to Postgres or internal services.

The proxy preserves any incoming `apikey` header.

## Security suite

The frontend package includes an outside-in security test suite. Run it through Docker-managed project scripts, not host dependency installs.

```bash
docker compose run --rm opposite-osiris node scripts/container-only.mjs vitest run scripts/security
```

Run one category:

```bash
docker compose run --rm opposite-osiris node scripts/container-only.mjs vitest run scripts/security -- --category=cors
```

The suite is documented in `opposite-osiris/scripts/security/README.md`. It is for testing infrastructure owned by this project only and must not be pointed at systems without explicit authorization.
