# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    sonar-fetch-issues.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# scripts/sonar-fetch-issues.sh — Fetch SonarCloud issues as JSON + TXT summary
set -euo pipefail
readonly SEP_LINE='══════════════════════════════════════════════════'

: "${SONAR_TOKEN:?Set SONAR_TOKEN or TOK_SONARCLOUD in .env}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-Univers42_mini-baas-infra}"
HOST="https://sonarcloud.io"
OUT_DIR="audit"
mkdir -p "$OUT_DIR"

PAGE=1
PER_PAGE=500
ALL_FILE="$OUT_DIR/issues-all.json"

echo '[]' > "$ALL_FILE"

echo "Fetching issues from SonarCloud (project: $PROJECT_KEY)…"

while true; do
  resp=$(curl -sS -u "${SONAR_TOKEN}:" \
    "${HOST}/api/issues/search?componentKeys=${PROJECT_KEY}&ps=${PER_PAGE}&p=${PAGE}&resolved=false&statuses=OPEN,CONFIRMED,REOPENED")

  total=$(echo "$resp" | jq -r '.total // 0')
  issues=$(echo "$resp" | jq '.issues // []')
  count=$(echo "$issues" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    break
  fi

  # Merge into all-issues file
  jq -s '.[0] + .[1]' "$ALL_FILE" <(echo "$issues") > "$OUT_DIR/tmp.json"
  mv "$OUT_DIR/tmp.json" "$ALL_FILE"

  fetched=$(jq 'length' "$ALL_FILE")
  echo "  Page $PAGE — fetched $count issues (total so far: $fetched / $total)"

  if [[ "$fetched" -ge "$total" ]]; then
    break
  fi
  PAGE=$((PAGE + 1))
done

TOTAL_ISSUES=$(jq 'length' "$ALL_FILE")
echo ""
echo "Total open issues: $TOTAL_ISSUES"

# ── Generate per-severity JSON ──────────────────────────────
for sev in BLOCKER CRITICAL MAJOR MINOR INFO; do
  jq --arg s "$sev" '[.[] | select(.severity == $s)]' "$ALL_FILE" > "$OUT_DIR/issues-${sev,,}.json"
done

# ── Generate TXT summary ────────────────────────────────────
SUMMARY="$OUT_DIR/summary.txt"
{
  echo "$SEP_LINE"
  echo " SonarCloud Audit Report — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo " Project: $PROJECT_KEY"
  echo "$SEP_LINE"
  echo ""

  for sev in BLOCKER CRITICAL MAJOR MINOR INFO; do
    cnt=$(jq --arg s "$sev" '[.[] | select(.severity == $s)] | length' "$ALL_FILE")
    printf "  %-10s %s\n" "$sev" "$cnt"
  done
  echo ""

  # Breakdown by type
  echo "── By Type ────────────────────────────────────────"
  for typ in BUG VULNERABILITY CODE_SMELL; do
    cnt=$(jq --arg t "$typ" '[.[] | select(.type == $t)] | length' "$ALL_FILE")
    printf "  %-18s %s\n" "$typ" "$cnt"
  done
  echo ""

  # Detailed listing
  echo "── Detailed Issues ────────────────────────────────"
  jq -r '.[] | "[\(.severity)] \(.type) — \(.component | split(":")[1] // .component):\(.line // "?") — \(.message)"' "$ALL_FILE" \
    | sort -t'[' -k2,2 \
    | head -500
  echo ""
  echo "$SEP_LINE"
  echo " Total: $TOTAL_ISSUES open issues"
  echo "$SEP_LINE"
} > "$SUMMARY"

cat "$SUMMARY"

echo ""
echo "Artifacts saved:"
echo "  $ALL_FILE  ($TOTAL_ISSUES issues)"
echo "  $SUMMARY"
ls -la "$OUT_DIR"/issues-*.json
