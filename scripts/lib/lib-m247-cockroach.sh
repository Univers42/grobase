# shellcheck shell=bash
# lib-m247-cockroach.sh — the CockroachDB legs of scripts/verify/m247-engine-tls.sh
# (docs/adr/0029-g5-cockroach-secure-mode.md, devil g5-cockroach CR1–CR12). Sourced after m247
# defines pass/fail/step and before its live helpers; the live functions run after them all.
#
# Live: A the default is insecure and a root:<password> DSN still connects; C the overlay with
# no cert refuses and names the script; B secure mode with plaintext accepted: verify-full,
# a password over plaintext, passwordless root refused (28P01), the SAN legs through
# `openssl s_client -starttls postgres`, PID 1 uid 1001, the keys 600 on tmpfs, nothing in the
# store, the password absent from docker inspect, 8080 still plain HTTP; D the rollback: the
# overlay dropped, the same store boots --insecure, data and the password DSN survive (CR12).

CRDB_OVERLAY="orchestrators/compose/docker-compose.engine-tls-cockroach.yml"
CRDB_CLIENTS=(scripts/ops/engine-backup.sh scripts/ops/stack-health-requests.sh
  scripts/seed/multidb-workspace.sh scripts/verify/m188-engine-backup-restore.sh)

cockroach_static_checks() {
  local overlay="${ROOT}/${CRDB_OVERLAY}" base
  base="$(sed -n '/^  cockroach:/,/^  [a-z#]/p' "${ROOT}/orchestrators/compose/base/engines-extra.yml")"
  step "static: cockroach secure mode is opt-in and keeps plaintext"
  grep -q 'start-single-node --insecure' <<<"${base}" || fail "the default cockroach is no longer --insecure (CR1)"
  grep -q -- '--accept-sql-without-tls' "${overlay}" || fail "the overlay drops plaintext SQL (CR2)"
  ! grep -v '^ *#' "${overlay}" | grep -q -- '--insecure' || fail "the overlay still runs --insecure"
  grep -q 'engine-tls-cockroach-health.sh"\]' "${overlay}" || fail "the overlay keeps the --insecure healthcheck (CR7)"
  grep -q 'mode: 0400' "${overlay}" || fail "the password secret is not mode 0400 (CR3)"
  [[ "$(grep -v '^ *#' "${overlay}" | grep -c COCKROACH_PASSWORD)" == 1 ]] ||
    fail "COCKROACH_PASSWORD appears outside the top-level secret (it would land in docker inspect)"
  grep -q 'GENERATED_KEYS=.*COCKROACH_PASSWORD' "${ROOT}/scripts/env/generate-env.sh" ||
    fail "make env does not generate COCKROACH_PASSWORD (CR3)"
  grep -q '| sql >/dev/null' "${ROOT}/infra/docker/services/engine-tls/cockroach-health.sh" ||
    fail "the password does not reach cockroach on stdin (CR3)"
  grep -q '^cockroach)' "${ROOT}/infra/docker/services/engine-tls/drop-entrypoint.sh" ||
    fail "the wrapper has no cockroach case (CR5)"
  grep -q '^# Caveat: the HTTP port (8080' "${overlay}" || fail "the overlay does not say 8080 stays plain HTTP (CR11)"
  pass "default --insecure, overlay secure + --accept-sql-without-tls, password a 0400 secret set on stdin"
  crdb_static_client_checks
}

