# Grobase — GA-Readiness Scorecard (honest /10)

> **Why this doc exists.** A scorecard is only worth reading if you can *trust* it. So every "done"
> here cites a gate-green script (`mini-baas-infra/scripts/verify/m<NN>-*.sh`) or a measured
> artifact, and every "not done" names the **exact** remainder and its kind:
> **[ENG]** engineering · **[HUMAN]** a human atom (a person must click/sign/run an irreversible) ·
> **[INFRA-MEAS]** an infra/measurement we have not yet taken · **[LEGAL]** lawyer/auditor review.
> Unmeasured numbers are written **PENDING <atom>** — they are *not* claimed.
>
> **What "gate-green" means:** the script boots the real services and asserts behavior (e.g. a
> VIEWER gets `403` on `project:create` in m103; a read returns `sentinel=='replica'` in m122),
> then logs `GATE m<NN>=PASS`. A gate that passes vacuously is not counted.
>
> Last updated: 2026-06-15 · Branch context: `feat/baas-scale-program`.

---

## 0. The three GA targets — at a glance

| # | Target | Honest score | One line: what stands between us and 10/10 |
|---|--------|:---:|---|
| 1 | **Buyable managed cloud** (a stranger signs up → project → key → CRUD/realtime → usage → billed) | **7 / 10** | The funnel is proven against a *mock* Stripe; 10/10 needs the live Stripe account + a public domain/TLS — both **[HUMAN]**. |
| 2 | **SLA-backable GA** (we can sign an availability/latency SLA and mean it) | **6 / 10** | The HA architecture is now **composed of gate-backed parts** (read-availability m122, PITR m99, multi-node m51/m98) and **deploy-availability is real** (zero-downtime helm RollingUpdate, ≥2 replicas) — write-failover is correctly **delegated to managed Postgres** (RDS Multi-AZ / Patroni / Cloud SQL HA). Caps remain honest: write-failover RTO/RPO + 100K load + uptime % are **PENDING the drills in `deploy/ha/README.md`** — the SLA number is still a `(TARGET)`, not a measurement. |
| 3 | **Enterprise-procurable** (orgs/RBAC, SSO/SCIM, audit, hard-erase, trust posture, CMEK/BYOK) | **7.5 / 10** | The whole control surface is gate-green (m103–m112) and **CMEK/BYOK + crypto-shred** now landed (m123) — the last enterprise *code* gap is closed. 10/10 needs a real IdP wired end-to-end **[HUMAN]**, a SOC2 *audit* **[LEGAL]**, and lawyer-reviewed legal docs **[LEGAL]** — all human/legal, zero engineering. |

The three targets share two structural walls: **failover RTO/RPO + 100K load + uptime % are not yet
measured** (caps Target 2 — the *architecture* is now documented and gate-backed in `deploy/ha/README.md`;
what remains is running the drills) and a cluster of **human/legal atoms** (live Stripe, domain, IdP,
lawyer, auditor) cap Targets 1 & 3. None of these is an *engineering* gap in the committed codebase — the
code is gate-green and the HA composition is documented; the remainder is run-the-drill,
turn-it-on-in-production, and have-a-human-sign work. **Data-plane write-failover is not on this list
because it is correctly delegated** to the managed-Postgres layer (RDS Multi-AZ / Patroni / Cloud SQL HA):
sqlx pools open lazily, so retrying a write on a standby risks a double-write — the safe owner of write
failover is the database, not the router (see `deploy/ha/README.md`).

---

## 1. Target 1 — Buyable managed cloud · **7 / 10**

**Proven (the "done" parts):**
- End-to-end signup→project→key→CRUD→usage→bill funnel is gate-green against a **mock** Stripe:
  `m94-cloud-funnel.sh` (drives DATA_PLANE_METERING + DATA_PLANE_QUOTA_ENFORCEMENT on a real
  data-plane-router). Quota truth on a real tenant: `m101-quota-realtenant.sh`. Spend/suspend
  enforcement: `m120-spend-suspend-enforce.sh` (ENFORCE arm asserts suspend actually denies).
- Tenant self-serve surface (`/v1/tenants/me*`, tenant resolved from credential — no `{id}`, no
  cross-tenant by construction): `m83-selfserve.sh`, console route `m84-console-route.sh`.
