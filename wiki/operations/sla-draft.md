# Grobase Managed Cloud — Service Level Agreement (DRAFT)

> **Status: DRAFT — not a binding contract.** This document is a *template* for a
> commercial SLA. Sections marked **PROVEN** are backed today by a measured artifact
> and a reproducing gate (cited inline). Sections marked **PENDING measurement** are
> structurally complete but carry **no committed number**, because the number does not
> yet exist as a measurement. **An SLA you cannot measure is dishonest** — so this draft
> refuses to print an availability %, an RTO, or an RPO we have not run. The PENDING atom
> (the exact run that would unblock the number) is named in each case.
>
> Before this becomes a customer-facing contract it requires: (a) the PENDING measurements
> below, and (b) legal review — the remedy/credit and liability language here is a
> placeholder template, **not** lawyer-reviewed.
>
> Discipline (binding): *measured, not claimed*; *honest, not certified*; flag-gated
> features stay OFF in the committed baseline (byte-parity). See
> `apps/baas/.claude/CLAUDE.md` §2.1.

Last reviewed: 2026-06-15 · Applies to: **Grobase Managed Cloud** (the hosted product).
The OSS self-host edition carries **no SLA** — you operate it; these commitments are for
the managed offering only.

---

## 1. What we will and will not commit to today

We split every clause into two buckets and never blur them:

| Bucket | Meaning | Where it appears |
|---|---|---|
| **PROVEN** | A measured artifact, a green gate, or a deployed mechanism backs the commitment. We commit to it. | §3 (Performance), §4 (Density), §5 (Footprint), §5b (Zero-downtime deploys) |
| **PENDING measurement** | The clause is real and the structure is here, but the number is not yet measured. **We commit to nothing until the named run exists.** | §6 (Availability), §7 (RTO/RPO/DR) |

This boundary is the whole point of the document. A latency p95 we have measured under
load is a promise we can keep and verify. An uptime % we have **not** measured (no
real-infra failover run exists; the 100K-tenant load figure is *projected*, not run)
would be a number invented to look good in a sales deck — so it stays PENDING.

---

## 2. Tier coverage (which plan gets which SLA)

SLA strength is keyed to the service tier. Tiers are defined once in
`config/packages/packages.json` (the single source of truth; the control plane embeds a
byte-identical copy, asserted by gate m28). The performance ceilings below are the
*advertised* per-request limits from that file — themselves derived from measurement
(`artifacts/bench/capacity-essential.json`: a single mount sustains ~400 rps of reads at
p95 < 2 ms before the connection-pool cliff; advertised rps = floor(ceiling × fair_share × 0.5)).

| Tier (packages.json) | Advertised rps / burst | Performance SLA (§3) | Availability SLA (§6) | DR / backup (§7) | Support target |
|---|---|---|---|---|---|
| **nano** (alias `free`) | 50 / 100 | best-effort, **no SLA** | none | none (single-binary, self-managed data) | community |
| **basic** | 100 / 200 | best-effort, **no SLA** | none | best-effort | community |
| **essential** | 200 / 400 | **PROVEN** p95 read target (§3) | PENDING — *standard* tier on the SLO ladder | PENDING (RPO/RTO templates, §7) | business-hours |
| **pro** | 400 / 800 | **PROVEN** p95 read target (§3) | PENDING — *standard* tier | PENDING (§7) | business-hours |
| **max** (alias `enterprise`) | 800 / 1600 | **PROVEN** p95 read target (§3) | PENDING — *premium* tier (highest target once measured) | PENDING (§7, premium RPO/RTO) | priority / named contact |

> The two availability "ladder" labels (*standard* / *premium*) are committed structure;
> the **numbers attached to them remain PENDING** until §6 is measured. We do not ship a
> tier with a printed uptime number ahead of the run that proves it.

---

## 3. Performance SLA — **PROVEN**

These are committed for **essential / pro / max** managed tenants. The numbers come from a
load run, not a brochure.

| Clause | Committed target | Measured value (artifact) |
|---|---|---|
| **Read latency (p50)** | ≤ 5 ms (gateway read, warm) | **1.63 ms** measured — `artifacts/bench/grobase-vs-supabase.json` (n=60, same `GET /rest/v1` against both stacks) |
| **Read latency (p95)** | ≤ 10 ms (gateway read, warm) | **2.20 ms** measured — `artifacts/bench/grobase-vs-supabase.json`; corroborated by the essential CRUD `list` op p95 **2.19 ms** in `artifacts/bench/load-essential-crud.json` (median of 3×60 s runs @ 20 rps, 0 server errors) |
| **CRUD error rate** | ≤ 0.5 % over a rolling 5 min window | **0.00 %** server errors across all three essential CRUD runs — `artifacts/bench/load-essential-crud.json` (`server_errors: 0`, `err_pct: 0`) |
| **Sustained read capacity (single mount)** | per-tier advertised rps (table §2) | single mount sustains **400 rps** at p95 < 2 ms before the pool cliff — `artifacts/bench/capacity-essential.json` (`max_sustained_rps: 400`, `slo_p95_ms: 50`) |

