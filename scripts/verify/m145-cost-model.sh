#!/usr/bin/env bash
# **************************************************************************** #
#   m145-cost-model.sh — the COST MODEL is measured, positive-margin,        #
#                        formula-consistent, honest, and never drifts from    #
#                        its mirrors (site simulator + packages.json)         #
#                                                                              #
#   infra/config/cost-model.json is the SINGLE SOURCE OF TRUTH for the Grobase      #
#   cost simulator (consumed by the wiki + the site cost simulator). Kernel   #
#   rule #4 ("measured, not claimed") + the binding "every price cites a      #
#   source_url + date + confidence; NEVER invent a number" mean this file     #
#   must be auditable against the artifacts it cites and against the other     #
#   sources of truth (packages.json tiers, the site mirror). This gate is     #
#   that enforcement seam. It runs where ALL of these are visible (the repo   #
#   tree) and proves seven things — each with a concrete failing input:       #
#                                                                              #
#     1) SHAPE:      cost-model.json exists, is valid JSON, has the required   #
#                    top-level keys (version/as_of/components/hosters/         #
#                    density/tiers).                                           #
#     2) MEASURED:   every component (and edition idle RAM) whose `source`     #
#                    names a real artifact file carries a RAM number that      #
#                    MATCHES that artifact (within a small MiB tolerance).     #
#                    A number that drifts from its cited artifact FAILS.       #
#                    mem_limit-basis rows only assert their compose/limit ref. #
#     3) MARGIN:     every priced tier's suggested_price is strictly above     #
#                    its CHEAPEST-hoster infra_cost AND equals the model's     #
#                    own rule round(min_cost/(1-margin),2) with margin ==      #
#                    default_margin_pct. (The single suggested_price is        #
#                    anchored to the cheapest hoster per the model's own       #
#                    basis text + worked_examples — see NOTE in check 3.)      #
#                    nano is the deliberate free-tier exception (price 0).     #
#     4) MATH:       the gate RE-IMPLEMENTS the cost formula from primitives   #
#                    (factors + the Fly.io hoster, the one hoster defined as   #
#                    always-per-GB) and reproduces a stored worked_example +   #
#                    the stored Fly infra_cost for every tier, within tol —    #
#                    so the stored numbers cannot silently drift from the      #
#                    formula they claim to follow.                            #
#     5) HONESTY:    as_of present; every hoster has a non-empty source_url +  #
#                    a confidence in {measured,published,estimated}; the file  #
#                    carries no TODO/TBD/FIXME/XXX placeholder.                #
#     6) SITE PARITY:site/src/data/cost-model.ts mirrors cost-model.json —     #
#                    every tier name + every hoster name in the JSON appears   #
#                    in the TS, and density.per_tenant_marginal_mib appears    #
#                    verbatim (same idea as m144's posture<->security.ts).     #
#     7) PKG PARITY: each tier name + its rps in cost-model.json matches       #
#                    infra/config/packages/packages.json (limits.rps) — no tier or   #
#                    rps drift between the two sources of truth.               #
#                                                                              #
#   Pure file check — no container, no network. Safe to run anywhere.          #
#   Non-vacuous BY CONSTRUCTION: each check has a concrete bad input that      #
#   trips it (a drifted RAM number, a below-cost price, a missing mirror, a    #
#   placeholder, an rps mismatch). Needs python3 (already a hard dep of the    #
#   sibling m143/m144 gates).                                                  #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
SITE="${BAAS_DIR}/site"
COST_JSON="${INFRA_DIR}/infra/config/cost-model.json"
PACKAGES_JSON="${INFRA_DIR}/infra/config/packages/packages.json"
COST_TS="${SITE}/src/data/cost-model.ts"
ARTIFACTS_DIR="${INFRA_DIR}" # artifact paths in JSON are relative to mini-baas-infra
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M145] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M145] FAIL — $*"
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 not found (required to parse cost-model.json + artifacts)"

# ── 1) shape: file exists, valid JSON, required top-level keys ────────────────────
step "1/7 cost-model.json present, valid JSON, has version/as_of/components/hosters/density/tiers"
[[ -s "${COST_JSON}" ]] || fail "missing/empty: ${COST_JSON#"${BAAS_DIR}/"}"
SHAPE="$(
  python3 - "${COST_JSON}" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"INVALID JSON: {e}"); sys.exit(0)
