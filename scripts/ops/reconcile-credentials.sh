#!/bin/sh
# reconcile-credentials.sh — make the ENGINES accept the credentials that are on disk.
#
# THE FAILURE THIS EXISTS FOR
#
# Engine root passwords are minted per install and applied by the engine's first-boot
# initialisation ONLY — initdb for postgres, the entrypoint's root-user creation for mongo.
# Both ignore the variable entirely once their data directory exists. So the moment .env is
# re-minted, or force-pulled from the vault, over volumes that already exist, every volume
# keeps a password that no longer exists anywhere on disk and the whole stack is locked out
# of its own data. Observed on this project: `make backend-up` exited 2, db-bootstrap said
# only "password authentication failed", mongo-init said only "Authentication failed", and
# the sole documented way out was `docker compose down -v` — i.e. delete the data.
#
# It is not a wipe. Both engines can be reached WITHOUT their network password:
#   postgres — the unix socket inside the container is trust-authenticated
#   mongo    — a standalone mongod started without --keyFile runs with auth off
# so the stored credential can be rewritten to match .env with the data untouched.
#
# THE TRAP THAT COST AN HOUR: `docker rm -f` (SIGKILL) on the throwaway mongod silently
# loses the write. updateUser reports success, the process dies before the write is durable,
# and the next start still rejects the password — identical symptoms to never having run.
# Every shutdown here is SIGTERM with a real timeout, and the result is VERIFIED by a
# separate process against the same volume before the real container comes back.
#
# Explicit only. Never wire this into `make all`: it rewrites a superuser credential, which
# is not something a boot path should do on its own.
#
# Usage:
#   sh scripts/ops/reconcile-credentials.sh            # postgres + mongo + mysql
#   sh scripts/ops/reconcile-credentials.sh postgres   # one engine
set -eu

ENV_FILE="${ENV_FILE:-.env}"
PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
MONGO_CONTAINER="${MONGO_CONTAINER:-mini-baas-mongo}"
MONGO_VOLUME="${MONGO_VOLUME:-mini-baas_mongo-data}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
TMP_MONGO=reconcile-mongo-tmp

say() { printf '[reconcile] %s\n' "$1" >&2; }
die() { printf '[reconcile] ERROR: %s\n' "$1" >&2; exit 1; }

# getenv KEY — read one value from the env file. Values are never printed, only used.
getenv() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# wait_mongo NAME — block until a mongod answers ping, or give up after ~90s.
wait_mongo() {
	i=0
	while [ "$i" -lt 45 ]; do
		docker exec "$1" mongosh --quiet --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 2
	done
	return 1
}

# ── postgres ────────────────────────────────────────────────────────────────────
# ALTER USER over the container's trust-authenticated unix socket. No restart, no downtime.
reconcile_postgres() {
	if ! running "$PG_CONTAINER"; then
		say "postgres: $PG_CONTAINER not running — skipped"
		return 0
	fi
	pw=$(getenv POSTGRES_PASSWORD)
	[ -n "$pw" ] || die "POSTGRES_PASSWORD not found in $ENV_FILE"
	auth=$(getenv AUTHENTICATOR_PASSWORD)
	sql='ALTER USER postgres WITH PASSWORD :'"'"'pw'"'"';'
	if [ -n "$auth" ]; then
		sql="$sql ALTER USER authenticator WITH PASSWORD :'auth';"
	fi
	printf '%s\n' "$sql" | docker exec -i "$PG_CONTAINER" \
		psql -U postgres -v ON_ERROR_STOP=1 -v pw="$pw" -v auth="${auth:-unused}" >/dev/null
	docker exec -e PGPASSWORD="$pw" "$PG_CONTAINER" \
		psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 ||
		die "postgres still rejects the password over TCP after ALTER USER"
	say "postgres: reconciled and verified over TCP"
}

