# Grobase

**A self-hostable Backend-as-a-Service: one backend, any frontend, no per-project server code.**

Grobase gives any application a complete backend over plain HTTP — auth, relational + document
data, realtime, object storage, email, and a multi-tenant query plane — with **swappable engines,
isolation models, and editions on one codebase, no rewrite**. The same code scales from a **5 MB
single binary to a 10K-tenant platform**.

It is a **live product mid-migration (TypeScript → Rust data plane)**: Rust is the sole live data
path; legacy TypeScript engine code is retained behind a deletion gate (see
[`wiki/archive/cutover-status.md`](wiki/archive/cutover-status.md)), not deleted. Beyond OSS self-host, Grobase also
runs as a **managed cloud** (sign-up → API key → CRUD/realtime → usage → Stripe billing) and an
**enterprise-procurable** platform (orgs/RBAC, SSO/SCIM, audit, compliance, CMEK) — every
cloud/enterprise behavior is **flag-gated OFF by default** so the stack stays byte-parity with the
OSS edition.

---

## Where things live

> **The repo root is the buildable system, driven by the root [`Makefile`](Makefile)** — a thin
> orchestrator that includes the fragments under `orchestrators/makes/`. Run every lifecycle
> command from the repo root.

`src/` (application, control and data planes) · `infra/config/` and `infra/docker/` (config and
Docker build contexts) · `orchestrators/compose/` (plane files and overlays) ·
`orchestrators/makes/` (Makefile fragments) · `sdks/` · `scripts/` (grouped by family — see
[`scripts/README.md`](scripts/README.md)) · `deploy/` · `wiki/` · `vendor/` (playground apps
re-platformed onto Grobase). `HUMAN-ATOMS.md` is supporting material. The marketing site is not in
this repo (there is no `site/` directory).

---

## Quickstart

```sh
git clone https://github.com/Univers42/grobase.git
cd grobase

make quickstart          # .env (generated, chmod 600) → stack up → health (default tier: essential)
```

What you get (gateway is the only public door, `http://localhost:8000`):

- **Auth** `/auth/v1` (GoTrue: signup, login, JWT)
- **REST** `/rest/v1` (PostgREST over Postgres with RLS)
- **Data plane** `/data/v1` (Rust router — CRUD/aggregate on every engine)
- **Realtime** `/realtime/v1` (WebSocket)

Prefer a single static binary (no Docker, no root)? The PocketBase-class editions:

| Edition | What you get | Measured |
|---|---|---|
| **binocle-nano** | headless data plane: CRUD + schema + graph + scoped API keys + SSE | 5.16 MB / ~2.1 MiB idle RSS |
| **binocle-one** | nano + accounts (email/password, OAuth2, TOTP MFA), file storage, filtered SSE realtime, admin UI at `/_/` | 6.41 MB / ~2.2 MiB idle RSS |

Full 5-minute walkthrough (both paths): **[`QUICKSTART.md`](QUICKSTART.md)**.

---

## Editions & tiers

An **edition** is a named set of planes; a **tier** is a measured, repeatable shape you start with
`make up PACKAGE=<tier>` (run from the repo root):

| Tier | RAM (measured) | You get |
|---|---|---|
| **basic** | ~460 MiB (0 Node) | CRUD on SQLite + Postgres through the Rust plane |
| **essential** | ~660 MiB | + aggregates, Go orchestrator (default) |
| **pro** | ~1.4 GiB | + MySQL/Mongo/Redis/Cockroach, realtime, storage, transactions |
| **max** | ~3.5 GiB | + MSSQL/HTTP, DDL, analytics (Trino), observability |

Editions (`make editions`): `lean query realtime analytics prod full`. Additive compose overlays
(`orchestrators/compose/docker-compose.{cloud,pooler,scale,netseg,graphql,prod,ci}.yml`) opt into
capabilities — never defaults. `make cloud-up` turns the managed-cloud feature flags ON.

---

## The three-language plane layout

