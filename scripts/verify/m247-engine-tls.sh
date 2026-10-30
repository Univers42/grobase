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
# Live (M247_LIVE=1, docker; M247_ENGINE=postgres|mongo|redis|mariadb|mysql|mssql, default postgres): three
# throwaway boots of the real service under compose project m247, each torn down
# with its volume. Postgres:
#   A  no overlay        → SHOW ssl = off (byte-identical default)
#   B  overlay + cert    → verify-full connects with pg_stat_ssl.ssl = t for its
#                          own pid; a name outside the SANs is refused; an explicit
#                          sslmode=disable still connects (accept mode); the key
#                          is 600 postgres on tmpfs and absent from PGDATA
#   C  overlay, no cert  → the container refuses to start and names the script
# Mongo: the same three legs with mongosh (verified --tls, a name outside the SANs,
# a default plaintext client), plus PID 1 running as uid 999, never root (G5b-C3), and
#   D  requireTLS + clients → mongo-init, mongo-api, realtime, the orchestrator's driver and
#                          engine-backup all verify the cert (engine-tls-mongo-clients-live.sh).
# M247_MONGO_LEGS=ABC or D runs half (CI splits them); the static mongo-client checks always run.
# M247_PROJECT (default m247) names the compose project, for a second run on the same daemon.
# Redis: the same with redis-cli on 6380 (verified --tls, a name outside the SANs, plaintext
# refused there) while 6379 stays plaintext, and PID 1 as uid 100.
# MariaDB: leg A finds the default already on TLS with a cert our CA does not sign; B swaps
# in the engine cert (verified session, SAN legs via openssl -starttls mysql, --skip-ssl
# still connects) and PID 1 runs as uid 100. The mysql service is MariaDB too: the same legs.
# MSSQL: leg A finds a self-signed cert a CA-trusting sqlcmd refuses; B serves the engine cert
# (verified -N m session, a name outside the SANs refused, an unencrypted client still in)
# and PID 1 runs as the image's mssql user; the render shows the overlay alone sets the data plane's
# INSECURE=0 (ADR 0027). MySQL 8 (Oracle, ADR 0026): scripts/lib/lib-m247-mysql8.sh.
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
# shellcheck source=engine-tls-mongo-clients.sh
. "${ROOT}/scripts/verify/engine-tls-mongo-clients.sh"
# shellcheck source=engine-tls-mongo-clients-live.sh
. "${ROOT}/scripts/verify/engine-tls-mongo-clients-live.sh"
OVERLAY="orchestrators/compose/docker-compose.engine-tls.yml"
ENGINE="${M247_ENGINE:-postgres}"
case "${ENGINE}" in
postgres) LIVE_OVERLAY="${OVERLAY}" ;;
mongo | redis | mariadb | mysql | mysql8 | mssql) LIVE_OVERLAY="orchestrators/compose/docker-compose.engine-tls-${ENGINE}.yml" ;;
*)
  printf 'M247_ENGINE=%s: expected postgres, mongo, redis, mariadb, mysql, mysql8 or mssql\n' "${ENGINE}" >&2
  exit 2
  ;;
esac
case "${ENGINE}" in
mariadb | mssql) PROFILE="engines-extra" ;;
mysql8) PROFILE=mysql8 ;;
*) PROFILE=data-plane ;;
esac

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ [M247] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
skip() { printf '  \033[33m- SKIP %s\033[0m\n' "$*"; }
# shellcheck source=../lib/lib-m247-mysql8.sh
. "${ROOT}/scripts/lib/lib-m247-mysql8.sh"
# shellcheck source=../lib/lib-m247-mssql-plane.sh
. "${ROOT}/scripts/lib/lib-m247-mssql-plane.sh"

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
  mysql8_static_checks
  mssql_plane_static_checks
  mongo_clients_static_checks
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
    ! grep -Eqi -- "--tls|--ssl|^ *- .*tls" <(sed -n "/^  ${name}:/,/^  [a-z]/p" \
      "${ROOT}/orchestrators/compose/base/data-engines.yml" "${ROOT}/orchestrators/compose/base/engines-extra.yml") ||
      fail "the default ${name} service sets a TLS flag (G5b-C2)"
  done
  grep -q 'exec setpriv --reuid="$uid" --regid="$gid" --clear-groups' \
    "${ROOT}/infra/docker/services/engine-tls/drop-entrypoint.sh" || fail "the wrapper does not drop root (G5b-C3)"
  ! grep -q '^    ports:' "${ROOT}/orchestrators/compose/docker-compose.engine-tls-redis.yml" ||
    fail "redis publishes its TLS port (G5b-C6: in-network only)"
  pass "per-engine overlays, sibling cert directories, root dropped before the engine starts"
}

