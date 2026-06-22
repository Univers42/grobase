#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    provision-contract.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dev.pro.photo@gmail.com>         +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# GENERIC contract-driven provisioner — the one consumer of an app's declarative
# provisioning contract (infra/config/contracts/<app>.json). It subsumes the
# per-app scripts/seed/*-tenant.sh: read the contract → create the app's OWN
# database → POST /v1/provision (tenant + key + roles + mount, idempotent) →
# set read_scoped → apply schema → run seed → emit the frontend's config. grobase
# stays app-agnostic; ALL app specifics live in the contract.
#
# Usage:  bash scripts/provision-contract.sh infra/config/contracts/<app>.json
# Idempotent: re-running a converged contract is a no-op (mount/key reused).
set -euo pipefail

CONTRACT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/service-auth.sh"

PG_CTN="${PG_CONTAINER:-mini-baas-postgres}"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '· %s\n' "$*" >&2; }

# Preflight: the tools + the contract file must exist.
preflight() {
  [ -n "${CONTRACT}" ] || die "usage: provision-contract.sh <contract.json>"
  [ -f "${CONTRACT}" ] || die "contract not found: ${CONTRACT}"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required (service-auth signer)"
  command -v docker >/dev/null 2>&1 || die "docker is required"
}

# Read a container env var (works for distroless images — no shell in the image).
ctn_env() { # $1 container, $2 var
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^$2=" | head -1 | cut -d= -f2-
}

# Host port a container publishes for $2 (e.g. 8000/tcp).
ctn_port() { # $1 container, $2 container-port/proto
  docker port "$1" "$2" 2>/dev/null | head -1 | sed 's/.*://'
}

# Discover the running stack: gateway/control-plane URLs, service token, Kong
# consumer keys, Postgres credentials. Everything from the live containers so a
# stale host env can't poison it (the lib-live-tenant.sh discipline).
discover_stack() {
  local kp tp
  kp="$(ctn_port mini-baas-kong 8000/tcp)" || true
  tp="$(ctn_port mini-baas-tenant-control 3022/tcp)" || true
  [ -n "${kp}" ] || die "kong host port not found (is the stack up? make up)"
  [ -n "${tp}" ] || die "tenant-control host port not found"
  KONG_URL="http://127.0.0.1:${kp}"
  TC_URL="http://127.0.0.1:${tp}"
  SERVICE_TOKEN="$(ctn_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
  ANON_KEY="$(ctn_env mini-baas-kong KONG_PUBLIC_API_KEY)"
  SERVICE_KEY="$(ctn_env mini-baas-kong KONG_SERVICE_API_KEY)"
  PG_USER="$(ctn_env "${PG_CTN}" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
  PG_PASS="$(ctn_env "${PG_CTN}" POSTGRES_PASSWORD)"; PG_PASS="${PG_PASS:-postgres}"
  [ -n "${SERVICE_TOKEN}" ] || die "INTERNAL_SERVICE_TOKEN not found on tenant-control"
  [ -n "${SERVICE_KEY}" ] || die "Kong service key not found"
  export SERVICE_TOKEN
  note "stack: kong=${KONG_URL} tc=${TC_URL}"
}

# Run SQL in the Postgres container against database $1.
pg_sql() { # $1 database, stdin sql
  docker exec -i -e PGPASSWORD="${PG_PASS}" "${PG_CTN}" \
    psql -U "${PG_USER}" -d "$1" -v ON_ERROR_STOP=1 -tA
}

# Create database $1 if it does not already exist (idempotent; the per-app DB is
# the physical isolation boundary — two apps' DBs can never merge).
ensure_database() { # $1 dbname
  local exists
  exists="$(printf "SELECT 1 FROM pg_database WHERE datname='%s';" "$1" | pg_sql postgres || true)"
  if [ "${exists}" = "1" ]; then note "db ${1}: exists"; return 0; fi
  printf 'CREATE DATABASE "%s";' "$1" | pg_sql postgres >/dev/null
  note "db ${1}: created"
}

