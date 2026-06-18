#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    compliance-evidence-export.sh                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# compliance-evidence-export — assemble the SELF-DESCRIBING audit hand-off
# bundle a SOC 2 auditor / ISO/IEC 27001 body / Vanta / Drata / pen-tester
# receives. It copies the in-repo compliance pack (matrices + SoA + RoPA +
# DPIA + risk register + policies + auditor index + the Vanta/Drata map + the
# pen-test scope), the canonical control catalog (config/trust/posture.json),
# the list of re-runnable gate scripts, and any gate-battery logs present, then
# writes a MANIFEST.md (what's inside + how to re-verify each item) and a
# sha256sums.txt over the whole tree.
#
# HONESTY (kernel rule #4): this produces "AUDIT-READY EVIDENCE", NOT a
# certificate. Every control cites a re-runnable gate or a source path; the
# pending human/$$ atoms (external auditor, ISO body, counsel, live IdP/KMS,
# uptime probe, independent pen test) are enumerated in auditor-handoff.md and
# echoed in the MANIFEST.
#
# It copies files that already exist — NO live stack is required to produce a
# bundle. If the live control plane is up AND SOC2_EVIDENCE_ENABLED is set, it
# ALSO pulls the sealed evidence snapshots from GET /v1/compliance/evidence and
# GET /v1/compliance/verify; otherwise it records that those snapshots require
# enabling the flag + collecting (it never fails for their absence).
#
# USAGE
#   bash scripts/security/handoff/compliance-evidence-export.sh
#
# ENV (all optional)
#   OUT_DATE            override the bundle date dir (default: `date +%Y-%m-%d`)
#   COMPLIANCE_BASE_URL control-plane base for the live evidence pull
#                       (default: http://127.0.0.1:3022 — the tenant-control port)
#   SOC2_EVIDENCE_ENABLED  if truthy AND the base is reachable, pull live snapshots
#
# OUTPUT
#   apps/baas/mini-baas-infra/artifacts/audit-handoff/<YYYY-MM-DD>/
#     ├── MANIFEST.md          self-describing index + per-item re-verify recipe
#     ├── sha256sums.txt       checksum over every file in the bundle
#     ├── wiki-compliance/     the compliance pack (matrices, SoA, RoPA, DPIA, ...)
#     ├── wiki-legal/          DPA / ToS / privacy / SLA / subprocessors templates
#     ├── posture.json         the canonical machine-readable control catalog
#     ├── gate-scripts.txt     every scripts/verify/m<NN>-*.sh (the re-runnable proof)
#     ├── gate-battery-logs/   any artifacts/gate-battery/*.log present
#     └── live-evidence/       (only if the live pull succeeded) sealed snapshots

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/security/handoff -> mini-baas-infra
BAAS_INFRA="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BAAS_DIR="$(cd "${BAAS_INFRA}/.." && pwd)" # apps/baas
cd "${BAAS_INFRA}"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

DATE="${OUT_DATE:-$(date +%Y-%m-%d)}"
GEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_REV="$(git -C "${BAAS_INFRA}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

OUT_DIR="${BAAS_INFRA}/artifacts/audit-handoff/${DATE}"
COMPLIANCE_BASE_URL="${COMPLIANCE_BASE_URL:-http://127.0.0.1:3022}"

cyan "[handoff] assembling audit hand-off bundle → ${OUT_DIR}"
cyan "[handoff] source rev ${GIT_REV} · generated ${GEN_AT}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# ── 1) the compliance documentation pack (matrices + SoA + RoPA + DPIA + ...) ──
SRC_COMPLIANCE="${BAAS_DIR}/wiki/compliance"
if [[ -d "${SRC_COMPLIANCE}" ]]; then
  cp -a "${SRC_COMPLIANCE}" "${OUT_DIR}/wiki-compliance"
  # strip nothing — the pack is meant to be handed whole.
  green "[handoff] copied wiki/compliance/ ($(find "${OUT_DIR}/wiki-compliance" -type f | wc -l | tr -d ' ') files)"
else
  red "[handoff] MISSING ${SRC_COMPLIANCE} — the compliance pack is the core of this bundle"
  exit 2
