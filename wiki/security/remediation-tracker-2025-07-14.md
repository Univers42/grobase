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
| **N-2** | **Revoke the Unsplash access key** committed in `daa68cf93b` (`vendor/vite-gourmand/Back/scripts/update-menu-images.ts:18`, since removed from the tree). trufflehog verified it **live** on 2026-09-24. | It stays in git history; only revoking it makes it harmless, and Unsplash has **no revocation API** (checked 2026-09-25): the app owner deletes/regenerates the key at unsplash.com/oauth/applications or asks api@unsplash.com. The `trufflehog` job of the Security workflow is red until then. |
| **C-1** | Revoke the leaked GitHub PAT at github.com/settings/tokens, then rotate anything that used it. | Issuer-side action. The value is no longer on the dev machine (checked 2026-09-25: `.env*`, home, containers, shell history, git history — only the fake fixture), and GitHub's revocation API needs the value. `fix/pat-out-of-env` (m-series, on main) stops `make env` from carrying GitHub tokens into `.env`. |
| **L-11** | Require signed commits on `main` (GitHub → Branches). | Repository setting. |
| **Vault base image** | `infra/docker/services/vault/Dockerfile` is `vault:1.21` (last 1.21 tag), `Dockerfile.fly` is `vault:1.16`; both carry fixable HIGH/CRITICAL CVEs (see `.trivyignore` note). Fix = Vault 2.x. | Major upgrade that ships to deployments (storage format, unseal) — needs a planned rollout. |

Deployment target: **self-hosted** (`make prod-up` = enforced preflight + prod overlay). fly.io is retired
(2026-09, cost); `deploy/fly/` is kept, not deleted, and its `boot.sh` changes ship only if it returns.

## Needs a product / architecture decision

| # | Finding | Evidence | Options |
|---|---|---|---|
| **H-16** | `deploy/fly/boot.sh` sets `GOTRUE_MAILER_AUTOCONFIRM=true`: sign-up without owning the address. | Fly is retired. The self-hosted path (`make prod-up`) layers the prod overlay, which sets `false` (m195) and needs a real `SMTP_HOST`. `boot.sh:61` is `${GOTRUE_MAILER_AUTOCONFIRM:-true}` if Fly ever returns. | Decide before a Fly return; confirm the website/vault42 frontends handle the confirmation step before a self-hosted go-live. |
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
| H-6 | A rotated-out service token (`INTERNAL_SERVICE_TOKEN_PREV`) was accepted silently | `fix/h6-service-token-rotation-signal` — `serviceauth.Verify` returns which token matched (both still compared, current wins); a `RotationNotice` logs ONE warning per process and counts `baas_service_token_previous_accepted_total`, never the token. Wired into every tenant-control service-token route (incl. `POST /v1/keys/verify`) and adapter-registry; the 16 other guards keep the plain bool (one-line switch each). | `match_test.go`, `rotation_test.go` (logs once, no token in output, 0 allocs on the current-token path); fuzz + rotation tests unchanged |
| H-14 | The identity-envelope replay cache was per process (a replay to another replica passed) | `fix/h14-identity-nonce-store` — `NonceStore` port; memory by default (parity), `IDENTITY_NONCE_STORE=redis` = `SET NX PX` shared store, fail-closed, 2 s timeouts; unknown kinds refused. Also: a malformed `INTERNAL_IDENTITY_MAX_SKEW_MS` no longer disables the freshness check. | `nonce-store.spec.ts`, `request-identity.spec.ts` (cross-replica replay rejected; guard-level replay 401 for all three guards; malformed skew) |
| M-8 | `SECURITY_MODE=max` never denied (compose passed `permissive`) | `82a9ea82` | m195 `static_realtime_mode`; `fallback_tests` |
| M-11 | Key issue/revoke left no trace | `12ccee2b` | m83 step 4e3 (log lines for the key id) |
| M-12 | Bucket policy: presign skipped it; a bucket named `constructor` bypassed a `*` deny | `34af96f1` | `bucket-policy.spec.ts` |
| M-16 | Automation rule names could forge log lines (CR/LF) | `61514472` | `automations.service.spec.ts` |
| M-17/L-9 | Presigned GETs of SVG/HTML rendered on a browsable origin | `5807534a` (+ `a47f906a` proxied path) | `presign-active-content.spec.ts` |
| L-6 | One small image upload + transform OOM-killed storage-router (measured: 151 MP under the 128 MiB limit) | `f3dc5cfc` | `image-transform.spec.ts`; measurements in the commit |
| H-20 | ShellCheck SC2086 disabled globally | `fix/sec-h20-quoting` | CI shellcheck job, step *Quoting (SC2086) on untrusted-input scripts*: `--norc -i SC2086` over the 58 container-entrypoint / deploy / ops / db / env / secrets / vault scripts — red before (8 hits), green after. None of the 8 was exploitable (the `export PGPASSWORD=${…}` split only on dash < 0.5.11); fly's `bring_up` splits `$DC`/`$SERVICES` on purpose (function-level directive). |
| L-12 | Webhook DNS rebinding | `2463fd66` (IP-pinned connect-time lookup; the reverted IP-rewrite broke TLS) | `automations.pin.spec.ts` |
| C-3 | Kong admin API on the flat network | `e92133b1` (prod: admin off, status listener keeps /metrics) | m195 throwaway Kong |
| C-5 | Vault on fly ran as root | `3368756b` (`VAULT_DROP_PRIVILEGES_ENABLED`) | m196 |

