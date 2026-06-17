#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m84-console-route.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M84 — Track-B B4b-2: the osionos "BaaS Console" self-service surface wired LIVE
# THROUGH KONG. m83 already proves the /v1/tenants/me* API DIRECTLY on tenant-
# control in isolation; THIS gate proves the NEW artifact m83 does not cover —
# the public Kong route that fronts that API:
#
#   client (Authorization: Bearer mbk_… / X-API-Key)
#     │  Kong 3.8 DBLESS, declarative route `tenant-selfserve`
#     │    paths (start-anchored PCRE):  ~/v1/tenants/me$  ·  ~/v1/tenants/me/.*
#     │    url  http://tenant-control:3022 (bare) + strip_path:false → path
#     │         forwarded VERBATIM (data-plane-direct / storage-sign precedent;
#     │         a stripping url would lose the /me/sub-path to a greedy-regex match)
#     │    PUBLIC: NO key-auth, NO ip-restriction (the app authenticates ITSELF;
#     │            Kong forwards the Authorization header unchanged) — only a
#     │            request-size-limit + a per-IP rate-limit, as a public surface.
#     ▼
#   tenant-control (Go, TENANT_SELFSERVE_ENABLED=1)  selfAuth → caller's OWN tenant
#
# What it asserts THROUGH KONG (proxy port), not directly at the upstream:
#
#   (A · POSITIVE) GET kong/v1/tenants/me  (Bearer A's mbk_ key) → 200, body is A;
#       and a sub-route GET kong/v1/tenants/me/keys → 200 (proves the /me/ subtree
#       regex matches AND the path reaches the upstream VERBATIM — strip_path:false
#       forwards /v1/tenants/me/keys untouched, so the sub-route is not lost).
#
#   (B · REJECT, LOAD-BEARING — a gate that only shows the happy path is vacuous):
#       (a) NO auth header → 401 (Kong forwards; tenant-control's selfAuth rejects).
#       (b) the ADMIN surface is NOT reachable via this public route — GET
#           kong/v1/tenants/{otherTenantId} must NOT return another tenant's body
#           (expect 401/404, NEVER 200-with-B). This is the cross-tenant /
#           admin-leak guard: a bare API key carries no service token and no
#           matching X-Tenant-Id header, so the upstream {id} handler (tokenOrSelf)
#           401s it — AND the anchored regex means /v1/tenants/{id} never even
#           matches the public route (it 404s at Kong). Either way: never 200.
#       (c) PREFIX-OVERMATCH — GET kong/v1/tenants/members and /v1/tenants/mexico
#           must NOT be 200 (the bare-prefix trap: '/v1/tenants/me' as a plain
#           prefix would ALSO match these; the start-anchored `~/v1/tenants/me$` +
#           `~/v1/tenants/me/.*` regexes do NOT, so these 404 AT THE GATE,
#           never touching the upstream). This is the regression guard for the
#           Kong regex-path semantics the whole design leans on.
#
#   (C · PARITY) the SAME Kong route in front of a tenant-control with
#       TENANT_SELFSERVE_ENABLED UNSET: GET kong/v1/tenants/me → 401 (the /me
#       handler is not mounted, so the request falls to the pre-existing
#       GET /v1/tenants/{id} wildcard whose tokenOrSelf rejects a bare API key —
#       byte-identical to the pre-B4a baseline; m83 arm 6b asserts the same 401).
#       The Kong route is harmless when the feature is off.
#
# Seeding is via tenant-control's service-token admin endpoints (POST /v1/tenants
# + POST /v1/tenants/{id}/keys, X-Service-Token), hit DIRECTLY on tenant-control
# (the admin surface is NOT exposed through this public Kong route — by design).
# Then the /me surface is exercised ONLY through Kong with those keys.
#
# ISOLATED by design (mirrors m83): scratch postgres (prelude + REAL 005 + 032 +
# 040) + tenant-control built FROM CURRENT source + a Kong 3.8 container in DBLESS
# mode loading a MINIMAL declarative config the script writes to a temp file,
# ALL on a PRIVATE network, every name suffixed with $$, an EXIT-trap removing
# EVERYTHING. It NEVER touches a mini-baas-* container/network/image/volume and
# NEVER edits the live docker-compose.yml or the live kong.yml.
#
# tenant-control listens on container port 3022 here (TENANT_CONTROL_PORT=3022) so
# the upstream URL is byte-identical to the canonical kong.yml line
# `url: http://tenant-control:3022/v1/tenants/me`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/go/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_040="${MIG_DIR}/040_tenant_usage.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M84] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M84] FAIL — $*"; exit 1; }

