# query-router running the audit_log purge

Declined 2026-10-30 (devil verdict on grobase#83, option b, [ADR 0022](../docs/adr/0022-audit-log-retention-erasure.md)).

## Why

query-router runs on the VM and already writes audit rows. But moving the purge there splits one data-protection concern across two services: erasure in gdpr, retention in the query engine. The gdpr sub-service runs wherever the orchestrator runs, so it owns both.

## Reopen when

The orchestrator stops being part of every deployment that has an `audit_log`.
