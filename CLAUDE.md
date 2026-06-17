# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **standalone `grobase` repository** (`github.com/Univers42/grobase`) — the Grobase
BaaS, extracted from the Track-Binocle monorepo's `apps/baas/` subtree and migrated here as a
self-contained repo (own remote, own CI; see commit `d3de3fb`). It is **not** a subtree anymore:
there is no parent `../../CLAUDE.md` and no monorepo to defer to.

Grobase is a **self-hostable Backend-as-a-Service**: one backend, any frontend, no per-project
server code — swappable engines, isolation models, and editions on **one codebase, no rewrite**
(5 MB single binary → 10K-tenant platform). It is a **live product mid-migration (TS → Rust data
plane)**, so legacy TS engine code is retained behind the deletion gate while Rust serves traffic.
Beyond OSS self-host it also runs as a **managed cloud** (sign-up → API key → CRUD/realtime → usage
→ Stripe billing) and an **enterprise-procurable** platform (orgs/RBAC, SSO/SCIM, audit, compliance,
CMEK). Every cloud/enterprise behavior is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition (flag tables below).

## ⚠️ Branch state — the working tree is mid-restructure (READ THIS FIRST)

There are **two layouts**, and which one you see depends on the ref:

> **Working tree (branch `chore/lean-architecture`) — what's on disk NOW: a flattened "lean"
> layout.** `mini-baas-infra/` has been **deleted from disk** (it shows as ~1247 ` D` entries in
> `git status`) and its contents hoisted to the **repo root**: `src/`, `infra/`, `sdks/`,
> `orchestrators/`, `scripts/`, plus a **root `Makefile`** (735 lines), `docker-compose.yml`, and
> `sonar-project.properties`. **This restructure is UNCOMMITTED** (the new tree is untracked, the old
> tree is staged-deleted).
>
> **Committed `HEAD` / `origin/main` — what a fresh clone gets: the old `mini-baas-infra/` layout.**

**This document describes the lean working-tree layout as primary** (because that is what an agent
opened in this directory will actually see), with a **compact `origin/main` path map in the appendix**
at the bottom. **Sanity check which one you're on:** `ls mini-baas-infra` → "No such file" means the
lean working tree; if it lists files, you're on a clean checkout of `origin/main` and should mentally
re-prefix every path below with `mini-baas-infra/`.

The lean restructure is **half-finished**: the new root `Makefile` and the SDK codegen still point at
several stale paths, so a number of targets **don't build yet** — see the next section before running
anything.

## Code generation

- Always walk the minimalism ladder before writing code (see [`.claude/rules/minimalism-ladder.md`](.claude/rules/minimalism-ladder.md)).
- Mark deliberate simplifications with `// ponytail:` comments (see [`.claude/rules/minimalism-markers.md`](.claude/rules/minimalism-markers.md)).

## In-flight restructure — paths that don't build yet

The new root `Makefile`/codegen were hoisted but their internal paths were **not all rewritten**.
These are **confirmed broken on the current working tree** (they reference the pre-flatten locations):

| Target / file                                                           | Stale ref (in-file)                                                                | Actual location now                                |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------- |
| `make go-control-plane-check` / `-build` (Makefile L275/292/605)        | mounts `$(CURDIR)/go/control-plane`                                                | `src/control-plane` (NOT `src/go/…` — no `go/` dir exists) |
| `make rust-data-plane-*` (CARGO_DPR, L538)                              | mounts `docker/services/data-plane-router`                                         | `src/data-plane-router`                            |
| `make rust-realtime-*` (CARGO_REALTIME, L539)                           | mounts `docker/services/realtime/realtime-agnostic`                                | `infra/docker/services/realtime/realtime-agnostic` |
| `make nano-build` / `one-build` (L568/584)                              | `docker/services/data-plane-router/Dockerfile.{nano,one}`                          | `src/data-plane-router/Dockerfile.{nano,one}`      |
| `make certs` (L470) + `make up` cert probe (L164)                       | `../scripts/generate-localhost-cert.sh`, `../certs/localhost.pem` (parent-of-repo) | `certs/` is at the repo root, not `../`            |
| `make legacy-%` (L621)                                                  | `-f Makefile.legacy`                                                               | no `Makefile.legacy` at root                       |
| `make packages` banner (L336, cosmetic)                                 | prints `config/packages/packages.json`                                             | `infra/config/packages/packages.json`              |
| `sdks/js` `openapi:collect` (package.json L54) → so `codegen:all` chain | `../../mini-baas-infra/scripts/openapi-collect.sh`                                 | `scripts/ops/openapi-collect.sh`                   |
| `sdks/js/scripts/codegen-polyglot.sh` (L24)                             | `SPEC="mini-baas-infra/openapi/grobase-public.json"`                               | `infra/config/openapi/grobase-public.json`         |
| `scripts/verify/m58-sdks-compile.sh`                                    | resolves SDKs via `APPS_BAAS_DIR` = **parent of repo root**                        | SDKs are at `<repo>/sdks/` (off by one)            |
| `.github/workflows/ci.yml` (629 lines, L75–150)                         | `context: mini-baas-infra/src`, `…/go/control-plane`, `…/docker/services/*`        | will break when the flatten is committed           |

