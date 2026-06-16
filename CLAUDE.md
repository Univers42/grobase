# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This file scopes the **`apps/baas/` subtree** (the Grobase BaaS). The repo-root `../../CLAUDE.md`
covers the wider Track-Binocle monorepo; this file does not repeat it. Two other docs are
**authoritative and binding** for work here — read them before substantial changes:

- **`.claude/CLAUDE.md`** — the agent-OS *kernel* (rules, workflow, gates). Not auto-loaded. Its
  always-binding rules apply even to one-off edits (see "Binding rules" below).
- **`.claude/instructions.md`** — the TS→Rust deletion-gate discipline.

## What this subtree is

Grobase is a **self-hostable Backend-as-a-Service**: one backend, any frontend, no per-project
server code — swappable engines, isolation models, and editions on **one codebase, no rewrite**
(5 MB single binary → 10K-tenant platform). It is a **live product mid-migration (TS → Rust data
plane)**, so legacy TS engine code is retained behind the deletion gate while Rust serves traffic.

Beyond OSS self-host it now also runs as a **managed cloud** (sign-up → API key → CRUD/realtime →
usage → Stripe billing) and an **enterprise-procurable** platform (orgs/RBAC, SSO/SCIM, audit,
compliance, CMEK). Every such behavior is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition (flag tables below).

### Three-language plane layout (where the real code lives)

| Plane | Language | Path | What |
|---|---|---|---|
| **Application** | TypeScript (NestJS) | `mini-baas-infra/src/apps/*` + `src/libs/*` | query-router, storage-router, schema/session/permission/analytics/ai/email/gdpr/newsletter services, outbox-relay, mongo-api |
| **Control** | Go | `mini-baas-infra/go/control-plane/` (module `github.com/dlesieur/mini-baas/control-plane`) | ~30 `internal/` pkgs — **core:** `tenants provision packages orchestrator adapterregistry shared`; **cloud/metering:** `metering quotastage spendcap abuseguard entitlements backup`; **functions:** `funcsecrets functriggers scheduler`; **enterprise (D):** `orgs sso scim passkeys audit compliance cmek trust ipguard erase export telemetryexport`; **parity (E):** `branching push webhooks` |
| **Data** | Rust | `mini-baas-infra/docker/services/data-plane-router/` (cargo workspace) | crates: `data-plane-core`, `data-plane-pool`, `data-plane-server`, `engine-conformance` |
| **Realtime** | Rust | `mini-baas-infra/docker/services/realtime/realtime-agnostic/` | event-bus router + IRC bridge (separate workspace) |

**8 engine adapters** live in `data-plane-pool/src/`: `postgres mysql mongo mssql sqlite redis http
dynamodb`. **Engine-agnostic by construction** — a fix that works for Postgres but breaks the other
seven is not done. Owner-scoping/RLS is enforced **per request**, not by pool state (this is what
lets `SHARE_POOLS` collapse 10K tenants onto one pool).

The top-level `go/control-plane/` (repo root) is a stub with **no `go.mod`** — ignore it; the
buildable control plane is the one above.

## Running & building (which Makefile matters)

There are **two Makefiles**, and where you run a target matters:

- **`mini-baas-infra/Makefile`** — service lifecycle for *this* subtree. Run from
  `mini-baas-infra/`. Drive the stack **only** through it (Docker-first; no host node/cargo/go for
  lifecycle). `Makefile.legacy` is the old one — don't use it.
- **repo-root `Makefile`** — exposes milestone gates (`baas-verify-mN`, `baas-verify-all`) and
  `baas-security-scan`.

```bash
# from mini-baas-infra/
make editions                 # lean query realtime analytics prod full  (default EDITION=query)
make up EDITION=query         # bring up a known-good shape; planes compose into editions
make planes                   # list planes (data control go rust adapter background analytics storage realtime …)
make doctor                   # environment sanity check
make health / make ps / make logs
make build                    # build the stack images
make rust-data-plane-build    # build just the Rust data plane (also: rust-data-plane-check)
make rust-realtime-build|check|test
make go-control-plane-build|check
make migrate / migrate-status / migrate-all / migrate-mongo / migrate-mysql
make bench-load|bench-capacity|bench-footprint|bench-mem|bench-startup
make nano-up|one-up           # the two product editions: binocle-nano (5 MB) / binocle-one
make cloud-up                 # managed-cloud overlay (turns cloud/enterprise flags ON — NOT a default)
make conformance / parity / parity-suite
```

### Verify gates (the unit of "done")

New BaaS work lands behind a **numbered milestone gate**. Each milestone has a self-contained
script `mini-baas-infra/scripts/verify/m<NN>-*.sh` (currently **123 scripts, through m142**). Run one
directly to check a feature:

