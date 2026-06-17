# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **standalone `grobase` repository** (`github.com/Univers42/grobase`) — the Grobase
BaaS, extracted from the Track-Binocle monorepo's `apps/baas/` subtree and migrated here as a
self-contained repo (own remote, own CI; see commit `d3de3fb`). It is **not** a
subtree anymore: there is no parent `../../CLAUDE.md` and no monorepo root Makefile to defer to.

Grobase is a **self-hostable Backend-as-a-Service**: one backend, any frontend, no per-project
server code — swappable engines, isolation models, and editions on **one codebase, no rewrite**
(5 MB single binary → 10K-tenant platform). It is a **live product mid-migration (TS → Rust data
plane)**, so legacy TS engine code is retained behind the deletion gate while Rust serves traffic.
Beyond OSS self-host it also runs as a **managed cloud** (sign-up → API key → CRUD/realtime → usage
→ Stripe billing) and an **enterprise-procurable** platform (orgs/RBAC, SSO/SCIM, audit, compliance,
CMEK). Every cloud/enterprise behavior is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition (flag tables below).

## Repo layout & migration traps — READ THIS FIRST

The migration left the working tree in a half-settled state. The single most important fact:

> **The buildable system lives under `mini-baas-infra/`. Drive everything from
> `mini-baas-infra/Makefile`. There is no root Makefile.**

Everything else at the repo root (`sdk*/`, `wiki/`, `scripts/`, `config/`, `Dockerfile`,
`HUMAN-ATOMS.md`) is the rest of the old `apps/baas/*` tree carried along.

**Untracked / dead artifacts — never edit these, they are not part of any build:**

- **`grobase/` (nested)** — *was* an *orphan embedded git repo* (gitlink mode `160000`, **not** in
  `.gitmodules`): a recursive pre-migration copy of this repo. **De-tracked in commit `3396baf`,
  which is now in `origin/main`** — so `git ls-tree origin/main grobase` is empty and a fresh clone
  no longer carries it. If an *old* local checkout still has a nested `grobase/`, ignore it entirely
  (`git ls-files` shows zero files under it).
- **Root `docker/` and `site/`** — content exists on disk (root-owned) but **0 files are
  git-tracked**. The canonical docker tree is `mini-baas-infra/docker/`; the marketing site is
  driven via `site/package.json` (below).
- **`sdk-dart.rootowned-stale/`, `sdk-python.rootowned-stale/`** — dead root-owned duplicates. Use
  the un-suffixed `sdk-dart/`, `sdk-python/`.
- **Root `CONCLUSION.md`, `vendor/`, and `certs/`** — all **untracked** (`git ls-files` shows zero),
  not part of any build. `vendor/` holds only `vendor/Understand-Anything/` (its own nested `.git/`);
  `certs/` is local dev TLS material (regenerate locally, never commit). Working-tree artifacts — ignore them.

**CI is rewired (no longer mid-migration).** `.github/workflows/ci.yml` builds every service from
`context: mini-baas-infra/...` and runs all compose/migrate/gate jobs with
`working-directory: mini-baas-infra`, so the bare `docker-compose.yml` + `scripts/generate-env.sh` it
references resolve correctly inside `mini-baas-infra/` (where they actually live — note
`generate-env.sh` is `mini-baas-infra/scripts/generate-env.sh`, *not* root `scripts/`). The old flat
`./docker/services/<svc>` layout is gone (see the comment near `ci.yml` L64). It's a single ~630-line
workflow with a per-PR fast path + a nightly full enterprise gate battery. **Which `ci.yml`:** two
are git-tracked — the **active** one is the repo-root `.github/workflows/ci.yml` (~630 lines,
`context: mini-baas-infra/...`); the other lives inside the vendored realtime workspace
(`docker/services/realtime/realtime-agnostic/.github/workflows/ci.yml`) — upstream vendored code,
leave it. (A dead pre-migration duplicate at `mini-baas-infra/.github/workflows/ci.yml` — never
executed, since GitHub only runs workflows under the repo-root `.github/workflows/` — was deleted.)

