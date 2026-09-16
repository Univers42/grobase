#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    vault-restore.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/09/16 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/09/16 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Disaster recovery: rebuild every engine's DATA from the 42ctl vault seeds.
#
# `make up` alone brings the stack back with EMPTY engines. This restores what
# was in them, in the one order that works.
#
# ORDER IS LOAD-BEARING, and getting it wrong fails silently:
#
#   1. Engines only, no apps. db-bootstrap/pg-migrate and gotrue CREATE AND SEED
#      tables in the `postgres` database. If they run before the replay, the
#      dump's CREATE TABLE hits "already exists", its COPY never lands, and you
#      are left with a bootstrap-shaped `users` table holding zero rows. The
#      table COUNT still matches, so every naive check reports success. Measured.
#   2. Replay. pg_dumpall carries DROP DATABASE for every database except the
#      one you are connected to, so `postgres` itself must have its schemas
#      dropped by hand or it keeps the bootstrap's objects.
#   3. Apps last, so migrations run against restored data rather than racing it.
#
# REDIS IS NOT A FILE COPY. With appendonly on, Redis loads the AOF and ignores
# dump.rdb entirely — and a running Redis rewrites dump.rdb on shutdown, so a
# file dropped in before stopping is destroyed. The RDB is loaded by a throwaway
# instance with appendonly off, which then writes the AOF the real container reads.
#
# Idempotent: re-running replays the same dumps over the same engines.
#
# Usage:
#   FT_PASSPHRASE=... bash scripts/ops/vault-restore.sh
#   FT_PASSPHRASE=... FETCH=1 bash scripts/ops/vault-restore.sh   # 42ctl pull first
#   SEED_DIR=/path/to/secrets bash scripts/ops/vault-restore.sh
#
# Env:
#   SEED_DIR     ./secrets              directory holding the dumps
#   FETCH        0                      1 = `42ctl pull` before restoring
#   PROJECT      groot                  42ctl project to pull
#   EDITION      realtime               edition to bring up at the end
#   ENGINES      postgres mysql mongo redis minio
#   NET          mini-baas_mini-baas    compose network for sidecar tools

set -eu

# Resolve SEED_DIR against the CALLER's cwd, then move to the grobase root. `make up` here
# means orchestrators/makes/20-stack.mk; run from the SUPERPROJECT root the same word is
# infrastructure/makes/compose.mk's `up`, which builds and starts everything and ignores
# SERVICE entirely — so "engines only" would silently become "the whole stack". The default
# SEED_DIR=./secrets happens to resolve at the root too, which is exactly what would have
# hidden the bug.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GROBASE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
_seed_in="${SEED_DIR:-./secrets}"
SEED_DIR=$(CDPATH= cd -- "$_seed_in" 2>/dev/null && pwd || printf '%s' "$_seed_in")
cd "$GROBASE_ROOT"

FETCH="${FETCH:-0}"
PROJECT="${PROJECT:-groot}"
# infrastructure/makes/grobase.mk:42 sets GROBASE_EDITION ?= devlean — that is what a real
# `make all` runs. Defaulting to anything else brings up a different stack than the caller's.
EDITION="${EDITION:-devlean}"
ENGINES="${ENGINES:-postgres mysql mongo redis minio}"
NET="${NET:-mini-baas_mini-baas}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"
MC_IMAGE="${MC_IMAGE:-ghcr.io/univers42/grobase-mc:latest}"
REDIS_IMAGE="${REDIS_IMAGE:-ghcr.io/univers42/grobase-redis:latest}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[vault-restore] %s\n' "$*" >&2
}

have() {
	[ -f "$SEED_DIR/$1" ]
}

dump_for() {
	case "$1" in
	postgres) printf 'postgres-all.sql.gz' ;;
	mysql) printf 'mysql-all.sql.gz' ;;
	mongo) printf 'mongo.archive.gz' ;;
	minio) printf 'minio.tar.gz' ;;
	redis) printf 'redis.rdb' ;;
	*) printf '' ;;
	esac
}

# FAIL-CLOSED coverage, checked in preflight BEFORE anything is stopped or dropped.
#
# `have()` used to mean "absent -> skip", and the comment above it said "half a restore is
# worse than a named omission" — directly above the code implementing the skip. Because
# restore_postgres runs FIRST and the others `die` under `set -e`, a missing mysql dump
# aborted the run AFTER postgres had already been dropped and replayed: the half-restore
# that comment warns about, reached by the shortest path in the file.
#
# It checks the ENGINES this run intends to restore, not what happens to be running — "what
# is running" is not knowable before engines_up, and a gate that depends on timing is not a
# gate. A stack that legitimately omits an engine narrows ENGINES.
require_coverage() {
	missing=""
	for eng in $ENGINES; do
		f=$(dump_for "$eng")
		[ -n "$f" ] || continue
		have "$f" || missing="$missing $eng($f)"
	done
	[ -z "$missing" ] || die "ENGINES names these, but $SEED_DIR has no dump for:$missing
  Restoring would replace some engines and leave the rest exactly as they were — a
  half-restored stack that still reports success. Capture them (make vault-seed), or
  narrow the set: ENGINES='postgres mysql' ..."
}

