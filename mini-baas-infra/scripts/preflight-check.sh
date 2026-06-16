# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    preflight-check.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/preflight-check.sh
# Pre-deployment validation — checks everything before starting the stack
# Usage: bash scripts/preflight-check.sh
#        make preflight

set -euo pipefail
readonly SEP_LINE='═══════════════════════════════════════════'

PASS=0
FAIL=0
WARN=0

pass() { local msg="$1"; echo "  ✓ $msg"; PASS=$((PASS + 1)); return 0; }
fail() { local msg="$1"; echo "  ✗ $msg"; FAIL=$((FAIL + 1)); return 0; }
warn() { local msg="$1"; echo "  ⚠ $msg"; WARN=$((WARN + 1)); return 0; }

echo "$SEP_LINE"
echo " mini-BaaS Preflight Check"
echo "$SEP_LINE"
echo ""

# ─── 1. Docker ────────────────────────────────────────────────────
echo "Docker:"
if command -v docker >/dev/null 2>&1; then
  pass "Docker installed ($(docker --version | awk '{print $3}' | tr -d ','))"
else
  fail "Docker not installed"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose v2 available"
else
  fail "Docker Compose v2 not available"
fi

if docker info 2>/dev/null | grep -q "buildkit"; then
  pass "BuildKit enabled"
else
  warn "BuildKit status unknown — set DOCKER_BUILDKIT=1"
fi
echo ""

# ─── 2. Environment ──────────────────────────────────────────────
echo "Environment:"
if [[ -f .env ]]; then
  pass ".env file exists"

  REQUIRED_VARS=(
    JWT_SECRET
    POSTGRES_PASSWORD
    KONG_PUBLIC_API_KEY
    KONG_SERVICE_API_KEY
    MONGO_URI
  )

  for var in "${REQUIRED_VARS[@]}"; do
    if grep -q "^${var}=" .env; then
      val=$(grep "^${var}=" .env | cut -d= -f2-)
      if [[ ${#val} -ge 8 ]]; then
        pass "$var set (${#val} chars)"
      else
        warn "$var is short (${#val} chars)"
      fi
    else
      fail "$var is missing from .env"
    fi
  done
else
  fail ".env file missing — run: bash scripts/generate-env.sh .env"
fi
echo ""

# ─── 3. Dockerfiles ──────────────────────────────────────────────
echo "Dockerfiles:"
dockerfile_count=0
for df in docker/services/*/Dockerfile; do
  if [[ -f "$df" ]]; then
    dockerfile_count=$((dockerfile_count + 1))
  fi
done
if [[ $dockerfile_count -gt 0 ]]; then
  pass "Found $dockerfile_count Dockerfiles"
else
  fail "No Dockerfiles found in docker/services/"
fi
echo ""

# ─── 4. Config files ─────────────────────────────────────────────
echo "Configuration:"
for config_file in \
  "docker/services/kong/conf/kong.yml" \
  "config/prometheus/prometheus.yml" \
  "config/grafana/provisioning/datasources/datasources.yml" \
  "config/loki/loki.yaml" \
  "config/promtail/promtail.yaml"; do
  if [[ -f "$config_file" ]]; then
    pass "$config_file"
  else
    warn "$config_file missing"
  fi
done
echo ""

# ─── 5. Disk space ───────────────────────────────────────────────
echo "Resources:"
avail=$(df -m . | awk 'NR==2 {print $4}')
if [[ "$avail" -gt 2048 ]]; then
  pass "Disk space: ${avail}MB available"
else
  warn "Low disk space: ${avail}MB available (recommend >2GB)"
fi
echo ""

# ─── 6. Port conflicts ───────────────────────────────────────────
echo "Ports:"
for port in 8000 5432 27017 6379 9000 3010 3020 4001 3030 9090; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    warn "Port $port already in use"
  else
    pass "Port $port available"
  fi
done
echo ""

# ─── Summary ─────────────────────────────────────────────────────
echo "$SEP_LINE"
echo " Results: ✓ $PASS passed | ⚠ $WARN warnings | ✗ $FAIL failed"
echo "$SEP_LINE"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Fix the failures above before deploying."
  exit 1
fi
