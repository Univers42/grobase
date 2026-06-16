#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    parity.sh                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# G10 — reusable layer-swap parity gate.
#
# "Prove plane B matches plane A for route set R, and emit a verdict."
#
# This is the generic successor to parity-probe.sh (which was the one-shot
# TS-vs-Rust full-suite probe, now historical). It is DATA-DRIVEN: the request
# battery lives in a declarative route-set file, not in the script, so any
# future plane promotion reuses the same gate by authoring a route-set.
#
#   make parity NEW=http://localhost:8000 ROUTES=contract-surface --record
#       capture a golden contract snapshot from the live plane.
#
#   make parity NEW=http://localhost:8000 ROUTES=contract-surface
#       contract mode — assert the live plane still matches its golden
#       (a regression gate for a single-plane world, post-cutover).
#
#   make parity OLD=http://localhost:8001 NEW=http://localhost:8000 ROUTES=…
#       diff mode — assert two reachable planes return the same contract.
#
# A route-set file (scripts/verify/parity/<name>.routes.json):
#   {
#     "name": "...", "description": "...",
#     "normalize": "<jq program applied to every response body>",
#     "requests": [
#       { "name": "...", "method": "GET", "path": "/query/v1/engines",
#         "headers": {"X-Service-Token": "${INTERNAL_SERVICE_TOKEN}"},
#         "body": null, "normalize": "<optional per-request jq override>" }
#     ]
#   }
# ${VAR} placeholders in path/headers/body are expanded from the environment,
# so secrets are never written into the route-set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_DIR="${SCRIPT_DIR}/parity"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
VERDICT_DIR="${PARITY_VERDICT_DIR:-${REPO_ROOT}/apps/baas/mini-baas-infra/.parity}"

cyan()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
fail()   { red   "[PARITY] FAIL: $*" >&2; exit 1; }
step()   { cyan  "[PARITY] ${*}"; }
pass()   { green "[PARITY] PASS: ${*}"; }

command -v jq   >/dev/null 2>&1 || fail "jq is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

OLD="${OLD:-}"
NEW="${NEW:-}"
ROUTES="${ROUTES:-data-plane-contract}"
RECORD=0
for arg in "$@"; do [[ "${arg}" == "--record" ]] && RECORD=1; done

# Resolve the route-set: a bare name maps into scripts/verify/parity/, an
# explicit path is honoured verbatim.
if [[ -f "${ROUTES}" ]]; then
  ROUTES_FILE="${ROUTES}"
  ROUTES_NAME="$(basename "${ROUTES}" .routes.json)"
  GOLDEN_DIR="$(dirname "${ROUTES}")"
else
  ROUTES_FILE="${ROUTES_DIR}/${ROUTES}.routes.json"
  ROUTES_NAME="${ROUTES}"
  GOLDEN_DIR="${ROUTES_DIR}"
fi
[[ -f "${ROUTES_FILE}" ]] || fail "route-set not found: ${ROUTES_FILE}"
jq -e . "${ROUTES_FILE}" >/dev/null 2>&1 || fail "route-set is not valid JSON: ${ROUTES_FILE}"

GOLDEN_FILE="${GOLDEN_DIR}/${ROUTES_NAME}.golden.json"

# Decide the mode from what the operator supplied.
if [[ ${RECORD} -eq 1 ]]; then
  MODE="record";   [[ -n "${NEW}" ]] || fail "--record needs NEW=<base-url>"
elif [[ -n "${OLD}" && -n "${NEW}" ]]; then
  MODE="diff"
elif [[ -n "${NEW}" ]]; then
  MODE="contract"
  [[ -f "${GOLDEN_FILE}" ]] || fail "contract mode needs a golden (${GOLDEN_FILE}); run with --record first"
else
  fail "supply NEW=<base-url> (contract mode) or OLD= and NEW= (diff mode)"
fi

GLOBAL_NORM="$(jq -r '.normalize // "."' "${ROUTES_FILE}")"
REQ_COUNT="$(jq '.requests | length' "${ROUTES_FILE}")"
[[ "${REQ_COUNT}" -gt 0 ]] || fail "route-set has no requests"

# probe: <base-url> <index> -> echoes "<status>\n<normalized-body>"; the body is
# parsed as JSON and run through the route-set's normalize program, falling back
# to the raw payload when the response is not JSON.
probe() {
  local base="$1" idx="$2" tmp method path body norm headers status raw
  method="$(jq -r ".requests[${idx}].method // \"GET\"" "${ROUTES_FILE}")"
  path="$(jq -r ".requests[${idx}].path" "${ROUTES_FILE}" | envsubst)"
  norm="$(jq -r ".requests[${idx}].normalize // empty" "${ROUTES_FILE}")"
  [[ -n "${norm}" ]] || norm="${GLOBAL_NORM}"

  local -a curl_args=(-sS -o - -w $'\n%{http_code}' -X "${method}" --max-time 20)
  # Headers: each "k": "v" pair becomes -H "k: v" after env expansion.
  while IFS=$'\t' read -r k v; do
    [[ -z "${k}" ]] && continue
    curl_args+=(-H "${k}: $(printf '%s' "${v}" | envsubst)")
  done < <(jq -r ".requests[${idx}].headers // {} | to_entries[] | [.key, .value] | @tsv" "${ROUTES_FILE}")

  body="$(jq -c ".requests[${idx}].body // empty" "${ROUTES_FILE}")"
  if [[ -n "${body}" ]]; then
    curl_args+=(--data-binary "$(printf '%s' "${body}" | envsubst)")
  fi

  raw="$(curl "${curl_args[@]}" "${base}${path}" 2>/dev/null || true)"
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  [[ "${status}" =~ ^[0-9]{3}$ ]] || status="000"

  printf '%s\n' "${status}"
  # Normalize the body; if it isn't JSON, emit it verbatim so raw payloads
  # (e.g. plain "ok" health bodies) still compare meaningfully.
  if printf '%s' "${body}" | jq -e . >/dev/null 2>&1; then
    printf '%s' "${body}" | jq -S "${norm}" 2>/dev/null || printf '%s' "${body}"
  else
    printf '%s' "${body}"
  fi
}

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "${VERDICT_DIR}"
cases_json="$(mktemp)"; printf '[]' >"${cases_json}"
matched=0; mismatched=0

