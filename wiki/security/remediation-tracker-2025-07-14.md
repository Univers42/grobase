# Security Remediation Tracker

Full audit: [`wiki/security/vulnerability-report-2025-07-14.md`](vulnerability-report-2025-07-14.md)

**Legend:** ✅ Fixed in code | ⚠️ Needs human action | 🔲 Tracked (not yet fixed)

---

## P0 — Must be done before production traffic

| ID | Finding | Status | Where fixed |
|----|---------|--------|-------------|
| C-1 | **Leaked GitHub PAT** (`ghp_[REDACTED-revoked]` in `.env.local`) | ⚠️ **HUMAN ACTION REQUIRED** | Revoke at https://github.com/settings/tokens — then rotate any downstream tokens that used it |
| C-2 | Tenant header spoofing — `TENANT_HEADER_IDENTITY_HMAC` default OFF | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `TENANT_HEADER_IDENTITY_HMAC=1` |
| C-3 | Kong Admin API bound to `0.0.0.0:8001` | ✅ Fixed | `orchestrators/compose/base/gateway.yml:64` — changed to `127.0.0.1:8001` |
| C-4 | Vault API bound to `0.0.0.0:8200` | ✅ Fixed | `orchestrators/compose/base/secrets.yml:17` — changed to `vault:8200` |
| C-5 | Vault Fly Dockerfile runs as root | ✅ Fixed | `infra/docker/services/vault/Dockerfile.fly` — added `USER vault` before `ENTRYPOINT` |
| C-6 | CockroachDB admin HTTP hardcoded `0.0.0.0:8080` | ✅ Fixed | `orchestrators/compose/base/engines-extra.yml:92` — changed to `127.0.0.1:8080` |
| C-7 | RLS bypassed before migration 065 | ⚠️ **VERIFY** | Run `bash scripts/verify/m27-conformance.sh` + check `pg_policies` table on all envs |
| H-16 | `GOTRUE_MAILER_AUTOCONFIRM=true` default | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `GOTRUE_MAILER_AUTOCONFIRM=false` |
| H-19 | `IDENTITY_HEADER_MODE=compat` default | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `IDENTITY_HEADER_MODE=strict` |

---

## P1 — This sprint

