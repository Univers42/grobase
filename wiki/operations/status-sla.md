# Grobase Status Page & SLA (Track C / C7)

> **Honesty rule (kernel #4):** every number here is a **TARGET** until a
> Track-C gate proves it. An SLA you cannot measure is unenforceable; an
> uptime credit you cannot compute is a dispute. Targets are tagged `(TARGET)`.

Customer-facing operational commitments. The operator's half (incident
response, on-call, per-symptom runbooks) is [`operations-runbook.md`](./operations-runbook.md);
the measured density/latency evidence is [`scale-slo.md`](./scale-slo.md).

---

## 1. Status page

A public status page reports per-component health + incident history.

| Component | Health source | Status |
|---|---|---|
| API (Kong front door) | uptime probe of `/` on the ingress | `(TARGET)` — probe not yet wired |
| Auth | probe `/api/auth/availability` (no `/health` on the gateway) | `(TARGET)` |
| Data plane | `:4011/metrics` `baas_data_plane_*` + a probe | partially measurable |
| Realtime | `--healthcheck` + a WS probe | `(TARGET)` |
| Database | `pg_isready` + replication lag (once HA) | `(TARGET)` |

**The C7 gate is exactly this:** *the status page reads REAL uptime.* Until a
probe writes durable availability samples, the page is a static scaffold and the
SLA below is **not** enforceable. Implementation options (pick one at go-live):
external synthetic probe (e.g. a 60s curl from an off-box runner writing to a
time series) → public page (Statuspage/Upptime-style). This is on-demand
infra, not yet stood up.

`security.txt` + a vulnerability-disclosure link live alongside the status page
(D4.6, Trust Center).

---

## 2. SLA targets by tier

SLA is offered on **paid** tiers; the free/nano tier is best-effort (no SLA).
Quantities below are **TARGETS** pending the C7 uptime probe + a signed
agreement (legal templates are D4.2).

| Tier | Monthly uptime `(TARGET)` | Support response `(TARGET)` | RTO / RPO `(TARGET)` |
|---|---|---|---|
| nano / free | best-effort, no SLA | community | none |
| basic | 99.5 % | 1 business day | best-effort |
| essential | 99.9 % | 8 business hours | see §3 |
| pro | 99.9 % | 4 business hours | see §3 |
| max / enterprise | 99.95 % | 1 hour (SEV1) | negotiated, see §3 |

> Uptime excludes scheduled maintenance (announced ≥ 72 h ahead) and force
> majeure. "Uptime" = the API availability SLO in `operations-runbook.md` §1
> (5xx-based), measured over a calendar month.

---

## 3. Disaster recovery — RTO / RPO (the honest section)

**RTO** (Recovery Time Objective) = how long to restore service. **RPO**
(Recovery Point Objective) = how much data loss is acceptable.

| Capability | Target | Honest status |
|---|---|---|
| Per-tenant logical backup/restore | available | **shipped** (B6, `TENANT_BACKUP_ENABLED`; schema-per-tenant MVP) |
| Point-in-time recovery (restore-to-T) | RPO ≤ 5 min `(TARGET)` | **NOT shipped** — needs **C4b** WAL archiving |
| Full-cluster DR / failover | RTO ≤ 1 h `(TARGET)` | **NOT proven** — needs **C4** failover drill |

> **The binding honesty constraint (plan critic):** RTO/RPO is **only honest WITH
> C4b PITR**. Do NOT publish an RTO/RPO number to a customer until: (a) C4b WAL
> archiving + restore-to-timestamp gates, and (b) C4 runs an actual failover
> drill and records the measured RTO. Until then DR is "logical per-tenant backup
> exists; cluster-level PITR/failover is roadmap." Anything stronger is a claim
> without an artifact.

---

## 4. Uptime-credit policy (stub)

When measured monthly uptime falls below a tier's SLA target, the customer is
eligible for a service credit on the next invoice. **TARGET schedule** (final
numbers are a legal/commercial decision — D4.2 + D4.9):

| Measured uptime (paid tier) | Credit `(TARGET)` |
|---|---|
| below target, ≥ 99.0 % | 10 % of monthly fee |
| 95.0 – 99.0 % | 25 % |
| below 95.0 % | 50 % |

Mechanics (to build — **D4.9** uptime-credit calculator):
1. The C7 uptime probe is the **single source of truth** for monthly uptime.
2. The customer requests a credit within 30 days of the incident month.
3. The calculator reads probe uptime → computes the credit → issues it via the
   billing system (B3/E5) and writes a **tamper-evident audit event** (D3a).
4. Maximum credit per month is capped at the tier's monthly fee.

> This policy is a **stub** until: the uptime probe is live (C7 gate), the
> calculator exists (D4.9), and the credit amounts are legally signed off (D4.2).
> Issuing a credit off an unmeasured uptime number would be a dispute, not a
> commitment — so the policy is published as a target, not yet operative.

---

## 5. Cross-references

- Operator runbooks + incident response → [`operations-runbook.md`](./operations-runbook.md)
- Measured scale/density/latency evidence → [`scale-slo.md`](./scale-slo.md)
- Plan rows: C4 (DR), C4b (PITR), C7 (ops/uptime), D4.9 (SLA credit), D4.2
  (legal/DPA/ToS) → [`../.claude/plans/managed-cloud-enterprise.md`](../../.claude/plans/managed-cloud-enterprise.md)
