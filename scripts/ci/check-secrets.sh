# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    check-secrets.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/check-secrets.sh
# Scan source code for hardcoded secrets
# Usage: bash scripts/check-secrets.sh
# Exit code: 1 if hardcoded secrets found, 0 otherwise

set -euo pipefail

echo "Scanning for hardcoded secrets..."

FOUND=0

# Drop matches that are demonstrably NOT live secrets: comment/docstring lines,
# OpenAPI-generated SDK example snippets, and obvious placeholder values. Keeps
# the scan strict on real source assignments while killing the known noise.
strip_false_positives() {
  grep -vE ':[0-9]+:[[:space:]]*(//|#|\*|/\*)' |
    grep -vE '/sdks/(python|kotlin|swift|dart)/' |
    grep -vEi '(example|placeholder|your[-_]|change[-_]?me|dummy|redacted|sample|anon-or-service|usage\.events|process\.env|os\.environ|getenv|<[a-z_]+>)' ||
    true
}

# Pattern: assignment with a string literal value >= 8 chars
# Covers: password = "...", secret: '...', key="..."
hits="$(grep -rEn '(password|secret|key|token)[[:space:]]*[:=][[:space:]]*["\x27][^"\x27$\{]{8,}["\x27]' \
  --include='*.js' --include='*.ts' --include='*.py' --include='*.yml' --include='*.yaml' \
  --exclude-dir=node_modules --exclude-dir='.git' --exclude-dir=vendor \
  --exclude='check-secrets.sh' --exclude='*.lock' \
  . 2>/dev/null | strip_false_positives)" || true
[[ -n "$hits" ]] && { printf '%s\n' "$hits"; FOUND=1; }

# Pattern: Bearer tokens or API keys as string literals
hits="$(grep -rEn 'Bearer[[:space:]]+[A-Za-z0-9_.-]{20,}' \
  --include='*.js' --include='*.ts' --include='*.py' \
  --exclude-dir=node_modules --exclude-dir='.git' --exclude-dir=vendor \
  --exclude-dir=scripts \
  . 2>/dev/null | strip_false_positives)" || true
[[ -n "$hits" ]] && { printf '%s\n' "$hits"; FOUND=1; }

if [[ "$FOUND" -eq 1 ]]; then
  echo ""
  echo "⚠ Potential hardcoded secrets detected above!"
  echo "Replace with environment variables or Docker secrets."
  exit 1
fi

echo "✓ No hardcoded secrets found."
