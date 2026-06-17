# Grobase Cloud Edition + the m94 end-to-end funnel gate (DESIGN)

> **Status:** DESIGN-ONLY. This document specifies an OPT-IN cloud edition (a
> `docker-compose.cloud.yml` overlay + a `flags.env.cloud`) and the **m94**
> end-to-end funnel gate — the concrete "100% cloud infrastructure that is
> usable, runnable on local docker" proof (acceptance **bar 4**). No code,
> compose, or gate is created by this doc; it is the build plan the BUILD step
> follows.
>
> **The law it must keep (kernel rule #5):** flag-gated-OFF = byte-parity. The
> cloud edition is purely additive — the default stack is byte-untouched. Every
> claim below cites a file:line I read.

---

## 0. What already exists (grounded — do not re-build these)

The cloud *components* B1–B6 + the B7.8/B7.9 guards are **already built and
gate-proven flag-OFF**. The cloud edition just *turns them on together* and the
m94 gate *exercises the whole funnel at once*. Inventory:

| Component | Flag(s) | Consumer (file:line) | Existing gate |
|---|---|---|---|
| B1 metering producer (Rust) | `METERING_ENABLED` + `DATA_PLANE_METERING` | `data-plane-router/crates/data-plane-server/src/config.rs:238,241` | m74/75/77 |
| B1 metering ingest (Go) | `METERING_ENABLED` + `METERING_INGEST` | `internal/metering/consumer.go`, registered in `cmd/orchestrator/main.go:89` | — |
| B1c usage read API | (always; reads tenant_usage) | `internal/metering/handler.go:29` `GET /v1/tenants/{id}/usage` | — |
| B2 quota guard (Go) | `METERING_ENABLED` + `QUOTA_ENFORCEMENT` | `internal/metering/quotaguard.go:78`, registered `cmd/orchestrator/main.go:94` | m80 |
| B2 quota enforce (Rust → **402**) | `METERING_ENABLED` + `DATA_PLANE_QUOTA_ENFORCEMENT` | `config.rs:264,267`; `quota.rs:30` `QUOTA_OVER_SET="quota:over"`; `routes.rs:175,310` | m80 |
| B3 billing reporter (Go→Stripe) | `METERING_ENABLED` + `BILLING_ENABLED` | `internal/metering/billing.go:82`; POSTs `{STRIPE_API_BASE}/v1/billing/meter_events` `billing_stripe.go:68` | m82 |
| B4a self-serve `/v1/tenants/me*` | `TENANT_SELFSERVE_ENABLED` | `internal/tenants/selfserve.go:51-56`, mounted `cmd/tenant-control/main.go:133` | m83 |
| B4b console Kong route | (route always present, harmless when upstream off) | `docker/services/kong/conf/kong.yml:448` `~/v1/tenants/me$` | m84 |
| B5 per-tenant obs | `TENANT_OBS_ENABLED` + `DATA_PLANE_TENANT_OBS` | `internal/shared/logger.go` | m85 |
| B6 backup/restore | `TENANT_BACKUP_ENABLED` (+ `TENANT_BACKUP_SELFSERVE_ENABLED`) | `internal/backup/handler.go`, mounted `cmd/tenant-control/main.go:159` | m87 |
| B7.8 spend caps (Go) | `METERING_ENABLED` + `SPEND_CAPS_ENABLED` | `internal/spendcap/spendcap.go:97`, registered `cmd/orchestrator/main.go:110`; set `spend:over` | m89 |
| B7.9 abuse guard (Go) | `ABUSE_GUARD_ENABLED` | `internal/abuseguard/abuseguard.go:102`, mounted `cmd/tenant-control/main.go:199`; `/v1/abuse/*`; set `tenant:suspended` | m90 |
| B7.2 staged quota dial | `QUOTA_STAGE` shadow\|warn\|enforce | `internal/quotastage/quotastage.go` | m89(C) |

The Stripe-mock already exists: `scripts/verify/m82-mock-stripe/server.mjs` — a
zero-dep Node mock of the Meter Events API that records POSTs and serves
`GET /_events`.

### 0.1 Drift this design corrects (read before trusting the manifest)

`config/cloud/flags.env.example:102-115` labels `SPEND_CAPS_ENABLED` and
`ABUSE_GUARD_ENABLED` **"(SCAFFOLD — not yet built; name reserved) … flipping
ON today is a no-op until the consumer lands."** **That is now stale.** The
consumers landed afterward (the package files are dated `Jun 14 18:xx`, after the
manifest's `18:05`): `spendcap.NewGuard` is registered in
`cmd/orchestrator/main.go:110` and `abuseguard.Mount` in
`cmd/tenant-control/main.go:204`, both with green gates (m89, m90). The BUILD
step's first action is to **delete the (SCAFFOLD) labels and the R7 "no consumer
yet" caveat** in `flags.env.example` + `config/cloud/README.md:33-35,72` so the
manifest stops lying. (Librarian doc-sync, kernel rule #8: one source of truth.)

**Honest scope of enforcement in the data plane (do NOT over-claim):** the Rust
data plane consumes **only `quota:over`** today (`grep` of
`data-plane-router/crates/` finds `quota:over` but **no** `spend:over` /
`tenant:suspended`). So:

- **B2 quota** rejects with a **real end-to-end HTTP 402 on the data path**.
- **B7.8 spend cap** is proven at the **control-plane boundary**: the
  over-budget tenant lands in Redis `spend:over` (the set the data plane *will*
  read once `DATA_PLANE_SPEND_CAPS` lands; that wiring is a separate slice). m89
  proves exactly this and m94 reuses it verbatim.
- **B7.9 abuse** rejects at the control plane: `POST /v1/abuse/admit` → **403**
  + auto-suspend (`tenant:suspended`). m90 proves this; m94 reuses it.

The m94 doc and gate output must state this split plainly — a gate that implied a
spend-cap 402 on the data path would be a parity/honesty lie.

---

## 1. The Cloud Edition — overlay + flags file (opt-in, additive)

### 1.1 Decision: overlay `docker-compose.cloud.yml`, NOT a new `EDITION=`

The Makefile's `EDITION`/`PACKAGE` machinery only selects **compose profiles**
(`Makefile:48-118`) — it cannot inject env. The cloud edition is the *same
services as `EDITION=prod`* with the **cloud flags ON**, so it is an
**env overlay**, not a new profile set. Precedent already in the tree:
`docker-compose.prod.yml`, `.scale.yml`, `.pooler.yml`, `.netseg.yml`,
`.graphql.yml` are all overlays layered with `-f`. The cloud edition follows the
same shape, so the default `docker-compose.yml` stays byte-untouched (kernel #5).

**Two new files** (the only durable artifacts of slice 1):

```
config/cloud/flags.env.cloud         # all cloud flags ON, local/mock values, NO real secrets
docker-compose.cloud.yml             # env-only overlay: env_file += flags.env.cloud + stripe-mock svc
```

### 1.2 `config/cloud/flags.env.cloud` (all cloud flags ON, local-safe)

A copy of `flags.env.example` with the ladder flipped to **R6** (R1 observe →
R2 self-serve → R3-5 quota enforce → R6 billing) **plus** R7 spend/abuse, using
the *mock* Stripe and fixed local rates. Concretely (names verified against the
consumers in §0):

```ini
# ── B1 metering (master + both planes) ──
METERING_ENABLED=1
METERING_INGEST=1
DATA_PLANE_METERING=1
DATA_PLANE_METERING_FLUSH_MS=2000        # config.rs:244 — fast flush so usage lands within the gate window
# ── B2 quota: enforce, congruent dial ──
QUOTA_STAGE=enforce
QUOTA_ENFORCEMENT=1                       # quotaguard.go:78 (control-plane publisher of quota:over)
DATA_PLANE_QUOTA_ENFORCEMENT=1           # config.rs:267 (data-plane reader → 402)
DATA_PLANE_QUOTA_REFRESH_MS=2000         # config.rs:270 — fast snapshot refresh
# ── B3 billing → MOCK Stripe (no live account; see §2) ──
BILLING_ENABLED=1
BILLING_REPORT_INTERVAL_MS=5000
STRIPE_API_BASE=http://stripe-mock:8080  # billing.go:86 / billing_stripe.go:68
STRIPE_API_KEY=sk_test_local_mock        # any non-empty value (billing.go:112 only checks non-empty)
BILLING_METER_QUERY_COUNT=query_count    # billing.go:109 — catalog must be non-empty or Init is fatal
BILLING_METER_WRITE_ROWS=write_rows
# ── B4 self-serve (already :-1 in compose for tenant-control; explicit here) ──
TENANT_SELFSERVE_ENABLED=1
# ── B5 per-tenant obs ──
TENANT_OBS_ENABLED=1
DATA_PLANE_TENANT_OBS=1
# ── B6 backup/restore ──
TENANT_BACKUP_ENABLED=1
TENANT_BACKUP_SELFSERVE_ENABLED=1
# ── B7.8 spend caps (control-plane publisher of spend:over) ──
SPEND_CAPS_ENABLED=1
SPEND_CAPS_INTERVAL_MS=5000
SPEND_RATE_query.count=1                  # spendcap loadRateTable — non-empty or Init is fatal (spendcap.go:120)
SPEND_RATE_write.rows=2
# ── B7.9 abuse / KYC-lite ──
ABUSE_GUARD_ENABLED=1
ABUSE_VELOCITY_MAX=20                     # abuseguard.go:104
ABUSE_VELOCITY_WINDOW_MS=3600000
```

**Invariants this file keeps congruent** (from `config/cloud/README.md:74-90`):
`QUOTA_STAGE=enforce ⇔ QUOTA_ENFORCEMENT=1`; metering ON before quota/billing
(every guard ANDs with `METERING_ENABLED`); billing has a non-empty catalog + a
non-empty `STRIPE_API_KEY` or `Init` is fatal by design (`billing.go:109-114`);
spend-cap has non-empty `SPEND_RATE_*` or `Init` is fatal (`spendcap.go:120`).

`flags.env.cloud` carries **no real secret** (mock Stripe base + a fake test
key) so, unlike `flags.<env>.env`, it is **safe to commit** and gitignore is not
required — but the BUILD step must add a header saying "LOCAL/MOCK ONLY — never a
real key here".

### 1.3 `docker-compose.cloud.yml` (the overlay)

An env-only overlay (no new app images). For every service that reads a cloud
flag, add `env_file: [.env, config/cloud/flags.env.cloud]` (compose merges; the
later file wins). The services that must get the overlay, and why:

| Service | Cloud env it needs |
|---|---|
| `orchestrator` | `METERING_ENABLED`, `METERING_INGEST`, `QUOTA_ENFORCEMENT`, `BILLING_ENABLED`+`STRIPE_*`+`BILLING_METER_*`, `SPEND_CAPS_ENABLED`+`SPEND_RATE_*` (it hosts metering ingest, quota-guard, billing-reporter, spend-cap — `cmd/orchestrator/main.go:89,94,101,110`) |
| `tenant-control` | `TENANT_SELFSERVE_ENABLED`, `TENANT_BACKUP_ENABLED`+`*_SELFSERVE`, `ABUSE_GUARD_ENABLED`+`ABUSE_*`, `BILLING_ENABLED` (the `/me` plan-change view, `main.go:139`) |
| `data-plane-router-rust` | `DATA_PLANE_METERING`, `DATA_PLANE_QUOTA_ENFORCEMENT`, `DATA_PLANE_*_REFRESH/FLUSH`, `DATA_PLANE_TENANT_OBS` |
| `metering` read-API host (tenant-control) | already serves `/v1/tenants/{id}/usage` (`handler.go:29`) — no extra env |

Plus **one new service** — the local Stripe mock (§2):

```yaml
stripe-mock:
  image: node:20-alpine
  command: ["node", "/srv/server.mjs"]
  volumes: ["./scripts/verify/m82-mock-stripe/server.mjs:/srv/server.mjs:ro"]
  environment: { PORT: "8080" }
  networks: [mini-baas]
  profiles: [cloud]          # never started by a non-cloud edition
```

### 1.4 The make target

Add to the Makefile (mirrors how `prod`/`scale` overlays are layered):

```make
CLOUD_FILES := -f docker-compose.yml -f docker-compose.cloud.yml
cloud-up:   ## Boot the FULL managed-cloud stack locally (all cloud flags ON, mock Stripe)
	@$(DC) $(CLOUD_FILES) --profile control-plane --profile go-control-plane \
	    --profile rust-data-plane --profile adapter-plane --profile data-plane \
	    --profile background --profile realtime --profile storage --profile cloud up -d
cloud-down: ## Stop the cloud edition
	@$(DC) $(CLOUD_FILES) --profile cloud down
```

(The profile list = `EDITION_prod` planes + the new `cloud` profile for
stripe-mock. `up EDITION=prod` + `-f docker-compose.cloud.yml` would also work;
the wrapper just bakes in the overlay so an operator can't forget it.)

---

## 2. Stripe without a live account — DECISION: the existing zero-dep mock

**Pick the mock, NOT Stripe test-mode keys, NOT the `stripe/stripe-mock`
image.** Rationale (the deciding factor is the human-atom count):

| Option | Human atom? | Verdict |
|---|---|---|
| Stripe **test-mode keys** | **YES** — needs a Stripe account + a `sk_test_…` from the dashboard + created Products/Prices/meters | rejected for the local proof |
| `stripe/stripe-mock` (official) | NO account, but a 30 MB+ image pull + it returns canned fixtures, not *our recorded* events | heavier; can't assert "we sent EXACTLY these windows" |
| **`m82-mock-stripe/server.mjs`** (already in-tree) | **ZERO** | **chosen** |

The billing reporter targets `{STRIPE_API_BASE}/v1/billing/meter_events`
(`billing_stripe.go:68`), `STRIPE_API_BASE` is env-overridable (`billing.go:86`),
and the only check on `STRIPE_API_KEY` is *non-empty* (`billing.go:112`). The
mock (`m82-mock-stripe/server.mjs`) already records every POST and serves them at
`GET /_events`, which is exactly what m82 asserts. The cloud overlay points
`STRIPE_API_BASE` at the `stripe-mock` service; **no Stripe account, no network,
no human atom.** A *real* live Stripe account is a §5 go-live atom only.

---

## 3. The m94 end-to-end funnel gate — `scripts/verify/m94-cloud-funnel.sh`

m94 is the **bar-4 proof**: a stranger's whole journey, all flags ON, on one
isolated local stack. It does NOT re-prove each component (m74–m90 do that
unit-by-unit); it proves they **compose into a working product**. It mirrors the
isolation discipline of m80/m82/m83/m84/m85/m89/m90 exactly.

### 3.1 Isolation (verbatim from the m80/m89/m90 family)

- A scratch **private network** named `m94-net-$$` (run-id = `$$` PID suffix).
- Scratch **postgres** (`postgres:16-alpine`) seeded with the migration preludes
  the funnel touches: `032` (tenants/keys) + `040` (tenant_usage) + `041`
  (tenant_billing) + `045` (tenant_safety) — same prelude set m82/m89/m90 use.
- Scratch **redis** (the `quota:over`/`spend:over`/`tenant:suspended` carrier).
- `data-plane-router` **built FROM CURRENT source** + `orchestrator` and
  `tenant-control` **built FROM CURRENT source** (so the EXACT production
  enforcement + selfserve + abuse code runs), + the `m82-mock-stripe` node mock.
- Every container/volume/network name suffixed `-$$`; an **`EXIT` trap**
  `docker rm -f`/`network rm` removes EVERYTHING.
- It **NEVER** touches a `mini-baas-*` container/network/image/volume and
  **NEVER** edits the live `docker-compose.yml` (kernel #2, the m80 header
  contract).
- Data path uses the router's internal trusted-envelope `/v1/query` (no Kong) for
  the CRUD/402 leg exactly as m80, AND a real **Kong** hop for the one
  reachability assertion in step 7 (so the public console route is proven, like
  m84).

### 3.2 POSITIVE arm — the full funnel (all cloud flags ON)

Each step asserts off the wire (not from logs):

1. **Provision a tenant** — `POST /v1/provision` (or `tenants.Mount` admin
   create) → a tenant id. (Path: `internal/tenants/provision.go`.)
2. **Issue an API key** — via `POST /v1/tenants/me/keys` (selfserve, JWT-bearer,
   `selfserve.go:54`) OR the admin `/v1/keys` path → an `X-Baas-Api-Key`.
3. **CRUD through the data plane** — N writes + reads via the router `/v1/query`
   with that key's signed identity. Assert 200s.
4. **Usage shows up in `tenant_usage` (B1)** — poll `public.tenant_usage` for the
   tenant's `query.count` row; assert `qty == N` (the metering producer flushed,
   the ingest consumer drained). LOAD-BEARING: a non-zero, *correct* count.
5. **`GET /v1/tenants/me/usage` returns it (B4a)** — the self-serve read
   (`selfserve.go:52`) returns the same `query.count` total. Assert the body
   matches step 4 (the `/me/usage` filter is shape-identical to `{id}/usage` —
   `selfserve.go:438`).
6. **A meter event is reported to stripe-mock (B3)** — within
   `BILLING_REPORT_INTERVAL_MS`, `GET http://stripe-mock:8080/_events` shows ≥1
   event with the right `event_name` (`query_count`), `customer`, `value`, and
   `identifier` = the window idempotency key. (Requires a `tenant_billing` row
   with a `stripe_customer_id` for this tenant — m94 seeds it, like m82.)
   Re-tick sends nothing new (idempotent, the local `billing_reported` ledger).
7. **The self-serve console route is reachable through Kong (B4b)** — `GET`
   through the gateway at `~/v1/tenants/me` (`kong.yml:448`) returns the tenant
   summary (200), proving the public buyer-facing surface is wired, not just the
   internal port.

### 3.3 LOAD-BEARING REJECT arm

A gate whose only outcome is the happy path is **vacuous** (kernel #4 + the m80
header). m94 asserts three rejects, each at its honest layer (§0.1):

- **R1 · quota 402 (B2, end-to-end on the data path).** Seed (or drive) the
  tenant over its tier `query.count` cap so the QuotaGuard publishes it to
  `quota:over`; after the data-plane refresh window, a `/v1/query` as that tenant
  returns **402** (read off the wire). This is the one *real HTTP-402-on-the-data-
  path* assertion — the strongest reject. (Path: `quota.rs` →
  `routes.rs:310`; same as m80 arm A.)
- **R2 · spend cap halt (B7.8, control-plane boundary).** Seed an over-budget
  `tenant_budgets` row; after `SPEND_CAPS_INTERVAL_MS`, assert the tenant is a
  member of Redis `spend:over` (the set the data plane *will* consult). Assert an
  under-budget tenant is **absent**. This is the m89 reject reused — m94 must
  print "spend-cap halt proven at the control-plane `spend:over` set; the data-
  plane reject wiring (`DATA_PLANE_SPEND_CAPS`) is a separate slice" so the claim
  stays honest.
- **R3 · over-velocity project-create refused/suspended (B7.9).** With
  `ABUSE_VELOCITY_MAX` set low (e.g. 3), the 1st-3rd `POST /v1/abuse/admit`
  `{action:project_create}` → 200 admit:true, the 4th → **403
  velocity_exceeded** AND the tenant flips to `tenant:suspended`; a subsequent
  admit for the now-suspended tenant → 403 `tenant_suspended`. (m90 arm A reused;
  `abuseguard` decide path.)

### 3.4 FLAG-OFF PARITY arm

Re-run the *same* funnel calls on a second scratch stack built from the same
source but with the cloud flags **unset** (env file omitted). Assert
byte-identical OSS behavior:

- step 3 CRUD → still **200** (no metering tax, no 402).
- step 4 → `public.tenant_usage` has **zero rows** (the producer never emits;
  `config.rs:241` OFF).
- quota arm → the over-cap tenant's `/v1/query` is still **200** (no `quota:over`
  written; `quotaguard.go:78` OFF, `config.rs:267` OFF) — the m80 arm B contract.
- billing arm → a *fresh* stripe-mock receives **zero** events (`/_events`
  count == 0; `billing.go:104` OFF) — the m82 arm B contract.
- abuse arm → `POST /v1/abuse/admit` → **404** (routes not mounted;
  `main.go:199` gate OFF) — the m90 arm B contract.
- spend arm → `spend:over` never written (`spendcap.go:97` OFF) — the m89 arm B.

The parity arm is the guarantee that **the cloud edition is opt-in and the
default stack is unchanged** (kernel #5).

### 3.5 Wrapper + CI

Add `baas-verify-m94` to the **root** Makefile (sibling of `baas-verify-mNN`)
and list m94 in the milestone map. Independent ground truth everywhere (seed
`tenant_usage`/`tenant_budgets`/`tenant_safety` rows directly, never trust the
thing under test to also be the oracle), exactly like m80/m82/m89.

---

## 4. Parity statement (explicit)

The cloud edition is **purely additive and opt-in**, so the default stack is
byte-untouched:

1. **No default file changes.** `docker-compose.yml` is not edited; the cloud
   behavior lives in a *new* `docker-compose.cloud.yml` overlay + a *new*
   `config/cloud/flags.env.cloud`. A non-cloud `make up EDITION=…` never reads
   either (it doesn't pass `-f docker-compose.cloud.yml`).
2. **Every flag defaults OFF in the service code itself**, so even if the overlay
   is absent the binaries are byte-parity: `config.rs:238,264` (Rust),
   `billing.go:82`, `quotaguard.go:78`, `spendcap.go:97`, `abuseguard.go:102`,
   the `envBool` gates in `cmd/*/main.go` (Go). The manifest only makes the
   cloud-canonical values explicit (`config/cloud/README.md:92-97`).
3. **The stripe-mock service is in a `cloud` profile**, so no non-cloud edition
   ever starts it.
4. **m94's own flag-OFF arm (§3.4) is the proof**, joining the existing
   all-flags-OFF matrix posture (plan risk #1 / `flags.env.example:96`). The one
   honest exception already in the live tree: `TENANT_SELFSERVE_ENABLED` defaults
   `:-1` for `tenant-control` in `docker-compose.yml:1119` with a documented
   kill-switch + m84's OFF arm — m94 must not regress that.

---

## 5. HUMAN ATOMs — needed for the REAL hosted go-live, NOT for the local m94 proof

m94 proves "usable, runnable on local docker" with **zero** human atoms (mock
Stripe, scratch local containers). The following are required only to turn the
*same* edition into a **real hosted product a stranger can buy** (Track-B B7.6/
B7.7 + plan §"Human / $$ atoms"). They are out of scope for the m94 gate:

- [ ] **Live Stripe account** + Products/Prices/meters mapped to
  `config/packages/packages.json` (B7.3) + a real `sk_live_…` / `sk_test_…` fed
  via the secrets tool into `STRIPE_API_KEY` and `BILLING_METER_*` — never
  committed. (Replaces the mock `STRIPE_API_BASE`.)
- [ ] **A domain + DNS + edge TLS** for the public API/console (B7.6, also the
  D2f shared edge primitive).
- [ ] **Fly Machines + Fly Vault** hosting the control/data/realtime planes
  (B7.6) + prod SMTP/OAuth credentials — a recurring **cloud bill**.
- [ ] **The go-live gating triad before public signup** (plan critic): B7.8 spend
  caps + B7.9 abuse/KYC **wired into the data-plane reject path**
  (`DATA_PLANE_SPEND_CAPS`/suspend reader — the slice §0.1 flags as not-yet-
  built) + B7.11 API-version contract. m94 proves the control-plane halves;
  shipping public signup needs the data-plane halves too.
- [ ] **KYC/fraud review process**, a **support org + on-call**, and the
  pen-test/SOC2/legal atoms (plan risks #2, #5) — none gate the local proof.

None of these block `baas-verify-m94`. The local proof is complete with the mock.

---

## 6. Build plan (what slice-1 + slice-m94 create — no code in this doc)

1. `config/cloud/flags.env.cloud` — §1.2 (NEW, commit-safe, mock values only).
2. `docker-compose.cloud.yml` — §1.3 (NEW overlay: per-service `env_file`
   addition + the `stripe-mock` service in a `cloud` profile).
3. `Makefile` — `cloud-up`/`cloud-down` targets (§1.4).
4. `scripts/verify/m94-cloud-funnel.sh` — §3 (NEW, mirrors m80/m89/m90
   isolation; reuses `m82-mock-stripe/server.mjs`).
5. Root `Makefile` — `baas-verify-m94` wrapper + milestone-map entry.
6. **Doc-drift fix** — strip the "(SCAFFOLD)/no consumer yet" labels for
   `SPEND_CAPS_ENABLED`/`ABUSE_GUARD_ENABLED` in `config/cloud/flags.env.example`
   + `config/cloud/README.md` (§0.1).
7. Librarian sync: this doc → `apps/baas/wiki/`; decision → `memory/decisions.md`
   (a new D-0xx "cloud edition = opt-in overlay + m94 funnel gate, mock Stripe,
   zero go-live atoms for the local proof").

Engine-agnostic note (kernel #6): the funnel's CRUD leg should run on the
default Postgres mount; B1 metering already meters every engine via the data
plane, so m94 does not need a per-engine matrix — but the gate must NOT hardcode
anything Postgres-only that would falsely pass on another engine.