**No initialized git submodules — but `.gitmodules` is still committed.** `.gitmodules` is tracked in
`HEAD` (it declares 6 *dead* submodules: `vendor/{libcss,scripts,tinte,ui,ui.nowts.app}` +
`docker/services/realtime/realtime-agnostic`), yet **none were ever initialized** (zero `160000`
gitlinks anywhere). It is currently **deleted from the working tree but the deletion is uncommitted**
(`git status` shows ` D .gitmodules`) — so treat every declaration as dead, but know the file still
exists in the committed tree until that removal lands. The realtime Rust workspace is **vendored as
plain files** at `mini-baas-infra/docker/services/realtime/realtime-agnostic` (162 tracked files, no
nested `.git`), not a submodule — update it in place.

**Root `scripts/`** are host-side helpers (TLS cert generation, env bootstrap, DB bootstrap,
Postgres password sync) — a *different* set from `mini-baas-infra/scripts/`. Don't confuse the two.

## Three-language plane layout (paths under `mini-baas-infra/`)

| Plane | Language | Path | What |
|---|---|---|---|
| **Application** | TypeScript (NestJS) | `src/apps/*` + `src/libs/*` | query-router, storage-router, schema/session/permission/analytics/ai/email/gdpr/newsletter services, outbox-relay, mongo-api |
| **Control** | Go | `go/control-plane/` (module `github.com/dlesieur/mini-baas/control-plane`) | ~30 `internal/` pkgs — **core:** `tenants provision packages orchestrator adapterregistry shared`; **cloud:** `metering quotastage spendcap abuseguard entitlements backup`; **functions:** `funcsecrets functriggers scheduler`; **enterprise (D):** `orgs sso scim passkeys audit compliance cmek trust ipguard erase export telemetryexport`; **parity (E):** `branching push webhooks` |
| **Data** | Rust | `docker/services/data-plane-router/` (cargo workspace) | crates: `data-plane-core`, `data-plane-pool`, `data-plane-server`, `engine-conformance` |
| **Realtime** | Rust (vendored) | `docker/services/realtime/realtime-agnostic/` | event-bus router + IRC bridge (separate workspace) |

**8 engine adapters** live in `data-plane-pool/src/`: `postgres mysql mongo mssql sqlite redis http
dynamodb` (`dynamodb` is an opt-in cargo feature, OFF by default). **Engine-agnostic by construction** —
a fix that works for Postgres but breaks the other seven is not done. Owner-scoping/RLS is enforced
**per request**, not by pool state (this is what lets `SHARE_POOLS` collapse 10K tenants onto one pool).

**The load-bearing seam** (needs all three plane dirs to see): the **Go control plane** resolves a
cleartext API key → identity via `POST /v1/keys/verify`; the **Rust data plane** then *executes* the
query and owner-scopes it per request using that identity. Control plane = tenancy/keys/billing/enterprise
(6 `cmd/` binaries — `tenant-control adapter-registry orchestrator function-scheduler webhook-dispatcher
scale-seed`; email/gdpr/newsletter/session/outbox also live in Go under `internal/orchestrator/`, not only
in the TS plane). Data plane = query execution; per-engine capability truth lives in Rust
(`data_plane_core::EngineCapabilities`) and is surfaced through the TS query-router. The **TS→Rust cutover
is a per-request switch, not a build flag**: `RUST_DATA_PLANE_FORWARD=1` (TS-side, default off;
`RUST_DATA_PLANE_FORWARD_ENGINES=postgresql,mongodb`) is independent of the Rust-side
`DATA_PLANE_ROUTER_PRODUCT_MODE` (`shadow`|`enabled`); the m18/parity gates exercise both halves.

The data plane also builds **multiple product shapes from one codebase via cargo features**: `nano`
(SQLite-only, ~5 MB scratch image), `one` (+ OAuth/TOTP/SMTP/file-storage/admin UI at `/_/`), opt-in
`dynamodb`, `control-pg` (server-backed automations + transactional outbox). The realtime workspace is
10 crates (`realtime-core/-engine/-auth/-gateway/-server/-client`, DB producers `-db-postgres`/`-db-mongodb`,
buses `-bus-inprocess`/`-bus-irc`) with a **pluggable EventBus** (`inprocess`|`irc`) and DB change
producer (`postgres`|`mongodb`) assembled in `realtime-server`. Per-crate `README.md`s under
`docker/services/data-plane-router/crates/` are the authoritative architecture docs for the data plane.

## Running & building (`mini-baas-infra/Makefile`)

Run from `mini-baas-infra/`. Drive the stack **only** through it (Docker-first; no host
node/cargo/go for lifecycle).

