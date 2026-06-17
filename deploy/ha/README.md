# Grobase HA — the supported high-availability architecture (HONEST)

> **What "SLA-backable" means here.** This document does **not** quote an
> availability percentage, a failover RTO, or an RPO. Those are *measured*
> numbers, and Grobase has not yet run the real-infra drills that earn them (see
> [§6 Pending measurement](#6-pending-measurement-the-numbers-not-yet-earned)).
> What this document *does* do is enumerate the availability properties Grobase
> **can** back today, **each mapped to a green gate or to an honest delegation**,
> plus the **exact procedure** to turn the still-pending numbers into measured
> ones. A claim without an artifact is not in this plan.

The chart this builds on is the production Helm chart at
[`../helm/grobase`](../helm/grobase); the one-command go-live runbook is
[`../go-live/README.md`](../go-live/README.md).

---

## 1. The availability matrix — property → proof

| Availability property | How Grobase provides it | Proof (gate / artifact / this change) | Honest limit |
|---|---|---|---|
| **Read-availability during primary degradation** | Pure reads (`op=list`) on a mount carrying a read-replica DSN are served from the replica's own pool when `DATA_PLANE_READ_REPLICA` is ON; writes & flag-OFF reads stay on the primary | Gate [`m122-read-replica-routing.sh`](../../scripts/verify/m122-read-replica-routing.sh) (routing decision proven via two scratch PGs with divergent sentinels) | m122 proves the **routing mechanism only** — *not* streaming replication, replication-lag SLOs, or latency-under-lag (those need a real WAL stream → infra) |
| **Zero-downtime app deploys** (image/env change) | Stateless Deployments roll **surge-then-drain**: `maxUnavailable: 0` + `maxSurge: 1`, gated by the per-plane readiness probes already declared in the chart | **This change** — `deployStrategy` in [`../helm/grobase/values.yaml`](../helm/grobase/values.yaml); visible in `helm template grobase ../helm/grobase` (a `strategy:` block on every `kind: Deployment`, none on StatefulSets) | App-layer only; a Postgres image/version change is **not** zero-downtime (single-primary StatefulSet — see write-failover row) |
| **Survives a node drain / cluster upgrade** | PodDisruptionBudget (`minAvailable: 1`) per multi-replica stateless plane caps voluntary eviction so a drain never removes the last replica | **This change** — `podDisruptionBudget` in values + [`../helm/grobase/templates/pdb.yaml`](../helm/grobase/templates/pdb.yaml); `helm template … --set podDisruptionBudget.enabled=true` renders 5 PDBs | OFF by default (baseline byte-parity); needs an enforcing cluster; PDB protects **voluntary** disruption only, not a node crash |
| **Recovery / point-in-time recovery (PITR)** | WAL archiving (`archive_mode=on` → artifact store) + `pitr-restore.sh` rebuilds a fresh PGDATA and replays WAL to a `--target-time` | Gate [`m99-pitr-restore.sh`](../../scripts/verify/m99-pitr-restore.sh) (flag `PG_BACKUP_PITR`, restore-to-timestamp proven) | A restore is **recovery, not failover** — it has a real RTO measured per dataset size, not an instantaneous cutover |
| **Logical backup / restore** | Whole-cluster `pg_dump` → store + `pg_restore`; per-tenant scoped backup/restore (B6) | Gate [`m87-per-tenant-backup.sh`](../../scripts/verify/m87-per-tenant-backup.sh) (one tenant backup/restore, restore of A can never touch B) + m47 cluster restore-drill | Logical backup RTO grows with data size; for low-RTO recovery prefer PITR (m99) over a cold logical restore |
| **Multi-node rate-limit correctness** | N data-plane replicas draw from **one** shared Redis bucket — a tenant cannot burst its tier once per replica | Gate [`m51-multinode.sh`](../../scripts/verify/m51-multinode.sh) (two limiter instances on one Redis admit ≈ the burst, not 2×) | Redis itself is a single StatefulSet here; Redis HA (Sentinel/Cluster) is its own infra concern, not yet gated |
| **Connection-pool economics under scale** | The Rust PG adapter dials a transaction-mode pooler (supavisor/pgbouncer) when `DATA_PLANE_POOLER_URL` is set, returning row-identical results while per-request RLS GUCs survive the pooled checkout | Gate [`m98-pooler-parity.sh`](../../scripts/verify/m98-pooler-parity.sh) + overlay [`docker-compose.pooler.yml`](../../docker-compose.pooler.yml) | Parity proven; the pooler's *own* HA (it is one more process to make redundant) is an operator concern |
| **WRITE / PRIMARY failover** | **DELEGATED** to a managed-Postgres HA layer (RDS Multi-AZ / Cloud SQL HA / Patroni / CloudNativePG) — see [§3](#3-writeprimary-failover-is-delegated-on-purpose) | The delegation is the proof: the app proxy is *correctly* not in this path | **The app must NOT fake write-failover** — sqlx pools open lazily and retrying a write on a standby risks a double-write. This is a designed boundary, not a gap. |

### Density / latency context (the cost side of the SLA)

These are not availability numbers, but they are the **measured** facts a buyer
weighs against an SLA price:

- Read **p95 = 2.20 ms** (and p50 1.63 ms) — same `GET` against Grobase and
  Supabase PostgREST: [`../../artifacts/bench/grobase-vs-supabase.json`](../../artifacts/bench/grobase-vs-supabase.json).
- Footprint **essential = 821.7 MiB** total RSS vs **Supabase 2884 MiB**:
  [`../../artifacts/footprint-essential.json`](../../artifacts/footprint-essential.json)
  + the supabase RSS in the vs-supabase artifact above.
- **24,887 live tenants held by a 2.6 MiB data plane**, 0 standing pools at rest:
  [`../../artifacts/scale/footprint-live-24887.json`](../../artifacts/scale/footprint-live-24887.json)
  (strengthens the gated 10K headline `m46-share-pools-isolation.sh`).

---

## 2. Zero-downtime app deploys — how the rollout works

The five stateless planes (`data-plane-router-rust`, `tenant-control`,
`adapter-registry-go`, `realtime`, `kong`) are `kind: Deployment`. The chart now
gives every Deployment a **surge-then-drain** rollout:

```yaml
# deploy/helm/grobase/values.yaml  (default — safe, on)
deployStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0     # never drop a Ready pod before its replacement is Ready
    maxSurge: 1           # bring one extra pod up first
```

Why this is zero-downtime for app changes:

1. `maxSurge: 1` starts a **new** pod (new image/env) **before** any old pod is
   touched, so total capacity never dips below the desired count.
2. The new pod only joins the Service's Endpoints once its **readiness probe**
   passes (each plane already declares one in `values.yaml` — e.g.
   `data-plane-router --healthcheck`, `kong health`).
3. `maxUnavailable: 0` forbids Kubernetes from terminating an old Ready pod until
   the replacement is Ready — there is **always** at least the desired number of
   serving pods.

Net effect: a `helm upgrade` that changes an image tag or a ConfigMap value rolls
pods one-at-a-time with **continuous serving capacity** — no window where the
plane has zero Ready pods.

**Scope limits, stated plainly:**

- StatefulSets (`postgres`, `redis`) deliberately keep K8s's **ordered, default**
  `updateStrategy` — they are not in `deployStrategy`. A Postgres
  version/image change is **not** zero-downtime on the single-primary in-chart
  StatefulSet; that is the [write-failover delegation](#3-writeprimary-failover-is-delegated-on-purpose).
- Zero-downtime assumes **≥2 replicas** of the plane (the chart defaults
  `data-plane`, `tenant-control`, `adapter-registry`, `realtime`, `kong` to 2).
  With 1 replica, surge still avoids a gap *if the node can hold 2 pods briefly*,
  but you lose the redundancy a real SLA needs — keep `replicas ≥ 2`.
- For **voluntary node disruption** (drains/upgrades), also turn on the
  PodDisruptionBudget: `--set podDisruptionBudget.enabled=true` (off by default to
  keep the committed baseline byte-identical). It renders one PDB
  (`minAvailable: 1`) per multi-replica stateless plane.

A canary/blue-green path, if desired, is expressed as **documented values**
(image tag / replica weights across two releases), not new infra — run a second
release `grobase-canary` with a smaller replica count and shift Ingress/Service
weight; converge by bumping the stable release's tag. Nothing in the chart
hard-codes a single-color assumption.

---

## 3. WRITE / PRIMARY failover is DELEGATED (on purpose)

**The app proxy must never fake write-failover.** Two hard reasons:

1. The Rust data plane opens `sqlx` pools **lazily** and per-request. There is no
   safe, generic way for the proxy to know a write committed on a primary that
   then died — **retrying that write against a standby risks a double-write**.
2. Correct write-failover requires consensus/quorum (who is the new primary?),
   fencing the old primary, and promoting a replica with a known WAL position.
   That is exactly what a managed-Postgres HA control loop does — and what a
   stateless query proxy is structurally the wrong place to do.

So primary/write HA is delegated to a **managed-Postgres HA endpoint**. The chart
makes this a one-flag boundary:

```yaml
# Point Grobase at external managed HA Postgres (RDS Multi-AZ / Cloud SQL HA /
# Patroni / CloudNativePG). The in-chart single-primary StatefulSet is dropped.
planes:
  postgres:
    enabled: false                       # do NOT render the in-chart StatefulSet
```

…and supply the external DSN to the planes. `DATABASE_URL` is the single env key
every control/data-plane service reads for the primary (compose default
`postgres://postgres:postgres@postgres:5432/postgres`). In the chart it lives in
the release ConfigMap/Secret, **not** baked into the chart:

```sh
# The external HA endpoint is the writer/cluster endpoint your provider gives you,
# e.g. an RDS cluster endpoint, a Cloud SQL HA IP, or a Patroni/PgBouncer VIP that
# always points at the CURRENT primary. Put it in the SECRET (it carries a
# password), or via Vault-CSI in prod:
helm -n grobase upgrade --install grobase ../helm/grobase \
  --set planes.postgres.enabled=false \
  --set env.secret.create=true \
  --set env.secret.data.DATABASE_URL='postgresql://USER:PASS@my-rds-cluster.xxxxx.eu-west-1.rds.amazonaws.com:5432/postgres?sslmode=require'
```

| Provider | What handles write-failover | The endpoint to point `DATABASE_URL` at |
|---|---|---|
| **AWS RDS / Aurora** | Multi-AZ automatic failover | the **cluster writer endpoint** (always resolves to the current primary) |
| **GCP Cloud SQL** | HA (regional) automatic failover | the HA primary IP / private service connect endpoint |
| **Self-managed Patroni** | etcd/Consul-backed leader election + promotion | the Patroni REST/HAProxy "leader" endpoint (or PgBouncer in front of it) |
| **CloudNativePG (in-cluster operator)** | operator-driven promotion | the operator's `-rw` (read-write) Service |

The point: a request that hits the writer endpoint mid-failover gets a brief
connection error and **retries to the now-promoted primary** — the *provider*
owns the cutover semantics (fencing, WAL position, RTO/RPO). Grobase's job is to
(a) route reads to a replica when one is configured (m122) and (b) not invent a
failover it cannot do safely.

> **Read replicas vs. write failover are different features.** m122 gives you
> *read*-availability by routing reads to a replica DSN. It does **not** promote a
> replica to primary — that is this delegated layer's job. Configure both: the
> writer endpoint as `DATABASE_URL`, and a reader endpoint as the mount's
> read-replica DSN with `DATA_PLANE_READ_REPLICA` ON.

---

## 4. Multi-node correctness (why N replicas stay correct)

Scaling the stateless planes horizontally is only safe because correctness is
**per-request**, not **per-pool/per-node**:

- **Rate limiting** is authoritative across replicas via a shared Redis bucket —
  proven by [`m51-multinode.sh`](../../scripts/verify/m51-multinode.sh). N data
  planes do not multiply a tenant's allowance.
- **Tenant isolation** (owner-scope / RLS) is applied on every request, so
  collapsing many tenants onto a shared pool — and many requests across many pods
  — preserves isolation regardless of which pod served the request (the
  `SHARE_POOLS` design; `m46`).
- **Connection economics** under a pooler are parity-proven —
  [`m98-pooler-parity.sh`](../../scripts/verify/m98-pooler-parity.sh) — and the
  per-request RLS GUCs survive a transaction-mode pooled checkout.

Caveat carried honestly: **realtime presence is per-node** until cross-node
broadcast (Track E2) lands — that is why `planes.realtime.autoscaling.enabled` is
`false` in the chart. Scale realtime manually and pin client affinity until E2.

---

## 5. Deploy + rollback (one page)

Cross-references the one-command runbook [`../go-live/go-live.sh`](../go-live/go-live.sh)
(DRY-RUN by default; `GO_LIVE_APPLY=1` to apply). The zero-downtime strategy +
PDBs above make each of these steps non-disruptive.

```sh
# 0. PREVIEW — renders the chart offline, validates, applies NOTHING
bash ../go-live/go-live.sh

# 1. DEPLOY / UPGRADE (idempotent, atomic, zero-downtime rollout)
#    helm upgrade --install --atomic --timeout 10m  (go-live.sh does exactly this)
GO_LIVE_APPLY=1 bash ../go-live/go-live.sh
#    For HA clusters also enable PDBs so node drains never evict the last replica:
#      ... --set podDisruptionBudget.enabled=true

# 2. WATCH the rollout (each plane rolls surge-then-drain; capacity never dips)
kubectl -n grobase rollout status deploy/grobase-data-plane-router-rust
kubectl -n grobase rollout status deploy/grobase-kong

# 3. SMOKE (go-live.sh runs this on apply): edge reachable over TLS,
#    /v1/tenants/me wired + protected (401 without a key == correct)

# 4. ROLLBACK — one command (go-live.sh prints the exact PRIOR_REV line)
KUBECONFIG=$KUBECONFIG helm -n grobase rollback grobase <PRIOR_REV>
#    A FAILED `helm upgrade --atomic` auto-rolls-back already (cluster unchanged).
#    To revert cloud features to OFF (byte-parity): rollback to the pre-go-live rev.
```

| Situation | Action |
|---|---|
| Bad release / error spike after upgrade | `helm -n grobase rollback grobase <PRIOR_REV>` (printed by `go-live.sh`) |
| `helm upgrade` itself failed | already auto-rolled-back by `--atomic` |
| Need cloud features fully OFF | `helm rollback` to the pre-go-live revision (flags → OFF = byte-parity) |
| Node maintenance | drain with PDBs enabled → eviction respects `minAvailable: 1` |
| Postgres primary failure | handled by the **managed-PG HA layer** ([§3](#3-writeprimary-failover-is-delegated-on-purpose)), not by helm |

---

## 6. Pending measurement (the numbers NOT yet earned)

These require **real infrastructure** Grobase has not stood up, so they are
deliberately left as PENDING rather than invented. Each has an exact drill to
earn it.

| Number | Why it's not claimed | Drill that would earn it |
|---|---|---|
| **Availability %** (e.g. "99.9%") | Needs a long-running uptime probe against live infra; not measured | Run a black-box uptime probe (e.g. blackbox-exporter / synthetic `GET /v1/tenants/me` → 401) against `$GO_LIVE_DOMAIN` for **≥ 30 days**; availability % = (successful probe windows ÷ total). Publish the artifact + the probe config. |
| **Failover RTO** (write-path) | Needs a real managed-PG HA endpoint and a forced-failover drill; not measured | On the managed-PG provider, **force a primary failover** (RDS `reboot --force-failover` / Cloud SQL failover / `patronictl switchover`) while a write workload runs; measure wall-clock from last successful write to first successful write post-promotion. Repeat ≥3× for a distribution, not a single sample. |
| **RPO** (write-path) | Needs the same drill + transaction-level verification; not measured | During the same forced-failover, record the last committed transaction before the cut and the first replayed transaction after; RPO = data-loss window. For synchronous-replication configs this should be 0 — **measure it, don't assume it.** |
| **Recovery RTO (PITR)** | m99 proves the mechanism; the *time* depends on dataset size + WAL volume on real infra | Run `pitr-restore.sh` against a production-sized snapshot + WAL archive; record wall-clock to a usable PGDATA at `--target-time`. Publish per-data-size. |
| **100K-tenant load** | The 10K headline (m46) + 24,887 at-rest fleet are measured; 100K under load is not | Run the 100K harness on a **quiet, dedicated node** (the box used for the 24,887 capture is Chrome/CPU-contended); publish to `artifacts/scale/`. |

**Until these artifacts exist, an SLA built on this architecture should quote the
*delegated* provider's published HA SLA for the write path** (e.g. RDS Multi-AZ's
SLA), and state Grobase's own app-tier availability as "pending a ≥30-day uptime
probe" — honestly, with the drill above as the path to a real number.

---

## 7. Files in this slice

| File | What changed |
|---|---|
| [`../helm/grobase/values.yaml`](../helm/grobase/values.yaml) | added `deployStrategy` (RollingUpdate maxUnavailable:0 / maxSurge:1, the zero-downtime default) + `podDisruptionBudget` (off by default) |
| [`../helm/grobase/templates/workloads.yaml`](../helm/grobase/templates/workloads.yaml) | renders `strategy:` on `kind: Deployment` planes only (per-plane override honored; StatefulSets untouched) |
| [`../helm/grobase/templates/pdb.yaml`](../helm/grobase/templates/pdb.yaml) | **new** — one PDB per multi-replica stateless Deployment when `podDisruptionBudget.enabled=true` |
| this file | the honest HA architecture + property→proof matrix + pending-measurement drills |

Validated: `helm lint` clean (default + `values-dev.yaml`); `helm template`
renders valid YAML with a `strategy:` block on all 5 Deployment planes and none on
the 2 StatefulSets; PDBs render 5 (stateless) when enabled, 0 by default.
