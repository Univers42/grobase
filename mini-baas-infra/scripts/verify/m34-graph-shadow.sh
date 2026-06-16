#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m34-graph-shadow.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate M34 — GRAPH SHADOW PARITY (Phase D).
#
# Proves the Rust-native `/data/v1/graph` (a faithful port of the query-router's
# GraphService) returns a node-link subgraph IDENTICAL to the legacy
# `/query/v1/graph`, on a controlled fixture that exercises the real BFS:
# multi-hop traversal, the `from`/`to` edges mount, and node fetch. Built + read
# entirely through the public API (Node-free DDL + CRUD), then both front doors
# are diffed canonically (nodes/edges sorted by id).
set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
fail(){ red "[M34] FAIL: $*"; exit 1; }
step(){ cyan "[M34] ${*}"; }
pass(){ green "[M34] PASS: ${*}"; }

command -v jq >/dev/null 2>&1 || fail "jq required"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-live-tenant.sh"

RUST_PORT="$(docker port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
RUST="http://127.0.0.1:${RUST_PORT:-4011}"

live_tenant_provision "graph-$(date +%s)" || fail "provision failed"
DBID="${LIVE_TENANT_DB_ID}"; KEY="${LIVE_TENANT_API_KEY}"
# Unique fixture table names per run (the probe mount points at the shared
# platform postgres, so fixed names would collide across runs).
GN="gnode_$(date +%s)_$$"; GE="gedge_$(date +%s)_$$"

bypass() { curl -s -X POST "${RUST}/data/v1/$1" -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' -d "$2"; }
ddl_ok() { echo "$1" | grep -q '"status"' || fail "DDL failed: $1"; }
drop_t() { bypass schema/ddl "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"drop_table\",\"table\":\"$1\"}}" >/dev/null 2>&1 || true; }
trap 'drop_t "${GN}"; drop_t "${GE}"; live_tenant_cleanup' EXIT

# ── fixture: GN(id,name) + GE(id,"from","to","type") — reserved cols quoted ──
step "create node + edge tables via /data/v1/schema/ddl (reserved from/to/type)"
ddl_ok "$(bypass schema/ddl "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"create_table\",\"table\":\"${GN}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"name\",\"normalized_type\":\"text\",\"nullable\":true}],\"primary_key\":[\"id\"]}}")"
ddl_ok "$(bypass schema/ddl "{\"db_id\":\"${DBID}\",\"ddl\":{\"op\":\"create_table\",\"table\":\"${GE}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"from\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"to\",\"normalized_type\":\"text\",\"nullable\":false},{\"name\":\"type\",\"normalized_type\":\"text\",\"nullable\":true}],\"primary_key\":[\"id\"]}}")"

ins() { bypass query "{\"db_id\":\"${DBID}\",\"operation\":{\"op\":\"insert\",\"resource\":\"$1\",\"data\":$2}}" >/dev/null; }
step "seed a 3-node / 2-edge chain n1→n2→n3"
for n in n1 n2 n3; do ins "${GN}" "{\"id\":\"${n}\",\"name\":\"node ${n}\"}"; done
ins "${GE}" "{\"id\":\"e1\",\"from\":\"${DBID}:${GN}:n1\",\"to\":\"${DBID}:${GN}:n2\",\"type\":\"link\"}"
ins "${GE}" "{\"id\":\"e2\",\"from\":\"${DBID}:${GN}:n2\",\"to\":\"${DBID}:${GN}:n3\",\"type\":\"link\"}"

FOCUS="${DBID}:${GN}:n1"
BODY="{\"focus\":\"${FOCUS}\",\"depth\":2,\"edgesDbId\":\"${DBID}\",\"edgesTable\":\"${GE}\"}"

step "assemble the subgraph through BOTH front doors (depth 2)"
LEG="$(curl -s -X POST "${LIVE_KONG_URL}/query/v1/graph" -H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${KEY}" -H 'Content-Type: application/json' -d "${BODY}")"
NEW="$(bypass graph "${BODY}")"

nn="$(echo "${NEW}" | jq '.nodes|length')"; ne="$(echo "${NEW}" | jq '.edges|length')"
echo "  new: nodes=${nn} edges=${ne} guarantee=$(echo "${NEW}" | jq -r '.guarantee')"
[[ "${nn}" == "3" && "${ne}" == "2" ]] || fail "expected 3 nodes / 2 edges, got ${nn}/${ne}: ${NEW:0:300}"
pass "BFS reached all 3 nodes + 2 edges through the Rust port"

step "canonical diff: /data/v1/graph must equal /query/v1/graph"
canon(){ jq -cS '{focus,depth,guarantee,nodes:(.nodes|sort_by(.id)),edges:(.edges|sort_by(.id))}'; }
if diff <(echo "${LEG}" | canon) <(echo "${NEW}" | canon) >/dev/null 2>&1; then
  pass "row-for-row identical across both front doors"
else
  red "  legacy: $(echo "${LEG}" | canon | head -c 240)"
  red "  bypass: $(echo "${NEW}" | canon | head -c 240)"
  fail "graph divergence between /query/v1/graph and /data/v1/graph"
fi

green "[M34] ALL GATES GREEN — Rust /data/v1/graph is row-for-row identical to /query/v1/graph (cutover-ready)"
