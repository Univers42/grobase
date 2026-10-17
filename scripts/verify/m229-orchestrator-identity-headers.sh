#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m229-orchestrator-identity-headers.sh — no client can mint an identity      #
#  upstream: X-Baas-Role/-User-Id/-Roles/-Scopes/-Tenant-Id never arrive, and  #
#  X-User-* arrive only from a JWT Kong verified (G2 TM1-TM4).                 #
#                                                                              #
#    static  Kong's parsed config: the pre-function only clears; the claims    #
#            copy is a post-function gated on authenticated_jwt_token; the    #
#            gdpr and newsletter routes are anchored regex routes, not        #
#            prefixes; auth-otp-request carries acl baas-admin                #
#    live    a throwaway Kong (repo kong.yml, rendered by the repo's own      #
#            render-kong-config.sh) → a header-echo upstream: forged          #
#            identity headers are gone; anon key + a JWT with a bad          #
#            signature yields no X-User-Id; a valid JWT yields X-User-Id =   #
#            sub (positive control); the public gdpr/newsletter/otp paths    #
#            reach the upstream rewritten; admin and cross-service paths     #
#            (/send, /admin/*) get Kong's own 404                            #
#    mutant  (a) one X-Baas-Role clear removed, (b) the claims copy put back  #
#            in the pre-function, (c) the otp acl removed: each MUST fail    #
#            this gate (a, b) or m206 (c), else the probes are blind          #
#  Caveat: /admin/v1 keeps a client-supplied X-Baas-Tenant-Id on purpose (the #
#  mount catalog); the probe asserts that exception, so removing it fails.    #
#  Needs jq, the kong image and node:20-alpine locally (nothing pulled);     #
#  otherwise SKIP, exit 77, never 0. M229_KONG_IMAGE / M229_NODE_IMAGE        #
#  override the images.                                                       #
# **************************************************************************** #
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/lib-kong-scratch.sh
. "${ROOT}/scripts/lib/lib-kong-scratch.sh"
CONF="${ROOT}/infra/docker/services/kong/conf/kong.yml"
NODE_IMG="${M229_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
JWT_SECRET="scratch-dummy-jwt-secret-scratch-dummy"
ISS="http://localhost:8000/auth/v1"
TAG="m229gate$$"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M229] %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33m[M229] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}
cleanup() {
  docker rm -f "${TAG}-up" "${TAG}-kong" "${TAG}-mut" >/dev/null 2>&1 || true
  docker network rm "${TAG}-net" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# kong_image prints the kong image the base compose file names, or the override.
kong_image() {
  [ -z "${M229_KONG_IMAGE:-}" ] || {
    printf '%s\n' "${M229_KONG_IMAGE}"
    return
  }
  (cd "${ROOT}" && docker compose config --format json) | jq -r '.services.kong.image'
}

# start_echo runs a node server whose aliases are the upstream hosts kong.yml
# names, on each port it names, answering every request with what it received.
start_echo() {
  local alias_args=() a
  for a in orchestrator tenant-control adapter-registry-go query-router; do alias_args+=(--network-alias "$a"); done
  docker run -d --name "${TAG}-up" --network "${TAG}-net" "${alias_args[@]}" "${NODE_IMG}" node -e '
    for (const port of [3026, 3022, 3021, 4001])
      require("http").createServer((q, r) => { r.setHeader("content-type", "application/json");
        r.end(JSON.stringify({ url: q.url, method: q.method, headers: q.headers })); }).listen(port);' >/dev/null ||
    skip "could not start the echo upstream"
}

# start_kong $1 $2 runs Kong container $1 on the echo network loading template
# $2 (default: $KONG_SCRATCH_CONF, else the repo's) and waits for its proxy.
start_kong() {
  KONG_SCRATCH_CONF="${2:-${KONG_SCRATCH_CONF:-}}" kong_scratch_start "$1" "${KONG_IMG}" "${TAG}-net" || skip "could not start kong"
  kong_scratch_wait "$1" || skip "kong never served :8000"
}

# mint_jwt $1 $2 prints an HS256 JWT for sub $1 signed with secret $2 (iss and
# exp set so Kong's jwt plugin accepts it when the secret is right).
mint_jwt() {
  docker exec "${TAG}-up" node -e '
    const c = require("crypto"), b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const h = b({ alg: "HS256", typ: "JWT" }), p = b({ iss: process.argv[3], sub: process.argv[1],
      email: "m229@example.com", role: "authenticated", exp: Math.floor(Date.now() / 1000) + 600 });
    process.stdout.write(h + "." + p + "." + c.createHmac("sha256", process.argv[2]).update(h + "." + p).digest("base64url"));' \
    "$1" "$2" "${ISS}"
}

# probe K METHOD PATH header... prints the HTTP status, a space, then the body.
probe() {
  local k="$1" raw
  shift
  raw="$(kong_scratch_send "${k}" 8000 "$@" | tr -d '\r')"
  printf '%s %s' "$(head -n1 <<<"${raw}" | awk '{ print $2 }')" "$(awk 'b { print } /^$/ { b = 1 }' <<<"${raw}")"
}

# seen $1 $2 prints the echoed request header $2 of probe output $1 (empty if absent).
seen() { printf '%s' "${1#* }" | jq -r --arg h "${2,,}" '.headers[$h] // empty' 2>/dev/null; }

# forged_headers prints the header lines a hostile client sends.
forged_headers() {
  printf '%s\n' "X-Baas-Role: service_role" "X-Baas-User-Id: forged-admin" "X-Baas-Roles: admin" \
    "X-Baas-Scopes: *" "X-Baas-Tenant-Id: forged-tenant" "X-User-Id: forged-user" "X-User-Email: forged@evil.example" \
    "X-User-Role: service_role"
}

# assert_identity_probes K proves, on Kong container K, that forged identity
# headers are gone on both orchestrator routes and the otp route.
assert_identity_probes() {
  local k="$1" out h path bad_jwt good_jwt
  local -a fh
  mapfile -t fh < <(forged_headers)
  for path in /gdpr/v1/consents /newsletter/v1/confirm/abc123; do
    out="$(probe "${k}" GET "${path}" "apikey: scratch-anon" "${fh[@]}")"
    [ "${out%% *}" = 200 ] || bad "${path}: forged-header probe got '${out:0:80}', want 200 from the echo"
    for h in X-Baas-Role X-Baas-User-Id X-Baas-Roles X-Baas-Scopes X-Baas-Tenant-Id X-User-Id X-User-Email X-User-Role; do
      [ -z "$(seen "${out}" "${h}")" ] || bad "${path}: forged ${h} reached the upstream ($(seen "${out}" "${h}"))"
    done
  done
  [ "${FAILED}" = 0 ] && ok "forged X-Baas-* and X-User-* never reach the orchestrator routes"
  bad_jwt="$(mint_jwt victim-sub wrong-secret)"
  out="$(probe "${k}" GET /gdpr/v1/consents "apikey: scratch-anon" "Authorization: Bearer ${bad_jwt}")"
  [ -z "$(seen "${out}" X-User-Id)" ] && [ -z "$(seen "${out}" X-User-Email)" ] &&
    ok "anon key + bad-signature JWT → no X-User-Id upstream" ||
    bad "anon key + bad-signature JWT forged X-User-Id=$(seen "${out}" X-User-Id)"
  good_jwt="$(mint_jwt verified-sub "${JWT_SECRET}")"
  out="$(probe "${k}" GET /gdpr/v1/consents "apikey: scratch-anon" "Authorization: Bearer ${good_jwt}")"
  [ "$(seen "${out}" X-User-Id)" = verified-sub ] && [ "$(seen "${out}" X-User-Email)" = m229@example.com ] &&
    ok "valid JWT → X-User-Id = sub, X-User-Email = email (positive control)" ||
    bad "valid JWT did not yield X-User-Id=verified-sub (got '$(seen "${out}" X-User-Id)', ${out:0:80})"
}

# assert_tenant_header_scope K proves X-Baas-Tenant-Id is cleared on /query and
# survives only on /admin/v1 (the documented exception), where the identity
# headers are still cleared.
assert_tenant_header_scope() {
  local k="$1" out
  out="$(probe "${k}" GET /query/v1/x "apikey: scratch-anon" "X-Baas-Tenant-Id: forged-tenant")"
  [ -z "$(seen "${out}" X-Baas-Tenant-Id)" ] && ok "/query/v1: client X-Baas-Tenant-Id cleared" || bad "/query/v1 leaked X-Baas-Tenant-Id"
  out="$(probe "${k}" GET /admin/v1/databases "apikey: scratch-service" "X-Baas-Tenant-Id: mount-tenant" "X-Baas-Role: service_role")"
  [ "$(seen "${out}" X-Baas-Tenant-Id)" = mount-tenant ] && [ -z "$(seen "${out}" X-Baas-Role)" ] &&
    ok "/admin/v1: the mount catalog's X-Baas-Tenant-Id kept, X-Baas-Role still cleared" ||
    bad "/admin/v1 tenant exception broken: tenant='$(seen "${out}" X-Baas-Tenant-Id)' role='$(seen "${out}" X-Baas-Role)' (${out:0:80})"
}

# assert_route_surface K proves the public paths reach the upstream rewritten
# and every other orchestrator path is Kong's own 404.
assert_route_surface() {
  local k="$1" out want path method
  while read -r method path want; do
    out="$(probe "${k}" "${method}" "${path}" "apikey: scratch-anon")"
    [ "${out%% *}" = 200 ] && [ "$(printf '%s' "${out#* }" | jq -r .url)" = "${want}" ] ||
      bad "${method} ${path}: want 200 with upstream path ${want}, got '${out:0:90}'"
  done <<'EOF'
GET /gdpr/v1/consents /consents
POST /gdpr/v1/consents /consents
GET /gdpr/v1/consents/analytics /consents/analytics
DELETE /gdpr/v1/consents/non-essential /consents/non-essential
GET /gdpr/v1/export /export
POST /gdpr/v1/deletion-requests /deletion-requests
GET /gdpr/v1/deletion-requests/mine /deletion-requests/mine
GET /gdpr/v1/health/live /health/live
POST /newsletter/v1/subscribe /subscribe
GET /newsletter/v1/confirm/abc123 /confirm/abc123
GET /newsletter/v1/unsubscribe/abc123 /unsubscribe/abc123
EOF
  [ "${FAILED}" = 0 ] && ok "public gdpr/newsletter paths: 200 from the upstream, prefix rewritten"
  while read -r method path; do
    out="$(probe "${k}" "${method}" "${path}" "apikey: scratch-service")"
    case "${out}" in
    "404 "*"no Route matched"*) ;;
    *) bad "${method} ${path}: want Kong's 404 'no Route matched' even with the service key, got '${out:0:90}'" ;;
    esac
  done <<'EOF'
POST /gdpr/v1/send
POST /newsletter/v1/send
GET /newsletter/v1/admin/stats
POST /newsletter/v1/admin/campaigns/send
GET /newsletter/v1/admin/subscribers
GET /gdpr/v1/deletion-requests/admin
POST /gdpr/v1/deletion-requests/admin/1/process
POST /gdpr/v1/email/v1/send
GET /gdpr/v1/consents/a/b
GET /gdpr/v1/consents/..%2fsend
GET /newsletter/v1/confirm/a%2f..%2fsend
PUT /newsletter/v1/subscribe
EOF
  [ "${FAILED}" = 0 ] && ok "admin, /send and traversal paths: Kong's 404 'no Route matched'"
  out="$(probe "${k}" GET /v1/auth/otp/request "apikey: scratch-anon")"
  case "${out}" in "403 "*"cannot consume this service"*) ok "/v1/auth/otp/request: anon key → acl 403" ;; *) bad "/v1/auth/otp/request anon got '${out:0:90}', want the acl 403" ;; esac
  out="$(probe "${k}" GET /v1/auth/otp/request "apikey: scratch-service")"
  [ "${out%% *}" = 200 ] && ok "/v1/auth/otp/request: service key passes" || bad "/v1/auth/otp/request service got '${out:0:90}'"
  for path in /v1/auth/otp/verify /v1/auth/escrow; do
    out="$(probe "${k}" GET "${path}")"
    [ "${out%% *}" = 200 ] && continue
    bad "${path}: want the public route (200 from the echo, no key), got '${out:0:90}'"
  done
  [ "${FAILED}" = 0 ] && ok "otp verify and escrow stay public"
}

