# Secrets Contract

## Sources

Secrets must be injected at runtime from one of these sources:

- Docker environment variables passed to Compose services.
- Local `.env.production` for Dockerized production tooling such as Fly CLI auth.
- Bitwarden through the `secrets` Docker Compose service.
- Fly secrets managed with `flyctl secrets set` through the `fly` Docker Compose service.
- CI secret stores such as GitHub Actions secrets.

## Forbidden Locations

Secrets must not be committed to:

- `infrastructure/contracts/`
- `infrastructure/services/*/config/`
- `.env.production.example`
- `.env.production`
- `docs/`
- `docker-compose.yml`
- `infrastructure/services/fly/config/fly.toml`

## Fly Secrets

Use the Dockerized Fly service:

```bash
docker compose --env-file .env.production --profile tools run --rm fly bash -lc 'flyctl secrets set KEY=value -a vite-gourmand-withered-glitter-7902'
```

The service accepts either `FLY_API_TOKEN` or `FLY_ACCESS_TOKEN`; if only `FLY_API_TOKEN` is present, the container maps it to `FLY_ACCESS_TOKEN` before running `flyctl`.

Do not put real secret values in `infrastructure/services/fly/config/fly.toml`; keep only non-secret production defaults there.

## Local Development

Local backend secrets belong in `Back/.env`. Fetch them through:

```bash
make secrets
```

`Back/.env` remains local-only and must not be committed.