#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m202-strict-identity-serviceable.sh — IDENTITY_HEADER_MODE=strict is         #
#  serviceable for real traffic (H-19).                                        #
#                                                                              #
#  Production stayed on `compat` because only the api-key route could produce  #
#  an identity strict accepts: ApiKeyMiddleware self-signs an envelope, and it  #
#  is mounted on query-router alone. Every other Nest service saw only the raw  #
#  X-User-* headers Kong derives from the JWT, which strict rejects — so the    #
#  flip would have 401'd legitimate traffic. resolveRequestIdentity now has a   #
#  bearer-JWT rung, and THIS gate is what licenses the flip:                   #
#                                                                              #
#    (1) the rendered compose gives every service that verifies a user token    #
#        the same GOTRUE_JWT_ISSUER that GoTrue stamps                          #
#    (2) live, against a storage-router running in strict mode: a real GoTrue   #
#        session token is accepted, while a raw X-User-Id with no token, a      #
#        cross-app realtime token (whose `sub` is a tenant slug) and a token    #
#        signed with the wrong secret are all refused                          #
#                                                                              #
#  storage-router is the subject on purpose: it has no signer of its own, so it #
#  is the service where strict is hardest. Secrets are read from the running    #
#  container's own env and never printed. Needs the stack up with storage-router #
#  built from this tree and recreated with IDENTITY_HEADER_MODE=strict.         #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SR=mini-baas-storage-router
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M202] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M202] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# sr_env NAME prints one variable from the storage-router container's env.
sr_env() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${SR}" | sed -n "s/^$1=//p"; }