# --- live -------------------------------------------------------------------

WORK=""
# The profile is on every call, not just `up`: `down` skips a profiled service it cannot
# see, so mongo outlived its leg and the next boot found it. M247_PROJECT keeps two runs on one
# daemon apart: `down --remove-orphans` removes every container of its project.
M247_PROJECT="${M247_PROJECT:-m247}"
NETWORK="${M247_PROJECT}_mini-baas"
dc() {
  docker compose -p "${M247_PROJECT}" --project-directory "${ROOT}" -f "${ROOT}/docker-compose.yml" --profile "${PROFILE}" "$@"
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
  # M247_IMAGE tests a local build without retagging the image a running stack uses.
  [[ -z "${M247_IMAGE:-}" ]] || printf '    image: %s\n' "${M247_IMAGE}" >>"${WORK}/rename.yml"
  [[ "${ENGINE}" != mongo ]] ||
    printf '  mongo-keyfile:\n    container_name: m247-mongo-keyfile\n' >>"${WORK}/rename.yml"
  # M247_SUBNET pins the throwaway network for a daemon whose default pools are spent.
  [[ -z "${M247_SUBNET:-}" ]] ||
    printf 'networks:\n  mini-baas:\n    ipam:\n      config:\n        - subnet: %s\n' "${M247_SUBNET}" >>"${WORK}/rename.yml"
}

# The local CA and this engine's cert go into WORK, never into certs/.
mint_ca() {
  TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
}
mint_cert() {
  mint_ca
  TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="$1" \
    sh "${ROOT}/scripts/certs/generate-engine-cert.sh" "${ENGINE}" >/dev/null
}

refuses_without_cert() { # $1 the engine's cert directory, left empty
  step "live C: overlay without a cert → refuses to start"
  mkdir -p "$1"
  ! boot -f "${ROOT}/${LIVE_OVERLAY}" || fail "${ENGINE} started with TLS on and no cert"
  # compose can report the failure before the exited container's log is readable
  # (redis, CI run 40990129485), so the remedy line gets a few seconds to appear.
  # The log is read whole first: under pipefail `docker logs | grep -q` reads 141 once grep
  # quits early, so a restarting engine's repeated refusal read as a miss (CI run 41010336246).
  local _ logs=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    logs="$(docker logs "m247-${ENGINE}" 2>&1)" || true
    grep -qF 'generate-engine-cert.sh' <<<"${logs}" && break
    sleep 1
  done
  if ! grep -qF 'generate-engine-cert.sh' <<<"${logs}"; then
    tail -5 "${WORK}/up.log" >&2
    docker logs --tail 10 "m247-${ENGINE}" >&2 2>&1 || true
    fail "the refusal does not name the cert script"
  fi
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

# M247_MONGO_LEGS: ABCD (default), ABC (the server legs) or D (requireTLS with the clients).
mongo_live_checks() {
  local legs="${M247_MONGO_LEGS:-ABCD}"
  [[ "${legs}" =~ ^(ABCD|ABC|D)$ ]] || fail "M247_MONGO_LEGS=${legs}: expected ABCD, ABC or D"
  live_setup
  M247_MONGO_PW="$(openssl rand -hex 16)"
  export M247_MONGO_PW MONGO_INITDB_ROOT_PASSWORD="${M247_MONGO_PW}" ENGINE_TLS_MONGO_CERT_DIR="${WORK}/mongo"
  MONGO_EVAL="EJSON.stringify(db.adminCommand({getCmdLineOpts: 1}).parsed.net.tls || null)"
  [[ "${legs}" != ABC* ]] || mongo_server_legs
  [[ "${legs}" != *D ]] || mongo_clients_live_checks
}

mongo_server_legs() {
  step "live A: no overlay → plaintext only"
  boot_or_fail "the default mongo did not become healthy"
  [[ "$(mongosh_in mongo)" == null ]] || fail "the default boot has TLS options"
  pass "no net.tls in getCmdLineOpts"
  down

  refuses_without_cert "${ENGINE_TLS_MONGO_CERT_DIR}"
  mongo_leg_b
}

mongo_leg_b() {
  local verify=(--tls --tlsCAFile /etc/engine-tls/ca.pem) refused
  step "live B: overlay + cert → accept-mode TLS that verifies"
  mint_cert "${ENGINE_TLS_MONGO_CERT_DIR}"
  boot_or_fail "mongo with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(mongosh_in mongo "${verify[@]}")" == *'"mode":"allowTLS"'* ]] || fail "a verified --tls session failed"
  pass "verified --tls session against the CA, net.tls.mode = allowTLS"
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