# Resolve a mount's DSN from its contract credentials block. docker_service reads
# the Postgres container creds + dials the in-network host alias the data plane
# uses; fly_secret reads the DSN straight from an env var (prod).
resolve_dsn() { # $1 mount index
  local src host port db dsn_env
  src="$(jq -r ".mounts[$1].credentials.source" "${CONTRACT}")"
  db="$(jq -r ".mounts[$1].database" "${CONTRACT}")"
  case "${src}" in
    fly_secret)
      dsn_env="$(jq -r ".mounts[$1].credentials.dsn_env" "${CONTRACT}")"
      dsn="$(printenv "${dsn_env}" || true)"
      [ -n "${dsn}" ] || die "mount ${1}: ${dsn_env} not set in env" ;;
    docker_service|*)
      host="$(jq -r ".mounts[$1].credentials.host // \"postgres\"" "${CONTRACT}")"
      port="$(jq -r ".mounts[$1].credentials.port // 5432" "${CONTRACT}")"
      dsn="postgres://${PG_USER}:${PG_PASS}@${host}:${port}/${db}" ;;
  esac
  printf '%s' "${dsn}"
}

# Build the StackSpec engines[] array, injecting each resolved DSN. Also creates
# each app database first (db_per_tenant is not reconcilable → made out-of-band).
build_engines() {
  local n eng iso dsn db count i
  ENGINES='[]'
  count="$(jq '.mounts | length' "${CONTRACT}")"
  for ((i=0; i<count; i++)); do
    eng="$(jq -r ".mounts[$i].engine" "${CONTRACT}")"
    db="$(jq -r ".mounts[$i].database" "${CONTRACT}")"
    [ "${eng}" = "postgresql" ] && ensure_database "${db}"
    n="$(jq -r ".mounts[$i].name" "${CONTRACT}")"
    iso="$(jq -r ".mounts[$i].isolation // \"shared_rls\"" "${CONTRACT}")"
    dsn="$(resolve_dsn "$i")"
    ENGINES="$(jq -c --arg e "${eng}" --arg n "${n}" --arg c "${dsn}" --arg i "${iso}" \
      '. + [{engine:$e,name:$n,connection_string:$c,isolation:$i}]' <<<"${ENGINES}")"
  done
}

# POST the contract to /v1/provision (HMAC-signed). The live route decodes the
# ProvisionRequest shape (mounts[] + seed_roles + default_key_name), not the raw
# StackSpec — ENGINES is already MountSpec-shaped, so it maps directly. Captures
# the result in PROV (tenant + per-resource ids).
provision_stack() {
  local tenant name owner plan keyname req code
  tenant="$(jq -r '.tenant.id' "${CONTRACT}")"
  name="$(jq -r '.tenant.name // .tenant.id' "${CONTRACT}")"
  owner="$(jq -r '.tenant.owner_user_id // ""' "${CONTRACT}")"
  plan="$(jq -r '.tenant.plan // "free"' "${CONTRACT}")"
  keyname="$(jq -r '.api_keys[0].name // "default"' "${CONTRACT}")"
  local rolename
  rolename="$(jq -r '.roles[0].name // "user"' "${CONTRACT}")"
  req="$(jq -nc --arg t "${tenant}" --arg name "${name}" --arg o "${owner}" --arg p "${plan}" \
    --arg kn "${keyname}" --arg rn "${rolename}" --argjson m "${ENGINES}" \
    '{tenant:$t,name:$name,owner_user_id:$o,plan:$p,default_key_name:$kn,default_role_name:$rn,seed_roles:true,mounts:$m}')"
  svc_auth POST /v1/provision "${req}"
  code="$(curl -s -o /tmp/prov.json -w '%{http_code}' -X POST "${TC_URL}/v1/provision" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${req}")"
  [ "${code}" = "200" ] || [ "${code}" = "201" ] || die "provision failed (${code}): $(cat /tmp/prov.json)"
  PROV="$(cat /tmp/prov.json)"
  TENANT="${tenant}"
  note "provisioned tenant ${tenant} (outcome $(jq -r '.outcome' <<<"${PROV}"))"
}