```bash
# from mini-baas-infra/  — Docker-first: every toolchain (cargo/go/node) runs INSIDE containers
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
make nano-up|one-up           # product editions: binocle-nano (5 MB) / binocle-one
make cloud-up                 # managed-cloud overlay (turns cloud/enterprise flags ON — NOT a default)
make conformance | conformance-<engine> | parity | parity-suite
```

**Two orthogonal stack-shaping dimensions** exist, not one: **EDITIONS** (a named set of planes) and
**PACKAGES** (the customer tiers in `mini-baas-infra/config/packages/packages.json` — the single source
of truth for tiers; keys `nano basic essential pro max`, though `make up PACKAGE=` accepts only the
four non-nano tiers — `nano` ships standalone via `make nano-up`, not `PACKAGE=nano`). When several are set, precedence is
**`PROFILES` > `PACKAGE` > `EDITION`**. Each plane auto-generates `up-/down-/restart-/logs-<plane>`
verbs. Gotchas:

- `make up EDITION=full` deliberately **excludes** the `playground` plane (its assets aren't in this
  repo, so `full` still comes up clean), and bare `make parity` **errors out** (exit 1, not a silent
  no-op) — it needs `make parity NEW=<url> [OLD=<url>] [ROUTES=<set>]`.
- **First run:** `make up` auto-generates `.env` if it's missing (`[ -f .env ] || make env`, same as
  `quickstart`) and never clobbers an existing one (`scripts/generate-env.sh` refuses without
  `FORCE=1`). `make env`/`make secrets` shell out to **host `openssl`** — the one Docker-first
  exception — and abort if it's absent.
- **Busy ports:** `make up` evaluates `scripts/resolve-ports.sh`, which auto-increments any in-use
  host port (Kong 8000, Postgres 5432, Mongo 27017, …) to the next free one and only warns on stderr.
  `make health` and the `quickstart` banner discover the live published Kong port at runtime
  (`docker port mini-baas-kong 8000/tcp`, falling back to 8000 when the stack is down), so they probe
  and print the correct `localhost:<port>` even when 8000 was taken. Other host ports surface only via
  that stderr warning — use `docker compose ps` / `docker port` to confirm them.

Build/lint/test per language is its own table below.

### Verify gates (the unit of "done")

New BaaS work lands behind a **numbered milestone gate** — a self-contained script
`mini-baas-infra/scripts/verify/m<NN>-*.sh` (currently **126 scripts, through m145**). There are no
`baas-verify-*` Makefile wrappers in this repo (those were monorepo-root targets). Run a gate
directly:

```bash
bash mini-baas-infra/scripts/verify/m80-quota-enforce.sh           # one gate, direct
bash mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh
```

A gate that passes vacuously (no-op) is not a gate — gates must actually exercise the behavior. Run
**many** gates at once with `bash mini-baas-infra/scripts/verify/run-gate-battery.sh m120`. The
script's two curated sets are the source of truth (**not** a contiguous range): `--enterprise` runs
the nightly enterprise + data-plane battery (m101 + m103…m112, m120…m122, m135–m137, m139, m141, m143 — `m144`/`m145`
are *deliberately excluded*: they validate the gitignored `site/` and uncommitted bench artifacts, so
run those two by hand at release time), `--fast` runs the per-PR subset (m101 + m120), and a
bare/`-h` invocation prints help and runs nothing (trailing gate tokens are appended, so `--fast m122`
works). CI runs a per-PR subset plus a nightly full battery, so a gate is *enforced*, not just a local
convenience. Useful insight: `make conformance` is just an alias
for the m27 script and `make verify-all` loops every `m*-*.sh` — **the scripts are the source of
truth; the make targets are thin wrappers.** Each flag-gated feature has its own gate (e.g. `m103-orgs-rbac.sh`,
`m110-sso-oidc.sh`, `m123-cmek-envelope.sh`, `m135-abac-column-mask.sh`) — run that one to verify a single flag.
The newest band **m140–m145** is *not* feature-flagged (hence absent from the flag tables below): these are
hardening / posture gates — `m140` network-controls + WAF, `m141` compliance-posture, `m142` edge-error-mapping,
`m143` compliance-matrices, `m144` trust-page-parity, `m145` cost-model integrity.

### Build, lint & test (per plane) — including how to run ONE test