# mint_token ISS SUB prints an HS256 token signed with the live JWT_SECRET. ISS
# "-" omits the claim; SECRET_OVERRIDE, when set, signs with that instead, which
# is how the wrong-secret negative is produced.
mint_token() {
  TOKEN_ISS="$1" TOKEN_SUB="$2" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
b = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
secret = (os.environ.get('SECRET_OVERRIDE') or os.environ['JWT_SECRET']).encode()
claims = {'sub': os.environ['TOKEN_SUB'], 'exp': int(time.time()) + 300, 'role': 'authenticated'}
if os.environ['TOKEN_ISS'] != '-':
    claims['iss'] = os.environ['TOKEN_ISS']
head = b(json.dumps({'alg': 'HS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
body = b(json.dumps(claims, separators=(',', ':')).encode())
print(f'{head}.{body}.' + b(hmac.new(secret, f'{head}.{body}'.encode(), hashlib.sha256).digest()))
PY
}

# probe prints the HTTP status storage-router returns for a listing, called on
# its own network so Kong's pre-function cannot rewrite the headers under test.
# "$1" is the bearer token ("-" for none), "$2" an extra raw header ("-" none).
probe() {
  docker run --rm --network "${NET}" \
    -e TOKEN="$1" -e EXTRA="$2" \
    public.ecr.aws/docker/library/curlimages/curl:8.11.1 sh -c '
      set -- -s -o /dev/null -w "%{http_code}" "http://storage-router:3040/storage/v1/bucket"
      [ "$TOKEN" != "-" ] && set -- "$@" -H "Authorization: Bearer $TOKEN"
      [ "$EXTRA" != "-" ] && set -- "$@" -H "$EXTRA"
      curl "$@"' 2>/dev/null | tail -n1
}

step "0/2 preconditions — storage-router running in strict mode"
docker inspect -f '{{.State.Running}}' "${SR}" 2>/dev/null | grep -qx true || fail "${SR} is not running (make up)"
NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${SR}" | awk '{print $1}')"
MODE="$(sr_env IDENTITY_HEADER_MODE)"
[ "${MODE}" = "strict" ] ||
  fail "${SR} runs IDENTITY_HEADER_MODE='${MODE:-unset}'; recreate it with strict — this gate must not pass in compat"
ISSUER="$(sr_env GOTRUE_JWT_ISSUER)"
[ -n "${ISSUER}" ] || fail "${SR} has no GOTRUE_JWT_ISSUER; the bearer rung refuses to run without it"
[ -n "$(sr_env JWT_ALLOW_NO_ISSUER)" ] && fail "JWT_ALLOW_NO_ISSUER is set on ${SR}; unset it to run this gate"
JWT_SECRET="$(sr_env JWT_SECRET)"
export JWT_SECRET
[ -n "${JWT_SECRET}" ] || fail "${SR} has no JWT_SECRET, so it can verify no user token"
ANON="$(sr_env ANON_KEY)"
[ -n "${ANON}" ] || fail "${SR} has no ANON_KEY (needed to reach GoTrue through the gateway)"
ok "storage-router strict on ${NET}, issuer pinned"

step "1/2 compose — every user-token verifier shares GoTrue's issuer"
cd "${ROOT}" || exit 1
RENDERED="$(docker compose --profile adapter-plane --profile auth-api --profile storage config 2>/dev/null)" ||
  fail "docker compose config failed"
GOTRUE_ISS="$(sed -n 's/^ *GOTRUE_JWT_ISSUER: //p' <<<"${RENDERED}" | sort -u)"
[ -n "${GOTRUE_ISS}" ] || fail "compose renders no GOTRUE_JWT_ISSUER at all"
[ "$(wc -l <<<"${GOTRUE_ISS}")" -eq 1 ] ||
  fail "services disagree on GOTRUE_JWT_ISSUER; a token one mints would not verify at another"
VERIFIERS="$(sed -n 's/^ *GOTRUE_JWT_ISSUER: .*/x/p' <<<"${RENDERED}" | grep -c x)"
[ "${VERIFIERS}" -ge 3 ] || fail "only ${VERIFIERS} service(s) carry GOTRUE_JWT_ISSUER; expected the Nest set"
ok "${VERIFIERS} services share one issuer: ${GOTRUE_ISS}"

step "2/2 live — a real session is accepted, everything else refused"
KPORT="$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
GW="http://localhost:${KPORT:-8000}"
EMAIL="m202-$(date +%s)@grobase.local"
SESSION="$(curl -s -X POST "${GW}/auth/v1/signup" -H "apikey: ${ANON}" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"M202-probe#2026\"}" |
  sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[ -n "${SESSION}" ] || fail "GoTrue signup returned no access_token (is the auth-api plane up?)"

ACCEPTED="$(probe "${SESSION}" '-')"
case "${ACCEPTED}" in
401 | 403) fail "a real GoTrue session was refused (${ACCEPTED}) in strict mode — the flip is not serviceable" ;;
2*) ok "real GoTrue session → ${ACCEPTED}" ;;
*) fail "unexpected status ${ACCEPTED} for a real session (service unhealthy?)" ;;
esac

RAW="$(probe '-' 'X-User-Id: 00000000-0000-4000-8000-0000000000ff')"
[ "${RAW}" = "401" ] || fail "a raw X-User-Id with no token got ${RAW}, expected 401 in strict mode"
ok "raw X-User-Id, no token → 401"

XAPP="$(probe "$(mint_token grobase-realtime victim-tenant)" '-')"
[ "${XAPP}" = "401" ] || fail "a cross-app realtime token got ${XAPP}, expected 401 (its sub is a tenant slug)"
ok "cross-app realtime token (iss grobase-realtime) → 401"

FOREIGN="$(SECRET_OVERRIDE=m202-not-the-real-secret mint_token "${ISSUER}" m202-forged)"
WRONG="$(probe "${FOREIGN}" '-')"
[ "${WRONG}" = "401" ] || fail "a token signed with the wrong secret got ${WRONG}, expected 401"
ok "token signed with another secret → 401"

printf '\033[0;32m[M202] OK — strict identity mode is serviceable for real traffic\033[0m\n'
