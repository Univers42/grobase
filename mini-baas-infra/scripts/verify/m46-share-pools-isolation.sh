#!/usr/bin/env bash
# **************************************************************************** #
#   m46-share-pools-isolation.sh — cross-engine SHARE_POOLS proof (§7.5)       #
# **************************************************************************** #
#
# The live gate behind master-plan §7.5 / commit e20a49a: SHARE_POOLS pool-
# collapse is correct on EVERY engine, not just Postgres. Two `shared_rls`
# tenants are pointed at ONE mysql backend and ONE mongo backend, then we prove:
#
#   (a) NO 502 — both tenants serve through the shared pool (the single-owner
#       check_tenant guard is correctly skipped);
#   (b) ISOLATION — each tenant lists ONLY its own rows, never the other's
#       (owner_id predicate on mysql; owner_id+tenant_id, both from the request
#       identity, on mongo — the fix that switched mongo off the pool field);
#   (c) COLLAPSE — under SHARE_POOLS=1 the two tenants share ONE pool per engine
#       (pool_events created delta = 1/engine), vs 2 under SHARE_POOLS=0.
#
# Heavy + live (provisions real tenants) → SKIPs unless SHARE_POOLS_PROBE=1, so
# verify-all stays cheap. SHARE_POOLS_EXPECT (1|0) is the data-plane's configured
# mode; the collapse assertion is keyed to it. SKIPs (exit 0) when stack is down.
#
#   SHARE_POOLS_PROBE=1 SHARE_POOLS_EXPECT=1 bash scripts/verify/m46-share-pools-isolation.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/service-auth.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-live-tenant.sh"

green(){ printf '\033[0;32m[M46] %s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m[M46] FAIL: %s\033[0m\n' "$*"; }
cyan(){ printf '\033[0;36m[M46] %s\033[0m\n' "$*"; }
skip(){ printf '\033[1;33m[M46] SKIP: %s\033[0m\n' "$*"; exit 0; }

[[ "${SHARE_POOLS_PROBE:-0}" == "1" ]] || skip "set SHARE_POOLS_PROBE=1 to run the live cross-engine probe"
docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 || skip "data plane not up"
[[ "$(docker inspect --format '{{.State.Health.Status}}' mini-baas-tenant-control 2>/dev/null)" == "healthy" ]] || skip "tenant-control not healthy"

EXPECT="${SHARE_POOLS_EXPECT:-1}"   # 1 = expect collapse (shared), 0 = per-tenant
DP="mini-baas-data-plane-router-rust"
TS="$(date +%s)"
ART_DIR="${ROOT}/artifacts/bench"; mkdir -p "${ART_DIR}"
ART="${ART_DIR}/share-pools-cross-engine-expect${EXPECT}.json"

# Same DSNs for BOTH tenants → effective_pool_key collapses them onto one pool
# per engine when SHARE_POOLS is on. Creds + in-network hostnames from compose.
MYSQL_DSN="mysql://mini_baas:mini_baas_pw@mysql:3306/mini_baas"
MONGO_DSN="mongodb://mongo:mongo@mongo:27017/mini_baas?authSource=admin"
TABLE="sp_items_${TS}"   # unique per run (mysql table + mongo collection)

metric(){ # $1 = metric substring → value (pipefail-safe: empty on no-match)
  local port v; port="$(docker port "${DP}" 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  # grep -v '^#' drops the Prometheus `# HELP`/`# TYPE` lines so a bare metric
  # name (no `{labels}`) matches the VALUE line, not the comment (whose $2 is the
  # word HELP → an arithmetic crash under set -u downstream).
  v="$(curl -s "http://127.0.0.1:${port}/metrics" 2>/dev/null | grep -F "$1" | grep -v '^#' | awk '{print $2}' | head -1 || true)"
  printf '%s' "${v}"
}
created(){ metric 'baas_data_plane_pool_events_total{service="data-plane-router",event="created"}'; }

# Register a mount under a tenant via the Kong admin route. $1 slug $2 engine
# $3 dsn $4 name → echoes the mount id (fails the gate on a non-201).
reg_mount(){
  local slug="$1" engine="$2" dsn="$3" name="$4" code
  code="$(curl -s -o /tmp/m46-mount.json -w '%{http_code}' -X POST \
    "${KONG}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${slug}" -H 'Content-Type: application/json' \
    -d "{\"engine\":\"${engine}\",\"name\":\"${name}\",\"connection_string\":\"${dsn}\",\"isolation\":\"shared_rls\"}")"
  [[ "${code}" == "201" ]] || { red "mount ${engine}/${name} register HTTP ${code}: $(cat /tmp/m46-mount.json)"; exit 1; }
  _lt_json_field id < /tmp/m46-mount.json
}

# CRUD query through the gateway. $1 key $2 db_id $3 operation-json → raw response.
q(){ curl -s -X POST "${KONG}/data/v1/query" \
  -H "apikey: ${ANON}" -H "X-Baas-Api-Key: $1" -H 'Content-Type: application/json' \
  -d "{\"db_id\":\"$2\",\"operation\":$3}"; }