| Plane | Language | Path |
|---|---|---|
| **Application** | TypeScript (NestJS) | `src/apps/*` + `src/libs/*` — query/storage routers, schema, session, permission, analytics, email, gdpr services |
| **Control** | Go | `src/control-plane/` — tenants, provisioning, metering, billing, backup, orgs/RBAC, SSO/SCIM, audit, CMEK |
| **Data** | Rust | `src/data-plane-router/` — 8 engine adapters (`postgres mysql mongo mssql sqlite redis http dynamodb`) |
| **Realtime** | Rust | `infra/docker/services/realtime/realtime-agnostic/` — event-bus router + IRC bridge |

**Engine-agnostic by construction** — owner-scoping/RLS is enforced *per request*, which is what
lets `SHARE_POOLS` collapse 10K tenants onto one pool.

---

## Verify gates (the unit of "done")

New work lands behind a numbered milestone gate — a self-contained script
`scripts/verify/m<NN>-*.sh`. Run one directly:

```sh
bash scripts/verify/m80-quota-enforce.sh
bash scripts/verify/m46-share-pools-isolation.sh
```

A gate that passes vacuously (no-op) is not a gate.

---

## Common commands (from the repo root)

```sh
make editions                 # list editions
make up EDITION=query         # bring up a known-good shape
make planes                   # list planes
make doctor                   # environment sanity check
make health / make ps / make logs
make build                    # build the stack images
make migrate / migrate-status
make bench-load|bench-capacity|bench-footprint|bench-mem|bench-startup
make nano-up|one-up           # the two product editions: binocle-nano / binocle-one
make conformance / parity     # engine conformance + shadow-parity
```

---

## Documentation

- **[`wiki/guides/infrastructure.md`](wiki/guides/infrastructure.md)** — the stack: runtime topology,
  service composition, operational model (security model: [`SECURITY.md`](SECURITY.md); production:
  [`DEPLOYMENT.md`](DEPLOYMENT.md))
- **[`QUICKSTART.md`](QUICKSTART.md)** — 5-minute onboarding (binary + Docker)
- **[`wiki/architecture/00-overview.md`](wiki/architecture/00-overview.md)** — the architectural map (3-language plane pattern, request flow)
- **[`wiki/go-to-market/grobase-master-plan.md`](wiki/go-to-market/grobase-master-plan.md)** · **[`wiki/go-to-market/roadmap-to-market.md`](wiki/go-to-market/roadmap-to-market.md)** — the plan and the five tracks (OSS · cloud · scale · enterprise · parity)
- **[`wiki/competitive/competitive-matrix.md`](wiki/competitive/competitive-matrix.md)** · **[`wiki/competitive/nano-vs-pocketbase.md`](wiki/competitive/nano-vs-pocketbase.md)** — head-to-head vs Supabase / Firebase / PocketBase
- **[`wiki/cost-and-tiers/service-tiers.md`](wiki/cost-and-tiers/service-tiers.md)** — what each tier honestly delivers
- **[`wiki/go-to-market/ga-readiness-scorecard.md`](wiki/go-to-market/ga-readiness-scorecard.md)** · **[`wiki/cost-and-tiers/pricing-honesty-audit.md`](wiki/cost-and-tiers/pricing-honesty-audit.md)** — the honest GA posture (measured, not claimed)
- **[`HUMAN-ATOMS.md`](HUMAN-ATOMS.md)** — every human / money / external-account action left to reach GA

> Ethos: a competitive claim without a measured artifact + a reproducing `make` target is not in
> the plan. Tiers are defined once in `infra/config/packages/packages.json` and must match measured reality.

## License

Grobase is **open-core** — see [`LICENSING.md`](LICENSING.md) for the full map.

- **Core** (server / control / data planes) — **GNU AGPLv3** ([`LICENSE`](LICENSE)). Real open
  source; running a *modified* hosted version obliges you to publish your source.
- **SDKs** (`sdks/*`) — **MIT**. Build any client, open or closed.
- **Enterprise features** (SSO, SCIM, audit, CMEK, …) — **commercial**
  ([`LICENSE-ENTERPRISE.md`](LICENSE-ENTERPRISE.md)); paid license for production use.

We retain copyright via the [`CLA.md`](CLA.md), which is what lets us dual-license: a commercial
license can waive the AGPL copyleft for customers who need that.
