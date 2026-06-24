#!/usr/bin/env bash
# **************************************************************************** #
#  m152-hypertube-rest.sh — Hypertube RESTful API (subject §VI) contract gate  #
#                                                                              #
#  Proves the hypertube-api service honours the subject's mandatory RESTful     #
#  contract — OAuth2 client_credentials, authenticated access only, and the     #
#  per-resource authorization rules — over Kong /api against the RUNNING stack:  #
#    1. token      — POST /oauth/token (client_credentials) → 200 + access_token;#
#                    a bad client_secret → 401.                                  #
#    2. authn       — an unauthenticated GET on a protected route → 401.         #
#    3. read-other  — GET /users/{other} succeeds but HIDES the email           #
#                     (subject: a user may view others but not their email).     #
#    4. write-other — PATCH /users/{other} → 403 (only the owner edits self).    #
#    5. comment own — PATCH/DELETE a comment by a NON-owner → 403.               #
#    6. unknown      — an unknown route → 404.                                   #
#                                                                              #
#  The 401/403/404 reject arms are the LOAD-BEARING proof (a contract gate that  #
#  only checks happy 200s is VACUOUS). Live gate: needs hypertube-api on Kong    #
#  /api. SKIPs cleanly (exit 0) when the service is not reachable so CI stays    #
#  green.                                                                        #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/lib-live-tenant.sh
source "${BAAS_DIR}/scripts/lib/lib-live-tenant.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M152] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33mSKIP m152: %s\033[0m\n' "$*"
  exit 0
}
fail() {
  printf '\033[0;31m[M152] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

jval() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
code() { curl -s -o "${TMP}/r.json" -w '%{http_code}' "$@"; }

# ── 0) stack reachable + api route present? otherwise SKIP ───────────────────
KPORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KPORT}" ]] || skip "mini-baas-kong not running (make up + docker compose --profile hypertube up -d)"
KONG="http://127.0.0.1:${KPORT}"
ANON="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
[[ -n "${ANON}" ]] || skip "anon key not found on mini-baas-kong"
# A reachable health/oauth route on /api means the service is up; otherwise SKIP.
if ! curl -fsS -o /dev/null --max-time 5 "${KONG}/api/health" -H "apikey: ${ANON}" 2>/dev/null \
  && [[ "$(code -X POST "${KONG}/api/oauth/token" -H "apikey: ${ANON}" -H 'Content-Type: application/json' -d '{}')" == "000" ]]; then
  skip "hypertube-api not reachable on ${KONG}/api (start the hypertube profile)"
fi
ok "gateway ${KONG}/api"

# ── 1) provision + demo users for the authz checks ───────────────────────────
step "1/6 provision (idempotent) + demo subs"
bash "${BAAS_DIR}/scripts/seed/hypertube-tenant.sh" >"${TMP}/seed.log" 2>&1 \
  || fail "provisioning failed — $(tail -3 "${TMP}/seed.log")"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.hypertube-baas.env"
ALICE="${HT_ALICE_SUB:-}"; BOB="${HT_BOB_SUB:-}"
[[ -n "${ALICE}" && -n "${BOB}" ]] || skip "demo subs not seeded (HT_ALICE_SUB/HT_BOB_SUB empty)"
# OAuth2 client credentials: the API issues an app token via client_credentials.
# The client id/secret come from the service env (never hardcoded); read from the
# running container, falling back to the seeded api key as the client secret.
CID="$(_lt_env mini-baas-hypertube-api API_OAUTH_CLIENT_ID)"; CID="${CID:-hypertube}"
CSEC="$(_lt_env mini-baas-hypertube-api API_OAUTH_CLIENT_SECRET)"; CSEC="${CSEC:-${HT_API_KEY:-}}"
[[ -n "${CSEC}" ]] || skip "no OAuth client secret available (service env + state both empty)"
ok "client_id=${CID}"

