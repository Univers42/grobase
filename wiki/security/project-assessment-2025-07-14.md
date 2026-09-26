# Grobase — Master Technical Assessment & Roadmap to Professional
**Date:** 2025-07-14 | **Author:** Security & architecture audit (Bob)

> This document captures everything discovered across the full security audit,
> architecture review, and codebase analysis. It is the single source of truth for
> "what needs to happen to make this production-professional." Reference it before
> starting any major work sprint.

---

## 1. What this project actually is (honest summary)

Grobase is a **self-hostable Backend-as-a-Service** — a Supabase/Firebase competitor
designed for self-hosting, with a managed-cloud tier and an enterprise tier on top of
the same codebase. The product thesis: *one backend, any frontend, no per-project
server code*. Apps are declarative provisioning contracts (`infra/config/contracts/`),
not custom code baked into the server.

**Three-language plane architecture:**

| Plane | Language | Path | Job |
|-------|----------|------|-----|
| Application | TypeScript / NestJS | `src/apps/` + `src/libs/` | REST API surface, query routing, auth middleware |
| Control | Go 1.25 | `src/control-plane/` | Tenant identity, API key lifecycle, billing, RBAC |
| Data | Rust | `src/data-plane-router/` | Query execution, owner-scoping per request, 8 engine adapters |
| Realtime | Rust (vendored) | `infra/docker/services/realtime/` | WebSocket event bus, IRC bridge |

**8 database engine adapters:** Postgres, MySQL, MongoDB, MSSQL, SQLite, Redis, HTTP,
DynamoDB (opt-in).

**Live on:** fly.io as `grobase-stack` (Docker-in-Docker compose deploy).  
**Proven by:** 11 vendor apps re-platformed onto it (`vendor/`).  
**160 numbered verify gates** (`scripts/verify/m*.sh`).

---

## 2. Genuine strengths — don't touch these

- **Per-request owner-scoping** (not per-pool): what makes 10K-tenant-on-one-pool
  credible. Never add pool-level tenant context.
- **Flag-gating discipline**: every cloud/enterprise feature starts from byte-parity
  with OSS. Cloud is sold as hosting, not licensed features. This is the correct moat.
- **Argon2id + `subtle.ConstantTimeCompare` throughout**: key handling is done right.
- **Parameterized queries in the Rust data plane**: `quote_ident()`, parameter sinks,
  `mysql_literal()` — injection is structurally blocked, not just defended.
- **The verify-gate system**: 160 executable "done" criteria. Most projects have none.
- **The ASVS control map** (`wiki/security/security-audit-asvs.md`): self-honest
  `[v]`/`[~]`/`[x]` status. Don't let this drift.
- **SSRF in automations is properly fixed**: DNS-pinned fetch (post this audit).
- **The minimalism ladder** (`.claude/rules/minimalism-ladder.md`): enforced.

---

## 3. The structural problems (things that will bite in production)

### 3.1 Dev-defaults-as-baseline is the #1 systemic risk

Almost every dangerous setting is dev-permissive and documented as "production MUST
override". Comments are not enforcement. The current posture:

| Setting | Dev value | Required prod value | Gap |
|---------|-----------|---------------------|-----|
| `TENANT_HEADER_IDENTITY_HMAC` | OFF | ON | Tenant spoofing possible |
| `GOTRUE_MAILER_AUTOCONFIRM` | true | false | No email verification |
| `IDENTITY_HEADER_MODE` | compat | strict | Unsigned headers trusted |
| `REALTIME_NAMESPACE_FALLBACK` | permissive | deny | Wildcard token = all channels |
| `SECURITY_MODE` | baseline | max | NoAuth provider available |
| `SMTP_SECURE` | false | true | Plaintext email credentials |
| `API_KEY_ABAC_ENABLED` | off | on | Admin scope bypasses ABAC |
| `DATA_PLANE_RATELIMIT_BACKEND` | memory | redis | Per-replica rate limit bypass |

**Status (re-checked 2026-09-26 against `docker-compose.prod.yml`):** two of the
eight are set there: `GOTRUE_MAILER_AUTOCONFIRM=false` and `IDENTITY_HEADER_MODE=strict`
on the 11 services that read it (gate m195). The other six are deliberately not set,
each for a stated reason in the overlay's header or the tracker:
`TENANT_HEADER_IDENTITY_HMAC` (no signer exists, it would 401 legitimate traffic),
`REALTIME_NAMESPACE_FALLBACK=deny` (GoTrue tokens carry no `namespaces` claim, so it
closes every topic to browsers), `SECURITY_MODE`, `SMTP_SECURE` (depends on the SMTP
provider), `API_KEY_ABAC_ENABLED` (H-5, an owner decision) and
`DATA_PLANE_RATELIMIT_BACKEND=redis` (needed only with more than one data-plane replica;
commented in the overlay).

