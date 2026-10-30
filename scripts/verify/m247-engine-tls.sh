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
# Gate (G5a ADR 0011, G5b ADR 0012): an engine accepts TLS only when its own knob
# composes its overlay, and then serves a cert that verifies. Postgres: ENGINE_TLS=1
# and docker-compose.engine-tls.yml. The others: ENGINE_TLS_ENGINES lists them and
# docker-compose.engine-tls-<engine>.yml.
#
# Static (no stack): the default service has no ssl setting, the overlay mounts
# only certs/engines (never the CA key) and refuses a missing directory, the
# key goes to a tmpfs, and nothing that runs on every host mints the cert.
#
# Live (M247_LIVE=1, docker; M247_ENGINE=postgres|mongo, default postgres): three
# throwaway boots of the real service under compose project m247, each torn down
# with its volume. Postgres:
#   A  no overlay        → SHOW ssl = off (byte-identical default)
#   B  overlay + cert    → verify-full connects with pg_stat_ssl.ssl = t for its
#                          own pid; a name outside the SANs is refused; an explicit
#                          sslmode=disable still connects (accept mode); the key
#                          is 600 postgres on tmpfs and absent from PGDATA
#   C  overlay, no cert  → the container refuses to start and names the script
# Mongo: the same three legs with mongosh (verified --tls, a name outside the SANs,
# a default plaintext client), plus PID 1 running as uid 999, never root (G5b-C3).
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
ENGINE="${M247_ENGINE:-postgres}"
case "${ENGINE}" in
postgres) LIVE_OVERLAY="${OVERLAY}" ;;
mongo) LIVE_OVERLAY="orchestrators/compose/docker-compose.engine-tls-${ENGINE}.yml" ;;
*)
  printf 'M247_ENGINE=%s: expected postgres or mongo\n' "${ENGINE}" >&2
  exit 2
  ;;
esac

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
  g5b_static_checks
}

g5b_static_checks() {
  local cfg="${ROOT}/orchestrators/makes/00-config.mk" overlay name
  step "static: each other engine has its own knob, cert directory and privilege drop"
  grep -q 'foreach e,$(ENGINE_TLS_ENGINES), -f orchestrators/compose/docker-compose.engine-tls-$(e).yml' "${cfg}" ||
    fail "ENGINE_TLS_ENGINES does not compose the per-engine overlays"
  grep -q '$(filter 1,$(ENGINE_TLS)), -f orchestrators/compose/docker-compose.engine-tls.yml)' "${cfg}" ||
    fail "ENGINE_TLS=1 must compose the Postgres overlay only (G5b-C1)"
  for overlay in "${ROOT}"/orchestrators/compose/docker-compose.engine-tls-*.yml; do
    name="${overlay##*/docker-compose.engine-tls-}"
    name="${name%.yml}"
    # A sibling of Postgres's certs/engines, never inside another engine's mount (G5b-C5).
    grep -q "CERT_DIR:-./certs/engine-tls/${name}}" "${overlay}" || fail "${name}: the cert is not in its own directory"
    grep -q 'create_host_path: false' "${overlay}" || fail "${name}: the cert bind would be created root-owned"
    grep -q '/run/engine-tls:mode=0700' "${overlay}" || fail "${name}: the key copy is not on a 0700 tmpfs"
    grep -q "ENGINE_TLS_NAME: ${name}$" "${overlay}" || fail "${name}: the wrapper is not told which engine it runs"
    ! grep -Eqi "^ *- .*tls" <(sed -n "/^  ${name}:/,/^  [a-z]/p" "${ROOT}/orchestrators/compose/base/data-engines.yml") ||
      fail "the default ${name} service sets a TLS flag (G5b-C2)"
  done
  grep -q 'exec setpriv --reuid="$uid" --regid="$gid" --clear-groups' \
    "${ROOT}/infra/docker/services/engine-tls/drop-entrypoint.sh" || fail "the wrapper does not drop root (G5b-C3)"
  pass "per-engine overlays, sibling cert directories, root dropped before the engine starts"
}

# --- live -------------------------------------------------------------------

WORK=""
# The profile is on every call, not just `up`: `down` skips a profiled service it cannot
# see, so mongo outlived its leg and the next boot found it.
dc() {
  docker compose -p m247 --project-directory "${ROOT}" -f "${ROOT}/docker-compose.yml" --profile data-plane "$@"
}
down() { dc -f "${ROOT}/${LIVE_OVERLAY}" -f "${WORK}/rename.yml" down -v --remove-orphans >/dev/null 2>&1 || true; }
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
  dc "$@" -f "${WORK}/rename.yml" up -d --wait --wait-timeout 120 --no-build \
    --pull missing "${ENGINE}" >"${WORK}/up.log" 2>&1
}
boot_or_fail() { # $1 why, rest: extra -f files
  local why="$1"
  shift
  boot "$@" && return
  tail -5 "${WORK}/up.log" >&2
  docker logs --tail 10 "m247-${ENGINE}" >&2 2>&1 || true
  fail "${why}"
}