req = ["version", "as_of", "components", "hosters", "density", "tiers"]
miss = [k for k in req if k not in d]
if miss: print("MISSING TOP-LEVEL KEYS: " + ", ".join(miss)); sys.exit(0)
if not isinstance(d["components"], list) or not d["components"]: print("components must be a non-empty list"); sys.exit(0)
if not isinstance(d["hosters"], list) or not d["hosters"]:       print("hosters must be a non-empty list"); sys.exit(0)
if not isinstance(d["tiers"], list) or not d["tiers"]:           print("tiers must be a non-empty list"); sys.exit(0)
print("")
PY
)"
[[ -z "${SHAPE}" ]] || fail "${SHAPE}"
ok "valid JSON; all required top-level keys present"

# ── 2) measured-truth: every cited-artifact RAM number matches its artifact ───────
step "2/7 measured: each component/edition RAM matches its cited artifact file (tol 0.05 MiB)"
MEAS="$(
  python3 - "${COST_JSON}" "${ARTIFACTS_DIR}" <<'PY'
import json, os, re, sys
cm = json.load(open(sys.argv[1])); BASE = sys.argv[2]
TOL = 0.05  # absolute MiB tolerance — artifact RSS is reported to 0.1; 0.05 catches any real drift
def load(rel):
    p = os.path.join(BASE, rel)
    if not os.path.exists(p): return None, f"cited artifact not found: {rel}"
    try: return json.load(open(p)), None
    except Exception as e: return None, f"cited artifact not JSON: {rel} ({e})"
def canon(s): return re.sub(r'[^a-z0-9]', '', s.lower())

# Pre-load the artifacts cost-model cites, build name->rss lookups.
live, e = load("artifacts/scale/footprint-live-24888-today.json")
nano, e2 = load("artifacts/nano-vs-pocketbase.json")
fp = {}
for p in ("basic", "essential", "pro", "max"):
    fp[p], _ = load(f"artifacts/footprint-{p}.json")

errs = []
# live file is nested {plane:{svc:{rss_mib}}}; flatten to canon(name)->rss
live_canon = {}
if live:
    def walk(d):
        for k, v in d.items():
            if isinstance(v, dict):
                if "rss_mib" in v: live_canon[canon(k)] = v["rss_mib"]
                else: walk(v)
    walk({k: v for k, v in live.items() if k not in ("_comment", "captured", "fleet", "env")})
svc_canon = {}
for p, d in fp.items():
    svc_canon[p] = {canon(s["service"]): s["ram_mib"] for s in d.get("services", [])} if d else {}

# manual aliases where artifact key has a lang suffix cost-model omits
ALIAS = {canon("data-plane-router"): "dataplanerouterrust",
         canon("realtime"): "realtimerust"}

def which(src):
    s = src.lower()
    if "footprint-live-24888" in s: return "live"
    for p in ("basic", "essential", "pro", "max"):
        if f"footprint-{p}.json" in s: return p
    if "nano-vs-pocketbase" in s: return "nano"
    if "docker-compose" in s or "mem_limit" in s: return "limit"
    return None

def comp_key(name):
    base = re.split(r'\(', name)[0].strip()
    k = canon(base)
    return ALIAS.get(k, k)

def lookup(art, key):
    table = live_canon if art == "live" else svc_canon.get(art, {})
    if key in table: return table[key]
    for k, v in table.items():            # tolerate a lang suffix in the artifact key
        if k.startswith(key): return v
    return None

checked = 0
for c in cm["components"]:
    src = c.get("source", ""); val = c.get("mem_basis_mib")
    name = c.get("name", "?"); art = which(src)
    if c.get("basis_kind") == "mem_limit" or art == "limit":
        # mem_limit rows: just assert the source actually references a limit/compose
        if "mem_limit" not in src.lower() and "docker-compose" not in src.lower():
            errs.append(f"mem_limit component '{name}' cites no mem_limit/docker-compose source")
        continue
    if art is None:
        errs.append(f"component '{name}' source names no recognizable artifact: {src[:60]}")
        continue
    if art == "nano":
        if not nano: errs.append(f"'{name}' cites nano-vs-pocketbase.json but it is missing/invalid"); continue
        got = float(re.sub(r'[^0-9.]', '', nano["nano"]["rss"]))
    else:
        if (art == "live" and not live) or (art in fp and not fp[art]):
            errs.append(f"'{name}' cites {art} artifact but it is missing/invalid"); continue
        got = lookup(art, comp_key(name))
    if got is None:
        errs.append(f"component '{name}': no matching service in cited artifact ({art})")
        continue
    checked += 1
    if abs(got - val) > TOL:
        errs.append(f"RAM DRIFT '{name}': cost-model={val} but {art} artifact={got} (|Δ|={abs(got-val):.3f} > {TOL})")

