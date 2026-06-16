# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    validate-all.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/validate-all.sh
# Pre-commit local validation — runs all fast checks before any commit.
# Usage: bash scripts/validate-all.sh
# Exit code: 0 only if all checks pass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
CHECKS=0

check() {
  local label="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label"
    ERRORS=$((ERRORS + 1))
  fi
  return 0
}

echo -e "${BOLD}═══ mini-BaaS validate-all ═══${NC}"
echo ""

# ── 1. Shell syntax check (bash -n) ──────────────────────────────
echo -e "${BOLD}1. Shell syntax${NC}"
sh_files=$(find "$ROOT_DIR/scripts" "$ROOT_DIR/vendor/scripts" -type f -name '*.sh' 2>/dev/null || true)
if [[ -z "$sh_files" ]]; then
  echo -e "  ${YELLOW}⚠${NC} No .sh files found"
else
  sh_fail=0
  while IFS= read -r f; do
    if ! bash -n "$f" 2>/dev/null; then
      echo -e "  ${RED}✗${NC} Syntax error: $f" >&2
      sh_fail=1
    fi
  done <<< "$sh_files"
  CHECKS=$((CHECKS + 1))
  if [[ "$sh_fail" -eq 0 ]]; then
    count=$(echo "$sh_files" | wc -l)
    echo -e "  ${GREEN}✓${NC} $count .sh files passed bash -n"
  else
    ERRORS=$((ERRORS + 1))
  fi
fi

# ── 2. Node.js syntax check (node --check) ──────────────────────
echo -e "${BOLD}2. JavaScript syntax${NC}"
js_files=$(find "$ROOT_DIR/docker/services" -type f -name '*.js' \
  -not -path '*/node_modules/*' 2>/dev/null || true)
if [[ -z "$js_files" ]]; then
  echo -e "  ${YELLOW}⚠${NC} No .js files found"
else
  js_fail=0
  while IFS= read -r f; do
    if ! node --check "$f" 2>/dev/null; then
      echo -e "  ${RED}✗${NC} Syntax error: $f" >&2
      js_fail=1
    fi
  done <<< "$js_files"
  CHECKS=$((CHECKS + 1))
  if [[ "$js_fail" -eq 0 ]]; then
    count=$(echo "$js_files" | wc -l)
    echo -e "  ${GREEN}✓${NC} $count .js files passed node --check"
  else
    ERRORS=$((ERRORS + 1))
  fi
fi

# ── 3. Docker Compose config validation ──────────────────────────
echo -e "${BOLD}3. Docker Compose${NC}"
check "docker compose config --quiet" \
  docker compose -f "$ROOT_DIR/docker-compose.yml" config --quiet

# ── 4. Secrets validation ────────────────────────────────────────
echo -e "${BOLD}4. Secrets${NC}"
if [[ -f "$ROOT_DIR/.env" ]]; then
  if [[ -x "$ROOT_DIR/scripts/secrets/validate-secrets.sh" ]] || \
     [ -f "$ROOT_DIR/scripts/secrets/validate-secrets.sh" ]]; then
    check "make secrets-validate" \
      bash "$ROOT_DIR/scripts/secrets/validate-secrets.sh"
  else
    echo -e "  ${YELLOW}⚠${NC} secrets/validate-secrets.sh not found, skipping"
  fi
else
  echo -e "  ${YELLOW}⚠${NC} .env not found — skipping secrets-validate"
fi

# ── 5. Hardcoded secrets scan ────────────────────────────────────
echo -e "${BOLD}5. Secret scan${NC}"
check "make check-secrets" \
  bash "$ROOT_DIR/scripts/check-secrets.sh"

# ── Summary ──────────────────────────────────────────────────────
echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "${RED}${BOLD}✗ $ERRORS/$CHECKS checks failed${NC}"
  exit 1
fi

echo -e "${GREEN}${BOLD}✓ All $CHECKS checks passed${NC}"
exit 0