step "route-set '${ROUTES_NAME}' (${REQ_COUNT} requests) — mode=${MODE}"
[[ "${MODE}" == "diff" ]] && step "OLD=${OLD}  NEW=${NEW}"

# In record mode we collect golden side-by-side; otherwise we compare.
record_obj="$(mktemp)"; printf '{}' >"${record_obj}"

for (( i=0; i<REQ_COUNT; i++ )); do
  name="$(jq -r ".requests[${i}].name // \"req-${i}\"" "${ROUTES_FILE}")"
  method="$(jq -r ".requests[${i}].method // \"GET\"" "${ROUTES_FILE}")"
  path="$(jq -r ".requests[${i}].path" "${ROUTES_FILE}")"

  new_out="$(probe "${NEW}" "${i}")"
  new_status="${new_out%%$'\n'*}"; new_body="${new_out#*$'\n'}"

  case "${MODE}" in
    record)
      # Store the normalized body verbatim as a JSON string so capture and
      # compare stay symmetric regardless of JSON-vs-raw payloads.
      b="$(printf '%s' "${new_body}" | jq -R -s .)"
      jq --arg n "${name}" --arg s "${new_status}" --argjson b "${b}" \
        '.[$n] = {status:$s, body:$b}' "${record_obj}" >"${record_obj}.x" && mv "${record_obj}.x" "${record_obj}"
      cyan "  • ${name} (${method} ${path}) → ${new_status} [recorded]"
      ;;
    diff)
      old_out="$(probe "${OLD}" "${i}")"
      old_status="${old_out%%$'\n'*}"; old_body="${old_out#*$'\n'}"
      sm=$([[ "${old_status}" == "${new_status}" ]] && echo true || echo false)
      bm=$([[ "${old_body}" == "${new_body}" ]] && echo true || echo false)
      ;;
    contract)
      old_status="$(jq -r --arg n "${name}" '.[$n].status // "000"' "${GOLDEN_FILE}")"
      # Golden stores the normalized body as a JSON string; new_body is already
      # normalized text — compare text to text for a symmetric structural check.
      old_body="$(jq -r --arg n "${name}" '.[$n].body // ""' "${GOLDEN_FILE}")"
      sm=$([[ "${old_status}" == "${new_status}" ]] && echo true || echo false)
      bm=$([[ "${old_body}" == "${new_body}" ]] && echo true || echo false)
      ;;
  esac

  if [[ "${MODE}" != "record" ]]; then
    if [[ "${sm}" == "true" && "${bm}" == "true" ]]; then
      matched=$((matched+1)); green "  ✓ ${name} (${method} ${path}) → ${new_status}"
    else
      mismatched=$((mismatched+1))
      red "  ✗ ${name} (${method} ${path}): status ${old_status}->${new_status} (match=${sm}), body match=${bm}"
    fi
    jq --arg n "${name}" --arg m "${method}" --arg p "${path}" \
      --arg os "${old_status}" --arg ns "${new_status}" \
      --argjson sm "${sm}" --argjson bm "${bm}" \
      '. += [{name:$n, method:$m, path:$p, old_status:$os, new_status:$ns, status_match:$sm, body_match:$bm, match:($sm and $bm)}]' \
      "${cases_json}" >"${cases_json}.x" && mv "${cases_json}.x" "${cases_json}"
  fi
done

if [[ "${MODE}" == "record" ]]; then
  jq -S . "${record_obj}" >"${GOLDEN_FILE}"
  rm -f "${record_obj}" "${cases_json}"
  pass "golden contract captured → ${GOLDEN_FILE} (${REQ_COUNT} requests)"
  exit 0
fi
rm -f "${record_obj}"

verdict=$([[ ${mismatched} -eq 0 ]] && echo pass || echo fail)
verdict_file="${VERDICT_DIR}/verdict-${ROUTES_NAME}-$(date -u +%Y%m%dT%H%M%SZ).json"
jq -n \
  --arg routes "${ROUTES_NAME}" --arg mode "${MODE}" --arg old "${OLD:-${GOLDEN_FILE}}" \
  --arg new "${NEW}" --arg ts "${ts}" --arg verdict "${verdict}" \
  --argjson total "${REQ_COUNT}" --argjson matched "${matched}" --argjson mismatched "${mismatched}" \
  --slurpfile cases "${cases_json}" \
  '{tool:"parity", routes:$routes, mode:$mode, old:$old, new:$new, generated_at:$ts,
    total:$total, matched:$matched, mismatched:$mismatched, verdict:$verdict, cases:$cases[0]}' \
  >"${verdict_file}"
rm -f "${cases_json}"

echo
step "verdict recorded → ${verdict_file}"
if [[ "${verdict}" == "pass" ]]; then
  pass "${matched}/${REQ_COUNT} requests parity-equal (${MODE} mode)"
else
  red  "[PARITY] FAIL: ${mismatched}/${REQ_COUNT} requests diverged (${MODE} mode)"
  exit 1
fi