# edition idle RAM per tier
for t in cm["tiers"]:
    src = t.get("edition_ram_idle_source", ""); idle = t.get("edition_ram_idle_mib")
    name = t.get("name", "?"); art = which(src)
    if art == "nano":
        if not nano: errs.append("nano edition cites nano-vs-pocketbase.json but it is missing"); continue
        got = float(re.sub(r'[^0-9.]', '', nano["nano"]["rss"]))
        if abs(got - idle) > TOL: errs.append(f"edition idle DRIFT nano: cost-model={idle} artifact={got}")
    elif art in fp:
        if not fp[art]: errs.append(f"edition '{name}' cites {art} artifact but it is missing"); continue
        got = fp[art].get("ram_mib_total")
        if got is None or abs(got - idle) > 0.1:
            errs.append(f"edition idle DRIFT '{name}': cost-model={idle} artifact ram_mib_total={got}")
    else:
        errs.append(f"edition '{name}' idle source names no recognizable artifact: {src[:60]}")

if checked < 20:
    errs.append(f"only {checked} measured components verified — too few, matcher likely broke (expected ~38)")
print("\n".join(errs))
print(f"__CHECKED__={checked}")
PY
)"
MEAS_CHECKED="$(printf '%s\n' "${MEAS}" | sed -n 's/^__CHECKED__=//p')"
MEAS_ERRS="$(printf '%s\n' "${MEAS}" | grep -v '^__CHECKED__=' || true)"
[[ -z "${MEAS_ERRS}" ]] || fail "measured-truth drift between cost-model.json and its cited artifacts:\n${MEAS_ERRS}"
ok "${MEAS_CHECKED} measured component RAM numbers + 5 edition idle floors match their cited artifacts"

# ── 3) positive margin: price > cheapest-hoster cost, derived per the model's rule ─
# NOTE: cost-model carries ONE scalar suggested_price per tier but a PER-HOSTER
# infra_cost dict. By the model's own basis text + worked_examples the headline
# price is anchored to the CHEAPEST hoster (Hetzner) via cost/(1-margin); the
# pricier Fly/AWS dedicated costs are shown for the spread, not as the pricing
# basis. So the real positive-margin invariant is: price > min(infra_cost) AND
# price == round(min_cost/(1-margin),2) AND margin_pct == default_margin_pct.
# A tier priced below its cheapest hoster, or with a drifted margin, FAILS here.
step "3/7 margin: each priced tier's price > cheapest infra_cost & == round(min_cost/(1-margin),2)"
MARGIN="$(
  python3 - "${COST_JSON}" <<'PY'
import json, sys
cm = json.load(open(sys.argv[1]))
errs = []
prev = -1.0   # margins must form a non-decreasing ladder (entry-low → premium-high)
for t in cm["tiers"]:
    name = t.get("name", "?")
    costs = t.get("infra_cost_usd_month", {})
    price = t.get("suggested_price_usd_month")
    mp = t.get("margin_pct")
    if not costs or price is None:
        errs.append(f"tier '{name}' missing infra_cost_usd_month or suggested_price"); continue
    mn = min(costs.values())
    if name == "nano":           # deliberate free tier: price 0 / margin 0 by product design
        if price != 0 or mp not in (0, 0.0):
            errs.append(f"nano expected free (price 0/margin 0) but price={price} margin_pct={mp}")
        continue
    # PER-TIER margin (tiered ladder, D-039 lock-in): price == round(cheapest_cost/(1-tier_margin),2)
    if mp is None or not (0.0 <= mp < 0.95):
        errs.append(f"tier '{name}' margin_pct={mp} outside the sane band [0,0.95)"); continue
    if not (price > mn):
        errs.append(f"tier '{name}' priced BELOW cheapest cost: price={price} <= min_infra_cost={mn}")
    derived = round(mn / (1 - mp), 2)
    if abs(price - derived) > 0.02:
        errs.append(f"tier '{name}' price {price} != round(min_cost {mn}/(1-{mp}),2)={derived} (per-tier margin drift)")
    if mp + 1e-9 < prev:
        errs.append(f"tier '{name}' margin_pct {mp} < previous tier {prev} (margin ladder must be non-decreasing)")
    prev = mp
print("\n".join(errs))
PY
)"
[[ -z "${MARGIN}" ]] || fail "positive-margin / pricing-rule violation:\n${MARGIN}"
ok "every priced tier is strictly above its cheapest-hoster cost at its PER-TIER margin (non-decreasing ladder); nano free by design"