preflight() {
	command -v docker >/dev/null 2>&1 || die "docker not found"
	[ -d "$SEED_DIR" ] || die "SEED_DIR not found: $SEED_DIR (run with FETCH=1?)"
	[ "$FETCH" = "1" ] || return 0
	command -v 42ctl >/dev/null 2>&1 || die "42ctl not found but FETCH=1"
	[ -n "${FT_PASSPHRASE:-}" ] || die "FT_PASSPHRASE required for 42ctl pull"
	note "pulling project '$PROJECT' from the vault"
	FT_S3_KEY="$(42ctl vault get infra/S3_KEY)" \
	FT_S3_SECRET="$(42ctl vault get infra/S3_SECRET)" \
		42ctl pull --project "$PROJECT" --apply || die "42ctl pull failed"
}

# Engines only. Anything that migrates or seeds must stay down until the replay has
# finished (see ORDER above).
#
# This used to be the `make up SERVICE=...` line alone — which STARTS the named services and
# stops nothing. Against an already-running stack it was a complete no-op, so the
# load-bearing order this file's header calls "Measured" was silently violated on exactly
# the runs where it mattered. Two independent reasons it must really stop things:
#
#   1. db-bootstrap / pg-migrate / gotrue CREATE AND SEED tables. Live, the dump's
#      CREATE TABLE hits "already exists" and its COPY never lands.
#   2. DROP DATABASE refuses while ANY session is connected, and supavisor, postgrest,
#      realtime and pg_net all hold persistent ones. Measured on this stack: rc=1,
#      'database "..." is being accessed by other users. DETAIL: There is 1 other session'.
#      The dump carries 6 such DROPs for real application databases.
#
# Stopped, not remembered-and-restarted: `_rm-stale` (00-config.mk) `docker rm -f`s every
# Exited mini-baas-* container, so that bookkeeping could not survive. The `make up EDITION`
# at the end of main() is the supported way back, and it recreates them.
stop_non_engines() {
	keep=""
	for e in $ENGINES; do keep="$keep mini-baas-$e"; done
	victims=""
	for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep '^mini-baas-' || true); do
		case " $keep " in *" $c "*) continue ;; esac
		victims="$victims $c"
	done
	if [ -z "$victims" ]; then
		note "only engines are running — nothing to stop"
		return 0
	fi
	note "stopping non-engine containers so the replay is not raced:$victims"
	# shellcheck disable=SC2086
	docker stop -t 30 $victims >/dev/null 2>&1 || true
}

engines_up() {
	stop_non_engines
	note "starting engines only: $ENGINES"
	# shellcheck disable=SC2086
	make --no-print-directory up EDITION="$EDITION" SERVICE="$ENGINES" >/dev/null \
		|| die "could not start engines"
	wait_for_postgres
}

wait_for_postgres() {
	n=0
	while [ "$n" -lt 30 ]; do
		if docker exec mini-baas-postgres sh -c \
			'pg_isready -U "$POSTGRES_USER"' >/dev/null 2>&1; then
			return 0
		fi
		n=$((n + 1))
		sleep 2
	done
	die "postgres did not become ready"
}

# A pg_dumpall --clean replay ALWAYS emits statements that cannot succeed, because the dump
# tries to drop objects the replaying session is necessarily using. Verified in
# secrets/postgres-all.sql.gz:
#
#   line    107  DROP DATABASE template1;        a template database cannot be dropped
#   line 122957  DROP DATABASE postgres;         you are connected to it
#   line     34  DROP ROLE IF EXISTS postgres;   you are authenticated as it
#
# So ON_ERROR_STOP=1 cannot be used on this dump as-is: it would abort at line 107 on every
# single run. The honest equivalent is to capture stderr and fail on any error that is NOT
# one of those. The old code instead sent stderr to /dev/null with `|| true` and printed
# "postgres: done" — the silent success this file's own header documents as "Measured".
#
# The line between benign and fatal is WHICH SECTION of the dump failed, and it is not a
# matter of taste:
#
#   GLOBALS (roles, the connected database) — benign. pg_dumpall's DROP ROLE fails whenever
#   a role owns objects, and you can drop neither the role you authenticate as nor the
#   database you are connected to. The subsequent CREATE then says "already exists". None of
#   that loses data; the role/database is already there with the right name.
#
#   SCHEMA/DATA (relation, constraint, trigger, policy, duplicate key, multiple primary
#   keys) — FATAL. Those mean the pre-replay clear did not actually clear, so the dump's
#   CREATE TABLE lands on an existing table and its COPY never runs. That is precisely the
#   "table count matches, zero rows, everything reports success" failure this file's header
#   calls Measured. Observed for real: replaying twice without clearing first produced 1029
#   such errors — 408 "relation already exists", 143 "multiple primary keys", 44 duplicate
#   keys — and the old code swallowed every one of them.
PG_BENIGN='^ERROR:  role "[^"]*" (already exists|cannot be dropped because some objects depend on it)$|^ERROR:  current user cannot be dropped$|^ERROR:  database "postgres" (already exists|is being accessed by other users)$|^ERROR:  database "template1" |is a template|must be owner of database template1'

