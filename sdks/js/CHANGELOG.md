# Changelog — `@mini-baas/js`

All notable changes to the Grobase product SDK (and the bundled `baas` CLI) are recorded here.
This package follows [semantic versioning](https://semver.org). Releases publish to npm only on an
explicit `baas-cli-v<semver>` tag (see `.github/workflows/baas-cli-publish.yml`).

## Unreleased — Track-E SDK hardening

### Added
- **Idempotency-aware retry** — GET/HEAD/PUT/DELETE (and explicit `idempotent: true`)
  auto-retry on `429/500/502/503/504` + network errors with exponential backoff + jitter,
  a `maxDelayMs` cap, and `Retry-After` honoring. **POST creates do not auto-retry** by
  default (set `idempotent: true` to opt in). Tune via `retry: { attempts, delayMs, maxDelayMs, retryOn }`.
- **Typed error hierarchy** — `MiniBaasError` now has subclasses so callers can branch on
  type: `MiniBaasBadRequestError (400)`, `MiniBaasUnauthorizedError (401)`,
  `MiniBaasForbiddenError (403)`, `MiniBaasNotFoundError (404)`, `MiniBaasConflictError (409)`,
  `MiniBaasRateLimitError (402/429, carries `retryAfterMs`)`, `MiniBaasServerError (5xx)`,
  `MiniBaasNetworkError (transport)`. Each carries `status` + the server `body`; all remain
  `instanceof MiniBaasError` (back-compat).
- **Per-call timeout + AbortSignal** — `timeoutMs` and an external `signal` on REST request
  options; the external signal composes with the per-call timeout. Aborts surface as
  `MiniBaasTimeoutError` (`.external` distinguishes timeout vs caller-cancel).
- **`from(t).changesSince(cursor, { cursorColumn, limit })`** — keyset (offline-sync)
  pagination built from existing PostgREST primitives (no server change); returns
  `{ rows, nextCursor, hasMore }`.

### Notes
- All additive and back-compatible — existing call sites keep working with defaults.

## 0.2.0 — initial public release

First release intended for the public npm registry. The SDK is the **public product API**: gateway
routes and service endpoints stay private inside the SDK, so application code only ever calls domain
methods. The surface is **Supabase-shaped** on purpose (`createClient`, `.from(...)`, `.auth`,
`.storage`, `.rpc()`), so migration from Supabase is mostly a dependency swap (see
`wiki/migrate-from-supabase.md`).

### Added
- **Client** — `createClient({ url, anonKey, defaultDatabaseId, timeoutMs, retry })` with built-in
  timeout + retry, talking to the gateway over the public surface.
- **Data** — `.from(table).select/insert/update/delete/upsert(...)` over the engine-agnostic data
  plane (one API across all supported engines), with multi-database selection via
  `defaultDatabaseId` / per-call database id.
- **Auth** — `.auth.signIn/signUp/session(...)`.
- **Storage** — `.storage.from(bucket)` upload / download / list / createBucket / signed URLs.
- **RPC & analytics** — `.rpc(...)` and `.analytics.track(...)`.
- **Typed domain methods** — generated from the live OpenAPI spec (`npm run codegen:all`) so the
  surface stays congruent with the gateway contract.
- **`baas` CLI** (`npx baas …` / bundled bin) — `login`, `functions`, `secrets`, `triggers` for
  deploying serverless functions and managing function secrets/DB-event triggers (gate m61).

### Notes
- Published with npm provenance and `--access public` under the `@mini-baas` scope.
- In this monorepo the SDK is consumed via Docker-managed dependency volumes — do not install it on
  the host for local development (Docker-first).
