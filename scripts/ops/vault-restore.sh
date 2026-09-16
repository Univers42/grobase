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

SEED_DIR="${SEED_DIR:-./secrets}"
FETCH="${FETCH:-0}"
PROJECT="${PROJECT:-groot}"
EDITION="${EDITION:-realtime}"
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

# A dump that is absent is skipped, not fatal: a stack may legitimately not use
# every engine, and half a restore is worse than a named omission.
have() {
	[ -f "$SEED_DIR/$1" ]
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

# Engines only. Anything that migrates or seeds must stay down until the replay
# has finished (see ORDER above).
engines_up() {
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

# The connected database cannot be dropped by the dump, so its schemas go first.
# Every other database carries its own DROP DATABASE inside the dump.
restore_postgres() {
	have postgres-all.sql.gz || { note "no postgres dump — skipped"; return 0; }
	note "postgres: dropping bootstrap schemas in the 'postgres' database"
	docker exec mini-baas-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER" -d postgres \
		-c "DROP SCHEMA IF EXISTS public CASCADE; DROP SCHEMA IF EXISTS auth CASCADE; DROP SCHEMA IF EXISTS gdpr CASCADE; DROP SCHEMA IF EXISTS newsletter CASCADE; DROP SCHEMA IF EXISTS session CASCADE; CREATE SCHEMA public;"' \
		>/dev/null 2>&1 || die "could not clear the postgres database"
	note "postgres: replaying dump"
	gzip -dc "$SEED_DIR/postgres-all.sql.gz" \
		| docker exec -i mini-baas-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -U "$POSTGRES_USER"' \
		>/dev/null 2>&1 || true
	note "postgres: done"
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
