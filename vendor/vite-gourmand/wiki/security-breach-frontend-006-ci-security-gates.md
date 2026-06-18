# Frontend Breach 006: Missing Frontend Security Gates in CI

Date: 2026-05-26
Severity: Medium
Status: Fixed

## Affected Files

- `.github/workflows/ci-cd.yml`

## Evidence

The CI pipeline ran lint, backend tests, and builds, but it did not run a frontend dependency audit or fail on high-risk frontend security patterns.

## Exploit Scenario

A vulnerable dependency or a reintroduced XSS/token-storage pattern could merge while normal lint/build checks still pass.

## Root Cause

Security checks were not part of the required frontend CI path.

## Repair

- Added a `frontend-security` job.
- Runs `npm ci` and `npm audit --audit-level=moderate --json` in `View`.
- Uploads the audit JSON as a CI artifact.
- Fails on forbidden patterns: `dangerouslySetInnerHTML`, `.innerHTML =`, `eval`, `new Function`, `javascript:`, browser-readable JWT persistence, and EventSource URL tokens.
- Made the build job depend on both backend tests and the frontend security job.

## Verification

- Pull requests and pushes to `main` must pass the new `3 · Frontend security` job before build artifacts are produced.
- Local forbidden-pattern search should match the CI logic.

## Residual Risk

`npm audit` is advisory-based and can miss unknown vulnerabilities. Add CodeQL/dependency-review in repository settings for stronger coverage.