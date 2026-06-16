#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m33-lean-basic.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for the LEAN BASIC tier (Phase C) + the schema/DDL bypass (Phase D).
#
#   1. Footprint: PACKAGE=basic fits ≤512 MiB (the $5-VPS / Pi bar).
#   2. FULLY Node-free lifecycle through the Rust `/data/v1` front door — create
#      table → introspect → insert → read — with NO query-router / permission-
#      engine in the path (the Node services basic omits). The schema + DDL are
#      the Phase-D additions (`/data/v1/schema`, `/data/v1/schema/ddl`); there is
#      no psql/out-of-band step — the whole lifecycle is the public API.
#   3. Scope gate: a read-only key is DENIED a write AND a DDL (403), allowed a
#      read — the api-key authorization a Node-free tier depends on.
#
set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
fail(){ red "[M33] FAIL: $*"; exit 1; }
step(){ cyan "[M33] ${*}"; }
pass(){ green "[M33] PASS: ${*}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-live-tenant.sh"

RUST_PORT="$(docker port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
RUST="http://127.0.0.1:${RUST_PORT:-4011}"
TBL="lean_$(date +%s)"

bypass() { # $1 path  $2 key  $3 body  → echoes "<body> HTTP<code>"
  curl -s -w ' HTTP%{http_code}' -X POST "${RUST}/data/v1/$1" \
    -H "X-Baas-Api-Key: $2" -H 'Content-Type: application/json' -d "$3"
}

# ── 1. footprint ──────────────────────────────────────────────────────────
step "footprint: PACKAGE=basic must fit ≤512 MiB"
PROFILES="go-control-plane rust-data-plane" LABEL="basic" BAR_MB=512 \
  bash "${SCRIPT_DIR}/../bench/footprint.sh" >/tmp/m33-fp.txt 2>&1 \
  || { cat /tmp/m33-fp.txt; fail "basic tier exceeds its 512 MiB budget"; }
grep -E 'TOTAL|budget' /tmp/m33-fp.txt
pass "basic tier within the Pi-class budget"

# ── provision a probe tenant + read+write key + pg mount (Node-free Go) ─────
step "provisioning a probe tenant + key + mount (Node-free Go control plane)"
live_tenant_provision "basic-$(date +%s)" || fail "provision failed"
trap 'bypass schema/ddl "${LIVE_TENANT_API_KEY}" "{\"db_id\":\"${LIVE_TENANT_DB_ID}\",\"ddl\":{\"op\":\"drop_table\",\"table\":\"${TBL}\"}}" >/dev/null 2>&1 || true; live_tenant_cleanup' EXIT
DBID="${LIVE_TENANT_DB_ID}"
WKEY="${LIVE_TENANT_API_KEY}"   # read+write

# ── 2. Node-free lifecycle: create table → introspect → insert → read ───────
step "create table via /data/v1/schema/ddl (write scope, Node-free DDL)"
DDL="$(bypass schema/ddl "${WKEY}" "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"create_table\",\"table\":\"${TBL}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"name\",\"normalized_type\":\"text\",\"nullable\":true}],\"primary_key\":[\"id\"]}}")"
echo "${DDL}" | grep -q 'HTTP20[0-1]' || fail "create_table via /data/v1/schema/ddl failed: ${DDL}"

step "introspect via /data/v1/schema (read scope) — the new table is visible"
SCH="$(bypass schema "${WKEY}" "{\"db_id\":\"${DBID}\"}")"
echo "${SCH}" | grep -q "${TBL}" || fail "introspect did not list the new table ${TBL}: ${SCH:0:200}"

step "insert + read via /data/v1/query (no query-router in the path)"
INS="$(bypass query "${WKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"${TBL}\",\"data\":{\"id\":\"p1\",\"name\":\"lean-hello\"}}}")"
echo "${INS}" | grep -q 'HTTP20[01]' || fail "insert via /data/v1 failed: ${INS}"
LST="$(bypass query "${WKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"list\",\"resource\":\"${TBL}\",\"limit\":10}}")"
echo "${LST}" | grep -q 'lean-hello' || fail "read-back via /data/v1 missing the row: ${LST}"
pass "full create→introspect→insert→read lifecycle clean through the Node-free bypass"

# ── 3. scope gate: read-only key denied write AND ddl, allowed read ─────────
step "scope gate: read-only key → write 403, ddl 403, read 200"
m33kb='{"name":"m33-readonly","scopes":["read"]}'
svc_auth POST "/v1/tenants/${LIVE_TENANT_SLUG}/keys" "${m33kb}"
code=$(curl -s -o /tmp/m33-rk.json -w '%{http_code}' -X POST \
  "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${LIVE_TENANT_SLUG}/keys" \
  "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
  -d "${m33kb}")
[[ "${code}" == "201" ]] || fail "read-only key mint failed (${code})"
RKEY="$(sed -n 's/.*"key":"\([^"]*\)".*/\1/p' /tmp/m33-rk.json | head -1)"
[[ "${RKEY}" == mbk_* ]] || fail "read-only key has unexpected shape"

W="$(bypass query "${RKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"${TBL}\",\"data\":{\"id\":\"p2\",\"name\":\"nope\"}}}")"
echo "${W}" | grep -q 'HTTP403' || fail "read-only key was NOT denied the write: ${W}"
D="$(bypass schema/ddl "${RKEY}" "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"drop_table\",\"table\":\"${TBL}\"}}")"
echo "${D}" | grep -q 'HTTP403' || fail "read-only key was NOT denied the DDL: ${D}"
R="$(bypass query "${RKEY}" "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"list\",\"resource\":\"${TBL}\",\"limit\":1}}")"
echo "${R}" | grep -q 'HTTP200' || fail "read-only key was denied a READ: ${R}"
pass "scope gate enforced — write 403, ddl 403, read 200"

green "[M33] ALL GATES GREEN — basic tier is Pi-class (≤512 MiB), Node-free end-to-end (DDL+schema+CRUD), scope-enforced"
