#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m27-conformance.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M27: the ENGINE CONFORMANCE battery
# (crates/engine-conformance). For each live engine it builds the matching
# EngineAdapter, drives it through its public EnginePool surface against the
# real database over the mini-baas network, and asserts the adapter serves
# EXACTLY what its EngineCapabilities descriptor advertises (crud, upsert,
# batch atomicity, aggregate, filtering, transactions, introspection,
# honesty) — skipping precisely what the descriptor says it lacks.
#
# This is the merge gate for NEW engines (Phase 3): an engine is "agnostic
# enough to ship" only when `make conformance-<engine>` is green here.
#
# Docker-first: cargo runs INSIDE the rust toolchain image (no host rustc),
# attached to the engine's network, with the DSN discovered from the running
# engine container (env + in-network alias) — never the caller's shell.
#
# Usage:
#   m27-conformance.sh                 # every wired engine (the gate)
#   m27-conformance.sh postgresql      # one engine (make conformance-postgresql)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
fail()  { red "[M27] FAIL: $*"; exit 1; }
step()  { cyan "[M27] ${*}"; }
pass()  { green "[M27] PASS: ${*}"; }
skip()  { yellow "[M27] SKIP: ${*}"; }

TOOLCHAIN_IMG="mini-baas-rust-toolchain"

env_of() { # $1 container, $2 var
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^$2=" | head -1 | cut -d= -f2-
}
container_up() { docker inspect "$1" >/dev/null 2>&1; }

# Engine → (container, in-network DSN). Echoes DSN, or empty if engine down.
dsn_for() {
  case "$1" in
    postgresql)
      container_up mini-baas-postgres || return 1
      local u p d
      u="$(env_of mini-baas-postgres POSTGRES_USER)"; u="${u:-postgres}"
      p="$(env_of mini-baas-postgres POSTGRES_PASSWORD)"; p="${p:-postgres}"
      d="$(env_of mini-baas-postgres POSTGRES_DB)"; d="${d:-postgres}"
      echo "postgres://${u}:${p}@postgres:5432/${d}" ;;
    mysql)
      container_up mini-baas-mysql || return 1
      local u p d
      u="$(env_of mini-baas-mysql MYSQL_USER)"; u="${u:-mini_baas}"
      p="$(env_of mini-baas-mysql MYSQL_PASSWORD)"; p="${p:-mini_baas_pw}"
      d="$(env_of mini-baas-mysql MYSQL_DATABASE)"; d="${d:-mini_baas}"
      echo "mysql://${u}:${p}@mysql:3306/${d}" ;;
    mariadb)
      container_up mini-baas-mariadb || return 1
      local u p d
      u="$(env_of mini-baas-mariadb MARIADB_USER)"; u="${u:-mini_baas}"
      p="$(env_of mini-baas-mariadb MARIADB_PASSWORD)"; p="${p:-mini_baas_pw}"
      d="$(env_of mini-baas-mariadb MARIADB_DATABASE)"; d="${d:-mini_baas}"
      echo "mysql://${u}:${p}@mariadb:3306/${d}" ;;
    mongodb)
      container_up mini-baas-mongo || return 1
      local u p
      u="$(env_of mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"; u="${u:-mongo}"
      p="$(env_of mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"; p="${p:-mongo}"
      echo "mongodb://${u}:${p}@mongo:27017/conformance?authSource=admin" ;;
    redis)
      container_up mini-baas-redis || return 1
      echo "redis://redis:6379" ;;
    cockroachdb)
      container_up mini-baas-cockroach || return 1
      # Insecure single-node: root, no password, sslmode=disable. The suite
      # qualifies its probe table to public.conf_probe (CRDB shares pg's
      # "$user", public search_path quirk).
      echo "postgres://root@cockroach:26257/defaultdb?sslmode=disable" ;;
    sqlite)
      # Embedded — no container. A fresh file inside the ephemeral conformance
      # container (bundled SQLite, so no system libsqlite3 needed).
      echo "sqlite:///tmp/conf-sqlite.db" ;;
    mssql)
      container_up mini-baas-mssql || return 1
      local p
      p="$(env_of mini-baas-mssql MSSQL_SA_PASSWORD)"; p="${p:-Mssql_Strong!Pass1}"
      echo "mssql://sa:${p}@mssql:1433/master" ;;
    *) return 2 ;;
  esac
}

# Network the engines share (discovered, not assumed).
NET="$(docker inspect mini-baas-postgres --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1)"
[[ -n "${NET}" ]] || fail "mini-baas network not found — is the stack up? (make up EDITION=query)"

ensure_toolchain() {
  docker image inspect "${TOOLCHAIN_IMG}" >/dev/null 2>&1 && return 0
  step "building the rust toolchain image (one-off, layer-cached)"
  printf 'FROM public.ecr.aws/docker/library/rust:1.89-slim-bookworm\nRUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' \
    | docker build -q -t "${TOOLCHAIN_IMG}" - >/dev/null
}

run_engine() { # $1 engine -> 0 green, 1 fail, 2 skip (engine down)
  local engine="$1" dsn rc out
  if ! dsn="$(dsn_for "${engine}")"; then
    return 2
  fi
  step "conformance: ${engine}"
  out="$(mktemp)"
  # Single run: the test (tests/conformance.rs) asserts green, so cargo's
  # exit code is the source of truth; we tee the report for the operator.
  set +e
  docker run --rm --network "${NET}" \
    -e CONFORMANCE_ENGINE="${engine}" \
    -e CONFORMANCE_DSN="${dsn}" \
    -e CONFORMANCE_TENANT="conf-${engine}" \
    -e DATA_PLANE_TLS_INSECURE=1 \
    -v "${ROUTER_DIR}":/work -w /work \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry \
    -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v mini-baas-dpr-target:/work/target \
    "${TOOLCHAIN_IMG}" \
    cargo test -p engine-conformance -- --nocapture >"${out}" 2>&1
  rc=$?
  set -e
  grep -E "conformance:|PASS |SKIP |FAIL |passed,|panicked" "${out}" || tail -5 "${out}"
  rm -f "${out}"
  return ${rc}
}

ensure_toolchain

# One engine (make conformance-<engine>) or all (the gate).
if [[ $# -ge 1 ]]; then
  ENGINES=("$1")
else
  # Always-on engines + engines-extra (mariadb/cockroachdb/mssql, skipped
  # cleanly when their profile isn't up — run_engine returns 2=skip).
  ENGINES=(postgresql mysql mariadb cockroachdb mongodb redis sqlite mssql)
fi

FAILED=0
RAN=0
for engine in "${ENGINES[@]}"; do
  set +e
  run_engine "${engine}"
  rc=$?
  set -e
  case "${rc}" in
    0) pass "${engine} conformance green"; RAN=$((RAN + 1)) ;;
    2) skip "${engine} not running — start it (make up EDITION=query) to gate it" ;;
    *) red "[M27] ${engine} conformance FAILED"; FAILED=$((FAILED + 1)) ;;
  esac
done

[[ "${FAILED}" == "0" ]] || fail "${FAILED} engine(s) failed conformance"
[[ "${RAN}" -gt 0 ]] || fail "no engines were reachable to gate (is the stack up?)"
green "[M27] ALL GATES GREEN — ${RAN} engine(s) conform to their descriptors"