# DROP DATABASE refuses while any session is connected; the dump carries 6 of them for real
# application databases. Clear the connections so those DROPs can actually execute.
pg_terminate_sessions() {
	docker exec mini-baas-postgres sh -c \
		'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER" -d postgres -c \
		 "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
		  WHERE pid <> pg_backend_pid() AND datname IS NOT NULL"' >/dev/null 2>&1 || true
}

# The `postgres` database is the one database the dump cannot drop — you are connected to
# it — so everything the dump will recreate inside it has to be cleared by hand first, or
# its CREATEs land on existing objects and its COPYs never run.
#
# Generated from the catalog rather than hardcoded. The previous version named five schemas
# literally (public, auth, gdpr, newsletter, session). They happen to be exactly the five
# that exist today — so it looked correct — but the sixth schema somebody adds next would be
# missed silently, which is this file's entire failure genre. Publications are the proof
# that a hardcoded list rots: they are database-level, not schema-level, so DROP SCHEMA
# never touched them and `CREATE PUBLICATION mini_baas_outbox_pub` failed on every re-run.
# The SQL goes in over STDIN as a heredoc, not through `psql -c` inside `sh -c '...'`.
# Generating SQL shell-side needed '"'"' three times per literal and silently fell apart —
# it printed the right statements when run by hand and failed inside the script. A heredoc
# has no quoting interaction with the shell at all, and the DO block keeps the whole thing
# server-side so nothing has to be escaped twice.
clear_postgres_db() {
	note "postgres: clearing the 'postgres' database (schemas + publications)"
	docker exec -i mini-baas-postgres sh -c \
		'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1' \
		>/dev/null 2>&1 <<-'SQL' || die "could not clear the postgres database"
	DO $$
	DECLARE r record;
	BEGIN
	  FOR r IN SELECT pubname FROM pg_publication LOOP
	    EXECUTE format('DROP PUBLICATION IF EXISTS %I', r.pubname);
	  END LOOP;
	  FOR r IN SELECT nspname FROM pg_namespace
	           WHERE nspname NOT IN ('information_schema','pg_catalog','pg_toast')
	             AND nspname NOT LIKE 'pg\_%' LOOP
	    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', r.nspname);
	  END LOOP;
	  EXECUTE 'CREATE SCHEMA IF NOT EXISTS public';
	END $$;
	SQL
}

# Reversibility of this operation was scored 5/5: it drops 8 databases and 7 roles with no
# way back, and the git snapshot only rewinds to 2026-07-28. One command buys a way back.
backup_postgres() {
	out="$SEED_DIR/pre-restore-postgres-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
	note "postgres: taking a pre-restore dump -> $(basename "$out")"
	docker exec mini-baas-postgres sh -c \
		'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_USER" --clean' 2>/dev/null \
		| gzip -9 >"$out" || true
	[ -s "$out" ] || die "could not take a pre-restore backup — refusing to go further"
	note "postgres: pre-restore backup is $(wc -c <"$out") bytes"
}

restore_postgres() {
	have postgres-all.sql.gz || { note "no postgres dump — skipped"; return 0; }
	backup_postgres
	clear_postgres_db
	pg_terminate_sessions
	note "postgres: replaying dump"
	err=$(mktemp)
	gzip -dc "$SEED_DIR/postgres-all.sql.gz" \
		| docker exec -i mini-baas-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER"' \
		>/dev/null 2>"$err" || true
	real=$(grep '^ERROR:' "$err" 2>/dev/null | grep -Ev "$PG_BENIGN" || true)
	count=$(printf '%s' "$real" | grep -c . || true)
	if [ "${count:-0}" -gt 0 ]; then
		# Keep the WHOLE stderr, not the five lines that fit on screen. Diagnosing this
		# needs the shape of all of them — 408 "relation already exists" says the clear
		# failed, one "duplicate key" says something quite different.
		kept="$SEED_DIR/failed-replay-$(date -u +%Y%m%dT%H%M%SZ).log"
		cp "$err" "$kept" 2>/dev/null || true
		rm -f "$err"
		printf '%s\n' "$real" | head -10 >&2
		die "postgres replay reported $count schema/data error(s) beyond the unavoidable
  globals (first 10 above). That means the pre-replay clear did not clear: the dump's
  CREATE TABLE landed on existing tables and its COPY never ran. The stack is NOT restored.
    full stderr : $kept
    rollback    : gzip -dc $SEED_DIR/pre-restore-postgres-*.sql.gz | docker exec -i mini-baas-postgres sh -c 'PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -q -U \"\$POSTGRES_USER\"'"
	fi
	rm -f "$err"
	note "postgres: replayed cleanly (only the unavoidable globals errors)"
}

