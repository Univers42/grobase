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

# Pattern: assignment with a string literal value >= 8 chars
# Covers: password = "...", secret: '...', key="..."
if grep -rEn '(password|secret|key|token)\s*[:=]\s*["\x27][^"\x27$\{]{8,}["\x27]' \
    --include='*.js' --include='*.ts' --include='*.py' --include='*.yml' --include='*.yaml' \
    --exclude-dir=node_modules --exclude-dir='.git' --exclude-dir=vendor \
    --exclude='check-secrets.sh' --exclude='*.lock' \
    . 2>/dev/null; then
  FOUND=1
fi

# Pattern: Bearer tokens or API keys as string literals
if grep -rEn 'Bearer\s+[A-Za-z0-9_\-\.]{20,}' \
    --include='*.js' --include='*.ts' --include='*.py' \
    --exclude-dir=node_modules --exclude-dir='.git' --exclude-dir=vendor \
    --exclude-dir=scripts \
    . 2>/dev/null; then
  FOUND=1
fi

if [[ "$FOUND" -eq 1 ]]; then
  echo ""
  echo "⚠ Potential hardcoded secrets detected above!"
  echo "Replace with environment variables or Docker secrets."
  exit 1
fi

echo "✓ No hardcoded secrets found."
