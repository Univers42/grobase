# 0018 — A request id that is not a bare UUID is stored as its UUIDv5, never stripped

- Status: accepted. On 2026-10-30 the devil ruled BLOCK on stripping `#counter`. That ruling lifts once conditions 1–4 hold; this change meets 1–7. Code on develop. The VM still runs the old query-router (condition 8).
- Date: 2026-10-30
- Deciders: devil (ruling). Owners of anything that joins audit_log or the outbox by `request_id`.

## Context

- `public.audit_log.request_id` is `UUID NOT NULL` (`scripts/migrations/postgresql/013_audit_log.sql:36`).
- Kong's correlation-id plugin sets X-Request-ID with `generator: uuid#counter` (`infra/docker/services/kong/conf/kong.yml:59-62`). It produces one UUID per worker plus a request counter, e.g. `61e4b18d-…-6988ff443eaf#41649`.
- Every audited request through Kong therefore failed its insert. On the b2b VM (query-router started 2026-10-29T23:52Z, 72 h of log read 2026-10-30):
  - 234 completed POSTs produced 231 `audit_log insert failed`.
  - All 231 ids carried `#counter`.
  - 31 failed with `invalid input syntax for type uuid`.
  - 200 failed on pool exhaustion (grobase#81).
  - `public.audit_log` held 0 rows.
- The outbox had its own copy of this check (`outbox.service.ts`, `uuidOrNull`), so every Kong request was written there with a NULL `request_id`.

## Decision

- `requestIdUuid` (`src/libs/common/src/audit/request-id.ts`) keeps a bare UUID unchanged. Anything else becomes the RFC 4122 v5 UUID of the whole string, under a fixed namespace, using `node:crypto` SHA-1 only.
- `AuditService.record` and all four outbox insert sites call it, so one request carries the same id in both tables. `uuidOrNull` stays for `actor_id` and uses the shared `isUuid`.
- The failure log shows the stored id and at most 128 characters of the raw header.

## Rejected

- **Strip `#counter`.** Every request a Kong worker served would share one permanent id in an append-only table (the devil's BLOCK).
- **`randomUUID()` for non-UUID ids.** Each table would get a different id for the same request, so the tables could not be joined.
- **Put the raw header in the payload as `request_id_raw`.** `normalizePayload` does not redact it, it cannot be attached to a primitive payload, and it overwrites a body field of that name.
- **Change the column to TEXT.** A schema change on a live table with RLS (`016_unify_rls.sql`) and a REST read grant (`090_control_tables_rest_readonly.sql`).
- **Change the Kong generator to `uuid`.** The VM's `kong.yml` carries uncommitted operator edits.

## Consequences

- Outbox rows for Kong requests gain a `request_id` instead of NULL. This is additive: nothing reads the column (`rg` finds only the inserts and `scripts/verify/m1-hardening.sh:117`).
- Caveat: the header is client-asserted (Kong keeps an inbound X-Request-ID). The id correlates rows; it does not authenticate them. To join a log line to its rows, recompute `requestIdUuid(<logged header>)`.
- Pool exhaustion still drops rows under a burst (grobase#81).

## Evidence

- jest in node:22: 42 suites, 686 tests passed. The audit specs pass 11/11, covering the RFC 4122 v5 vector, `u#1` ≠ `u#2`, determinism, a bare UUID unchanged, `req-1` / a 16 KiB string / an empty string, and `$1` bound as a UUID. prettier, eslint `--max-warnings 0`, and tsc (lib, query-router, root) are all clean.
- Mutation: hashing only the part before `#` fails `keeps every Kong uuid#counter request distinct` (1 failed, 10 passed).
- Rollout probe (condition 8, not run yet):
  - A POST through Kong produces a new row whose `request_id` equals `requestIdUuid` of the response's X-Request-ID.
  - Two POSTs produce two different ids.
  - The query-router is tagged `:pre-` first, in a confirmed window, and the VM `kong.yml` is left untouched.