**The startup validator exists:** `make prod-up` runs
`scripts/ops/preflight-production.sh`, which refuses dev credentials and dev security
values (gate m194). It does not yet cover all six settings above.

### 3.2 The TS→Rust migration is in-flight

Two execution paths exist simultaneously for the most critical part of the stack:

- `RUST_DATA_PLANE_FORWARD=1` (TS-side feature flag, default OFF)
- `DATA_PLANE_ROUTER_PRODUCT_MODE` (Rust-side, default `shadow`)

Both halves must be tested independently. The legacy TS engine code is still
load-bearing. This is intentional (shadow→parity→cutover→delete) but it means:
- Any security fix to query execution may need to be applied in BOTH planes
- The cutover gates (m18, shadow-parity, CI-green-with-forward) must all pass before
  the TS path is removed
- **Never delete legacy TS engine code until all three gates pass. UNKNOWN = FAIL.**

### 3.3 Maintenance surface is very large for the team size

| Area | Size |
|------|------|
| Verify gates | 160 scripts |
| DB migrations | 85 PostgreSQL + MongoDB + MySQL |
| Engine adapters | 8 (each with its own query/filter/schema/tx paths) |
| SDK languages | 5 (JS, Python, Kotlin, Swift, Dart) |
| Vendor apps | 11 re-platformed apps |
| `.claude/agents` | 8 specialists |
| `.claude/rules` | 13 always-on rules |

The `vendor/AppFlowy` checkout (~2880 tracked files) adds ~2880 files to the tree
with zero BaaS wiring. It should be removed or moved to a submodule.

### 3.4 Missing production-enforcement tooling

The following exist as comments/documentation but not as runnable checks:
- No `make preflight-production` that validates security-critical env vars
- No startup assertion that `POSTGRES_PASSWORD != 'postgres'`
- No CI check that `__KONG_CORS_ORIGIN__` placeholders were substituted
- No enforcement that `docker-compose.prod.yml` is used in production deploys
- No `make sonar-scan` in the main CI path (only in a separate workflow)

---

## 4. Full security audit status

Two audits have been run:

| Audit | Date | Findings | Status |
|-------|------|----------|--------|
| Internal audit (prior session) | 2026-06-11 | 6 HIGH, 5 MED fixed | All fixed + verified |
| Full static audit (this session) | 2025-07-14 | 61 findings (7 CRITICAL, 22 HIGH, 18 MED, 14 LOW) | 18 fixed in code, 1 needs human (PAT rotation), 42 tracked |

**Security docs:**
- [`wiki/security/vulnerability-report-2025-07-14.md`](vulnerability-report-2025-07-14.md) — all 61 findings with evidence
- [`wiki/security/remediation-tracker-2025-07-14.md`](remediation-tracker-2025-07-14.md) — fix status per finding
- [`wiki/security/security-audit.md`](security-audit.md) — prior session fixes
- [`wiki/security/security-audit-asvs.md`](security-audit-asvs.md) — OWASP ASVS / SOC2-lite control map

**Open gaps from ASVS map** (status 2026-09-26; details in [`security-audit-asvs.md`](security-audit-asvs.md) §3):
- `G-Vault`: done in code — `max` refuses inline DSNs and resolves Vault refs (m121); other tiers encrypt inline DSNs at rest by design
- `G-Net`: done for compose — engines and vault off the app bridge, default in `make prod-up` (m66)
- `G-RS256`: GoTrue still signs HS256; RS256 cutover deferred (coordinated with GoTrue) — **open, human**
- `G-Rotate`: service-token rotation done (m205); `JWT_SECRET` rotation open

**The single most dangerous unfixed item:**  
The GitHub PAT `ghp_[REDACTED-revoked]` that was in `.env.local` is live
until manually rotated at https://github.com/settings/tokens (C-1). As of 2026-09-25 the value is
no longer on the dev machine or in git history; only the issuer-side revocation is left.

---

## 5. Tracked work — prioritized backlog

> **Status 2026-09-26.** Each item below carries its outcome. `[x]` = fixed or shown not to be a
> hole, `[~]` = partly done, `[ ]` = still open (all of them need the owner). The per-finding
> evidence is in the [tracker](remediation-tracker-2025-07-14.md).

### P0 — Before any production traffic (most already fixed, one human action needed)

- [ ] **HUMAN: Rotate GitHub PAT** at https://github.com/settings/tokens — still open (C-1)
- [~] Verify migration `065` ran on prod/staging/CI (`pg_policies` check) — recorded in `public.schema_migrations` on the dev stack (2026-09-26, with 088/089); m203 checks every migration records its version. Any other environment: operator
- [x] ~~Verify `docker-compose.prod.yml` is being used in the fly.io deploy~~ — fly is retired; `make prod-up` layers the prod overlay after the preflight (m194, m195)