PG_IMAGE="${M84_PG_IMAGE:-postgres:16-alpine}"
KONG_IMAGE="${M84_KONG_IMAGE:-kong:3.8}"
TC_IMG="m84-tc-$$:scratch"
NET="m84net-$$"
PG="m84-pg-$$"
TC_ON="m84-tc-on-$$"        # TENANT_SELFSERVE_ENABLED=1   (A · positive / B · reject)
TC_OFF="m84-tc-off-$$"      # TENANT_SELFSERVE_ENABLED unset (C · parity)
KONG_ON="m84-kong-on-$$"    # Kong → TC_ON  (alias tenant-control)
KONG_OFF="m84-kong-off-$$"  # Kong → TC_OFF (alias tenant-control)
# tenant-control listens on 3022 (matches the canonical kong.yml upstream url).
TC_PORT=3022
# Host-published ports: admin (direct, for seeding) + Kong proxy (the surface under test).
PORT_TC="${M84_PORT_TC:-18994}"        # direct tenant-control admin (seed only)
PORT_KONG_ON="${M84_PORT_KONG_ON:-18995}"
PORT_KONG_OFF="${M84_PORT_KONG_OFF:-18996}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m84-internal-service-token-$$"
TENANT_A="m84-a-$$"
TENANT_B="m84-b-$$"          # the "other" tenant — its id is probed via the admin-leak arm (B-b)
KEY_A_NAME="m84-a-primary-$$"
KEY_B_NAME="m84-b-secret-$$"
BODY_TMP="$(mktemp)"
KONG_YML="$(mktemp /tmp/m84-kong-$$.XXXXXX.yml)"