```bash
bash mini-baas-infra/scripts/verify/m80-quota-enforce.sh        # one gate, direct
bash mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh
# or via the root Makefile wrappers:
make -C ../.. baas-verify-m80
make -C ../.. baas-verify-all     # m1…m10 in order  (BAAS_VERIFY_LIVE=1 for live)
make -C ../.. baas-security-scan  # SEMGREP + npm audit
```

A gate that passes vacuously (no-op) is not a gate — gates must actually exercise the behavior.

## Editions, planes, and compose overlays

An **edition** = a named set of planes (`EDITION_query := data go rust adapter background`, etc.).
Beyond the base `docker-compose.yml`, additive overlays opt into capabilities — never defaults:

| Overlay | Purpose |
|---|---|
| `docker-compose.cloud.yml` | Managed-cloud: turns Track-B feature flags **ON** |
| `docker-compose.pooler.yml` | Connection pooler (supavisor) — Track-C / C1 |
| `docker-compose.scale.yml` | 10K-tenant scale experiment (raises `max_connections` — costly) |
| `docker-compose.netseg.yml` | Per-plane network segmentation |
| `docker-compose.graphql.yml` | GraphQL edition (A5) |
| `docker-compose.prod.yml` | Production: no dev ports, resource limits |
| `docker-compose.ci.yml` | CI shape (used by the gate battery in GitHub Actions) |

## Cloud, enterprise & parity features are flag-gated OFF

Every cloud / enterprise / parity feature is **flag-gated OFF by default** so the stack stays
byte-parity with the OSS edition. **Do not flip these ON in shared/parity runs without a gate** —
OFF is the proven state. `make cloud-up` turns the set ON for the managed-cloud overlay.

**Track-B managed-cloud (B1–B6):**

| Feature | Flag(s) | Migration |
|---|---|---|
| metering (m74–m79) | `DATA_PLANE_METERING`, `METERING_ENABLED` | `040_tenant_usage.sql` |
| quota enforce (m80) | `QUOTA_ENFORCEMENT` | — |
| billing/Stripe (m82) | `BILLING_ENABLED` | `041_tenant_billing.sql` |
| tenant self-serve (m83–m84) | `TENANT_SELFSERVE_ENABLED` | — (`/v1/tenants/me*`, tenant from credential — no `{id}`, no cross-tenant by construction) |
| per-tenant obs (m85) | `TENANT_OBS_ENABLED`, `DATA_PLANE_TENANT_OBS` | — (tenant_id as a log *field*, never a Prometheus label) |
| backup/restore (m87) | `TENANT_BACKUP_ENABLED` | `042_tenant_backups.sql` |

**Track-D enterprise · Track-E parity · dynamic-builder / ABAC (landed since m87):**

| Feature (track · gate) | Flag(s) | Migration |
|---|---|---|
| org model + RBAC (D1 · m103) | `ORG_MODEL_ENABLED` | — |
| audit chain (D3 · m104) | `TENANT_AUDIT_ENABLED` | — |
| hard-erase (D4.4 · m105) · IP allowlist (D2e · m106) | `HARD_ERASE_ENABLED` · `TENANT_IP_ALLOWLIST_ENABLED` | `049` |
| passkeys / WebAuthn (D2c · m107) | `PASSKEYS_ENABLED` | `050` |
| SOC2-lite evidence (D4.1 · m108) · tenant export (D4.3 · m109) | `SOC2_EVIDENCE_ENABLED` · `TENANT_EXPORT_ENABLED` | `051`, `052` |
| enterprise SSO/OIDC (D2a · m110) · SCIM 2.0 (D2b · m111) | `SSO_ENABLED` · `SCIM_ENABLED` | `053`, `054` |
| trust center (D4.6 · m112) | `TRUST_CENTER_ENABLED` | — |
| DB branching (E · m113) · push/messaging (E · m114) | `DB_BRANCHING_ENABLED` · `PUSH_ENABLED` (+ `PUSH_SSRF_ALLOW_HOSTS`) | `055`, `056` |
| CMEK / BYOK envelope (m123) | `CMEK_ENABLED` | `061` |
| dynamic builder (m130–m134) | `BUILDER_ENABLED` | `062` |
| fine-grained ABAC (m135–m139) | `PERMISSION_CONDITIONS_ENABLED`, `API_KEY_ABAC_ENABLED` | `063` |

Other cloud/scale slices, also OFF by default: `QUOTA_STAGE` · `SPEND_CAPS_ENABLED` ·
`ABUSE_GUARD_ENABLED` (m89–m91); `FUNCTIONS_CRON_ENABLED` (m96); `TENANT_TELEMETRY_EXPORT_ENABLED`
(m100); `DATA_PLANE_READ_REPLICA` (m122). SQL migrations
(`mini-baas-infra/scripts/migrations/postgresql/`) now run **040–063**.

## SDKs