**Honest carve-out — the write tail.** The committed latency targets above are for the
**read** path. The **write** path has a measured tail we will not hide: essential CRUD
`insert` p99 reaches **~56 ms** and `delete` p99 **~69 ms** in
`artifacts/bench/load-essential-crud.json` (outbox/relay tail, tracked as D-write-tail).
Until a write-path SLO is separately measured under sustained write load, **writes are
explicitly excluded from the latency commitment** and served best-effort. We name the
enemy rather than averaging it away.

Reproduce: `make -C apps/baas/mini-baas-infra bench-load` and `bench-capacity`.

---

## 4. Multi-tenant isolation & density — **PROVEN**

Relevant to an SLA because it bounds the *noisy-neighbour* failure mode: one tenant's load
cannot exhaust another's resources, by construction.

| Clause | Committed property | Proof |
|---|---|---|
| **Per-request owner-scoping / RLS** | Tenant data isolation is enforced per request, not by pool state | gate **m46** — `scripts/verify/m46-share-pools-isolation.sh` (SHARE_POOLS=1 → isolation holds + pools collapse; =0 → byte-identical) |
| **Pool count independent of tenant count** | 10K tenants collapse to **1 shared pool**, **0× 5xx** under load | gate **m46**; `artifacts/bench/multitenant-10000-sharepools.json` (`server_errors: 0`, 9,775 tenants, zipf) |
| **At-rest density** | A ~25K-tenant fleet imposes no standing memory cost beyond the binary | **24,887 live tenants** held by a **2.6 MiB** data plane with **0 standing pools** — `artifacts/scale/footprint-live-24887.json` |

> **Honest note on the 100K headline:** any figure above the measured ~25K at-rest /
> 10K-under-load fleet is **PROJECTED, not run**. We do not state a 100K SLA. See §6.

---

## 5. Footprint moat — **PROVEN** (informational, not a runtime SLA clause)

Not an availability promise, but a measured, contractually-honest efficiency statement.

| Clause | Measured value (artifact) |
|---|---|
| **Footprint vs Supabase (same box)** | Grobase `essential` **821.7 MiB** vs Supabase **2884 MiB** = **3.5× lighter** (lean `basic` **309.8 MiB** = 9.3× lighter) — gate **m32-footprint.sh** / `make bench-footprint`; per-service RSS summed in `artifacts/footprint-essential.json` / `artifacts/footprint-basic.json`; Supabase 2884 MiB RSS independently captured in `artifacts/bench/grobase-vs-supabase.json` + `artifacts/bench/supabase-footprint-breakdown.txt` (per-container RSS). |
| **Per-edition RAM (running)** | essential **821.7 MiB**, pro **1188.4 MiB**, max **3634.0 MiB** — `artifacts/footprint-essential.json` / `footprint-pro.json` / `footprint-max.json` |
| **Nano single-binary idle** | ~2.0 MiB idle / ~5.1 MB image — `artifacts/nano-vs-pocketbase.json` |

---

## 5b. Zero-downtime deploys — **PROVEN** (deploy-availability, distinct from node-loss failover)

A routine release does **not** drop traffic. This is *deploy*-availability — the part of the
availability story that does not depend on the unmeasured node-loss failover number in §6, so we
commit it today.

| Clause | Committed property | Proof |
|---|---|---|
| **Rolling deploys serve continuously** | A version rollout drains and replaces pods one at a time, gating each new pod on readiness before traffic, with no full-fleet outage window | Helm workloads are stateless `Deployment`s with **≥2 replicas** (data plane `replicas: 2` + HPA `minReplicas: 2`, `deploy/helm/grobase/values.yaml`) and **readiness + liveness probes** (`deploy/helm/grobase/templates/workloads.yaml`). The chart sets an **explicit `RollingUpdate` strategy (`maxUnavailable: 0` / `maxSurge: 1`)** on the Deployment planes (`deploy/helm/grobase/values.yaml` `deployStrategy`), so a replacement pod is Ready before any running pod is drained (zero capacity dip); an optional PodDisruptionBudget (`minAvailable: 1`) protects rollouts through node drains. |