cleanup() {
  docker rm -fv "${KONG_ON}" "${KONG_OFF}" "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${KONG_YML}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration file the SAME way `make migrate` does: strip the leading
# `#` 42-header lines (sed '/^#/d') before piping to psql. $1 = file.
apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Admin (service-token) request DIRECTLY against tenant-control → status, body→BODY_TMP.
#   $1=method  $2=port  $3=path  $4(optional)=json body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# Self-service request THROUGH KONG with a tenant API key (Authorization: Bearer
# mbk_…) → status, body→BODY_TMP. The Bearer-mbk_ form is what the osionos Console
# uses; it exercises Kong's header forwarding (Kong forwards Authorization by
# default — no plugin on this public route strips it).
#   $1=method  $2=kong-port  $3=path  $4=api-key  $5(optional)=json body
kong_me() {
  local m="$1" p="$2" path="$3" key="$4" body="${5:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "Authorization: Bearer ${key}"
  fi
}

# A no-auth request THROUGH KONG → status, body→BODY_TMP.  $1=method $2=kong-port $3=path
kong_noauth() {
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "$1" "http://127.0.0.1:$2$3"
}

# Extract a top-level JSON string field off BODY_TMP. Tolerates ZERO matches
# (grep wrapped in `|| true` so pipefail+set -e does not kill us on a missing
# field — an empty result is a normal "field absent" outcome). $1=field.
json_str() { # $1=field
  { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://; s/"//g'
}

# tenant-control readiness: /health/live is the shared router liveness route.
wait_tc_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# Kong readiness through the proxy: probe a path we KNOW is wired so a 200/401
# (i.e. Kong is routing + the upstream answered) means the route is live. We use
# the no-auth /v1/tenants/me probe — it returns 401 once Kong forwards to a live
# tenant-control, or a 404 if the upstream /me handler is absent (parity arm).
# Any of {200,401,404,403} proves Kong is up AND reaching the upstream; a 502/503
# means Kong is up but the upstream is not yet reachable → keep waiting.
wait_kong_route() { # $1=kong-container $2=kong-port
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/v1/tenants/me" 2>/dev/null || true)"
    case "${code}" in
      200|401|403|404) return 0 ;;
    esac
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never routed to the upstream (last code='${code}'):"; docker logs "$1" 2>&1 | tail -25; return 1
}

# Write the MINIMAL DBLESS declarative config: the ONE new self-serve route, in
# front of upstream `tenant-control:3022` (a docker network alias — see boot). The
# route is byte-faithful to the canonical kong.yml `tenant-selfserve` block:
# anchored dual-regex paths, strip_path, PUBLIC (no key-auth / no ip-restriction),
# request-size-limiting 64 KiB + per-IP rate-limiting 120/min. A minimal global
# cors (allowing Authorization) is included so the config mirrors production
# header-forwarding fidelity; the curl assertions here send no preflight, so cors
# is not load-bearing — it is present only to keep the declarative faithful.
write_kong_yml() {
  cat > "${KONG_YML}" <<'YAML'
_format_version: "3.0"

plugins:
  - name: cors
    config:
      origins:
        - http://localhost:3001
        - http://127.0.0.1:3001
      methods: [GET, POST, PUT, PATCH, DELETE, OPTIONS]
      headers: [Authorization, Content-Type, X-API-Key, Accept]
      credentials: true
      max_age: 3600

services:
  # B4b-2: tenant self-service console surface (/v1/tenants/me*). PUBLIC by
  # design — the app authenticates ITSELF (Bearer mbk_… / X-API-Key / GoTrue JWT)
  # and Kong forwards that header unchanged, so NO key-auth and NO ip-restriction
  # here. Path safety is REGEX-TIGHT at the gate: `~/^/v1/tenants/me$` matches ONLY
  # the bare endpoint; `~/^/v1/tenants/me/.*` matches ONLY the /me/ subtree.
  # Neither matches /v1/tenants/members or /v1/tenants/mexico (those 404 at Kong),
  # and the admin /v1/tenants/{id} surface is unreachable here.
  #
  # PATH PRESERVATION — bare url + strip_path:false (the data-plane-direct /
  # storage-sign precedent, kong.yml lines 649-654 / 765-772), NOT a stripping
  # url. The tenant-control self-serve handlers are mounted at the FULL public
  # paths (selfserve.go: GET /v1/tenants/me, GET /v1/tenants/me/keys, …), so the
  # request path must reach the upstream VERBATIM. We deliberately do NOT use the
  # `url: …/v1/tenants/me` + strip_path:true form: Kong's documented rule strips
  # the ENTIRE regex match (greedy `.*`), so `/v1/tenants/me/keys` would strip to
  # "" and re-append to /v1/tenants/me → the upstream would see /v1/tenants/me and
  # the sub-route would be LOST. strip_path:false forwards the path untouched, so
  # /v1/tenants/me/keys → upstream /v1/tenants/me/keys with zero strip arithmetic.
  # Safety is still REGEX-gated (the over-match 404s at Kong, never reaches the
  # upstream); the upstream {id} handler's tokenOrSelf 401 is the second line.
  - name: tenant-selfserve
    url: http://tenant-control:3022
    routes:
      - name: tenant-selfserve
        paths:
          - ~/v1/tenants/me$
          - ~/v1/tenants/me/.*
        strip_path: false
        plugins:
          - name: request-size-limiting
            config: { allowed_payload_size: 64, size_unit: kilobytes }
          - name: rate-limiting
            config: { policy: local, limit_by: ip, minute: 120, hour: 3000 }
YAML
}

# Boot a Kong DBLESS container on the private net, mounting the minimal kong.yml.
# The upstream `http://tenant-control:3022/...` resolves via Docker's embedded DNS
# to whichever tenant-control container currently carries the `tenant-control`
# network-alias (TC_ON for the positive/reject arms, TC_OFF for parity) — that
# alias lives on the tenant-control container, and Kong, on the same network,
# resolves it. ($2 names the intended upstream for readability; resolution is
# alias-driven, not via this arg.)
boot_kong() { # $1=kong-name $2=upstream-tc-container(doc) $3=host-proxy-port
  docker run -d --name "$1" \
    --network "${NET}" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/kong.yml \
    -e KONG_PROXY_ACCESS_LOG=/dev/stdout \
    -e KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    -e KONG_PROXY_ERROR_LOG=/dev/stderr \
    -e KONG_ADMIN_ERROR_LOG=/dev/stderr \
    -e KONG_ADMIN_LISTEN=off \
    -e KONG_NGINX_WORKER_PROCESSES=1 \
    -e KONG_MEM_CACHE_SIZE=32m \
    -v "${KONG_YML}:/kong.yml:ro" \
    -p "127.0.0.1:$3:8000" \
    "${KONG_IMAGE}" >/dev/null
}

# ── 0) build the scratch tenant-control FROM CURRENT source ────────────────────
step "0/8 build scratch tenant-control from CURRENT source (the B4a self-service code Kong fronts)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT="${TC_PORT}" \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must front the drafted self-service code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + prelude + REAL 005/032/040 ────────────────────
step "1/8 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections' || true)" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "postgres up"

step "1b/8 apply prelude (schema_migrations, auth.current_tenant_id, roles), then REAL 005 + 032 + 040"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
apply_migration "${MIGRATION_040}" || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
[[ "$(psql_val "SELECT count(*) FROM public.tenants")" == "0" ]]   || fail "tenants should start EMPTY (line: 032 empty check)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_api_keys")" == "0" ]] || fail "tenant_api_keys should start EMPTY (line: keys empty check)"
ok "migrations 005 + 032 + 040 applied — tenants / tenant_api_keys / tenant_usage exist and are empty"