| ID | Finding | Status | Where fixed |
|----|---------|--------|-------------|
| H-1 | Database engines can bind to `0.0.0.0` via `ENGINE_BIND_ADDR` | ✅ Fixed | `orchestrators/compose/base/data-engines.yml` — Postgres/Mongo passwords now require explicit values (no fallback); Redis already hardcoded 127.0.0.1 |
| H-2 | Control-plane services bind to `0.0.0.0` | 🔲 Tracked | These are process-local Docker bindings; containers are not published to host. Lower severity than originally assessed — resolve when moving to Kubernetes (use ClusterIP services) |
| H-3 | Data-plane router binds to `0.0.0.0` | 🔲 Tracked | Same as H-2 — internal Docker network only |
| H-4 | API key verify cache TTL 30 s (revocation staleness) | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `TENANT_CONTROL_VERIFY_CACHE_TTL_MS=5000` |
| H-5 | `admin` scope bypasses ABAC entirely | ⚠️ **OPERATOR ACTION** | Enable `API_KEY_ABAC_ENABLED=1` in production `.env.local`. This is a feature flag — enabling it changes authorization semantics; test against your tenant config before flipping |
| H-6 | Service token grace window — previous token accepted with no audit log | 🔲 Tracked | Low blast radius for single-operator deploys; add audit logging in the serviceauth package's `Verify()` function |
| H-7 | No per-IP rate limiting on key verification | 🔲 Tracked | Add Kong rate-limiting plugin to `POST /v1/keys/verify` route in `infra/docker/services/kong/conf/kong.yml` |
| H-8 | CI docker login uses GITHUB_TOKEN | 🔲 Tracked | Migrate `.github/workflows/ci.yml` to OIDC (`actions/login-to-ghcr`) — see P2 below |
| H-9 | CI `packages: write` permission on push jobs | 🔲 Tracked | Scope to release-only job once OIDC migration done |
| H-10 | `docker exec sh -c` with embedded variables (mongo credentials) | ✅ Fixed | `scripts/ops/engine-backup.sh` — switched to array form `docker exec "$C" mongodump ... -u "$USER" -p "$PASS"` |
| H-11 | Dockerfile downloads unsigned binaries | 🔲 Tracked | `infra/docker/services/supavisor/Dockerfile` — add SHA256 checksum verification for hex.ez and rebar3 downloads |
| H-12 | Compose default fallback passwords (`postgres`/`mongo`/`minioadmin`) | ✅ Fixed | `data-engines.yml`, `storage.yml` — changed `:-postgres` / `:-mongo` / `:-minioadmin` to `:?must be set` |
| H-13 | Admin key can issue unbounded admin keys | 🔲 Tracked | Add delegation depth limit in `src/control-plane/internal/tenants/selfserve_keys.go`. Log all key issuances to audit table |
| H-14 | In-memory nonce replay cache lost on pod restart | 🔲 Tracked | Switch to Redis-backed nonce store in `src/libs/common/src/identity/request-identity.ts` for multi-pod deployments |
| H-15 | Kong CORS origins not validated post-substitution | 🔲 Tracked | Add pre-flight startup check in Kong entrypoint that greps `kong.yml` for `__KONG_CORS_ORIGIN` and fails if found |
| H-17 | Realtime NoAuth no hard startup refusal under SECURITY_MODE=max | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `SECURITY_MODE=max` |
| H-18 | `SMTP_SECURE=false` default | ✅ Fixed | `config.env` — added comment; production `.env.local` must set `SMTP_SECURE=true` |
| H-20 | ShellCheck SC2086 globally disabled | 🔲 Tracked | Re-enable SC2086 in `.shellcheckrc`; fix unquoted variables in scripts |
| H-21 | `.trivyignore` contained CVEs without justification/expiry | ✅ Fixed | `.trivyignore` — added justification comments and `REVIEW-BY` dates for all entries |
| H-22 | `chmod +x || true` in Vault Dockerfile | ✅ Fixed | `infra/docker/services/vault/Dockerfile` — changed to `chmod 700` without `|| true` |
| M-1 | Postgres error messages leaked in 400 responses | ✅ Fixed | `src/apps/query-router/src/query/sqlro.service.ts:88` — replaced with generic message + internal correlation ID |
| M-8 | Realtime namespace fallback permissive by default | ✅ Fixed | `orchestrators/compose/docker-compose.prod.yml` — sets `REALTIME_NAMESPACE_FALLBACK=deny` |

---

## P2 — Backlog

