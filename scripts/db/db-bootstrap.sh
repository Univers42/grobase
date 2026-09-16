#!/bin/sh
# db-bootstrap.sh — wait until postgres actually ACCEPTS US, then apply db-bootstrap.psql.
#
# This used to be an inline `until pg_isready …; do sleep 1; done` in the compose command.
# pg_isready answers "is the server accepting connections", NOT "can I log in": it exits 0
# on a password rejection. So the loop passed immediately, the psql below died with a bare
#
#   psql: error: … FATAL:  password authentication failed for user "postgres"
#
# and nothing said why. Measured on a fresh clone whose engines had been up for two hours.
#
# The cause is almost always credential drift, and it is a one-way door: POSTGRES_PASSWORD
# is minted per install and initdb honours it ONLY on an empty PGDATA, so the moment .env is
# re-minted (or force-pulled from the vault) over an existing postgres-data volume, the
# volume keeps a password that no longer exists anywhere on disk. db-bootstrap is also the
# only place in the stack that resets a role password — and it sat behind the one credential
# that has no reset at all.
#
# So: gate on a real query, and when it never succeeds, say which of the two failures it is
# and how to get out. It does NOT reconcile the password itself: that would be this script
# silently rewriting a superuser credential on every boot.
set -eu

BOOTSTRAP_SQL="${BOOTSTRAP_SQL:-/bootstrap/db-bootstrap.psql}"
PGHOST_NAME="${PGHOST_NAME:-postgres}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"

# can_login: a real authenticated round-trip, not a reachability probe.
can_login() {
	psql -h "$PGHOST_NAME" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc 'select 1' >/dev/null 2>&1
}

# reachable: the server answers at all (this is what pg_isready alone was testing).
reachable() {
	pg_isready -h "$PGHOST_NAME" -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
}

diagnose() {
	if reachable; then
		echo "db-bootstrap: postgres is UP but REJECTS POSTGRES_USER/POSTGRES_PASSWORD." >&2
		echo "db-bootstrap: the data volume was initialised with a DIFFERENT password." >&2
		echo "  initdb applies POSTGRES_PASSWORD only to an EMPTY PGDATA, so a re-minted or" >&2
		echo "  force-pulled .env over an existing mini-baas_postgres-data cannot log in." >&2
		echo "  Reconcile it (keeps the data — the local socket is trust-authenticated):" >&2
		echo "    docker exec -i mini-baas-postgres psql -U postgres -v p=\"\$PW\" \\" >&2
		echo "      -c \"ALTER USER postgres WITH PASSWORD :'p'\"   # PW from apps/grobase/.env" >&2
		echo "  Or discard the data and let it re-init: docker compose down -v" >&2
	else
		echo "db-bootstrap: postgres never became reachable within ${WAIT_SECONDS}s." >&2
		echo "  Check: docker logs mini-baas-postgres" >&2
	fi
}

main() {
	i=0
	while ! can_login; do
		i=$((i + 1))
		if [ "$i" -ge "$WAIT_SECONDS" ]; then
			diagnose
			exit 2
		fi
		sleep 1
	done
	exec psql -h "$PGHOST_NAME" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
		-v ON_ERROR_STOP=1 \
		-v pwd="$POSTGRES_PASSWORD" \
		-v realtime_db="$REALTIME_DB_NAME" \
		-v authenticator_pwd="$AUTHENTICATOR_PASSWORD" \
		-f "$BOOTSTRAP_SQL"
}

main "$@"
