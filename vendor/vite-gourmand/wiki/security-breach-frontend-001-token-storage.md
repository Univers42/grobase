# Frontend Breach 001: Browser-Readable JWT Storage

Date: 2026-05-26
Severity: Critical
Status: Fixed

## Affected Files

- `View/src/services/api.ts`
- `View/src/services/auth.ts`
- `View/src/portal_dashboard/PortalAuthContext.tsx`
- `View/src/pages/OrderPage.tsx`
- `Back/src/auth/auth.controller.ts`
- `Back/src/auth/strategies/jwt.strategy.ts`
- `Back/src/auth/auth.module.ts`

## Evidence

The frontend stored `accessToken` and `refreshToken` in `localStorage`. Any XSS payload running in the origin could read and exfiltrate those tokens, then replay them as bearer credentials.

The backend also configured access tokens for `7d`, increasing the replay window.

## Exploit Scenario

An attacker injects script through any future XSS point, third-party script compromise, browser extension, or supply-chain issue. The script reads `localStorage.accessToken` and uses it to access protected API routes as the victim.

## Root Cause

The session model depended on browser-readable persistent storage for bearer tokens.

## Repair

- Added an httpOnly `vg_access_token` cookie on login/register/Google login.
- Updated JWT extraction to accept either the legacy Authorization header or the secure cookie.
- Removed frontend storage of JWTs in `localStorage` and clear legacy token keys at module load/logout.
- Added `credentials: 'include'` to API requests.
- Shortened JWT lifetime from `7d` to `15m`.
- Kept access-token response bodies only for `NODE_ENV=test` compatibility with existing backend tests.

## Verification

- Search must find no `localStorage.setItem('accessToken'...)` or `localStorage.setItem('refreshToken'...)` in `View/src`.
- Login should set an httpOnly cookie and not persist JWTs in browser storage.
- Existing bearer-token tests remain supported in test mode.

## Residual Risk

Access-token cookies still authenticate requests until expiry. SameSite=Lax, httpOnly, 15-minute JWT expiry, and the CSRF header check reduce theft/replay and cross-site request risk. A full refresh-token rotation model would be stronger for long-lived sessions.