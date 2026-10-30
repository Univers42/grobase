# The Node gdpr-service owning audit_log erasure and retention

Declined 2026-10-30 (devil verdict on grobase#83, [ADR 0022](../docs/adr/0022-audit-log-retention-erasure.md)).

## Why

The Node `gdpr-service` is retired. It is in the `legacy-node` profile (`orchestrators/compose/base/app-services.yml:445`), and Kong sends `/gdpr` to the Go orchestrator. Erasure and the purge live in `gdprsvc`, the only live path. If the Node service is started again as a rollback, both are lost; the ADR says so.

## Reopen when

The `legacy-node` profile becomes the live gdpr path again.