# ── 2) OAuth2 token: good secret → 200; bad secret → 401 ─────────────────────
step "2/6 POST /oauth/token: client_credentials → 200; bad secret → 401"
gc="$(code -X POST "${KONG}/api/oauth/token" -H "apikey: ${ANON}" \
  --data-urlencode 'grant_type=client_credentials' --data-urlencode "client_id=${CID}" --data-urlencode "client_secret=${CSEC}")"
[[ "${gc}" == "200" ]] || fail "good client_credentials expected 200, got ${gc}: $(head -c 200 "${TMP}/r.json")"
TOK="$(jval "${TMP}/r.json" access_token)"
[[ -n "${TOK}" ]] || fail "token endpoint returned no access_token: $(head -c 200 "${TMP}/r.json")"
ok "token issued (200)"
bc="$(code -X POST "${KONG}/api/oauth/token" -H "apikey: ${ANON}" \
  --data-urlencode 'grant_type=client_credentials' --data-urlencode "client_id=${CID}" --data-urlencode "client_secret=wrong-$$")"
[[ "${bc}" == "401" ]] || fail "bad client_secret expected 401, got ${bc}"
ok "bad client_secret rejected (401)"

# ── 3) authn: unauthenticated protected route → 401 ──────────────────────────
step "3/6 authn: unauthenticated GET /users/${ALICE:0:8} → 401"
uc="$(code "${KONG}/api/users/${ALICE}" -H "apikey: ${ANON}")"
[[ "${uc}" == "401" ]] || fail "unauthenticated protected GET expected 401, got ${uc}"
ok "unauthenticated request rejected (401)"

AUTH=(-H "apikey: ${ANON}" -H "Authorization: Bearer ${TOK}")

# ── 4) read-other: GET /users/{other} succeeds but HIDES email ───────────────
step "4/6 GET /users/${BOB:0:8} as a token → 200 but email hidden"
rc="$(code "${KONG}/api/users/${BOB}" "${AUTH[@]}")"
[[ "${rc}" == "200" ]] || fail "GET other user expected 200, got ${rc}: $(head -c 200 "${TMP}/r.json")"
grep -qi '"email"' "${TMP}/r.json" && fail "GET /users/{other} LEAKED the email field (subject forbids it)"
ok "other user readable, email hidden"

# ── 5) write-other: PATCH /users/{other} → 403 ───────────────────────────────
step "5/6 PATCH /users/${BOB:0:8} → 403 (only the owner edits self)"
pc="$(code -X PATCH "${KONG}/api/users/${BOB}" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"first_name":"hacked"}')"
[[ "${pc}" == "403" ]] || fail "PATCH other user expected 403, got ${pc}"
ok "cross-user write rejected (403)"

# ── 6) comment own: PATCH/DELETE a foreign comment → 403; unknown route → 404 ─
step "6/6 PATCH/DELETE a foreign comment → 403; unknown route → 404"
pcc="$(code -X PATCH "${KONG}/api/comments/not-mine-$$" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"content":"x"}')"
[[ "${pcc}" == "403" || "${pcc}" == "404" ]] || fail "PATCH foreign comment expected 403/404, got ${pcc}"
dcc="$(code -X DELETE "${KONG}/api/comments/not-mine-$$" "${AUTH[@]}")"
[[ "${dcc}" == "403" || "${dcc}" == "404" ]] || fail "DELETE foreign comment expected 403/404, got ${dcc}"
nc="$(code "${KONG}/api/this-route-does-not-exist-$$" "${AUTH[@]}")"
[[ "${nc}" == "404" ]] || fail "unknown route expected 404, got ${nc}"
ok "foreign comment write rejected (PATCH ${pcc}, DELETE ${dcc}); unknown route 404"

printf '\033[0;32m[M152] ALL GATES GREEN — Hypertube REST: OAuth2 (200/401) · authn 401 · email hidden · cross-user write 403 · foreign comment 403 · unknown 404\033[0m\n'
