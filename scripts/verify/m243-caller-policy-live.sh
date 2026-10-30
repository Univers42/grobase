#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m243-caller-policy-live.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 18:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 18:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Live leg of m243 (D1, ADR 0023): the forged-identity arms against a scratch
# data plane under DATA_PLANE_CALLER_POLICY=enforce, SERVICE_TOKEN_MODE=hmac,
# with a scratch postgres (log_connections on) and a scratch tenant-control.
#
#   403: shared token on /v1/query · tenant-control key on /v1/query ·
#        query-router key on /v1/admin/{raw,migrate} claiming service_role ·
#        identity tenant != mount tenant · inline_dsn on a route that refuses
#        it, with ZERO connects reaching postgres.        401: unsigned.
#   200: tenant-control migrate with an inline DSN · the Kong relay
#        (tenant-control /v1/admin/migrate, apikey arm) · query-router
#        /v1/query with an inline DSN · a dial control that postgres does log.
#   relay's service-token arm (devil D1-P1): 401 under enforce · 200 and one
#        would_deny line under shadow · an unknown policy refuses boot.
#
# Containers, network and keys are per run (suffix $$) and removed by the EXIT
# trap; keys reach `docker run` by name only (-e NAME), never on argv. It never
# touches a mini-baas-* container. M243_DPR_IMAGE / M243_TC_IMAGE reuse prebuilt
# images (never removed); otherwise both are built from this checkout.
#
# Caveat: "zero connects" is read from postgres' own log (log_connections), so
# it proves no TCP session reached THIS postgres under a user name only this arm
# uses; a dial to another host would not show here (the unit test
# k5_a_refused_inline_dsn_is_never_dialled counts raw TCP accepts). The Kong arm
# calls tenant-control directly — Kong's route to it is not booted here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/service-auth.sh
. "${SCRIPT_DIR}/../lib/service-auth.sh"

RUN="d1keys-m243-$$"
NET="${RUN}-net"
PG="${RUN}-pg"
DPR="${RUN}-dpr"
TCC="${RUN}-tc"
DPR_IMG="${M243_DPR_IMAGE:-${RUN}-dpr:scratch}"
TC_IMG="${M243_TC_IMAGE:-${RUN}-tc:scratch}"
DPR_PORT="${M243_DPR_PORT:-18243}"
TC_PORT="${M243_TC_PORT:-18244}"
BODY="$(mktemp)"

export SERVICE_TOKEN_MODE=hmac DATA_PLANE_CALLER_POLICY=enforce
INTERNAL_SERVICE_TOKEN="$(openssl rand -hex 32)"
DATA_PLANE_KEY_QUERY_ROUTER="$(openssl rand -hex 32)"
DATA_PLANE_KEY_TENANT_CONTROL="$(openssl rand -hex 32)"
KONG_SERVICE_API_KEY="$(openssl rand -hex 32)"
POSTGRES_PASSWORD="$(openssl rand -hex 16)"
export INTERNAL_SERVICE_TOKEN DATA_PLANE_KEY_QUERY_ROUTER DATA_PLANE_KEY_TENANT_CONTROL \
  KONG_SERVICE_API_KEY POSTGRES_PASSWORD

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }

cleanup() {
  docker rm -fv "${DPR}" "${TCC}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  [ -n "${M243_DPR_IMAGE:-}" ] || docker image rm -f "${DPR_IMG}" >/dev/null 2>&1 || true
  [ -n "${M243_TC_IMAGE:-}" ] || docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY}"
}
trap cleanup EXIT

build_images() {
  [ -n "${M243_DPR_IMAGE:-}" ] ||
    docker build -q -t "${DPR_IMG}" "${ROOT}/src/data-plane-router" >/dev/null
  [ -n "${M243_TC_IMAGE:-}" ] ||
    docker build -q -t "${TC_IMG}" --build-arg APP=tenant-control \
      --build-arg PORT=3022 "${ROOT}/src/control-plane" >/dev/null
}

# wait_ready <url> <container> — until <url> answers 2xx, or the container dies.
wait_ready() {
  for _ in $(seq 1 120); do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$2" 2>/dev/null)" = true ] || break
    sleep 0.5
  done
  docker logs "$2" 2>&1 | tail -15 >&2
  return 1
}

