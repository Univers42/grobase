# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    audit.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/audit.sh — Full project audit: local checks + SonarCloud report
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/audit.sh              # Run everything
#   ./scripts/audit.sh --fetch-only # Only fetch SonarCloud report
#   ./scripts/audit.sh --local-only # Only run local checks (no network)
#
# Requires: SONAR_TOKEN in .env (or environment)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Colours & Unicode ────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'
BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
PASS="✅"; FAIL="❌"; WARN="⚠️ "; INFO="ℹ️ "; LINE="─"; BOX_TL="┌"; BOX_TR="┐"
BOX_BL="└"; BOX_BR="┘"; BOX_H="─"; BOX_V="│"

# ── Config ───────────────────────────────────────────────────────────────────
SONAR_ORG="univers42"
SONAR_PROJECT="Univers42_realtime-agnostic"
SONAR_API="https://sonarcloud.io/api"
REPORT_DIR="reports"
JSON_REPORT="${REPORT_DIR}/sonarcloud-issues.json"
TXT_REPORT="${REPORT_DIR}/sonarcloud-issues.txt"
SUMMARY_FILE="${REPORT_DIR}/audit-summary.txt"

MODE="all"
[[ "${1:-}" == "--fetch-only" ]] && MODE="fetch"
[[ "${1:-}" == "--local-only" ]] && MODE="local"

mkdir -p "$REPORT_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────
hr()   { printf '%s' "$BOX_TL"; printf '%0.s─' $(seq 1 68); printf '%s\n' "$BOX_TR"; }
hr_b() { printf '%s' "$BOX_BL"; printf '%0.s─' $(seq 1 68); printf '%s\n' "$BOX_BR"; }
row()  { printf "${BOX_V} %-66s ${BOX_V}\n" "$1"; }

declare -A CHECK_STATUS=()
declare -A CHECK_DETAIL=()

record() {
    # record <name> <status: pass|fail|warn|skip> [detail]
    CHECK_STATUS["$1"]="$2"
    CHECK_DETAIL["$1"]="${3:-}"
}

