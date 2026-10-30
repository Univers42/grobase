#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m247-engine-tls.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 10:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 10:00:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #
#
# Gate (G5a, ADR 0011): the central Postgres accepts TLS only when ENGINE_TLS=1
# composes docker-compose.engine-tls.yml, and then serves a cert that verifies.
#
# Static (no stack): the default service has no ssl setting, the overlay mounts
# only certs/engines (never the CA key) and refuses a missing directory, the
# key goes to a tmpfs, and nothing that runs on every host mints the cert.
#
# Live (M247_LIVE=1, docker): three throwaway boots of the real postgres service
# under compose project m247, each torn down with its volume:
#   A  no overlay        → SHOW ssl = off (byte-identical default)
#   B  overlay + cert    → verify-full connects with pg_stat_ssl.ssl = t for its
#                          own pid; a name outside the SANs is refused; an explicit
#                          sslmode=disable still connects (accept mode); the key
#                          is 600 postgres on tmpfs and absent from PGDATA
#   C  overlay, no cert  → the container refuses to start and names the script
#
# Stack (M247_STACK=1, a running stack composed with ENGINE_TLS=1): which
# clients and walsenders negotiated TLS, by application_name, and every logical
# slot has a consumer on TLS whose walsender decodes past a probe WAL message.
#
# Caveat: the probe proves the server streamed past it over the encrypted
# session (pg_stat_replication.sent_lsn), not that the consumer acted on it:
# confirmed_flush_lsn only moves on a captured table (Debezium: outbox_events,
# no heartbeat), and the gate never writes one. A consumer that stalls after
# reading still passes; one that reconnects mid-probe can read as a FAIL.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OVERLAY="orchestrators/compose/docker-compose.engine-tls.yml"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ [M247] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
skip() { printf '  \033[33m- SKIP %s\033[0m\n' "$*"; }

static_checks() {
  local engines="${ROOT}/orchestrators/compose/base/data-engines.yml"
  step "static: TLS is opt-in and the cert is minted by nothing that runs anyway"
  ! grep -Eq 'ssl(=|_cert|_key)' "${engines}" || fail "the default postgres service sets ssl (G5a-C2)"
  grep -q 'docker-compose.engine-tls.yml)' "${ROOT}/orchestrators/makes/00-config.mk" ||
    fail "ENGINE_TLS=1 does not compose the overlay"
  grep -q 'create_host_path: false' "${ROOT}/${OVERLAY}" || fail "the cert bind would be created root-owned"
  grep -q 'ENGINE_TLS_CERT_DIR:-./certs/engines}' "${ROOT}/${OVERLAY}" || fail "the overlay must mount certs/engines only"
  ! grep -Eq 'source: \./certs/?$|ca-key' "${ROOT}/${OVERLAY}" || fail "the overlay exposes the CA key"
  grep -q '/run/engine-tls:mode=0700' "${ROOT}/${OVERLAY}" || fail "the key copy is not on a 0700 tmpfs (G5a-C3)"
  grep -q 'install -m 600 -o postgres' "${ROOT}/infra/docker/services/postgres/engine-tls-entrypoint.sh" ||
    fail "the entrypoint does not copy the key as 600 postgres"
  local caller
  for caller in scripts/ops/expose.sh orchestrators/makes/60-secrets.mk scripts/certs/generate-localhost-cert.sh; do
    ! grep -q 'generate-engine-cert' "${ROOT}/${caller}" || fail "${caller} mints the engine cert (G5a-C1)"
  done
  pass "default unchanged, overlay opt-in, CA key never mounted, cert minted on request only"
}

# --- live -------------------------------------------------------------------

WORK=""
dc() {
  docker compose -p m247 --project-directory "${ROOT}" -f "${ROOT}/docker-compose.yml" "$@"
}
down() { dc -f "${ROOT}/${OVERLAY}" -f "${WORK}/rename.yml" down -v --remove-orphans >/dev/null 2>&1 || true; }
cleanup() {
  [[ -z "${WORK}" ]] && return
  down
  rm -rf "${WORK}"
}

# psql inside the server container, so the client dials the in-network name.
psql_in() { # $1 conninfo tail, $2 sql
  docker exec -e PGPASSWORD m247-postgres psql -X -At \
    "host=${HOST:-postgres} user=postgres dbname=postgres connect_timeout=5 $1" -c "$2"
}

boot() { # $@ extra -f files; compose's output goes to up.log
  dc "$@" -f "${WORK}/rename.yml" up -d --wait --wait-timeout 120 --no-build --pull missing postgres \
    >"${WORK}/up.log" 2>&1
}
boot_or_fail() { # $1 why, rest: extra -f files
  local why="$1"
  shift
  boot "$@" && return
  tail -5 "${WORK}/up.log" >&2
  docker logs --tail 10 m247-postgres >&2 2>&1 || true
  fail "${why}"
}