**What DOES work on the lean tree** (already root-relative): `make up`/`editions`/`planes`/`packages`/
`build`, the `.env`/secrets/port machinery (`scripts/env/generate-env.sh`, `scripts/ops/resolve-ports.sh`),
`make migrate*` (→ `scripts/migrations/`), the verify gates (`scripts/verify/m*-*.sh`), and
`make conformance`/`verify-all`. If you're finishing this restructure, the table above is the to-do
list.

## Repo layout (lean working tree — primary)

```
.  (repo root — Makefile, docker-compose.yml, docker-bake.hcl, package.json, sonar-project.properties)
├── src/                       # the application + control + data planes (was mini-baas-infra/src + go + docker/.../data-plane-router)
│   ├── apps/                  # TS NestJS services (query-router, permission-engine, schema-service, …)
│   ├── libs/                  # TS shared libs (common, database, health)
│   ├── control-plane/         # Go control plane (module github.com/dlesieur/mini-baas/control-plane) — note: src/control-plane, NOT src/go/
│   ├── data-plane-router/     # Rust data-plane cargo workspace (crates/…)
│   └── coverage/              # generated lcov — FILTER OUT when grepping source
├── infra/
│   ├── config/                # packages.json, cloud/flags.env.cloud, openapi/grobase-public.json
│   └── docker/                # docker build contexts + the vendored realtime workspace
├── orchestrators/
│   ├── compose/               # base/*.yml (split plane files, included by root docker-compose.yml) + 9 additive docker-compose.*.yml overlays
│   └── makes/                 # makefile fragments
├── sdks/                      # js (was sdk/, now @grobase/js) + python kotlin swift dart
├── scripts/                   # organized by family (see scripts/README.md):
│                              #   test/{phase,smoke,postman} · verify/ (gates) · migrations/ · bench/(+scale) · report/ · security/ · seed/
│                              #   secrets/ · env/ · vault/ · certs/ · db/ · ci/ · deploy/ · ops/ · lib/ (shared sourced helpers: lib-*, service-auth)
├── deploy/                    # go-live/go-live.sh, HA manifests
├── certs/                     # local dev TLS material (untracked; regenerate, never commit)
├── build/  wiki/              # build artifacts dir · product docs
```

Other on-disk artifacts to know: `certs/` and `infra/docker/services/realtime/realtime-agnostic`
are **untracked** in the working tree (the realtime workspace is vendored plain files, ~163 source
files, no nested `.git`). `.gitmodules` has been **removed** (the deletion is committed on this
branch — it declared 6 dead submodules, none ever initialized); the orphan nested `grobase/`
gitlink was de-tracked in `3396baf`. There is **no `site/`** (marketing site) in this repo, on any
ref. `coverage/` HTML under `src/` will pollute `grep` hits — exclude it.

**Root docs worth knowing:** `QUICKSTART.md` (5-min bring-up), `DEPLOYMENT.md` (production),
`SECURITY.md` (threat model / hardening / reporting), `RELEASE.md` (how a version ships),
`HUMAN-ATOMS.md` (the GA human/money/account checklist), and the open-core licensing set —
`LICENSING.md` · `LICENSE` (AGPLv3) · `LICENSE-ENTERPRISE.md` · `CLA.md` (see **Licensing** below).
`DEVDOC.md`/`USERDOC.md` are dev/user guides; `prompt.md` is a design-rationale scratch note (origin
of the minimalism-ladder rule), not operational. Builds can also go through `docker-bake.hcl` (buildx
bake groups `apps`/`infra`).

## Three-language plane layout (lean paths)

| Plane           | Language            | Path                                                                                        | What                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------- | ------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Application** | TypeScript (NestJS) | `src/apps/*` + `src/libs/*`                                                                 | query-router, storage-router, schema/session/permission/analytics/ai/email/gdpr/newsletter services, outbox-relay, mongo-api                                                                                                                                                                                                                                                                                                                                                                                          |
| **Control**     | Go                  | `src/control-plane/` (module `github.com/dlesieur/mini-baas/control-plane`, `go 1.25.0`)    | **30** `internal/` pkgs — **core:** `tenants provision packages orchestrator adapterregistry shared`; **cloud:** `metering quotastage spendcap abuseguard entitlements backup`; **functions:** `funcsecrets functriggers scheduler`; **enterprise (D):** `orgs sso scim passkeys audit compliance cmek trust ipguard erase export telemetryexport`; **parity (E):** `branching push webhooks`. **6** `cmd/` binaries: `tenant-control adapter-registry orchestrator function-scheduler webhook-dispatcher scale-seed` |
| **Data**        | Rust                | `src/data-plane-router/` (cargo workspace)                                                  | crates: `data-plane-core`, `data-plane-pool`, `data-plane-server`, `engine-conformance`                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Realtime**    | Rust (vendored)     | `infra/docker/services/realtime/realtime-agnostic/`                                         | 10-crate event-bus router + IRC bridge (separate workspace)                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