## Found during re-verification (not in the audit)

| ID | Finding | Fix | Proof |
|---|---|---|---|
| N-1 | `public.schema_registry` (cross-tenant table catalog) readable, insertable and deletable with the anon key | `90c122e0`, migration 088 | m200 (invariant + live 401) |
| **N-3** | A table created through the DDL API on a mount pointing at the platform database — or any table nothing granted — was readable/writable with the anon key via PostgREST: `db-bootstrap` + `001` granted anon/authenticated on every existing AND future `public` table, and bootstrap re-granted every boot (fly never re-runs migrations, so a reboot undid 088). On a fresh install every control-plane table had anon read+write with RLS as the only barrier. Option (b) taken: no blanket/default grant; bootstrap revokes the default every boot; migration 089. | `fix/sec-n3-default-privileges` | m200 step 4 (fresh ungranted table: 200 → 401); old-vs-new fresh-install ACL diff over 67 tables (authenticated keeps every explicit grant); CI integration phases on a fresh stack |
| N-4 | Vault unseal key + root token written `0644`; a lost key file wiped all Vault storage | `03b69632` | m199 |
| N-5 | `h2` 0.3 (RUSTSEC-2026-0258) in the DynamoDB build fly runs | `5047bb02` | `make audit-deps`: FAIL → OK; live dynamodb-local round trip |
| N-6 | 17 fixable HIGH npm advisories (multer, sharp, nodemailer, axios, js-yaml, …) | `d40b2909` | trivy fs 17 → 0; jest 445/445; m55 + phase 9 live |
| N-7 | SAST scanner reported "clean" on a missing report; real semgrep verdict was 1 ERROR | `c628adb8` | semgrep 0 ERROR; missing report → FAIL |
| N-8 | Gates that could not fail: m157 (swallowed render errors), m198 (never booted), m5/m60 (monorepo paths, formatter-mangled key) | `8e74a577`, `132c995e`, `9dba37ec` | each red on a broken input, green on the real one |
| N-9 | No security scanner ran in CI | `9dba37ec` | `.github/workflows/mini-baas-security.yml` + blocking `security-gate`; m5, m60 green |
| N-10 | `postgres/Dockerfile` wrote placeholder "sha256:…-pinned-by-mini-baas" strings into a manifest claiming pinned FDW builds; m6 "proved" the pins by grepping the ARG names; the FDWs are not compiled in at all | `fix/fdw-manifest-honest` | manifest states not-built/built-in with real versions (partial image build printed); m6 fails on any placeholder pin |
| M-13 / L-5 | GoTrue password length and refresh-reuse window hard-coded in base compose | `fix/gotrue-compose-params` | renders: base 8/10, .env override 14, prod 12 |

## Open, tracked

| ID | Finding | Note |
|---|---|---|
| M-4 | Realtime does not check `iss` | Step 1 done (`fix/sec-m4-issuer-expression`: GoTrue and tenant-control resolve the issuer from one expression, so an override cannot split minter and verifier). Remaining, in order: stamp `iss` in `appchannels/mint.go` (only after the Go verifier can tell that token apart — its `sub` is a tenant slug); re-issue the five seed app tokens that use `iss: "supabase"` (canagrou, gourmand, hambooking, hypertube, red-tetris) plus m22/m23/seed-live-demo; set `REALTIME_JWT_ISSUER`; then require `iss` in realtime's validation. Every minter shares one secret, so this is defence in depth. Minter inventory: 12 paths, in the M-4/M-5 sweep of 2026-09-25. |
| M-5 | `sub` not validated as a UUID | **Rejected as asked**: SSO sessions carry the IdP's raw subject and passkeys' `user_id` is client-supplied — a UUID check breaks both (and gate m64). The real hole it pointed at is closed instead: with an empty `GOTRUE_JWT_ISSUER` the verifier accepted any same-secret token (cross-app, seed) as a user session; tenant-control now refuses to start with an empty issuer (`fix/sec-m5-issuer-guard`, `JWT_ALLOW_NO_ISSUER=1` opts out; `TestRequireIssuer`). |
| — | `edition-query` offer build was intermittent in CI | Cause found: concurrent Rust builds raced on a `sharing=shared` cargo cache mount ('failed to unpack package'); now `sharing=locked`. |

## False positive, mitigated or by design

C-4 (`VAULT_API_ADDR` is the advertise address) · C-6 (dev-only profile, localhost) · H-2/H-3
(container-internal binds) · H-7 (verify needs the service token; fast hash for new keys) · H-8
(`GITHUB_TOKEN` is per-job and masked; H-9 least privilege done in `a51ffad2`) · H-10 (the original
`sh -c` expands inside the container and is not injectable; the reverted fix broke backups) · H-12
(`:?` in base breaks every render without `.env`; enforced by the preflight, m194, which `make prod-up` runs before compose up) · H-17 (realtime
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
