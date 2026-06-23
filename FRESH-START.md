# Fresh-Start — Grobase from a clean machine (fetch + make)

Clean PC → working backend + apps, with **all secrets fetched from vault42** (none in the repo).
The contract: **`42ctl pull` then `make`** — secrets come from vault42, code from git.

## 0. Prereqs
Docker + Docker Compose v2 only (no host Node/cargo/Go — `make` builds everything in containers),
plus `git`, `openssl`, and the `42ctl` binary.
```bash
git clone https://github.com/Univers42/grobase && cd grobase
```

## 1. Fetch ALL secrets from vault42  (any depth, one command)
Every `*.env`/`*.secrets` (root **and** nested: `build/website.env`, `vendor/vite-gourmand/View/.env`,
`.gourmand-baas.env`, …) is stored path-aware in vault42. A fresh machine restores them all:
```bash
42ctl keys recover                       # email-OTP + your passphrase → your keystore on this PC
42ctl pull --project grobase --apply     # restores the WHOLE env tree, byte-exact, at its paths
```
> To (re)populate vault42 from a working tree, push the whole tree from the **repo root** (not a
> staging dir): `42ctl push --project grobase` — it scans `*.env*`/`*.secrets` recursively.
> Verified: 14 files pushed → pulled back **byte-exact**.

If you have no keystore yet (truly first machine), `make env` generates a fresh local set instead.

## 2. Build & run — `make`
```bash
make up PACKAGE=pro     # kong + gotrue + postgres + data/query planes + storage + realtime
make health
```
Fresh-machine gotchas (each is one command):

| Symptom | Fix |
|---|---|
| `db-bootstrap` exit 2, `password authentication failed for user "postgres"` | stale data volume vs fetched `.env` → `make fclean CONFIRM=1` then `make up PACKAGE=pro` |
| `tenant-control`/`adapter-registry` crash-loop (*"public.tenants missing"*) | `make migrate` then `docker compose restart tenant-control adapter-registry-go` |
| `query-router` stuck **Created** | `docker start mini-baas-query-router` |
| app query `name resolution failed` after provisioning a mount | `docker compose restart data-plane-router-rust` (reopens pools) |

## 3. Apps
Kong port: `docker port mini-baas-kong 8000/tcp`.

**grobase-website** (`~/Documents/grobase-website`, Astro — needs Node 22):
```bash
KONG_URL=http://127.0.0.1:8000 bash scripts/provision-contract.sh infra/config/contracts/website.json
sed 's#^PUBLIC_GROBASE_URL=.*#PUBLIC_GROBASE_URL=#' build/website.env > ~/Documents/grobase-website/.env.production
docker run --rm -e GROBASE_IN_DOCKER=1 -e NODE_ENV=production -v ~/Documents/grobase-website:/app -w /app \
  -v gw-nm:/app/node_modules node:22-alpine sh -c 'npm ci --ignore-scripts && npx astro build'
docker run -d --name gw-serve --network mini-baas_mini-baas -p 5190:5190 \
  -e PORT=5190 -e BINOCLE_URL=http://kong:8000 -e DIST=/app/dist \
  -v ~/Documents/grobase-website:/app -w /app node:22-alpine node scripts/serve.mjs   # → :5190
```

**vite-gourmand** (`vendor/vite-gourmand`, React/Vite):
```bash
bash scripts/seed/gourmand-baas.sh                 # tenant + mbk_ key + demo users + View config
docker run --rm -v "$PWD/vendor/vite-gourmand/View":/app -w /app -v vg-nm:/app/node_modules \
  node:20-alpine sh -c 'npm ci && npx vite build'
GOURMAND_PORT=5180 docker compose --profile gourmand up -d --no-deps gourmand   # → :5180
```
Owner-scoped reads need `read_scoped:true` on the mount (the contract/seed set it) — or global
`DATA_PLANE_PG_READ_PREDICATE=1` (already in the fetched `.env`); restart the data-plane after.
Demo login: `admin@gourmand.local` / `Gourmand#2026`.

Verified working: grobase-website signup/login + owner-scoped data; vite-gourmand shared catalog +
admin-bypass + per-user owner-scoping.

## Reset
```bash
make clean              # this project's images/containers/caches — KEEPS data + other projects
make fclean CONFIRM=1   # + wipe this project's data volumes (true fresh)
make re                 # clean → build → up
```
