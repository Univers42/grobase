#!/usr/bin/env bash
# **************************************************************************** #
#   m143-compliance-matrices.sh — the framework cross-walks are COMPLETE +    #
#                                 HONEST (audit-ready, not "certified")        #
#                                                                              #
#   Sibling of m141-compliance-posture (which proves the POSTURE: the audit    #
#   chain spine + GDPR routes + posture.json dangling-evidence). THIS gate     #
#   proves the per-framework MATRICES that an auditor / ISO body / Vanta /     #
#   Drata is handed are real, complete and non-vacuous. Pure doc/citation      #
#   gate — NO container boot (route reachability is m141's job).               #
#                                                                              #
#   NON-VACUOUS assertions (each has a concrete failing input):                #
#     (1) the whole pack exists + is non-empty (a missing file fails);         #
#     (2) the SOC 2 matrix walks CC1..CC9; the GDPR matrix cites >=15 articles;#
#     (3) the ISO 27001 SoA decides EVERY Annex A:2022 control —               #
#         A.5.1-37, A.6.1-8, A.7.1-14, A.8.1-34 (93). A missing control fails  #
#         (this is the headline completeness assertion — a blank SoA fails);   #
#     (4) NO placeholder (TODO/FIXME/bare TBD/lorem) in a non-template file    #
#         (the two customer-fill templates may carry [TBD]);                   #
#     (5) NO dangling citation — every backticked `mNN` resolves to a verify   #
#         script, every backticked `0NN_*.sql` resolves to a migration;        #
#     (6) posture.json <-> matrices consistency — every implemented control    #
#         that cites a gate is cross-walked in the pack (no orphan control).   #
#                                                                              #
#   Reads only the repo working tree; touches nothing; safe to run anywhere.   #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
PACK="${BAAS_DIR}/wiki/compliance"
POSTURE_JSON="${INFRA_DIR}/config/trust/posture.json"
MIGR_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M143] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M143] FAIL — $*"
  exit 1
}

SOA="${PACK}/iso27001-soa.md"
SOC2="${PACK}/soc2-tsc-matrix.md"
GDPR="${PACK}/gdpr-article-matrix.md"

# Files that must exist + be non-empty. The two TEMPLATE files (gdpr-ropa,
# dpia-template) are the ONLY ones allowed to carry [TBD] placeholders.
PACK_FILES=(
  README.md soc2-tsc-matrix.md gdpr-article-matrix.md iso27001-soa.md
  gdpr-ropa.md dpia-template.md risk-register.md auditor-handoff.md
  security-policies/00-index.md security-policies/infosec-policy.md
  security-policies/access-control-policy.md security-policies/incident-response-policy.md
  security-policies/change-management-policy.md security-policies/vendor-supplier-policy.md
  security-policies/bcp-dr-policy.md security-policies/data-retention-policy.md
)
TEMPLATE_FILES=(gdpr-ropa.md dpia-template.md)

# ── 1) the whole pack exists + is non-empty ─────────────────────────────────────
step "1/6 framework-evidence pack present + non-empty (${#PACK_FILES[@]} files)"
for f in "${PACK_FILES[@]}"; do
  [[ -s "${PACK}/${f}" ]] || fail "pack file missing/empty: wiki/compliance/${f}"
done
ok "all ${#PACK_FILES[@]} pack files present + non-empty"

# ── 2) SOC 2 CC1..CC9 + GDPR >=15 articles (not a stub) ─────────────────────────
step "2/6 SOC 2 matrix walks CC1..CC9; GDPR matrix cites >=15 distinct articles"
for c in 1 2 3 4 5 6 7 8 9; do
  grep -qE "CC${c}\b" "${SOC2}" || fail "SOC 2 matrix never references CC${c} — incomplete Common Criteria walk"
done
GDPR_ARTS="$(grep -oiE 'Art\.?\s*[0-9]+' "${GDPR}" | grep -oE '[0-9]+' | sort -un | wc -l | tr -d ' ')"
[[ "${GDPR_ARTS}" -ge 15 ]] || fail "GDPR matrix cites only ${GDPR_ARTS} distinct articles (<15) — too thin to be a real article-by-article map"
ok "SOC 2 CC1..CC9 all present; GDPR cites ${GDPR_ARTS} distinct articles"