cyan "cross-engine SHARE_POOLS probe (EXPECT=${EXPECT}: $([[ ${EXPECT} == 1 ]] && echo 'collapse — 1 pool/engine' || echo 'per-tenant — 2 pools/engine'))"

# ── 1) provision two enterprise-tier tenants (any-engine mounts allowed) ──────
live_tenant_provision "sp-a-${TS}" >/dev/null || { red "provision A failed"; exit 1; }
A_KEY="${LIVE_TENANT_API_KEY}"; A_SLUG="${LIVE_TENANT_SLUG}"; A_KEYID="${LIVE_TENANT_KEY_ID}"; A_PG="${LIVE_TENANT_DB_ID}"
KONG="${LIVE_KONG_URL}"; ANON="${LIVE_ANON_APIKEY}"; SERVICE_KEY="${LIVE_SERVICE_APIKEY}"
live_tenant_provision "sp-b-${TS}" >/dev/null || { red "provision B failed"; exit 1; }
B_KEY="${LIVE_TENANT_API_KEY}"; B_SLUG="${LIVE_TENANT_SLUG}"; B_KEYID="${LIVE_TENANT_KEY_ID}"; B_PG="${LIVE_TENANT_DB_ID}"
cyan "tenants: A=${A_SLUG} B=${B_SLUG}"

cleanup(){
  set +e
  # Drop the scratch mysql table via the platform DDL path (owner-scoped) so
  # repeat runs don't accumulate sp_items_* in the shared db. Best-effort.
  if [[ -n "${A_MY:-}" && -n "${A_KEY:-}" ]]; then
    curl -s -o /dev/null -X POST "${KONG}/data/v1/schema/ddl" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" -H 'Content-Type: application/json' \
      -d "{\"db_id\":\"${A_MY}\",\"ddl\":{\"op\":\"drop_table\",\"table\":\"${TABLE}\"}}" 2>/dev/null
  fi
  for m in "${A_MY:-}" "${B_MY:-}" "${A_MG:-}" "${B_MG:-}" "${A_PG:-}" "${B_PG:-}"; do
    [[ -n "${m}" ]] || continue
    svc_auth DELETE "/databases/${m}" ""
    curl -s -o /dev/null -X DELETE "${KONG}/admin/v1/databases/${m}" \
      -H "apikey: ${SERVICE_KEY}" "${SVC_AUTH[@]}" -H "X-Tenant-Id: ${A_SLUG}" 2>/dev/null
  done
  for t in "${A_SLUG}:${A_KEYID}" "${B_SLUG}:${B_KEYID}"; do
    local slug="${t%%:*}" kid="${t##*:}"
    svc_auth DELETE "/v1/tenants/${slug}/keys/${kid}" ""
    curl -s -o /dev/null -X DELETE "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${slug}/keys/${kid}" "${SVC_AUTH[@]}" 2>/dev/null
    svc_auth DELETE "/v1/tenants/${slug}" ""
    curl -s -o /dev/null -X DELETE "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${slug}" "${SVC_AUTH[@]}" 2>/dev/null
  done
}
trap cleanup EXIT

# ── 2) register mysql + mongo shared_rls mounts (SAME DSN) under each tenant ──
A_MY="$(reg_mount "${A_SLUG}" mysql   "${MYSQL_DSN}" "sp-my-a-${TS}")"
B_MY="$(reg_mount "${B_SLUG}" mysql   "${MYSQL_DSN}" "sp-my-b-${TS}")"
A_MG="$(reg_mount "${A_SLUG}" mongodb "${MONGO_DSN}" "sp-mg-a-${TS}")"
B_MG="$(reg_mount "${B_SLUG}" mongodb "${MONGO_DSN}" "sp-mg-b-${TS}")"
cyan "mounts: mysql A=${A_MY} B=${B_MY} · mongo A=${A_MG} B=${B_MG}"
# Pre-probe baseline: pools open BEFORE any data query to my mounts (mount
# registration is control-plane only — the data plane pools lazily on first
# query). The post-isolation delta is exactly the pools my mounts hold.
POOLS_BASE="$(metric 'baas_data_plane_pools_open')"; POOLS_BASE="${POOLS_BASE:-0}"
cyan "baseline pools_open=${POOLS_BASE}"

# ── 3) create the shared mysql table once (owner_id auto-appended) ────────────
DDL="{\"op\":\"create_table\",\"table\":\"${TABLE}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"label\",\"normalized_type\":\"text\",\"nullable\":true}],\"primary_key\":[\"id\"]}"
dcode="$(curl -s -o /tmp/m46-ddl.json -w '%{http_code}' -X POST "${KONG}/data/v1/schema/ddl" \
  -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" -H 'Content-Type: application/json' \
  -d "{\"db_id\":\"${A_MY}\",\"ddl\":${DDL}}")"
