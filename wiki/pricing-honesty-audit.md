# Pricing / Offer Honesty Audit — Grobase tiers

**The "every offer honest" victory bar.** This audits the single source of truth for service tiers,
[`config/packages/packages.json`](../mini-baas-infra/config/packages/packages.json) (v2), against
**measured reality** — the verify gates and bench artifacts that actually prove each advertised
number/capability/engine. The discipline: a tier line that advertises something with no backing
gate or artifact is **overstated** (or **pending** if the value is honestly projected but not yet
measured).

- **Audited:** `packages.json` v2, schema `version: 2`, `default_package: essential`.
- **Method:** per claim → cite the backing gate (`scripts/verify/m<NN>-*.sh`) or artifact
  (`artifacts/**`) → verdict (**honest** / **overstated** / **pending**).
- **This is a report only.** It does NOT edit `packages.json` (changing live tier definitions needs
  care). The exact lines to fix, if any, are listed at the end.
- **Audit date:** 2026-06-15. **Auditor:** GA-readiness night, Slice F.

---

## 0. Verdict summary

| Dimension | nano | basic | essential | pro | max |
|---|---|---|---|---|---|
| **engines** | honest | honest | honest | honest | honest |
| **capabilities** | honest | honest | honest | honest | honest |
| **rps / burst** | honest | honest | honest | honest | **PENDING** (800 not measured) |
| **quota (B2)** | honest | honest | honest | honest | honest¹ |
| **isolation / pools** | honest | honest | honest | honest | honest |
| **addons** | honest (none) | honest (none) | honest (none) | honest | honest |

**Bottom line: the offer is honest with ONE caveat — `max`'s advertised `rps: 800` is a
*projection*, not a measured number.** Every other line — engines, capabilities, lower-tier rps,
quotas, isolation, addons — is backed by a green gate or a bench artifact. `max`'s 800 rps is
*labelled* as a projection in `packages.json` (`_measured` note) and `wiki/offer-sheet-v2.md` (the
"†" footnote), so it is **honestly disclosed but not measured**. See §6 + the fix list.

¹ `max` advertises **no `quota`** (cumulative usage cap absent = unlimited). That is internally
consistent (the absent-quota = unlimited convention is documented in the manifest `_comment`), so it
is honest *as a tier definition*; it is flagged in §6 only as a billing/abuse exposure for the
hosted product, not as a false claim.

---

## 1. Engines — what each tier may mount

`engines` gates mount registration in the control plane (Go `internal/packages` allowlist; enforced
when `PACKAGE_ENFORCEMENT=1`).

| Tier | Advertised engines | Backing | Verdict |
|---|---|---|---|
| nano | `sqlite` | binocle-nano embeds SQLite in-process (gate **m37**); engine-conformance asserts the sqlite adapter (`m27`, `crates/engine-conformance`) | **honest** |
| basic | `sqlite`, `postgresql` | both adapters exist (`data-plane-pool/src/{sqlite,postgres}.rs`) + conformance (`m27`); `footprint-basic.json` runs the Rust plane Node-free | **honest** |
| essential | `postgresql`, `sqlite` | as above | **honest** |
| pro | `postgresql`, `sqlite`, `mysql`, `mariadb`, `mongodb`, `redis`, `cockroachdb` | adapters exist for pg/sqlite/mysql/mongo/redis; **mariadb served by the MySQL adapter** (`MysqlEngineAdapter::with_engine_name("mariadb")`, descriptor `mariadb()`); **cockroachdb served by the Postgres adapter over pgwire** (`PgDialect::Cockroach`, descriptor `cockroachdb()`). engine-conformance constructs + tests both explicitly (`crates/engine-conformance/tests/conformance.rs`). `footprint-pro.json` runs mongo+mysql live | **honest** |
| max | + `mssql`, `http` | `data-plane-pool/src/{mssql,http}.rs` exist + conformance; `footprint-max.json` runs mariadb + cockroach + mssql + mongo + mysql + redis + postgres all `up` | **honest** |

**Engine count is honest.** There are **8 physical adapters** (`postgres mysql mongo mssql sqlite
redis http dynamodb`). `mariadb`/`cockroachdb` are **not separate adapters** but wire-compatible
engines served by the `mysql`/`postgres` adapters with their **own honest capability descriptors** —
not silent aliases. The adapter source files and `engine-conformance` both confirm this. `dynamodb`
(adapter exists, gate **m88**) is **not listed in any tier** — under-advertised, not over.