live_checks() {
  command -v docker >/dev/null || fail "M247_LIVE=1 needs docker"
  WORK="$(mktemp -d "${M247_TMP:-${TMPDIR:-/tmp}}/m247.XXXXXX")"
  trap cleanup EXIT
  # No host port and a name of its own: never collides with a running stack.
  printf 'services:\n  postgres:\n    container_name: m247-postgres\n    ports: !reset []\n' >"${WORK}/rename.yml"
  # M247_SUBNET pins the throwaway network for a daemon whose default pools are spent.
  [[ -z "${M247_SUBNET:-}" ]] ||
    printf 'networks:\n  mini-baas:\n    ipam:\n      config:\n        - subnet: %s\n' "${M247_SUBNET}" >>"${WORK}/rename.yml"
  PGPASSWORD="$(openssl rand -hex 16)"
  export PGPASSWORD POSTGRES_PASSWORD="${PGPASSWORD}" ENGINE_TLS_CERT_DIR="${WORK}/engines"

  step "live A: no overlay → plaintext only"
  boot_or_fail "the default postgres did not become healthy"
  [[ "$(psql_in sslmode=disable 'SHOW ssl')" == off ]] || fail "the default boot has ssl on"
  pass "SHOW ssl = off"
  down

  step "live C: overlay without a cert → refuses to start"
  mkdir -p "${ENGINE_TLS_CERT_DIR}"
  ! boot -f "${ROOT}/${OVERLAY}" || fail "postgres started with ENGINE_TLS=1 and no cert"
  docker logs m247-postgres 2>&1 | grep -q 'generate-engine-cert.sh' || fail "the refusal does not name the cert script"
  pass "exit with the remedy in the log"
  down

  step "live B: overlay + cert → accept-mode TLS that verifies"
  TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
  TRACK_BINOCLE_CERT_DIR="${WORK}" sh "${ROOT}/scripts/certs/generate-engine-cert.sh" >/dev/null
  boot_or_fail "postgres with the engine cert did not become healthy" -f "${ROOT}/${OVERLAY}"
  local verify="sslmode=verify-full sslrootcert=/etc/engine-tls/ca.pem"
  [[ "$(psql_in "${verify}" 'SHOW ssl')" == on ]] || fail "SHOW ssl is not on"
  [[ "$(psql_in "${verify}" 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')" == t ]] ||
    fail "a verify-full session is not encrypted"
  pass "verify-full against the CA, pg_stat_ssl.ssl = t for its own pid"
  # The container name resolves but is not a SAN, so only verification can refuse it.
  local refused
  refused="$(HOST=m247-postgres psql_in "${verify}" 'SELECT 1' 2>&1 || true)"
  [[ "${refused}" == *"does not match host name"* ]] ||
    fail "a name outside the SANs was not refused by verification: ${refused}"
  pass "a host name outside the SANs is refused"
  [[ "$(psql_in sslmode=disable 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')" == f ]] ||
    fail "an explicit sslmode=disable client is refused (accept mode must allow it)"
  pass "explicit sslmode=disable still connects, unencrypted"
  [[ "$(docker exec m247-postgres stat -c '%a %U' /run/engine-tls/server.key)" == "600 postgres" ]] ||
    fail "the key copy is not 600 postgres"
  [[ -z "$(docker exec m247-postgres find /var/lib/postgresql/data -name '*.key' -o -name '*.pem')" ]] ||
    fail "a key or cert landed in PGDATA"
  pass "key is 600 postgres on tmpfs, nothing in PGDATA"
}

# --- stack ------------------------------------------------------------------

stack_checks() {
  local pg="${M247_PG_CONTAINER:-mini-baas-postgres}" user slots probe waited=0 behind
  user="$(docker exec "${pg}" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
  sql() { docker exec "${pg}" psql -X -At -U "${user}" -d postgres -c "$1"; }
  step "stack: who negotiated TLS on ${pg}"
  [[ "$(sql 'SHOW ssl')" == on ]] || fail "${pg} is not composed with ENGINE_TLS=1"
  sql "SELECT a.backend_type || ' ' || coalesce(nullif(application_name, ''), '(unnamed)') || ' '
         || client_addr || ' ssl=' || s.ssl || coalesce(' ' || s.version, '')
       FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid)
       WHERE a.backend_type IN ('client backend', 'walsender') AND client_addr IS NOT NULL
       ORDER BY 1" | sed 's/^/    /'
  step "stack: every logical slot streams over TLS past a probe"
  slots="$(sql "SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical'")"
  ((slots > 0)) || {
    skip "no logical slot on this stack"
    return
  }
  [[ "$(sql "SELECT count(*) FROM pg_replication_slots r JOIN pg_stat_ssl s ON s.pid = r.active_pid
             WHERE r.slot_type = 'logical' AND r.active AND s.ssl")" == "${slots}" ]] ||
    fail "a logical slot has no consumer, or its consumer is not on TLS"
  probe="$(sql "SELECT pg_logical_emit_message(false, 'm247', 'probe')")"
  while :; do
    behind="$(sql "SELECT count(*) FROM pg_replication_slots r
                   LEFT JOIN pg_stat_replication w ON w.pid = r.active_pid
                   WHERE r.slot_type = 'logical' AND coalesce(w.sent_lsn < '${probe}', true)")"
    [[ "${behind}" == 0 ]] && break
    ((waited < ${M247_SLOT_WAIT:-15})) || fail "${behind} slot(s) did not decode past ${probe} in ${waited}s"
    sleep 1
    waited=$((waited + 1))
  done
  pass "${slots} logical slot(s) active on TLS, decoded past ${probe} in ${waited}s"
}

static_checks
if [[ "${M247_LIVE:-0}" == 1 ]]; then live_checks; else skip "live boots (M247_LIVE=1)"; fi
if [[ "${M247_STACK:-0}" == 1 ]]; then stack_checks; else skip "stack inventory (M247_STACK=1)"; fi
printf '\033[32m[M247] engine TLS gate green\033[0m\n'