> **Honest scope.** This commitment covers *planned* rollouts (deploys/restarts), not *unplanned*
> node loss — that is the §6/§7 failover question, which is delegated to the managed-Postgres HA layer
> and remains PENDING a measured drill. The HA architecture, the write-failover delegation, and the
> drills that earn the §6/§7 numbers are documented in `mini-baas-infra/deploy/ha/README.md`.

Reproduce: `helm template deploy/helm/grobase` and inspect the `Deployment` strategy + probes; a live
rollout (`kubectl rollout status`) under load is the operational check.

---

## 6. Availability SLO — **PENDING measurement (no number committed)**

> **We have NOT measured an availability percentage. None is printed here.** The
> structure below is a template; every numeric field is a blank to be filled *only after*
> the named run exists. Publishing 99.9% today would violate "measured, not claimed."

### 6.1 Definition template (structure only)

- **Monthly Uptime Percentage** = (Total minutes in month − Downtime minutes) ÷ Total
  minutes in month × 100, where *Downtime* = a contiguous period in which the managed
  control-plane health endpoint and the data-plane read path both fail external probes.
- **Excluded** from Downtime: scheduled maintenance (announced ≥ 72 h ahead), customer
  misconfiguration, force majeure, and abuse-suspension (gate m120 spend/suspend).

### 6.2 The numbers (all PENDING)

| Tier | Target Monthly Uptime % | Status |
|---|---|---|
| essential / pro (*standard*) | **PENDING measurement** — requires the **managed-PG failover drill + uptime soak in `deploy/ha/README.md`** (the failover *mechanism* is delegated to managed Postgres; what is owed is the timed drill + a ≥30-day uptime probe) | no number committed |
| max (*premium*) | **PENDING measurement** — same drill, premium target | no number committed |

### 6.3 Why it is PENDING (the missing atoms, named)

The availability *architecture* is documented and gate-backed — what is missing is the **measurement**,
not the design. The composition (read-availability `m122`, multi-node shared bucket `m51`, pooler
parity `m98`, PITR `m99`, backup/restore `m47`/`m87`) and the write-failover **delegation** to managed
Postgres are all written up in `deploy/ha/README.md`. The numbers stay PENDING for three reasons:

1. **No timed failover *drill* has been run.** Data-plane *write*-failover is **delegated to the
   managed-Postgres HA layer** (RDS Multi-AZ / Patroni / Cloud SQL HA) — sqlx pools open lazily, so
   retrying a write on a standby risks a double-write; the database is the safe owner of write failover.
   The *mechanism* exists at that layer; what is owed is a **timed drill** (kill the primary mid-load,
   measure recovery + lost writes) — specified in `deploy/ha/README.md`. Read-replica routing (gate
   **m122**) proves the **routing decision only** and *explicitly* excludes streaming replication and
   failover (see the m122 header), so it does not by itself yield a recovery number.
2. **The 100K-tenant figure is projected, not run.** A real availability number under
   target scale needs a **100K load run on a quiet node** (the current 10K-under-load /
   ~25K-at-rest fleet, §4, is the proven envelope).
3. **Service-credit table is therefore blank.** A credit schedule (e.g. < X% → Y% credit)
   is meaningless without a committed target; it is intentionally omitted until §6.2 is
   filled.

### 6.4 How to earn this number (exact — the drill lives in `deploy/ha/README.md`)

```
# Run the managed-PG failover + uptime drills documented in
#   mini-baas-infra/deploy/ha/README.md :
#   1. bring up >=2 data-plane replicas behind the shared global bucket (m51 proves
#      the bucket is already shared across replicas — scripts/verify/m51-multinode.sh)
#      against a managed-PG endpoint that fails a standby over transparently,
#   2. trigger a managed-PG failover mid-load, measure recovery time + lost/dropped
#      writes (this is the RTO/RPO drill in §7),
#   3. run a sustained ≥30-day uptime probe to compute a real Monthly Uptime %.
# THEN run a 100K-tenant load on a quiet node and record artifacts/scale/.
# ONLY THEN fill §6.2.  (These runs are human-triggered, irreversible-class operations;
#  the README PREPARES the drill — it does not run it automatically.)
```

---

## 7. Disaster Recovery — RTO / RPO — **PENDING measurement (no number committed)**

> The backup/restore **mechanism is proven**; the **time/loss objectives are not measured**.
> We commit the mechanism, not a number, until a real-infra DR drill is run.

### 7.1 What is PROVEN (mechanism, not objective)