**8 engine adapters** live in `src/data-plane-router/crates/data-plane-pool/src/`: `postgres mysql
mongo mssql sqlite redis http dynamodb` (`dynamodb` is an opt-in cargo feature, OFF by default —
not in `default` or `engines-full`). **Engine-agnostic by construction** — a fix that works for
Postgres but breaks the other seven is not done. Owner-scoping/RLS is enforced **per request**, not
by pool state (this is what lets `SHARE_POOLS` collapse 10K tenants onto one pool).

**The load-bearing seam** (needs all three plane dirs to see): the **Go control plane** resolves a
cleartext API key → identity via `POST /v1/keys/verify`; the **Rust data plane** then _executes_ the
query and owner-scopes it per request using that identity. Data plane = query execution; per-engine
capability truth lives in Rust (`data_plane_core::EngineCapabilities`) and is surfaced through the TS
query-router. The **TS→Rust cutover is a per-request switch, not a build flag**:
`RUST_DATA_PLANE_FORWARD=1` (TS-side, default off; `RUST_DATA_PLANE_FORWARD_ENGINES=postgresql,mongodb`,
in `src/apps/query-router/.../rust-data-plane.proxy.ts`) is independent of the Rust-side
`DATA_PLANE_ROUTER_PRODUCT_MODE` (`shadow`|`enabled`, default `shadow`); the m18/parity gates exercise
both halves.

The data plane builds **multiple product shapes from one codebase via cargo features** (in
`crates/data-plane-server/Cargo.toml`): `nano` (SQLite-only, ~5 MB scratch image), `one`
(+ OAuth/OIDC, argon2id email-password, RFC-6238 TOTP MFA, SMTP, file-storage, admin UI at `/_/`),
opt-in `dynamodb`, `control-pg` (server-backed automations + transactional outbox). `default =
[engines-full, control-pg, ratelimit-redis]`. The realtime workspace is 10 crates
(`realtime-core/-engine/-auth/-gateway/-server/-client`, DB producers `-db-postgres`/`-db-mongodb`,
buses `-bus-inprocess`/`-bus-irc`) with a **pluggable EventBus** (`inprocess`|`irc`) and DB change
producer (`postgres`|`mongodb`) assembled in `realtime-server`. Per-crate `README.md`s under
`src/data-plane-router/crates/` are the authoritative architecture docs for the data plane.

## Running & building (root `Makefile`)

Run from the **repo root**. Drive the stack **only** through it (Docker-first; no host
node/cargo/go for lifecycle — the make wrappers build/cache the toolchain images). `make legacy-<t>`
is meant to reach the preserved `Makefile.legacy` but that file is not present (see caveats above).

```bash
make quickstart               # one shot: generate .env → up (PACKAGE=essential) → health
make editions / make packages # editions: lean query realtime analytics prod full (default query)
                              #   packages (customer tiers): nano basic essential pro max
make up EDITION=query         # bring up a known-good shape; planes compose into editions
make up PACKAGE=pro ADDONS="analytics engines"   # tier-shaped instead of edition
make planes                   # 15 planes: data control go rust adapter background analytics storage
                              #   realtime functions observability ops studio playground engines
make doctor / make health / make ps / make logs
make re | fclean | clean      # full reset (honours EDITION) | destructive prune | = down
make build                    # build all edition images   (build-svc-<svc> = one image)
make migrate / migrate-status / migrate-all / migrate-mongo / migrate-mysql
make bench-load|bench-capacity|bench-footprint|bench-mem|bench-startup
make audit-deps               # supply-chain CVE scan: cargo-audit (Rust) + govulncheck (Go)
make nano-up|one-up           # product editions: binocle-nano (:8090) / binocle-one (:8091)
make cloud-up                 # managed-cloud overlay (turns cloud/enterprise flags ON — NOT a default)
make conformance | conformance-<engine> | parity | parity-suite
```

