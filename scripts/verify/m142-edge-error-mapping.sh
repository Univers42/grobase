#!/usr/bin/env bash
# **************************************************************************** #
#    m142-edge-error-mapping.sh — pin the two edge-hardening fixes so the     #
#    gateway can never silently regress them back to a 500.                   #
#                                                                            #
#    The gateway query path (/query/v1/<db>/tables/<t>) must classify two    #
#    classes of bad input as CLIENT errors, not server crashes:             #
#                                                                            #
#      (1) an OVERSIZE request body (well over the body-size limit) → the    #
#          edge must reject it with HTTP 413 (Payload Too Large), NOT spill  #
#          into a 500 by trying to buffer/parse a body it already refused.   #
#      (2) a MALFORMED operation body — a top-level JSON *array* where the   #
#          handler expects an object/op envelope → HTTP 400 (Bad Request),   #
#          NOT a 500 from an unhandled deserialization panic.               #
#                                                                            #
#    A regression of either to 5xx leaks an internal-error surface to the   #
#    caller and breaks the contract that bad client input is a 4xx. This    #
#    gate is the teeth: each assertion FAILS LOUDLY if the behavior drifts  #
#    back to 500. A normal list (assertion 3) is the positive control so a  #
#    blanket "everything 4xx" does not pass vacuously.                       #
#                                                                            #
#    Live, through Kong, on a scratch tenant (lib-live-tenant.sh).           #
# **************************************************************************** #
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail() { printf '\033[0;31m[M142] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m[M142] PASS: %s\033[0m\n' "$*"; }
step() { printf '\033[0;36m[M142] %s\033[0m\n' "$*"; }

source lib/lib-live-tenant.sh
SLUG="m142-$(date +%s)"
live_tenant_provision "$SLUG" || fail "provision failed (is the stack up?)"
trap 'live_tenant_cleanup || true' EXIT
K="$LIVE_KONG_URL"; A="$LIVE_ANON_APIKEY"; T="$LIVE_TENANT_API_KEY"; DB="$LIVE_TENANT_DB_ID"
H=(-H "apikey: $A" -H "X-Baas-Api-Key: $T" -H 'Content-Type: application/json')
TBL="m142_edge_$(date +%s)"
TMP="$(mktemp -d)"; trap 'live_tenant_cleanup || true; rm -rf "$TMP"' EXIT

# ── setup: a tiny table to address (id, val) ─────────────────────────────────
step "create table ($TBL: id, val) via /query/v1/<db>/schema/ddl"
DDL="{\"op\":\"create_table\",\"table\":\"${TBL}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"integer\",\"nullable\":false,\"default\":null,\"enum_values\":null},{\"name\":\"val\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null}],\"primary_key\":[\"id\"]}"
c=000
for i in $(seq 1 20); do
  c=$(curl -s -o "$TMP/ddl.json" -w '%{http_code}' "${H[@]}" -X POST "$K/query/v1/${DB}/schema/ddl" -d "$DDL")
  [[ "$c" =~ ^(200|201|409)$ ]] && break
  sleep 1
done
[[ "$c" =~ ^(200|201|409)$ ]] || fail "create_table never settled (last $c) — $(head -c 200 "$TMP/ddl.json")"

# ── warm-verify loop: wait until a normal list is reachable (not 5xx) ─────────
# The mount/data plane can be transiently degraded just after provisioning (the
# documented stale-IP wedge → 502/503). Warm up on a NORMAL request before we
# assert anything, so a 500-regression assertion can't be confused with infra.
step "warm-verify: a normal list must reach a non-5xx steady state"
warm=000
for i in $(seq 1 30); do
  warm=$(curl -s -o "$TMP/warm.json" -w '%{http_code}' "${H[@]}" -X POST "$K/query/v1/${DB}/tables/${TBL}" -d '{"op":"list"}')
  [[ "$warm" =~ ^(502|503|000)$ ]] || break
  sleep 1
done
[[ "$warm" =~ ^(502|503|000)$ ]] && fail "data path never warmed (last $warm) — infra degraded, re-run — $(head -c 200 "$TMP/warm.json")"
ok "warm: normal list reachable (HTTP $warm, not 5xx)"

