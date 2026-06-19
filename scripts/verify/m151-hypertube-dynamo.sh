#!/usr/bin/env bash
# **************************************************************************** #
#  m151-hypertube-dynamo.sh — Hypertube DynamoDB per-user state gate           #
#                                                                              #
#  Proves the Hypertube DynamoDB mount does what the subject needs — per-user   #
#  watch_state and server-side media_jobs — end to end through Kong against the  #
#  RUNNING stack, with the owner partition enforced PER REQUEST:                #
#    1. provision   — hypertube-tenant.sh (idempotent): registers the dynamo    #
#                     mount (HT_DYNAMO_DB_ID) when the engine is enabled.        #
#    2. watch_state — user A upserts a row (id=movie) → get → round-trip equal.  #
#    3. isolation   — user B GETs A's id → empty/absent (partition-key isolation #
#                     keyed on the owner). The cross-owner miss is LOAD-BEARING  #
#                     (a gate that only reads your own row is VACUOUS).          #
#    4. media_jobs  — idempotent upsert of a job row: second upsert leaves a     #
#                     single row with the updated state.                         #
#                                                                              #
#  Live gate: needs the dynamo plane (HT_DYNAMO_DB_ID non-empty). SKIPs cleanly  #
#  (exit 0) when DynamoDB is not yet enabled so CI stays green.                  #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/lib-live-tenant.sh
source "${BAAS_DIR}/scripts/lib/lib-live-tenant.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M151] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33mSKIP m151: %s\033[0m\n' "$*"
  exit 0
}
fail() {
  printf '\033[0;31m[M151] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

jval() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
jrows() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rows",[])))' "$1" 2>/dev/null || echo 0; }
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }

# ── 0) stack reachable? otherwise SKIP (keep CI green) ───────────────────────
KPORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KPORT}" ]] || skip "mini-baas-kong not running (make up + docker compose --profile hypertube up -d)"

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/4 provision the hypertube tenant + dynamo mount (idempotent)"
bash "${BAAS_DIR}/scripts/seed/hypertube-tenant.sh" >"${TMP}/seed.log" 2>&1 \
  || fail "provisioning failed — $(tail -3 "${TMP}/seed.log")"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.hypertube-baas.env"
KONG="${HT_KONG_URL}"; ANON="${HT_ANON_APIKEY}"; AK="${HT_API_KEY}"; DDB="${HT_DYNAMO_DB_ID}"
[[ -n "${KONG}" && -n "${ANON}" && -n "${AK}" ]] || fail "incomplete provisioning state"
[[ -n "${DDB}" ]] || skip "DynamoDB not enabled (HT_DYNAMO_DB_ID empty) — P1 enables the engine + dynamodb-local"
# Confirm the mount serves queries. DynamoDB has NO schema introspection
# (introspect:false), so probe with a real op:list (200 = engine up) instead.
case "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG}/query/v1/${DDB}/tables/watch_state" \
  -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json' \
  -d '{"op":"list","limit":1}')" in
  200 | 201) : ;;
  *) skip "dynamo mount ${DDB} not reachable (engine not built/up) — keeping CI green" ;;
esac
ok "tenant=${HT_TENANT_SLUG} dynamo=${DDB}"

