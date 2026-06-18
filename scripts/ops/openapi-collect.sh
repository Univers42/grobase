#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    openapi-collect.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/31 23:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/31 23:30:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Collect every NestJS app's /docs-json into infra/config/openapi/
# Each file is the live OpenAPI 3.0 document Swagger generates from the app's
# decorators. The SDK codegen step consumes these files (`npm run codegen`
# under sdks/js/) to produce typed clients.
#
# Usage:
#   bash scripts/ops/openapi-collect.sh
#   bash scripts/ops/openapi-collect.sh --apps query-router,mongo-api

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

OUT_DIR="infra/config/openapi"
mkdir -p "${OUT_DIR}"

declare -A APP_PORTS=(
  [log - service]=3010
  [adapter - registry]=3020
  [ai - service]=3030
  [storage - router]=3040
  [permission - engine]=3050
  [email - service]=3060
  [gdpr - service]=3070
  [newsletter - service]=3080
  [schema - service]=3090
  [session - service]=3100
  [analytics - service]=3110
  [mongo - api]=3120
  [query - router]=4001
)

FILTER=""
HOST="localhost"
for arg in "$@"; do
  case "$arg" in
  --apps=* | --apps)
    FILTER="${arg#--apps=}"
    ;;
  --docker-network)
    # When called from inside the mini-baas docker network, reach services
    # by their DNS name (mini-baas-adapter-registry etc.). Each service
    # listens on its <PORT> env var — same value as the host port above.
    HOST="DOCKER_DNS"
    ;;
  esac
done

ok=0
fail=0
for app in "${!APP_PORTS[@]}"; do
  if [[ -n "${FILTER}" ]] && [[ ",${FILTER}," != *",${app},"* ]]; then
    continue
  fi
  port="${APP_PORTS[$app]}"
  if [[ "${HOST}" == "DOCKER_DNS" ]]; then
    # Container DNS name matches the compose service key.
    url="http://${app}:${port}/docs-json"
  else
    url="http://localhost:${port}/docs-json"
  fi
  out="${OUT_DIR}/${app}.json"

  if curl -fsS "$url" -o "${out}.tmp" 2>/dev/null; then
    # Normalise output if `jq` is available, otherwise leave as-is.
    if command -v jq >/dev/null 2>&1; then
      jq -S '.' "${out}.tmp" >"${out}"
      rm -f "${out}.tmp"
    else
      mv "${out}.tmp" "${out}"
    fi
    size=$(wc -c <"${out}")
    echo "  ✓ ${app} (${size}B) → ${out}"
    ok=$((ok + 1))
  else
    rm -f "${out}.tmp"
    echo "  ✗ ${app} (${url} unreachable)"
    fail=$((fail + 1))
  fi
done

echo
echo "Collected: ${ok} ok, ${fail} failed"
if [[ ${fail} -gt 0 && ${ok} -eq 0 ]]; then
  echo "No OpenAPI documents collected — is the baas stack up?"
  echo "  Try: BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_NO_WAF=1 make baas-up"
  exit 1
fi
