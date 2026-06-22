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

## Layout & branch state

The **lean (flattened) layout IS the layout** — the restructure is **done and committed to
`origin/main`**. `mini-baas-infra/` no longer exists; its contents were hoisted to the repo root
(`src/`, `infra/`, `sdks/`, `orchestrators/`, `scripts/`) under a **thin ~74-line root `Makefile`**
that `include`s **12** `orchestrators/makes/*.mk` fragments (the old 735-line monolith survives only
as `Makefile.bak`). A fresh clone gets this layout — **there is no dual-layout situation anymore** and
no `mini-baas-infra/` prefix to re-map. (Sanity check: `ls mini-baas-infra` → "No such file".) The
SDK-codegen chain and CI (`.github/workflows/ci.yml`) were repointed to lean paths in the same
restructure and are on `main` too.

The active branch is **`main`** (HEAD `9cefdcf`); the vendor re-platform commits (Canagrou · HamBooking ·
Nimbus · MovieVerse · vite-gourmand · surfind-spain · hypertube) plus the per-table-isolation +
query-router-JWT data-plane work, the websites playground, and the per-mount `read_scoped` data-plane
feature (migration `070`) all **landed on `main`** earlier. Since then `main` has advanced through the
**vault42/42ctl Increment-3** work (RBAC hierarchy `m162` · GitHub-connect `m163` · email-OTP login `m164`
· multi-device escrow) and the **contract-factory + fly.io production deploy** (`m165`, see "Going to
production" below). The working tree is largely **clean**: the AppFlowy clone is committed as **plain
tracked files** (nested `.git` removed, ~2880 files), `vendor/twenty/` is a tracked **orphan gitlink**
(mode 160000, `.gitmodules` is gone), the old in-repo `vendor/java-dam-baas/` stale snapshot was
**removed** in `a0bfc38`, and **`vendor/vault42/`** is now a tracked nested checkout of its own repo
(`Univers42/vault42`).

## Code generation

- Always walk the minimalism ladder before writing code (see [`.claude/rules/minimalism-ladder.md`](.claude/rules/minimalism-ladder.md)).
- Mark deliberate simplifications with `// ponytail:` comments (see [`.claude/rules/minimalism-markers.md`](.claude/rules/minimalism-markers.md)).

## Key build paths (lean layout)

The Makefile re-split repointed every build target to the lean tree (the old monolith's line numbers
no longer apply):

- `make rust-data-plane-*` → `src/data-plane-router` (`70-langtiers.mk` `CARGO_DPR`)
- `make rust-realtime-*` → `infra/docker/services/realtime/realtime-agnostic` (`CARGO_REALTIME`)
- `make go-control-plane-check`/`-build` → `src/control-plane` (`golang:1.25-bookworm`)
- `make certs` → `scripts/certs/generate-localhost-cert.sh` + root `certs/localhost.pem`
- `make nano-build`/`one-build` → `src/data-plane-router/Dockerfile.{nano,one}`
- `make packages` banner → `infra/config/packages/packages.json`

SDK codegen + CI resolve against the lean tree too: `sdks/js/package.json`'s `openapi:collect` →
`../../scripts/ops/openapi-collect.sh` (output → `infra/config/openapi/`), `codegen-polyglot.sh`'s
`SPEC` → `infra/config/openapi/grobase-public.json`, and `.github/workflows/ci.yml` builds with
`context:` → `src` · `src/control-plane` · `src/data-plane-router` · `infra/docker/services/<svc>`.
The `make legacy-*` target is **gone** (the monolith survives only as `Makefile.bak`).

## Repo layout (lean layout)

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
└── vendor/                    # playground apps re-platformed onto / mounted into the BaaS — see "vendor/" below
```

Other on-disk artifacts to know: `certs/` and `infra/docker/services/realtime/realtime-agnostic`
are **untracked** in the working tree (the realtime workspace is vendored plain files, ~163 source
files, no nested `.git`). `.gitmodules` has been **removed** (committed to `main` — it declared 6
dead submodules, none ever initialized); the orphan nested `grobase/` gitlink was de-tracked in
`3396baf`. There is **no `site/`** (marketing site) in this repo, on any
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
| **Control**     | Go                  | `src/control-plane/` (module `github.com/dlesieur/mini-baas/control-plane`, `go 1.25.0`)    | **36** `internal/` pkgs — **core:** `tenants provision packages orchestrator adapterregistry`; **infra/cross-cutting:** `config httpx identity jsoncanon observability pg serviceauth` (these replaced the former `shared` junk-drawer, per the no-`shared` rule); **cloud:** `metering quotastage spendcap abuseguard entitlements backup`; **functions:** `funcsecrets functriggers scheduler`; **enterprise (D):** `orgs sso scim passkeys audit compliance cmek trust ipguard erase export telemetryexport`; **parity (E):** `branching push webhooks`. **6** `cmd/` binaries: `tenant-control adapter-registry orchestrator function-scheduler webhook-dispatcher scale-seed` |
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

Run from the **repo root**. The `Makefile` is a **thin orchestrator** (`.DEFAULT_GOAL := help`, so
bare `make` prints the grouped help) — all logic lives in `orchestrators/makes/*.mk`, loaded in order
(`00-config` first). Drive the stack **only** through it (Docker-first; no host node/cargo/go for
lifecycle — the make wrappers build/cache the toolchain images). `make all` = `build` then `up` (the
"42 Classics" group also has `all-full`, `re`, `fclean`, `clean`). There is **no** `make legacy-*`
target anymore; the pre-split monolith survives only as `Makefile.bak`.

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
`scripts/verify/m<NN>-*.sh` (currently **152 scripts, highest m172**; the m-numbers are a _range_,
not contiguous, and a few are reused — e.g. several `m23`/`m24`/`m101`/`m102`/`m146`/`m154` scripts exist). There
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
compliance-matrices, `m144` trust-page-parity, `m145` cost-model integrity. Beyond that, the
**m146–m154 + m160–m161** band is the **vendor re-platform proof set** (`m146-canagrou-roundtrip`,
`m146-movieverse`, `m147-hambooking-isolation`, `m148-nimbus-roundtrip`, `m149-gourmand-baas`,
`m150`…`m154` hypertube, `m154-savanna-zoo` + `m155-savanna-security`, `m160-surfind-spain` +
`m161-surfind-deep`) — see the `vendor/` section; these need the stack up + each app's seed script run
first. The **m156–m159** band is a separate **core platform-hardening** set (security fixes to the OSS
core, not vendor): `m156` recover-no-enumeration, `m157` kong-admin-not-exposed, `m158`
admin-tenant-scope, `m159` storage-bucket-scope (the last flag-gated via `STORAGE_BUCKET_SCOPE_ENABLED`).
The band **m162–m165** is the **vault42/42ctl Increment-3 + deploy** set: `m162` rbac-hierarchy
(teams/project-grants), `m163` github-connect (`GITHUB_CONNECT_ENABLED`), `m164` email-OTP login, `m165`
contract-provision (the generic contract-driven provisioner — see "Going to production"). The newest band
**m166–m172** is the **org/team/group/environment RBAC + ZK per-environment scope-key secret** set: `m166`
environments + groups + per-env grant isolation + scope-pubkey publish, `m168` generalized team/group
invites, `m170` standalone-project direct invites + the 409 org-guard, `m172` member pubkey registry +
grant-fulfilment seam (all control-plane-only, flag-gated OFF). Its cross-repo crypto half is proven by
vault42 `v14`/`v15` + the self-contained live harness `scripts/test/e2e-rbac-scope-keys-live.sh`.

### Build, lint & test (per plane) — including how to run ONE test

Every toolchain runs **in Docker**. There's a wrapper for the _whole_ suite per plane; for a _single_
test, invoke the runner through the same container. The Rust/Go make wrappers now mount the lean paths
(repointed in the Makefile re-split — `src/data-plane-router`, `src/control-plane`,
`infra/docker/services/realtime/realtime-agnostic`), so `make rust-data-plane-check`/
`go-control-plane-check` build; the direct `docker run` forms below use the same paths if you'd rather
skip `make`.

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
is **gitignored** (except the committed curated `engines.ts`) — regenerate with `cd sdks/js && npm run codegen:all` (the `openapi:collect` link in
that chain was repointed to `../../scripts/ops/openapi-collect.sh` in the flatten). All SDKs derive
from one spec: `infra/config/openapi/grobase-public.json` (polyglot via `bash sdks/js/scripts/codegen-polyglot.sh`).

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
it `include:`s **19** base files under **`orchestrators/compose/base/*.yml`** (gateway, secrets,
data-engines, auth-api, engines-extra, lakehouse, control-plane, data-plane, app-services, storage,
observability, ops, studio, playground, plus the vendor-app profiles **movieverse** + **gourmand** +
**hypertube** + **savanna** + **surfind**, which are profile-gated, not default planes); a 20th file
`_common.yml` holds shared YAML anchors. The
old single-file monolith was split into these. Beyond that base, additive overlays under
**`orchestrators/compose/`** opt into capabilities — never defaults:

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

**Gotcha — GHCR pull-fallback.** **54** services across the `orchestrators/compose/base/*.yml` plane
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
in **`scripts/migrations/postgresql/`**; the numeric set now runs **001–084** (73 files; sequence is
non-contiguous, gaps include **057–059**: `056` jumps to `060`; highest is `084_vault42_env_secrets.sql`). The
cloud/enterprise/parity flag slice runs **040–065**; **066–070** are vendor/infra, not flag-gated
(`066`/`067` MovieVerse schema + like-counts, `068` per-mount shared_resources, `069` DynamoDB engine
CHECK, `070` per-mount `read_scoped` read-owner-scoping). The newest band **071–076** backs the
vault42/Increment-3 + deploy work: `071` vault42 zero-knowledge blob substrate, `072` teams, `073`
project-grants (both Track-D RBAC hierarchy, control-plane-only — never enter the RLS GUCs), `074`
GitHub-connect linkage (`GITHUB_CONNECT_ENABLED`, zero-token columns), `075` email login-OTP, `076`
multi-device keystore escrow. The band **077–084** adds the org/team/group/environment RBAC +
zero-knowledge per-environment scope-key secret feature: `077` environments, `078` groups, `079`
project-grants-ext (`env_id` + `group` grantee), `080` invites, `081` user-pubkeys (wrap-target
registry + grant-fulfilment seam), `082` vault42_scope_keys, `083` env scope-pubkey columns, `084`
vault42_env_secrets (shared env-secret store) — all control-plane-only, flag-gated OFF (gates
m166/m168/m170/m172; live cross-repo proof `scripts/test/e2e-rbac-scope-keys-live.sh`).
Mongo/MySQL migrations are separate and tiny
(`scripts/migrations/{mongodb,mysql}/`, via `make migrate-mongo` / `migrate-mysql`, which need the
`data-plane` profile up).

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

**Org / team / group / environment RBAC + ZK per-environment scope-key secrets (m162 · m166–m172):**

| Feature (gate)                                                  | Flag(s)                                       | Migration    |
| --------------------------------------------------------------- | --------------------------------------------- | ------------ |
| environments + per-env grants + scope-pubkey publish (m166)     | `ENVIRONMENTS_ENABLED`                        | `077`, `083` |
| project-scoped groups (`<project>'s group`) (m166)              | `GROUPS_ENABLED`                              | `078`        |
| generalized team/group/project invites + accept (m168 · m170)   | `INVITES_ENABLED`                             | `080`, `079` |
| member pubkey registry + grant-fulfilment seam (m172)           | `USER_PUBKEYS_ENABLED`                        | `081`        |
| vault42 scope-key wrap/get/rotate + env-secret store (v14·v15)  | `VAULT42_SCOPE_KEYS_ENABLED` (vault42-server) | `082`, `084` |

All depend on `RBAC_HIERARCHY_ENABLED` (teams `072` + project-grants `073`) + `ORG_MODEL_ENABLED`
(`043`); all default OFF = byte-parity, control-plane-only (never enter the data-plane RLS GUCs).
Env READS gate on `CapProjectRead` (any granted org member resolves an env), MUTATIONS on
`CapProjGrant`. Design: [`wiki/architecture/org-team-group-rbac.md`](wiki/architecture/org-team-group-rbac.md);
operator guide: [`USERDOC.md`](USERDOC.md); live proof: `scripts/test/e2e-rbac-scope-keys-live.sh`.

Other slices, also OFF by default: `QUOTA_STAGE` · `SPEND_CAPS_ENABLED` · `ABUSE_GUARD_ENABLED`
(m89–m91); `FUNCTIONS_CRON_ENABLED` (m96); `TENANT_TELEMETRY_EXPORT_ENABLED` (m100);
`DATA_PLANE_READ_REPLICA` (m122); `GITHUB_CONNECT_ENABLED` (m163, Track-E GitHub-App connect/sync).

## SDKs

The TS SDK is **`sdks/js/`** (package **`@grobase/js`**, renamed from `@mini-baas/js` during the
`sdks/` consolidation, commit `ca6aaf8`) — a hand-written reference client, layout
`src/{core,domains,generated,bin,__type_tests__}` + `index.ts`/`types.ts`, tested with **`node:test`**
(not jest/vitest). Its `src/generated/` is **gitignored EXCEPT the curated `engines.ts`** — the engine
capability catalog is the SDK's contract (pinned by `__type_tests__/engines.test-d.ts`) and is committed
as the source of truth (`codegen-engines.mjs` only diffs it vs a live `/engines`); the rest is reproduced.
The polyglot SDKs (`sdks/python/`, `sdks/kotlin/`, `sdks/swift/`, `sdks/dart/`) are
**OpenAPI-generated** from `infra/config/openapi/grobase-public.json` via
`bash sdks/js/scripts/codegen-polyglot.sh` (package identities: python `grobase`, dart `grobase`,
swift `Grobase`, kotlin `com.grobase:grobase-sdk`). The old flat `sdk*/` and `*.rootowned-stale`
duplicate dirs **no longer exist** (they survive only in pre-flatten git history). Build/test
commands are in the table above. The `openapi:collect` link in `codegen:all`, `codegen-polyglot.sh`'s
`SPEC=`, and `m58`'s SDK/spec paths were repointed from the old `mini-baas-infra/…openapi/` location to
`infra/config/openapi/grobase-public.json` (+ `scripts/ops/openapi-collect.sh`) in the flatten, so
codegen now resolves against the lean tree.

## Going to production

- **`HUMAN-ATOMS.md`** (repo root) is the authoritative checklist of every human / money /
  external-account action left to reach GA across the three targets (OSS · managed-cloud ·
  enterprise).
- **`deploy/go-live/go-live.sh`** is a DRY-RUN-default preflight that **fail-fast validates the
  required env vars** (collects a `MISSING=()` list, names the exact missing one, and exits; it never
  pushes, deploys, or flips a flag). It only acts when `GO_LIVE_APPLY=1` is set (then it runs
  `helm upgrade --install --atomic`, projects the cloud flags ON, and does the RS256 cutover) —
  otherwise it renders offline via `helm template`. `deploy/` also holds `helm/` (`grobase` +
  `mini-baas` charts), `kustomize/`, `ha/`, and `github-relay/` (the P5 Vercel relay for GitHub-App
  connect).
- **The full backend is LIVE on fly.io** as the single Machine app **`grobase-stack`** (`deploy/fly/`).
  It is a **Docker-in-Docker compose** deploy: `deploy/fly/Dockerfile` + `compose.override.yml` bring
  the stack up inside one Machine, with Kong exposed publicly; `deploy/fly/boot.sh` is the turnkey
  entrypoint that **auto-migrates and auto-provisions** the registered contracts on boot (`ensure_gateway`
  force-starts mongo-init→realtime→kong so a reboot doesn't strand Kong). Backup rotation:
  `deploy/fly/BACKUP-ROTATION.md`. Two non-merging Postgres DBs (website + vault42) prove per-user
  `read_scoped` isolation over public HTTPS.
- **grobase is a generic contract-driven factory, not an app host.** It contains **zero app-specific
  code**; each app is a declarative **provisioning contract** at `infra/config/contracts/<app>.json`
  (+ a `<app>.schema.sql`) that the generic provisioner consumes to create an isolated DB, seed it,
  mint keys, and emit the frontend's `PUBLIC_*` config (gate `m165`). Stateless frontends live on
  Vercel; **grobase (fly) owns all state** (DB/auth/OTP/realtime/files). This boundary is **binding** —
  see [`.claude/rules/service-boundaries.md`](.claude/rules/service-boundaries.md). Live contracts today:
  `website.json` and `vault42.json`.

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
binding code-gen rules — `minimalism-ladder`, `minimalism-markers`, `comments`, `no-globals`,
`go-package-design`, per-language `refactor-{c,go,rust,typescript,shell,common}`, `api-convention`,
and the binding **`service-boundaries`** rule — grobase owns all state, Vercel hosts only stateless
frontends, apps are contracts not code); `agents/` (8 single-purpose
specialists: architect · benchmarker · compat-tester · devil · documenter · norminette · reviewer ·
security); `skills/` (api-endpoint · debug · doc · incident · new-module · pr-review · release ·
write-test); `commands/`; `workflows/`; and `plugins/`. There is **no** kernel
(`CLAUDE.md`/`instructions.md`/`objectives/`) and **no** `/baas-wave` skill — references to "the
kernel" or `make -C ../.. baas-*` in carried-over docs belong to the monorepo, not this repo.

## `vendor/` — playground apps that connect to the BaaS

`vendor/` is the **proving ground**: real third-party apps re-platformed onto Grobase (or built
native on it) that demonstrate the product thesis — _one backend, any frontend, no per-project server
code_. They are **plain tracked directories** (no submodules, no `.gitmodules`), are **not** part of
the default build/CI (the exceptions are opt-in `movieverse` + `gourmand` compose profiles in
`orchestrators/compose/base/{movieverse,gourmand}.yml`), and each carries its own per-app migration note
(`GROBASE.md` / `GROBASE-MIGRATION.md`; there is **no** top-level `vendor/` doc). The canonical
"migrate an external app onto nano" procedure is the **`.claude/workflows/onboard-app.md`** playbook
(recon → schema → rewire frontend → validate → report).

**Two integration shapes — don't conflate them:**

- **Re-platformed / native** — the app's own backend is replaced by Grobase; the frontend talks
  _only_ to the Kong gateway (Canagrou, MovieVerse, Nimbus, savanna-zoo, HamBooking, **vite-gourmand**).
- **External-DB mount** — the app keeps its own backend untouched and Grobase **mounts its live
  database** (`tenant_owned` isolation) so the platform can introspect/read/write it. vite-gourmand
  _also_ exposes such a mount (`m24`, consumed by osionos dashboards) **in addition to** its
  re-platform — the two are separate dbIds over the same DB and don't interfere.

**Per-app conventions** (uniform across the migrated apps):

- **Provisioning** — an idempotent `scripts/seed/<app>-tenant.sh` creates the tenant, mints an API key
  (`mbk_*`), registers a per-app DB **mount** with its connection string, applies the schema, mints
  tokens, and emits the frontend config (`baas-config.js` → `window.__BAAS__`, `VITE_BAAS_*`, or
  `baas.properties`). Re-running converges.
- **Connection** — mostly **hand-rolled REST clients** over Kong routes (`/auth/v1` GoTrue,
  `/query/v1/{dbId}/tables` or PostgREST `/rest/v1`, `/query/v1/txn` for ACID, `/storage/v1`,
  `/realtime/v1/ws` or SSE) with `apikey` + `X-Baas-Api-Key` + Bearer-JWT headers. Only **MovieVerse**
  uses the `@grobase/js` SDK (via a `grobase-client.js` wrapper).
- **Owner model** — a dedicated per-app mount, owner-scoped per request. Variants: RLS keyed to
  `auth.users` (MovieVerse, vite-gourmand), `owner_id` stamping + `role=admin` bypass (HamBooking), or
  a single shared app-key identity for a public wall (Canagrou, Nimbus).
- **Proof** — each migration lands behind a numbered verify gate that exercises the round-trip live.

| App (`vendor/`)                   | Was                                          | BaaS state                                                                                        | Gate                            |
| --------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------- |
| **Canagrou**                      | PHP/MariaDB photo-share SPA + Flutter mobile | ✅ re-platformed (web **and** mobile) — dedicated PG mount, GoTrue, `post-images` bucket, realtime | `m146-canagrou-roundtrip.sh`    |
| **MovieVerse**                    | Java/Spring/Thymeleaf/MySQL movie community  | ✅ re-platformed → static `dist/` + `@grobase/js` + Go TMDB proxy; PostgREST + RLS, zero app server | `m146-movieverse.sh`            |
| **saas** (Nimbus)                 | React/Vite SaaS admin console (no backend)   | ✅ built native — dual-engine PG **+** Mongo, ACID `/query/v1/txn` money model, realtime           | `m148-nimbus-roundtrip.sh`      |
| **savanna-zoo**                   | React/Vite zoo-management (no backend)       | ✅ built native — PostgREST + GoTrue RBAC + SSE realtime + storage                                 | _(none)_                        |
| **java-dam-baas** (HamBooking)    | Java/Spring/JavaFX ham-carver booking        | ✅ re-platformed — **but the migrated client lives in an external clone `~/Documents/java-dam-baas` (branch `feature/grobase-baas-migration`)**, not here; the old in-repo `vendor/java-dam-baas/` stale snapshot was **removed** in `a0bfc38` (no longer on disk). What IS in-repo: the MariaDB mount + `owner_id` schema + per-table-isolation flags + green gate | `m147-hambooking-isolation.sh` |
| **vite-gourmand**                 | React/NestJS/Prisma/Supabase restaurant ordering | ✅ **re-platformed** — static React SPA on a **local owner-scoped Postgres mount** (GoTrue auth, business logic re-homed to PG triggers); needed the **F1/F2 authz model ported from MySQL to the Postgres adapter**. The older `m24` `tenant_owned` osionos-observability mount still coexists (separate dbId) | `m149-gourmand-baas.sh` (+ `m24-gourmand*`) |
| **music-room**                    | React-Native/NestJS/Mongo music collab       | ⬜ untouched playground — zero BaaS wiring                                                          | —                               |
| **surfind-spain**                 | Laravel 12/Livewire/MySQL Spanish surf directory | ✅ re-platformed — **server-rendered (no SPA), so the frontend was REBUILT from scratch** as a React/Vite/Leaflet SPA (`web/`) on PostgREST+GoTrue; role RLS via `app_metadata`, owner-scoped favorites/comments, 16 beaches seeded; Laravel/MySQL backend removed; serve `:5183` | `m160-surfind-spain.sh`         |
| **hypertube**                     | 42 BitTorrent video search+stream subject    | ✅ re-platformed — backend **entirely Grobase** (GoTrue auth + **MongoDB** catalog/comments/profiles + **DynamoDB** watch_state + realtime) plus **4 custom services** under `vendor/hypertube/grobase/`: a **new Rust `hypertube-stream` engine** (axum/reqwest range-proxy → archive.org HTTP `206` partial-content, YouTube-style fast buffer, H.264+AAC audio, `X-Accel-Buffering:no`), `hypertube-media` (torrent→Range/206 + ffmpeg transcode), `hypertube-search` (archive.org + TMDb), `hypertube-api` (RESTful OAuth2) + a YouTube-style React/Vite SPA (`View/`, same-origin via `grobase/serve.mjs`). **~1848 real archive.org films** bulk-seeded (`hypertube-catalog-bulk`, throttled), **8 user profiles + comments** (`hypertube-users`). **Forced real Grobase fixes: the 8th engine DynamoDB end-to-end (build-arg `--features dynamodb` + `DYNAMODB_ENGINE_ENABLED` + migration `069` + registry `ensureSchemaDDL` engine-CHECK + `RUST_DATA_PLANE_FORWARD_ENGINES` + `dynamodb-local`), Mongo `shared_resources` cross-owner reads, and seed idempotency (control-plane key-reuse, GoTrue pagination, persisted secrets).** Known data-plane limits: pool loses `shared_resources` after a provision (restart `data-plane-router`); mongo `upsert` not idempotent. | `m150`–`m154` |
| **AppFlowy**                      | OSS Notion-alternative — Flutter UI + Rust `flowy-*` core (AGPL-3.0) | ⬜ now committed in-repo as **plain tracked files** (nested `.git` removed in `a0bfc38`, ~2880 files; upstream was `AppFlowy-IO/AppFlowy.git` HEAD `4af02cdc`), still **zero BaaS wiring**; its own backend (AppFlowy-Cloud = PG + GoTrue + storage + collab) mirrors Grobase → a prime future re-platform target. See the **AppFlowy** note below the table | —                               |
| **twenty**                        | TypeScript CRM — twentyhq/twenty (NestJS + GraphQL + TypeORM/Postgres backend, React/Apollo front, nx/yarn monorepo) | ⬜ untouched upstream clone — own nested `.git` (`twentyhq/twenty.git`, branch `main`, HEAD `705caab2`), tracked as an **orphan gitlink** (mode 160000, no `.gitmodules` entry), **zero BaaS wiring** (like music-room); its NestJS + Postgres + GraphQL backend mirrors Grobase → a future re-platform candidate | —                               |
| **vault42**                       | _(new product, own repo)_ — zero-knowledge secrets vault (Rust) | ✅ built **native on Grobase** — tracked nested checkout of `Univers42/vault42`, uses grobase as its store (**GrobaseStore**): per-user ZK envelope blobs in a dedicated `vault42` DB via `/query/v1` with per-user JWT-minting → `read_scoped` owner-scoping (proven: user B sees 0 rows of A). Driven by the **42ctl** umbrella CLI (separate repo `Univers42/42ctl`). Substrate migration `071`; OTP-login `075` + escrow `076` | `m162`–`m165` (rbac/github/otp/contract) |
| **claude-deal-with-the-devil**    | _(not an app)_                               | n/a — a Claude Code framework (rules/agents/skills/tools), **misfiled** here; not a migration target | —                               |

**Gotchas:** Canagrou carries heavy uncommitted/untracked changes on the current branch
(`feature/grobase-hambooking-baas`). MovieVerse opts into the stack with
`docker compose --profile movieverse up -d` before its gate; the others bring the stack up with
`make up`, then run their `scripts/seed/<app>-tenant.sh` + gate by hand. The HamBooking gate proves
isolation over **REST** (F1 shared-catalog read, F2a owner-scope, F2b admin bypass, caps trigger)
against the MariaDB mount — it exercises the Grobase side, independent of any JavaFX client; the
actually-rewired desktop client is the **external** `~/Documents/java-dam-baas` clone; the in-repo
`vendor/java-dam-baas/` snapshot has since been **removed** (no stale `ApiClient` left here to mislead). The per-table-isolation + admin-bypass
data-plane work that backs it is flag-gated (`DATA_PLANE_PER_TABLE_ISOLATION`, `DATA_PLANE_ADMIN_BYPASS`,
default OFF). `scripts/seed/agency-tenant.sh` provisions a permanent "agency" demo tenant (not tied to
one `vendor/` app).

### AppFlowy (`vendor/AppFlowy`) — untouched upstream, un-integrated

A checkout of **AppFlowy-IO/AppFlowy** (the AGPL-3.0 OSS Notion alternative), originally upstream HEAD
`4af02cdc`, **now committed in-repo as plain tracked files** (its nested `.git` was removed in `a0bfc38`,
~2880 files — the same vendoring shape as the realtime workspace) and with **zero grobase references on
disk**. It is **not** wired to the BaaS and **not** in grobase's build/CI — an unintegrated playground
(it shares `music-room`'s zero-wiring state, though `music-room` stays untracked). Documented here only
so a future re-platform starts from facts instead of a re-scan; unlike the other apps it builds **on the
host** (Flutter + cargo-make), not through grobase's Docker stack.

**Architecture (one codebase, two languages — under `frontend/`):** a **Flutter** UI (`appflowy_flutter`,
app `appflowy` v0.11.4, Flutter ≥3.27.4 / Dart ≥3.3.0; `flutter_bloc` + `get_it` + `go_router`, plugin
system under `lib/plugins/`) embeds a **Rust** core (`rust-lib`, a **31-member** cargo workspace, Rust
1.85) over `dart:ffi`. The `dart-ffi` crate compiles to `libdart_ffi` and bridges Dart↔Rust across the
`lib-dispatch` protobuf **event bus** (FFI symbols `init_sdk` / `async_event` / `sync_event` /
`set_stream_port`); `flowy-core::AppFlowyCore` is the composition root wiring the feature managers
(`flowy-folder` / `-document` / `-database2` / `-user` / `-ai` / `-search` / `-storage`). Each feature
crate is paired with a thin **`*-pub` port crate** that declares its cloud-service trait, and the
**backend is chosen at runtime by `AuthType`** (`Local`=0 offline vs `AppFlowyCloud`=2, see
`flowy-core/src/server_layer.rs`) — `flowy-server` ships both `local_server` and `af_cloud` impls.
Offline-first sync is the external **AppFlowy-Collab** CRDT crates (rev `4dfccef`, **yrs 0.21** = the Rust
Yjs port) glued in via `collab-integrate` (+ RocksDB local persistence). The hosted backend is the
**separate `AppFlowy-IO/AppFlowy-Cloud`** project (client-api git deps at rev `592f644` in
`rust-lib/Cargo.toml`) — **Postgres + GoTrue + object storage + a collab/realtime server**, i.e. the same
shape Grobase provides, which is exactly why AppFlowy is a strong (but large) future re-platform candidate.

**Build (cargo-make is the entry point):** the driver is `frontend/Makefile.toml` (it `extend`s **10**
`scripts/makefile/*.toml` fragments). Protobuf + `dart_event` bindings are generated **FROM the Rust** at
build time (`dart-ffi`'s `build.rs` → `flowy_codegen`); Dart-side `freezed`/`json`/`envied` via
`build_runner`. Key invocations (run in `frontend/`): bootstrap `bash scripts/install_dev_env/install_linux.sh`;
full dev build `cargo make --profile development-linux-x86_64 appflowy-dev`; codegen
`cargo make code_generation`; tests `cargo make rust_lib_unit_test` / `dart_unit_test`; one Flutter case
`cargo make flutter_test '<path>' --name '<case>'`. The in-repo `docker-compose` builds only the
X11-forwarded **desktop client**, not a backend.

> **One on-disk `vendor/` dir is absent from the table above** (there are now **13** on-disk dirs; the
> table covers 12 of them and additionally keeps a **`java-dam-baas`** row whose in-repo snapshot was
> removed in `a0bfc38`): the uncovered on-disk dir is
> **`grobase-website`** — *not* an external app but a nested checkout whose remote is
> `Univers42/grobase.git` itself (HEAD `a0bfc38`, an Astro site in its tree); the canonical
> marketing/login portal is the **separate** `Univers42/grobase-website` repo (cloned at
> `~/Documents/grobase-website`, wired to binocle-one), so it is deliberately not given a re-platform row.
> (**AppFlowy** *is* in the table now — its deep-dive note is the section directly above this line.)

## Appendix — historical note (pre-flatten layout)

The lean layout is now on `main`, so a clean clone never shows the old tree. You will only meet it
when **reading pre-flatten commits/branches**: there the buildable system lived under
**`mini-baas-infra/`** with no root `Makefile`, the Go control plane was `mini-baas-infra/go/control-plane`
(→ now `src/control-plane`), the Rust data plane `mini-baas-infra/docker/services/data-plane-router`
(→ `src/data-plane-router`), config under `mini-baas-infra/{config,openapi}/` (→ `infra/config/…`),
and the SDKs were `sdk/` (`@mini-baas/js`) + `sdk-{python,kotlin,swift,dart}/` (+ `*.rootowned-stale/`
dupes). To read such a ref, prefix the lean paths with `mini-baas-infra/` and apply those renames.
That ref also still tracks `.gitmodules` and CI with `context: mini-baas-infra/...`.