# ── 3) ISO 27001:2022 SoA completeness — EVERY Annex A control decided ───────────
step "3/6 (headline) ISO SoA decides every Annex A control: A.5x37 A.6x8 A.7x14 A.8x34 = 93"
[[ -s "${SOA}" ]] || fail "ISO SoA missing/empty: ${SOA}"
MISSING_A=""
check_family() { # $1=theme number  $2=count
  local t="$1" n="$2" i
  for i in $(seq 1 "${n}"); do
    grep -qE "A\.${t}\.${i}\b" "${SOA}" || MISSING_A="${MISSING_A} A.${t}.${i}"
  done
}
check_family 5 37
check_family 6 8
check_family 7 14
check_family 8 34
[[ -z "${MISSING_A}" ]] || fail "ISO SoA is INCOMPLETE — Annex A controls with no row:${MISSING_A}"
ok "all 93 Annex A:2022 controls have a SoA row (no blanks)"

# ── 4) honesty: NO placeholder leaked into a non-template file ───────────────────
step "4/6 no placeholder (TODO/FIXME/bare TBD/lorem) outside the two template files"
is_template() {
  local b
  b="$(basename "$1")"
  for t in "${TEMPLATE_FILES[@]}"; do [[ "${b}" == "${t}" ]] && return 0; done
  return 1
}
PLACEHOLDERS=""
while IFS= read -r f; do
  is_template "${f}" && continue
  if grep -nEi '\b(TODO|FIXME|TBD)\b|lorem ipsum|lorem' "${f}" >/dev/null 2>&1; then
    PLACEHOLDERS="${PLACEHOLDERS}\n  ${f#"${BAAS_DIR}/"}: $(grep -nEi '\b(TODO|FIXME|TBD)\b|lorem' "${f}" | head -1)"
  fi
done < <(find "${PACK}" -name '*.md' | sort)
[[ -z "${PLACEHOLDERS}" ]] || fail "placeholder text in a non-template matrix file (honesty bar):${PLACEHOLDERS}"
ok "no placeholders outside gdpr-ropa.md / dpia-template.md"

# ── 5) no dangling citation — every backticked gate + migration resolves ─────────
step "5/6 every backticked \`mNN\` resolves to a verify script + every \`0NN_*.sql\` to a migration"
DANGLING=""
for g in $(grep -rhoE '`m[0-9]{2,3}`' "${PACK}" | tr -d '`' | sort -u); do
  ls "${SCRIPT_DIR}/${g}-"*.sh >/dev/null 2>&1 || DANGLING="${DANGLING} ${g}"
done
[[ -z "${DANGLING}" ]] || fail "dangling gate citation(s) — no verify/<gate>-*.sh for:${DANGLING}"
DANGLING_M=""
for m in $(grep -rhoE '`0[0-9][0-9]_[a-z0-9_]+\.sql`' "${PACK}" | tr -d '`' | sort -u); do
  [[ -f "${MIGR_DIR}/${m}" ]] || DANGLING_M="${DANGLING_M} ${m}"
done
[[ -z "${DANGLING_M}" ]] || fail "dangling migration citation(s) — not under scripts/migrations/postgresql/:${DANGLING_M}"
ok "all gate + migration citations in the pack resolve to real files"

# ── 6) posture.json <-> matrices consistency (no orphan implemented control) ─────
step "6/6 every implemented gate-backed control in posture.json is cross-walked in the pack"
ORPHANS="$(
  python3 - "${POSTURE_JSON}" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
print("\n".join(
    c["evidence"] for c in d.get("controls", [])
    if c.get("status") == "implemented" and re.fullmatch(r"m\d+", str(c.get("evidence", "")))
))
PY
)"
MISS_X=""
for g in ${ORPHANS}; do
  grep -rq "\`${g}\`" "${PACK}" || MISS_X="${MISS_X} ${g}"
done
[[ -z "${MISS_X}" ]] || fail "posture.json implemented control(s) not cross-walked in the matrices:${MISS_X}"
ok "posture.json implemented gate-backed controls all appear in the pack"

# ── summary + gate event ────────────────────────────────────────────────────────
green "[M143] (1) pack present  (2) SOC2 CC1..CC9 + ${GDPR_ARTS} GDPR articles  (3) all 93 ISO Annex A controls decided"
green "[M143] (4) no placeholders outside templates  (5) all gate+migration citations resolve  (6) posture<->matrices consistent"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-compliance-matrices}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m143-compliance-matrices=PASS" --outcome pass \
      --msg "framework cross-walks complete+honest: SOC2 CC1-9 + ${GDPR_ARTS} GDPR articles + all 93 ISO Annex A controls decided; no placeholders; no dangling citation; posture<->matrices consistent" \
      --ref "scripts/verify/m143-compliance-matrices.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M143] ALL GREEN — SOC 2 / GDPR / ISO 27001 cross-walks are AUDIT-READY (complete + in-repo re-verifiable; NOT a formal certification)"
exit 0