**Two orthogonal stack-shaping dimensions** exist, not one: **EDITIONS** (a named set of planes) and
**PACKAGES** (the customer tiers in `infra/config/packages/packages.json` — the single source of truth
for tiers; 5 keys `nano basic essential pro max`, though `make up PACKAGE=` accepts only the **4**
non-nano tiers — `nano` ships standalone via `make nano-up`, not `PACKAGE=nano`). When several are
set, precedence is **`PROFILES` > `PACKAGE` > `EDITION`**. `EDITION_query := data go rust adapter
background`; `PACKAGE_basic := go rust`, `essential := +adapter background`, `pro := +data storage
realtime`, `max := +analytics observability functions engines`; `ADDONS` appends à-la-carte planes.
Each plane auto-generates `up-/down-/restart-/logs-<plane>` verbs. Gotchas:

- `make up EDITION=full` deliberately **excludes** the `playground` plane (its assets aren't in this
  repo), and bare `make parity` **errors out** (exit 1, not a silent no-op) — it needs
  `make parity NEW=<url> [OLD=<url>] [ROUTES=<set>]`.
- **First run:** `make up` auto-generates `.env` if it's missing (`[ -f .env ] || make env`, same as
  `quickstart`) and never clobbers an existing one (`scripts/env/generate-env.sh` refuses without
  `FORCE=1`, and aborts if host `openssl` is absent — the one Docker-first exception).
- **Busy ports:** `make up` evaluates `scripts/ops/resolve-ports.sh`, which auto-increments any in-use
  host port (Kong 8000, Postgres 5432, Mongo 27017, …) to the next free one and only warns on stderr.
  `make health` and the `quickstart` banner discover the live Kong port at runtime
  (`docker port mini-baas-kong 8000/tcp`, falling back to 8000), so they print the correct
  `localhost:<port>` even when 8000 was taken. Other host ports surface only via that stderr warning —
  use `docker compose ps` / `docker port` to confirm them.

### Verify gates (the unit of "done")

New BaaS work lands behind a **numbered milestone gate** — a self-contained script
`scripts/verify/m<NN>-*.sh` (currently **126 scripts, highest m145**; the m-numbers are a _range_,
not contiguous, and a few are reused — e.g. several `m23`/`m24`/`m101`/`m102` scripts exist). There
are no `baas-verify-*` Makefile wrappers in this repo (those were monorepo-root targets). Run a gate
directly:

```bash
bash scripts/verify/m80-quota-enforce.sh           # one gate, direct
bash scripts/verify/m46-share-pools-isolation.sh
```

A gate that passes vacuously (no-op) is not a gate — gates must actually exercise the behavior. Run
**many** at once with `bash scripts/verify/run-gate-battery.sh m120`. Its two curated sets are the
source of truth (**not** a contiguous range): `--enterprise` runs the nightly enterprise + data-plane
battery (`m101-quota-realtenant` + m103…m112, m120…m122, m135–m137, m139, m141, m143 — `m144`/`m145`
are _deliberately excluded_: they validate the (absent) `site/` and uncommitted bench artifacts, run
those two by hand at release time; `m102` is also excluded — it needs a live Kong). `--fast` runs the
per-PR subset (`m101-quota-realtenant` + m120); a bare/`-h` invocation prints help and runs nothing
(trailing gate tokens are appended, so `--fast m122` works). Note the battery uses full script names
like `m101-quota-realtenant` because plain `m101` is ambiguous (two `m101` scripts). `make conformance`
is just an alias for the `m27` script and `make verify-all` loops every `m*-*.sh` in version order —
**the scripts are the source of truth; the make targets are thin wrappers.** Each flag-gated feature
has its own gate (e.g. `m103-orgs-rbac.sh`, `m110-sso-oidc.sh`, `m123-cmek-envelope.sh`). The newest
band **m140–m145** is _not_ feature-flagged (hence absent from the flag tables): `m140`
network-controls + WAF, `m141` compliance-posture, `m142` edge-error-mapping, `m143`
compliance-matrices, `m144` trust-page-parity, `m145` cost-model integrity.

### Build, lint & test (per plane) — including how to run ONE test

Every toolchain runs **in Docker**. There's a wrapper for the _whole_ suite per plane; for a _single_
test, invoke the runner through the same container. **Caveat:** the Rust/Go make wrappers currently
mount stale paths (see "paths that don't build yet") — `cargo`/`go test` via `make` will fail until
those mounts are repointed; the direct `docker run` forms below already use the lean paths.