restore_mysql() {
	have mysql-all.sql.gz || { note "no mysql dump — skipped"; return 0; }
	note "mysql: replaying dump"
	gzip -dc "$SEED_DIR/mysql-all.sql.gz" \
		| docker exec -i mini-baas-mysql sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD"' \
		>/dev/null 2>&1 || die "mysql restore failed"
	note "mysql: done"
}

restore_mongo() {
	have mongo.archive.gz || { note "no mongo dump — skipped"; return 0; }
	note "mongo: replaying archive"
	MU="$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)"
	MP="$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)"
	export MU MP
	docker run --rm -i --network "$NET" -e MU -e MP --entrypoint sh "$MONGO_IMAGE" -c \
		'mongorestore --host mini-baas-mongo --port 27017 --username "$MU" --password "$MP" \
		 --authenticationDatabase admin --archive --gzip --drop' \
		< "$SEED_DIR/mongo.archive.gz" >/dev/null 2>&1 || die "mongo restore failed"
	note "mongo: done"
}

# Objects go back through the S3 API, never by writing into the volume.
restore_minio() {
	have minio.tar.gz || { note "no minio dump — skipped"; return 0; }
	note "minio: mirroring objects back"
	stage="$(mktemp -d)"
	tar -xzf "$SEED_DIR/minio.tar.gz" -C "$stage"
	MC_HOST_seed="http://$(docker exec mini-baas-minio printenv MINIO_ROOT_USER):$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)@mini-baas-minio:9000"
	export MC_HOST_seed
	for bucket in "$stage"/*; do
		[ -d "$bucket" ] || continue
		docker run --rm --network "$NET" -e MC_HOST_seed -e HOME=/tmp \
			--tmpfs /tmp:rw,size=16m "$MC_IMAGE" mb --ignore-existing \
			"seed/$(basename "$bucket")" >/dev/null 2>&1 || true
	done
	docker run --rm --network "$NET" -e MC_HOST_seed -e HOME=/tmp --tmpfs /tmp:rw,size=16m \
		-v "$stage":/in:ro "$MC_IMAGE" mirror --quiet /in seed >/dev/null 2>&1 \
		|| die "minio mirror failed"
	rm -rf "$stage"
	note "minio: done"
}

# See the REDIS note in the header: the real container reads the AOF, so the RDB
# is loaded by a throwaway instance that then writes that AOF.
restore_redis() {
	have redis.rdb || { note "no redis dump — skipped"; return 0; }
	note "redis: loading RDB through a throwaway instance"
	docker stop mini-baas-redis >/dev/null 2>&1 || true
	docker run --rm -v mini-baas_redis-data:/d alpine:latest \
		rm -rf /d/appendonlydir /d/dump.rdb >/dev/null 2>&1 || true
	docker cp "$SEED_DIR/redis.rdb" mini-baas-redis:/data/dump.rdb \
		|| die "could not place the rdb"
	docker rm -f vault-restore-redis >/dev/null 2>&1 || true
	docker run -d --name vault-restore-redis -v mini-baas_redis-data:/data \
		"$REDIS_IMAGE" redis-server --appendonly no --save '' --dir /data >/dev/null \
		|| die "throwaway redis failed to start"
	sleep 5
	docker exec vault-restore-redis redis-cli config set appendonly yes >/dev/null 2>&1 \
		|| die "could not enable AOF on the throwaway redis"
	sleep 4
	docker exec vault-restore-redis redis-cli shutdown nosave >/dev/null 2>&1 || true
	docker rm -f vault-restore-redis >/dev/null 2>&1 || true
	docker start mini-baas-redis >/dev/null 2>&1 || die "redis would not restart"
	note "redis: done"
}

main() {
	preflight
	require_coverage
	engines_up
	restore_postgres
	restore_mysql
	restore_mongo
	restore_minio
	restore_redis
	note "bringing up the full edition '$EDITION'"
	make --no-print-directory up EDITION="$EDITION" >/dev/null || die "stack did not come up"
	note "restore complete"
}

main "$@"
