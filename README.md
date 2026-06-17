# Grobase

**A self-hostable Backend-as-a-Service: one backend, any frontend, no per-project server code.**

Grobase gives any application a complete backend over plain HTTP — auth, relational + document
data, realtime, object storage, email, and a multi-tenant query plane — with **swappable engines,
isolation models, and editions on one codebase, no rewrite**. The same code scales from a **5 MB
single binary to a 10K-tenant platform**.

It is a **live product mid-migration (TypeScript → Rust data plane)**: Rust is the sole live data
path; legacy TypeScript engine code is retained behind a deletion gate (see
[`wiki/cutover-status.md`](wiki/cutover-status.md)), not deleted. Beyond OSS self-host, Grobase also
runs as a **managed cloud** (sign-up → API key → CRUD/realtime → usage → Stripe billing) and an
**enterprise-procurable** platform (orgs/RBAC, SSO/SCIM, audit, compliance, CMEK) — every
cloud/enterprise behavior is **flag-gated OFF by default** so the stack stays byte-parity with the
OSS edition.

---

## ⚠️ Where the buildable system lives — read this first

> **The buildable system is under [`mini-baas-infra/`](mini-baas-infra/), driven by its Makefile.
> There is no root Makefile.** Run every lifecycle command from inside `mini-baas-infra/`.

Everything else at the repo root (`sdk*/`, `wiki/`, `scripts/`, `config/`, `certs/`,
`HUMAN-ATOMS.md`) is supporting material. The canonical Docker tree is `mini-baas-infra/docker/`;
the marketing site is `site/` (container-only, **not** part of the BaaS stack).

---

## Quickstart

```sh
git clone https://github.com/Univers42/grobase.git
cd grobase/mini-baas-infra

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

Full 5-minute walkthrough (both paths): **[`mini-baas-infra/QUICKSTART.md`](mini-baas-infra/QUICKSTART.md)**.

---

## Editions & tiers

An **edition** is a named set of planes; a **tier** is a measured, repeatable shape you start with
`make up PACKAGE=<tier>` (run from `mini-baas-infra/`):

| Tier | RAM (measured) | You get |
|---|---|---|
| **basic** | ~460 MiB (0 Node) | CRUD on SQLite + Postgres through the Rust plane |
| **essential** | ~660 MiB | + aggregates, Go orchestrator (default) |
| **pro** | ~1.4 GiB | + MySQL/Mongo/Redis/Cockroach, realtime, storage, transactions |
| **max** | ~3.5 GiB | + MSSQL/HTTP, DDL, analytics (Trino), observability |

Editions (`make editions`): `lean query realtime analytics prod full`. Additive compose overlays
(`docker-compose.{cloud,pooler,scale,netseg,graphql,prod,ci}.yml`) opt into capabilities — never
defaults. `make cloud-up` turns the managed-cloud feature flags ON.

---

## The three-language plane layout

| Plane | Language | Path (under `mini-baas-infra/`) |
|---|---|---|
| **Application** | TypeScript (NestJS) | `src/apps/*` + `src/libs/*` — query/storage routers, schema, session, permission, analytics, email, gdpr services |
| **Control** | Go | `go/control-plane/` — tenants, provisioning, metering, billing, backup, orgs/RBAC, SSO/SCIM, audit, CMEK |
| **Data** | Rust | `docker/services/data-plane-router/` — 8 engine adapters (`postgres mysql mongo mssql sqlite redis http dynamodb`) |
| **Realtime** | Rust | `docker/services/realtime/realtime-agnostic/` — event-bus router + IRC bridge |

**Engine-agnostic by construction** — owner-scoping/RLS is enforced *per request*, which is what
lets `SHARE_POOLS` collapse 10K tenants onto one pool.

---

## Verify gates (the unit of "done")

New work lands behind a numbered milestone gate — a self-contained script
`mini-baas-infra/scripts/verify/m<NN>-*.sh`. Run one directly:

```sh
bash mini-baas-infra/scripts/verify/m80-quota-enforce.sh
bash mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh
```

A gate that passes vacuously (no-op) is not a gate.

---

## Common commands (from `mini-baas-infra/`)

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

- **[`mini-baas-infra/README.md`](mini-baas-infra/README.md)** — the stack: services, request
  lifecycle, auth/security model, compose profiles, env vars
- **[`mini-baas-infra/QUICKSTART.md`](mini-baas-infra/QUICKSTART.md)** — 5-minute onboarding (binary + Docker)
- **[`wiki/00-overview.md`](wiki/00-overview.md)** — the architectural map (3-language plane pattern, request flow)
- **[`wiki/grobase-master-plan.md`](wiki/grobase-master-plan.md)** · **[`wiki/roadmap-to-market.md`](wiki/roadmap-to-market.md)** — the plan and the five tracks (OSS · cloud · scale · enterprise · parity)
- **[`wiki/competitive-matrix.md`](wiki/competitive-matrix.md)** · **[`wiki/nano-vs-pocketbase.md`](wiki/nano-vs-pocketbase.md)** — head-to-head vs Supabase / Firebase / PocketBase
- **[`wiki/service-tiers.md`](wiki/service-tiers.md)** — what each tier honestly delivers
- **[`wiki/ga-readiness-scorecard.md`](wiki/ga-readiness-scorecard.md)** · **[`wiki/pricing-honesty-audit.md`](wiki/pricing-honesty-audit.md)** — the honest GA posture (measured, not claimed)
- **[`HUMAN-ATOMS.md`](HUMAN-ATOMS.md)** — every human / money / external-account action left to reach GA

> Ethos: a competitive claim without a measured artifact + a reproducing `make` target is not in
> the plan. Tiers are defined once in `mini-baas-infra/config/packages/packages.json` and must match measured reality.
