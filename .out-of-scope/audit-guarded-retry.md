# Retrying an ambiguous audit insert behind a `NOT EXISTS` guard

Declined 2026-10-30 (devil verdict A2/A12 on grobase#81, [ADR 0021](../docs/adr/0021-audit-batch-writer.md)).

## Why

When the connection drops after an `INSERT` was sent, nobody knows whether it committed. A retry guarded by `WHERE NOT EXISTS (SELECT 1 FROM audit_log WHERE request_id = …)` looks safe, but `audit_log` has row-level security: the writer may not see a row that is there, so the guard lets a duplicate through. `request_id` also has no unique index, so nothing else rejects it.

## Reopen when

`audit_log` gets a unique key the writer can rely on (for example `UNIQUE (request_id)` with `INSERT … ON CONFLICT DO NOTHING`), or the outbox writes the audit row in the business transaction.