# assert_static K proves the shape of Kong's parsed config.
assert_static() {
  local k="$1" pre post
  kong_scratch_get "${k}" 8001 '/plugins?size=1000' | tr -d '\r' | awk 'b { print } /^$/ { b = 1 }' >"${WORK}/plugins.json"
  kong_scratch_get "${k}" 8001 '/routes?size=1000' | tr -d '\r' | awk 'b { print } /^$/ { b = 1 }' >"${WORK}/routes.json"
  pre="$(jq -r '[.data[] | select(.name == "pre-function" and .route == null) | .config.access[]] | join("\n")' "${WORK}/plugins.json")"
  post="$(jq -r '[.data[] | select(.name == "post-function" and .route == null) | .config.access[]] | join("\n")' "${WORK}/plugins.json")"
  ! grep -q 'set_header' <<<"${pre}" && ok "pre-function sets no header (it only clears)" || bad "pre-function calls set_header — claims copied before jwt verified"
  grep -q 'authenticated_jwt_token' <<<"${post}" && ok "post-function copies claims only behind kong.ctx.shared.authenticated_jwt_token" ||
    bad "no post-function gated on authenticated_jwt_token"
  jq -e '[.data[] | select(.name == "gdpr-routes" or .name == "newsletter-routes") | .paths[]]
    | length > 0 and all(startswith("~/") and endswith("$"))' "${WORK}/routes.json" >/dev/null &&
    ok "gdpr and newsletter routes are anchored regex paths, no prefix route" || bad "a gdpr/newsletter route is a prefix or unanchored"
  jq -e --slurpfile p "${WORK}/plugins.json" '.data[] | select(.name == "auth-otp-request") | . as $r
    | [$p[0].data[] | select(.route.id == $r.id and .name == "acl" and (.config.allow | index("baas-admin")))] | length == 1' \
    "${WORK}/routes.json" >/dev/null && ok "auth-otp-request carries acl baas-admin" || bad "auth-otp-request missing or without acl baas-admin"
}