# ── 2) boot the SELF-SERVE-ON tenant-control (TENANT_SELFSERVE_ENABLED=1) ───────
#       under the network alias `tenant-control` so the canonical upstream url
#       (http://tenant-control:3022/...) resolves to it.
step "2/8 boot tenant-control TENANT_SELFSERVE_ENABLED=1 on alias tenant-control:${TC_PORT} (direct admin on :${PORT_TC})"
docker run -d --name "${TC_ON}" --network "${NET}" --network-alias tenant-control \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_SELFSERVE_ENABLED=1 \
  -e TENANT_CONTROL_PORT="${TC_PORT}" \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:${TC_PORT}" "${TC_IMG}" >/dev/null
wait_tc_ready "${TC_ON}" "${PORT_TC}" || fail "self-serve-ON tenant-control not ready (line: wait_tc_ready TC_ON)"
ok "self-serve-ON tenant-control up (EnsureSchema applied, /me routes mounted, alias=tenant-control)"

# ── 2b) boot Kong (DBLESS) in front of TC_ON ───────────────────────────────────
step "2b/8 write minimal kong.yml (the NEW tenant-selfserve route) + boot Kong ${KONG_IMAGE} (DBLESS) → tenant-control:${TC_PORT} on :${PORT_KONG_ON}"
write_kong_yml
boot_kong "${KONG_ON}" "${TC_ON}" "${PORT_KONG_ON}"
wait_kong_route "${KONG_ON}" "${PORT_KONG_ON}" || fail "Kong(ON) never routed to tenant-control (line: wait_kong_route ON)"
ok "Kong(ON) up + routing the public /v1/tenants/me* surface → tenant-control:${TC_PORT}"