# Resolve a mount's database id by name via the adapter-registry (works on first
# run and on re-run, where /v1/provision no longer re-emits ids).
mount_id() { # $1 mount name
  curl -s "${KONG_URL}/admin/v1/databases" \
    -H "apikey: ${SERVICE_KEY}" -H "X-Tenant-Id: ${TENANT}" \
    | jq -r --arg n "$1" '.[]? | select(.name==$n) | .id' | head -1
}

# Set read_scoped on each mount that asked for it (StackSpec carries no
# read_scoped; this UPDATE is the authoritative convergence — re-register 409s,
# this always converges). Per-mount owner-scoping is what isolates users.
apply_read_scoped() {
  local count i n rs id
  count="$(jq '.mounts | length' "${CONTRACT}")"
  for ((i=0; i<count; i++)); do
    rs="$(jq -r ".mounts[$i].read_scoped // false" "${CONTRACT}")"
    [ "${rs}" = "true" ] || continue
    n="$(jq -r ".mounts[$i].name" "${CONTRACT}")"
    id="$(mount_id "${n}")"
    [ -n "${id}" ] || die "mount ${n}: id not found after provision"
    printf "UPDATE public.tenant_databases SET read_scoped=true WHERE id='%s' AND tenant_id='%s';" \
      "${id}" "${TENANT}" | pg_sql postgres >/dev/null
    note "mount ${n} (${id}): read_scoped=true"
  done
}

# Apply each engine's schema file into its own database (idempotent DDL expected).
apply_schema() {
  local count i eng db file
  count="$(jq '.mounts | length' "${CONTRACT}")"
  for ((i=0; i<count; i++)); do
    eng="$(jq -r ".mounts[$i].engine" "${CONTRACT}")"
    file="$(jq -r ".schema.${eng} // empty" "${CONTRACT}")"
    [ -n "${file}" ] || continue
    [ -f "${REPO}/${file}" ] || die "schema file missing: ${file}"
    db="$(jq -r ".mounts[$i].database" "${CONTRACT}")"
    pg_sql "${db}" < "${REPO}/${file}" >/dev/null
    note "schema applied to ${db} (${file})"
  done
}

# Resolve the LEAST-PRIVILEGE frontend key: reuse the one already emitted (so
# re-runs stay idempotent); else mint a scoped key from the contract's api_keys
# scopes (read/write — NOT the provision default admin key, which a browser must
# never hold). The provision default key stays the tenant's admin key, unexposed.
# key_valid verifies a cleartext mbk_ key still resolves to an identity
# (POST /v1/keys/verify → 200). Guards against reusing a stale emitted key after
# a DB reset, where build/<app>.env persists but the key is gone from the DB.
key_valid() {
  local vbody code
  vbody="$(jq -nc --arg k "$1" '{key:$k}')"
  svc_auth POST /v1/keys/verify "${vbody}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${TC_URL}/v1/keys/verify" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${vbody}")"
  [ "${code}" = "200" ]
}

# mint_key NAME SCOPES — POST a scoped key for the tenant; sets KEY_CODE (HTTP status)
# and writes the reply to /tmp/prov-key.json. svc_auth output is not captured.
mint_key() {
  local body
  body="$(jq -nc --argjson s "${2}" --arg n "${1}" '{name:$n,scopes:$s}')"
  svc_auth POST "/v1/tenants/${TENANT}/keys" "${body}"
  KEY_CODE="$(curl -s -o /tmp/prov-key.json -w '%{http_code}' -X POST \
    "${TC_URL}/v1/tenants/${TENANT}/keys" "${SVC_AUTH[@]}" \
    -H 'Content-Type: application/json' -d "${body}")"
}

