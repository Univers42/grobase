#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    run-gate-battery.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# run-gate-battery — run a given list of verify/m<NN>-*.sh gate scripts IN
# ORDER, logging PASS/FAIL per gate, and exiting NON-ZERO on the FIRST failure
# (fail-fast). Both the CI `gates-full` job and a human use the same entrypoint,
# so "what CI runs" == "what I can reproduce locally".
#
# Each enterprise / data-plane gate (m103..m122) is SELF-CONTAINED: it builds
# the tenant-control / data-plane-router images FROM CURRENT source, boots a
# scratch postgres/redis on a private docker network suffixed with $$, and has
# an EXIT-trap that force-removes EVERYTHING. They never touch a mini-baas-*
# resource and need NO live stack — exactly the cloud-gates contract. That is
# why this battery can run them back-to-back on a clean runner with nothing up.
#
# USAGE
#   # explicit list (names with or without the .sh suffix, or full paths):
#   bash scripts/verify/run-gate-battery.sh m101 m120 m122
#   bash scripts/verify/run-gate-battery.sh m101-quota-realtenant.sh
#
#   # the full enterprise + data-plane battery (the nightly set):
#   bash scripts/verify/run-gate-battery.sh --enterprise
#
#   # the curated fast per-PR subset:
#   bash scripts/verify/run-gate-battery.sh --fast
#
# A name like "m103" resolves to the single scripts/verify/m103-*.sh script.
# Ambiguous prefixes (more than one match) are a hard error — never guess.
#
# Each gate's own stdout/stderr is teed to LOG_DIR/<gate>.log (default
# ./artifacts/gate-battery/), so CI can upload per-gate logs as artifacts even
# when an earlier gate already failed the run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colors (no-op when not a TTY / FORCE_COLORS=0) ─────────────────────────────
if [ -t 1 ] && [ "${FORCE_COLORS:-1}" != "0" ]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;36m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''
fi
green() { printf '%s%s%s\n' "$C_G" "$*" "$C_0"; }
red()   { printf '%s%s%s\n' "$C_R" "$*" "$C_0"; }
yellow(){ printf '%s%s%s\n' "$C_Y" "$*" "$C_0"; }
blue()  { printf '%s%s%s\n' "$C_B" "$*" "$C_0"; }

# ── curated sets (single source of truth — keep CI in sync with these) ─────────
# Full enterprise + data-plane battery, in dependency-free order. m102 is NOT
# here: it needs a LIVE Kong gateway and is already gated in CI's per-PR
# integration-tests job, not in this self-contained battery.
ENTERPRISE_BATTERY=(
  m101-quota-realtenant  # quota-truth (real-tenant billing gate; supersedes the vacuous m80)
  m103  # orgs / RBAC
  m104  # tamper-evident audit chain
  m105  # hard-erase (GDPR right-to-be-forgotten)
  m106  # IP allowlist
  m107  # passkeys / WebAuthn
  m108  # SOC2-lite evidence (audit-ready, NOT certified)
  m109  # tenant data export
  m110  # SSO via OIDC
  m111  # SCIM user provisioning
  m112  # trust-center / legal templates
  m120  # data-plane spend-cap + abuse-suspend enforcement
  m121  # vault credential-ref enforcement
  m122  # read-replica routing
  m135  # fine-grained ABAC: column masking applied (the highest-value mask proof)
  m136  # fine-grained ABAC: stored conditions evaluate (ip_cidr/time_window; deny>allow; flag-OFF parity)
  m137  # fine-grained ABAC: per-table + per-instance granularity (table/instance overrides)
  m139  # fine-grained ABAC: api-key callers under the PDP (same mask as JWT; flag-OFF byte-parity)
  m141  # compliance posture honest+provable (audit-chain spine + GDPR routes + no dangling evidence)
  m143  # framework cross-walks complete+honest (SOC2 CC1-9 + GDPR articles + all 93 ISO Annex A controls)
  # m144 (trust-page parity) and m145 (cost-model artifact lockstep) are intentionally
  # NOT in the CI battery: they validate the marketing site (site/ — gitignored in this
  # repo) and the measured bench artifacts (mini-baas-infra/artifacts/ — produced by
  # make bench-*, not committed). Neither is present in a fresh checkout, so they only
  # run locally / at release time: bash scripts/verify/m144-*.sh · m145-*.sh
)

# Cheapest high-signal subset for the per-PR path. m102 (live gateway) is run
# separately in integration-tests; here we add the two self-contained gates
# that catch the highest-blast-radius regressions cheaply: billing/quota truth
# and the data-plane spend/suspend enforcement that protects the cloud edition.
FAST_SUBSET=(
  m101-quota-realtenant  # quota-truth — billing correctness; a silent break loses real money
  m120  # spend/suspend enforcement on the request path
)

