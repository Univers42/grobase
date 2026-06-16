#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    parity-probe.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/02 01:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/02 01:30:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate #2 (shadow parity) — runs the live BaaS verify suite twice:
#
#   Phase A: RUST_DATA_PLANE_FORWARD=0 (current default) — TS engines execute.
#   Phase B: RUST_DATA_PLANE_FORWARD=1 with all R2/R3/R7/R8 engines listed —
#            Rust data-plane-router executes via the RustDataPlaneProxy.
#
# Both phases must pass M1..M10 for parity to be considered demonstrated. If
# either phase fails, the script exits non-zero and prints which path broke.
#
# Designed to be safe to re-run: it always restores the query-router to the
# state it was in when the script started.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail()   { red   "[PARITY] FAIL: $*"; exit 1; }
step()   { cyan  "[PARITY] ${*}"; }
pass()   { green "[PARITY] PASS: ${*}"; }

# All engines the Rust data-plane-router currently implements (R2 + R3 + R7 + R8).
FORWARD_ENGINES_ALL="postgresql,mongodb,mysql,redis,http"

restart_with_env() {
  local forward="$1"
  local engines="$2"
  local product_mode="$3"
  step "restarting query-router and data-plane-router-rust (FORWARD=${forward}, MODE=${product_mode})"
  # Include every profile that the running stack uses — compose's dependency
  # resolution rejects partial profile sets when one service in the project
  # references a service that's hidden behind a profile we omitted.
  RUST_DATA_PLANE_FORWARD="${forward}" \
  RUST_DATA_PLANE_FORWARD_ENGINES="${engines}" \
  DATA_PLANE_ROUTER_PRODUCT_MODE="${product_mode}" \
  docker compose -f "${COMPOSE_FILE}" \
    --profile control-plane --profile adapter-plane --profile data-plane \
    --profile background --profile storage --profile rust-data-plane \
    up -d --force-recreate query-router data-plane-router-rust >/dev/null

  local tries=0
  until docker inspect mini-baas-query-router --format '{{.State.Health.Status}}' 2>/dev/null \
        | grep -q '^healthy$'; do
    tries=$((tries + 1))
    if [[ ${tries} -gt 30 ]]; then
      fail "query-router did not become healthy in 60s (FORWARD=${forward})"
    fi
    sleep 2
  done
  pass "query-router healthy"
}

run_verify_suite() {
  local label="$1"
  step "running BAAS_VERIFY_LIVE=1 baas-verify-all (${label})"
  local out_file
  out_file="$(mktemp -t parity-${label}.XXXXXX.log)"
  if WAF_HTTP_PORT=8880 WAF_HTTPS_PORT=8443 KONG_HTTPS_PORT=8443 \
     PROMETHEUS_PORT=9090 GRAFANA_PORT=3030 LOKI_PORT=3100 \
     BAAS_VERIFY_OBSERVABILITY=1 BAAS_VERIFY_LIVE=1 \
     make baas-verify-all >"${out_file}" 2>&1; then
    pass "${label} suite green ($(grep -c 'OK —' "${out_file}") milestones)"
    rm -f "${out_file}"
    return 0
  else
    red "[PARITY] FAIL: ${label} suite broke — see ${out_file}"
    tail -30 "${out_file}" >&2
    return 1
  fi
}

RESTORE_FORWARD="${RUST_DATA_PLANE_FORWARD:-0}"
RESTORE_ENGINES="${RUST_DATA_PLANE_FORWARD_ENGINES:-postgresql,mongodb}"
RESTORE_MODE="${DATA_PLANE_ROUTER_PRODUCT_MODE:-shadow}"
PARITY_PROVEN=0
# On failure: restore to the env the script inherited so the operator is back
# where they started. On success: leave the stack in Rust-forwarding mode —
# that's the whole point of the probe.
trap 'rc=$?
      if [[ ${rc} -ne 0 || ${PARITY_PROVEN} -eq 0 ]]; then
        yellow "[PARITY] non-clean exit; restoring services to FORWARD=${RESTORE_FORWARD} MODE=${RESTORE_MODE}"
        restart_with_env "${RESTORE_FORWARD}" "${RESTORE_ENGINES}" "${RESTORE_MODE}" || true
      else
        yellow "[PARITY] parity proven; leaving services in Rust-forward mode"
      fi' EXIT

step "Phase A — TypeScript engines serve everything"
restart_with_env "0" "" "shadow"
if ! run_verify_suite "phaseA-ts"; then
  fail "TypeScript baseline is broken — parity probe cannot proceed"
fi

step "Phase B — Rust data-plane-router serves all R2/R3/R7/R8 engines"
restart_with_env "1" "${FORWARD_ENGINES_ALL}" "enabled"
if ! run_verify_suite "phaseB-rust"; then
  fail "Rust forwarding broke the live verify suite — parity NOT proven"
fi

PARITY_PROVEN=1
green "[PARITY] both paths pass M1..M10 — gate #2 (shadow parity) demonstrated"
green "[PARITY] safe to flip RUST_DATA_PLANE_FORWARD=1 as the default and delete TS engines"
