# Security Remediation Tracker

Full audit: [`vulnerability-report-2025-07-14.md`](vulnerability-report-2025-07-14.md) (61 findings).

**Re-verified 2026-09-24 against the code, not the report.** The previous version of this file
marked ~20 findings "✅ Fixed", but those edits had been reverted (the diff was parked as
`.bob/security-diff-reverted.patch`, since deleted) and several of them were regressions: they
broke the Prometheus→Kong scrape, the Vault init container, the Fly Vault boot, engine backups
(m188) and webhook TLS. Every row below was checked in the code; every ✅ names the commit and
the test or gate that goes red without the fix. Work lands on `develop` (git-flow, one branch
per problem).

**Legend** — ✅ fixed and proven · 🟡 needs a human / product decision · 📌 open, tracked ·
⚪ false positive or already mitigated (evidence given) · ➖ accepted by design.

## Needs a human (do these first)

| # | What | Why it cannot be done in code |
|---|---|---|
| **N-2** | **Revoke the Unsplash access key** committed in `daa68cf93b` (`vendor/vite-gourmand/Back/scripts/update-menu-images.ts:18`, since removed from the tree). trufflehog verified it **live** on 2026-09-24. | It stays in git history; only revoking it at Unsplash makes it harmless. The `trufflehog` job of the Security workflow is red until then. |
| **C-1** | Revoke the leaked GitHub PAT, then rotate anything that used it. | Issuer-side action. `fix/pat-out-of-env` (m-series, on main) stops `make env` from carrying GitHub tokens into `.env`. |
| **L-11** | Require signed commits on `main` (GitHub → Branches). | Repository setting. |
| **Vault base image** | `infra/docker/services/vault/Dockerfile` is `vault:1.21` (last 1.21 tag), `Dockerfile.fly` is `vault:1.16`; both carry fixable HIGH/CRITICAL CVEs (see `.trivyignore` note). Fix = Vault 2.x. | Major upgrade that ships to deployments (storage format, unseal) — needs a planned rollout. |
| **Fly redeploy** | `deploy/fly/boot.sh` changed (H-15: no dev CORS origins on fly; preflight-production now runs at boot, warn-only — `PREFLIGHT_ENFORCE=1` to refuse). | Deploys are human-triggered. |

## Needs a product / architecture decision

| # | Finding | Evidence | Options |
|---|---|---|---|
| **N-3** | **A tenant table created through the DDL API on a mount that points at the platform database is readable with the public anon key via PostgREST.** Proven: a table `m60` created via `POST /query/v1/{db}/schema/ddl` answered `GET /rest/v1/<table>` with its secret row (anon key only). Cause: `001_initial_schema` / `db-bootstrap` `ALTER DEFAULT PRIVILEGES … GRANT … TO anon, authenticated` on `public`, and API-created tables have no RLS. | m200's invariant flags every such table. Contract-provisioned and self-serve apps get their own database (m176/m177), which PostgREST does not see; test tenants (lib-live-tenant) and any operator-made mount on the platform DB do not. | (a) the Postgres DDL path enables RLS on tables it creates in the platform DB; (b) revoke the default privileges and grant explicitly (vendor apps on PostgREST must then grant in their schema.sql); (c) forbid mounts on the platform database. |
| **H-16** | `deploy/fly/boot.sh` sets `GOTRUE_MAILER_AUTOCONFIRM=true` on the live stack: sign-up without owning the address. | `boot.sh:60` | Turning it off changes sign-up UX for the website/vault42 frontends (separate repos, not verifiable here). |
| **H-19** | `IDENTITY_HEADER_MODE=compat` everywhere but fly. | `config.env:37`; the prod overlay deliberately does not set strict: no signer exists for the JWT path, so strict/HMAC would 401 legitimate traffic. | Build the header signer first, then flip. |
| **H-4** | Verify-cache TTLs (Go 60 s, TS 30 s) bound revocation latency. | Go revocation already evicts both local and data-plane caches; the 60 s TTL is the measured fix for the Argon2 verify ceiling. | Lower only with a bench artifact (binding rule 3). |
| **H-5** | An `admin`-scoped API key short-circuits ABAC (`query.service.ts:774`). | By design; m139 asserts `API_KEY_ABAC_ENABLED` defaults off. | Turn the flag on per deployment after testing policies. |