fi

# ── 2) the legal templates (DPA / ToS / privacy / SLA / subprocessors) ─────────
SRC_LEGAL="${BAAS_DIR}/wiki/legal"
if [[ -d "${SRC_LEGAL}" ]]; then
  cp -a "${SRC_LEGAL}" "${OUT_DIR}/wiki-legal"
  green "[handoff] copied wiki/legal/ ($(find "${OUT_DIR}/wiki-legal" -type f | wc -l | tr -d ' ') files)"
else
  amber "[handoff] no wiki/legal/ — DPA/ToS templates absent (counsel atom)"
fi

# ── 3) the canonical control catalog ───────────────────────────────────────────
SRC_POSTURE="${BAAS_INFRA}/config/trust/posture.json"
if [[ -f "${SRC_POSTURE}" ]]; then
  cp -a "${SRC_POSTURE}" "${OUT_DIR}/posture.json"
  green "[handoff] copied config/trust/posture.json (the source-of-truth catalog)"
else
  red "[handoff] MISSING ${SRC_POSTURE} — the canonical control catalog"
  exit 2
fi

# ── 4) the re-runnable gate scripts list (the differentiator) ──────────────────
GATE_LIST="${OUT_DIR}/gate-scripts.txt"
{
  echo "# Re-runnable verify gates (scripts/verify/m<NN>-*.sh) at rev ${GIT_REV}"
  echo "# Each is self-contained: builds tenant-control / data-plane from current"
  echo "# source on a throwaway DB; touches no shared stack. Run one directly:"
  echo "#   bash apps/baas/mini-baas-infra/scripts/verify/<name>"
  echo "# Or the full enterprise battery:"
  echo "#   bash apps/baas/mini-baas-infra/scripts/verify/run-gate-battery.sh --enterprise"
  echo "#"
  (cd "${BAAS_INFRA}/scripts/verify" && ls -1 m*.sh 2>/dev/null | sort -V)
} >"${GATE_LIST}"
GATE_COUNT="$(grep -cE '^m' "${GATE_LIST}" || echo 0)"
green "[handoff] enumerated ${GATE_COUNT} verify gate scripts → gate-scripts.txt"