# redis-cli inside the server container; $1 the host, rest redis-cli flags then the command.
redis_in() {
  local host="$1"
  shift
  docker exec m247-redis redis-cli -h "${host}" "$@"
}

# openssl s_client to m247-redis:6380 verifying the host name $1 against the minted CA.
redis_tls_as() {
  local ip
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' m247-redis)"
  timeout 10 openssl s_client -connect "${ip}:6380" -CAfile "${ENGINE_TLS_REDIS_CERT_DIR}/ca.pem" \
    -verify_hostname "$1" -verify_return_error </dev/null 2>&1 || true
}

redis_live_checks() {
  live_setup
  export ENGINE_TLS_REDIS_CERT_DIR="${WORK}/redis"
  local verify=(-p 6380 --tls --cacert /etc/engine-tls/ca.pem) out

  step "live A: no overlay → plaintext only"
  boot_or_fail "the default redis did not become healthy"
  [[ "$(redis_in redis CONFIG GET tls-port | tail -1)" == 0 ]] || fail "the default boot listens for TLS"
  pass "tls-port 0"
  down

  refuses_without_cert "${ENGINE_TLS_REDIS_CERT_DIR}"

  step "live B: overlay + cert → TLS on 6380 that verifies, 6379 unchanged"
  mint_cert "${ENGINE_TLS_REDIS_CERT_DIR}"
  boot_or_fail "redis with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(redis_in redis "${verify[@]}" PING)" == PONG ]] || fail "a verified --tls PING on 6380 failed"
  pass "verified --tls PING on 6380 against the CA"
  # redis-cli checks the chain but never the host name (hiredis), so the SAN legs use
  # openssl from the host against the container's address.
  [[ "$(redis_tls_as redis)" == *"Verify return code: 0 (ok)"* ]] || fail "openssl could not verify redis as host redis"
  out="$(redis_tls_as m247-redis)"
  [[ "${out}" == *"hostname mismatch"* ]] || fail "a name outside the SANs was not refused by verification"
  pass "the served cert verifies as redis, and a host name outside the SANs is refused"
  [[ "$(redis_in redis PING)" == PONG ]] || fail "plaintext on 6379 is refused (accept mode must keep it)"
  out="$(redis_in redis -p 6380 PING 2>&1 || true)"
  [[ "${out}" != *PONG* ]] || fail "6380 answers plaintext"
  pass "6379 plaintext PONG, plaintext on 6380 refused"
  [[ "$(docker exec m247-redis awk '/^Uid:/ {print $2}' /proc/1/status)" == 100 ]] || fail "PID 1 is not uid 100 (G5b-C3)"
  [[ "$(docker exec m247-redis stat -c '%a %u' /run/engine-tls/server.key)" == "600 100" ]] ||
    fail "the key copy is not 600 uid 100"
  [[ -z "$(docker exec m247-redis find /data -name '*.pem' -o -name '*.key')" ]] || fail "a key or cert landed in /data"
  pass "PID 1 is uid 100, the key is 600 uid 100 on tmpfs, nothing in /data"
}