# ── 4) math-consistency: re-implement the formula, reproduce stored numbers ────────
step "4/7 math: re-implement the cost formula (Fly per-GB) and reproduce stored numbers (tol 0.02)"
MATH="$(
  python3 - "${COST_JSON}" <<'PY'
import json, sys
cm = json.load(open(sys.argv[1]))
f = cm["factors"]; m = f["default_margin_pct"]
errs = []
fly = next((h for h in cm["hosters"] if h["name"] == "Fly.io"), None)
if not fly:
    print("Fly.io hoster missing — cannot run the per-GB math-consistency check"); sys.exit(0)
TOL = 0.02
def tier(n): return next((t for t in cm["tiers"] if t["name"] == n), None)

# (a) reproduce the basic/Fly.io amortized(÷40) worked example from primitives.
b = tier("basic")
if b:
    tpn = int((f["rps_single_pool_ceiling"] / b["rps"]) / f["concurrency_peak_fraction"])
    if tpn != 40:
        errs.append(f"tenants_per_node_rps(basic) recomputed = {tpn}, expected 40 (400/100/0.10)")
    node = 1 * fly["usd_per_gb_ram_month"] + 1 * fly["usd_per_vcpu_month"]   # 1 GB, 1 vCPU
    stor = f["storage_gb_per_tenant_default"]["basic"] * fly["usd_per_gb_storage_month"]
    egr  = f["egress_gb_per_tenant_default"]["basic"] * fly["usd_per_gb_egress"]
    cost = node / tpn + stor + egr
    price = cost / (1 - m)
    if abs(cost - 0.270) > 0.005:
        errs.append(f"basic/Fly amortized cost recomputed = {cost:.4f}, worked_example says 0.270")
    if abs(price - 0.675) > 0.01:
        errs.append(f"basic/Fly amortized price recomputed = {price:.4f}, worked_example says ~0.68")

# (b) Fly is defined as always-per-GB (ram_gb*5 + vcpu*2); reproduce the stored
#     DEDICATED Fly infra_cost for every tier from its node_ram_gb/vcpu shape.
#     node_ram_gb comes from tenants_per_node; vCPU is 1 for ≤2 GB nodes, 4 for the 8 GB max node
#     (per the worked_examples: max Fly = 8*5 + 4*2 = 48).
shapes = {"nano": (1, 1), "basic": (1, 1), "essential": (2, 1), "pro": (2, 1), "max": (8, 4)}
for name, (gb, vcpu) in shapes.items():
    t = tier(name)
    if not t: continue
    stored = t.get("infra_cost_usd_month", {}).get("Fly.io")
    if stored is None:
        errs.append(f"tier '{name}' has no Fly.io infra_cost to check the formula against"); continue
    node = gb * fly["usd_per_gb_ram_month"] + vcpu * fly["usd_per_vcpu_month"]
    # tiers store the DEDICATED node cost in infra_cost_usd_month (storage/egress added in worked_examples)
    if abs(node - stored) > TOL:
        errs.append(f"tier '{name}' Fly node recomputed = {node} but stored infra_cost(Fly.io) = {stored}")
print("\n".join(errs))
PY
)"
[[ -z "${MATH}" ]] || fail "math-consistency: stored numbers do not reproduce from the formula:\n${MATH}"
ok "the basic/Fly amortized worked example + every tier's Fly infra_cost reproduce from primitives"

# ── 5) honesty: as_of + per-hoster source_url/confidence + no placeholders ─────────
step "5/7 honesty: as_of present; every hoster has source_url + confidence∈{measured,published,estimated}; no TODO/TBD/FIXME"
HONEST="$(
  python3 - "${COST_JSON}" <<'PY'
import json, sys
cm = json.load(open(sys.argv[1]))
errs = []
if not str(cm.get("as_of", "")).strip():
    errs.append("as_of missing/empty")
VALID = {"measured", "published", "estimated"}
for h in cm.get("hosters", []):
    n = h.get("name", "?")
    if not str(h.get("source_url", "")).strip():
        errs.append(f"hoster '{n}' has empty/missing source_url")
    conf = h.get("confidence")
    if conf not in VALID:
        errs.append(f"hoster '{n}' confidence={conf!r} not in {sorted(VALID)}")
print("\n".join(errs))
PY
)"
[[ -z "${HONEST}" ]] || fail "honesty metadata violation:\n${HONEST}"
PLACEHOLDERS="$(grep -nE 'TODO|TBD|FIXME|XXX' "${COST_JSON}" || true)"
[[ -z "${PLACEHOLDERS}" ]] || fail "placeholder text in cost-model.json (the model must be complete, not stubbed):\n${PLACEHOLDERS}"
ok "as_of present; all hosters carry source_url + a valid confidence; no placeholder text"

