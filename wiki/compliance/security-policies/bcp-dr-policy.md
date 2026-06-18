# Business Continuity & Disaster Recovery Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Ensure information and services can be recovered after disruption. (ISO/IEC 27001 Annex A
A.5.29–A.5.30; SOC 2 CC9.1 + Availability A1.)

## Policy
- **Backup (enforced).** Per-tenant logical backup and whole-cluster backups exist and are
  restore-tested: gate `m87` (per-tenant backup/restore), gate `m47` (cluster backup roundtrip /
  restore-drill).
- **Recovery (enforced).** Point-in-time restore to a timestamp is proven: gate `m99`. Restoration
  drills are themselves re-runnable gates, so recoverability is demonstrable, not asserted.
- **Resilience.** Read-replica routing offloads reads (gate `m122`); the hosting provider supplies
  redundant power/cooling/network (inherited — see [`../iso27001-soa.md`](../iso27001-soa.md) A.7,
  A.8.14).
- **Objectives — stated honestly.** Recovery-time and recovery-point objectives, and any uptime SLA,
  are **not asserted as live numbers**: per-tier targets are TARGETS pending the C7 uptime probe
  (`sla-uptime` = planned). The draft commitments live in [`../../sla-draft.md`](../../operations/sla-draft.md);
  they become enforceable only once a probe writes durable availability samples (tracked as
  R-UPTIME in [`../risk-register.md`](../risk-register.md)).

## Testing & review
Restore drills run as part of the gate battery; the plan is reviewed at least annually and after any
major architecture change.