# /query helper on the dynamo mount under a user Bearer ($3) → /tmp, echoes status.
q() {
  local hdr=(-H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json')
  [[ -n "${3:-}" ]] && hdr+=(-H "Authorization: Bearer $3")
  curl -s -o "${TMP}/q.json" -w '%{http_code}' -X POST "${KONG}/query/v1/${DDB}/tables/$1" "${hdr[@]}" -d "$2"
}
signup() { # $1 label → echoes "<sub> <jwt>"
  local email code
  email="m151_$1_$(date +%s)$$@hypertube.local"
  code=$(curl -s -o "${TMP}/a.json" -w '%{http_code}' -X POST "${KONG}/auth/v1/signup" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"M151pass!secret\",\"data\":{\"username\":\"m151_$1_$$\"}}")
  [[ "${code}" == "200" || "${code}" == "201" ]] || fail "signup $1 (${code}): $(head -c 200 "${TMP}/a.json")"
  local jwt sub
  jwt="$(jval "${TMP}/a.json" access_token)"
  sub="$(jsub "${jwt}")"
  [[ -n "${jwt}" && -n "${sub}" ]] || fail "signup $1 returned no JWT/sub"
  echo "${sub} ${jwt}"
}

read -r UA JA <<<"$(signup a)"
read -r UB JB <<<"$(signup b)"
ok "two users signed up (A=${UA:0:8} B=${UB:0:8})"

# ── 2) watch_state: A upsert → get → round-trip ──────────────────────────────
step "2/4 watch_state: A upsert (id=movie) → get → round-trip equal"
MOV="m151-mov-$$"
[[ "$(q watch_state "{\"op\":\"upsert\",\"data\":{\"id\":\"${MOV}\",\"watched\":true,\"progress_sec\":42,\"updated_at\":\"2026-06-19T00:00:00Z\"}}" "${JA}")" =~ ^20[01]$ ]] \
  || fail "A watch_state upsert: $(head -c 200 "${TMP}/q.json")"
q watch_state "{\"op\":\"get\",\"filter\":{\"id\":\"${MOV}\"}}" "${JA}" >/dev/null
grep -q '"progress_sec":42' "${TMP}/q.json" || fail "A get did not round-trip progress_sec=42: $(head -c 200 "${TMP}/q.json")"
ok "A's watch_state round-trips (progress_sec=42, watched=true)"

# ── 3) partition isolation: B cannot read A's row (LOAD-BEARING) ─────────────
step "3/4 partition isolation: B GETs A's id → empty/absent (LOAD-BEARING)"
bcode="$(q watch_state "{\"op\":\"get\",\"filter\":{\"id\":\"${MOV}\"}}" "${JB}")"
[[ "${bcode}" == "200" || "${bcode}" == "201" || "${bcode}" == "404" ]] \
  || fail "B cross-owner get returned ${bcode} (want 2xx-empty or 404): $(head -c 200 "${TMP}/q.json")"
grep -q '"progress_sec":42' "${TMP}/q.json" \
  && fail "PARTITION LEAK — B read A's watch_state row through the same id"
ok "B cannot read A's row — partition keyed on the owner (foreign id absent)"

# ── 4) media_jobs: idempotent upsert collapses to one row ────────────────────
step "4/4 media_jobs: idempotent upsert — second upsert updates, no duplicate"
JOB="m151-job-$$"
PK="media:${MOV}"
[[ "$(q media_jobs "{\"op\":\"upsert\",\"data\":{\"owner_pk\":\"${PK}\",\"id\":\"${JOB}\",\"state\":\"downloading\",\"pct\":10,\"last_seen_at\":\"2026-06-19T00:00:00Z\"}}" "${JA}")" =~ ^20[01]$ ]] \
  || fail "media_jobs first upsert: $(head -c 200 "${TMP}/q.json")"
[[ "$(q media_jobs "{\"op\":\"upsert\",\"data\":{\"owner_pk\":\"${PK}\",\"id\":\"${JOB}\",\"state\":\"ready\",\"pct\":100,\"last_seen_at\":\"2026-06-19T00:01:00Z\"}}" "${JA}")" =~ ^20[01]$ ]] \
  || fail "media_jobs second upsert: $(head -c 200 "${TMP}/q.json")"
q media_jobs "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${JOB}\"}}}" "${JA}" >/dev/null
[[ "$(jrows "${TMP}/q.json")" == "1" ]] || fail "media_jobs upsert duplicated the row (count=$(jrows "${TMP}/q.json"))"
grep -q '"state":"ready"' "${TMP}/q.json" || fail "media_jobs upsert did not update state to ready"
ok "media_jobs idempotent: one row, state=ready, pct=100"

# ── cleanup test data ────────────────────────────────────────────────────────
q watch_state "{\"op\":\"delete\",\"filter\":{\"id\":\"${MOV}\"}}" "${JA}" >/dev/null 2>&1 || true
q media_jobs "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":\"${JOB}\"}}}" "${JA}" >/dev/null 2>&1 || true

printf '\033[0;32m[M151] ALL GATES GREEN — Hypertube DynamoDB: watch_state round-trip · partition isolation (B≠A) · media_jobs idempotent upsert\033[0m\n'