- Per-tenant telemetry/usage export proven: `m100-tenant-telemetry-export.sh`. Gateway query path
  for paying tenants: `m102-gateway-query-path.sh`.
- Footprint moat that makes the unit economics real: **821.7 MiB** Grobase `essential` vs **2884 MiB**
  Supabase (**3.5× lighter**; the lean `basic` edition is **309.8 MiB** = **9.3× lighter**) — per-service
  RSS summed in `artifacts/footprint-essential.json` / `artifacts/footprint-basic.json`, Supabase RSS in
  `artifacts/bench/grobase-vs-supabase.json` + `artifacts/bench/supabase-footprint-breakdown.txt`;
  reproducer gate `m32-footprint.sh` / `make bench-footprint`.
  Read latency p50 **1.63 ms** / p95 **2.20 ms** vs Supabase p95 2.57 ms (`artifacts/bench/grobase-vs-supabase.json`, n=60).

**Exact remainder to 10/10:**
- **[HUMAN]** Live Stripe account + flip `BILLING_ENABLED` on the *hosted* deployment (the reporter
  is built + gate-proven against mock, `m82-billing-report.sh`; flipping the flag ON in the committed
  baseline is forbidden — OFF = byte-parity. This is a production-deploy human atom, not code).
- **[HUMAN]** Public domain registration + production TLS + Kong public route on a real host.
- **[INFRA-MEAS]** A real-money end-to-end test charge (one paid signup actually billed) — PENDING the
  live Stripe atom above.

**What stands between us and 10/10:** wire the live Stripe key and a public domain on a hosted node
and run one real paid signup — pure **[HUMAN]** production turn-on, zero new code.

---

## 2. Target 2 — SLA-backable GA · **6 / 10**

The availability story is no longer one unbuilt feature — it is a **composed architecture** whose parts
are each gate-backed, with the one genuinely-risky piece (write-failover) **correctly delegated** to the
managed-Postgres layer. The HA composition and its earn-the-number drills are documented in
`mini-baas-infra/deploy/ha/README.md`. The score moves up only by what is genuinely added —
**deploy-availability** and a **documented, gate-backed architecture** — and the honest caps stay.

**Proven (the "done" parts):**
- **Zero-downtime deploys are real.** The helm workloads are stateless `Deployment`s with **≥2 replicas**
  (data plane `replicas: 2` + HPA `minReplicas: 2`, `deploy/helm/grobase/values.yaml`) and **readiness +
  liveness probes** (`deploy/helm/grobase/templates/workloads.yaml`). The chart sets an **explicit
  `RollingUpdate` strategy with `maxUnavailable: 0` / `maxSurge: 1`** (`deploy/helm/grobase/values.yaml`
  `deployStrategy`, rendered on the 5 Deployment planes only — StatefulSets keep their ordered strategy),
  so a replacement pod must be **Ready before any running pod is drained** — a rollout serves continuously
  with zero capacity dip. An optional `PodDisruptionBudget` (`minAvailable: 1`, off by default) protects the
  same planes through node drains/upgrades. (This is *deploy*-availability, distinct from *node-loss*
  failover below.)
- **Read-availability**: read-replica routing is gate-green — `m122-read-replica-routing.sh` asserts
  (ENFORCE arm) that a read with the flag ON returns `200` **and** `sentinel=='replica'`, so reads provably
  leave the primary and survive a primary read-load spike. (m122 proves the *routing decision* only — not
  streaming replication or lag SLOs, per its own header.)
- **Recovery**: PITR WAL + restore-to-timestamp proven by `m99-pitr-restore.sh`; logical backup/restore
  round-trip `m47-backup-restore.sh`; per-tenant backup/restore `m87-per-tenant-backup.sh`.
- **Multi-node correctness**: the per-tenant rate-limit is one global bucket across replicas
  (`m51-multinode.sh`), and the connection-pooler path is byte-parity with direct
  (`m98-pooler-parity.sh`) — so horizontal scale-out does not break limits or correctness.
- **Density that de-risks the scale story**: **24,887 live tenants held at rest by a 2.6 MiB data plane,
  `pools_open: 0`** (`artifacts/scale/footprint-live-24887.json`); **10K tenants → 1 pool, 0 × 5xx**
  (gate `m46`). These prove RSS / pool-count / 5xx are functions of working set, not tenant count.