| Plane                               | Whole suite (Docker wrapper)                                                                                       | One test                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **TS app** (NestJS · Jest)          | `make nestjs-ci` = `tsc --noEmit` + eslint + `jest --passWithNoTests`; `make nestjs-build-<app>`                   | from repo root: `docker run --rm -v "$PWD/src":/app -w /app -v mini-baas-src-node-modules:/app/node_modules node:20-alpine npx jest <spec> -t '<case>'`. There are **16** spec files (12 under `src/apps`: schema-service, analytics-service, mongo-api, log-service, query-router's proxy/graph/query/dto; 4 under `src/libs/common`) — **not** confined to one dir |
| **Go control**                      | `make go-control-plane-check` (`go vet ./... && go test ./...`); `make go-control-plane-build` (compose build)     | from `src/control-plane/`: `docker run --rm -v "$PWD":/src -w /src golang:1.25-bookworm go test ./internal/<pkg> -run TestX -v` (1.25 — `go.mod` says `go 1.25.0`; `-check` pins `golang:1.25-bookworm`)                                                                                                                                                          |
| **Rust data**                       | `make rust-data-plane-check` / `-test` / `-build` (a `-test` target **does** exist now = `cargo test --workspace`) | `make _rust-toolchain` once, then `cargo test -p data-plane-core <name>` via the data-plane CARGO wrapper; engine integration = `make conformance` / `conformance-<engine>` (the m27 gate)                                                                                                                                                                           |
| **Rust realtime**                   | `make rust-realtime-check \| -test \| -build`                                                                      | `cargo test -p realtime-core <name>` via the realtime CARGO wrapper                                                                                                                                                                                                                                                                                                  |
| **TS SDK** (`sdks/js/` · node:test) | `cd sdks/js && npm run build && npm test`                                                                          | `node --test tests/<name>.test.mjs` (or `--test-name-pattern='<re>'`) — **NOT** jest/vitest                                                                                                                                                                                                                                                                          |
| **Polyglot SDKs**                   | py+dart `m58-sdks-compile.sh` · swift `m62-sdk-swift.sh` · kotlin `m63-sdk-kotlin.sh`                              | the generated `test/` stubs are empty `pass` bodies — the **build/compile gates are the real check**, not `pytest`/`dart test`                                                                                                                                                                                                                                       |

Notes: the data-plane crate's produced binary is **`data-plane-router`** (package `data-plane-server`,
`[[bin]] name = "data-plane-router"`); realtime's is `realtime-server`. The SDK `src/generated/` tree
is **gitignored** — regenerate with `cd sdks/js && npm run codegen:all` (but the `openapi:collect` link
in that chain is currently broken — see caveats). All SDKs derive from one spec:
`infra/config/openapi/grobase-public.json` (polyglot via `bash sdks/js/scripts/codegen-polyglot.sh`).

**Code quality (SonarCloud).** `sonar-project.properties` (repo root; org `univers42`, projectKey
`Univers42_grobase`) defines the scope — sources `docker/services, scripts, config, src/apps,
src/libs`; the script families (`scripts/{verify,bench,security,seed,env,vault,certs,db,ci,ops,test,lib}/**`),
migrations, Dockerfiles, and the vendored `realtime-agnostic/**` are **excluded** (only `scripts/*.py`
stays in analysis scope). There ARE make
targets now: `make sonar-coverage` (regenerate jest + deno lcov) and `make sonar-scan` (coverage then
scanner; token from `SONAR_TOKEN`/`TOK_SONARCLOUD`). Pull the live issue list with
`bash scripts/ops/sonar-fetch-issues.sh` (writes JSON+TXT into `audit/`; defaults
`SONAR_PROJECT_KEY=Univers42_grobase`).

## Editions, planes, and compose overlays

An **edition** = a named set of planes. The **root `docker-compose.yml` is now a thin orchestrator** —
it `include:`s 14 per-plane base files under **`orchestrators/compose/base/*.yml`** (gateway, secrets,
data-engines, auth-api, engines-extra, lakehouse, control-plane, data-plane, app-services, storage,
observability, ops, studio, playground); the old single-file monolith was split into these. Beyond that
base, additive overlays under **`orchestrators/compose/`** opt into capabilities — never defaults:

| Overlay                            | Purpose                                                             |
| ---------------------------------- | ------------------------------------------------------------------- |
| `docker-compose.cloud.yml`         | Managed-cloud: turns Track-B feature flags **ON** (`make cloud-up`) |
| `docker-compose.pooler.yml`        | Connection pooler (supavisor) — Track-C / C1                        |
| `docker-compose.scale.yml`         | 10K-tenant scale experiment (raises `max_connections` — costly)     |
| `docker-compose.netseg.yml`        | Per-plane network segmentation                                      |
| `docker-compose.graphql.yml`       | GraphQL edition (A5)                                                |
| `docker-compose.prod.yml`          | Production: no dev ports, resource limits                           |
| `docker-compose.ci.yml`            | CI shape                                                            |
| `docker-compose.track-binocle.yml` | Carried-over monorepo-integration overlay                           |
| `docker-compose.monolith.yml`      | Preserved pre-split single-file compose (all services inline; uses stale `./docker/services/` paths) |

