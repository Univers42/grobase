# Security — model, hardening, reporting

How the stack defends itself, and the checklist that makes a deployment
production-grade. Layered design: **if one layer fails, the next still holds.**

---

## 1. The layers

| Layer | Mechanism | Where |
|---|---|---|
| **Perimeter** | nginx + ModSecurity + OWASP CRS WAF filters before anything else | `waf` service |
| **Gateway** | Kong (DB-less, config in Git): key-auth, JWT validation (HS256, algorithm pinned), per-route rate limits, CORS, `X-Request-ID`, security headers (HSTS 2y, X-Frame-Options DENY) | `docker/services/kong/conf/kong.yml` |
| **Identity** | GoTrue issues JWTs; refresh tokens live in `HttpOnly; Secure; SameSite=Lax` cookies at the app gateway; WebAuthn/passkeys supported | `gotrue` |
| **Service trust** | Internal calls carry `INTERNAL_SERVICE_TOKEN`; the Go control plane **refuses to boot** on an empty/known-weak token | `go/control-plane/internal/shared/config.go` |
| **API keys** | 160-bit random keys, stored as salted SHA-256 (HMAC-peppered with `KEY_HASH_PEPPER`); legacy Argon2id hashes verify and lazy-upgrade | `go/control-plane/internal/tenants/keys.go` |
| **Data** | Postgres **RLS** (`auth.uid() = owner_id`) has the last word; every engine adapter stamps owner/tenant scope per request (proven cross-engine by gate m46); parameterized queries everywhere | migrations + Rust data plane |
| **At rest** | Tenant-supplied DB credentials encrypted **AES-256-GCM** (scrypt KDF) | adapter-registry (Go) |
| **Secrets** | Generated `.env` (chmod 600, gitignored); optional HashiCorp Vault profile; `make check-secrets` scans for leaks | `scripts/generate-env.sh` |

## 2. Production checklist

Set these before exposing a deployment (see [DEPLOYMENT.md](DEPLOYMENT.md) for context):

- [ ] **`ADAPTER_REGISTRY_SERVICE_TOKEN`** set to a strong random value — `make env`
      generates one; the literal dev fallback is boot-refused by the Go plane.
- [ ] **`KEY_HASH_PEPPER`** set (32+ hex) — HMAC pepper for API-key hashes; a DB
      dump alone can then never validate keys.
- [ ] **`SECURITY_MODE=max`** — external database mounts must present a verifiable
      TLS chain (`sslmode=require` is auto-upgraded to `verify-full`); custom CA
      via `DATA_PLANE_TLS_CA_FILE`. This also neutralizes the dev escape
      `DATA_PLANE_TLS_INSECURE` (default 1 so the bundled self-signed mssql
      works out of the box; ignored under max — remote mounts always verify).
- [ ] **`PACKAGE_ENFORCEMENT=1`** — tier engine-allowlists, capability masks and
      rate limits are enforced (default 0 to avoid retroactively gating existing
      tenants; assign plans first).
- [ ] **Apply `docker-compose.prod.yml`** — strips direct DB ports (postgres,
      mongo, redis, gotrue, postgrest, studio) and adds restart policies/limits.
- [ ] **Replace MinIO defaults** (`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`) —
      `make env` generates a random password; never ship `minioadmin`.
- [ ] **Rotate on schedule**: `make secrets-rotate GROUP=jwt` (JWT family),
      `make vault-rotate GROUP=…` when running the Vault profile.
- [ ] **TLS at the edge**: terminate HTTPS in front of the WAF (your LB or a
      reverse proxy). The in-stack hop is HTTP on an isolated Docker network.
- [ ] **Backups proven**: run `make verify-m47` once (dump→restore round-trip),
      then enable the `backups` profile.

## 3. JWT specifics

- Default HS256, secret injected at Kong start via placeholder substitution
  (never in the YAML), algorithm pinned (no `none`/algorithm swaps).
- RS256/JWKS is verify-side ready in the Go plane (`JWT_ALG=RS256` + `JWKS_URL`)
  for deployments fronted by an external IdP.
- JWT exp: 1 h (`GOTRUE_JWT_EXP=3600`); refresh via cookie flow.

## 4. What the test suite enforces

`make verify-all` runs 46+ milestone gates; the security-relevant ones:
isolation (m4/m46 cross-tenant, cross-engine), auth fail-closed (m37: bogus key
401, missing key 401), capability masks (m25/m26: 0 violations), packages parity
(m28), footprint budgets (m32). CI additionally runs Semgrep SAST, dependency
audit (npm/pnpm), and Trivy filesystem scans on every PR.

## 5. Reporting a vulnerability

Open a **private GitHub Security Advisory** on the repository (Security →
Advisories → Report a vulnerability). Please do not file public issues for
exploitable bugs. You'll get an acknowledgement within 72 h.
