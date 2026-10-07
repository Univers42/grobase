# Fresh-Start — Grobase from a clean machine (fetch + make)

Clean PC → working backend + apps, with **all secrets fetched from vault42** (none in the repo).
The contract: **`make ctl-remote ARGS="pull …"` then `make up`** — secrets from vault42, code from git.

## 0. Prereqs
**Docker + Docker Compose v2, `git`, `openssl`** — nothing else. No host Node/cargo/Go, and **no 42ctl
install**: it runs from its published image (`dlesieur/42ctl`, 33 MB scratch+musl) through `make ctl-remote`.
```bash
git clone https://github.com/Univers42/grobase && cd grobase
```

## 1. Fetch ALL secrets from vault42 (remote, any depth)
Every `*.env`/`*.secrets` (root **and** nested) is stored path-aware in **vault42** under the
environment's scope key, so every member the authority granted can read it. Three commands restore
the tree byte-exact on any machine — proven: **11 files pushed → pulled into a scratch tree →
byte-identical, modes preserved**.

`make ctl42` runs the published 42ctl image against the live fly stack (no clone, no cargo). On first
use it writes the `~/.config/42ctl/config.json` profile for you and mounts this repo so a pull lands
the tree here. A host binary works too: install the SHA256-verified release from
`Univers42/42ctl` and call `42ctl` directly.

```bash
FT_PASSPHRASE='<passphrase>' make ctl42 ARGS="keys recover --email <you@example.com>"   # emailed code → your keypair
make ctl42 ARGS="auth login --password --email <you@example.com>"                       # session
make ctl42 ARGS="auth login --tenant grobase"                                           # contract (the gRPC store needs one)
make vault-pull-env APPLY=1                                                             # restores the tree for this GROBASE_ENV
```
- The **passphrase** unlocks your escrowed keystore. `keys escrow` must have been run once on the
  machine that owns it, or there is nothing to recover — zero-knowledge means no reset exists.
  Identity persists in `~/.config/42ctl`, deliberately **outside** the worktree.
- The profile it writes: `server=vault42-server.fly.dev` (the gRPC store) ·
  `authority=vault42-authority.fly.dev` (accounts, orgs, teams, projects, contracts, and the
  email-code + escrow routes) · `grobase=` empty, so those routes default to the authority.
  **`vault42.fly.dev`, `grobase-nano.fly.dev` and `grobase-stack.fly.dev` are dead**, and the first
  two are other people's apps — a profile seeded with them authenticates you against a stranger's
  authority. Gate `m216` keeps them out of every seeded profile.
- `make vault-pull-env` / `vault-push-env` use the **team** path by default (org `univers-42`,
  project `grobase`, environment from `GROBASE_ENV`). Sharing is encryption, not RBAC: a tree pushed
  the personal way (`VAULT_ENV_PERSONAL=1`) is unreadable by teammates whatever their org role.
- A team push seals `vendor/` to you alone — those are other apps' credentials.

If you have no vault42 account yet, `make env` generates a fresh local secret set instead.

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

## Reset
```bash
make clean              # this project's images/containers/caches — KEEPS data + other projects
make fclean CONFIRM=1   # + wipe this project's data volumes (true fresh)
make re                 # clean → build → up
```