[[ "${dcode}" =~ ^20[01]$ || "${dcode}" == 409 ]] || { red "mysql create_table HTTP ${dcode}: $(cat /tmp/m46-ddl.json)"; exit 1; }
green "shared mysql table ${TABLE} ready (HTTP ${dcode})"

# ── 4) seed: A writes A-secret, B writes B-secret (mysql + mongo) ─────────────
ins(){ # $1 key $2 db_id $3 id $4 label — informative; step 5 is the real gate
  local r; r="$(q "$1" "$2" "{\"op\":\"insert\",\"resource\":\"${TABLE}\",\"data\":{\"id\":\"$3\",\"label\":\"$4\"}}")"
  cyan "  insert $4 → ${r:0:140}"
}
ins "${A_KEY}" "${A_MY}" a1 "A-secret"
ins "${B_KEY}" "${B_MY}" b1 "B-secret"
ins "${A_KEY}" "${A_MG}" a1 "A-secret"
ins "${B_KEY}" "${B_MG}" b1 "B-secret"
green "seeded A-secret (A) + B-secret (B) on mysql + mongo"

# ── 5) ISOLATION: each tenant sees ONLY its own row ──────────────────────────
fail=0
iso(){ # $1 desc $2 key $3 db_id $4 own $5 other
  local r; r="$(q "$2" "$3" "{\"op\":\"list\",\"resource\":\"${TABLE}\",\"limit\":50}")"
  if ! grep -q "$4" <<<"${r}"; then red "$1: missing OWN row '$4' — resp: ${r}"; fail=1; return; fi
  if grep -q "$5" <<<"${r}"; then red "$1: CROSS-TENANT LEAK — saw '$5' — resp: ${r}"; fail=1; return; fi
  green "$1: sees '$4', NOT '$5' ✓"
}
iso "mysql A" "${A_KEY}" "${A_MY}" "A-secret" "B-secret"
iso "mysql B" "${B_KEY}" "${B_MY}" "B-secret" "A-secret"
iso "mongo A" "${A_KEY}" "${A_MG}" "A-secret" "B-secret"
iso "mongo B" "${B_KEY}" "${B_MG}" "B-secret" "A-secret"

# ── 6) COLLAPSE: how many pools do 2 tenants on ONE backend per engine hold?
#       Shared → 1 pool/engine (2 total); per-tenant → 2/engine (4 total). The
#       isolation queries just opened them, so `pools_open` is current; the delta
#       from the pre-probe baseline is exactly what my 4 mounts hold. (No reaper
#       dependency — measured: idle pools persist well past the run window.)
POOLS_OPEN="$(metric 'baas_data_plane_pools_open')"; POOLS_OPEN="${POOLS_OPEN:-0}"
[[ "${POOLS_BASE}" =~ ^[0-9]+$ ]] || POOLS_BASE=0
[[ "${POOLS_OPEN}" =~ ^[0-9]+$ ]] || POOLS_OPEN=0
DELTA=$(( POOLS_OPEN - POOLS_BASE ))
WANT=$([[ "${EXPECT}" == 1 ]] && echo 2 || echo 4)   # 2 engines × (1|2) pools
cyan "pools held by 2 tenants × 2 engines: ${DELTA} (open=${POOLS_OPEN}, base=${POOLS_BASE}); expect ${WANT} for SHARE_POOLS=${EXPECT}"
if [[ "${DELTA}" != "${WANT}" ]]; then red "collapse mismatch: ${DELTA} pools held, expected ${WANT}"; fail=1; fi

# ── 7) artifact + verdict ────────────────────────────────────────────────────
verdict=$([[ "${fail}" == 0 ]] && echo PASS || echo FAIL)
cat > "${ART}" <<JSON
{
  "probe": "share-pools-cross-engine",
  "share_pools_expect": ${EXPECT},
  "engines": ["mysql", "mongodb"],
  "tenants": ["${A_SLUG}", "${B_SLUG}"],
  "shared_backend": { "mysql": "mysql:3306/mini_baas", "mongodb": "mongo:27017/mini_baas" },
  "isolation": { "mysql_A_sees_only_own": $([[ ${fail} == 0 ]] && echo true || echo "\"see-log\""), "no_cross_tenant_leak": $([[ ${fail} == 0 ]] && echo true || echo "\"see-log\"") },
  "collapse": { "pools_created_by_2tenants_2engines": ${DELTA}, "expected": ${WANT}, "pools_open_after": "${POOLS_OPEN:-?}" },
  "verdict": "${verdict}",
  "git_sha": "$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "ts": ${TS}
}
JSON
cyan "artifact: ${ART#${ROOT}/}"
[[ "${fail}" == 0 ]] || { red "cross-engine SHARE_POOLS probe FAILED (EXPECT=${EXPECT})"; exit 1; }
green "PASS — mysql+mongo: isolation holds, ${DELTA} pools for 2 tenants×2 engines (SHARE_POOLS=${EXPECT})"
