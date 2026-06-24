# Infrastructure

This directory is the source of truth for Docker-managed infrastructure.

## Layout

```text
infrastructure/
├── contracts/
│   ├── secrets.md
│   └── transport-security.md
└── services/
	├── app/
	├── dev/
	├── fly/
	├── mongo/
	├── postgres/
	└── secrets/
```

Each service owns:

- `Dockerfile`: image definition used by Docker Compose.
- `config/`: non-secret configuration owned by that service.
- `scripts/`: service-local operational scripts or notes.

## Fly Without Host flyctl

Fly is available through Docker only:

```bash
docker compose --profile tools build fly
docker compose --env-file .env.production --profile tools run --rm fly infrastructure/services/fly/scripts/status.sh
docker compose --env-file .env.production --profile tools run --rm fly infrastructure/services/fly/scripts/deploy.sh
```

Local `.env.production` may contain `FLY_API_TOKEN` or `FLY_ACCESS_TOKEN`; the Fly container maps `FLY_API_TOKEN` for `flyctl` automatically. This file is ignored by Git.

The Fly config is now:

```text
infrastructure/services/fly/config/fly.toml
```

Root Make targets call the Dockerized Fly service, so the host does not need `flyctl` installed.

## Certificate Verification

```bash
scripts/security/verify-production-https.sh
```

This checks DNS, CA trust, certificate expiry, HTTP-to-HTTPS redirects, HSTS, and public pages.