### P1 — This sprint (code changes needed)

**Security:**
- [ ] H-5: Enable `API_KEY_ABAC_ENABLED=1` by default in prod overlay — open, a product decision; the admin short-circuit is now logged (H-5a)
- [x] H-7: Add Kong rate-limiting plugin to `POST /v1/keys/verify` — not needed: verify requires the service token (see [tracker](remediation-tracker-2025-07-14.md))
- [x] H-11: Add SHA256 checksum verification to `infra/docker/services/supavisor/Dockerfile` — `660a3233`
- [x] H-13: Add delegation depth limit in `src/control-plane/internal/tenants/selfserve_keys.go` — a key can no longer revoke a wider one, `7c8af1c5` (m83)
- [x] H-15: Kong CORS pre-flight check in entrypoint — `abeeea71` (m195)
- [x] H-20: Re-enable ShellCheck SC2086; fix root causes — CI quoting step over 58 scripts

**Code quality:**
- [x] M-2: Tighten API key payload — not needed: the hash comparison is length-independent (see [tracker](remediation-tracker-2025-07-14.md))
- [x] M-3: Add JWT `iat` claim validation in `api-key.middleware.ts:198` — `e215b475` (TS + Go)
- [x] M-4: Require `GOTRUE_JWT_ISSUER` to be set; add startup check — realtime issuer check (m201), tenant-control refuses an empty issuer
- [x] M-13: Raise `GOTRUE_PASSWORD_MIN_LENGTH=12` in prod overlay — m195 asserts 12

**Infrastructure:**
- [x] `make preflight-production` script — `scripts/ops/preflight-production.sh`, run by `make prod-up` (m194)
- [x] Startup validator: refuse to start if `POSTGRES_PASSWORD == 'postgres'` — the preflight refuses dev credentials (m194)
- [ ] Remove `AppFlowy` from tracked files or convert to proper submodule — open, owner decision

### P2 — This month

**CI/CD hardening:**
- [x] H-8/H-9: Migrate CI to OIDC — H-8 not needed (`GITHUB_TOKEN` is per-job and masked); H-9 least privilege `56ed5e9d`
- [x] L-8: Add `::add-mask::` for dynamically-generated tokens in CI — already masked
- [ ] L-11: Require signed commits on `main` branch (GitHub repo settings) — open, repository setting
- [x] L-14: `chmod 600` on `.env.secrets` in all CI steps — already everywhere

**Multi-tenant hardening:**
- [x] H-14: Redis-backed nonce replay cache for multi-pod deployments — `IDENTITY_NONCE_STORE=redis`
- [x] M-6: Property-based fuzz tests for `assertNoMongoOperators()` — `collections.filter.property.spec.ts`
- [x] M-15: `DATA_PLANE_RATELIMIT_BACKEND=redis` in prod overlay — not needed while production runs one replica

**Storage:**
- [x] M-17: Add `X-Content-Type-Options: nosniff` to all storage responses — `f89a354a`, `8eae9aeb`
- [x] L-6: Log when Sharp encounters errors — pixel limit + 422, `280b8b25`
- [x] L-7: Document + deny-list validation for `PUSH_SSRF_ALLOW_HOSTS` — not needed: applies to push only (see [tracker](remediation-tracker-2025-07-14.md))

### P3 — Architecture (before enterprise / SOC2 milestone)

- [x] `G-Net`: Per-plane Docker network segmentation — default in `make prod-up` (m66); Helm policies need a cluster
- [x] `G-Vault`: Enforce Vault for all DSNs under `SECURITY_MODE=max` — m121 (nightly)
- [ ] `G-RS256`: GoTrue RS256 cutover (coordinated) — open, human; m81 proves the target setup
- [~] `G-Rotate`: Per-deployment key rotation primitive + rotation runbook — service tokens done (m205 + runbook); `JWT_SECRET` open
- [x] H-2/H-3: Control/data-plane internal bind — not needed: container-internal binds
- [x] H-6: Audit logging for service token current/previous usage — `RotationNotice` + `baas_service_token_previous_accepted_total`
- [x] H-13: Key delegation depth limit + audit trail — H-13 + M-11 (`3db64f09`)

---

## 6. What makes this NOT yet production-professional (gap list)

These are the things that separate a proof-of-concept from a product that can survive
real multi-tenant traffic and pass a security review:

### 6.1 No production-safe defaults
The entire security posture relies on an operator knowing to use
`docker-compose.prod.yml`. A single compose file should be safe by default;
development should be the explicit opt-in (`docker-compose.dev.yml`).

**Fix:** Invert the defaults. Make the base compose production-safe. Create
`docker-compose.dev.yml` that enables dev conveniences.