# ── mongo ───────────────────────────────────────────────────────────────────────
# A standalone mongod (no --keyFile, no --replSet) on the same volume runs with auth off and
# is writable; a lone replica-set member without a reachable config is not. Single-node set,
# so nothing can diverge, and the rs config in local/ is never touched.
mongo_image() { docker inspect "$MONGO_CONTAINER" -f '{{.Config.Image}}'; }

mongo_write_password() {
	docker run -d --name "$TMP_MONGO" -v "$MONGO_VOLUME:/data/db" "$1" --bind_ip 127.0.0.1 >/dev/null
	wait_mongo "$TMP_MONGO" || die "throwaway mongod never became reachable"
	docker exec -e P="$2" -e U="$3" "$TMP_MONGO" mongosh --quiet admin \
		--eval 'db.updateUser(process.env.U, { pwd: process.env.P })' >/dev/null
	# SIGTERM with a real timeout. `docker rm -f` here loses the write silently.
	docker stop -t "$STOP_TIMEOUT" "$TMP_MONGO" >/dev/null
	docker rm "$TMP_MONGO" >/dev/null
}

mongo_verify_password() {
	docker run -d --name "$TMP_MONGO" -v "$MONGO_VOLUME:/data/db" "$1" --bind_ip 127.0.0.1 --auth >/dev/null
	wait_mongo "$TMP_MONGO" >/dev/null 2>&1 || true
	ok=0
	if docker exec -e P="$2" -e U="$3" "$TMP_MONGO" mongosh --quiet admin \
		--eval 'db.auth(process.env.U, process.env.P)' >/dev/null 2>&1; then
		ok=1
	fi
	docker stop -t "$STOP_TIMEOUT" "$TMP_MONGO" >/dev/null
	docker rm "$TMP_MONGO" >/dev/null
	if [ "$ok" != 1 ]; then
		die "mongo still rejects the password after the reset — volume NOT changed back; investigate before retrying"
	fi
}

reconcile_mongo() {
	user=$(getenv MONGO_INITDB_ROOT_USERNAME)
	pass=$(getenv MONGO_INITDB_ROOT_PASSWORD)
	if [ -z "$user" ] || [ -z "$pass" ]; then
		die "MONGO_INITDB_ROOT_USERNAME/PASSWORD not found in $ENV_FILE"
	fi
	img=$(mongo_image) || die "cannot inspect $MONGO_CONTAINER for its image"
	docker rm -f "$TMP_MONGO" >/dev/null 2>&1 || true
	was_running=0
	if running "$MONGO_CONTAINER"; then
		was_running=1
		docker stop -t "$STOP_TIMEOUT" "$MONGO_CONTAINER" >/dev/null
	fi
	trap 'docker rm -f "$TMP_MONGO" >/dev/null 2>&1 || true
	      if [ "$was_running" = 1 ]; then docker start "$MONGO_CONTAINER" >/dev/null 2>&1 || true; fi' EXIT INT TERM
	mongo_write_password "$img" "$pass" "$user"
	mongo_verify_password "$img" "$pass" "$user"
	trap - EXIT INT TERM
	if [ "$was_running" = 1 ]; then
		docker start "$MONGO_CONTAINER" >/dev/null
	fi
	say "mongo: reconciled and verified by a separate process on the same volume"
}

# ── mysql (MariaDB) ─────────────────────────────────────────────────────────────
# Grant tables live in the data volume, so a replayed `mysql` system database — or any
# re-mint of MYSQL_ROOT_PASSWORD — leaves root holding a password nobody has. Observed: after
# restoring a dump that carried the grant tables, root rejected every credential that exists.
# A throwaway mariadbd with --skip-grant-tables and --skip-networking on the same volume accepts
# a local socket with no password; FLUSH PRIVILEGES re-enables account management so ALTER USER
# works. Same discipline as mongo: SIGTERM, then verified against the REAL container.
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mini-baas-mysql}"
MYSQL_VOLUME="${MYSQL_VOLUME:-mini-baas_mysql-data}"
TMP_MYSQL=reconcile-mysql-tmp