Every toolchain runs **in Docker** (the make wrappers build/cache the images — no host node/cargo/go).
There is a wrapper for the *whole* suite per plane; for a *single* test, invoke the runner through the
same container (right-hand column).

| Plane | Whole suite (Docker wrapper) | One test |
|---|---|---|
| **TS app** (NestJS · Jest) | `make nestjs-ci` = tsc --noEmit + eslint + jest; `make nestjs-build-<app>` | `docker run --rm -v "$PWD/src":/app -w /app -v mini-baas-src-node-modules:/app/node_modules node:20-alpine npx jest <spec> -t '<case>'` — only 3 specs exist, all under `src/apps/query-router/src/query/` |
| **Go control** | `make go-control-plane-check` (`go vet ./... && go test ./...`); `make go-control-plane-build` | from `go/control-plane/`: `docker run --rm -v "$PWD":/src -w /src golang:1.25-bookworm go test ./internal/<pkg> -run TestX -v` (use 1.25 — go.mod declares `go 1.25.0`; both `go-control-plane-check` and `-build` pin `golang:1.25-bookworm`) |
| **Rust data** | `make rust-data-plane-check` / `-build` — **no `-test` target** | `make _rust-toolchain` once, then `cargo test -p data-plane-core <name>` via the data-plane CARGO wrapper; engine integration = `make conformance` / `conformance-<engine>` |
| **Rust realtime** | `make rust-realtime-check \| -test \| -build` | `cargo test -p realtime-core <name>` via the realtime CARGO wrapper |
| **TS SDK** (`sdk/` · node:test) | `cd sdk && npm run build && npm test` | `node --test tests/<name>.test.mjs` (or `--test-name-pattern='<re>'`) — **NOT** jest/vitest |
| **Polyglot SDKs** | py+dart `m58-sdks-compile.sh` · swift `m62-sdk-swift.sh` · kotlin `m63-sdk-kotlin.sh` | the generated `test/` stubs are empty `pass` bodies — the **build/compile gates are the real check**, not `pytest`/`dart test` |

Notes: the data-plane crate's produced binary is **`data-plane-router`** (not `data-plane-server`);
realtime's is `realtime-server`. The SDK `src/generated/` tree is **gitignored** — regenerate with
`cd sdk && npm run codegen:all`. All SDKs (polyglot ones via `bash sdk/scripts/codegen-polyglot.sh`)
derive from one spec: `mini-baas-infra/openapi/grobase-public.json`.

**Code quality (SonarCloud).** `mini-baas-infra/sonar-project.properties` (org `univers42`,
projectKey `Univers42_grobase`) defines the analysis scope — sources are `docker/services`, `scripts`,
`config`, `src/apps`, `src/libs`, but the verify-gate battery (`scripts/verify/**`), benches,
`security`/`scale`/`seed` scripts, migrations, Dockerfiles, and the vendored `realtime-agnostic/**`
are **excluded**, so lint nits there are intentionally not findings. There is **no make target** —
analysis runs through SonarCloud's GitHub integration; pull the current issue list with
`bash mini-baas-infra/scripts/sonar-fetch-issues.sh`.

## Editions, planes, and compose overlays

An **edition** = a named set of planes (`EDITION_query := data go rust adapter background`, etc.).
Beyond the base `mini-baas-infra/docker-compose.yml`, additive overlays opt into capabilities —
never defaults:

| Overlay | Purpose |
|---|---|
| `docker-compose.cloud.yml` | Managed-cloud: turns Track-B feature flags **ON** (`make cloud-up`) |
| `docker-compose.pooler.yml` | Connection pooler (supavisor) — Track-C / C1 |
| `docker-compose.scale.yml` | 10K-tenant scale experiment (raises `max_connections` — costly) |
| `docker-compose.netseg.yml` | Per-plane network segmentation |
| `docker-compose.graphql.yml` | GraphQL edition (A5) |
| `docker-compose.prod.yml` | Production: no dev ports, resource limits |
| `docker-compose.ci.yml` | CI shape |
| `docker-compose.track-binocle.yml` | Carried-over monorepo-integration overlay |