# resolve_api_key — reuse a verified emitted key, else mint a scoped 'frontend' key.
# Idempotent on re-run: if the emitted file was lost but the named key still exists,
# the first mint 409s ("already exists"); fall back to a unique name instead of dying.
resolve_api_key() {
  API_KEY="$(read_emitted_key)"
  if [ -n "${API_KEY}" ] && key_valid "${API_KEY}"; then
    note "api key: reused from emitted config (verified)"
    return 0
  fi
  [ -n "${API_KEY}" ] && note "emitted api key stale (verify failed) — minting fresh"
  local scopes
  scopes="$(jq -c '.api_keys[0].scopes // ["read","write"]' "${CONTRACT}")"
  mint_key "frontend" "${scopes}"
  if [ "${KEY_CODE}" != "201" ] && grep -q 'already exists' /tmp/prov-key.json 2>/dev/null; then
    note "key 'frontend' exists from a prior run (emit lost) — minting a unique name"
    mint_key "frontend-$(date +%s)" "${scopes}"
  fi
  [ "${KEY_CODE}" = "201" ] || die "key mint failed (${KEY_CODE}): $(cat /tmp/prov-key.json)"
  API_KEY="$(jq -r '.key' /tmp/prov-key.json)"
  note "api key: minted scoped (${scopes})"
}

# Read a previously-emitted API key from the contract's frontend config target
# (so re-runs stay idempotent without re-minting).
read_emitted_key() {
  local path
  local f
  path="$(jq -r '.frontend_config.path // empty' "${CONTRACT}")"
  [ -n "${path}" ] || return 0
  case "${path}" in /*) f="${path}" ;; *) f="${REPO}/${path}" ;; esac
  [ -f "${f}" ] || return 0
  grep -hoE '(PUBLIC_API_KEY|VITE_BAAS_API_KEY|GROBASE_APP_KEY)=mbk_[A-Za-z0-9_-]+' "${f}" 2>/dev/null \
    | head -1 | cut -d= -f2-
}

# Substitute the contract's frontend_config tokens and write the config file the
# frontend reads. Tokens: ${KONG_URL} ${ANON_KEY} ${API_KEY} ${TENANT_ID}
# ${MOUNT_ID:<name>}. The frontend owns no data — only this emitted config.
emit_frontend_config() {
  local path out k v line
  path="$(jq -r '.frontend_config.path // empty' "${CONTRACT}")"
  [ -n "${path}" ] || { note "no frontend_config — skipped"; return 0; }
  case "${path}" in /*) out="${path}" ;; *) out="${REPO}/${path}" ;; esac
  mkdir -p "$(dirname "${out}")"; : >"${out}"
  while IFS=$'\t' read -r k v; do
    line="$(subst_tokens "${v}")"
    printf '%s=%s\n' "${k}" "${line}" >>"${out}"
  done < <(jq -r '.frontend_config.vars | to_entries[] | "\(.key)\t\(.value)"' "${CONTRACT}")
  note "frontend config emitted → ${path}"
}

# Replace one value's tokens with live values (mount ids resolved by name).
subst_tokens() { # $1 template value
  local v="$1" name id
  v="${v//\$\{KONG_URL\}/${KONG_URL}}"
  v="${v//\$\{ANON_KEY\}/${ANON_KEY}}"
  v="${v//\$\{API_KEY\}/${API_KEY}}"
  v="${v//\$\{TENANT_ID\}/${TENANT}}"
  while [[ "${v}" =~ \$\{MOUNT_ID:([a-zA-Z0-9_-]+)\} ]]; do
    name="${BASH_REMATCH[1]}"; id="$(mount_id "${name}")"
    v="${v//\$\{MOUNT_ID:${name}\}/${id}}"
  done
  printf '%s' "${v}"
}

# Run the contract's seed script (optional) with the resolved connection env.
run_seed() {
  local script
  script="$(jq -r '.seed.script // empty' "${CONTRACT}")"
  [ -n "${script}" ] || return 0
  [ -f "${REPO}/${script}" ] || die "seed script missing: ${script}"
  note "seeding via ${script}"
  BAAS_URL="${KONG_URL}" ANON_KEY="${ANON_KEY}" API_KEY="${API_KEY}" \
    TENANT_ID="${TENANT}" PG_USER="${PG_USER}" PG_PASS="${PG_PASS}" PG_CTN="${PG_CTN}" \
    bash "${REPO}/${script}"
}

main() {
  preflight
  discover_stack
  build_engines
  provision_stack
  apply_read_scoped
  apply_schema
  resolve_api_key
  emit_frontend_config
  run_seed
  printf '✅ provisioned "%s" from %s\n' "${TENANT}" "${CONTRACT}"
}

main "$@"