| Property | Proof |
|---|---|
| Logical backup/restore round-trips with a verified checksum | gate **m47** — `scripts/verify/m47-backup-restore.sh` (`pg_dump -Fc` → recreate → `pg_restore`; row count + md5 checksum must match the seed). The scheduled `pg-backup → MinIO` path reuses the exact same mechanics. |
| Point-in-time recovery (WAL + restore-to-timestamp) mechanism | gate **m99** — `scripts/verify/m99-pitr-restore.sh` (proves WAL-based restore-to-timestamp works; bounds the *mechanism* for a low RPO once a cadence is measured). |
| Per-tenant logical backup/restore exists | Track-B B6, gate **m87** (`TENANT_BACKUP_ENABLED`, migration `042_tenant_backups.sql`) — flag-gated OFF in the committed baseline |
| Per-tenant data export | gate **m109** — `scripts/verify/m109-tenant-export.sh` |
| Read-replica routing decision (NOT replication) | gate **m122** — routing mechanism only; real streaming replication / failover is delegated to managed Postgres (see `deploy/ha/README.md`) and out of scope per the gate's own header |

### 7.2 RTO (Recovery Time Objective) — PENDING

| Tier | Target RTO | Status |
|---|---|---|
| essential / pro | **PENDING measurement — requires the timed DR drill in `deploy/ha/README.md`** (managed-PG failover wall-clock + a timed restore of a production-sized dataset from the `pg-backup → MinIO` path onto a fresh node) | no number committed |
| max (premium) | **PENDING measurement** — same drill, premium target | no number committed |

> We have a *checksum-correct restore mechanism* (m47), a *PITR restore-to-timestamp*
> mechanism (m99), and managed-PG transparent standby promotion for the write path — but
> **no measured wall-clock recovery time** at production data size on managed infra. Until
> the drill in `deploy/ha/README.md` is timed, RTO is blank. Quoting "RTO 1 h" off an
> un-timed mechanism would be invented.

### 7.3 RPO (Recovery Point Objective) — PENDING

| Tier | Target RPO | Status |
|---|---|---|
| essential / pro | **PENDING measurement — requires a measured backup cadence** (scheduled `pg-backup` interval observed in production + the max data-loss window proven by the PITR restore drill in `deploy/ha/README.md`) | no number committed |
| max (premium) | **PENDING measurement** — the PITR *mechanism* exists (gate **m99**, WAL restore-to-timestamp); premium RPO additionally rides the managed-PG synchronous/streaming replication delegated in `deploy/ha/README.md`. Number PENDING the measured drill. | no number committed |

### 7.4 How to earn these numbers (exact — the drills live in `deploy/ha/README.md`)

```
# RTO: time recovery on managed infra at production data size, per deploy/ha/README.md:
#   (a) trigger a managed-PG failover (RDS Multi-AZ / Patroni / Cloud SQL HA) under load,
#       wall-clock until the write path is healthy again; AND
#   (b) pg_restore from the pg-backup MinIO artifact onto a fresh node, wall-clock the
#       recovery; run on >=1 representative tenant fleet (cross-ref §4 density numbers).
# RPO: (a) record the scheduled pg-backup cadence in production; (b) prove the max
#   data-loss window with the PITR restore-to-timestamp drill (mechanism = gate m99) and,
#   for premium RPO, the managed-PG streaming/synchronous replication delegated in
#   deploy/ha/README.md.
# ONLY THEN fill §7.2 / §7.3.  (These runs are human-triggered, irreversible-class
#  operations; deploy/ha/README.md PREPARES the drill — it does not run it automatically.)
```

---

## 8. How each commitment is proven (clause → gate / artifact)

The auditable spine of this draft. **Every PROVEN row cites a real, reproducible source;
every PENDING row names the run that does not yet exist.**

