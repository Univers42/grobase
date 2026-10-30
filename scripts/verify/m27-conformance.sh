#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m27-conformance.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 03:50:00 by dlesieur         ###   ########.fr        #
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
# sqlite, http and dynamodb need no stack: sqlite is a file inside the run,
# http talks to a throwaway REST upstream (http-conformance-upstream.py) and
# dynamodb to a throwaway in-memory dynamodb-local, both on a private network
# removed on exit — so CI gates them per PR with no stack up.
#
# Usage:
#   m27-conformance.sh                 # every wired engine (the gate)
#   m27-conformance.sh postgresql      # one engine (make conformance-postgresql)
#
# mssql over a verified pool (ADR 0027): M27_MSSQL_TLS_CA=<the engine's ca.pem> runs it with
# DATA_PLANE_TLS_INSECURE=0 and that CA pinned; adding M27_MSSQL_EXPECT=refused inverts the leg,
# so it passes only when the pinned run cannot connect while the escape run on the same server
# is green. Unset, mssql keeps the escape (INSECURE=1), as before.
# M27_TARGET (a volume or host path) holds cargo's target dir instead of mini-baas-dpr-target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROUTER_DIR="${BAAS_DIR}/src/data-plane-router"
# shellcheck source=../lib/lib-crdb-client.sh
. "${BAAS_DIR}/scripts/lib/lib-crdb-client.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
fail() {
  red "[M27] FAIL: $*"
  exit 1
}
step() { cyan "[M27] ${*}"; }
pass() { green "[M27] PASS: ${*}"; }
skip() { yellow "[M27] SKIP: ${*}"; }

TOOLCHAIN_IMG="mini-baas-rust-toolchain"
PY_IMAGE="${M27_PY_IMAGE:-python:3.12-alpine}"
DDB_IMAGE="${M27_DDB_IMAGE:-amazon/dynamodb-local:latest}"
AWS_CLI_IMAGE="${M27_AWS_CLI_IMAGE:-amazon/aws-cli:latest}"
HTTP_UPSTREAM="m27-http-upstream-$$"
DDB="m27-dynamodb-$$"
# Plain HTTP on purpose: both throwaway upstreams have no TLS listener and are
# reachable only on this run's docker network (TLS upstream: grobase#67).
HTTP_UPSTREAM_URL="http://${HTTP_UPSTREAM}:8080"
DDB_ENDPOINT="http://${DDB}:8000"
OWN_NET=""
STACK_FREE=" sqlite http dynamodb "

cleanup() {
  docker rm -f "${HTTP_UPSTREAM}" "${DDB}" >/dev/null 2>&1 || true
  [[ -z "${OWN_NET}" ]] || docker network rm "${OWN_NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

env_of() { # $1 container, $2 var
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    grep "^$2=" | head -1 | cut -d= -f2-
}
container_up() {
  # An engine counts as "up" only if it is RUNNING, not restarting, and (when it
  # declares a healthcheck) HEALTHY. This makes the gate honestly SKIP engines
  # that are down/crash-looping/unhealthy (e.g. a DB with drifted creds) rather
  # than fail trying to connect to one that cannot serve.
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] || return 1
  [ "$(docker inspect -f '{{.State.Restarting}}' "$1" 2>/dev/null)" = "false" ] || return 1
  [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "$1" 2>/dev/null)" = "healthy" ]
}

