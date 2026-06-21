# grobase-stack — backup, restore & secret rotation runbook

Operations for the live single-Machine deploy (`grobase-stack.fly.dev`, see
[`README.md`](README.md)). Postgres runs **inside** the Machine as the
`mini-baas-postgres` container on the `/data` fly volume (`grobase_data`) and owns
two databases: **`website`** and **`vault42`**. There is **no host flyctl** — every
command below runs flyctl from the `flyio/flyctl` Docker image and reaches into the
Machine over `fly ssh console`.

```sh
# convenience alias used throughout (export your token from the secrets store first)
export FLY_API_TOKEN=...
fly() { docker run --rm -i -e FLY_API_TOKEN flyio/flyctl:latest "$@"; }
# interactive (TTY) variant for shells / restores:
flyt() { docker run --rm -it -e FLY_API_TOKEN flyio/flyctl:latest "$@"; }
```

---

## 1. Durability layers

Three independent layers, weakest blast-radius first.

### (a) fly volume scheduled snapshots — whole-volume, automatic

`grobase_data` has **scheduled snapshots with 5-day retention** (fly default daily).
This captures the *entire* volume: PG data dir, mongo, redis, docker images, the
cloned repo, every marker file. Coarse but free and automatic.

```sh
VOL=$(fly volumes list --app grobase-stack --json | docker run --rm -i ghcr.io/jqlang/jq -r '.[0].id')
fly volumes snapshots list "$VOL"              # list snapshots + ids + ages
fly volume snapshots create "$VOL"             # take an on-demand snapshot now
```

### (b) logical per-DB backup — granular, portable

A `pg_dump` of one database. Restores into a fresh DB without touching the other,
survives a PG major-version bump, and is diffable. Run it before any risky migration.

```sh
# dump ONE database to a local gzip (read-only on the server)
fly ssh console --app grobase-stack \
  -C "sh -lc 'docker exec -i mini-baas-postgres pg_dump -Fc -U postgres -d website'" \
  > website-$(date -u +%Y%m%dT%H%M%SZ).dump      # -Fc = custom format (for pg_restore)
fly ssh console --app grobase-stack \
  -C "sh -lc 'docker exec -i mini-baas-postgres pg_dump -Fc -U postgres -d vault42'" \
  > vault42-$(date -u +%Y%m%dT%H%M%SZ).dump
```

### (c) off-fly ZK backup of the vault42 envelopes — the important one

`vault42.public.vault42_secrets` holds vault42-server's **zero-knowledge** secret
envelopes (opaque base64 `envelope` + `owner_id` + `author_pubkey`; the server never
holds plaintext). Because the blobs are already client-side encrypted, an off-fly copy
**leaks nothing** — that is the whole point: you can store this backup anywhere
(another cloud, cold storage, a laptop) without expanding the trust boundary.

```sh
FLY_API_TOKEN=$FLY_API_TOKEN bash scripts/ops/backup-vault42-envelopes.sh
# → ./build/backups/vault42-envelopes-<ts>.sql.gz  (+ printed sha256)
# copy the .sql.gz off-fly; record the sha256 alongside it.
```

This dumps only `public.vault42_secrets` + `public.vault42_audit` (read-only,
pg_dump only). It is the layer you copy *off the platform* for true durability —
(a) and (b) still live on fly.

---

## 2. Restore procedures

> Restores are **disruptive writes**. Stop the writers (`gotrue`, the data plane,
> vault42-server) or take a maintenance window before restoring into a live DB.

### Restore layer (a) — whole volume from a snapshot

A volume restore creates a **new** volume from a snapshot; you then re-point the
Machine at it. This rolls back *everything* on `/data`.

```sh
fly volumes snapshots list "$VOL"                       # pick a snapshot id
fly volume create grobase_data_restored \
  --snapshot-id <snapshot-id> --size 20 --region cdg --app grobase-stack
# then update fly.toml [[mounts]] source -> grobase_data_restored and re-deploy:
fly deploy --remote-only --config deploy/fly/fly.toml --app grobase-stack --ha=false
# verify, then destroy the stale volume once happy:  fly volumes destroy <old-vol-id>
```

### Restore layer (b)/(c) — logical, one DB or one table set

Stream the dump back through `fly ssh console` into `pg_restore` (custom format) or
`psql` (plain SQL from the ZK script / script c output).

```sh
# (b) custom-format dump → pg_restore into the SAME db (clean+recreate objects)
gzip -dc website-<ts>.dump.gz 2>/dev/null || cat website-<ts>.dump \
  | fly ssh console --app grobase-stack \
      -C "sh -lc 'docker exec -i mini-baas-postgres pg_restore --clean --if-exists -U postgres -d website'"

# (c) the ZK script emits plain SQL → psql.  Restore vault42 envelopes:
gzip -dc build/backups/vault42-envelopes-<ts>.sql.gz \
  | fly ssh console --app grobase-stack \
      -C "sh -lc 'docker exec -i mini-baas-postgres psql -v ON_ERROR_STOP=1 -U postgres -d vault42'"
```

Restoring into a **fresh** database instead (safest — verify, then swap):

```sh
fly ssh console --app grobase-stack \
  -C "sh -lc 'docker exec -i mini-baas-postgres createdb -U postgres vault42_restore'"
gzip -dc build/backups/vault42-envelopes-<ts>.sql.gz \
  | fly ssh console --app grobase-stack \
      -C "sh -lc 'docker exec -i mini-baas-postgres psql -v ON_ERROR_STOP=1 -U postgres -d vault42_restore'"
# inspect, then point vault42-server's DSN at it (or rename) and restart the writer.
```

