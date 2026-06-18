# Service Level Agreement (SLA)

> **TEMPLATE — review by counsel before use; not legal advice.** This is the
> contract-facing wrapper around the operational SLA. **It invents no numbers.**
> Every uptime target, support window, and RTO/RPO figure here is **referenced
> from** [`../status-sla.md`](../operations/status-sla.md), where each value is tagged
> `(TARGET)` until a Track-C gate proves it. Do not present any figure as a binding
> commitment until the source doc marks it measured/enforceable.

This SLA forms part of the [Terms of Service](./terms-of-service.md) and applies to
paid tiers of the Grobase managed Service. The free / nano tier is best-effort with
**no SLA**.

## 1. Where the numbers live (single source of truth)

The authoritative, version-controlled SLA values are in
[`wiki/status-sla.md`](../operations/status-sla.md):

- **§2** — per-tier monthly uptime targets, support-response targets.
- **§3** — RTO / RPO and their honest shipped/not-shipped status.
- **§4** — the uptime-credit policy (stub until the C7 probe + D4.9 calculator).

This legal wrapper deliberately does **not** restate those figures, so the two can
never drift. When `status-sla.md` flips a value from `(TARGET)` to measured, this
SLA's commitment for that value becomes enforceable — not before.

## 2. Enforceability precondition (the honesty gate)

An uptime commitment is enforceable only once **all** of the following are true,
per `status-sla.md`:

1. The **C7 uptime probe** is live and writing durable availability samples (it is
   the single source of truth for monthly uptime).
2. A signed agreement incorporates the tier's uptime target.
3. For RTO/RPO: **C4b** (WAL archiving + restore-to-timestamp) and **C4** (a measured
   failover drill) have run. Until then DR is "logical per-tenant backup exists
   (B6, shipped); cluster-level PITR/failover is roadmap" — nothing stronger may be
   promised.

Until §2.1 is satisfied, the status page is a scaffold and the SLA below is **not**
enforceable. This is stated plainly so a credit is never issued off an unmeasured
number.

## 3. Service credits

Service credits follow the **target** schedule in `status-sla.md` §4 and are computed
by the D4.9 uptime-credit calculator from C7 probe data, capped at the tier's monthly
fee, requested within 30 days, and recorded as a tamper-evident audit event
(trust center control `tamper-evident-audit`, gate m104). The credit schedule's final
numbers are a legal/commercial decision (D4.2) and are not operative until the probe
and calculator exist.

## 4. Exclusions

Uptime excludes scheduled maintenance (announced ≥ 72 h ahead) and force majeure, per
`status-sla.md` §2.

## 5. Cross-references

- Customer-facing operational SLA + status page → [`../status-sla.md`](../operations/status-sla.md)
- Measured density/latency evidence → [`../scale-slo.md`](../operations/scale-slo.md)
- Operator incident response → [`../operations-runbook.md`](../operations/operations-runbook.md)
- Trust center (evidence-backed controls) → [`../trust-center.md`](../security/trust-center.md)