## Fixed and proven

| ID | Finding (as re-verified) | Fix | Proof (red before → green after) |
|---|---|---|---|
| C-2 | `ipguard`/`audit` self-auth compared the raw `X-Baas-Tenant-Id` and ignored `TENANT_HEADER_IDENTITY_HMAC` | `cd55d9a2` | `self_auth_test.go` ×2 (forged header authorized → rejected) |
| C-7 | No proof PostgREST logs in as a role RLS applies to; track-binocle fallback named the superuser | `e88d10c7` | m200 (3): authenticator NOSUPER/NOBYPASSRLS, sessions only authenticator; mutant `BYPASSRLS` → red |
| H-1 | Prod overlay `ports: []` stripped nothing (compose merges lists); minio got `0.0.0.0:9000` | `83c5d83b` | m195 `static_ports` |
| H-11 | supavisor build used unverified hex/rebar3 downloads | `7bc2c04f` | pinned RUN block: real pins build, tampered pin refused |
| H-13 | A write key could revoke the tenant's admin keys | `78c9db31` | m83 step 4e2 (200 → 403), in CI cloud-gates |
| H-15 | Five localhost dev origins had credentialed CORS in production | `3211e86c` | m195 CORS preflight (prod allowed localhost:5180 → refused); phase 13 13/13 |
| H-22 | Vault image built green without executable scripts | `bbf1be51` | build without scripts: exit 0 → exit 1 |
| M-1 | Data-plane 502 bodies echoed backend hosts/URLs | `f75ada7b` | `routes::tests::backend_error_body_hides_internal_detail` |
| M-3 | User JWT without `exp` never expired; future `iat` accepted (TS + Go) | `910727f8` | `api-key.middleware.spec.ts`, `jwt_time_test.go` |
| M-8 | `SECURITY_MODE=max` never denied (compose passed `permissive`) | `82a9ea82` | m195 `static_realtime_mode`; `fallback_tests` |
| M-11 | Key issue/revoke left no trace | `12ccee2b` | m83 step 4e3 (log lines for the key id) |
| M-12 | Bucket policy: presign skipped it; a bucket named `constructor` bypassed a `*` deny | `34af96f1` | `bucket-policy.spec.ts` |
| M-16 | Automation rule names could forge log lines (CR/LF) | `61514472` | `automations.service.spec.ts` |
| M-17/L-9 | Presigned GETs of SVG/HTML rendered on a browsable origin | `5807534a` (+ `a47f906a` proxied path) | `presign-active-content.spec.ts` |
| L-6 | One small image upload + transform OOM-killed storage-router (measured: 151 MP under the 128 MiB limit) | `f3dc5cfc` | `image-transform.spec.ts`; measurements in the commit |
| L-12 | Webhook DNS rebinding | `2463fd66` (IP-pinned connect-time lookup; the reverted IP-rewrite broke TLS) | `automations.pin.spec.ts` |
| C-3 | Kong admin API on the flat network | `e92133b1` (prod: admin off, status listener keeps /metrics) | m195 throwaway Kong |
| C-5 | Vault on fly ran as root | `3368756b` (`VAULT_DROP_PRIVILEGES_ENABLED`) | m196 |

## Found during re-verification (not in the audit)