# ── 3) SEED two tenants + a key each, DIRECTLY on tenant-control (admin surface
#       is NOT exposed via the public Kong route — by design) ──────────────────
step "3/8 seed tenant A(${TENANT_A}) + tenant B(${TENANT_B}) via DIRECT POST /v1/tenants (X-Service-Token)"
C="$(admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_A}\",\"name\":\"A\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant A expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed A)"
C="$(admin_req POST "${PORT_TC}" /v1/tenants "{\"id\":\"${TENANT_B}\",\"name\":\"B\",\"plan\":\"nano\"}")"
[[ "${C}" == "201" ]] || fail "seed tenant B expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed B)"
ok "tenants A + B created (both nano)"

step "3b/8 mint A's key (admin-scoped) + B's uniquely-named key via DIRECT POST /v1/tenants/{id}/keys (X-Service-Token)"
C="$(admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_A}/keys" "{\"name\":\"${KEY_A_NAME}\",\"scopes\":[\"read\",\"write\",\"admin\"]}")"
[[ "${C}" == "201" ]] || fail "mint A key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: mint A key)"
KEY_A="$(json_str key)"
[[ "${KEY_A}" == mbk_* ]] || fail "A key not returned as a full mbk_ key — got '${KEY_A}' — $(head -c 300 "${BODY_TMP}") (line: A key shape)"
C="$(admin_req POST "${PORT_TC}" "/v1/tenants/${TENANT_B}/keys" "{\"name\":\"${KEY_B_NAME}\"}")"
[[ "${C}" == "201" ]] || fail "mint B key expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: mint B key)"
KEY_B="$(json_str key)"
[[ "${KEY_B}" == mbk_* ]] || fail "B key not returned as a full mbk_ key — got '${KEY_B}' — $(head -c 300 "${BODY_TMP}") (line: B key shape)"
ok "minted A's key (${KEY_A_NAME}) + B's key (${KEY_B_NAME}); both full mbk_ keys"

# ── 4) (A · POSITIVE) drive the /me surface THROUGH KONG with A's key ──────────
step "4/8 (A · POSITIVE) GET kong/v1/tenants/me (Bearer A's key) → 200, body is A's tenant"
C="$(kong_me GET "${PORT_KONG_ON}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET kong/me expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A GET kong/me)"
grep -q "\"id\":\"${TENANT_A}\"" "${BODY_TMP}" \
  || fail "(A) GET kong/me body is not tenant A (id=${TENANT_A}) — $(head -c 300 "${BODY_TMP}") (line: A kong/me is A)"
grep -q '"plan":"nano"' "${BODY_TMP}" \
  || fail "(A) GET kong/me body missing plan=nano — $(head -c 300 "${BODY_TMP}") (line: A kong/me plan)"
ok "(A) GET kong/v1/tenants/me → 200; Kong forwarded the Bearer key, tenant-control resolved A (no path id)"

step "4b/8 (A · POSITIVE) sub-route GET kong/v1/tenants/me/keys (Bearer A's key) → 200, lists A's key"
C="$(kong_me GET "${PORT_KONG_ON}" /v1/tenants/me/keys "${KEY_A}")"
[[ "${C}" == "200" ]] || fail "(A) GET kong/me/keys expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A GET kong/me/keys)"
grep -q "${KEY_A_NAME}" "${BODY_TMP}" \
  || fail "(A) GET kong/me/keys missing A's key '${KEY_A_NAME}' — the /me/ sub-path did not reach the upstream verbatim — $(head -c 300 "${BODY_TMP}") (line: A kong/me/keys lists A)"
ok "(A) GET kong/v1/tenants/me/keys → 200; the /me/ subtree regex matched and strip_path:false forwarded /me/keys verbatim"

# ── 5) (B · REJECT, LOAD-BEARING) no-auth · admin-leak · prefix-overmatch ──────
step "5/8 (B · REJECT) (a) no auth header through Kong → 401"
C="$(kong_noauth GET "${PORT_KONG_ON}" /v1/tenants/me)"
[[ "${C}" == "401" ]] || fail "(B-a) GET kong/me with NO auth expected 401, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B no-auth)"
ok "(B-a) unauthenticated kong/v1/tenants/me → 401 (Kong forwards; tenant-control selfAuth rejects)"