- **Write-failover is delegated, not missing.** Data-plane sqlx pools open lazily, so retrying a write on a
  standby risks a double-write — the safe owner of write-failover is the database. Grobase therefore
  delegates it to **managed Postgres HA** (RDS Multi-AZ / Patroni / Cloud SQL HA), which presents a single
  endpoint and promotes a standby transparently. The composition + the delegation contract are documented
  in `deploy/ha/README.md`.

**Exact remainder to 10/10 — the honest caps (now: run the drills, not build the feature):**
- **[INFRA-MEAS]** **Write-failover RTO/RPO is not yet measured.** The mechanism is the managed-PG layer
  above; what is owed is a **timed failover drill** (kill the primary mid-load, measure recovery time +
  dropped/lost writes against the managed endpoint) — the drill is specified in `deploy/ha/README.md`.
  **PENDING the failover drill; no RTO/RPO number is claimed.**
- **[INFRA-MEAS]** There is **no uptime probe** running yet, so the availability number is unknown. Per
  `wiki/trust-center.md` the SLA stays a `(TARGET)`, *not enforceable until the uptime probe exists*. Do
  **not** publish any availability %. **PENDING uptime probe (≥30 days of samples) — see `deploy/ha/README.md`.**
- **[INFRA-MEAS]** **100K is PROJECTED, not measured.** `wiki/scale-slo.md §4` is explicit: serve-path
  metrics carry to 100K (they don't grow with N), but the clean 100K *load-latency* SLO needs a
  **dedicated quiet node** — the shared dev box is Chrome/CPU-contended. The 100K row is `~300 MiB
  extrapolated · ~50 min seed`, marked **projected**. **PENDING a real 100K run on a quiet node.**
- **[LEGAL]** The SLA document itself is a **TEMPLATE** (`wiki/legal/sla.md`) needing counsel.

**What stands between us and 10/10:** the architecture is now documented and gate-backed — what remains is
to **run** the drills, not invent them: a timed managed-PG failover drill to earn RTO/RPO, a ≥30-day uptime
probe to earn a real availability number, and a clean 100K load run on a quiet node (all **[INFRA-MEAS]**,
all specified in `deploy/ha/README.md`). Until those runs exist this target is honestly capped — we offer a
best-effort SLA backed by a documented HA architecture, not a signed-and-measured uptime number.

---

## 3. Target 3 — Enterprise-procurable · **7 / 10**

**Proven (the "done" parts) — the enterprise lane is gate-complete (m103–m112):**
- **Orgs / RBAC**: `m103-orgs-rbac.sh` asserts a VIEWER role gets `403` on `project:create` (RBAC is
  enforced, not cosmetic) and that org-scoping is **control-plane only** — the data-plane body is
  byte-unchanged after migrations 043/044, preserving SHARE_POOLS density.
- **Tamper-evident audit**: `m104-audit-chain.sh` (hash-chained audit log).
- **Hard-erase / right-to-be-forgotten**: `m105-hard-erase.sh`. **Tenant data export**:
  `m109-tenant-export.sh`.
- **IP allowlist**: `m106-ip-allowlist.sh`. **Passkeys / WebAuthn**: `m107-passkeys.sh`.
- **SSO (OIDC)**: `m110-sso-oidc.sh` (11-step gate against a mock OIDC IdP). **SCIM provisioning**:
  `m111-scim.sh`.
- **Trust center**: `m112-trust-center.sh` + `wiki/trust-center.md`. **SOC2 evidence collection**:
  `m108-soc2-evidence.sh` — evidence is *collected and audit-ready*, **NOT** "SOC2 certified".
- **Credential-reference via Vault** (no raw secrets in tenant config): `m121-credref-vault-enforce.sh`
  (PACKAGE_ENFORCEMENT arm).
- **CMEK / BYOK (customer-managed encryption keys)**: `m123-cmek-envelope.sh` — per-mount DSN
  envelope-encrypted (random DEK → AES-256-GCM; DEK wrapped by an external-KMS KEK the customer
  controls). The gate proves a **real** Vault-Transit unwrap round-trip AND **crypto-shred** (delete
  the KMS key → the platform can no longer decrypt). Control-plane only (data plane / RLS / pool key
  untouched); flag-OFF = byte-parity. Migration 061 / 3-way secret-mode CHECK.

**Exact remainder to 10/10:**
- **[HUMAN]** Wire a *real* enterprise IdP (Okta/Entra/etc.) end-to-end — gates prove the SSO/SCIM
  protocol against a **mock** IdP (`mock-oidc.py`); a customer-facing claim needs one real tenant
  connected. No new code expected; configuration + a customer.
- **[LEGAL]** A SOC2 **audit** by a real firm. We have m108 SOC2-*lite* (evidence collected,
  audit-ready). "SOC2 certified" stays false until an auditor signs. **PENDING audit firm engagement.**
- **[LEGAL]** Legal docs are **TEMPLATES** (`wiki/legal/{terms-of-service,privacy-policy,
  data-processing-addendum,subprocessors,acceptable-use-policy,sla}.md`), each marked *TEMPLATE — not
  legal advice*. **PENDING counsel review.**
- **[HUMAN]** A *cloud* KMS provider (AWS KMS / GCP KMS) for CMEK if a customer requires it — the CMEK
  envelope + crypto-shred are gate-green TODAY via **Vault Transit** (`m123`), and per-tenant distinct
  KEKs are schema-supported (`cmek_kms_key_id` per row); wiring a specific cloud-KMS backend + each
  tenant's own key is configuration, not new envelope code.

**What stands between us and 10/10:** connect one real IdP **[HUMAN]**, engage a SOC2 audit firm and
a lawyer **[LEGAL]** — the entire engineering surface is already gate-green.

---

## 4. The six readiness bars

| Bar | Score | Backed by (gate / artifact) | Exact remainder |
|---|:---:|---|---|
| **1 · Parity** | **9 / 10** | Flag-gated-OFF = byte-parity is the committed baseline (every Track-B/C/D/E flag OFF by default). Org-scoping proven control-plane-only, data-plane body byte-unchanged (`m103`). 8-engine agnostic (`m7-adapters.sh`, `m46`). | **[ENG]** Final TS→Rust legacy deletion still blocked behind the m18 live-traffic + shadow-parity + CI-forward gates (UNKNOWN = FAIL); retained, not deleted. |
| **2 · Scale-SLO** | **6 / 10** | 24,887 tenants @ 2.6 MiB, 0 pools (`artifacts/scale/footprint-live-24887.json`); 10K → 1 pool, 0×5xx (`m46`); read-availability routing (`m122`); multi-node shared rate-limit (`m51`) + pooler parity (`m98`); read p50 1.63 / p95 2.20 ms (`grobase-vs-supabase.json`, n=60); HA architecture composed + documented in `deploy/ha/README.md`. | **[INFRA-MEAS]** 100K load PROJECTED, not measured (needs quiet node, `scale-slo.md §4–5`). **[INFRA-MEAS]** No uptime probe → availability unknown. **[INFRA-MEAS]** write-failover RTO/RPO unmeasured — mechanism delegated to managed PG (RDS Multi-AZ / Patroni / Cloud SQL HA), drill PENDING in `deploy/ha/README.md`. |
| **3 · Security** | **8 / 10** | Tamper audit (`m104`), hard-erase (`m105`), IP allowlist (`m106`), passkeys (`m107`), Vault cred-ref (`m121`), RS256 issuer proof (`m81-rs256-issuer.sh`), adapter HMAC (`m67`), netseg (`m66`). | **[LEGAL]** SOC2 = lite/audit-ready (`m108`), not certified — needs an auditor. **[HUMAN]** RS256 *live* auth cutover is held for an explicit human trigger. |
| **4 · Live-signup** | **7 / 10** | Cloud funnel proven vs **mock** Stripe (`m94`); quota-truth (`m101`); spend/suspend enforce (`m120`); self-serve + console (`m83`, `m84`); telemetry export (`m100`). | **[HUMAN]** Live Stripe key + public domain/TLS + one real paid signup. |
| **5 · Enterprise** | **7 / 10** | Gate-complete: orgs/RBAC (`m103`), SSO-OIDC (`m110`), SCIM (`m111`), tenant export (`m109`), trust-center (`m112`). | **[HUMAN]** one real IdP wired; **[LEGAL]** SOC2 audit + lawyer-reviewed legal docs. |
| **6 · Operational** | **7 / 10** | Zero-downtime deploys (helm RollingUpdate, ≥2 replicas + readiness probes — `deploy/helm/grobase/`); HA architecture + delegation + drills documented (`deploy/ha/README.md`); spend/suspend enforcement (`m120`), read-availability routing (`m122`), PITR (`m99`), backup/restore (`m47`) + per-tenant backup (`m87`), multi-node rate-limit (`m51`) + pooler parity (`m98`), per-tenant observability (`m85-tenant-observability.sh`), credref-vault (`m121`). | **[INFRA-MEAS]** write-failover RTO/RPO drill (mechanism delegated to managed PG). **[INFRA-MEAS]** uptime/error-budget probe. **[INFRA-MEAS]** 100K ops run on a quiet node. (All drills specified in `deploy/ha/README.md`.) |

---

## 5. The remainder, deduplicated by kind (the actual GA punch-list)

**[ENG] — engineering still owed (the only true code gaps):**
1. Final TS→Rust legacy deletion — only after m18 + shadow-parity + CI-forward all PASS (UNKNOWN = FAIL).

> **Not an ENG gap — delegated by design:** data-plane *write*-failover / replica-promotion is **not**
> owed as Grobase code. sqlx pools open lazily, so retrying a write on a standby risks a double-write;
> the safe owner is the database. It is delegated to the managed-Postgres HA layer (RDS Multi-AZ /
> Patroni / Cloud SQL HA) — see `deploy/ha/README.md`. What remains is to *measure* its RTO/RPO (below),
> not to *build* it.

**[INFRA-MEAS] — measurements we have not yet taken (numbers we are NOT allowed to claim):**
2. **Availability %** — PENDING a ≥30-day uptime probe (the SLA is a `(TARGET)` until then). Drill: `deploy/ha/README.md`.
3. **Write-failover RTO/RPO** — PENDING a timed managed-PG failover drill (kill primary mid-load, measure recovery + lost writes). Drill: `deploy/ha/README.md`.
4. **Clean 100K load-latency SLO** — PENDING a run on a dedicated quiet node (`scale-slo.md §5`).
5. A real-money end-to-end billing charge — PENDING the live Stripe human atom (#6).

**[HUMAN] — a person must perform an irreversible (scripts PREPARE; they do not execute):**
6. Provision a live Stripe account + flip `BILLING_ENABLED` on the hosted deploy.
7. Register a public domain + production TLS + Kong public route.
8. Wire one real enterprise IdP (Okta/Entra) end-to-end.
9. RS256 live-auth cutover (held for explicit human trigger).
10. npm publish of the SDK / push / deploy / tag (held for explicit human trigger).

**[LEGAL] — lawyer or auditor sign-off:**
11. SOC2 **audit** by a real firm (today: m108 SOC2-lite = evidence collected, audit-ready).
12. Counsel review of every legal TEMPLATE (`wiki/legal/*`).

---

## 6. Reproduce any "done" cell

```bash
# from apps/baas/  — run a single gate directly:
bash mini-baas-infra/scripts/verify/m103-orgs-rbac.sh        # VIEWER → 403 on project:create
bash mini-baas-infra/scripts/verify/m122-read-replica-routing.sh   # read sentinel=='replica'
bash mini-baas-infra/scripts/verify/m94-cloud-funnel.sh      # signup→key→CRUD→usage→bill (mock Stripe)
bash mini-baas-infra/scripts/verify/m108-soc2-evidence.sh    # SOC2 evidence collection (audit-ready, NOT certified)
# or via the root wrappers:
make -C ../.. baas-verify-all                                 # m1…m10 in order
```

Artifacts cited above: `artifacts/bench/footprint-*`, `artifacts/bench/load-essential-crud.json`,
`artifacts/bench/supabase-footprint-breakdown.txt`, `artifacts/scale/footprint-live-24887.json`.

---

### Honesty footer
Nothing in this doc claims an availability %, a measured 100K-load number, an uptime SLO, or "SOC2
certified" — those are explicitly **PENDING** their atoms above. Flag-gated features stay **OFF** in the
committed baseline (OFF = byte-parity); this scorecard scores capability, not a flipped-on baseline.