# Engine → (container, in-network DSN). Echoes DSN, or empty if engine down.
dsn_for() {
  case "$1" in
  postgresql)
    container_up mini-baas-postgres || return 1
    local u p d
    u="$(env_of mini-baas-postgres POSTGRES_USER)"
    u="${u:-postgres}"
    p="$(env_of mini-baas-postgres POSTGRES_PASSWORD)"
    p="${p:-postgres}"
    d="$(env_of mini-baas-postgres POSTGRES_DB)"
    d="${d:-postgres}"
    # M27_PG_TLS_CA (the engine CA, ADR 0011) runs the pool over verify-full.
    echo "postgres://${u}:${p}@postgres:5432/${d}${M27_PG_TLS_CA:+?sslmode=verify-full}"
    ;;
  mysql)
    container_up mini-baas-mysql || return 1
    local u p d
    u="$(env_of mini-baas-mysql MYSQL_USER)"
    u="${u:-mini_baas}"
    p="$(env_of mini-baas-mysql MYSQL_PASSWORD)"
    p="${p:-mini_baas_pw}"
    d="$(env_of mini-baas-mysql MYSQL_DATABASE)"
    d="${d:-mini_baas}"
    echo "mysql://${u}:${p}@mysql:3306/${d}"
    ;;
  mysql8)
    container_up mini-baas-mysql8 || return 1
    local u p d
    u="$(env_of mini-baas-mysql8 MYSQL_USER)"
    u="${u:-mini_baas}"
    p="$(env_of mini-baas-mysql8 MYSQL_PASSWORD)"
    p="${p:-mini_baas_pw}"
    d="$(env_of mini-baas-mysql8 MYSQL_DATABASE)"
    d="${d:-mini_baas}"
    echo "mysql://${u}:${p}@mysql8:3306/${d}"
    ;;
  mariadb)
    container_up mini-baas-mariadb || return 1
    local u p d
    u="$(env_of mini-baas-mariadb MARIADB_USER)"
    u="${u:-mini_baas}"
    p="$(env_of mini-baas-mariadb MARIADB_PASSWORD)"
    p="${p:-mini_baas_pw}"
    d="$(env_of mini-baas-mariadb MARIADB_DATABASE)"
    d="${d:-mini_baas}"
    echo "mysql://${u}:${p}@mariadb:3306/${d}"
    ;;
  mongodb)
    container_up mini-baas-mongo || return 1
    local u p
    u="$(env_of mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)"
    u="${u:-mongo}"
    p="$(env_of mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"
    p="${p:-mongo}"
    echo "mongodb://${u}:${p}@mongo:27017/conformance?authSource=admin"
    ;;
  redis)
    container_up mini-baas-redis || return 1
    echo "redis://redis:6379"
    ;;
  cockroachdb)
    container_up mini-baas-cockroach || return 1
    # root with its password when one exists (secure mode refuses passwordless root; an
    # insecure node ignores it, ADR 0029); M27_PG_TLS_CA runs the pool over verify-full.
    # The suite qualifies its probe table to public.conf_probe (CRDB shares pg's
    # "$user", public search_path quirk).
    crdb_dsn mini-baas-cockroach defaultdb "${M27_PG_TLS_CA:+verify-full}"
    ;;
  sqlite)
    # Embedded — no container. A fresh file inside the ephemeral conformance
    # container (bundled SQLite, so no system libsqlite3 needed).
    echo "sqlite:///tmp/conf-sqlite.db"
    ;;
  mssql)
    container_up mini-baas-mssql || return 1
    local p
    p="$(env_of mini-baas-mssql MSSQL_SA_PASSWORD)"
    p="${p:-Mssql_Strong!Pass1}"
    echo "mssql://sa:${p}@mssql:1433/master"
    ;;
  http)
    start_http_upstream || return 3
    echo "{\"baseUrl\":\"${HTTP_UPSTREAM_URL}\"}" # NOSONAR(S5332) grobase#67
    ;;
  dynamodb)
    start_dynamodb || return 3
    echo "dynamodb://local?endpoint=${DDB_ENDPOINT}&region=us-east-1&access_key=fake&secret_key=fake" # NOSONAR(S5332) grobase#67
    ;;
  *) return 2 ;;
  esac
}