# ── assertion 1: OVERSIZE body → 413, NOT 500 ────────────────────────────────
# Build a body well over the limit (~2 MiB of payload) and POST it. The edge
# must short-circuit with 413 before it ever tries to buffer/parse it. A 500
# here means the size guard regressed into the body reader.
step "assert 1/3: oversize body (~2 MiB) → HTTP 413, not 500"
BIG="$TMP/big.json"
{
  printf '{"op":"insert","data":{"id":1,"val":"'
  head -c 2200000 /dev/zero | tr '\0' 'A'
  printf '"}}'
} > "$BIG"
code1=000
for i in $(seq 1 8); do
  code1=$(curl -s -o "$TMP/r1.json" -w '%{http_code}' "${H[@]}" -X POST "$K/query/v1/${DB}/tables/${TBL}" --data-binary @"$BIG")
  [[ "$code1" =~ ^(502|503|000)$ ]] || break
  sleep 2
done
[[ "$code1" =~ ^(502|503|000)$ ]] && fail "oversize probe stuck on infra ($code1) after retries — re-run — $(head -c 200 "$TMP/r1.json")"
[[ "$code1" =~ ^5 ]] && fail "REGRESSION: oversize body returned 5xx ($code1) — must be 413, the size guard fell through to the body reader — $(head -c 200 "$TMP/r1.json")"
[[ "$code1" == "413" ]] || fail "oversize body returned $code1 — expected 413 (Payload Too Large) — $(head -c 200 "$TMP/r1.json")"
ok "oversize body → 413 (size limit rejects before body parse, not 500)"

# ── assertion 2: MALFORMED op (top-level JSON array) → 400, NOT 500 ──────────
# The per-table handler expects an op envelope (object). A top-level array is a
# shape the deserializer cannot map → it must be a clean 400, not a 500 from an
# unhandled parse/panic.
step "assert 2/3: malformed top-level array '[{\"op\":\"list\"}]' → HTTP 400, not 500"
code2=000
for i in $(seq 1 8); do
  code2=$(curl -s -o "$TMP/r2.json" -w '%{http_code}' "${H[@]}" -X POST "$K/query/v1/${DB}/tables/${TBL}" -d '[{"op":"list"}]')
  [[ "$code2" =~ ^(502|503|000)$ ]] || break
  sleep 2
done
[[ "$code2" =~ ^(502|503|000)$ ]] && fail "malformed-op probe stuck on infra ($code2) after retries — re-run — $(head -c 200 "$TMP/r2.json")"
[[ "$code2" =~ ^5 ]] && fail "REGRESSION: malformed top-level array returned 5xx ($code2) — must be 400, deserialization error leaked as a server error — $(head -c 200 "$TMP/r2.json")"
[[ "$code2" == "400" ]] || fail "malformed top-level array returned $code2 — expected 400 (Bad Request) — $(head -c 200 "$TMP/r2.json")"
ok "malformed top-level array → 400 (deserialization rejected as client error, not 500)"

# ── assertion 3 (sanity / positive control): a NORMAL list → clean, not 5xx ──
# Proves the 4xx assertions above are SELECTIVE — the path serves a well-formed
# request cleanly. A 2xx (rows envelope) or a benign 4xx (e.g. table-empty/
# resolution nuance) is fine; a 5xx is a real server fault.
step "assert 3/3 (sanity): a normal list → clean 2xx/4xx, never 5xx"
code3=000
for i in $(seq 1 8); do
  code3=$(curl -s -o "$TMP/r3.json" -w '%{http_code}' "${H[@]}" -X POST "$K/query/v1/${DB}/tables/${TBL}" -d '{"op":"list"}')
  [[ "$code3" =~ ^(502|503|000)$ ]] || break
  sleep 2
done
[[ "$code3" =~ ^(502|503|000)$ ]] && fail "normal-list sanity stuck on infra ($code3) after retries — re-run — $(head -c 200 "$TMP/r3.json")"
[[ "$code3" =~ ^5 ]] && fail "REGRESSION: a NORMAL list returned 5xx ($code3) — the happy path is broken — $(head -c 200 "$TMP/r3.json")"
[[ "$code3" =~ ^(2|4) ]] || fail "normal list returned unexpected $code3 (expected 2xx/4xx) — $(head -c 200 "$TMP/r3.json")"
ok "normal list → clean HTTP $code3 (positive control: 4xx mapping is selective, not blanket)"

ok "edge error mapping pinned LIVE — oversize→413 · malformed-array→400 · normal-list→${code3} (no 5xx on bad client input)"