The TS SDK is `apps/baas/sdk/` (package `@mini-baas/js`, codegen + `src/{core,domains,generated}`).
Polyglot SDKs: `sdk-python/`, `sdk-kotlin/`, `sdk-swift/`, `sdk-dart/`.

**Gotcha:** `sdk-dart.rootowned-stale/` and `sdk-python.rootowned-stale/` are dead root-owned
duplicates — never edit them; use the un-suffixed dirs.

## Marketing site & going to production

- **`site/`** — the standalone **Grobase marketing site** (`grobase-site`, Astro, container-only via
  `scripts/container-only.mjs`; strict hashed CSP, no inline `style=`/scripts). It is **not** part of
  the BaaS stack. Drive it from the **repo root**: `make grobase-up | grobase-logs | grobase-down |
  grobase-audit` (Lighthouse ×4 + CSP + pa11y) `| grobase-e2e` (Playwright). Targets live in
  `infrastructure/makes/grobase.mk`.
- **`HUMAN-ATOMS.md`** (subtree root) is the authoritative checklist of every human / money /
  external-account action left to reach GA across the three targets (OSS · managed-cloud ·
  enterprise). **`mini-baas-infra/deploy/go-live/go-live.sh`** is a DRY-RUN-default preflight that
  prints READY/MISSING per atom (it never pushes, deploys, or flips a flag). HA notes:
  `mini-baas-infra/deploy/ha/README.md`.

## Binding rules (from the kernel — apply even to one-off tasks)

1. **Never co-author a push.** No `Co-Authored-By` / "Generated with" trailer. *(Overrides the
   default git-trailer behavior for all `apps/baas/` work.)*
2. **Shadow → parity → cutover → delete.** No deletion/cutover unless all three gates PASS:
   m18 live-traffic · shadow parity · CI-green-with-forward. **UNKNOWN = FAIL.**
3. **Measured, not claimed.** Every perf/capacity statement cites an artifact (`mini-baas-infra/artifacts/bench/…`) + the make target that reproduces it.
4. **Least change, reversible first.** Behavior changes are flag-gated OFF by default so the live baseline stays byte-parity.
5. **Read by query, not by slurp.** Logs are JSONL — `tail`/`rg`/`jq`/`awk` or the Explore subagent; never pull a whole log/large file into context. Write logs only via `.claude/lib/log.sh` (or `log.mjs`), never hand-rolled.
6. **Confirm the irreversible** (pushes, deploys, deletions, npm publish, RS256 live cutover) — explicit human trigger.

## The `.claude/` agent OS (read the kernel before substantial work)

`apps/baas/.claude/` is a three-layer agent operating system — **L1 kernel** (`CLAUDE.md` +
`instructions.md` + `objectives/`) governs, **L2 orchestrator** (`agents/orchestrator.md` ⇄
`memory/` `context/` `logs/`) runs the loop, **L3 specialists** (researcher · planner · coder×N ·
tester · reviewer · librarian) are recruited per task. Right-size the pipeline: full fan-out for
substantial/risky work; small tasks may run directly **but still obey the binding rules above**.

- Per-task plans → `.claude/plans/<task>.md`; cross-track board → `.claude/plans/STATUS.md` (keep it timestamped + glanceable). Durable decisions → `.claude/memory/decisions.md`. Reusable recipes → `.claude/workflows/`. Durable product docs → `wiki/`. Don't mix the three.
- For ≥3 **independent** slices, invoke the **`/baas-wave <goal>`** skill (fan out one subagent per disjoint slice → converge on tester + reviewer). Sequence dependency chains instead.

## Roadmap & key docs (`wiki/`)

The roadmap now spans **five tracks** (`wiki/roadmap-to-market.md`): **A** = OSS self-host (shipped),
**B** = managed-cloud (metering→billing→self-serve, m72–m87 — all built + gate-proven), **C** =
scale/HA/SLO (`wiki/scale-slo.md`), **D** = enterprise (org/RBAC, SSO/SCIM, passkeys, audit,
compliance, CMEK — m103–m123), **E** = capability parity (DB branching, push, SDK hardening —
m113–m114). The mission expanded from OSS-only to a **six-bar** product (adds *enterprise-ready* +
*operationally-ready*); see `.claude/CLAUDE.md` §1 and `.claude/plans/managed-cloud-enterprise.md`.

Start points: `wiki/00-overview.md`, `grobase-master-plan.md`, `competitive-matrix.md`,
`competitive-benchmark-report.md`, `nano-vs-pocketbase.md`, `engineering-capability-matrix.md`
(engine×op truth), `service-tiers.md`, `operations-runbook.md`, and the honest-GA posture set
`ga-readiness-scorecard.md` · `sla-draft.md` · `pricing-honesty-audit.md`. Tiers are defined once in
`config/packages/packages.json` (single source of truth — must match measured reality).
