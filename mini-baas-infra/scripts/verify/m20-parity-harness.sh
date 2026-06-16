#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m20-parity-harness.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M20 — the parity gate (G10) self-test. Offline structural checks always run;
# --live exercises the harness end-to-end (record → compare(pass) → tamper →
# compare(fail) → restore) against the running Rust data-plane, proving the gate
# itself works. The gate that guards every future cutover must itself be gated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
PARITY="${BAAS_DIR}/scripts/verify/parity.sh"
PARITY_DIR="${BAAS_DIR}/scripts/verify/parity"
MAKEFILE="${BAAS_DIR}/Makefile"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M20] FAIL: $*"; exit 1; }
step()  { cyan "[M20] ${*}"; }
pass()  { green "[M20] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "structural: parity harness present + sound"
[[ -f "${PARITY}" ]]   || fail "missing ${PARITY}"
[[ -x "${PARITY}" ]]   || fail "${PARITY} is not executable"
bash -n "${PARITY}"    || fail "${PARITY} has a syntax error"
for mode in '"record"' '"diff"' '"contract"'; do
  grep -q "MODE=${mode}" "${PARITY}" || grep -q "MODE=${mode//\"/}" "${PARITY}" || fail "harness missing mode ${mode}"
done
grep -q 'verdict' "${PARITY}" || fail "harness does not emit a verdict"
pass "parity.sh is executable, parses, and supports record/diff/contract + verdict"

step "structural: Makefile parity target wires the generic gate"
grep -qE '^parity:.*ROUTES=' "${MAKEFILE}" || fail "make parity help lost its OLD/NEW/ROUTES contract"
grep -q 'scripts/verify/parity.sh' "${MAKEFILE}" || fail "make parity does not invoke parity.sh"
grep -qE '^parity-suite:' "${MAKEFILE}" || fail "legacy full-suite probe should remain as parity-suite"
pass "make parity → parity.sh (OLD=/NEW=/ROUTES=/RECORD=); parity-suite preserved"

step "structural: shipped route-set + docs"
[[ -f "${PARITY_DIR}/README.md" ]] || fail "missing route-set authoring README"
default_set="${PARITY_DIR}/data-plane-contract.routes.json"
[[ -f "${default_set}" ]] || fail "missing default route-set ${default_set}"
command -v jq >/dev/null 2>&1 || fail "jq required"
jq -e '.requests | length >= 1' "${default_set}" >/dev/null || fail "default route-set has no requests"
jq -e '.normalize' "${default_set}" >/dev/null || fail "default route-set has no normalize program"
pass "default route-set is valid and documented"

if [[ ${LIVE} -eq 0 ]]; then
  green "[M20] structural checks green — run with --live to exercise the round-trip"
  exit 0
fi

# ----- live round-trip: record → pass → tamper → fail → clean -----
command -v curl >/dev/null 2>&1 || fail "curl required for --live"
RUST_URL="${RUST_DATA_PLANE_URL:-http://localhost:4011}"
if ! curl -sS -o /dev/null --max-time 5 "${RUST_URL}/v1/capabilities"; then
  red "[M20] --live: ${RUST_URL}/v1/capabilities unreachable — is the rust-data-plane up? (skipping live)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
rs="${work}/selftest.routes.json"
cp "${default_set}" "${rs}"

step "live: record golden from ${RUST_URL}"
NEW="${RUST_URL}" ROUTES="${rs}" bash "${PARITY}" --record >/dev/null || fail "record failed"
[[ -f "${work}/selftest.golden.json" ]] || fail "record did not produce a golden next to the route-set"

step "live: contract compare should PASS"
if ! NEW="${RUST_URL}" ROUTES="${rs}" PARITY_VERDICT_DIR="${work}/.parity" bash "${PARITY}" >/dev/null; then
  fail "contract compare against a freshly recorded golden should pass"
fi
ls "${work}/.parity/"*.json >/dev/null 2>&1 || fail "compare did not emit a verdict file"
jq -e '.verdict == "pass"' "${work}/.parity/"*.json >/dev/null || fail "verdict json not pass"

step "live: tampered golden should FAIL (exit 1)"
jq '.capabilities.status = "503"' "${work}/selftest.golden.json" > "${work}/t.json" \
  && mv "${work}/t.json" "${work}/selftest.golden.json"
if NEW="${RUST_URL}" ROUTES="${rs}" PARITY_VERDICT_DIR="${work}/.parity" bash "${PARITY}" >/dev/null 2>&1; then
  fail "a tampered golden must make the gate fail"
fi
pass "round-trip verified: record → pass → tamper → fail"
green "[M20] parity harness fully verified (structural + live)"