**Gotcha — GHCR pull-fallback.** ~49 services in the base `docker-compose.yml` carry an
`image: ghcr.io/univers42/grobase-<svc>:latest` line above their `build:` block, so a plain
`docker compose up` **pulls the prebuilt `:latest` image instead of building local source** — your
edits to a service won't take effect until you build it (`make build`, or `docker compose build
<svc>`). (Image org is lowercase `univers42`, unlike the repo's `Univers42`.)

## Cloud, enterprise & parity features are flag-gated OFF

Every cloud / enterprise / parity feature is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition. **Do not flip these ON in shared/parity runs without a gate** —
OFF is the proven state. OFF is *structural*, not config-file-based: in Go the feature routes are
physically not mounted unless `if envBool("FLAG")` (defaults false), so a missing var = byte-parity by
construction. `make cloud-up` turns the set ON via `config/cloud/flags.env.cloud`. **Gotcha — the
master+sub-flag AND pattern:** several features need *both* halves truthy, e.g. metering =
`METERING_ENABLED` (control) AND `DATA_PLANE_METERING` (Rust); enforcement = `QUOTA_ENFORCEMENT` AND
`DATA_PLANE_QUOTA_ENFORCEMENT` — flip only one and you get a silent no-op. **Subtle TS-vs-Go gate
seam:** `PERMISSION_CONDITIONS_ENABLED` / `API_KEY_ABAC_ENABLED` (m135–m139, ABAC) are *not* Go
`envBool` route-mount gates like the Track-D flags — they gate at the **TS / data-plane PDP** (query
execution & permission evaluation), so grep them in `src/apps/permission-engine` & `query-router`, not
the Go control plane. SQL migrations live in `mini-baas-infra/scripts/migrations/postgresql/`; the full
set is **001–065** and the cloud/enterprise/parity slice specifically runs **040–065** (note the
**057–059 gap**: `056` jumps to `060`; highest is `065_least_privilege_rls.sql`). Mongo/MySQL migrations
are separate and tiny (`make migrate-mongo` / `migrate-mysql`, which need the `data-plane` profile up).

**Track-B managed-cloud (B1–B6):**

| Feature | Flag(s) | Migration |
|---|---|---|
| metering (m74–m79) | `DATA_PLANE_METERING`, `METERING_ENABLED` | `040_tenant_usage.sql` |
| quota enforce (m80) | `QUOTA_ENFORCEMENT` | — |
| billing/Stripe (m82) | `BILLING_ENABLED` | `041_tenant_billing.sql` |
| tenant self-serve (m83–m84) | `TENANT_SELFSERVE_ENABLED` | — (`/v1/tenants/me*`, tenant from credential — no `{id}`, no cross-tenant by construction) |
| per-tenant obs (m85) | `TENANT_OBS_ENABLED`, `DATA_PLANE_TENANT_OBS` | — (tenant_id as a log *field*, never a Prometheus label) |
| backup/restore (m87) | `TENANT_BACKUP_ENABLED` | `042_tenant_backups.sql` |

**Track-D enterprise · Track-E parity · dynamic-builder / ABAC:**

| Feature (track · gate) | Flag(s) | Migration |
|---|---|---|
| org model + RBAC (D1 · m103) | `ORG_MODEL_ENABLED` | — |
| audit chain (D3 · m104) | `TENANT_AUDIT_ENABLED` | — |
| hard-erase (D4.4 · m105) · IP allowlist (D2e · m106) | `HARD_ERASE_ENABLED` · `TENANT_IP_ALLOWLIST_ENABLED` | `049` |
| passkeys / WebAuthn (D2c · m107) | `PASSKEYS_ENABLED` | `050` |
| SOC2-lite evidence (D4.1 · m108) · tenant export (D4.3 · m109) | `SOC2_EVIDENCE_ENABLED` · `TENANT_EXPORT_ENABLED` | `051`, `052`, `064` |
| enterprise SSO/OIDC (D2a · m110) · SCIM 2.0 (D2b · m111) | `SSO_ENABLED` · `SCIM_ENABLED` | `053`, `054` |
| trust center (D4.6 · m112) | `TRUST_CENTER_ENABLED` | — |
| DB branching (E · m113) · push/messaging (E · m114) | `DB_BRANCHING_ENABLED` · `PUSH_ENABLED` (+ `PUSH_SSRF_ALLOW_HOSTS`) | `055`, `056` |
| CMEK / BYOK envelope (m123) | `CMEK_ENABLED` | `061` |
| dynamic builder (m130–m134) | `BUILDER_ENABLED` | `062` |
| fine-grained ABAC (m135–m139) | `PERMISSION_CONDITIONS_ENABLED`, `API_KEY_ABAC_ENABLED` | `063` |

Other slices, also OFF by default: `QUOTA_STAGE` · `SPEND_CAPS_ENABLED` · `ABUSE_GUARD_ENABLED`
(m89–m91); `FUNCTIONS_CRON_ENABLED` (m96); `TENANT_TELEMETRY_EXPORT_ENABLED` (m100);
`DATA_PLANE_READ_REPLICA` (m122).

## SDKs

The TS SDK is `sdk/` (package `@mini-baas/js`) — hand-written reference client, layout
`src/{core,domains,generated,bin,__type_tests__}`, tested with **`node:test`** (not jest/vitest). Its
`src/generated/` is **gitignored** (reproduced from the spec, never committed). The polyglot SDKs
(`sdk-python/`, `sdk-kotlin/`, `sdk-swift/`, `sdk-dart/`) are **OpenAPI-generated** from
`mini-baas-infra/openapi/grobase-public.json` via `bash sdk/scripts/codegen-polyglot.sh`. The
`*.rootowned-stale` dirs are **older, git-tracked spec generations** (not byte-identical duplicates) —
never edit them; use the un-suffixed dirs. Build/test commands are in the table above.

## Marketing site (`site/`) — not part of the BaaS stack

`site/` is the standalone **Grobase marketing site** (`grobase-site`, Astro; strict hashed CSP, no
inline `style=`/scripts). It is **container-only**: every script proxies through
`site/scripts/container-only.mjs`. Drive it via `site/package.json` (the monorepo's
`make grobase-*` / `infrastructure/makes/grobase.mk` targets do **not** exist in this repo):

```bash
# inside a container, from site/
npm run dev          # astro dev on :4324
npm run build        # production build
npm run audit:all    # Lighthouse + a11y (pa11y) + CSP
npm run test:e2e     # Playwright
```

## Going to production

- **`HUMAN-ATOMS.md`** (repo root) is the authoritative checklist of every human / money /
  external-account action left to reach GA across the three targets (OSS · managed-cloud ·
  enterprise).
- **`mini-baas-infra/deploy/go-live/go-live.sh`** is a DRY-RUN-default preflight that **fail-fast
  validates the required env vars** (collects a `MISSING=()` list, names the exact missing one, and
  exits; it never pushes, deploys, or flips a flag). It only acts when
  `GO_LIVE_APPLY=1` is set (then it runs `helm upgrade --install --atomic`, projects the cloud flags
  ON, and does the RS256 cutover) — otherwise it renders offline via `helm template`.

## Binding rules (project policy — apply even to one-off tasks)

1. **Never co-author a push.** Commits and PRs carry **no** `Co-Authored-By` / "Generated with"
   trailer. *(Overrides the default git-trailer behavior for all work in this repo.)*
2. **Shadow → parity → cutover → delete.** No deletion/cutover of legacy TS engine code unless all
   three gates PASS: m18 live-traffic · shadow parity · CI-green-with-forward. **UNKNOWN = FAIL.**
3. **Measured, not claimed.** Every perf/capacity statement cites an artifact
   (`mini-baas-infra/artifacts/bench/…`) + the make target that reproduces it. No invented numbers.
4. **Least change, reversible first.** Behavior changes are flag-gated OFF by default so the live
   baseline stays byte-parity.
5. **Engine-agnostic by construction.** A fix for one engine that breaks the other seven is not done.
6. **Confirm the irreversible** (pushes, deploys, deletions, npm publish, RS256 live cutover) —
   explicit human trigger. Report outcomes faithfully (failures stated, skips stated).
7. **Read by query, not by slurp.** Logs/large files: `tail`/`rg`/`jq`/`awk` or the Explore
   subagent; never pull a whole log/large file into context.

## Note on the agent OS

Unlike the monorepo's `apps/baas/.claude/`, this repo's `.claude/` holds **only**
`settings.local.json` (disables the `osionos` MCP server) — there is **no** agent-OS kernel
(`CLAUDE.md`/`instructions.md`/`agents/`/`objectives/`) and no `/baas-wave` skill here. References to
"the kernel" or `make -C ../.. baas-*` in carried-over docs belong to the monorepo, not this repo.
