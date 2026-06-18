# Frontend Breach 003: Unsafe DOM Sink in Google Login Button

Date: 2026-05-26
Severity: Medium
Status: Fixed

## Affected Files

- `View/src/portal_dashboard/PortalLoginForm.tsx`
- `.github/workflows/ci-cd.yml`

## Evidence

The Google Identity button container was cleared with `googleBtnRef.current.innerHTML = ''`.

## Exploit Scenario

This specific assignment used a static empty string, so direct exploitation was limited. Still, allowing `innerHTML` patterns in authentication UI normalizes a dangerous sink that could later be changed to include dynamic content.

## Root Cause

The code used a string-parsing DOM API for a task that only needed child removal.

## Repair

- Replaced `innerHTML = ''` with `replaceChildren()`.
- Added a CI forbidden-pattern scan for `dangerouslySetInnerHTML`, `.innerHTML =`, `eval`, `new Function`, and `javascript:` URLs.

## Verification

- Forbidden-pattern scan in CI must pass.
- Google button still renders correctly after switching login/register modes.

## Residual Risk

Google Identity still injects its own controlled button markup. CSP must continue to allow only the required Google Identity origin.