live_setup() {
  command -v docker >/dev/null || fail "M247_LIVE=1 needs docker"
  WORK="$(mktemp -d "${M247_TMP:-${TMPDIR:-/tmp}}/m247.XXXXXX")"
  trap cleanup EXIT
  # No host port and names of their own: never collides with a running stack.
  printf 'services:\n  %s:\n    container_name: m247-%s\n    ports: !reset []\n' "${ENGINE}" "${ENGINE}" >"${WORK}/rename.yml"
  [[ "${ENGINE}" != mongo ]] ||
    printf '  mongo-keyfile:\n    container_name: m247-mongo-keyfile\n' >>"${WORK}/rename.yml"
  # M247_SUBNET pins the throwaway network for a daemon whose default pools are spent.
  [[ -z "${M247_SUBNET:-}" ]] ||
    printf 'networks:\n  mini-baas:\n    ipam:\n      config:\n        - subnet: %s\n' "${M247_SUBNET}" >>"${WORK}/rename.yml"
}

# Mints the local CA and this engine's cert into WORK, never into certs/.
mint_cert() {
  TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
  TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="$1" \
    sh "${ROOT}/scripts/certs/generate-engine-cert.sh" "${ENGINE}" >/dev/null
}

refuses_without_cert() { # $1 the engine's cert directory, left empty
  step "live C: overlay without a cert → refuses to start"
  mkdir -p "$1"
  ! boot -f "${ROOT}/${LIVE_OVERLAY}" || fail "${ENGINE} started with TLS on and no cert"
  docker logs "m247-${ENGINE}" 2>&1 | grep -q 'generate-engine-cert.sh' || fail "the refusal does not name the cert script"
  pass "exit with the remedy in the log"
  down
}

postgres_live_checks() {
  live_setup
  PGPASSWORD="$(openssl rand -hex 16)"
  export PGPASSWORD POSTGRES_PASSWORD="${PGPASSWORD}" ENGINE_TLS_CERT_DIR="${WORK}/engines"

  step "live A: no overlay → plaintext only"
  boot_or_fail "the default postgres did not become healthy"
  [[ "$(psql_in sslmode=disable 'SHOW ssl')" == off ]] || fail "the default boot has ssl on"
  pass "SHOW ssl = off"
  down

  refuses_without_cert "${ENGINE_TLS_CERT_DIR}"

  step "live B: overlay + cert → accept-mode TLS that verifies"
  mint_cert "${ENGINE_TLS_CERT_DIR}"
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

# mongosh inside the server container as the root user; $1 the host, rest mongosh flags.
mongosh_in() {
  local host="$1"
  shift
  docker exec -e M247_MONGO_PW m247-mongo mongosh --quiet --host "${host}" -u mongo \
    --authenticationDatabase admin --eval "${MONGO_EVAL}" "$@" --password "${M247_MONGO_PW}"
}

mongo_live_checks() {
  live_setup
  M247_MONGO_PW="$(openssl rand -hex 16)"
  export M247_MONGO_PW MONGO_INITDB_ROOT_PASSWORD="${M247_MONGO_PW}" ENGINE_TLS_MONGO_CERT_DIR="${WORK}/mongo"
  local verify=(--tls --tlsCAFile /etc/engine-tls/ca.pem) opts='db.adminCommand({getCmdLineOpts: 1}).parsed.net.tls'
  MONGO_EVAL="EJSON.stringify(${opts} || null)"

  step "live A: no overlay → plaintext only"
  boot_or_fail "the default mongo did not become healthy"
  [[ "$(mongosh_in mongo)" == null ]] || fail "the default boot has TLS options"
  pass "no net.tls in getCmdLineOpts"
  down

  refuses_without_cert "${ENGINE_TLS_MONGO_CERT_DIR}"

  step "live B: overlay + cert → accept-mode TLS that verifies"
  mint_cert "${ENGINE_TLS_MONGO_CERT_DIR}"
  boot_or_fail "mongo with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(mongosh_in mongo "${verify[@]}")" == *'"mode":"allowTLS"'* ]] || fail "a verified --tls session failed"
  pass "verified --tls session against the CA, net.tls.mode = allowTLS"
  local refused
  refused="$(mongosh_in m247-mongo "${verify[@]}" 2>&1 || true)"
  [[ "${refused}" == *"Hostname/IP does not match"* || "${refused}" == *"does not match"* ]] ||
    fail "a name outside the SANs was not refused by verification: ${refused}"
  pass "a host name outside the SANs is refused"
  [[ "$(mongosh_in mongo)" == *'"mode":"allowTLS"'* ]] || fail "a default plaintext client is refused (accept mode must allow it)"
  pass "a default plaintext mongosh still connects"
  [[ "$(docker exec m247-mongo awk '/^Uid:/ {print $2}' /proc/1/status)" == 999 ]] || fail "PID 1 is not uid 999 (G5b-C3)"
  [[ "$(docker exec m247-mongo stat -c '%a %u' /run/engine-tls/server.key /run/engine-tls/server.pem | sort -u)" == "600 999" ]] ||
    fail "the key copies are not 600 uid 999"
  [[ -z "$(docker exec m247-mongo find /data/db -name '*.pem' -o -name '*.key')" ]] || fail "a key or cert landed in /data/db"
  pass "PID 1 is uid 999, keys are 600 uid 999 on tmpfs, nothing in /data/db"
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
if [[ "${M247_LIVE:-0}" == 1 ]]; then "${ENGINE}_live_checks"; else skip "live boots (M247_LIVE=1)"; fi
if [[ "${M247_STACK:-0}" == 1 ]]; then stack_checks; else skip "stack inventory (M247_STACK=1)"; fi
printf '\033[32m[M247] engine TLS gate green\033[0m\n'
