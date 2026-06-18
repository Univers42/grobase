# Frontend Breach 007: Cookie Auth Without Explicit CSRF Gate

Date: 2026-05-26
Severity: High
Status: Fixed

## Affected Files

- `Back/src/auth/auth-cookie.constants.ts`
- `Back/src/auth/auth.controller.ts`
- `Back/src/main.ts`
- `View/src/services/api.ts`

## Evidence

Moving authentication from bearer tokens to cookies improves token theft resistance, but cookies are sent by the browser automatically. Without an explicit CSRF check, authenticated unsafe requests could rely only on SameSite behavior.

## Exploit Scenario

A victim is logged in and visits an attacker-controlled site. The attacker attempts to submit a cross-site POST/PATCH/DELETE request to a protected API route. If the browser includes the auth cookie and the backend only checks the cookie, the action may run as the victim.

## Root Cause

Cookie-backed authentication was introduced before a second request proof was required for unsafe methods.

## Repair

- Added a readable `vg_csrf_token` cookie alongside the httpOnly auth cookie.
- Added backend CSRF middleware for unsafe `/api` requests when an auth cookie is present.
- Required the `X-CSRF-Token` header to match the CSRF cookie value.
- Exempted login/register/logout/password-reset endpoints where the flow must work before a valid session exists or must clear a broken session.
- Updated the frontend API wrapper to read the CSRF cookie and send `X-CSRF-Token` on POST/PUT/PATCH/DELETE requests.
- Cleared the readable CSRF cookie during frontend logout/session cleanup.

## Verification

- Backend e2e tests pass with cookie auth and CSRF middleware enabled.
- Unsafe protected API requests with an auth cookie but no matching `X-CSRF-Token` should return 403.
- Normal frontend API calls should continue because `apiRequest` attaches the header automatically.

## Residual Risk

CSRF tokens protect cross-site request forgery, not XSS. CSP, DOM-sink scanning, and removal of browser-readable JWTs remain necessary XSS controls.