crdb_static_client_checks() {
  local c users
  step "static: the root client cert and the client flag live in one place each"
  users="$(grep -rl 'cockroach-client' "${ROOT}/orchestrators/compose" "${ROOT}"/docker-compose*.yml 2>/dev/null)"
  [[ "${users}" == "${ROOT}/${CRDB_OVERLAY}" ]] || fail "the root client cert is mounted outside the cockroach overlay (CR4)"
  for c in "${CRDB_CLIENTS[@]}"; do
    grep -q 'crdb_auth' "${ROOT}/${c}" || fail "${c} does not pick its flag through lib-crdb-client.sh (CR6)"
  done
  ! grep -rn --include='*.sh' -e 'cockroach sql --insecure' "${ROOT}/scripts" | grep -v 'lib-m247-cockroach.sh' ||
    fail "a client still hard-codes cockroach sql --insecure (CR6)"
  grep -q 'crdb_dsn mini-baas-cockroach' "${ROOT}/scripts/verify/m27-conformance.sh" ||
    fail "m27 does not dial cockroach with the password DSN (CR6)"
  pass "client cert in the cockroach overlay only, ${#CRDB_CLIENTS[@]} exec clients + m27 through the shared helper"
}

# cockroach sql inside the node with the URL in COCKROACH_URL (env, not argv) and $2 the SQL;
# crdb_url_one keeps the last line, the value under the tsv header.
crdb_url_sql() {
  COCKROACH_URL="$1" docker exec -e COCKROACH_URL "${M247_PROJECT}-cockroach" \
    cockroach sql --format=tsv -e "$2" </dev/null 2>&1 || true
}
crdb_url_one() { crdb_url_sql "$@" | tail -1; }
crdb_root_url() { # $1 sslmode tail, $2 "pw" to carry the password
  printf 'postgresql://root%s@cockroach:26257/defaultdb?%s' "${2:+:${COCKROACH_PASSWORD}}" "$1"
}
crdb_cert_sql() { docker exec "${M247_PROJECT}-cockroach" cockroach sql --certs-dir=/run/engine-tls/certs --format=tsv -e "$1"; }

crdb_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${M247_PROJECT}-cockroach"; }
# openssl s_client -starttls postgres to the node; $@ the verification flags, none for a bare probe.
crdb_starttls() {
  timeout 10 openssl s_client -starttls postgres -connect "$(crdb_ip):26257" "$@" </dev/null 2>&1 || true
}
# The same, verifying host name $1 against the minted CA.
crdb_tls_as() {
  crdb_starttls -CAfile "${ENGINE_TLS_COCKROACH_CERT_DIR}/ca.pem" -verify_hostname "$1" -verify_return_error
}

cockroach_live_checks() {
  live_setup
  COCKROACH_PASSWORD="$(openssl rand -hex 16)"
  export COCKROACH_PASSWORD ENGINE_TLS_COCKROACH_CERT_DIR="${WORK}/cockroach"
  export ENGINE_TLS_COCKROACH_CLIENT_CERT_DIR="${WORK}/cockroach-client"

  step "live A: no overlay → insecure, the password DSN still connects"
  boot_or_fail "the default cockroach did not become healthy"
  [[ "$(crdb_url_one "$(crdb_root_url sslmode=disable pw)" 'SELECT 1')" == 1 ]] || fail "root:<password> over plaintext failed on the default"
  [[ "$(crdb_starttls)" != *"Server certificate"* ]] || fail "the default node serves TLS"
  pass "the default node is plaintext-only and takes the root:<password> DSN"
  down

  mkdir -p "${ENGINE_TLS_COCKROACH_CLIENT_CERT_DIR}"
  refuses_without_cert "${ENGINE_TLS_COCKROACH_CERT_DIR}"
  rmdir "${ENGINE_TLS_COCKROACH_CLIENT_CERT_DIR}"

  mint_cert "${ENGINE_TLS_COCKROACH_CERT_DIR}"
  crdb_leg_b
  crdb_leg_b_isolation
  crdb_leg_d
}