| ID | Finding | Fix | Proof |
|---|---|---|---|
| N-1 | `public.schema_registry` (cross-tenant table catalog) readable, insertable and deletable with the anon key | `90c122e0`, migration 088 | m200 (invariant + live 401) |
| N-4 | Vault unseal key + root token written `0644`; a lost key file wiped all Vault storage | `03b69632` | m199 |
| N-5 | `h2` 0.3 (RUSTSEC-2026-0258) in the DynamoDB build fly runs | `5047bb02` | `make audit-deps`: FAIL → OK; live dynamodb-local round trip |
| N-6 | 17 fixable HIGH npm advisories (multer, sharp, nodemailer, axios, js-yaml, …) | `d40b2909` | trivy fs 17 → 0; jest 445/445; m55 + phase 9 live |
| N-7 | SAST scanner reported "clean" on a missing report; real semgrep verdict was 1 ERROR | `c628adb8` | semgrep 0 ERROR; missing report → FAIL |
| N-8 | Gates that could not fail: m157 (swallowed render errors), m198 (never booted), m5/m60 (monorepo paths, formatter-mangled key) | `8e74a577`, `132c995e`, `9dba37ec` | each red on a broken input, green on the real one |
| N-9 | No security scanner ran in CI | `9dba37ec` | `.github/workflows/mini-baas-security.yml` + blocking `security-gate`; m5, m60 green |

## Open, tracked

| ID | Finding | Note |
|---|---|---|
| H-6 | A rotated-out service token is accepted with no log line | Low; only when `INTERNAL_SERVICE_TOKEN_PREV` is set. |
| H-14 | Identity nonce replay cache is per process | Matters only with several replicas (compose runs one); needs a shared store. |
| H-20 | ShellCheck SC2086 disabled globally | Info-level under CI's `-S error`; enable per file where input is untrusted. |
| M-4 | Realtime does not check `iss` | `appchannels` tokens carry no `iss`; enforcing it would break m179. Add `iss` to every minter first. tenant-control already checks it. |
| M-5 | `sub` not validated as a UUID | Token minters must be audited first. |
| M-13 / L-5 | GoTrue password length and refresh-reuse window hard-coded in base compose | Prod overlay sets min length 12. |
| — | `postgres/Dockerfile` FDW "checksums" are placeholders written to a manifest | No download uses them; the manifest overstates what is installed. |
| — | `edition-query` offer build was intermittent in CI | Cause found: concurrent Rust builds raced on a `sharing=shared` cargo cache mount ('failed to unpack package'); now `sharing=locked`. |

## False positive, mitigated or by design

C-4 (`VAULT_API_ADDR` is the advertise address) · C-6 (dev-only profile, localhost) · H-2/H-3
(container-internal binds) · H-7 (verify needs the service token; fast hash for new keys) · H-8
(`GITHUB_TOKEN` is per-job and masked; H-9 least privilege done in `a51ffad2`) · H-10 (the original
`sh -c` expands inside the container and is not injectable; the reverted fix broke backups) · H-12
(`:?` in base breaks every render without `.env`; enforced by the preflight, m194, which fly's boot now runs) · H-17 (realtime
already refuses NoAuth under max) · H-18 (`SMTP_SECURE=false` still upgrades via STARTTLS) · H-21
(2026 CVE ids are real) · L-1 (`NODE_ENV=production` in the image) · L-2 (algorithm pinned before
parse) · L-3 (`|| true` on `vault status` is required) · L-7 (applies to push, not automations) ·
L-8 (masked) · L-13 (fast hash + upgrade) · L-14 (`chmod 600` everywhere) · M-2 (hash comparison
is length-independent) · M-6 (deep operator check exists and is tested) · M-7 (session service
retired) · M-14/M-15 (single replica; Kong limits) · M-18 (mailpit is dev) · L-5 (accepted).

## Where CI proves it

- **CI** (`ci.yml`, push to main and develop): unit suites incl. functions-runtime Deno; security
  gates m195 m196 m198 m199; integration runs m157 m197 m200 plus the live test phases; cloud
  gates incl. m83; m194 in the lint job.
- **Security** (`mini-baas-security.yml`): gitleaks · trufflehog · semgrep · trivy · cargo-audit +
  govulncheck · ZAP baseline → `security-gate`.