# ── resolve a gate token (m103 | m103-orgs-rbac | m103-orgs-rbac.sh | path) ────
resolve_gate() {
  local token="$1" path matches
  # already a path that exists?
  if [ -f "$token" ]; then printf '%s\n' "$token"; return 0; fi
  # bare name with .sh under verify/?
  if [ -f "${SCRIPT_DIR}/${token}" ]; then printf '%s\n' "${SCRIPT_DIR}/${token}"; return 0; fi
  if [ -f "${SCRIPT_DIR}/${token}.sh" ]; then printf '%s\n' "${SCRIPT_DIR}/${token}.sh"; return 0; fi
  # prefix like "m103" → exactly one m103-*.sh
  matches=$(ls "${SCRIPT_DIR}/${token}"-*.sh 2>/dev/null || true)
  if [ -z "$matches" ]; then
    red "[battery] no gate script matches '${token}' under ${SCRIPT_DIR}/" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$matches" | wc -l)" -ne 1 ]; then
    red "[battery] ambiguous gate token '${token}' — matches:" >&2
    printf '  %s\n' $matches >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# ── parse args into the gate list ──────────────────────────────────────────────
GATES=()
case "${1:-}" in
  --enterprise) GATES=("${ENTERPRISE_BATTERY[@]}"); shift ;;
  --fast)       GATES=("${FAST_SUBSET[@]}");        shift ;;
  -h|--help|"")
    sed -n '14,40p' "${BASH_SOURCE[0]}"
    exit 0 ;;
esac
# any remaining positional args are appended (so `--fast m122` works too)
if [ "$#" -gt 0 ]; then GATES+=("$@"); fi

if [ "${#GATES[@]}" -eq 0 ]; then
  red "[battery] no gates to run"; exit 2
fi

LOG_DIR="${GATE_BATTERY_LOG_DIR:-${SCRIPT_DIR}/../../artifacts/gate-battery}"
mkdir -p "$LOG_DIR"

# resolve all tokens UP FRONT so a typo fails before we burn minutes building.
declare -a SCRIPTS=() NAMES=()
for token in "${GATES[@]}"; do
  if ! path=$(resolve_gate "$token"); then exit 2; fi
  SCRIPTS+=("$path")
  NAMES+=("$(basename "$path" .sh)")
done

blue "═══ gate battery: ${#SCRIPTS[@]} gate(s) — ${NAMES[*]} ═══"
blue "    logs → ${LOG_DIR}"

# ── run, fail-fast, per-gate log + timing ──────────────────────────────────────
declare -a RESULTS=()
overall_rc=0
run_start=$(date +%s)

for i in "${!SCRIPTS[@]}"; do
  path="${SCRIPTS[$i]}"
  name="${NAMES[$i]}"
  log="${LOG_DIR}/${name}.log"
  blue "─── [$((i + 1))/${#SCRIPTS[@]}] ${name} ───"
  g_start=$(date +%s)
  # tee so the gate's output is visible live AND captured per-gate for artifacts.
  if FORCE_COLORS=0 bash "$path" 2>&1 | tee "$log"; then
    rc=0
  else
    rc=${PIPESTATUS[0]}
  fi
  g_dur=$(( $(date +%s) - g_start ))
  if [ "$rc" -eq 0 ]; then
    green "    PASS ${name} (${g_dur}s)"
    RESULTS+=("PASS  ${name}  ${g_dur}s")
  else
    red "    FAIL ${name} (rc=${rc}, ${g_dur}s) — log: ${log}"
    RESULTS+=("FAIL  ${name}  ${g_dur}s  rc=${rc}")
    overall_rc=$rc
    if [ "${BATTERY_KEEP_GOING:-0}" != "1" ]; then
      # fail-fast (default): record the remaining gates as SKIPPED and stop.
      # Set BATTERY_KEEP_GOING=1 to run every gate and report all failures (CI uses
      # this so one run surfaces every environment issue instead of one-at-a-time).
      for j in $(seq $((i + 1)) $(( ${#SCRIPTS[@]} - 1 )) ); do
        RESULTS+=("SKIP  ${NAMES[$j]}  (not run — earlier gate failed)")
      done
      break
    fi
  fi
done

run_dur=$(( $(date +%s) - run_start ))

# ── summary ────────────────────────────────────────────────────────────────────
echo
blue "═══ gate battery summary (${run_dur}s total) ═══"
for line in "${RESULTS[@]}"; do
  case "$line" in
    PASS*) green " $line" ;;
    FAIL*) red   " $line" ;;
    *)     yellow " $line" ;;
  esac
done

if [ "$overall_rc" -eq 0 ]; then
  green "═══ ALL ${#SCRIPTS[@]} GATES PASSED ═══"
else
  red "═══ BATTERY FAILED (first failing gate above; exit ${overall_rc}) ═══"
fi
exit "$overall_rc"