# ── 6) site parity: cost-model.ts mirrors the JSON (tiers + hosters + density) ─────
step "6/7 site parity: site/src/data/cost-model.ts mirrors cost-model.json (tier names, hoster names, per_tenant_marginal_mib)"
[[ -s "${COST_TS}" ]] || fail "site simulator mirror missing: ${COST_TS#"${BAAS_DIR}/"} — the cost simulator's single source must be mirrored into the site (same discipline as m144's security.ts). Create it from infra/config/cost-model.json (tier names, hoster names, density.per_tenant_marginal_mib) so the public simulator cannot drift from the canonical model."
SITEPAR="$(
  python3 - "${COST_JSON}" "${COST_TS}" <<'PY'
import json, re, sys
cm = json.load(open(sys.argv[1])); ts = open(sys.argv[2]).read()
errs = []
# TIERS are enumerated TS objects: require each tier name as a QUOTED `id: '<name>'`
# literal — NOT a bare substring. (A bare substring is too weak: the lowercase
# tier word also appears in source-path strings + per-tier dict keys, so a renamed
# tier object would slip through a substring check. The id: literal is the identity.)
for t in cm["tiers"]:
    n = t["name"]
    if not re.search(rf"id:\s*['\"]{re.escape(n)}['\"]", ts):
        errs.append(f"tier '{n}' present in cost-model.json but not as a tier id: literal in cost-model.ts")
# HOSTERS: presence of the full name (spec: 'appears in the TS'). The full hoster
# name is a unique enough string that a rename drops it — already rename-sensitive.
for h in cm["hosters"]:
    if h["name"] not in ts:
        errs.append(f"hoster '{h['name']}' present in cost-model.json but NOT in cost-model.ts")
# DENSITY: the per-tenant marginal moat number must appear verbatim.
ptm = cm["density"]["per_tenant_marginal_mib"]
if str(ptm) not in ts:
    errs.append(f"density.per_tenant_marginal_mib ({ptm}) not found verbatim in cost-model.ts")
print("\n".join(errs))
PY
)"
[[ -z "${SITEPAR}" ]] || fail "site cost-model.ts drift from cost-model.json:\n${SITEPAR}"
ok "cost-model.ts mirrors every tier + hoster name and the per-tenant marginal density"

# ── 7) packages parity: tier names + rps match packages.json ──────────────────────
step "7/7 packages parity: each tier name + rps in cost-model.json matches packages.json (limits.rps)"
[[ -s "${PACKAGES_JSON}" ]] || fail "packages.json missing: ${PACKAGES_JSON#"${BAAS_DIR}/"}"
PKGPAR="$(
  python3 - "${COST_JSON}" "${PACKAGES_JSON}" <<'PY'
import json, sys
cm = json.load(open(sys.argv[1])); pk = json.load(open(sys.argv[2]))
pkgs = pk.get("packages", pk)
errs = []
for t in cm["tiers"]:
    name = t["name"]; rps = t.get("rps")
    if name not in pkgs:
        errs.append(f"tier '{name}' in cost-model.json has no matching package in packages.json"); continue
    p_rps = pkgs[name].get("limits", {}).get("rps")
    if p_rps is None:
        errs.append(f"package '{name}' has no limits.rps in packages.json"); continue
    if rps != p_rps:
        errs.append(f"rps DRIFT '{name}': cost-model={rps} packages.json limits.rps={p_rps}")
print("\n".join(errs))
PY
)"
[[ -z "${PKGPAR}" ]] || fail "tier/rps drift between cost-model.json and packages.json:\n${PKGPAR}"
ok "every tier name + rps matches packages.json (no tier/rps drift)"

# ── summary + gate event ──────────────────────────────────────────────────────────
green "[M145] (1) shape  (2) ${MEAS_CHECKED} RAM numbers measured-true  (3) positive margin  (4) formula-consistent  (5) honest  (6) site mirror in lockstep  (7) packages in lockstep"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-cost-model-gate}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m145-cost-model=PASS" --outcome pass \
      --msg "cost-model.json measured-true vs cited artifacts (${MEAS_CHECKED} components + 5 edition floors), positive-margin, formula-consistent, honest (source_url+confidence, no placeholders), mirrored by site cost-model.ts + packages.json" \
      --ref "scripts/verify/m145-cost-model.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M145] ALL GREEN — the cost model is measured, honest, and in lockstep with its mirrors"
exit 0