run_check() {
    local name="$1"; shift
    printf "  ${CYN}▶${RST} %-40s " "$name"
    local out=""
    if out=$("$@" 2>&1); then
        printf "${GRN}${PASS} pass${RST}\n"
        record "$name" "pass" "$out"
        return 0
    else
        printf "${RED}${FAIL} fail${RST}\n"
        record "$name" "fail" "$out"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: LOCAL CHECKS
# ══════════════════════════════════════════════════════════════════════════════
LOCAL_PASSED=0; LOCAL_FAILED=0; LOCAL_WARNED=0

run_local_checks() {
    echo ""
    printf "${BLD}${CYN}  ╔══════════════════════════════════════════════════════╗${RST}\n"
    printf "${BLD}${CYN}  ║           LOCAL AUDIT CHECKS                        ║${RST}\n"
    printf "${BLD}${CYN}  ╚══════════════════════════════════════════════════════╝${RST}\n"
    echo ""

    # 1. cargo fmt
    if run_check "cargo fmt --check" cargo fmt --all -- --check; then
        LOCAL_PASSED=$((LOCAL_PASSED + 1))
    else
        LOCAL_FAILED=$((LOCAL_FAILED + 1))
    fi

    # 2. cargo clippy (strict)
    if run_check "cargo clippy -D warnings" cargo clippy --all-targets --all-features -- -D warnings; then
        LOCAL_PASSED=$((LOCAL_PASSED + 1))
    else
        LOCAL_FAILED=$((LOCAL_FAILED + 1))
    fi

    # 3. cargo test
    if run_check "cargo test --workspace" cargo test --workspace; then
        LOCAL_PASSED=$((LOCAL_PASSED + 1))
    else
        LOCAL_FAILED=$((LOCAL_FAILED + 1))
    fi

    # 4. cargo audit (supply-chain)
    if command -v cargo-audit &>/dev/null; then
        if run_check "cargo audit (CVE scan)" cargo audit; then
            LOCAL_PASSED=$((LOCAL_PASSED + 1))
        else
            LOCAL_WARNED=$((LOCAL_WARNED + 1))
        fi
    else
        printf "  ${YEL}${WARN}${RST} %-40s ${DIM}skipped (install: cargo install cargo-audit)${RST}\n" "cargo audit (CVE scan)"
        record "cargo audit (CVE scan)" "skip"
    fi

    # 5. cargo machete (unused deps)
    if command -v cargo-machete &>/dev/null; then
        if run_check "cargo machete (unused deps)" cargo machete; then
            LOCAL_PASSED=$((LOCAL_PASSED + 1))
        else
            LOCAL_WARNED=$((LOCAL_WARNED + 1))
        fi
    else
        printf "  ${YEL}${WARN}${RST} %-40s ${DIM}skipped (install: cargo install cargo-machete)${RST}\n" "cargo machete (unused deps)"
        record "cargo machete (unused deps)" "skip"
    fi

    # 6. Check for TODO/FIXME/HACK in source
    local todo_count
    todo_count=$(grep -rn --include='*.rs' 'TODO\|FIXME\|HACK\|XXX' crates/ 2>/dev/null | wc -l || true)
    if [[ "$todo_count" -eq 0 ]]; then
        printf "  ${CYN}▶${RST} %-40s ${GRN}${PASS} pass (0 found)${RST}\n" "TODO/FIXME markers"
        record "TODO/FIXME markers" "pass" "0 markers"
        LOCAL_PASSED=$((LOCAL_PASSED + 1))
    else
        printf "  ${CYN}▶${RST} %-40s ${YEL}${WARN} ${todo_count} markers${RST}\n" "TODO/FIXME markers"
        record "TODO/FIXME markers" "warn" "${todo_count} markers"
        LOCAL_WARNED=$((LOCAL_WARNED + 1))
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: SONARCLOUD FETCH
# ══════════════════════════════════════════════════════════════════════════════
SONAR_TOTAL=0; SONAR_BLOCKER=0; SONAR_CRITICAL=0; SONAR_MAJOR=0; SONAR_MINOR=0; SONAR_INFO=0

fetch_sonarcloud() {
    echo ""
    printf "${BLD}${CYN}  ╔══════════════════════════════════════════════════════╗${RST}\n"
    printf "${BLD}${CYN}  ║           SONARCLOUD REPORT                         ║${RST}\n"
    printf "${BLD}${CYN}  ╚══════════════════════════════════════════════════════╝${RST}\n"
    echo ""

    if [[ -z "${SONAR_TOKEN:-}" ]]; then
        printf "  ${RED}${FAIL} SONAR_TOKEN not set — skipping SonarCloud fetch${RST}\n"
        record "SonarCloud fetch" "skip" "no token"
        return 1
    fi

    printf "  ${CYN}▶${RST} Fetching issues from SonarCloud...\n"

    # Paginate: SonarCloud returns max 500 per page
    local page=1 total=0 fetched=0
    echo '{"issues":[]}' > "$JSON_REPORT"
    local tmpfile
    tmpfile=$(mktemp)

    while true; do
        curl -sf -u "${SONAR_TOKEN}:" \
            "${SONAR_API}/issues/search?componentKeys=${SONAR_PROJECT}&statuses=OPEN,CONFIRMED,REOPENED&ps=500&p=${page}" \
            -o "$tmpfile" || { printf "  ${RED}${FAIL} API call failed${RST}\n"; rm -f "$tmpfile"; return 1; }

        if [[ "$page" -eq 1 ]]; then
            total=$(python3 -c "import json; print(json.load(open('$tmpfile'))['total'])")
            cp "$tmpfile" "$JSON_REPORT"
        else
            # Merge issues arrays
            python3 -c "
import json
with open('$JSON_REPORT') as f: base = json.load(f)
with open('$tmpfile') as f: extra = json.load(f)
base['issues'].extend(extra.get('issues', []))
base['total'] = $total
with open('$JSON_REPORT', 'w') as f: json.dump(base, f, indent=2)
"
        fi

        local page_issues
        page_issues=$(python3 -c "import json; print(len(json.load(open('$tmpfile')).get('issues',[])))")
        fetched=$((fetched + page_issues))

        if [[ "$fetched" -ge "$total" ]] || [[ "$page_issues" -eq 0 ]]; then
            break
        fi
        page=$((page + 1))
    done
    rm -f "$tmpfile"

    SONAR_TOTAL=$total
    printf "  ${CYN}▶${RST} Total open issues: ${BLD}%d${RST}\n" "$SONAR_TOTAL"
    record "SonarCloud fetch" "pass" "${SONAR_TOTAL} issues"

    # Generate human-readable TXT report
    python3 -c "
import json, sys
with open('$JSON_REPORT') as f:
    data = json.load(f)

issues = data.get('issues', [])
total = len(issues)

severity_order = {'BLOCKER': 0, 'CRITICAL': 1, 'MAJOR': 2, 'MINOR': 3, 'INFO': 4}
issues.sort(key=lambda i: (severity_order.get(i.get('severity','INFO'), 5), i.get('component','')))

sev_icon = {'BLOCKER': '🔴', 'CRITICAL': '🟠', 'MAJOR': '🟡', 'MINOR': '🔵', 'INFO': '⚪'}
by_sev = {}
by_file = {}
for i in issues:
    s = i.get('severity', '?')
    by_sev[s] = by_sev.get(s, 0) + 1
    comp = i.get('component','?').replace('Univers42_realtime-agnostic:', '')
    by_file[comp] = by_file.get(comp, 0) + 1

with open('$TXT_REPORT', 'w') as out:
    out.write('=' * 70 + '\n')
    out.write('  SONARCLOUD ISSUE REPORT\n')
    out.write('  Project: $SONAR_PROJECT\n')
    out.write('=' * 70 + '\n\n')

    out.write(f'Total open issues: {total}\n\n')

    out.write('BY SEVERITY:\n')
    for s in ['BLOCKER','CRITICAL','MAJOR','MINOR','INFO']:
        n = by_sev.get(s, 0)
        icon = sev_icon.get(s, '?')
        out.write(f'  {icon} {s:10s}: {n}\n')
    out.write('\n')

    out.write('BY FILE:\n')
    for f, n in sorted(by_file.items(), key=lambda x: -x[1]):
        out.write(f'  {n:3d} │ {f}\n')
    out.write('\n')

    out.write('─' * 70 + '\n')
    out.write('DETAILED ISSUES:\n')
    out.write('─' * 70 + '\n\n')
    for i in issues:
        s = i.get('severity','?')
        t = i.get('type','?')
        comp = i.get('component','?').replace('Univers42_realtime-agnostic:', '')
        line = i.get('line','?')
        msg = i.get('message','?')
        rule = i.get('rule','?')
        icon = sev_icon.get(s, '?')
        out.write(f'{icon} [{s}] {t}\n')
        out.write(f'   File: {comp}:{line}\n')
        out.write(f'   Rule: {rule}\n')
        out.write(f'   Msg:  {msg}\n\n')

print(f'  Reports saved to:\n    JSON: $JSON_REPORT\n    TXT:  $TXT_REPORT')
" || printf "  ${RED}${FAIL} Failed to generate TXT report${RST}\n"

    # Extract severity counts for summary
    SONAR_BLOCKER=$(python3 -c "import json; d=json.load(open('$JSON_REPORT')); print(sum(1 for i in d.get('issues',[]) if i.get('severity')=='BLOCKER'))")
    SONAR_CRITICAL=$(python3 -c "import json; d=json.load(open('$JSON_REPORT')); print(sum(1 for i in d.get('issues',[]) if i.get('severity')=='CRITICAL'))")
    SONAR_MAJOR=$(python3 -c "import json; d=json.load(open('$JSON_REPORT')); print(sum(1 for i in d.get('issues',[]) if i.get('severity')=='MAJOR'))")
    SONAR_MINOR=$(python3 -c "import json; d=json.load(open('$JSON_REPORT')); print(sum(1 for i in d.get('issues',[]) if i.get('severity')=='MINOR'))")
    SONAR_INFO=$(python3 -c "import json; d=json.load(open('$JSON_REPORT')); print(sum(1 for i in d.get('issues',[]) if i.get('severity')=='INFO'))")
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo ""
    printf "${BLD}${CYN}"
    printf "  ╔══════════════════════════════════════════════════════════════════╗\n"
    printf "  ║                    AUDIT SUMMARY                               ║\n"
    printf "  ╚══════════════════════════════════════════════════════════════════╝\n"
    printf "${RST}"
    echo ""

    # ── Local checks table ───────────────────────────────────────────────
    printf "  ${BLD}LOCAL CHECKS${RST}\n"
    printf "  ┌────────────────────────────────────────┬──────────┐\n"
    printf "  │ %-38s │ %-8s │\n" "Check" "Status"
    printf "  ├────────────────────────────────────────┼──────────┤\n"
    for name in "cargo fmt --check" "cargo clippy -D warnings" "cargo test --workspace" "cargo audit (CVE scan)" "cargo machete (unused deps)" "TODO/FIXME markers"; do
        local st="${CHECK_STATUS[$name]:-skip}"
        local icon=""
        case "$st" in
            pass) icon="${GRN}${PASS} pass${RST}" ;;
            fail) icon="${RED}${FAIL} FAIL${RST}" ;;
            warn) icon="${YEL}${WARN} warn${RST}" ;;
            skip) icon="${DIM}⏭  skip${RST}" ;;
        esac
        printf "  │ %-38s │ ${icon}  │\n" "$name"
    done
    printf "  └────────────────────────────────────────┴──────────┘\n"
    printf "  ${GRN}Passed: ${LOCAL_PASSED}${RST}  ${RED}Failed: ${LOCAL_FAILED}${RST}  ${YEL}Warned: ${LOCAL_WARNED}${RST}\n"
    echo ""

    # ── SonarCloud table ─────────────────────────────────────────────────
    if [[ "$MODE" != "local" ]]; then
        printf "  ${BLD}SONARCLOUD ISSUES${RST}\n"
        printf "  ┌────────────────┬───────┐\n"
        printf "  │ %-14s │ %5s │\n" "Severity" "Count"
        printf "  ├────────────────┼───────┤\n"
        printf "  │ 🔴 BLOCKER     │ %5d │\n" "$SONAR_BLOCKER"
        printf "  │ 🟠 CRITICAL    │ %5d │\n" "$SONAR_CRITICAL"
        printf "  │ 🟡 MAJOR       │ %5d │\n" "$SONAR_MAJOR"
        printf "  │ 🔵 MINOR       │ %5d │\n" "$SONAR_MINOR"
        printf "  │ ⚪ INFO        │ %5d │\n" "$SONAR_INFO"
        printf "  ├────────────────┼───────┤\n"
        printf "  │ ${BLD}TOTAL${RST}          │ ${BLD}%5d${RST} │\n" "$SONAR_TOTAL"
        printf "  └────────────────┴───────┘\n"
        echo ""
        if [[ "$SONAR_TOTAL" -eq 0 ]]; then
            printf "  ${GRN}${PASS} SonarCloud: ZERO ISSUES — all clean!${RST}\n"
        else
            printf "  ${YEL}${WARN} SonarCloud: %d issue(s) remaining${RST}\n" "$SONAR_TOTAL"
            printf "  ${DIM}   See: ${TXT_REPORT}${RST}\n"
            printf "  ${DIM}   See: ${JSON_REPORT}${RST}\n"
        fi
    fi

    # ── Final verdict ────────────────────────────────────────────────────
    echo ""
    if [[ "$LOCAL_FAILED" -eq 0 ]] && [[ "$SONAR_TOTAL" -eq 0 ]]; then
        printf "  ${GRN}${BLD}══════════════════════════════════════════${RST}\n"
        printf "  ${GRN}${BLD}  ${PASS}  ALL CLEAR — 0 errors, 0 warnings   ${RST}\n"
        printf "  ${GRN}${BLD}══════════════════════════════════════════${RST}\n"
    elif [[ "$LOCAL_FAILED" -eq 0 ]]; then
        printf "  ${YEL}${BLD}══════════════════════════════════════════${RST}\n"
        printf "  ${YEL}${BLD}  ${WARN}  Local OK, SonarCloud has issues     ${RST}\n"
        printf "  ${YEL}${BLD}══════════════════════════════════════════${RST}\n"
    else
        printf "  ${RED}${BLD}══════════════════════════════════════════${RST}\n"
        printf "  ${RED}${BLD}  ${FAIL}  AUDIT FAILED — see details above    ${RST}\n"
        printf "  ${RED}${BLD}══════════════════════════════════════════${RST}\n"
    fi
    echo ""

    # Save summary to file (strip ANSI for the file version)
    {
        echo "AUDIT SUMMARY — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "================================================"
        echo ""
        echo "LOCAL CHECKS"
        echo "  Passed: ${LOCAL_PASSED}  Failed: ${LOCAL_FAILED}  Warned: ${LOCAL_WARNED}"
        for name in "cargo fmt --check" "cargo clippy -D warnings" "cargo test --workspace" "cargo audit (CVE scan)" "cargo machete (unused deps)" "TODO/FIXME markers"; do
            local st="${CHECK_STATUS[$name]:-skip}"
            printf "  %-40s %s\n" "$name" "$st"
        done
        echo ""
        if [[ "$MODE" != "local" ]]; then
            echo "SONARCLOUD"
            echo "  BLOCKER:  ${SONAR_BLOCKER}"
            echo "  CRITICAL: ${SONAR_CRITICAL}"
            echo "  MAJOR:    ${SONAR_MAJOR}"
            echo "  MINOR:    ${SONAR_MINOR}"
            echo "  INFO:     ${SONAR_INFO}"
            echo "  TOTAL:    ${SONAR_TOTAL}"
        fi
    } > "$SUMMARY_FILE"

    return "$LOCAL_FAILED"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
echo ""
printf "${BLD}${CYN}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
printf "${BLD}${CYN}  ┃  realtime-agnostic — Full Audit                                 ┃${RST}\n"
printf "${BLD}${CYN}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"

case "$MODE" in
    local)
        run_local_checks
        ;;
    fetch)
        fetch_sonarcloud
        ;;
    all)
        run_local_checks
        fetch_sonarcloud
        ;;
esac

print_summary
