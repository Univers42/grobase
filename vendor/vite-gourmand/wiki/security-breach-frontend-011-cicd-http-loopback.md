# Frontend Breach 011: HTTP on Loopback in CI Environment Variables (Reviewed — Safe)

Date: 2026-05-27
Severity: Informational (security hotspot, not a vulnerability)
Status: Reviewed — accepted as safe by design

## Affected Files

- `.github/workflows/ci-cd.yml` (env block, lines 22-23)

## Evidence

SonarQube fired `githubactions:S5332` — *"Using clear-text protocols is
security-sensitive"* — on:

```yaml
CI_LOCAL_API_ORIGIN: ${{ format('{0}{1}127.0.0.1:3000', 'http', '://') }}
FRONTEND_URL: ${{ format('{0}{1}localhost:3000', 'http', '://') }}
```

These variables drive the CI pipeline's integration tests against the
backend that the workflow itself starts on the runner.

## Why Not a Vulnerability Here

The Sonar rule fires because the URL scheme is `http`, which lacks TLS.
The risk model the rule defends against is:

| Generic risk | Applicability to CI loopback |
|---|---|
| Sniffing on the network path | ❌ None — `127.0.0.1` / `localhost` never leaves the runner's kernel |
| Tampering by network attacker | ❌ None — no network attacker can interpose on loopback |
| Redirect to malicious endpoint | ❌ None — destination is `127.0.0.1`, not DNS-resolved |
| Credential exposure | ❌ Variables hold no secret — `ci-test-secret-not-used-in-prod`, fake Google client ID, etc. |
| Insider threat / lateral movement | ❌ The runner is ephemeral, exists only for the duration of one CI job |

Loopback traffic on GitHub Actions runners is handled in-kernel and never
hits a network adapter. The only entity that could "sniff" it is a process
running on the same runner with privileges to read another process's
sockets — at which point TLS gives no protection either, because the
attacker would simply read the plaintext from the application's memory.

## Why TLS Is the Wrong Tool Here

Forcing HTTPS on loopback in CI would require, on every run:

1. Generate a self-signed CA and server cert (with the loopback hostname
   in `subjectAltName`),
2. Install the CA into the runner's trust store,
3. Configure the NestJS app to bind with TLS,
4. Configure Playwright / Postman / curl to trust the CA,
5. Tear it all down on cleanup.

This adds ~5-15 s per CI run and zero security improvement. It also
*reduces* security by normalising self-signed-cert acceptance in test
tooling, which can leak into developer habits.

## Production Protections (the real defense)

The codebase explicitly forbids `http://` in production via **multiple
defense layers**, each of which would fail the build:

1. `Back/src/main.ts` → `validateTransportSecurityConfig()` throws at boot
   if `FRONTEND_URL`, `PUBLIC_SITE_URL`, `VITE_PUBLIC_SITE_URL` or
   `VITE_API_URL` is non-HTTPS in production.
2. `Back/src/main.ts` → `enforceHttps` middleware 308-redirects any
   inbound HTTP request to HTTPS.
3. Helmet's `strictTransportSecurity` ships HSTS with 1-year max-age and
   `includeSubDomains` in production.
4. The CI workflow step **`Check production HTTPS transport policy`**
   (`.github/workflows/ci-cd.yml`, line ~370) greps every tracked env-bearing
   file (`.github`, `Back`, `View`, `docker-compose*.yml`,
   `infrastructure`, `.env*.example`) for `http://` in any of the
   production URL variables, **excluding loopback**. Build fails if
   anything is found.
5. `fly.toml` sets `force_https = true` at the platform edge.

Together these mean the CI variables flagged here cannot leak into
production paths without breaking another check.

## Repair

Marked the two lines with explicit `NOSONAR(githubactions:S5332)` markers
and a multi-line block comment that documents the rationale, plus a link
to this wiki entry. The lines themselves are unchanged.

```yaml
# The two URLs below intentionally use http:// — they target the GitHub Actions
# runner's own loopback interface (127.0.0.1 / localhost), which is not reachable
# from any network. Setting up TLS for loopback in CI would require provisioning
# a self-signed cert per run with no security benefit (no sniffable network path).
# Production rejects http:// URLs via validateTransportSecurityConfig() in
# Back/src/main.ts and via the workflow step "Check production HTTPS transport
# policy" (line ~370) which scans every env-bearing file for clear-text URLs.
# See: wiki/security-breach-frontend-011-cicd-http-loopback.md
CI_LOCAL_API_ORIGIN: ${{ format('{0}{1}127.0.0.1:3000', 'http', '://') }}  # NOSONAR(githubactions:S5332)
FRONTEND_URL: ${{ format('{0}{1}localhost:3000', 'http', '://') }}  # NOSONAR(githubactions:S5332)
```

## Verification

1. `grep -nE 'http://' .github/workflows/ci-cd.yml` should return only
   loopback hosts (`127.0.0.1` or `localhost`). Verified.
2. The workflow step `Check production HTTPS transport policy` (line ~370)
   must still pass on every run — it greps for production HTTP URLs while
   excluding loopback, so the two CI loopback URLs are filtered out and
   never cause a false positive.
3. The hotspot in SonarUI should be marked **"Safe"** at the project level
   with this wiki page as the linked rationale.

## How to Mark "Safe" in SonarUI (one-time human action)

The `NOSONAR` comment quiets the rule in the source file. To also clear
the hotspot in the SonarQube dashboard:

1. Open the SonarUI project view → Security Hotspots tab
2. Find the two `githubactions:S5332` entries for `ci-cd.yml`
3. For each, click "Review" → choose **"Safe"** → paste the wiki URL
   (`wiki/security-breach-frontend-011-cicd-http-loopback.md`) as
   justification.

## Residual Risk

Effectively none for the CI environment. If a future regression introduces
HTTP usage in **production-facing** code, the five production protections
listed above will catch it independently before deploy.

## Related

- Rule reference: SonarQube `githubactions:S5332` — *"Using clear-text
  protocols is security-sensitive"*.
- Production transport policy: see `infrastructure/contracts/transport-security.md`.
- See also `security-breach-frontend-008-https-ca-enforcement.md` (production HTTPS
  enforcement) and `security-breach-frontend-010-cicd-echo-untrusted-variable.md`
  (sibling hotspot in the same workflow file).
