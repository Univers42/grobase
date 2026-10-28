# Grobase Status Page & SLA (Track C / C7)

> **Honesty rule (kernel #4):** every number here is a **TARGET** until a
> Track-C gate proves it. An SLA you cannot measure is unenforceable; an
> uptime credit you cannot compute is a dispute. Targets are tagged `(TARGET)`.

Customer-facing operational commitments. The operator's half (incident
response, on-call, per-symptom runbooks) is [`operations-runbook.md`](./operations-runbook.md);
the measured density/latency evidence is [`scale-slo.md`](./scale-slo.md).

---

## 1. Status page

An opt-in public status page and durable HTTP probe are implemented in
[`deploy/status`](../../deploy/status/README.md). Run it on an independent host
with operator-configured real public health URLs. Its read-only `/status.json`
and page show current freshness-aware component state and failed observations.
Missing/stale measurements are **unknown**, not invented uptime. No production
availability measurements or contractual SLA percentages are claimed here.

The **C7 mechanism** is exercised by `make reliability-test`: local real HTTP
probe → durable sample → public response, including failures, staleness and
restart. Production C7 evidence still requires independent deployment and real
samples; HTTP readiness alone does not prove SQL queries or WebSocket delivery.

| Component | Required operator evidence |
|---|---|
| API/Auth | Configure valid public readiness routes and exact successful response |
| Data plane | Add meaningful query/readiness probe; metrics alone are not availability |
| Realtime | Add a WebSocket/message probe; HTTP availability does not prove delivery |
| Database | Private SQL readiness and replication monitoring, not a public credentialed URL |
| Backups | Enable verified-completion freshness separately; see recovery runbook |

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
| Point-in-time recovery (restore-to-T) | RPO ≤ 5 min `(TARGET)` | Optional mechanism shipped (`PG_BACKUP_PITR`, m99); production configuration/measurement **not proven** |
| Full-cluster DR / failover | RTO ≤ 1 h `(TARGET)` | **NOT proven** — needs **C4** failover drill |

> **The binding honesty constraint (plan critic):** RTO/RPO is **only honest WITH
> C4b PITR**. Do NOT publish an RTO/RPO number to a customer until: (a) C4b WAL
> archiving + restore-to-timestamp gates, and (b) C4 runs an actual failover
> drill and records the measured RTO. Logical backups and optional PITR mechanisms
> exist; production failover and achieved RTO/RPO remain unproven. See
> [disaster-recovery.md](./disaster-recovery.md) for coverage, monitored schedules,
> isolated restore, cutover and evidence collection.

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