boot_postgres() {
  docker network create "${NET}" >/dev/null
  docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD \
    postgres:16-alpine -c log_connections=on >/dev/null
  for _ in $(seq 1 80); do
    [ "$(docker logs "${PG}" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] && return 0
    sleep 0.5
  done
  fail "scratch postgres never reached its post-init steady state"
}

boot_data_plane() {
  docker run -d --name "${DPR}" --network "${NET}" -e RUST_LOG=info \
    -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled -e SERVICE_TOKEN_MODE \
    -e INTERNAL_SERVICE_TOKEN -e DATA_PLANE_CALLER_POLICY \
    -e DATA_PLANE_KEY_QUERY_ROUTER -e DATA_PLANE_KEY_TENANT_CONTROL \
    -p "127.0.0.1:${DPR_PORT}:4011" "${DPR_IMG}" >/dev/null
  wait_ready "http://127.0.0.1:${DPR_PORT}/v1/capabilities" "${DPR}" ||
    fail "the data plane did not start under enforce"
}

# The relay arm needs tenant-control up; 1 = it never became ready. Its boot
# check wants public.tenants (migration 032); the relay never reads it, so a
# one-table stand-in is enough here.
# tc_start <policy> — (re)start the scratch tenant-control under that caller policy.
tc_start() {
  docker rm -fv "${TCC}" >/dev/null 2>&1 || true
  docker run -d --name "${TCC}" --network "${NET}" \
    -e TENANT_CONTROL_PORT=3022 -e SERVICE_TOKEN_MODE -e INTERNAL_SERVICE_TOKEN \
    -e DATABASE_URL="postgres://postgres:${POSTGRES_PASSWORD}@${PG}:5432/postgres?sslmode=disable" \
    -e RUST_DATA_PLANE_URL="http://${DPR}:4011" -e DATA_PLANE_CALLER_POLICY="$1" \
    -e DATA_PLANE_KEY_TENANT_CONTROL -e KONG_SERVICE_API_KEY \
    -p "127.0.0.1:${TC_PORT}:3022" "${TC_IMG}" >/dev/null
}

boot_tenant_control() {
  docker exec -e PGOPTIONS='-c client_min_messages=warning' "${PG}" psql -U postgres -qc \
    'create table if not exists public.tenants (id text primary key, name text, plan text)' >/dev/null
  tc_start "$1"
  wait_ready "http://127.0.0.1:${TC_PORT}/health/live" "${TCC}"
}

# mount_json <id> <tenant> <db user> — a postgres mount on the scratch DB.
mount_json() {
  local dsn="postgres://$3:${POSTGRES_PASSWORD}@${PG}:5432/postgres"
  printf '{"id":"%s-%s","tenant_id":"%s","engine":"postgresql","name":"db","credential_ref":{"provider":"inline","reference":"db","version":"1"},"inline_dsn":"%s"}' \
    "$1" "$$" "$2" "${dsn}"
}

# envelope <identity tenant> <mount json> <tail> — the body every route takes.
envelope() {
  printf '{"identity":{"tenant_id":"%s","user_id":"m243","roles":["service_role"],"scopes":["admin"],"source":"service_token"},"mount":%s,%s}' \
    "$1" "$2" "$3"
}

QUERY='"operation":{"op":"list","resource":"m243_probe"}'
RAW='"sql":"select 1"'
migrate_tail() { printf '"name":"%s","statements":["create table if not exists public.%s (id text primary key, owner_id text, tenant_id text)"]' "$1" "$1"; }

# call <key|""> <path> <body> — status of a POST to the data plane, signed
# with <key> (none when empty); the response body lands in ${BODY}.
call() {
  local auth=()
  if [ -n "$1" ]; then
    svc_auth_with "$1" POST "$2" "$3"
    auth=("${SVC_AUTH[@]}")
  fi
  curl -s -o "${BODY}" -w '%{http_code}' -X POST "http://127.0.0.1:${DPR_PORT}$2" \
    -H 'Content-Type: application/json' "${auth[@]}" -d "$3"
}

# expect <want> <label> <key|""> <path> <body>
expect() {
  local got
  got="$(call "$3" "$4" "$5")"
  [ "${got}" = "$1" ] || fail "$2: want $1, got ${got} — $(head -c 200 "${BODY}")"
  pass "$2 → $1"
}

dials_by() { docker logs "${PG}" 2>&1 | grep -c "user=$1\|\"$1\"" || true; }

has_table() {
  docker exec "${PG}" psql -U postgres -tAc \
    "select count(*) from pg_tables where tablename = '$1'" | grep -qx 1
}

QR="${DATA_PLANE_KEY_QUERY_ROUTER}"
TCK="${DATA_PLANE_KEY_TENANT_CONTROL}"
LEGACY="${INTERNAL_SERVICE_TOKEN}"

negative_arms() {
  local good refused
  good="$(mount_json neg t1 postgres)"
  refused="$(mount_json refused t1 m243_refused)"
  expect 401 "unsigned /v1/query" "" /v1/query "$(envelope t1 "${good}" "${QUERY}")"
  expect 403 "shared token on /v1/query" "${LEGACY}" /v1/query "$(envelope t1 "${refused}" "${QUERY}")"
  expect 403 "tenant-control key on /v1/query" "${TCK}" /v1/query "$(envelope t1 "${refused}" "${QUERY}")"
  expect 403 "query-router service_role on /v1/admin/raw" "${QR}" /v1/admin/raw "$(envelope t1 "${good}" "${RAW}")"
  expect 403 "query-router service_role on /v1/admin/migrate" "${QR}" /v1/admin/migrate \
    "$(envelope t1 "${refused}" "$(migrate_tail m243_forged)")"
  expect 403 "identity tenant t2 on a t1 mount" "${QR}" /v1/query "$(envelope t2 "${refused}" "${QUERY}")"
  expect 403 "inline_dsn on /v1/admin/raw (tenant-control)" "${TCK}" /v1/admin/raw \
    "$(envelope t1 "${refused}" "${RAW}")"
  sleep 1
  [ "$(dials_by m243_refused)" = 0 ] || fail "a refused call reached postgres"
  has_table m243_forged && fail "a refused migrate created its table"
  pass "postgres logged 0 connects as m243_refused; m243_forged not created"
}

positive_arms() {
  local good control
  good="$(mount_json pos t1 postgres)"
  expect 200 "tenant-control migrate with an inline DSN" "${TCK}" /v1/admin/migrate \
    "$(envelope t1 "${good}" "$(migrate_tail m243_probe)")"
  has_table m243_probe || fail "the allowed migrate created no table"
  expect 200 "query-router /v1/query with an inline DSN" "${QR}" /v1/query \
    "$(envelope t1 "${good}" "${QUERY}")"
  control="$(mount_json control t1 m243_control)"
  call "${QR}" /v1/query "$(envelope t1 "${control}" "${QUERY}")" >/dev/null
  sleep 1
  [ "$(dials_by m243_control)" -ge 1 ] || fail "dial control: postgres logged no connect"
  pass "dial control: postgres logs an allowed class's connect (the 0 above counts)"
}

# shellcheck source=../lib/lib-m243-relay.sh
. "${ROOT}/scripts/lib/lib-m243-relay.sh"

step "build scratch images and boot postgres, the data plane (enforce) and tenant-control"
build_images || fail "scratch image build failed"
boot_postgres
boot_data_plane
pass "data plane up under DATA_PLANE_CALLER_POLICY=${DATA_PLANE_CALLER_POLICY}, SERVICE_TOKEN_MODE=${SERVICE_TOKEN_MODE}"

step "403/401: forged identities and wrong callers are refused before any dial"
negative_arms

step "200: each caller's own routes serve, inline DSNs where the table allows"
positive_arms

# The service-token arm under each policy (devil D1-P1); tenant-control is already up
# under enforce.
relay_policy_arms() {
  local got
  got="$(relay_token m243_relay_token)"
  if [ "${got}" != 401 ] || ! grep -q 'DATA_PLANE_CALLER_POLICY=enforce' "${BODY}"; then
    fail "enforce: service-token relay want 401 naming the policy, got ${got} — $(head -c 200 "${BODY}")"
  fi
  ! has_table m243_relay_token || fail "a refused service-token relay created its table"
  pass "enforce: the relay refuses the service token (401 naming the policy, no table)"
  boot_tenant_control shadow || fail "tenant-control did not start under shadow"
  got="$(relay_token m243_relay_shadow)"
  [ "${got}" = 200 ] && has_table m243_relay_shadow || fail "shadow: service-token relay want 200 + table, got ${got}"
  got="$(docker logs "${TCC}" 2>&1 | grep -c 'would_deny' || true)"
  [ "${got}" = 1 ] || fail "shadow: want exactly 1 would_deny line, got ${got}"
  pass "shadow: the service token still relays (200) with one would_deny line"
  tc_start enforced
  got="$(timeout 60 docker wait "${TCC}" || echo hung)"
  if [ "${got}" = 0 ] || [ "${got}" = hung ] || ! docker logs "${TCC}" 2>&1 | grep -q 'want off, shadow or enforce'; then
    fail "DATA_PLANE_CALLER_POLICY=enforced did not refuse boot (exit ${got})"
  fi
  pass "DATA_PLANE_CALLER_POLICY=enforced: tenant-control refuses to start (exit ${got})"
}

step "200: the Kong admin relay through tenant-control; its service-token arm per policy"
if boot_tenant_control enforce; then
  relay_arms
  relay_policy_arms
else
  printf '  SKIP Kong relay arm: scratch tenant-control did not start (TestAdminRelaySignsTheDataPlaneHopWithItsOwnKey covers the signing)\n'
fi

printf '\033[32mm243 live arms passed\033[0m\n'