> Note: the manifest comments the `engines` addon as "Extra engines (MariaDB, CockroachDB, MSSQL)"
> — accurate to how those engines compose (the `engines-extra` plane), and consistent with the
> per-tier engine lists. No conflict.

---

## 2. Capabilities — the narrowing mask

`capabilities` is a **narrowing mask**: a `false` flag *removes* a capability the engine otherwise
has; the Rust planner (`apply_capability_overrides`) can never widen past the engine descriptor.
Each capability that an engine *promises* is proven *served* in
[`artifacts/oltp-matrix.json`](../mini-baas-infra/artifacts/oltp-matrix.json) (observed==served for
every promised op across pg/mysql/mongo/redis/…), and the mask mechanism itself is gate-proven by
**m28** (CRUD-only mask → `aggregate` 403 `capability_gated`, distinct from a 422 the engine can't
serve) and **m53** (tier engine-allowlist enforcement).

| Capability | nano | basic | essential | pro | max | Backing | Verdict |
|---|---|---|---|---|---|---|---|
| `read` / `write` / `upsert` | ✓ | ✓ | ✓ | ✓ | ✓ | `oltp-matrix.json` (every engine serves list/get/insert/update/delete/upsert); `m25`/`m26` OLTP matrix | **honest** |
| `introspect` | ✓ | ✓ | ✓ | ✓ | ✓ | descriptor introspection (`m27`) | **honest** |
| `aggregate` | ✗ | ✗ | **✓** | ✓ | ✓ | `oltp-matrix.json` aggregate served; mask gate **m28** proves it 403s below `essential` | **honest** (the real differentiator essential>basic) |
| `batch` | ✗ | ✗ | ✗ | **✓** | ✓ | `oltp-matrix.json` batch served (atomicity asserted by `m27`) | **honest** |
| `transactions` | ✗ | ✗ | ✗ | **✓** | ✓ | `/txn` endpoint + conformance transaction leg (`m27`); txn contract in `wiki/txn-contract.md` | **honest** |
| `schema_ddl` / `ddl` | ✗ | ✗ | ✗ | **✓** | ✓ | conformance DDL leg per engine (`m27`); pro/max engines support it | **honest** |

**Capabilities are honest** — every advertised `true` is an op proven *served* in `oltp-matrix.json`,
and every `false` is a real narrowing the mask enforces (`m28`). The ladder (nano/basic = CRUD,
essential adds aggregate, pro adds batch+txn+DDL, max = everything) matches what the planes carry:
`footprint-basic.json` is Node-free (no orchestration plane → no aggregate), `footprint-essential.json`
carries the Node query-router (aggregate served).

---

## 3. rps / burst — the per-request rate cap

Formula (`wiki/offer-sheet-v2.md`, `packages.json _measured`):
`rps = floor(measured_read_capacity × fair_share × 0.5)`, `burst = 2 × rps`.
**Measured ceiling = 400 rps** of reads at p95 < 2 ms before the connection-pool cliff
([`artifacts/bench/capacity-essential.json`](../mini-baas-infra/artifacts/bench/capacity-essential.json):
`max_sustained_rps: 400`; the 500-rps stage collapses to 93.69% errors, p99 10 s). Read p50 1.35–1.91
ms / p95 ~2 ms across the 25→400 rps stages — well within the cited p50 1.63 / p95 2.20 ms moat
(`artifacts/bench/grobase-vs-supabase.json`).

| Tier | rps / burst | fair_share implied (rps ÷ 400 ÷ 0.5) | Position vs 400 ceiling | Backing | Verdict |
|---|---|---|---|---|---|
| nano | 50 / 100 | 0.25 | 12.5% of ceiling | `capacity-essential.json` (400 ceiling); rate is the limiter, plane serves more | **honest** (conservative) |
| basic | 100 / 200 | 0.50 | 25% | as above; 100 rps "well under the measured ~400 single-pool read ceiling" | **honest** |
| essential | 200 / 400 | 1.00 | 50% (half ceiling, headroom for write path) | `capacity-essential.json`; this is the tier the bench was run against | **honest** |
| pro | 400 / 800 | 2.00 | **= the measured ceiling** | `capacity-essential.json` `max_sustained_rps: 400` (single mount sustains exactly this at p95 < 2 ms, 0 server errors at the 400-rps stage) | **honest** (at the proven edge) |
| **max** | **800 / 1600** | 4.00 | **2× the measured single-pool ceiling** | **NO 800-rps sustained artifact exists.** `capacity-essential.json` tops out at 400; the 800-rps stage shows 2.8% errors + p99 8.1 s (cliff). 800 requires the `DATA_PLANE_MAX_POOLS` policy + supavisor multiplexing (B4) — overlay-gated (`docker-compose.pooler.yml`), and the pooler gate **m98** proves only *parity* (pooled == direct, byte-identical), **not a throughput lift to 800**. | **PENDING** |

