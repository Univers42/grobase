# Quickstart — Grobase BaaS in 5 minutes

Two ways in. **Path A** is a single static binary (no Docker, no root). **Path B** is the
full self-hosted stack via Docker Compose. Pick one.

> In the `ft_transcendence` monorepo this directory is `apps/baas/mini-baas-infra/`;
> as a standalone checkout it is the repo root. All commands below run from here.

---

## Path A — single binary (binocle)

The PocketBase-class editions: one static `linux-amd64` binary, embedded SQLite,
zero dependencies.

| Edition | What you get | Measured |
|---|---|---|
| **binocle-one** | accounts (email/password, OAuth2-PKCE — 11 presets + any-OIDC, TOTP MFA), file storage, filtered SSE realtime, admin UI at `/_/` | 6.41 MB image / ~2.2 MiB idle RSS |
| **binocle-nano** | headless data plane: CRUD + schema + graph + scoped API keys + SSE | 5.1 MB image / ~2.0 MiB idle RSS |

```sh
# install (verifies sha256; BINOCLE_EDITION=nano for headless)
curl -fsSL https://github.com/Univers42/groot/releases/download/baas-v1.0.0/install.sh | sh

./binocle-one
#  → admin key printed on FIRST boot only — save it
#  → admin UI: http://localhost:8090/_/
#  → data API: http://localhost:8090/data/v1   (data lives in ./data)
```

Prefer Docker? The same editions are images:

```sh
docker run -d -p 8090:8090 -v one-data:/data dlesieur/binocle-one:1.0.0
```

First request:

```sh
curl -s http://localhost:8090/data/v1/query \
  -H "X-Baas-Api-Key: <admin key from first boot>" \
  -H "content-type: application/json" \
  -d '{"db_id":"local","operation":{"op":"list","resource":"_keys","limit":1}}'
```

---

## Path B — the full stack (Docker Compose)

Prerequisites: `git`, `make`, `curl`, Docker with the compose plugin. ~1 GB RAM
for the default tier.

```sh
git clone https://github.com/Univers42/groot.git
cd ft_transcendence/apps/baas/mini-baas-infra

make quickstart                  # .env (generated, chmod 600) → stack up → health
# or pick a tier explicitly:
make quickstart PACKAGE=basic    # Node-free Pi-class (~460 MiB)
```

What you now have (default tier `essential`):

- **Gateway** `http://localhost:8000` — the only public door (Kong)
- **Auth** `/auth/v1` (GoTrue: signup, login, JWT)
- **REST** `/rest/v1` (PostgREST over Postgres with RLS)
- **Data plane** `/data/v1` (Rust router — CRUD/aggregate on every engine)
- **Realtime** `/realtime/v1` (WebSocket)

First authenticated request:

```sh
APIKEY=$(grep '^KONG_PUBLIC_API_KEY=' .env | cut -d= -f2)
curl -s http://localhost:8000/auth/v1/health -H "apikey: ${APIKEY}"
```

From a frontend, use the SDK — it ships in this repo (no npm registry
involved; distribution is Docker Hub + this repo by design):

```sh
# as a file dependency from a checkout
npm install ./apps/baas/sdk
# or straight from git
npm install git+https://github.com/Univers42/groot.git#main:apps/baas/sdk
```

```ts
import { createClient } from '@mini-baas/js';
const client = createClient({ url: 'http://localhost:8000', anonKey: process.env.BAAS_ANON_KEY });
const data = await client.from('todos').query().select('*').limit(10);
```

> Coming from Supabase? The SDK is Supabase-shaped — see
> **[migrate-from-supabase](../wiki/migrate-from-supabase.md)** (mostly a
> dependency swap). From Firebase? See
> **[migrate-from-firebase](../wiki/migrate-from-firebase.md)**.

### Choosing your size

Every tier is a measured, repeatable shape (`make up PACKAGE=<tier>`):

| Tier | RAM (measured) | Services | You get |
|---|---|---|---|
| **basic** | ~460 MiB | 11 (0 Node) | CRUD on SQLite+Postgres through the Rust plane |
| **essential** | ~660 MiB | 13 | + aggregates, Go orchestrator (default) |
| **pro** | ~1.4 GiB | 28 | + MySQL/Mongo/Redis/Cockroach, realtime, storage, txns |
| **max** | ~3.5 GiB | 41 | + MSSQL/HTTP, DDL, analytics (Trino), observability |

Add-ons compose: `make up PACKAGE=basic ADDONS="realtime"`.

---

## Next steps

- **[DEPLOYMENT.md](DEPLOYMENT.md)** — production overlay, hardware sizing, backups/restore, upgrades
- **[SECURITY.md](SECURITY.md)** — the security model + the production checklist
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — when something doesn't start
- `make help` — every operation the stack supports