# mutate $1 $2 writes the repo kong.yml to $2 with mutation $1 applied; fails
# when the mutation changed nothing (the anchor it edits is gone).
mutate() {
  case "$1" in
  a) sed '/^ *"X-Baas-Role",$/d' "${CONF}" >"$2" ;;
  b) awk '/local _p = kong.request.get_path\(\) or ""/ && !done {
        print "          local _t = (kong.request.get_header(\"authorization\") or \"\"):match(\"^[Bb]earer%s+[^.]+%.([^.]+)\")"
        print "          local _b = _t and _t:gsub(\"-\", \"+\"):gsub(\"_\", \"/\")"
        print "          local _c = _b and require(\"cjson.safe\").decode(ngx.decode_base64(_b .. (\"=\"):rep((4 - #_b % 4) % 4)))"
        print "          if _c and _c.sub then kong.service.request.set_header(\"X-User-Id\", _c.sub) end"
        done = 1 } { print }' "${CONF}" >"$2" ;;
  c) awk '/name: auth-otp-request/ { inreq = 1 } inreq && /name: acl/ { getline; inreq = 0; next } { print }' "${CONF}" >"$2" ;;
  esac
  ! cmp -s "${CONF}" "$2"
}

# run_mutant_live $1 $2 $3 starts Kong on mutated template $2 and reports whether
# the live and static probes of this gate fail on mutation $1 with a message
# matching regex $3 (the right reason, not any failure).
run_mutant_live() {
  local before="${FAILED}" report
  FAILED=0
  start_kong "${TAG}-mut" "$2"
  report="$({
    assert_identity_probes "${TAG}-mut"
    assert_static "${TAG}-mut"
  } 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  FAILED="${before}"
  docker rm -f "${TAG}-mut" >/dev/null 2>&1
  grep -Eq "✗.*($3)" <<<"${report}"
}

