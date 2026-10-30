# shellcheck shell=bash
# lib-m247-mysql8.sh — the Oracle MySQL 8.4 legs of scripts/verify/m247-engine-tls.sh
# (docs/adr/0026-g5-mysql8-engine-tls.md, devil g5-mysql8 M1–M7). Sourced by m247 only: it
# uses m247's live_setup, boot_or_fail, down, mint_ca, mint_cert, refuses_without_cert,
# mariadb_tls_as and pass/fail/step. Sets no shell options.

# Static (M2, M6): the overlay restates the image CMD, drops to the image's uid 999, and the
# wrapper gives mysql8 the mariadb|mysql flag set. m247's per-overlay loop covers the rest.
mysql8_static_checks() {
  local overlay="${ROOT}/orchestrators/compose/docker-compose.engine-tls-mysql8.yml"
  step "static: mysql8 restates its CMD and drops to uid 999"
  grep -q '^    command: \["mysqld"\]$' "${overlay}" || fail "mysql8: the overlay does not restate command [mysqld]"
  [[ "$(grep -cE '^      ENGINE_TLS_(UID|GID): "999"$' "${overlay}")" == 2 ]] ||
    fail "mysql8: the overlay does not drop to the image's uid/gid 999"
  grep -q '^mariadb | mysql | mysql8)$' "${ROOT}/infra/docker/services/engine-tls/drop-entrypoint.sh" ||
    fail "mysql8: the wrapper has no flag set for it"
  pass "command [mysqld], uid/gid 999, the mariadb|mysql flag set"
}

# The mysql client inside the server container as root; $1 the host, rest client flags.
# The password travels as MYSQL_PWD, never in argv.
# A plaintext caching_sha2_password login needs the server's RSA key (ERROR 2061 without it,
# measured): that exchange is what the datadir's private_key.pem serves, hence M4.
MYSQL8_PLAIN=(--ssl-mode=DISABLED --get-server-public-key)
mysql8_in() {
  local host="$1"
  shift
  docker exec -e MYSQL_PWD m247-mysql8 mysql --no-defaults -h "${host}" --protocol=tcp -u root -N -B "$@" \
    -e "SHOW SESSION STATUS LIKE 'Ssl_version'"
}

# SHA-256 fingerprint of the cert m247-mysql8 serves to a client dialing it as mysql8.
mysql8_served_fingerprint() {
  mariadb_tls_as mysql8 | openssl x509 -noout -fingerprint -sha256 2>/dev/null
}

# M3: the overlay key is nowhere in the datadir. The datadir DOES hold pem files, ca-key.pem
# among them, by design: the image entrypoint's `mysqld --initialize-insecure` writes them on
# every boot path, overlay or not (devil g5-mysql8; M4 forbids deleting them). The positive
# control on /run/engine-tls proves the search can find the key at all.
# Caveat: a literal search for one base64 line of the PEM. A copy re-encoded (DER, another
# PEM wrapping) would not match, so this under-reports; it catches the copy a wrapper makes.
mysql8_key_not_in_datadir() { # $1 the overlay's engine-key.pem
  local found
  M247_KEY_LINE="$(sed -n 3p "$1")"
  export M247_KEY_LINE
  found="$(docker exec -e M247_KEY_LINE m247-mysql8 sh -c 'grep -rlF -e "$M247_KEY_LINE" /run/engine-tls /var/lib/mysql' || true)"
  unset M247_KEY_LINE
  [[ "${found}" == /run/engine-tls/server.key ]] ||
    fail "the overlay key is in the datadir, or the search cannot find it on tmpfs: ${found:-nothing}"
}

mysql8_default_leg() {
  step "live A: no overlay → MySQL's auto-generated cert, which nothing verifies"
  mint_ca
  boot_or_fail "the default mysql8 did not become healthy"
  [[ "$(mysql8_in mysql8 "${MYSQL8_PLAIN[@]}")" == Ssl_version$'\t' ]] || fail "an --ssl-mode=DISABLED client did not get plaintext"
  local out
  out="$(mariadb_tls_as mysql8)"
  [[ "${out}" == *"Verify return code:"* && "${out}" != *"Verify return code: 0 (ok)"* ]] ||
    fail "the default cert verifies against the local CA, or no TLS was served"
  pass "default serves TLS with a cert the local CA does not sign; --ssl-mode=DISABLED is plaintext"
  down
}

mysql8_overlay_leg() { # $1 the cert directory
  step "live B: overlay + cert → the served cert is the overlay's and verifies, plaintext still allowed"
  mint_cert "$1"
  boot_or_fail "mysql8 with the engine cert did not become healthy" -f "${ROOT}/${LIVE_OVERLAY}"
  [[ "$(mysql8_in mysql8 --ssl-mode=VERIFY_IDENTITY --ssl-ca=/etc/engine-tls/ca.pem)" == Ssl_version$'\t'TLSv1.[23] ]] ||
    fail "a VERIFY_IDENTITY session failed"
  pass "VERIFY_IDENTITY session against the CA"
  [[ "$(mysql8_served_fingerprint)" == "$(openssl x509 -in "$1/engine.pem" -noout -fingerprint -sha256)" ]] ||
    fail "the served cert is not the overlay's engine.pem (M3)"
  [[ "$(mariadb_tls_as m247-mysql8)" == *"hostname mismatch"* ]] || fail "a name outside the SANs was not refused by verification"
  pass "served fingerprint = overlay engine.pem, and a host name outside the SANs is refused"
  [[ "$(mysql8_in mysql8 "${MYSQL8_PLAIN[@]}")" == Ssl_version$'\t' ]] || fail "an --ssl-mode=DISABLED client is refused (accept mode must allow it)"
  pass "an --ssl-mode=DISABLED client still connects, unencrypted"
  [[ "$(docker exec m247-mysql8 awk '/^Uid:/ {print $2}' /proc/1/status)" == 999 ]] || fail "PID 1 is not uid 999 (G5b-C3)"
  [[ "$(docker exec m247-mysql8 stat -c '%a %u' /run/engine-tls/server.key)" == "600 999" ]] || fail "the key copy is not 600 uid 999"
  mysql8_key_not_in_datadir "$1/engine-key.pem"
  pass "PID 1 is uid 999, the key is 600 uid 999 on tmpfs, and no datadir file holds it"
}

mysql8_live_checks() {
  live_setup
  MYSQL_PWD="$(openssl rand -hex 16)"
  export MYSQL_PWD MYSQL_ROOT_PASSWORD="${MYSQL_PWD}" MYSQL_PASSWORD="${MYSQL_PWD}"
  export ENGINE_TLS_MYSQL8_CERT_DIR="${WORK}/mysql8"
  mysql8_default_leg
  refuses_without_cert "${ENGINE_TLS_MYSQL8_CERT_DIR}"
  mysql8_overlay_leg "${ENGINE_TLS_MYSQL8_CERT_DIR}"
}
