# grobase on fly.io — single-Machine production deploy

The whole grobase backend (Postgres + Go control plane + Rust data plane + Kong +
GoTrue + realtime) on **one fly Machine** running the published GHCR images via
docker-compose. A fly Machine is a real Firecracker VM, so an inner `dockerd`
works (Docker-in-Docker) — this keeps the *exact* compose wiring that's tested
locally (service DNS, `depends_on`, healthchecks) instead of re-plumbing ~17
services into separate fly apps. **Kong is the only public door**; every other
service stays on the inner docker network.

## What it runs

`boot.sh` (the image entrypoint) on each start:

1. starts `dockerd` with its data-root on the `/data` fly volume (images + PG data persist),
2. clones/updates `github.com/Univers42/grobase` (main) into `/data/grobase`,
3. assembles `.env` (`config.env` + generated `.env.secrets` + a fly `.env.local`
   that sets `API_EXTERNAL_URL=https://<host>/auth/v1` — the one var that aligns
   GoTrue's `iss` with Kong's verifier — plus `EMAIL_OTP_ENABLED`, mailpit SMTP, strict identity),
4. brings up GoTrue first (creates `auth.users`), **then** runs the SQL migrations
   (order matters: migration 007 references `auth.users`), marks `/data/.migrated`,
5. brings up the curated 17-service set, restarts the control plane so
   adapter-registry's `ensureSchema` (which `ADD COLUMN isolation`) sees the migrated DB,
6. auto-provisions the contracts (`infra/config/contracts/{website,vault42}.json`)
   into separate grobase-owned Postgres databases — idempotent, marked `/data/.provisioned`.

`compose.override.yml` republishes Kong on `0.0.0.0:8000` (base compose binds it to
loopback because WAF is the public door in the full topology); fly's edge terminates TLS.

## Deploy / operate

```bash
export FLY_API_TOKEN=...                 # never commit; from the secrets store
fly apps create grobase-stack --org personal
fly volumes create grobase_data --size 20 --region cdg --app grobase-stack
fly deploy --remote-only --config fly.toml --app grobase-stack --ha=false
fly logs --app grobase-stack             # watch boot
fly ssh console --app grobase-stack -C "sh -lc 'cd /data/grobase && docker compose -f docker-compose.yml -f /opt/compose.override.yml ps'"
```

**One-shot DB reset:** bump `RESET` in `fly.toml` to a new value → next boot runs
`docker compose down -v` once (guarded by `/data/.reset_token`) and re-migrates +
re-provisions from scratch. Leave it unchanged for normal restarts (data persists).

## Verified live (2026-06-21)

- 14 services healthy; Kong public on `https://grobase-stack.fly.dev`.
- Two **physically separate** grobase-owned Postgres DBs: `website`, `vault42` (never merge).
- Per-user read isolation (`read_scoped`): insert as user A stamps
  `owner_id=user:<jwt-sub>`; A lists its row, **B lists 0** — proven via `/query/v1`.

## Footprint / cost

shared-cpu-4x / 8 GB for the first boot (trim with `fly scale memory` once measured;
~17 light Go/Rust binaries + postgres/mongo/redis idle well under that). ~$15–30/mo
+ the 20 GB volume. Frontends live on Vercel (free), talking to this over HTTPS.