# The mariadb client inside the server container (mariadb, or mysql: MariaDB too) as root;
# $1 the host, rest client flags.
# The password travels as MYSQL_PWD, never in argv.
mariadb_in() {
  local host="$1"
  shift
  docker exec -e MYSQL_PWD "m247-${ENGINE}" mariadb --no-defaults -h "${host}" -u root -N -B "$@" \
    -e "SHOW SESSION STATUS LIKE 'Ssl_version'"
}

# openssl s_client to m247-<engine>:3306 verifying the host name $1 against the minted CA.
mariadb_tls_as() {
  local ip
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "m247-${ENGINE}")"
  timeout 10 openssl s_client -starttls mysql -connect "${ip}:3306" -CAfile "${WORK}/track-binocle-local-ca.pem" \
    -verify_hostname "$1" </dev/null 2>&1 || true
}

mariadb_live_checks() {
  live_setup
  MYSQL_PWD="$(openssl rand -hex 16)"
  # Both services' variables: mariadb reads MARIADB_*, the mysql service MYSQL_*.
  export MYSQL_PWD MARIADB_ROOT_PASSWORD="${MYSQL_PWD}" MARIADB_PASSWORD="${MYSQL_PWD}"
  export MYSQL_ROOT_PASSWORD="${MYSQL_PWD}" MYSQL_PASSWORD="${MYSQL_PWD}"
  local cert_dir="${WORK}/${ENGINE}"
  export ENGINE_TLS_MARIADB_CERT_DIR="${cert_dir}" ENGINE_TLS_MYSQL_CERT_DIR="${cert_dir}"
  local verify=(--ssl-ca=/etc/engine-tls/ca.pem --ssl-verify-server-cert) out

  step "live A: no overlay → MariaDB's own TLS, a cert nothing verifies"
  mint_ca
  boot_or_fail "the default ${ENGINE} did not become healthy"
  [[ "$(mariadb_in "${ENGINE}" --skip-ssl)" == Ssl_version$'\t' ]] || fail "a --skip-ssl client did not get plaintext"
  out="$(mariadb_tls_as "${ENGINE}")"
  [[ "${out}" == *"Verify return code:"* && "${out}" != *"Verify return code: 0 (ok)"* ]] ||
    fail "the default cert verifies against the local CA, or no TLS was served"
  pass "default serves TLS with a cert the local CA does not sign; --skip-ssl is plaintext"
  down

  refuses_without_cert "${cert_dir}"

  step "live B: overlay + cert → a cert that verifies, plaintext still allowed"
  mint_cert "${cert_dir}"
  boot_or_fail "${ENGINE} with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(mariadb_in "${ENGINE}" "${verify[@]}")" == Ssl_version$'\t'TLSv1.[23] ]] || fail "a verified session failed"
  pass "verified session against the CA (--ssl-verify-server-cert)"
  [[ "$(mariadb_tls_as "${ENGINE}")" == *"Verify return code: 0 (ok)"* ]] || fail "openssl could not verify ${ENGINE} as host ${ENGINE}"
  out="$(mariadb_tls_as "m247-${ENGINE}")"
  [[ "${out}" == *"hostname mismatch"* ]] || fail "a name outside the SANs was not refused by verification"
  pass "the served cert verifies as ${ENGINE}, and a host name outside the SANs is refused"
  [[ "$(mariadb_in "${ENGINE}" --skip-ssl)" == Ssl_version$'\t' ]] || fail "a --skip-ssl client is refused (accept mode must allow it)"
  pass "a --skip-ssl client still connects, unencrypted"
  [[ "$(docker exec "m247-${ENGINE}" awk '/^Uid:/ {print $2}' /proc/1/status)" == 100 ]] || fail "PID 1 is not uid 100 (G5b-C3)"
  [[ "$(docker exec "m247-${ENGINE}" stat -c '%a %u' /run/engine-tls/server.key)" == "600 100" ]] ||
    fail "the key copy is not 600 uid 100"
  [[ -z "$(docker exec "m247-${ENGINE}" find /var/lib/mysql -name '*.pem' -o -name '*.key')" ]] ||
    fail "a key or cert landed in /var/lib/mysql"
  pass "PID 1 is uid 100, the key is 600 uid 100 on tmpfs, nothing in /var/lib/mysql"
}