start_http_upstream() {
  docker run -d --rm --name "${HTTP_UPSTREAM}" --network "${NET}" \
    -v "${SCRIPT_DIR}/http-conformance-upstream.py:/upstream.py:ro" \
    "${PY_IMAGE}" python /upstream.py >/dev/null || return 1
  local _
  for _ in $(seq 1 40); do
    docker exec "${HTTP_UPSTREAM}" python -c 'import socket; socket.create_connection(("127.0.0.1", 8080), 1)' \
      >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

ddb_cli() {
  local aws_env=(-e AWS_ACCESS_KEY_ID=fake -e AWS_SECRET_ACCESS_KEY=fake -e AWS_DEFAULT_REGION=us-east-1)
  docker run --rm --network "${NET}" "${aws_env[@]}" "${AWS_CLI_IMAGE}" dynamodb "$@" --endpoint-url "${DDB_ENDPOINT}" # NOSONAR(S5332) grobase#67
}

# The adapter keys every item on owner_pk (HASH) + id (RANGE) and creates no
# table itself, so the scratch table is made here. create-table retries double
# as the readiness wait.
start_dynamodb() {
  docker run -d --rm --name "${DDB}" --network "${NET}" \
    "${DDB_IMAGE}" -jar DynamoDBLocal.jar -inMemory >/dev/null || return 1
  local _
  for _ in $(seq 1 30); do
    ddb_cli create-table --table-name conf_probe \
      --attribute-definitions AttributeName=owner_pk,AttributeType=S AttributeName=id,AttributeType=S \
      --key-schema AttributeName=owner_pk,KeyType=HASH AttributeName=id,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Network the engines share (discovered, not assumed). Under the netseg overlay postgres
# is on net-data and net-meta; net-data is where every engine and its clients meet.
# M27_NET pins the network (a host whose docker address pools are exhausted).
# Any running engine names it: CI's per-engine matrix starts only the engine it gates.
NET="${M27_NET:-}"
for c in postgres mysql mysql8 mariadb mongo redis cockroach mssql; do
  [[ -z "${NET}" ]] || break
  NET="$(docker inspect "mini-baas-${c}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null |
    awk 'NF && !f {f = $0} /net-data$/ {d = $0} END {print (d != "" ? d : f)}' || true)"
done
# One engine (make conformance-<engine>) or all (the gate).
if [[ $# -ge 1 ]]; then
  ENGINES=("$1")
else
  # Always-on engines + engines-extra (mariadb/cockroachdb/mssql, skipped
  # cleanly when their profile isn't up — run_engine returns 2=skip).
  ENGINES=(postgresql mysql mysql8 mariadb cockroachdb mongodb redis sqlite mssql http dynamodb)
fi

if [[ -z "${NET}" ]]; then
  for engine in "${ENGINES[@]}"; do
    [[ "${STACK_FREE}" == *" ${engine} "* ]] ||
      fail "mini-baas network not found — is the stack up? (make up EDITION=query)"
  done
  OWN_NET="m27net-$$"
  NET="${OWN_NET}"
  docker network create "${NET}" >/dev/null || fail "could not create ${NET}"
fi

ensure_toolchain() {
  docker image inspect "${TOOLCHAIN_IMG}" >/dev/null 2>&1 && return 0
  step "building the rust toolchain image (one-off, layer-cached)"
  printf 'FROM mirror.gcr.io/library/rust:1.96-slim-bookworm@sha256:e18a79fc84dfcfc3ab5ba72290398a644c135c97eaa881447fddc354ee4701a3\nRUN rustup component add clippy rustfmt && apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' |
    docker build -q -t "${TOOLCHAIN_IMG}" - >/dev/null
}

run_engine() { # $1 engine -> 0 green, 1 fail, 2 skip (engine down)
  local engine="$1" dsn rc out
  # 3 = a scratch upstream this script owns failed to start: a failure, not a skip.
  dsn="$(dsn_for "${engine}")" || {
    rc=$?
    [[ ${rc} -eq 3 ]] && red "[M27] ${engine}: scratch upstream did not start" && return 1
    return 2
  }
  [[ "${engine}" != mssql || "${M27_MSSQL_EXPECT:-}" != refused ]] || mssql_escape_control || return 1
  step "conformance: ${engine}"
  out="$(mktemp)"
  local features=() extra_env=() pool_engine="${engine}" insecure=1
  # mysql8 is Oracle MySQL behind the same `mysql` pool descriptor as the MariaDB service.
  [[ "${engine}" != mysql8 ]] || pool_engine=mysql
  [[ "${engine}" != dynamodb ]] || features=(--features dynamodb)
  [[ "${engine}" != http ]] || extra_env=(-e DATA_PLANE_HTTP_ALLOW_INTERNAL=1)
  [[ "${engine}" != postgresql && "${engine}" != cockroachdb || -z "${M27_PG_TLS_CA:-}" ]] ||
    extra_env=(-v "${M27_PG_TLS_CA}":/run/m27-ca.pem:ro -e DATA_PLANE_TLS_CA_FILE=/run/m27-ca.pem)
  if [[ "${engine}" == mssql && -n "${M27_MSSQL_TLS_CA:-}" ]]; then
    insecure=0
    extra_env=(-v "${M27_MSSQL_TLS_CA}":/run/m27-ca.pem:ro -e DATA_PLANE_TLS_CA_FILE=/run/m27-ca.pem)
  fi
  # Single run: the test (tests/conformance.rs) asserts green, so cargo's
  # exit code is the source of truth; we tee the report for the operator.
  set +e
  docker run --rm --network "${NET}" \
    -e CONFORMANCE_ENGINE="${pool_engine}" \
    -e CONFORMANCE_DSN="${dsn}" \
    -e CONFORMANCE_TENANT="conf-${engine}" \
    -e DATA_PLANE_TLS_INSECURE="${insecure}" \
    "${extra_env[@]}" \
    -v "${ROUTER_DIR}":/work -w /work \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry \
    -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v "${M27_TARGET:-mini-baas-dpr-target}":/work/target \
    "${TOOLCHAIN_IMG}" \
    cargo test -p engine-conformance "${features[@]}" -- --nocapture >"${out}" 2>&1
  rc=$?
  set -e
  grep -E "conformance:|PASS |SKIP |FAIL |passed,|panicked" "${out}" || tail -5 "${out}"
  if [[ "${engine}" == mssql && "${M27_MSSQL_EXPECT:-}" == refused ]]; then
    if mssql_refused "${rc}" "${out}"; then rc=0; else rc=1; fi
  fi
  rm -f "${out}"
  [[ ${rc} -eq 0 && "${engine}" == mysql8 ]] && { mysql8_is_oracle || return 1; }
  return ${rc}
}

# M27_MSSQL_EXPECT=refused (ADR 0027 D5): the pinned-CA run must fail at its first checkout.
# Caveat: bb8 reports every dial error as "Timed out in bb8" (no error sink), so the output
# cannot name the certificate. mssql_escape_control runs first on the same server and DSN with
# only the trust changed; a refusal after a green control is the cert. Wrong direction: a server
# that dies between the two runs reads as a refusal (a false pass), so the leg runs them back to back.
mssql_escape_control() {
  step "control: the same mssql with the escape on (INSECURE=1) must be green"
  M27_MSSQL_TLS_CA='' M27_MSSQL_EXPECT='' run_engine mssql && return 0
  red "[M27] mssql control (INSECURE=1) failed: a refusal after it would prove nothing"
  return 1
}
mssql_refused() { # $1 cargo's exit code, $2 its output
  if [[ "$1" -ne 0 ]] && grep -q 'bootstrap: create scratch: backend error: mssql checkout failed: Timed out in bb8' "$2"; then
    pass "mssql: the pinned CA refuses the server cert, the escape on the same server is green"
    return 0
  fi
  red "[M27] mssql was not refused at checkout under the pinned CA (cargo exit $1)"
  return 1
}

# Load-bearing: a MariaDB image under the mysql8 name would pass the battery and prove nothing.
mysql8_is_oracle() {
  local version
  version="$(docker exec mini-baas-mysql8 mysqld --version 2>&1)" || version=""
  if [[ "${version}" == *"MySQL Community Server"* && "${version}" != *MariaDB* ]]; then
    pass "mysql8 is Oracle MySQL: ${version##*Ver }"
    return 0
  fi
  red "[M27] mysql8 is not Oracle MySQL Community Server: ${version:-no mysqld --version}"
  return 1
}

ensure_toolchain

FAILED=0
RAN=0
for engine in "${ENGINES[@]}"; do
  set +e
  run_engine "${engine}"
  rc=$?
  set -e
  case "${rc}" in
  0)
    pass "${engine} conformance green"
    RAN=$((RAN + 1))
    ;;
  2) skip "${engine} not running — start it (make up EDITION=query) to gate it" ;;
  *)
    red "[M27] ${engine} conformance FAILED"
    FAILED=$((FAILED + 1))
    ;;
  esac
done

[[ "${FAILED}" == "0" ]] || fail "${FAILED} engine(s) failed conformance"
[[ "${RAN}" -gt 0 ]] || fail "no engines were reachable to gate (is the stack up?)"
green "[M27] ALL GATES GREEN — ${RAN} engine(s) conform to their descriptors"