crdb_leg_b() {
  local verify="sslmode=verify-full&sslrootcert=/run/engine-tls/certs/ca.crt" out
  step "live B: overlay + cert → secure mode, plaintext with a password still accepted"
  boot_or_fail "cockroach in secure mode did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(crdb_url_one "$(crdb_root_url "${verify}" pw)" 'SELECT 1')" == 1 ]] || fail "a verify-full password session failed"
  pass "verify-full against the CA as root:<password>"
  [[ "$(crdb_url_one "$(crdb_root_url sslmode=disable pw)" 'SELECT 1')" == 1 ]] || fail "root:<password> over plaintext is refused (CR2)"
  pass "root:<password> over plaintext still connects (--accept-sql-without-tls)"
  out="$(crdb_url_sql "$(crdb_root_url sslmode=disable)" 'SELECT 1')"
  [[ "${out}" == *28P01* || "${out}" == *"password authentication failed"* ]] || fail "passwordless root was not refused: ${out}"
  pass "passwordless root is refused (28P01)"
  [[ "$(crdb_tls_as cockroach)" == *"Verify return code: 0 (ok)"* ]] || fail "openssl -starttls postgres does not verify 'cockroach'"
  out="$(crdb_tls_as "${M247_PROJECT}-cockroach")"
  [[ "${out}" != *"Verify return code: 0 (ok)"* && "${out}" == *mismatch* ]] || fail "a name outside the SANs was not refused"
  pass "openssl -starttls postgres verifies 'cockroach' and refuses a name outside the SANs"
  [[ "$(crdb_starttls)" == *"Server certificate"* ]] || fail "the bare STARTTLS probe saw no cert (leg A's check is vacuous)"
  out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$(crdb_ip):8080/health" || true)"
  [[ "${out}" =~ ^[1-5][0-9][0-9]$ ]] || fail "8080 no longer answers plain HTTP (the CR11 Caveat is stale): ${out}"
  pass "8080 still answers plain HTTP (${out}), as the overlay's Caveat says"
}

crdb_leg_b_isolation() {
  local c="${M247_PROJECT}-cockroach"
  [[ "$(docker exec "${c}" awk '/^Uid:/ {print $2}' /proc/1/status)" == 1001 ]] || fail "PID 1 is not uid 1001 (CR5)"
  [[ "$(docker exec "${c}" stat -c '%a %u' /run/engine-tls/certs/node.key /run/engine-tls/certs/client.root.key | sort -u)" == "600 1001" ]] ||
    fail "the key copies are not 600 uid 1001"
  [[ "$(docker exec "${c}" stat -c '%a' /run/secrets/cockroach_password)" == 400 ]] || fail "the password secret is not 0400"
  [[ -z "$(docker exec "${c}" find /cockroach/cockroach-data -name '*.key' -o -name '*.crt' -o -name '*.pem')" ]] ||
    fail "a key or cert landed in the store"
  [[ "$(docker inspect "${c}" | grep -cF "${COCKROACH_PASSWORD}")" == 0 ]] || fail "the password shows in docker inspect (CR3)"
  pass "PID 1 uid 1001, keys 600 uid 1001 on tmpfs, secret 0400, nothing in the store, password not in inspect"
  docker restart -t 20 "${c}" >/dev/null
  local _
  for _ in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "${c}")" == healthy ]] && break
    sleep 2
  done
  [[ "$(crdb_url_one "$(crdb_root_url sslmode=disable pw)" 'SELECT 1')" == 1 ]] || fail "the password did not survive a restart"
  pass "a restart re-runs the password set idempotently and the DSN still connects"
}

crdb_leg_d() {
  step "live D: drop the overlay → the same store boots --insecure, the password DSN survives (CR12)"
  crdb_cert_sql 'CREATE DATABASE IF NOT EXISTS m247keep' >/dev/null || fail "could not create the probe database"
  dc -f "${ROOT}/${LIVE_OVERLAY}" -f "${WORK}/rename.yml" down --remove-orphans >/dev/null 2>&1 ||
    fail "could not stop the secure node"
  boot_or_fail "the store did not boot --insecure after the overlay was dropped"
  [[ "$(crdb_url_one "$(crdb_root_url sslmode=disable pw)" 'SELECT count(*) FROM [SHOW DATABASES] WHERE database_name = '"'m247keep'")" == 1 ]] ||
    fail "the data or the password DSN did not survive the rollback"
  pass "rollback: --insecure on the same store, the database and the root:<password> DSN survive"
}
