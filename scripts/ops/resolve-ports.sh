# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    resolve-ports.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/02 12:42:55 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/resolve-ports.sh
# Detects port conflicts and exports free host-port env vars.
# Usage: eval "$(./scripts/resolve-ports.sh)"  or  source <(./scripts/resolve-ports.sh)
#
# For each VAR=DEFAULT pair, checks if the default port (or the value already
# set in the environment) is free.  If not, increments until a free port is
# found.  Outputs export statements so the caller gets the resolved values.

set -euo pipefail

# ── Port map: ENV_VAR=default_port ──────────────────────────────────
PORTS=(
  WAF_HTTP_PORT=8880
  WAF_HTTPS_PORT=8443
  KONG_HTTP_PORT=8000
  KONG_ADMIN_PORT=8001
  PG_PORT=5432
  TRINO_PORT=8080
  MONGO_PORT=27017
  GOTRUE_PORT=9999
  POSTGREST_PORT=3002
  REALTIME_PORT=4000
  REDIS_PORT=6379
  MINIO_API_PORT=9000
  MINIO_CONSOLE_PORT=9001
  SUPAVISOR_PORT=6543
  STUDIO_PORT=3001
  PROMETHEUS_PORT=9090
  GRAFANA_PORT=3030
  LOKI_PORT=3101
  PROMTAIL_PORT=9080
  TEMPO_PORT=3200
  OTEL_COLLECTOR_HTTP_PORT=4318
  OTEL_COLLECTOR_GRPC_PORT=4317
  OTEL_COLLECTOR_HEALTH_PORT=13133
)

declare -A SERVICE_PORTS=(
  [waf]=WAF_HTTPS_PORT
  [prometheus]=PROMETHEUS_PORT
  [grafana]=GRAFANA_PORT
  [loki]=LOKI_PORT
  [promtail]=PROMTAIL_PORT
  [tempo]=TEMPO_PORT
  [otel - collector]=OTEL_COLLECTOR_HEALTH_PORT
)

if [[ $# -gt 0 ]]; then
  for service in "$@"; do
    var="${SERVICE_PORTS[$service]:-}"
    [[ -n "$var" ]] || {
      echo "unknown service: $service" >&2
      exit 2
    }
    default=""
    for entry in "${PORTS[@]}"; do
      if [[ "${entry%%=*}" == "$var" ]]; then
        default="${entry#*=}"
        break
      fi
    done
    printf '%s\n' "${!var:-$default}"
  done
  exit 0
fi

# ── Helpers ─────────────────────────────────────────────────────────
_used_ports="" # track ports we've already claimed in this run

# Host ports published by THIS compose project's own containers. They are not
# "in use" for the purpose of `up`: compose either keeps that container (same
# port, no conflict) or stops it before recreating it. Counting them as busy
# is what made `make up` on a live stack relocate Kong 8000->8001 and the WAF
# 8443->8444 / 8880->8881 while every client still dialled the old ports
# (issue #19, measured 2026-09-23; gate m193). A port held by anything else is
# still avoided; without docker the old behaviour stands.
PROJECT="${COMPOSE_PROJECT_NAME:-$(sed -n 's/^name:[[:space:]]*//p' "$(dirname "${BASH_SOURCE[0]}")/../../docker-compose.yml" 2>/dev/null | head -n1)}"
_own_ports=" "
if [[ -n "$PROJECT" ]] && command -v docker >/dev/null 2>&1; then
  # From inspect, not `docker ps --format {{.Ports}}`: that column collapses
  # consecutive ports into ranges ("9000-9001->9000-9001/tcp").
  _ids=$(docker ps -q --filter "label=com.docker.compose.project=${PROJECT}" 2>/dev/null || true)
  if [[ -n "$_ids" ]]; then
    # shellcheck disable=SC2086 # one id per word, on purpose
    _own_ports=" $(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}} {{end}}{{end}}' $_ids 2>/dev/null |
      tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
  fi
fi

port_in_use() {
  local p=$1
  # Already claimed by an earlier entry in this script run
  if [[ " $_used_ports " == *" $p "* ]]; then
    return 0
  fi
  # Held by this stack itself: `up` reuses or frees it (see above)
  if [[ "$_own_ports" == *" $p "* ]]; then
    return 1
  fi
  # Check if something on the host is listening
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(:|^)${p}$"; then
    return 0
  fi
  return 1
}

find_free() {
  local p=$1
  while port_in_use "$p"; do
    ((p++))
  done
  echo "$p"
  return 0
}

# ── Main ────────────────────────────────────────────────────────────
changed=0
for entry in "${PORTS[@]}"; do
  var="${entry%%=*}"
  default="${entry#*=}"
  # Honour existing env override
  want="${!var:-$default}"
  got=$(find_free "$want")
  _used_ports="$_used_ports $got"
  if [[ "$got" != "$default" ]]; then
    echo "export ${var}=${got}"
    if [[ -t 2 ]]; then
      echo "  ⚠  ${var}: ${default} busy → ${got}" >&2
    fi
    ((changed++)) || true
  fi
done

if [[ "$changed" -eq 0 && -t 2 ]]; then
  echo "  ✓ All default ports available" >&2
fi
