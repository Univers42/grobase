# Frontend Breach 008: Missing Project-Wide HTTPS/CA Enforcement

Date: 2026-05-26
Severity: Critical
Status: Fixed

## Affected Files

- `Back/src/main.ts`
- `View/src/services/api.ts`
- `View/src/pages/PublicSPA.tsx`
- `.github/workflows/ci-cd.yml`
- `.env.production.example`
- `infrastructure/services/fly/config/fly.toml`
- `infrastructure/contracts/transport-security.md`
- `infrastructure/contracts/secrets.md`
- `docs/environment.md`

## Evidence

The project relied mainly on deployment configuration for HTTPS. The backend did not explicitly validate production public origins, did not redirect proxy-reported HTTP requests to HTTPS, and the frontend could be built with insecure production URL environment values.

## Exploit Scenario

A production environment is accidentally configured with a public `http://` origin or a reverse proxy forwards HTTP traffic without redirecting. Users could load pages, API calls, OAuth flows, or cookies over an insecure transport, exposing session and personal data to network interception or downgrade attacks.

## Root Cause

HTTPS was treated as a deployment detail instead of a permanent application and CI policy.

## Repair

- Added production origin validation in the backend: public origins must use `https://`.
- Added proxy-aware HTTPS enforcement with a permanent `308` redirect.
- Enabled Express `trust proxy` in production so TLS termination headers are honored.
- Set explicit production HSTS: `max-age=31536000; includeSubDomains; preload`.
- Kept localhost HTTP as a development/CI-only exception.
- Added frontend runtime guards for `VITE_API_URL` and `VITE_PUBLIC_SITE_URL`.
- Added CI checks for HTTPS enforcement, HSTS, Fly `force_https`, and insecure production URL values.
- Documented the CA-backed TLS requirement in `docs/environment.md` and `.env.production.example`.
- Added `scripts/deploy/fly-certificates.sh` to request/inspect Fly managed certificates.
- Added `scripts/security/verify-production-https.sh` to verify DNS, CA trust, certificate expiry, redirects, HSTS, and public pages.
- Added `View/public/.htaccess` for Apache/OVH-style static hosts and `docs/nginx-vite-gourmand-https.conf` for Nginx hosts.
- Moved Fly configuration under `infrastructure/services/fly/config/fly.toml` and Dockerized Fly CLI operations.

## Verification

- Production `FRONTEND_URL`, `PUBLIC_SITE_URL`, `VITE_PUBLIC_SITE_URL`, and `VITE_API_URL` must use `https://` unless the value is localhost for development/CI.
- HTTP requests reported by the proxy with `X-Forwarded-Proto: http` must receive a `308` redirect to the same host/path over HTTPS.
- Production responses must include `Strict-Transport-Security` with one-year max age, subdomains, and preload.
- CI must fail if production public URL configuration reintroduces non-localhost `http://`.
- `scripts/security/verify-production-https.sh` must pass after DNS points to the selected production hosting layer.

## Residual Risk

The application cannot issue a CA certificate by itself. The hosting layer must install and renew a browser-trusted certificate through Fly managed certificates, Let's Encrypt, Cloudflare, or another trusted CA. Current live checks show trusted Let's Encrypt certificates for `vite-gourmand.fr` and `www.vite-gourmand.fr`, but HSTS is missing and `http://www.vite-gourmand.fr` returns `200`; DNS/hosting must be cleaned up before production can be considered complete.