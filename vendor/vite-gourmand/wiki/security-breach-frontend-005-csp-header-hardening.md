# Frontend Breach 005: Incomplete Frontend Security Headers and URL Policy

Date: 2026-05-26
Severity: High
Status: Fixed

## Affected Files

- `Back/src/main.ts`
- `View/src/services/menus.ts`

## Evidence

The frontend delivery CSP missed several explicit restrictions such as `object-src`, `form-action`, and `frame-ancestors`. Menu image URLs were accepted if they were not Unsplash URLs, without first rejecting unsafe schemes or embedded credentials.

## Exploit Scenario

A future stored URL field could point to an unexpected scheme or credential-bearing URL. A weaker CSP also gives future XSS or content injection bugs more room to execute or frame the app.

## Root Cause

Security policy relied on framework defaults and image optimization logic instead of explicit allow/deny rules.

## Repair

- Added explicit CSP directives: `object-src 'none'`, `form-action 'self'`, `frame-ancestors 'none'`, `font-src`, stricter `connect-src`, and production `upgrade-insecure-requests`.
- Kept Google Identity origins explicit for OAuth.
- Added image URL validation before optimization; relative URLs and http/https URLs without embedded credentials are allowed, unsafe values fall back to the safe default image.

## Verification

- Header checks should show CSP, Referrer-Policy, Permissions-Policy, and no object/frame embedding permissions.
- Menu image transformation should never return `javascript:`, malformed, or credential-bearing URLs.

## Residual Risk

`script-src` and `style-src` still include `unsafe-inline` for compatibility with the current Vite/Google/Tailwind runtime. Removing those allowances should be a later hardening target with nonce/hash support.