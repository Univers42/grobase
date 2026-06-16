# Grobase Operations Runbook (Track C / C7)

> **Honesty rule (kernel #4):** every SLO/RTO/RPO/uptime figure in this doc is a
> **TARGET** until a Track-C gate proves it. Targets are tagged `(TARGET)`;
> measured facts cite an artifact + reproducing command (see
> [`scale-slo.md`](scale-slo.md)). A target stated as a fact is a defect.

This is the operator's index: what we commit to (SLOs + error budgets), how we
respond when it breaks (incident response + on-call), and the per-symptom
runbooks. It is the operational half of the **operationally-ready** bar
(`marketability-readiness.md` Bar 6); the customer-facing half is
[`status-sla.md`](status-sla.md).

---

## 1. Service Level Objectives & error budgets

An SLO is a target + a measurement window + an error budget (the allowed
unavailability). The error budget governs release pace: **budget remaining →
ship; budget exhausted → freeze features, spend the budget on reliability.**

| SLO | Target | Window | Error budget | Status |
|---|---|---|---|---|
| **API availability** (2xx/3xx + intended 4xx, excl. 5xx) | **99.9 %** `(TARGET)` | 30-day rolling | 43m 12s / 30d | TARGET — needs C7 uptime probe live |
| **Warm read latency** p95 | **≤ 5 ms** | 30-day | 0.1 % > 5 ms | **measured 2.4 ms** (`artifacts/bench/capacity-essential.json`) — within target |
| **Write latency** p99 | **≤ 750 ms** `(TARGET)` | 30-day | 1 % > 750 ms | TARGET — write-tail is the named enemy (583 ms warm single-tenant measured; at-scale not yet published) |
| **Multi-tenant density** (pools ⊥ tenants) | 1 pool / 0 idle | continuous | 0 regressions | **measured/gated** (m46; 24,887-tenant at-rest) |
| **Provisioning success** | **≥ 99 %** `(TARGET)` | 7-day | 1 % | TARGET — seed path is Argon2id-bound at 100K (`scale-slo.md` §4) |

**Error-budget policy (the release brake):**

1. **> 50 % budget remaining** — normal feature velocity.
2. **10–50 % remaining** — reliability work prioritized over new features; every
   change ships behind a flag OFF by default (already the kernel default).
3. **< 10 % remaining / exhausted** — **feature freeze.** Only reliability,
   rollback, and incident fixes land until the window rolls over.

> The budget is only enforceable once the C7 uptime probe writes real numbers
> (see [`status-sla.md`](status-sla.md) §"status page reads real uptime"). Until
> then the policy is documented but unmetered — **this is the open C7 gate.**

---

## 2. Severity ladder

| Sev | Definition | Examples | Page? | Target ack |
|---|---|---|---|---|
| **SEV1** | Platform-wide outage or data-loss risk | all-tenant 5xx, Postgres down, auth issuer broken (every request 401s) | **yes, immediate** | 5 min `(TARGET)` |
| **SEV2** | Major degradation, single plane | data plane 5xx spike, realtime down, one engine adapter unreachable | yes | 15 min `(TARGET)` |
| **SEV3** | Minor / single-tenant / degraded-not-down | one tenant 402 quota dispute, elevated p99, non-critical job backlog | next business hour | 1 business day |
| **SEV4** | Cosmetic / no customer impact | dashboard typo, noisy non-actionable alert | backlog | — |

---

## 3. Incident response (the loop)

```
DETECT ─► TRIAGE (assign sev + IC) ─► MITIGATE (stop the bleeding) ─►
          COMMUNICATE (status page + customers) ─► RESOLVE ─► POSTMORTEM (blameless)
```

- **Detect:** alert (Prometheus rule), customer report, or status-probe failure.
- **Triage:** the on-call **Incident Commander (IC)** assigns severity, opens an
  incident channel, and starts the timeline. One IC owns the incident; everyone
  else is a responder.
- **Mitigate first, root-cause later.** Prefer the reversible lever:
  - roll back the last deploy (`helm rollback grobase` / re-up the prior image),
  - flip a feature flag **OFF** (every behaviour change is flag-gated OFF by
    default — that is the kill switch),
  - shed load (rate-limit at Kong / scale the data plane via HPA).
- **Communicate:** post to the status page within the sev's target; update on a
  fixed cadence (SEV1 every 30 min) until resolved.
- **Postmortem:** **blameless**, within 5 business days for SEV1/2. Output:
  timeline, root cause, the reliability action items (each a tracked task), and —
  if an SLA was breached — the uptime-credit calc handed to billing (D4.9).

### Communication templates
- **Investigating:** "We are investigating elevated error rates affecting
  `<surface>`. Next update in `<N>` min."
- **Identified:** "We have identified the cause (`<one line>`) and are applying a
  fix."
- **Resolved:** "Resolved at `<UTC>`. A postmortem will follow within
  `<N>` business days."

---

## 4. On-call

- **Rotation:** weekly primary + secondary `(TARGET — needs a support org, see
  the plan's "human atoms")`. Primary acks the page; secondary is escalation.
- **Escalation:** primary → secondary (no ack in target) → engineering lead.
- **Handoff:** end-of-rotation handoff note — open incidents, watched alerts,
  error-budget state.
- **Hygiene:** every page must be **actionable**. A page that fires with no
  operator action is a defect → tune or delete the alert in the postmortem.

> A real 24×7 rotation requires staffing this project does not yet have. This
> section is the **process**; standing it up is a tracked human atom (plan §
> "Humans-only").

---

## 5. Runbook index (per symptom)

Each runbook: **symptom → probe → mitigation → escalation.** Probes assume the
compose stack; the K8s equivalents are `kubectl … exec`/`logs`/`port-forward`.

### R1 — All requests 5xx / platform down (SEV1)
- **Probe:** `make healthcheck`; `docker compose ps`; Kong reachable?
  `curl -fsS http://127.0.0.1:8000/` ; Postgres? `docker exec mini-baas-postgres pg_isready`.
- **Mitigate:** if a recent deploy → roll back (`helm rollback grobase` or re-up
  prior image tag). If Postgres down → restart; if disk-full → free PVC space.
- **Escalate:** data-loss risk → IC declares SEV1, page secondary immediately.

### R2 — Auth: every authenticated request 401s (SEV1)
- **Cause class:** JWT issuer / JWKS drift (the RS256 flip risk — see
  `security-residuals-runbook.md` G-RS256).
- **Probe:** `curl -fsS https://<host>/api/auth/availability` (the auth gateway
  has **no** `/health` — this is the probe); check GoTrue + Kong agree on the
  signing key.
- **Mitigate:** revert the issuer change / restore the prior JWKS; auth flips are
  **not** flag-gated to parity, so rollback is the lever.

### R3 — Data plane 5xx spike, auth fine (SEV2)
- **Probe:** `curl -s http://127.0.0.1:4011/metrics | grep -E 'baas_data_plane_(pools_open|pool_connections|requests)'`;
  data-plane logs (`RUST_LOG`); adapter-registry reachable?
- **Mitigate:** scale the data plane (HPA, or `replicas`); check a per-tenant
  mount engine is not down (one bad adapter ≠ platform down). If pool exhaustion
  → consider the C1 pooler overlay (`scripts/scale/POOLER.md`).
- **Known wedge:** after a data-plane recreate, tenant-control can hold a stale
  IP and 503 provisioning until `docker restart mini-baas-tenant-control`
  (`memory/project-baas-scale-program`).

### R4 — Latency / p99 regression (SEV2/3)
- **Probe:** compare `make bench-capacity` to the baseline
  (`artifacts/bench/capacity-essential.json`); check CPU saturation
  (HPA at max?), and write-tail (`outbox` backlog).
- **Mitigate:** scale out (HPA max up); if write-tail → check the batched outbox
  is draining; shed load at Kong if saturated.

### R5 — Tenant 402 (quota) dispute (SEV3)
- **Probe:** `GET /v1/tenants/{id}/usage` (metering) vs the tier quota in
  `config/packages/packages.json`; confirm `QUOTA_ENFORCEMENT` is intentionally on.
- **Mitigate:** if a metering bug over-counted → correct the counter; if a
  legitimate overage → upgrade plan or grant a temporary quota bump. Never edit a
  counter without an audit trail (D3a once live).

### R6 — Realtime down / events not delivering (SEV2)
- **Probe:** realtime `/health` (`/app/realtime-server --healthcheck`); outbox
  relay draining? `baas_*` on the relay; is `REALTIME_PUBLISH_URL` set?
- **Mitigate:** restart realtime; presence is per-node today (cross-node is
  Track E2) so a single-node restart drops presence — expected.

### R7 — Backup / restore (per-tenant) (SEV2/3)
- **Probe:** `POST /v1/tenants/{id}/backup` + `/restore/{id}` (B6, flag
  `TENANT_BACKUP_ENABLED`); check the backup artifact exists + checksum.
- **Mitigate:** B6 is logical per-tenant (schema-per-tenant MVP). **PITR /
  restore-to-timestamp is C4b — not yet shipped**; do NOT promise point-in-time
  recovery until C4b gates.
- **DR escalation:** full-cluster DR with stated RTO/RPO is **C4** and is only
  honest **with** C4b WAL archiving — see `status-sla.md` §DR.

### R8 — Disk / storage pressure (SEV2)
- **Probe:** PVC usage (`kubectl get pvc` / `docker system df`); WAL growth on
  Postgres; **all Docker work lives on `/mnt/storage`** (`memory/feedback-docker-on-big-disk`).
- **Mitigate:** expand the PVC; vacuum/checkpoint; archive + prune old backups.

---

## 6. What is honestly NOT operational yet

- **No live uptime measurement** → the availability SLO + error budget are
  documented but unmetered (the open **C7 gate**: status page must read a real
  probe — `status-sla.md`).
- **No stated, drilled RTO/RPO** → **C4** (HA swap + DR drill), honest only WITH
  **C4b** PITR. Do not publish an RTO/RPO number until the failover drill runs.
- **No 24×7 on-call rotation staffed** → §4 is process, not a staffed roster.
- **100K load p99 not measured on a quiet node** → `scripts/scale/load-100k.sh`
  is the on-demand harness; not a CI gate (`scale-slo.md` §5).

Each line above is a tracked Track-C/D item; none is claimed as done.