| § | Clause | Status | Gate / Artifact | Reproduce |
|---|---|---|---|---|
| 3 | Read p50 ≤ 5 ms (1.63 ms measured) | PROVEN | `artifacts/bench/grobase-vs-supabase.json` | `make -C apps/baas/mini-baas-infra bench-load` |
| 3 | Read p95 ≤ 10 ms (2.20 / 2.19 ms measured) | PROVEN | `grobase-vs-supabase.json` · `load-essential-crud.json` | `bench-load` |
| 3 | CRUD error rate ≤ 0.5 % (0.00 % measured) | PROVEN | `artifacts/bench/load-essential-crud.json` | `bench-load` |
| 3 | Single-mount read capacity 400 rps | PROVEN | `artifacts/bench/capacity-essential.json` | `make ... bench-capacity` |
| 3 | Write-path latency | EXCLUDED (honest carve-out) | insert/delete p99 in `load-essential-crud.json` | `bench-load` |
| 4 | Per-request isolation / RLS | PROVEN | gate **m46** `m46-share-pools-isolation.sh` | `bash scripts/verify/m46-share-pools-isolation.sh` |
| 4 | 10K tenants → 1 pool, 0× 5xx | PROVEN | gate **m46** · `multitenant-10000-sharepools.json` | m46 |
| 4 | 24,887 tenants @ 2.6 MiB at rest | PROVEN | `artifacts/scale/footprint-live-24887.json` | live probe (see artifact `_comment`) |
| 5 | Footprint 821.7 MiB (essential) / 309.8 MiB (basic) vs Supabase 2884 MiB | PROVEN | gate **m32-footprint.sh** · `artifacts/footprint-essential.json` · `artifacts/footprint-basic.json` · `grobase-vs-supabase.json` · `supabase-footprint-breakdown.txt` | `make bench-footprint` |
| 5b | Zero-downtime (rolling) deploys | PROVEN | helm `Deployment` explicit RollingUpdate `maxUnavailable:0`/`maxSurge:1` + ≥2 replicas + readiness/liveness probes + optional PDB `minAvailable:1` — `deploy/helm/grobase/values.yaml` · `deploy/helm/grobase/templates/workloads.yaml` · `deploy/helm/grobase/templates/pdb.yaml` | `helm template deploy/helm/grobase` (inspect strategy + probes); live `kubectl rollout status` under load |
| 6 | Availability / Monthly Uptime % | **PENDING** | mechanism composed (read-avail `m122`, multi-node `m51`, pooler `m98`) + write-failover delegated to managed PG; no measured number yet | requires the failover + ≥30-day uptime drills in `deploy/ha/README.md` + a 100K quiet-node run |
| 7.1 | Backup/restore round-trip mechanism | PROVEN | gate **m47** `m47-backup-restore.sh`; PITR **m99** `m99-pitr-restore.sh`; B6 gate **m87**; export gate **m109** | `bash scripts/verify/m47-backup-restore.sh` · `bash scripts/verify/m99-pitr-restore.sh` |
| 7.2 | RTO | **PENDING** | restore/failover *mechanism* proven (m47/m99 + managed-PG HA) — no timed drill yet | requires the timed DR drill in `deploy/ha/README.md` |
| 7.3 | RPO | **PENDING** | PITR mechanism proven (m99); managed-PG replication delegated — no measured loss window yet | requires the measured cadence + PITR drill in `deploy/ha/README.md` |

---

## 9. Maintenance, support response, and remedies (TEMPLATE — needs legal review)

- **Scheduled maintenance:** announced ≥ 72 h in advance; excluded from §6 Downtime.
- **Support response targets** (operational, not contractual until reviewed): nano/basic =
  community; essential/pro = next business day; max = priority / named contact.
- **Service credits:** **TEMPLATE — intentionally blank.** A credit schedule cannot be
  written before §6 commits a target (see §6.3). Sample structure to be completed by legal
  once §6 is measured:

  | Monthly Uptime below target | Credit (% of monthly fee) |
  |---|---|
  | PENDING | PENDING |

- **Liability / warranty / governing law:** **TEMPLATE — placeholder, requires a lawyer.**
  Nothing in this draft is a legal commitment.

---

## 10. Honesty ledger (what this draft deliberately does NOT claim)

1. **No availability % is printed anywhere.** Not 99.9, not 99.95 — none, because none is
   measured (§6).
2. **No RTO/RPO number is printed.** The restore/PITR *mechanism* is proven (m47/m99) and
   write-failover is delegated to managed Postgres; the *time* and *loss window* are not yet
   measured (§7) — earned by the drills in `deploy/ha/README.md`.
3. **The 100K-tenant figure is projected, not run** — the committed density envelope is the
   measured ~25K-at-rest / 10K-under-load fleet (§4).
4. **m122 is routing, not replication** — we do not claim real streaming replication or
   replication-lag SLOs; write-failover is **delegated** to the managed-Postgres HA layer
   (RDS Multi-AZ / Patroni / Cloud SQL HA), not built into the router (`deploy/ha/README.md`).
   **Zero-downtime *deploy*-availability (§5b) is committed; *node-loss* availability (§6) is not.**
5. **SOC2 posture** (gate **m108**, SOC2-lite) is *"evidence collected, audit-ready,"*
   **never "SOC2 certified."**
6. **Legal/remedy language is a template** needing a lawyer; nothing here binds.

When §6 and §7 are measured (their unblocking atoms run), promote the PENDING rows to
PROVEN with their artifacts and re-date the document.