**rps is honest for nano→pro and PENDING for max.** `pro`'s 400 rps is exactly the measured
`max_sustained_rps`. `max`'s 800 rps is a *projection* that needs the B4 pool-policy + supavisor
lift, which is **not yet measured** — there is no `capacity-max.json`, and `m98` is a parity gate,
not a capacity gate. It is **honestly disclosed** as a projection (`packages.json _measured`:
"max's 800 rps assumes the per-tier `DATA_PLANE_MAX_POOLS` policy + supavisor multiplexing (B4)";
`offer-sheet-v2.md` "†" footnote), so this is **not a deceptive claim** — but per the "measured, not
claimed" discipline an advertised number must cite a measuring artifact, and 800 does not. See §6.

---

## 4. quota (Track-B B2) — the cumulative per-period usage cap

`limits.quota` is the CUMULATIVE per-period cap the control-plane QuotaGuard enforces against
`public.tenant_usage` (B1 metering) — distinct from the per-request rps cap. Enforced ON only when
`QUOTA_ENFORCEMENT=1` + `DATA_PLANE_QUOTA_ENFORCEMENT=1` (flag-gated OFF = byte-parity). The
enforcement mechanism is gate-proven by **m80** (over-quota tenant → 402; under-quota → 200; OFF →
byte-parity). The *metering* it consumes is B1 (gates **m74–m79**).

| Tier | Advertised quota (`query.count`/month) | Backing | Verdict |
|---|---|---|---|
| nano | 100,000 | m80 cites "nano caps query.count@100000/mo" exactly; m74–m79 meter it | **honest** |
| basic | 500,000 | m80 enforcement mechanism (tier value read from packages.json) | **honest** |
| essential | 2,000,000 | as above | **honest** |
| pro | 10,000,000 | as above | **honest** |
| max | **(absent → unlimited)** | manifest `_comment`: "ABSENT quota = unlimited (parity — the byte-identical pre-B2 path)" — a documented convention, internally consistent | **honest¹** |

**Quotas are honest as tier definitions.** The numbers are the values m80 enforces; nano's 100k is
the exact figure the gate names. `max`'s *absent* quota = "unlimited" is a documented, consistent
convention (§6 flags it as a hosted-product abuse/billing exposure, not a false claim).

---

## 5. Isolation, pools & addons

| Claim | Backing | Verdict |
|---|---|---|
| `pool_policy.max_mounts` (1→50) caps databases per tenant | m28 control-plane mount-quota leg (`go test ./internal/packages`) | **honest** |
| `pool_policy.max_conn` (1→25) | feeds the per-tenant pool; density story = pools decoupled from tenant count | **honest** |
| Isolation models (shared_rls + 3 more, per mount) | **m46** (10K tenants → 1 pool under SHARE_POOLS, 0×5xx); `footprint-live-24887.json` (24,887 live tenants @ 2.6 MiB data plane, 0 standing pools) | **honest** |
| `max` `security_mode: "max"` | distinct from baseline; security gates m60/m65/m104/m106/m107 exist | **honest** (mode is a real config, not a marketing word) |
| pro addons: `realtime`, `analytics` | realtime live gate **m44** (topic filter + owner-filtered SSE); analytics plane in `footprint-pro.json` | **honest** |
| max addons: + `observability`, `engines`, `functions`, `storage` | storage live gate **m55** (byte round-trip + owner isolation), functions live gate **m56** (deploy/invoke + DB-trigger + tenant scope), observability plane (m85 per-tenant obs), engines-extra plane in `footprint-max.json` | **honest** |

Addons map 1:1 to compose planes (`addons` block), each present in the matching tier's
`footprint-*.json` profiles string. **All honest.**

---

## 6. Overstated / pending lines — the exact fixes

Only **one** claim fails the "measured, not claimed" bar; one more is a *consistency* flag rather
than a falsehood.

### FIX 1 (the only overstatement) — `max` advertises an unmeasured rps