step "5b/8 (B · REJECT, LOAD-BEARING) (b) admin surface NOT reachable — GET kong/v1/tenants/${TENANT_B} must NOT return B (expect 401/404, never 200)"
# Probe the OTHER tenant's admin {id} path through the PUBLIC route, carrying A's
# key as a Bearer (the realistic attack: a logged-in tenant trying to read a peer
# via the console surface). The anchored regex means this path does not match the
# tenant-selfserve route at all → 404 at Kong; even if it DID reach the upstream
# {id} handler, tokenOrSelf 401s a bare API key. Either way it must NOT be 200-B.
C="$(kong_me GET "${PORT_KONG_ON}" "/v1/tenants/${TENANT_B}" "${KEY_A}")"
[[ "${C}" != "200" ]] \
  || fail "(B-b) ADMIN LEAK: GET kong/v1/tenants/${TENANT_B} returned 200 through the PUBLIC route — cross-tenant/admin exposure! body=$(head -c 300 "${BODY_TMP}") (line: B admin-leak status)"
# Defense in depth: B's body must never appear regardless of status.
if grep -q "${TENANT_B}" "${BODY_TMP}"; then
  fail "(B-b) ADMIN LEAK: tenant B's id leaked in the response body (status ${C}) through the public route! body=$(head -c 300 "${BODY_TMP}") (line: B admin-leak body)"
fi
case "${C}" in
  401|404) : ;;
  *) fail "(B-b) GET kong/v1/tenants/${TENANT_B} returned unexpected ${C} (want 401/404, never 200) — $(head -c 300 "${BODY_TMP}") (line: B admin-leak code)" ;;
esac
ok "(B-b) the admin /v1/tenants/{id} surface is NOT reachable via the public console route (${C}, never 200-with-B)"

step "5c/8 (B · REJECT, LOAD-BEARING) (c) prefix-overmatch — GET kong/v1/tenants/members + /v1/tenants/mexico must NOT be 200 (anchored regex 404s them at Kong)"
# The bare-prefix trap: '/v1/tenants/me' as a plain prefix would ALSO match these.
# The anchored `~/^/v1/tenants/me$` + `~/^/v1/tenants/me/.*` do not, so Kong has no
# matching route → 404. Carry A's key to prove it is the ROUTING (not auth) that
# rejects: even an authenticated caller cannot reach an over-matched path.
for over in /v1/tenants/members /v1/tenants/mexico; do
  C="$(kong_me GET "${PORT_KONG_ON}" "${over}" "${KEY_A}")"
  [[ "${C}" != "200" ]] \
    || fail "(B-c) PREFIX OVERMATCH: GET kong${over} returned 200 — the bare-prefix trap is OPEN, the route is not regex-tight! $(head -c 300 "${BODY_TMP}") (line: B overmatch ${over})"
  [[ "${C}" == "404" ]] \
    || fail "(B-c) GET kong${over} expected 404 (no Kong route matches an anchored /me regex), got ${C} — $(head -c 300 "${BODY_TMP}") (line: B overmatch 404 ${over})"
done
ok "(B-c) /v1/tenants/members + /v1/tenants/mexico → 404 at Kong (anchored regex rejects the prefix overmatch; never reaches the upstream)"

