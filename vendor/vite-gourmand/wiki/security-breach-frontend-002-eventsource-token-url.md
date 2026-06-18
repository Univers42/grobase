# Frontend Breach 002: Access Token in EventSource URL

Date: 2026-05-26
Severity: High
Status: Fixed

## Affected Files

- `View/src/components/features/logs/useRealLogs.ts`
- `Back/src/logging/log.controller.ts`
- `Back/src/auth/strategies/jwt.strategy.ts`

## Evidence

The live log stream opened `EventSource('/api/logs/stream?token=...')`. Query strings can leak through browser history, proxy logs, server logs, referrer chains, monitoring tools, and screenshots.

## Exploit Scenario

An admin opens the DevBoard logs screen. The URL containing the JWT appears in request logs. Anyone with access to those logs can replay the token until it expires.

## Root Cause

Native EventSource cannot send custom Authorization headers, so the frontend passed the JWT in the URL.

## Repair

- Removed frontend token reading for the log stream.
- Changed EventSource to `new EventSource('/api/logs/stream', { withCredentials: true })`.
- Protected the SSE backend route with `JwtAuthGuard` and `RolesGuard` instead of a public query-token validator.
- Reused cookie JWT extraction from the normal auth strategy.

## Verification

- Search must find no EventSource URL containing `token=` in `View/src`.
- `/api/logs/stream` must return 401 without a valid auth cookie or bearer token.
- Admin/employee users should still receive live logs.

## Residual Risk

SSE still exposes operational logs to authorized users. Backend RBAC and audit logging remain the main controls for who can view those logs.