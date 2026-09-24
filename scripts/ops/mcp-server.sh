# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    mcp-server.sh                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/09/23 19:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/09/23 19:30:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/ops/mcp-server.sh
# Launch a local debugging MCP server (stdio) against the running dev stack.
# Usage: bash scripts/ops/mcp-server.sh <grafana|postgres>
#   grafana   Grafana MCP over the observability plane (Prometheus + Loki queries),
#             anonymous Viewer, write tools and anonymous usage stats disabled
#   postgres  Postgres MCP in restricted (read-only transaction) mode, creds from .env
# Wired from the repo-root .mcp.json. Resolves live host ports like `make health`
# (resolve-ports may bump defaults) and never prints a credential.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GRAFANA_IMG="grafana/mcp-grafana:1.5.1"
POSTGRES_IMG="crystaldba/postgres-mcp:0.3.0"

# die prints a message to stderr and exits 1.
die() { printf '%s\n' "$*" >&2; exit 1; }

# host_port prints the host port a running stack container publishes, or nothing.
# @param $1 container name  @param $2 container port/proto (e.g. 3000/tcp)
host_port() { docker port "$1" "$2" 2>/dev/null | sed -n '1s/.*://p'; }

# env_value prints VAR's last value from .env without sourcing the file.
# @param $1 variable name
env_value() { sed -n "s/^$1=//p" "$ROOT/.env" | tail -1; }

# run_grafana execs the read-only Grafana MCP against the live Grafana.
run_grafana() {
  local port
  port="$(host_port mini-baas-grafana 3000/tcp)"
  [ -n "$port" ] || die "mini-baas-grafana is not running — bring up the observability plane"
  exec docker run --rm -i --init --network host -e GRAFANA_URL="http://127.0.0.1:$port" \
    "$GRAFANA_IMG" -t stdio -disable-write -usage-stats disabled
}

# run_postgres execs the restricted Postgres MCP; the URI travels via env, not argv.
run_postgres() {
  local port user pass db
  port="$(host_port mini-baas-postgres 5432/tcp)"
  [ -n "$port" ] || die "mini-baas-postgres is not running — make up"
  [ -f "$ROOT/.env" ] || die ".env missing — run make env"
  user="$(env_value POSTGRES_USER)"
  db="$(env_value POSTGRES_DB)"
  pass="$(env_value POSTGRES_PASSWORD | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip(),safe=""))')"
  DATABASE_URI="postgresql://${user:-postgres}:${pass}@127.0.0.1:${port}/${db:-postgres}"
  export DATABASE_URI
  exec docker run --rm -i --init --network host -e DATABASE_URI "$POSTGRES_IMG" --access-mode=restricted
}

case "${1:-}" in
  grafana) run_grafana ;;
  postgres) run_postgres ;;
  *) die "usage: $0 <grafana|postgres>" ;;
esac