command -v jq >/dev/null || skip "jq is required"
KONG_IMG="$(kong_image)"
docker image inspect "${KONG_IMG}" >/dev/null 2>&1 || skip "kong image ${KONG_IMG} not present locally"
docker image inspect "${NODE_IMG}" >/dev/null 2>&1 || skip "node image ${NODE_IMG} not present locally"
docker network create --internal "${TAG}-net" >/dev/null || skip "cannot create the network"
step "1/3 live: throwaway Kong (repo kong.yml) → header-echo upstream"
start_echo
start_kong "${TAG}-kong" ""
assert_identity_probes "${TAG}-kong"
assert_tenant_header_scope "${TAG}-kong"
assert_route_surface "${TAG}-kong"
step "2/3 static: Kong's parsed config"
assert_static "${TAG}-kong"
step "3/3 mutants: each must be noticed"
declare -A why=([a]='forged X-Baas-Role reached' [b]='bad-signature JWT forged X-User-Id|pre-function calls set_header')
for m in a b; do
  mutate "${m}" "${WORK}/mutant-${m}.yml" || {
    bad "mutant ${m} changed nothing — its anchor is gone from kong.yml"
    continue
  }
  run_mutant_live "${m}" "${WORK}/mutant-${m}.yml" "${why[${m}]}" &&
    ok "mutant ${m} fails this gate (${why[${m}]%%|*})" || bad "mutant ${m} is not caught for '${why[${m}]}' — the probes are blind"
done
if mutate c "${WORK}/mutant-c.yml"; then
  KONG_SCRATCH_CONF="${WORK}/mutant-c.yml" M206_KONG_IMAGE="${KONG_IMG}" bash "${ROOT}/scripts/verify/m206-kong-admin-acl.sh" >"${WORK}/m206-c.log" 2>&1
  # The reason is asserted, not just the exit code: m206 also fails on a missing image or env.
  if grep -aq 'auth-otp-request is missing or lacks acl' "${WORK}/m206-c.log"; then
    ok "mutant c (otp acl removed) fails m206 for the otp acl"
  else
    bad "mutant c (otp acl removed) is not caught by m206: $(sed 's/\x1b\[[0-9;]*m//g' "${WORK}/m206-c.log" | tail -n1 | cut -c1-110)"
  fi
else
  bad "mutant c changed nothing — the auth-otp-request acl anchor is gone"
fi
[ "${FAILED}" = 0 ] || {
  printf '\033[0;31m[M229] FAIL\033[0m\n'
  exit 1
}
printf '\033[0;32m[M229] PASS — identity headers come only from Kong; the orchestrator routes expose the public paths only\033[0m\n'