**Gotcha — GHCR pull-fallback.** **49** services across the `orchestrators/compose/base/*.yml` plane
files (included by the thin root `docker-compose.yml`) carry an
`image: ghcr.io/univers42/grobase-<svc>:latest` line above their `build:` block (annotated
`# pull-fallback`), so a plain `docker compose up` **pulls the prebuilt `:latest` image instead of
building local source** — your edits to a service won't take effect until you build it (`make build`,
or `docker compose build <svc>`). (Image org is lowercase `univers42`, unlike the repo's `Univers42`.)

## Cloud, enterprise & parity features are flag-gated OFF

Every cloud / enterprise / parity feature is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition. **Do not flip these ON in shared/parity runs without a gate** —
OFF is the proven state. OFF is _structural_, not config-file-based: in Go the feature routes are
physically not mounted unless `if envBool("FLAG")` (~38 such sites; defaults false), so a missing var
= byte-parity by construction. `make cloud-up` turns the set ON via `infra/config/cloud/flags.env.cloud`.
**Gotcha — the master+sub-flag AND pattern:** several features need _both_ halves truthy across both
planes, e.g. metering = `METERING_ENABLED` (Go control) AND `DATA_PLANE_METERING` (Rust); enforcement
= `QUOTA_ENFORCEMENT` AND `DATA_PLANE_QUOTA_ENFORCEMENT` — flip only one and you get a silent no-op
(each plane reads its own master+sub chain). **Subtle TS-vs-Go gate seam:**
`PERMISSION_CONDITIONS_ENABLED` / `API_KEY_ABAC_ENABLED` (m135–m139, ABAC) are _not_ Go `envBool`
route-mount gates — they gate at the **TS / data-plane PDP**, so grep them in
`src/apps/permission-engine` & `src/apps/query-router`, not the Go control plane. SQL migrations live
in **`scripts/migrations/postgresql/`**; the full numeric set is **001–065** (52 distinct numbers
across 54 files — `035` is reused; sequence is non-contiguous, gaps include **057–059**: `056` jumps
to `060`; highest is `065_least_privilege_rls.sql`), and the cloud/enterprise/parity slice runs
**040–065**. Mongo/MySQL migrations are separate and tiny (`scripts/migrations/{mongodb,mysql}/`, via
`make migrate-mongo` / `migrate-mysql`, which need the `data-plane` profile up).

**Track-B managed-cloud (B1–B6):**

| Feature                     | Flag(s)                                                | Migration                                                                                  |
| --------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| metering (m74–m79)          | `DATA_PLANE_METERING`, `METERING_ENABLED`              | `040_tenant_usage.sql`                                                                     |
| quota enforce (m80)         | `QUOTA_ENFORCEMENT` (+ `DATA_PLANE_QUOTA_ENFORCEMENT`) | —                                                                                          |
| billing/Stripe (m82)        | `BILLING_ENABLED`                                      | `041_tenant_billing.sql`                                                                   |
| tenant self-serve (m83–m84) | `TENANT_SELFSERVE_ENABLED`                             | — (`/v1/tenants/me*`, tenant from credential — no `{id}`, no cross-tenant by construction) |
| per-tenant obs (m85)        | `TENANT_OBS_ENABLED`, `DATA_PLANE_TENANT_OBS`          | — (tenant_id as a log _field_, never a Prometheus label)                                   |
| backup/restore (m87)        | `TENANT_BACKUP_ENABLED`                                | `042_tenant_backups.sql`                                                                   |

**Track-D enterprise · Track-E parity · dynamic-builder / ABAC:**

| Feature (track · gate)                                         | Flag(s)                                                             | Migration                                                                               |
| -------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| org model + RBAC (D1 · m103)                                   | `ORG_MODEL_ENABLED`                                                 | —                                                                                       |
| audit chain (D3 · m104)                                        | `TENANT_AUDIT_ENABLED`                                              | —                                                                                       |
| hard-erase (D4.4 · m105) · IP allowlist (D2e · m106)           | `HARD_ERASE_ENABLED` · `TENANT_IP_ALLOWLIST_ENABLED`                | `048` (erasure) · `049` (ip-allowlist)                                                  |
| passkeys / WebAuthn (D2c · m107)                               | `PASSKEYS_ENABLED`                                                  | `050`                                                                                   |
| SOC2-lite evidence (D4.1 · m108) · tenant export (D4.3 · m109) | `SOC2_EVIDENCE_ENABLED` · `TENANT_EXPORT_ENABLED`                   | `051`, `052`, `064`                                                                     |
| enterprise SSO/OIDC (D2a · m110) · SCIM 2.0 (D2b · m111)       | `SSO_ENABLED` · `SCIM_ENABLED`                                      | `053`, `054`                                                                            |
| trust center (D4.6 · m112)                                     | `TRUST_CENTER_ENABLED`                                              | —                                                                                       |
| DB branching (E · m113) · push/messaging (E · m114)            | `DB_BRANCHING_ENABLED` · `PUSH_ENABLED` (+ `PUSH_SSRF_ALLOW_HOSTS`) | `055`, `056`                                                                            |
| CMEK / BYOK envelope (m123)                                    | `CMEK_ENABLED`                                                      | `061` (+ `060` Vault credref)                                                           |
| dynamic builder (m130–m134)                                    | `BUILDER_ENABLED`                                                   | `062` (filename `062_tenant_entitlements.sql` — trust the in-file header, not the name) |
| fine-grained ABAC (m135–m139)                                  | `PERMISSION_CONDITIONS_ENABLED`, `API_KEY_ABAC_ENABLED`             | `063`                                                                                   |

Other slices, also OFF by default: `QUOTA_STAGE` · `SPEND_CAPS_ENABLED` · `ABUSE_GUARD_ENABLED`
(m89–m91); `FUNCTIONS_CRON_ENABLED` (m96); `TENANT_TELEMETRY_EXPORT_ENABLED` (m100);
`DATA_PLANE_READ_REPLICA` (m122).

## SDKs

The TS SDK is **`sdks/js/`** (package **`@grobase/js`**, renamed from `@mini-baas/js` during the
`sdks/` consolidation, commit `ca6aaf8`) — a hand-written reference client, layout
`src/{core,domains,generated,bin,__type_tests__}` + `index.ts`/`types.ts`, tested with **`node:test`**
(not jest/vitest). Its `src/generated/` is **gitignored** (reproduced from the spec, never committed).
The polyglot SDKs (`sdks/python/`, `sdks/kotlin/`, `sdks/swift/`, `sdks/dart/`) are
**OpenAPI-generated** from `infra/config/openapi/grobase-public.json` via
`bash sdks/js/scripts/codegen-polyglot.sh` (package identities: python `grobase`, dart `grobase`,
swift `Grobase`, kotlin `com.grobase:grobase-sdk`). The old flat `sdk*/` and `*.rootowned-stale`
duplicate dirs **no longer exist** in the working tree (they survive only in `origin/main`). Build/test
commands are in the table above. **Caveat:** both the `openapi:collect` link in `codegen:all` and
`codegen-polyglot.sh`'s `SPEC=` path still reference the old `mini-baas-infra/…openapi/` location and
must be repointed to `infra/config/openapi/grobase-public.json` before codegen will run.

## Going to production

- **`HUMAN-ATOMS.md`** (repo root) is the authoritative checklist of every human / money /
  external-account action left to reach GA across the three targets (OSS · managed-cloud ·
  enterprise).
- **`deploy/go-live/go-live.sh`** is a DRY-RUN-default preflight that **fail-fast validates the
  required env vars** (collects a `MISSING=()` list, names the exact missing one, and exits; it never
  pushes, deploys, or flips a flag). It only acts when `GO_LIVE_APPLY=1` is set (then it runs
  `helm upgrade --install --atomic`, projects the cloud flags ON, and does the RS256 cutover) —
  otherwise it renders offline via `helm template`.

## Licensing (open-core)

Grobase is **open-core** — [`LICENSING.md`](LICENSING.md) is the authoritative map.

- **Core** (server / control / data planes) — **AGPL-3.0-only** ([`LICENSE`](LICENSE)). Real OSI open
  source; running a *modified* hosted version obliges publishing the corresponding source — that is
  the moat against a closed competing fork.
- **SDKs** (`sdks/*`) — **MIT**. Using an SDK to call a Grobase server does **not** put the caller
  under AGPL (the copyleft binds the *server* you run, not its clients).
- **Enterprise features** — **commercial** ([`LICENSE-ENTERPRISE.md`](LICENSE-ENTERPRISE.md), SPDX
  `LicenseRef-Grobase-Enterprise`): the 12 Track-D packages under
  `src/control-plane/internal/{orgs,sso,scim,passkeys,ipguard,audit,compliance,erase,export,telemetryexport,trust,cmek}`,
  each carrying its own directory `LICENSE` pointer. **Track-E** (`branching`/`push`/`webhooks`) and
  the **Track-B** cloud components stay in the AGPL core (sold as hosting, not licensed features).

Copyright is retained via [`CLA.md`](CLA.md) — the clause that enables **dual-licensing** (a paid
commercial license waives the AGPL copyleft). `LICENSE-ENTERPRISE.md` / `CLA.md` are lawyer-review
**templates** with `[…]` placeholders (a `HUMAN-ATOMS.md` legal atom — not yet final). To move a
package across the open-core line, add/remove its directory `LICENSE` and update `LICENSING.md`.

## Binding rules (project policy — apply even to one-off tasks)

1. **Never co-author a push.** Commits and PRs carry **no** `Co-Authored-By` / "Generated with"
   trailer. _(Overrides the default git-trailer behavior for all work in this repo.)_
2. **Shadow → parity → cutover → delete.** No deletion/cutover of legacy TS engine code unless all
   three gates PASS: m18 live-traffic · shadow parity · CI-green-with-forward. **UNKNOWN = FAIL.**
3. **Measured, not claimed.** Every perf/capacity statement cites an artifact
   (`artifacts/bench/…`) + the make target that reproduces it. No invented numbers.
4. **Least change, reversible first.** Behavior changes are flag-gated OFF by default so the live
   baseline stays byte-parity.
5. **Engine-agnostic by construction.** A fix for one engine that breaks the other seven is not done.
6. **Confirm the irreversible** (pushes, deploys, deletions, npm publish, RS256 live cutover) —
   explicit human trigger. Report outcomes faithfully (failures stated, skips stated).
7. **Read by query, not by slurp.** Logs/large files: `tail`/`rg`/`jq`/`awk` or the Explore
   subagent; never pull a whole log/large file into context.

## Note on the agent OS

Unlike the monorepo's `apps/baas/.claude/` (a three-layer agent-OS *kernel*), this repo's `.claude/`
is deliberately **lean and kernel-less** — see [`.claude/AGENTS.md`](.claude/AGENTS.md): fan out
subagents per task, converge, discard the scaffolding; don't rebuild half a kernel. It holds
`settings.json` + `settings.local.json` (the latter disables the `osionos` MCP server); `rules/` (the
binding code-gen rules — `minimalism-ladder`, `minimalism-markers`, per-language
`refactor-{c,go,rust,typescript,shell,common}`, `api-convention`); `agents/` (8 single-purpose
specialists: architect · benchmarker · compat-tester · devil · documenter · norminette · reviewer ·
security); `skills/` (api-endpoint · debug · doc · incident · new-module · pr-review · release ·
write-test); `commands/`; `workflows/`; and `plugins/`. There is **no** kernel
(`CLAUDE.md`/`instructions.md`/`objectives/`) and **no** `/baas-wave` skill — references to "the
kernel" or `make -C ../.. baas-*` in carried-over docs belong to the monorepo, not this repo.

## Appendix — `origin/main` (pre-restructure) layout

On a clean `origin/main` checkout the lean flatten has **not** happened: the buildable system lives
under **`mini-baas-infra/`** and there is no root `Makefile`. If `ls mini-baas-infra` succeeds, you're
on that layout — re-map the lean paths above as follows:

| Lean working tree (primary, this doc)                              | `origin/main` (`mini-baas-infra/`-rooted)                                                                    |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `./Makefile`, `./docker-compose.yml`, `./sonar-project.properties` | `mini-baas-infra/Makefile`, `mini-baas-infra/docker-compose.yml`, `mini-baas-infra/sonar-project.properties` |
| `src/apps`, `src/libs`                                             | `mini-baas-infra/src/apps`, `mini-baas-infra/src/libs`                                                       |
| `src/control-plane`                                                | `mini-baas-infra/go/control-plane`                                                                           |
| `src/data-plane-router`                                            | `mini-baas-infra/docker/services/data-plane-router`                                                          |
| `infra/docker/services/realtime/realtime-agnostic`                 | `mini-baas-infra/docker/services/realtime/realtime-agnostic`                                                 |
| `infra/config/packages/packages.json`                              | `mini-baas-infra/config/packages/packages.json`                                                              |
| `infra/config/cloud/flags.env.cloud`                               | `mini-baas-infra/config/cloud/flags.env.cloud`                                                               |
| `infra/config/openapi/grobase-public.json`                         | `mini-baas-infra/openapi/grobase-public.json`                                                                |
| `orchestrators/compose/docker-compose.*.yml`                       | `mini-baas-infra/docker-compose.*.yml`                                                                       |
| `scripts/verify`, `scripts/migrations`                             | `mini-baas-infra/scripts/verify`, `mini-baas-infra/scripts/migrations`                                       |
| `deploy/go-live/go-live.sh`                                        | `mini-baas-infra/deploy/go-live/go-live.sh`                                                                  |
| `sdks/js` (`@grobase/js`), `sdks/{python,kotlin,swift,dart}`       | `sdk/` (`@mini-baas/js`), `sdk-{python,kotlin,swift,dart}/` (+ `*.rootowned-stale/`)                         |

`origin/main` also still tracks `.gitmodules` (6 dead, uninitialized submodule declarations) and the
active CI (`.github/workflows/ci.yml`) builds with `context: mini-baas-infra/...` and
`working-directory: mini-baas-infra` — both of which the lean flatten removes/breaks and will need
updating when the restructure is committed.
