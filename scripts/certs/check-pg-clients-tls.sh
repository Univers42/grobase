#!/usr/bin/env bash
# check-pg-clients-tls.sh — refuses ENGINE_TLS_ENGINES=pg-clients before compose starts
# anything (G5, docs/adr/0032-g5-node-pg-clients-verify-full.md, devil NP4–NP6).
#
# The overlay appends `?sslmode=verify-full&sslrootcert=…` to DATABASE_URL, and three of the
# nine services it changes only WARN on a bad CA while dropping outbox and audit rows. So
# the failures are caught here, loudly:
#   - DATABASE_URL already carrying `?` or `#`: the appended `?` turns the first parameter's
#     value into `value?sslmode=…`, so sslmode is lost and that parameter is corrupted;
#   - a non-empty AUDIT_DATABASE_URL: the overlay cannot rewrite it, and audit would dial
#     plaintext beside a verified DATABASE_URL;
#   - engine.pem not signed by ca.pem, expiring within 30 days, or not naming the DSN host.
# Values are read as compose reads them: the shell env first, then .env. No DSN or password
# is printed; only the variable name, the host and the check that failed.
#
# Caveat: the host is cut from the DSN by hand (after the last `@`, up to `:` or `/`), so a
# bracketed IPv6 host or a DSN with no `@` and a `:` in the path is read wrong; it then fails
# the SAN check (noisy, never silent). The 30-day window is checked once, at make time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WINDOW_SECONDS=2592000

fail() {
  printf 'check-pg-clients-tls: %s (ADR 0032)\n' "$*" >&2
  exit 1
}

# compose_value NAME — the shell env when set, else the last NAME= line of .env, unquoted.
compose_value() {
  if [[ -v "$1" ]]; then
    printf '%s' "${!1}"
    return
  fi
  [[ -f "${ROOT}/.env" ]] || return 0
  sed -n "s/^$1=//p" "${ROOT}/.env" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

dsn_host() {
  local rest="${1#*://}"
  rest="${rest##*@}"
  printf '%s' "${rest%%[:/]*}"
}

check_dsn() {
  local dsn audit
  dsn="$(compose_value DATABASE_URL)"
  [[ -n "${dsn}" ]] || fail "DATABASE_URL is unset - run make env"
  [[ "${dsn}" != *[?#]* ]] ||
    fail "DATABASE_URL carries a query string or fragment; pg-clients appends ?sslmode=verify-full and would corrupt its first parameter - move the parameters out or drop pg-clients"
  audit="$(compose_value AUDIT_DATABASE_URL)"
  [[ -z "${audit}" ]] ||
    fail "AUDIT_DATABASE_URL is set; pg-clients cannot add verify-full to it - unset it (audit then uses DATABASE_URL) or drop pg-clients"
  DSN_HOST="$(dsn_host "${dsn}")"
}

check_cert() {
  local dir="${ENGINE_TLS_CERT_DIR:-./certs/engines}"
  [[ "${dir}" == /* ]] || dir="${ROOT}/${dir#./}"
  command -v openssl >/dev/null || fail "openssl is required to check ${dir}/engine.pem"
  [[ -r "${dir}/ca.pem" && -r "${dir}/engine.pem" ]] ||
    fail "${dir}/ca.pem or engine.pem is missing - run scripts/certs/generate-engine-cert.sh postgres"
  openssl verify -CAfile "${dir}/ca.pem" "${dir}/engine.pem" >/dev/null 2>&1 ||
    fail "${dir}/engine.pem is not signed by ${dir}/ca.pem"
  openssl x509 -in "${dir}/engine.pem" -noout -checkend "${WINDOW_SECONDS}" >/dev/null ||
    fail "${dir}/engine.pem expires within 30 days - re-run scripts/certs/generate-engine-cert.sh postgres"
  openssl x509 -in "${dir}/engine.pem" -noout -checkhost "${DSN_HOST}" | grep -q 'does match' ||
    fail "DATABASE_URL's host ${DSN_HOST} is not in ${dir}/engine.pem's SANs, so verify-full refuses it"
}

check_dsn
check_cert
printf 'check-pg-clients-tls: DATABASE_URL host %s verifies against ca.pem, 30+ days left\n' "${DSN_HOST}"