# The mysql service is MariaDB 11.4 built from its own Dockerfile: the same legs.
mysql_live_checks() { mariadb_live_checks; }

# sqlcmd from a throwaway root container of the server's image on the m247 network, trusting
# the minted CA: the server container runs non-root and cannot add a CA to its store.
# $1 the host name, $2 the -N mode (m verifies, o asks for no encryption); prints encrypt_option.
mssql_as() {
  local image
  image="$(docker inspect -f '{{.Config.Image}}' "m247-${ENGINE}")"
  docker run --rm --network "${NETWORK}" --user 0 -e SQLCMDPASSWORD="${MSSQL_SA_PASSWORD}" \
    -v "${WORK}/track-binocle-local-ca.pem:/ca.pem:ro" -e HOST="$1" -e MODE="$2" \
    --entrypoint /bin/bash "${image}" -c '
      cp /ca.pem /usr/local/share/ca-certificates/m247.crt && update-ca-certificates >/dev/null 2>&1
      extra=(); [[ "${MODE}" == o ]] && extra=(-C)
      /opt/mssql-tools18/bin/sqlcmd -S "${HOST}" -U sa -N "${MODE}" "${extra[@]}" -h -1 -b -l 10 \
        -Q "SET NOCOUNT ON; SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID"' 2>&1 |
    tr -d '\r' | sed 's/^ *//; s/ *$//' | head -3
}

mssql_live_checks() {
  live_setup
  MSSQL_SA_PASSWORD="A1a!$(openssl rand -hex 12)"
  export MSSQL_SA_PASSWORD
  local cert_dir="${WORK}/${ENGINE}" uid
  export ENGINE_TLS_MSSQL_CERT_DIR="${cert_dir}"

  step "live A: no overlay → a self-signed cert the local CA does not verify"
  mint_ca
  boot_or_fail "the default mssql did not become healthy"
  [[ "$(mssql_as mssql m)" == *"certificate verify failed"* ]] || fail "the default cert verifies against the local CA"
  pass "default cert refused by a client that trusts only the local CA"
  down

  refuses_without_cert "${cert_dir}"

  step "live B: overlay + cert → a cert that verifies, unencrypted clients still allowed"
  mint_cert "${cert_dir}"
  boot_or_fail "mssql with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(mssql_as mssql m)" == TRUE ]] || fail "a verified session (-N m, CA trusted) failed"
  pass "verified session as host mssql, encrypt_option TRUE"
  [[ "$(mssql_as "m247-${ENGINE}" m)" != TRUE ]] || fail "a name outside the SANs was not refused"
  pass "a host name outside the SANs is refused"
  [[ "$(mssql_as mssql o)" == FALSE ]] || fail "a client asking for no encryption is refused (accept mode must allow it)"
  pass "a client asking for no encryption still connects, encrypt_option FALSE"
  uid="$(docker exec "m247-${ENGINE}" id -u mssql)"
  [[ "$(docker exec "m247-${ENGINE}" awk '/^Uid:/ {print $2}' /proc/1/status)" == "${uid}" ]] || fail "PID 1 is not the mssql user (G5b-C3)"
  [[ "$(docker exec "m247-${ENGINE}" stat -c '%a %u' /run/engine-tls/server.key)" == "600 ${uid}" ]] ||
    fail "the key copy is not 600 mssql"
  [[ -z "$(docker exec "m247-${ENGINE}" find /var/opt/mssql -name 'server.*' -o -name '*.pem')" ]] ||
    fail "a key or cert landed in /var/opt/mssql"
  ! docker exec "m247-${ENGINE}" grep -qi tls /var/opt/mssql/mssql.conf || fail "mssql.conf in the volume carries TLS settings"
  pass "PID 1 is mssql (uid ${uid}), the key is 600 on tmpfs, the volume holds no cert and no TLS setting"
  mssql_plane_render_checks
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