# The image's entrypoint is bypassed, so nothing has created /run/mysqld: socket and pid go to
# /tmp, which the mysql user can always write.
mysql_tmp_sql() { docker exec -i "$TMP_MYSQL" mysql -uroot -S /tmp/mysqld.sock -N "$@"; }

mysql_write_password() {
	docker run -d --name "$TMP_MYSQL" -v "$MYSQL_VOLUME:/var/lib/mysql" --entrypoint mariadbd "$1" \
		--user=mysql --skip-grant-tables --skip-networking \
		--socket=/tmp/mysqld.sock --pid-file=/tmp/mysqld.pid >/dev/null
	i=0
	until mysql_tmp_sql -e 'select 1' >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 45 ] || die "throwaway mariadbd never became reachable"
		sleep 2
	done
	hosts=$(mysql_tmp_sql -e "SELECT Host FROM mysql.global_priv WHERE User='root'" 2>/dev/null)
	[ -n "$hosts" ] || die "no root account in the grant tables — refusing to guess which to create"
	esc=$(printf '%s' "$2" | sed "s/'/''/g")
	sql="FLUSH PRIVILEGES;"
	for h in $hosts; do
		sql="$sql ALTER USER 'root'@'$h' IDENTIFIED BY '$esc';"
	done
	# The password travels on stdin, never argv — `ps` inside the container cannot see it.
	printf '%s\n' "$sql" | mysql_tmp_sql >/dev/null
	docker stop -t "$STOP_TIMEOUT" "$TMP_MYSQL" >/dev/null
	docker rm "$TMP_MYSQL" >/dev/null
}

reconcile_mysql() {
	pw=$(getenv MYSQL_ROOT_PASSWORD)
	# MYSQL_ROOT_PASSWORD is in no env file today: compose falls back to its own literal
	# (`${MYSQL_ROOT_PASSWORD:-...}` in engines-extra.yml). The value the container was started
	# with is therefore the one every client uses, so that is the one to reconcile to.
	if [ -z "$pw" ]; then
		pw=$(docker inspect "$MYSQL_CONTAINER" -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
			sed -n 's/^MYSQL_ROOT_PASSWORD=//p' | head -1)
	fi
	[ -n "$pw" ] || die "MYSQL_ROOT_PASSWORD is set neither in $ENV_FILE nor on $MYSQL_CONTAINER"
	img=$(docker inspect "$MYSQL_CONTAINER" -f '{{.Config.Image}}') || die "cannot inspect $MYSQL_CONTAINER"
	docker rm -f "$TMP_MYSQL" >/dev/null 2>&1 || true
	docker stop -t "$STOP_TIMEOUT" "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
	trap 'docker rm -f "$TMP_MYSQL" >/dev/null 2>&1 || true
	      docker start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true' EXIT INT TERM
	mysql_write_password "$img" "$pw"
	trap - EXIT INT TERM
	docker start "$MYSQL_CONTAINER" >/dev/null
	i=0
	until docker exec -e MYSQL_PWD="$pw" "$MYSQL_CONTAINER" mysql -uroot -N -e 'select 1' >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 45 ] || die "mysql still rejects the password after the reset"
		sleep 2
	done
	say "mysql: reconciled and verified against the real container"
}

main() {
	[ -f "$ENV_FILE" ] || die "$ENV_FILE not found (run from apps/grobase, or set ENV_FILE=)"
	case "${1:-all}" in
	postgres) reconcile_postgres ;;
	mongo) reconcile_mongo ;;
	mysql) reconcile_mysql ;;
	all)
		reconcile_postgres
		reconcile_mongo
		reconcile_mysql
		;;
	*) die "unknown engine '${1}' — use: postgres | mongo | mysql | all" ;;
	esac
	say "done. Bring the stack back with: make up"
}

main "$@"