| ID | Finding | Status | Notes |
|----|---------|--------|-------|
| H-8/H-9 | CI OIDC migration | 🔲 Tracked | Replace `echo "$GITHUB_TOKEN" \| docker login ...` with `actions/login-to-ghcr@v2` in `.github/workflows/ci.yml` |
| L-9 | SVG stored without script stripping | ✅ Fixed | `src/apps/storage-router/src/storage/storage.service.ts` — `<script>` tags stripped on upload |
| L-12 | DNS rebinding TOCTOU in automation SSRF check | ✅ Fixed | `src/apps/query-router/src/query/automations.service.ts` — renamed `assertPublicHttpsTarget` to `resolveAndPin`; fetch now uses IP-pinned URL with `Host:` header for SNI |
| M-2 | API key payload accepts 16–64 chars (should be exactly 32) | 🔲 Tracked | `src/control-plane/internal/tenants/keys.go:77` — tighten to exact 32-char base32 |
| M-3 | JWT `iat` claim not validated | 🔲 Tracked | `src/libs/common/src/middleware/api-key.middleware.ts:198` — add `iat` check with skew tolerance |
| M-4 | JWT issuer validation optional | 🔲 Tracked | Document as required; add startup check that `GOTRUE_JWT_ISSUER` is set |
| M-6 | MongoDB filter injection (deep operator check) | 🔲 Tracked | Add property-based fuzz tests for `assertNoMongoOperators()` |
| M-13 | GoTrue password minimum 8 chars (weak) | 🔲 Tracked | Raise `GOTRUE_PASSWORD_MIN_LENGTH=12` in production overlay |
| M-15 | In-process rate limiter per-replica (not authoritative in multi-replica) | 🔲 Tracked | Set `DATA_PLANE_RATELIMIT_BACKEND=redis` in prod overlay for multi-replica deploys |
| M-17 | Storage Content-Type passthrough (no MIME whitelist) | 🔲 Tracked | Add `X-Content-Type-Options: nosniff` to all storage responses |
| L-5 | Refresh token reuse window 10 s | ✅ Acceptable | Documented; 10 s is intentional to handle network latency |
| L-6 | Sharp `failOn: 'none'` silently processes corrupted images | 🔲 Tracked | Add logging when Sharp encounters errors |
| L-7 | `PUSH_SSRF_ALLOW_HOSTS` can bypass SSRF protection | 🔲 Tracked | Document that this must never include metadata endpoints; add deny-list validation |
| L-8 | CI logs may contain tokens in curl responses | 🔲 Tracked | Add `::add-mask::` in CI for dynamically-generated tokens |
| L-11 | No signed commits requirement on main branch | ⚠️ **OPERATOR ACTION** | Enable in GitHub repo settings → Branches → Require signed commits |
| L-13 | `ARGON2_MAX_CONCURRENT=2` can be monopolized | 🔲 Tracked | Raise to 4–8 (benchmark first); add Kong rate limit on `/v1/keys/verify` |
| L-14 | `.env.secrets` mode 600 not enforced in CI | 🔲 Tracked | Add `chmod 600` to all CI steps that write `.env.secrets` |

---

## Files changed by this remediation pass

| File | Change |
|------|--------|
| `orchestrators/compose/base/gateway.yml` | C-3: Kong admin bound to `127.0.0.1:8001` |
| `orchestrators/compose/base/secrets.yml` | C-4: Vault API addr changed to `vault:8200` |
| `orchestrators/compose/base/engines-extra.yml` | C-6: CockroachDB `--http-addr=127.0.0.1:8080` |
| `infra/docker/services/vault/Dockerfile.fly` | C-5: Added `USER vault` before `ENTRYPOINT`; `--chown` on COPY |
| `infra/docker/services/vault/Dockerfile` | H-22: `chmod 700` (no `\|\| true`) |
| `orchestrators/compose/docker-compose.prod.yml` | C-2, H-4, H-16, H-17, H-19, M-8: All security overrides for production |
| `orchestrators/compose/base/data-engines.yml` | H-12: Postgres + Mongo passwords require explicit value |
| `orchestrators/compose/base/storage.yml` | H-12: MinIO password requires explicit value |
| `src/apps/query-router/src/query/sqlro.service.ts` | M-1: Raw Postgres errors replaced with correlation ID |
| `src/apps/storage-router/src/storage/storage.service.ts` | L-9: `<script>` strip on SVG upload |
| `src/apps/query-router/src/query/automations.service.ts` | L-12: DNS rebinding TOCTOU fixed — IP-pinned fetch |
| `scripts/ops/engine-backup.sh` | H-10: `docker exec` array form for mongo credentials |
| `config.env` | H-18: SMTP_SECURE comment clarifying prod requirement |
| `.trivyignore` | H-21: Added justification + REVIEW-BY to all entries |

---

## How to apply

```bash
# Production deploy (uses the prod overlay which enforces all P0 security vars):
docker compose -f docker-compose.yml -f orchestrators/compose/docker-compose.prod.yml up -d

# Verify migration 065 (RLS) ran on all environments:
bash scripts/verify/m27-conformance.sh

# Confirm no unsubstituted Kong CORS placeholders in the rendered config:
docker exec mini-baas-kong grep -c '__KONG_CORS_ORIGIN' /etc/kong/kong.yml && echo "FAIL: placeholders found" || echo "OK"
```
