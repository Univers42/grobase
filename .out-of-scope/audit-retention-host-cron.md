# A host cron or systemd timer for the audit_log purge

Declined 2026-10-30 (devil verdict on grobase#83, option c, [ADR 0022](../docs/adr/0022-audit-log-retention-erasure.md)).

## Why

A host timer has to be installed by hand on each machine, so a fresh clone gets no retention. Every deployment would also need its own install step and a check that it ran. The orchestrator's `gdprsvc.Run` comes up with the stack, so retention needs no install step.

## Reopen when

Purges must run while the orchestrator is down, or on a schedule an operator sets without restarting it.