- **File:** `config/packages/packages.json`
- **Line 112:** `"limits": { "rps": 800, "burst": 1600 },`
- **Problem:** 800 rps has **no measuring artifact** — `capacity-essential.json` tops out at
  `max_sustained_rps: 400`; the 800-rps stage is past the cliff (2.8% errors, p99 8.1 s). The B4
  supavisor lift that would sustain 800 is overlay-gated and only *parity*-proven (m98), not
  *capacity*-proven. Per discipline #1, an advertised number must cite a measuring artifact.
- **It is honestly disclosed** as a projection (the `_measured` note at line 4 + `offer-sheet-v2.md`
  "†" footnote), so this is **pending measurement, not deception**.
- **Two acceptable fixes (pick one):**
  1. **Measure it.** Run a capacity bench against `max` with the pooler overlay
     (`make -C mini-baas-infra bench-capacity` under `docker-compose.pooler.yml` + `DATA_PLANE_MAX_POOLS`),
     write `artifacts/bench/capacity-max.json` with `max_sustained_rps >= 800`, then the line is
     **honest**. *(This is the right fix — it turns a projection into a measurement.)*
  2. **Or footnote it in the manifest the way the wiki already does** — e.g. add `"rps_projected": true`
     (or keep 800 but ensure every customer-facing surface carries the "requires B4 multiplexing,
     not yet measured at 800" caveat already in `_measured`). This keeps the disclosure but does not
     satisfy "every advertised number cites a measuring artifact".
- **Recommended:** fix #1 (measure), because GA wants the number proven, not caveated.

### FLAG 2 (consistency, not a falsehood) — `max` has no `quota`

- **File:** `config/packages/packages.json`, **line 112** (`max` `limits` has no `quota` key).
- **Status:** **honest** as a tier definition (absent quota = unlimited is a documented convention,
  manifest `_comment` line 3). **Not** a fix-required overstatement.
- **Why flagged:** for the *hosted* product (Track-B B7 go-live), an unlimited tier with metered
  billing means usage is uncapped — that is a spend/abuse exposure handled by the spend-cap +
  abuse-guard layer (gates **m89**, **m90**, **m120** spend/suspend), **not** by a quota. If the
  hosted `max` should have a (high) hard ceiling for abuse containment, add a `quota` line; if
  "unlimited, spend-capped" is the intended offer, leave it and ensure `/compare` + the trust center
  say "unlimited usage, spend-capped" rather than implying an unmetered free-for-all. **No code/JSON
  change required for honesty** — this is a product-positioning decision.

### No other overstatements

nano→pro rps, all quotas, every engine, every capability `true`/`false`, every isolation claim, and
every addon are backed by a green gate or a bench artifact (cited per row above). `dynamodb` (m88)
is *under*-advertised (in no tier) — the opposite of a honesty problem.

---

## 7. Reproduce this audit

```bash
# the source of truth
cat config/packages/packages.json

# the measured ceiling behind rps (400, not 800)
jq '{package,max_sustained_rps,stages:[.stages[]|{rate,err_pct,p95:.http.p95}]}' \
  artifacts/bench/capacity-essential.json

# every advertised capability is "served"
jq '.engines' artifacts/bench/../oltp-matrix.json   # (artifacts/oltp-matrix.json)

# the gates that enforce the mask / engine allowlist / quota
bash mini-baas-infra/scripts/verify/m28-packages.sh            # mask + mount-quota
bash mini-baas-infra/scripts/verify/m53-package-enforcement.sh # engine allowlist (PACKAGE_ENFORCEMENT=1)
bash mini-baas-infra/scripts/verify/m80-quota-enforce.sh       # cumulative quota
bash mini-baas-infra/scripts/verify/m27-conformance.sh         # adapter == descriptor (incl. mariadb/cockroach dialects)
bash mini-baas-infra/scripts/verify/m44-one-realtime.sh        # realtime addon
bash mini-baas-infra/scripts/verify/m55-storage-live.sh        # storage addon
bash mini-baas-infra/scripts/verify/m56-functions-live.sh      # functions addon

# the density behind isolation/pools
jq . artifacts/scale/footprint-live-24887.json                 # 24,887 tenants @ 2.6 MiB, 0 pools
```

---

*Discipline: every number in this audit cites a concrete artifact path or gate. The single
"PENDING" (max 800 rps) is explicitly called out as projected, not measured — needs
`artifacts/bench/capacity-max.json` from a pooler-overlay capacity run. No claim was invented;
where a number is not measured, this audit says so.*
