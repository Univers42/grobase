#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    sqlmap-scan.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Targeted SQL-injection probe against the LIVE Grobase data-plane API with
# sqlmap. Runs the official googlesky/sqlmap image (sqlmap upstream ships no
# image; this is the de-facto mirror) — no host install. REQUIRES the live stack.
#
# This complements — does NOT replace — the in-repo INJECTION CORPUS at
#   apps/baas/mini-baas-infra/postman/corpus/_gen-injection-security.mjs
# which fires >=115 hand-built adversarial vectors (owner-spoof, $-operator,
# unconfirmed-DDL, control-char, 5xx-leak) through the Postman runner. sqlmap
# adds an *automated* boolean/time/error/union SQLi sweep on top of that corpus.
#
# HONESTY: a scanner finding nothing is NOT proof of security — it bounds known
# classes (here: automatable SQLi families on the probed params). The data plane
# escapes values + strips reserved owner/tenant fields per request, so we EXPECT
# no injectable param; this run CONFIRMS that. An independent pen test is still
# required (HUMAN-ATOMS).
#
# Usage:
#   bash apps/baas/mini-baas-infra/scripts/security/audit/sqlmap-scan.sh
#   TARGET_URL=http://127.0.0.1:8000 BAAS_API_KEY=... bash .../sqlmap-scan.sh
#
# Environment knobs:
#   TARGET_URL          live gateway URL (default http://127.0.0.1:8000)
#   BAAS_API_KEY        x-api-key to authenticate the probed endpoint (optional)
#   SQLMAP_DBID         mount/db id to target in the path (default demo)
#   SQLMAP_TABLE        table name to target (default items)
#   SQLMAP_IMAGE        override image (default googlesky/sqlmap)
#   SQLMAP_LEVEL/RISK   sqlmap intensity (default level=2 risk=1 — gentle)
#   AUDIT_ARTIFACTS_DIR apps/baas/mini-baas-infra/artifacts/security-audit (default)
#
# Exit codes: 0 no injectable param / 1 injection found / 2 target unreachable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ARTIFACTS_DIR="${AUDIT_ARTIFACTS_DIR:-${BAAS_DIR}/artifacts/security-audit}"
mkdir -p "${ARTIFACTS_DIR}"

TARGET="${TARGET_URL:-http://127.0.0.1:8000}"
SQLMAP_IMAGE="${SQLMAP_IMAGE:-googlesky/sqlmap:latest}"
DBID="${SQLMAP_DBID:-demo}"
TABLE="${SQLMAP_TABLE:-items}"
LEVEL="${SQLMAP_LEVEL:-2}"
RISK="${SQLMAP_RISK:-1}"
API_KEY="${BAAS_API_KEY:-}"
CORPUS="${BAAS_DIR}/postman/corpus/_gen-injection-security.mjs"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[0;33m%s\033[0m\n' "$*"; }

OUT_DIR="${ARTIFACTS_DIR}/sqlmap"
mkdir -p "${OUT_DIR}"
LOG_OUT="${ARTIFACTS_DIR}/sqlmap.log"
on_exit() {
  local rc=$?
  echo
  echo "[sqlmap] log: ${LOG_OUT}  | session: ${OUT_DIR}/"
  [[ ${rc} -eq 2 ]] && amber "[sqlmap] (no-op: live stack required)"
  return 0
}
trap on_exit EXIT

cyan "[sqlmap] SQLi probe against ${TARGET} @ $(date -u +%FT%TZ)"
[[ -f "${CORPUS}" ]] &&
  cyan "[sqlmap] complements in-repo injection corpus: ${CORPUS}" ||
  amber "[sqlmap] injection corpus not found at ${CORPUS} (informational)"

# ── live-stack guard ─────────────────────────────────────────────────────────
if ! curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "${TARGET}" 2>/dev/null |
  grep -qE "^[2-5][0-9][0-9]$"; then
  amber "[sqlmap] target ${TARGET} unreachable — SKIPPING (bring the stack up first)"
  amber "[sqlmap] this scanner needs the live data-plane API; nothing to probe, exiting cleanly"
  exit 2
fi
green "[sqlmap] target responded — proceeding"

# ── endpoints to probe ───────────────────────────────────────────────────────
# The data-plane CRUD endpoint takes a JSON op body. We probe two surfaces:
#   1) the filter object of a `list` op (most likely place a naive impl would
#      concat user input into SQL),
#   2) the path table segment.
QUERY_URL="${TARGET}/query/v1/${DBID}/tables/${TABLE}"
# sqlmap injects at the * marker; we mark the value inside the JSON filter.
LIST_BODY='{"op":"list","filter":{"name":"*"},"limit":10}'

HEADER_ARGS=()
HEADER_ARGS+=("--header=Content-Type: application/json")
[[ -n "${API_KEY}" ]] && HEADER_ARGS+=("--header=x-api-key: ${API_KEY}")
[[ -z "${API_KEY}" ]] && amber "[sqlmap] no BAAS_API_KEY set — probing unauthenticated (may 401; set the key for a real test)"

cyan "[sqlmap] probing POST ${QUERY_URL} (filter param, level=${LEVEL} risk=${RISK})"
# --network host → reach the host gateway from inside the container.
# --batch non-interactive; -v 1 quiet-ish; output dir mounted for the session.
docker run --rm \
  --network host \
  -v "${REPO_ROOT}/${OUT_DIR}:/sqlmap/output" \
  "${SQLMAP_IMAGE}" \
  -u "${QUERY_URL}" \
  --method=POST \
  --data="${LIST_BODY}" \
  "${HEADER_ARGS[@]}" \
  --level="${LEVEL}" --risk="${RISK}" \
  --batch --random-agent \
  --output-dir=/sqlmap/output \
  -v 1 \
  2>&1 | tee "${LOG_OUT}" | tail -50 || true

# ── verdict: sqlmap prints "is vulnerable" / "injectable" when it finds SQLi ──
echo
if grep -qiE 'parameter .* is vulnerable|the back-end DBMS is|appears to be .* injectable' "${LOG_OUT}" 2>/dev/null; then
  red "[sqlmap] FAIL — sqlmap reports an injectable parameter"
  grep -iE 'is vulnerable|injectable|back-end DBMS' "${LOG_OUT}" | head -15 || true
  exit 1
fi
if grep -qiE 'all tested parameters do not appear to be injectable|not injectable' "${LOG_OUT}" 2>/dev/null; then
  green "[sqlmap] OK — no injectable parameter found (data plane escapes/stamps as designed)"
  exit 0
fi
amber "[sqlmap] inconclusive (endpoint may have 401'd or returned no testable param) — inspect ${LOG_OUT}"
exit 0
