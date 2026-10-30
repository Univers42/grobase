# 0021 — `audit_log` rows are written in batches by one flusher

- Status: accepted. On 2026-10-30 the devil ruled PROCEED-WITH-CONDITIONS (A1–A12) on grobase#81. VM rollout pending: query-router first, the other six services after 24 h with `mini_baas_audit_log_dropped_total` at 0 (A11).
- Date: 2026-10-30
- Deciders: devil (ruling). Owners of `AuditService` and of the services that run it.

## Context

- `AuditInterceptor` calls `void audit.record(...)` after a handler succeeds. `record()` sent one single-row `INSERT` on a pool of 2 connections (`connectionTimeoutMillis: 5000`, `statement_timeout: 3000`).
- A burst queued every row behind the pool. A row that waited more than 5 s failed with `timeout exceeded when trying to connect` and was lost.
- On the VM, 2026-10-29 23:00–23:59Z: 234 POSTs, 231 audit failures, 200 of them that message.
- Bench (`postgres:16-alpine`, the 013 table and indexes, a `BEFORE INSERT` trigger that sleeps D ms, pg 8.20.0, the service's pool), N = 1000 concurrent rows: 74 lost at D = 10, 614 at D = 25, 810 at D = 50.

## Decision

`AuditBatchWriter` (`src/libs/common/src/audit/audit-writer.ts`) owns the buffer. `AuditService.record()` only builds the row and enqueues it.

- The row is redacted, stringified and given its UUIDv5 request id at enqueue time. The buffer holds primitives only (A5).
- The buffer is capped by rows (`AUDIT_BUFFER_MAX`, default 10 000) and by bytes (`AUDIT_BUFFER_MAX_BYTES`, default 8 MiB, counted as 2 × string length). Six services run with a 96 MB heap, so a row cap alone could crash them (A1). A row over either cap is dropped and counted in `mini_baas_audit_log_dropped_total`; the warning is logged at most once per 10 s.
- One flusher writes up to 100 rows per multi-row `INSERT` (800 parameters). A row enqueued while the flusher finishes starts the next flusher (A6).
- What a failure does depends on its class (A2–A4):

| Class | Codes | Action |
| --- | --- | --- |
| `connect` | pool connect timeout, `ECONNREFUSED`, `ENOTFOUND`, `EAI_AGAIN`, `57P01`, `57P03`, `53300`, `40001`, `40P01` | retry after 0.5 / 1 / 2 s, then give up |
| `data` | SQLSTATE class 22, 23 | write the batch row by row, once |
| `timeout` | `57014` | write the batch row by row, once |
| `other` | any other SQLSTATE (42, 28, …) | give up, no retry |
| `ambiguous` | no SQLSTATE (connection lost mid-statement, driver throw) | give up, no retry |

- A give-up adds the rows to `mini_baas_audit_log_write_failed_total{reason}` and logs one warning with at most 5 request ids and no payload (A8).
- `onModuleDestroy` stops accepting rows, drains for at most 5 s, counts what is left as dropped, then ends the pool (A7).
- The table, schema, interceptor and pool settings are unchanged (A10).

## Rejected

- **Retry ambiguous failures behind a `NOT EXISTS (request_id)` guard.** RLS on `audit_log` can hide rows from the writer, so the guard can let a duplicate through or skip a row that was never stored. `.out-of-scope/audit-guarded-retry.md`.
- **A larger pool.** It raises the ceiling without bounding the queue; the same burst at a higher rate loses rows the same way.
- **Write the audit row in the business transaction (outbox).** It is the long-term answer, but every service's writes would have to share one transaction with the audit row.

## Consequences

- Caveat: rows live in memory until they are written. A crash loses the buffer, where the old code lost only in-flight rows.
- Caveat: the byte count is 2 × string length, an upper bound for UTF-16 and not the real heap cost.
- A statement whose answer never came back is not retried. That batch is lost and counted as `ambiguous`, rather than risk a duplicate.
- After a `57014`, the batch is written one row per statement. At D = 50 ms per row that is 20 rows/s; a smaller batch would be faster. Not done: no measurement says the VM sees `57014`.

## Evidence

- jest in node:22: 45 suites, 731 tests passed. prettier, eslint `--max-warnings 0` and tsc are clean.
- `audit-writer.spec.ts` names the condition each test proves: a 1000-row burst through a 5 ms insert stores all 1000 in order in 11 statements; A1, A2 (ambiguous = 1 attempt, connect timeout = 4), A3/A9 (10 bad rows of 1000 → exactly 10 lost), A4, A6, A7, A8.
- Bench against the writer (`/mnt/storage/dlesieur/tmp/i81bench/run-writer.sh`, same pool and table; per-statement D adds a statement-level trigger):

| N | per-row D | per-statement D | lost | wall time |
| --- | --- | --- | --- | --- |
| 1000 | 0 | 0 | 0 | 26 ms |
| 1000 | 0 | 50 ms | 0 | 581 ms |
| 1000 | 10 ms | 0 | 0 | 10.1 s |
| 1000 | 25 ms | 0 | 0 | 25.2 s |
| 5000 | 0 | 50 ms | 0 | 2.7 s |
| 1000 | 50 ms | 0 | 299 (199 dropped at the bench's 60 s close) | 60 s |

The A4 gate (0 lost at per-statement D = 50 and per-row D = 25) passes. The last row is the row-by-row throughput limit above; every lost row is counted, none is silent.