# ── 5) any gate-battery run logs present (the evidence of execution) ────────────
SRC_BATTERY="${BAAS_INFRA}/artifacts/gate-battery"
BATTERY_COUNT=0
mkdir -p "${OUT_DIR}/gate-battery-logs"
if compgen -G "${SRC_BATTERY}/*.log" >/dev/null 2>&1; then
  cp -a "${SRC_BATTERY}"/*.log "${OUT_DIR}/gate-battery-logs/" 2>/dev/null || true
  BATTERY_COUNT="$(find "${OUT_DIR}/gate-battery-logs" -name '*.log' | wc -l | tr -d ' ')"
  green "[handoff] copied ${BATTERY_COUNT} gate-battery log(s)"
else
  amber "[handoff] no artifacts/gate-battery/*.log yet — run run-gate-battery.sh --enterprise to populate"
  echo "No gate-battery logs were present at export time (${GEN_AT})." \
    >"${OUT_DIR}/gate-battery-logs/_NONE.txt"
  echo "Generate them with: bash scripts/verify/run-gate-battery.sh --enterprise" \
    >>"${OUT_DIR}/gate-battery-logs/_NONE.txt"
fi

# ── 6) (optional) live sealed evidence snapshots — only if the flag is ON ───────
LIVE_DIR="${OUT_DIR}/live-evidence"
mkdir -p "${LIVE_DIR}"
LIVE_PULLED="no"
flag_on() { case "${1:-}" in 1 | true | TRUE | yes | on) return 0 ;; *) return 1 ;; esac }

if flag_on "${SOC2_EVIDENCE_ENABLED:-}"; then
  if curl -fsS -o /dev/null --max-time 4 "${COMPLIANCE_BASE_URL}/v1/compliance/evidence" 2>/dev/null; then
    cyan "[handoff] SOC2_EVIDENCE_ENABLED + live → pulling sealed snapshots from ${COMPLIANCE_BASE_URL}"
    curl -fsS --max-time 10 "${COMPLIANCE_BASE_URL}/v1/compliance/evidence" \
      -o "${LIVE_DIR}/evidence.json" 2>/dev/null || true
    curl -fsS --max-time 10 "${COMPLIANCE_BASE_URL}/v1/compliance/verify" \
      -o "${LIVE_DIR}/verify.json" 2>/dev/null || true
    if [[ -s "${LIVE_DIR}/evidence.json" ]]; then
      LIVE_PULLED="yes"
      green "[handoff] pulled live sealed evidence + verify summary"
    else
      amber "[handoff] live endpoint reachable but returned no body — leaving live-evidence empty"
    fi
  else
    amber "[handoff] SOC2_EVIDENCE_ENABLED set but ${COMPLIANCE_BASE_URL}/v1/compliance/evidence unreachable"
  fi
else
  amber "[handoff] SOC2_EVIDENCE_ENABLED not set — live snapshots not pulled (this is fine)"
fi

if [[ "${LIVE_PULLED}" == "no" ]]; then
  cat >"${LIVE_DIR}/_HOW-TO-COLLECT.md" <<EOF
# Live sealed evidence — not included in this bundle

The SOC2-lite continuous evidence collector (gate \`m108\`, internal/compliance,
migration 051/064) seals signed snapshots of CI gate results, access posture,
and the change-management trail. They were **not** pulled into this bundle
because the live control plane was not reachable with \`SOC2_EVIDENCE_ENABLED\`.

To produce them:

1. Bring up the control plane with the flag ON (managed-cloud overlay turns the
   Track-B flags on, or set \`SOC2_EVIDENCE_ENABLED=1\` for tenant-control):
   \`\`\`
   make -C apps/baas/mini-baas-infra cloud-up        # OR run tenant-control with SOC2_EVIDENCE_ENABLED=1
   \`\`\`
2. Collect a snapshot, then read it back:
   \`\`\`
   curl -s -X POST ${COMPLIANCE_BASE_URL}/v1/compliance/collect
   curl -s        ${COMPLIANCE_BASE_URL}/v1/compliance/evidence   # sealed section rows
   curl -s        ${COMPLIANCE_BASE_URL}/v1/compliance/verify     # recompute seals → intact / first break
   \`\`\`
3. Re-run this export with \`SOC2_EVIDENCE_ENABLED=1\` and the live stack up.

Self-contained proof of the collector's integrity (needs no live stack):
\`\`\`
bash apps/baas/mini-baas-infra/scripts/verify/m108-soc2-evidence.sh
\`\`\`
EOF
  green "[handoff] wrote live-evidence/_HOW-TO-COLLECT.md (flag-off path)"
fi

# ── 7) the MANIFEST — self-describing index + per-item re-verify recipe ─────────
COMPLIANCE_FILES="$(find "${OUT_DIR}/wiki-compliance" -type f | wc -l | tr -d ' ')"
MANIFEST="${OUT_DIR}/MANIFEST.md"
cat >"${MANIFEST}" <<EOF
# Grobase BaaS — Audit Hand-off Bundle

> **What this is.** The self-describing evidence package handed to a SOC 2
> auditor (CPA firm), an ISO/IEC 27001 certification body, a compliance
> platform (Vanta / Drata / Secureframe), or an independent pen-tester. Every
> control here cites a **re-runnable gate** (\`scripts/verify/m<NN>-*.sh\`) or an
> in-repo source path, so the auditor can reproduce the evidence rather than
> trust a PDF.

> **Honesty bar (kernel rule #4).** This bundle is **AUDIT-READY EVIDENCE, NOT
> A CERTIFICATE.** A formal SOC 2 Type 2 report or an ISO/IEC 27001 certificate
> requires an external party over a calendar-bound observation window. The
> pending human / \$\$ atoms are enumerated in \`wiki-compliance/auditor-handoff.md\`
> §7 (external auditor, ISO body, legal counsel, live IdP/KMS, uptime probe,
> independent pen test) — none are hidden.

| Field | Value |
|---|---|
| Generated (UTC) | ${GEN_AT} |
| Bundle date | ${DATE} |
| Source revision | \`${GIT_REV}\` |
| Verify gate scripts | ${GATE_COUNT} (see \`gate-scripts.txt\`) |
| Gate-battery logs included | ${BATTERY_COUNT} (see \`gate-battery-logs/\`) |
| Live sealed evidence pulled | ${LIVE_PULLED} (see \`live-evidence/\`) |
| Compliance pack files | ${COMPLIANCE_FILES} (see \`wiki-compliance/\`) |

---

## Start here (reading order)

1. \`wiki-compliance/auditor-handoff.md\` — **the single index.** Control catalog,
   framework cross-walks, the re-runnable gate map, the sampled population, and
   the honest human/\$\$ gap to a certificate.
2. \`wiki-compliance/vanta-drata-mapping.md\` — maps each Vanta/Drata automated
   test → the Grobase control + the in-repo evidence (gate / posture.json id /
   wiki doc) that satisfies it, and flags which tests are code vs config.
3. \`wiki-compliance/pentest-scope.md\` — pen-test scope / rules-of-engagement
   (in-scope targets, OWASP WSTG + ASVS L2 categories, the multi-tenant
   isolation/ABAC focus, out-of-scope, how findings feed the risk register).
4. \`posture.json\` — the **canonical** machine-readable control catalog. If any
   document disagrees with this file, the file wins.

---

## What's inside

| Path | Contents | How to re-verify |
|---|---|---|
| \`posture.json\` | Canonical control catalog (id · name · category · status · evidence), served at \`GET /v1/trust\` when \`TRUST_CENTER_ENABLED=1\`. | \`bash scripts/verify/m144-*.sh\` (public /security parity with posture.json) · \`m141\` (posture matrix honest+provable) |
| \`wiki-compliance/auditor-handoff.md\` | The auditor index (the document to read first). | n/a (index) |
| \`wiki-compliance/vanta-drata-mapping.md\` | Vanta/Drata automated-test → control → evidence map. | per-row gate cited in the table |
| \`wiki-compliance/pentest-scope.md\` | Pen-test RoE + scope (the strongest single due-diligence artifact). | n/a (scope doc); findings → \`risk-register.md\` |
| \`wiki-compliance/soc2-tsc-matrix.md\` | SOC 2 Trust Services Criteria CC1–CC9 + A/C/PI/P cross-walk. | \`bash scripts/verify/m143-compliance-matrices.sh\` |
| \`wiki-compliance/gdpr-article-matrix.md\` | GDPR Art. 5–50 cross-walk, controller/processor split. | \`bash scripts/verify/m143-compliance-matrices.sh\` |
| \`wiki-compliance/iso27001-soa.md\` | ISO/IEC 27001:2022 Statement of Applicability (all 93 Annex A controls). | \`bash scripts/verify/m143-compliance-matrices.sh\` |
| \`wiki-compliance/risk-register.md\` | ISO clause 6 / SOC 2 CC3 risk register (seeded from real residuals). | review; pen-test findings feed it |
| \`wiki-compliance/gdpr-ropa.md\` | GDPR Art. 30 Records of Processing (processor + controller views). | n/a (customer-fill fields) |
| \`wiki-compliance/dpia-template.md\` | GDPR Art. 35 DPIA template. | n/a (customer-fill) |
| \`wiki-compliance/security-policies/\` | ISMS policy set (infosec, access-control, incident-response, change-mgmt, vendor, BCP/DR, data-retention). | management/counsel adopt |
| \`wiki-legal/\` | DPA (Art. 28) · ToS · privacy policy · SLA · subprocessors · AUP — **templates, counsel review required.** | counsel review (legal atom) |
| \`gate-scripts.txt\` | List of every re-runnable \`scripts/verify/m<NN>-*.sh\`. | \`bash scripts/verify/run-gate-battery.sh --enterprise\` |
| \`gate-battery-logs/\` | Captured PASS/FAIL output of gate-battery runs (if present). | re-run the cited gate |
| \`live-evidence/\` | Sealed SOC2-lite snapshots **if** \`SOC2_EVIDENCE_ENABLED\` + live stack; else \`_HOW-TO-COLLECT.md\`. | \`bash scripts/verify/m108-soc2-evidence.sh\` |
| \`sha256sums.txt\` | SHA-256 over every file in this bundle (integrity). | \`sha256sum -c sha256sums.txt\` (from this dir) |

---

## Re-verify a specific assurance area (run the gate yourself)

These are self-contained: each builds tenant-control / data-plane from current
source on a throwaway database and removes everything afterwards — they never
touch a shared stack and need no live services.

| Assurance area | Gate | Proves |
|---|---|---|
| Tamper-evident audit log | \`m104\` | hash-chain recomputes; a tampered row → \`intact:false\` at the broken seq |
| Right to erasure (GDPR Art. 17) | \`m105\` | scoped delete + receipt; another tenant never touched |
| Data portability (GDPR Art. 15/20) | \`m109\` | engine-neutral export + manifest, strictly tenant-scoped |
| Per-tenant isolation | \`m46\` | per-request isolation byte-identical at 10K tenants → 1 pool |
| Fine-grained ABAC | \`m135\` \`m136\` \`m137\` \`m139\` | column-mask · stored conditions · per-instance · api-key callers under the PDP |
| IP allowlist | \`m106\` | per-tenant network access control + flag-off parity |
| Passkeys (WebAuthn) | \`m107\` | full ceremony; wrong-key/replay/cross-user rejected |
| Org RBAC / SSO / SCIM | \`m103\` / \`m110\` / \`m111\` | org model + OIDC + SCIM lifecycle + cross-tenant wall |
| CMEK / BYOK | \`m123\` | envelope seal/unwrap + crypto-shred on KEK revocation |
| Continuous evidence (sampled population) | \`m108\` | seals signed snapshots of CI/access/change-mgmt |
| Posture matrix honest+provable | \`m141\` | docs + standards mapping + audit spine + GDPR rights surface |
| Framework cross-walks complete+honest | \`m143\` | matrices complete (all 93 Annex A) + no dangling citation |

\`\`\`bash
# one gate, direct (example):
bash apps/baas/mini-baas-infra/scripts/verify/m104-audit-chain.sh
# the full enterprise + data-plane battery (logs to artifacts/gate-battery/):
bash apps/baas/mini-baas-infra/scripts/verify/run-gate-battery.sh --enterprise
\`\`\`

---

## Verify this bundle's integrity

\`\`\`bash
cd "$(dirname "\$0")" 2>/dev/null || cd .   # from this bundle directory
sha256sum -c sha256sums.txt
\`\`\`

---

## The honest gap to a certificate

This bundle proves the controls **exist and are re-verifiable**. It does **not**
make Grobase "SOC 2 certified" or "ISO 27001 certified" — those require external
parties over an observation window. See \`wiki-compliance/auditor-handoff.md\` §7
for the full enumerated list of pending human / \$\$ atoms. The single strongest
thing to add next is an **independent penetration test** (scope:
\`wiki-compliance/pentest-scope.md\`).
EOF
green "[handoff] wrote MANIFEST.md"

# ── 8) sha256sums over the whole bundle (excluding the sums file itself) ────────
SUMS="${OUT_DIR}/sha256sums.txt"
(cd "${OUT_DIR}" && find . -type f ! -name 'sha256sums.txt' -print0 |
  sort -z |
  xargs -0 sha256sum >sha256sums.txt)
SUMS_COUNT="$(wc -l <"${SUMS}" | tr -d ' ')"
green "[handoff] wrote sha256sums.txt over ${SUMS_COUNT} files"

# ── done ───────────────────────────────────────────────────────────────────────
echo
green "[handoff] OK — audit hand-off bundle ready"
echo "  bundle:   ${OUT_DIR}"
echo "  manifest: ${MANIFEST}"
echo "  checksums:${SUMS} (${SUMS_COUNT} files)"
echo "  gates:    ${GATE_COUNT} scripts · ${BATTERY_COUNT} battery log(s) · live evidence: ${LIVE_PULLED}"
echo
cyan "[handoff] this is AUDIT-READY EVIDENCE, not a certificate — see MANIFEST.md §'The honest gap to a certificate'"