Always confirm the **sha256** of a layer-(c) artifact before trusting a restore.

---

## 3. Secret rotation

### 3.1 The shared `GOTRUE_JWT_SECRET` (the load-bearing one)

One secret value, **three holders**. In grobase it is generated as `JWT_SECRET` and
exported to GoTrue/Kong as `GOTRUE_JWT_SECRET`; the other two apps read it under their
own var names:

| # | Holder | App / location | Env var | Uses it to |
|---|---|---|---|---|
| 1 | grobase-stack GoTrue **+** Kong | `grobase-stack` (in the Machine's `.env.secrets` as `JWT_SECRET` → `GOTRUE_JWT_SECRET`) | `JWT_SECRET` | GoTrue **issues/verifies** user sessions; Kong **verifies** them |
| 2 | vault42-server | `vault42` (fly secret) | `JWT_SECRET` | **mints per-user JWTs** to call grobase `/query/v1` |
| 3 | vault42-contract | `vault42` (fly secret) | `GOTRUE_JWT_SECRET` | **verifies the OTP-proof JWT** |

**This is HS256 — one symmetric secret shared by all three.** Rotating it:

- **invalidates every existing GoTrue session** (users are logged out — they re-auth);
- **breaks vault42-server → `/query/v1` and vault42-contract OTP verification** until
  apps 2 and 3 carry the new value too.

So it is **irreversible + disruptive** and needs a **maintenance window** with a
*coordinated* update — there is no zero-downtime ordering for a single symmetric
secret. Update **all three holders to the same new value as close together as
possible**, grobase last (so verifiers 2/3 are already on the new secret when the new
issuer 1 starts minting), then restart.

```sh
# 0. ANNOUNCE a maintenance window. Generate ONE new value, reuse it everywhere.
NEW=$(openssl rand -base64 48 | tr -d '\n')

# 1. vault42-server + vault42-contract (the verifiers / minters) — same app.
#    (fly secrets set triggers a rolling restart by default.)
fly secrets set JWT_SECRET="$NEW" GOTRUE_JWT_SECRET="$NEW" --app vault42

# 2. grobase-stack (the issuer). The secret lives in the Machine's persisted
#    /data/env.secrets (JWT_SECRET=...). Update it there, then restart the stack so
#    GoTrue+Kong pick it up. Edit in place over ssh:
flyt ssh console --app grobase-stack \
  -C "sh -lc 'cd /data && sed -i \"s|^JWT_SECRET=.*|JWT_SECRET=$NEW|\" env.secrets && \
      cd grobase && docker compose -f docker-compose.yml -f /opt/compose.override.yml \
      up -d --force-recreate gotrue kong'"
#    (a full machine restart — `fly machine restart` — also works; boot.sh re-reads
#     /data/env.secrets and re-assembles .env. Slower but simpler.)

# 3. VERIFY: a fresh GoTrue login works on grobase-stack, and a vault42 round-trip
#    (store + read an envelope) succeeds. Then close the window.
```

> Do **not** rotate one holder and not the others — a partial rotation is a hard
> outage for vault42 (server can't call `/query/v1`, contract rejects every OTP) with
> no error that names the cause. If a rotation half-lands, re-apply the SAME `$NEW` to
> the lagging holder; never roll forward to a third distinct value.

### 3.2 A tenant's scoped API key (`mbk_…`)

Per-tenant keys are independent of the JWT secret and rotate **without** a window —
mint the new one, re-emit the frontend config, then revoke the old.

```sh
# Issue a fresh scoped key for the tenant (admin / control-plane route; the
# provisioner uses POST /v1/tenants/<tenant>/keys with {name,scopes}). HMAC-signed.
#   scopes ["read","write"] for a browser key — NEVER the provision default admin key.
# Easiest path: re-run the contract provisioner, which mints+verifies+re-emits idempotently:
flyt ssh console --app grobase-stack \
  -C "sh -lc 'cd /data/grobase && KONG_URL=http://127.0.0.1:8000 \
      bash scripts/provision-contract.sh infra/config/contracts/website.json'"
#   → re-writes the frontend_config target (PUBLIC_API_KEY=mbk_… / VITE_BAAS_API_KEY).
#   Re-deploy / re-publish the frontend (Vercel) so it ships the new key.

# Revoke the old key once the frontend is live on the new one (self-serve/admin
# keys endpoint: DELETE the stale key id). Keep both valid only for the cutover window.
```

Because the key resolves to a **per-request owner-scoped identity**, a leaked/rotated
key never exposes another tenant's data — rotation is hygiene, not an emergency.

---

## 4. Cadence (suggested)

| Layer | When |
|---|---|
| (a) volume snapshots | automatic daily, 5-retention — verify monthly that a snapshot exists |
| (b) logical per-DB dump | before every migration / risky deploy; weekly otherwise |
| (c) off-fly ZK envelope backup | daily/weekly via `scripts/ops/backup-vault42-envelopes.sh`, copied off-fly + sha256 recorded |
| JWT secret rotation | only on suspected compromise or policy schedule — always windowed |
| `mbk_` key rotation | on leak/offboarding; otherwise per policy — no window |
