# shellcheck shell=sh
# lib-crdb-client.sh — how a host script logs in to a running cockroach container, insecure
# (the compose default) or secure (docs/adr/0029-g5-cockroach-secure-mode.md). One copy for
# every `docker exec … cockroach sql` client and every root DSN (devil g5-cockroach CR6).
# POSIX sh, so stack-health-requests.sh can source it too; sets no shell options.

CRDB_CERTS_DIR=/run/engine-tls/certs

# crdb_auth CONTAINER — the auth flag for `docker exec CONTAINER cockroach sql`: the certs dir
# holding the root client cert when the node runs secure, --insecure otherwise.
# Caveat: "secure" is read as "the overlay's wrapper put the root client cert on the tmpfs".
# A node made secure some other way reads as insecure: its client is refused, loudly.
crdb_auth() {
  if docker exec "$1" test -s "$CRDB_CERTS_DIR/client.root.crt" 2>/dev/null; then
    printf '%s\n' "--certs-dir=$CRDB_CERTS_DIR"
  else
    printf '%s\n' --insecure
  fi
}

# crdb_password CONTAINER — root's password: the overlay's compose secret, else the caller's
# COCKROACH_PASSWORD, else empty. Printed for a DSN only; an insecure node ignores it (measured).
crdb_password() {
  docker exec "$1" cat /run/secrets/cockroach_password 2>/dev/null || printf '%s' "${COCKROACH_PASSWORD:-}"
}

# crdb_dsn CONTAINER DB [SSLMODE] — root's in-network DSN, root:<password>@ whenever a password
# exists, so one DSN serves both modes. SSLMODE defaults to disable. The password is hex
# (generate-env.sh), so it needs no URL encoding.
crdb_dsn() {
  _crdb_pw=$(crdb_password "$1")
  printf 'postgres://root%s@cockroach:26257/%s?sslmode=%s\n' "${_crdb_pw:+:$_crdb_pw}" "$2" "${3:-disable}"
  unset _crdb_pw
}
