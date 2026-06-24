# Fly Service

This service provides Fly CLI tooling from Docker so the host machine does not need `flyctl` installed.

Common commands:

```bash
docker compose --profile tools build fly
docker compose --env-file .env.production --profile tools run --rm fly infrastructure/services/fly/scripts/status.sh
CREATE_CERTS=true docker compose --env-file .env.production --profile tools run --rm fly infrastructure/services/fly/scripts/certificates.sh
docker compose --env-file .env.production --profile tools run --rm fly infrastructure/services/fly/scripts/deploy.sh
```

Authentication options:

- Set `FLY_API_TOKEN` or `FLY_ACCESS_TOKEN` in `.env.production` or in the shell before running the service.
- Or run `docker compose --profile tools run --rm fly bash -lc "flyctl auth login"`; auth state persists in the `fly-data` Docker volume.

When `FLY_API_TOKEN` is present, the container maps it to `FLY_ACCESS_TOKEN` for `flyctl` automatically.