**Status 2026-09-26:** open, an owner decision. Today `make prod-up` is the safe entry: it runs the
preflight (m194) and layers the prod and netseg overlays (m195, m66).

### 6.2 No `make preflight-production`
No automated check that the environment is correctly configured before bringing up
the stack in production. This is the highest-ROI thing not yet built.

**Fix:** `scripts/ops/preflight-production.sh` — exits 1 with a clear message for
each missing or insecure value. Wire into `make cloud-up` and the fly.io boot script.

**Status 2026-09-26:** done — `scripts/ops/preflight-production.sh`: `make prod-up` refuses on it, `make cloud-up`
warns (`PREFLIGHT_ENFORCE=1` refuses) — m194.

### 6.3 No observability on security events
Revoked keys, failed auth, rate-limit hits, ABAC denials, and tenant isolation
violations all happen silently (logs only, no alerting, no dashboards).

**Fix:** Structured logging with `event_type` field for all security events. Loki
query for `event_type="auth_failure"` rate. Grafana alert on spike.

**Status 2026-09-26:** done for rejected credentials — `event_type=auth_failure` log lines, Kong and
query-router 401 counters, `platform-security` alerts and a Loki label, proven end to end by m204.

### 6.4 The `./vendor/AppFlowy` bloat (~2880 files)
~2880 tracked files with zero BaaS wiring bloating the repo, polluting `git log`,
slowing clone times, and confusing `grep` results.

**Fix:** Remove from tracked files. Either delete it or add it as a proper git
submodule with `--depth 1`. Update `CLAUDE.md`.

### 6.5`CLAUDE.md`.

**Status 2026-09-26:** open, an owner decision.

### 6.5 CI is not the truth source for quality
SonarCloud scan is a separate make target, not in the main CI path. The security
workflow (`.github/workflows/mini-baas-security.yml`) is separate from the main CI.

**Fix:** All quality gates (lint + typecheck + test + sonar + trivy + audit-deps)
must be in the main `ci.yml` and block merge.

**Status 2026-09-26:** partly done — the security workflow's `security-gate` is blocking and
runs gitleaks, trufflehog, semgrep, trivy, cargo-audit, govulncheck and ZAP. SonarCloud still
needs a `SONAR_TOKEN` (owner).

### 6.6 No load test baseline
The 10K-tenant claim exists as a gate (`m46`) but there is no continuous load test
in CI that would catch a regression.

**Fix:** Add a `bench-capacity` job to CI that runs on `main` push and fails if
median RPS drops below the m46 baseline. Cite the artifact.

**Status 2026-09-26:** done differently — the nightly `load-baseline` job runs m38 (k6 CRUD mix
through Kong) against `scripts/bench/budgets.json` and is fatal on a regression. Measured locally:
20.02 rps, p95 5.43 ms, 0 % errors (`artifacts/bench/load-essential-crud.json`). Its first CI
result is unknown (no GitHub API access).

### 6.7 Documentation debt in `CLAUDE.md`
`CLAUDE.md` is 600+ lines and covers state that has since changed
(monorepo references, AppFlowy, vendor/twenty, stale paths). It's the first thing
any agent reads.

**Fix:** Trim `CLAUDE.md` to ~200 lines covering only current state. Move historical
context to `wiki/archive/`. Keep the binding rules section intact.

**Status 2026-09-26:** open, an owner decision.

---

## 7. The right sequence to get to production-professional

```
Week 1:  Rotate PAT → preflight-production script → invert defaults (prod=safe)
Week 2:  CI consolidation → OIDC migration → signed commits
Week 3:  ABAC default ON → key delegation limit → Kong rate-limit on /v1/keys/verify
Week 4:  Observability on security events → load test baseline in CI
Month 2: G-Net (network segmentation) → G-Vault (DSN enforcement) → CLAUDE.md trim
Month 3: G-RS256 cutover → SOC2 audit-ready posture review → formal pentest
```

---

## 8. Reference map

| Topic | Document |
|-------|----------|
| Full vulnerability report (61 findings) | `wiki/security/vulnerability-report-2025-07-14.md` |
| Fix status per finding | `wiki/security/remediation-tracker-2025-07-14.md` |
| Prior session fixes (6 HIGH) | `wiki/security/security-audit.md` |
| OWASP ASVS / SOC2-lite control map | `wiki/security/security-audit-asvs.md` |
| Product roadmap | `wiki/product-plan/01-overview-and-sequencing.md` |
| Architecture | `wiki/architecture/` |
| Go-to-market / GA checklist | `HUMAN-ATOMS.md` |
| Service boundaries (binding rule) | `.claude/rules/service-boundaries.md` |
| Minimalism ladder (coding rule) | `.claude/rules/minimalism-ladder.md` |
| Agent config | `.claude/AGENTS.md` |