# ── 6) (C · PARITY) the SAME Kong route in front of self-serve-OFF tenant-control
#       → GET kong/v1/tenants/me 401 (the /me handler is absent; request falls to
#       the {id} wildcard whose tokenOrSelf rejects a bare key) = pre-B4a baseline ─
step "6/8 (C · PARITY) stop Kong(ON)+TC_ON, boot TC_OFF (TENANT_SELFSERVE_ENABLED unset) under the SAME alias tenant-control"
# Tear the ON pair down BEFORE the OFF pair so the network-alias `tenant-control`
# is unambiguous (no two containers share it) and a fresh Kong cannot cache a DNS
# answer pointing at the ON binary (openRisk: alias-swap). We rm -f both, then
# boot OFF + a fresh Kong against it.
docker rm -f "${KONG_ON}" "${TC_ON}" >/dev/null 2>&1 || true
docker run -d --name "${TC_OFF}" --network "${NET}" --network-alias tenant-control \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT="${TC_PORT}" \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_TC}:${TC_PORT}" "${TC_IMG}" >/dev/null
wait_tc_ready "${TC_OFF}" "${PORT_TC}" || fail "self-serve-OFF tenant-control not ready (line: wait_tc_ready TC_OFF)"
ok "self-serve-OFF tenant-control up (same DB, same seeded tenants; /me routes NOT mounted)"

step "6b/8 (C · PARITY) boot a FRESH Kong → tenant-control(OFF):${TC_PORT} on :${PORT_KONG_OFF}"
boot_kong "${KONG_OFF}" "${TC_OFF}" "${PORT_KONG_OFF}"
wait_kong_route "${KONG_OFF}" "${PORT_KONG_OFF}" || fail "Kong(OFF) never routed to tenant-control (line: wait_kong_route OFF)"
ok "Kong(OFF) up + routing → tenant-control(OFF)"

step "6c/8 (C · PARITY) GET kong/v1/tenants/me (Bearer A's key) on the OFF stack → 401 (handler absent; falls to {id} wildcard, tokenOrSelf rejects a bare key) — the SAME request was 200 on ON (arm 4)"
C="$(kong_me GET "${PORT_KONG_OFF}" /v1/tenants/me "${KEY_A}")"
[[ "${C}" == "401" ]] \
  || fail "(C) PARITY: GET kong/me (A's key) with self-serve OFF expected 401 — the pre-B4a baseline ('me' caught by the {id} wildcard whose tokenOrSelf rejects a bare API key); ON returned 200 — got ${C} — $(head -c 300 "${BODY_TMP}") (line: C kong/me parity)"
ok "(C) GET kong/v1/tenants/me → 401 OFF vs 200 ON — the flag gates the surface; the Kong route is harmless when the feature is off (byte-parity)"

# ── 7) summarize ──────────────────────────────────────────────────────────────
step "7/8 summary"
green "[M84] (A) POSITIVE: through Kong, A's Bearer key drives GET /v1/tenants/me (200, body=A) + sub-route GET /v1/tenants/me/keys (200)"
green "[M84] (B) REJECT:   no-auth → 401; admin /v1/tenants/{other} NOT reachable (401/404, never 200-with-B); prefix-overmatch /members + /mexico → 404 at Kong (anchored regex)"
green "[M84] (C) PARITY:   self-serve OFF → kong/v1/tenants/me 401 (vs 200 ON) = pre-B4a baseline; the public Kong route is harmless when the feature is off"

# ── 8) emit the gate event via the kernel log helper (best-effort) ─────────────
step "8/8 log GATE m84=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b4b-console-route}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m84=PASS" --outcome pass \
      --msg "B4b-2 console route: the /v1/tenants/me* self-service surface is wired LIVE through a Kong 3.8 DBLESS route (anchored dual-regex paths, strip_path, PUBLIC + size/rate limits) → tenant-control:3022. THROUGH KONG: GET /v1/tenants/me (Bearer mbk_ key) -> 200 body=A + sub-route /me/keys -> 200; no-auth -> 401; admin /v1/tenants/{other} NOT reachable (401/404, never 200); prefix-overmatch /members + /mexico -> 404 at Kong; with TENANT_SELFSERVE_ENABLED unset -> kong/v1/tenants/me 401 (pre-B4a baseline) = byte-parity, the route is harmless when off" \
      --ref "scripts/verify/m84-console-route.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M84] ALL GATES GREEN — B4b-2 console route: /v1/tenants/me* live through Kong, admin surface unreachable, prefix-tight, byte-parity when off"
exit 0
