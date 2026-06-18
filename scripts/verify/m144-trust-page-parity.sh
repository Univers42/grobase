#!/usr/bin/env bash
# **************************************************************************** #
#   m144-trust-page-parity.sh — the PUBLIC /security page never drifts from   #
#                               the canonical posture, and never overclaims    #
#                                                                              #
#   The marketing site (apps/baas/site) cannot read the control-plane's       #
#   posture.json at build time (its Docker build context is site/ only), so    #
#   site/src/data/security.ts is a HAND-AUTHORED mirror. This gate is the      #
#   single-source-of-truth enforcement seam — it runs where BOTH files are     #
#   visible (the repo tree) and proves:                                        #
#                                                                              #
#     (1) the page's control set == posture.json's control set (same ids),     #
#         and every control's status matches (no silent "planned -> green");   #
#     (2) the page never contains the one forbidden compliance adjective       #
#         (soft framing is allowed: "supports"/"aligned"/"audit-ready"; the    #
#          bare claim is not — kernel rule #4);                                #
#     (3) the RFC 9116 security.txt ships with a Contact, and the disclosure   #
#         anchor the Policy URL points at exists on the page.                   #
#                                                                              #
#   Pure file check — no container, no network. Safe to run anywhere.          #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
SITE="${BAAS_DIR}/site"
POSTURE_JSON="${INFRA_DIR}/config/trust/posture.json"
SECURITY_TS="${SITE}/src/data/security.ts"
SECURITY_ASTRO="${SITE}/src/pages/security.astro"
SECURITY_TXT="${SITE}/public/.well-known/security.txt"
COMP_DIR="${SITE}/src/components/security"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M144] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M144] FAIL — $*"
  exit 1
}

# ── 0) inputs present ────────────────────────────────────────────────────────────
step "0/4 inputs present (posture.json, security.ts, security.astro, security.txt)"
for f in "${POSTURE_JSON}" "${SECURITY_TS}" "${SECURITY_ASTRO}" "${SECURITY_TXT}"; do
  [[ -s "${f}" ]] || fail "missing/empty: ${f#"${BAAS_DIR}/"}"
done
ok "all four inputs present"

# ── 1) control set + statuses match posture.json exactly ─────────────────────────
step "1/4 site security.ts control set + statuses == posture.json (no drift)"
DRIFT="$(
  python3 - "${POSTURE_JSON}" "${SECURITY_TS}" <<'PY'
import json, re, sys
posture = {c["id"]: c["status"] for c in json.load(open(sys.argv[1])).get("controls", [])}
ts = open(sys.argv[2]).read()
# SecurityControl literals are the only objects with `id: '..', name: ..`; capture id+status.
pairs = re.findall(r"id:\s*'([^']+)',\s*name:[\s\S]*?status:\s*'([^']+)'", ts)
site = dict(pairs)
errs = []
if len(pairs) != len(site):
    errs.append(f"duplicate id in security.ts ({len(pairs)} literals, {len(site)} unique)")
for cid, st in site.items():
    if cid not in posture:
        errs.append(f"security.ts has '{cid}' not in posture.json")
    elif posture[cid] != st:
        errs.append(f"status drift for '{cid}': page={st} posture={posture[cid]}")
for cid in posture:
    if cid not in site:
        errs.append(f"posture.json control '{cid}' missing from security.ts")
print("\n".join(errs))
PY
)"
[[ -z "${DRIFT}" ]] || fail "trust-page drift from canonical posture.json:\n${DRIFT}"
NCTRL="$(grep -cE "id:\s*'[^']+',\s*$|id:\s*'[^']+'," "${SECURITY_TS}" || true)"
ok "security.ts mirrors posture.json (same ids, matching statuses)"

# ── 2) no forbidden compliance literal on the public page ────────────────────────
step "2/4 public security surface never contains the bare 'certified' claim"
HITS="$(grep -rinE 'certified' "${SECURITY_ASTRO}" "${SECURITY_TS}" "${COMP_DIR}" 2>/dev/null || true)"
[[ -z "${HITS}" ]] || fail "forbidden literal 'certified' on the public page (use 'audit-ready'/'aligned'/'certification'):\n${HITS}"
ok "no 'certified' literal in security.astro / security.ts / components/security"

# ── 3) RFC 9116 security.txt + disclosure anchor ─────────────────────────────────
step "3/4 security.txt has a Contact; the page exposes the #disclosure anchor"
grep -qE '^Contact:' "${SECURITY_TXT}" || fail "security.txt has no 'Contact:' line (RFC 9116 requires one)"
grep -qE '^Expires:' "${SECURITY_TXT}" || fail "security.txt has no 'Expires:' line (RFC 9116 requires one)"
grep -qE 'id="disclosure"' "${SECURITY_ASTRO}" || fail "security.astro has no id=\"disclosure\" anchor (security.txt Policy points there)"
ok "security.txt Contact+Expires present; #disclosure anchor present on the page"

# ── 4) summary + gate event ──────────────────────────────────────────────────────
step "4/4 summary"
green "[M144] (1) page<->posture parity OK  (2) no overclaim literal  (3) security.txt + disclosure anchor OK"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-trust-page-parity}"
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m144-trust-page-parity=PASS" --outcome pass \
      --msg "public /security page mirrors posture.json (ids+statuses), carries no 'certified' overclaim, ships RFC9116 security.txt + #disclosure anchor" \
      --ref "scripts/verify/m144-trust-page-parity.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
green "[M144] ALL GREEN — the public security page is honest + in lockstep with the canonical posture"
exit 0
