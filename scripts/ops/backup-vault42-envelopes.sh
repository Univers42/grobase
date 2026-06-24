#!/bin/sh
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    backup-vault42-envelopes.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Off-fly ZERO-KNOWLEDGE backup of vault42's secret envelopes.
#
# pg_dumps the `vault42` database's public.vault42_secrets + public.vault42_audit
# tables from the `mini-baas-postgres` container on the grobase-stack fly Machine,
# gzips the dump under BACKUP_DIR (default ./build/backups), and prints the path
# plus a sha256. The `envelope` column is an opaque vault42-core blob the server
# can never decrypt, so the resulting file leaks nothing — that is why an off-fly
# copy is safe. Read-only on the server: pg_dump only, no writes, no restore.
#
# Docker-first: there is no host flyctl, so flyctl runs from the flyio/flyctl
# image, reaches the Machine over `fly ssh console`, and `docker exec`s pg_dump
# inside the inner DinD. Idempotent: each run writes a fresh timestamped file and
# never mutates the database or a previous backup.
#
# Usage:
#   FLY_API_TOKEN=... bash scripts/ops/backup-vault42-envelopes.sh
#   FLY_API_TOKEN=... BACKUP_DIR=/secure/off-fly bash scripts/ops/backup-vault42-envelopes.sh
#
# Env:
#   FLY_API_TOKEN  (required) fly auth token — never commit it
#   FLY_APP        grobase-stack          fly app running the stack
#   PG_CONTAINER   mini-baas-postgres     postgres container inside the Machine
#   PG_DB          vault42                database holding the ZK envelopes
#   PG_USER        postgres               superuser for the read-only dump
#   TABLES         "public.vault42_secrets public.vault42_audit"  tables to dump
#   BACKUP_DIR     ./build/backups        local (off-fly) output directory
#   FLYCTL_IMAGE   flyio/flyctl:latest    flyctl Docker image

set -eu

FLY_APP="${FLY_APP:-grobase-stack}"
PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"
PG_DB="${PG_DB:-vault42}"
PG_USER="${PG_USER:-postgres}"
TABLES="${TABLES:-public.vault42_secrets public.vault42_audit}"
BACKUP_DIR="${BACKUP_DIR:-./build/backups}"
FLYCTL_IMAGE="${FLYCTL_IMAGE:-flyio/flyctl:latest}"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '[backup-vault42] %s\n' "$*" >&2
}

# Verify the host has the two tools this script depends on (docker for the
# flyctl image, plus a token), failing fast with a clear message.
preflight() {
	command -v docker >/dev/null 2>&1 || die "docker not found (Docker-first: flyctl runs in a container)"
	[ -n "${FLY_API_TOKEN:-}" ] || die "FLY_API_TOKEN is required (never commit it)"
	mkdir -p "$BACKUP_DIR" || die "cannot create BACKUP_DIR: $BACKUP_DIR"
}

# Build the `--table` flags from the space-separated TABLES list, printed one
# per line so the caller can read them safely.
table_flags() {
	for t in $TABLES; do
		printf -- '--table=%s\n' "$t"
	done
}

# Assemble the read-only pg_dump command run INSIDE the postgres container:
# plain-SQL, data+schema for exactly the requested tables, no ownership/ACL
# noise, ON_CONFLICT-free. Printed as a single string for the remote shell.
remote_dump_cmd() {
	flags=$(table_flags | tr '\n' ' ')
	printf 'docker exec -i %s pg_dump -U %s -d %s --no-owner --no-privileges %s' \
		"$PG_CONTAINER" "$PG_USER" "$PG_DB" "$flags"
}

# Run flyctl from its image, ssh into the Machine, and stream the pg_dump output
# back over stdout into the local file. Read-only on the server.
fetch_dump() {
	out="$1"
	cmd="$(remote_dump_cmd)"
	note "dumping [$TABLES] from $PG_DB on $FLY_APP (read-only pg_dump)"
	docker run --rm -i -e FLY_API_TOKEN \
		"$FLYCTL_IMAGE" \
		ssh console --app "$FLY_APP" -C "sh -lc '$cmd'" >"$out" \
		|| die "remote pg_dump failed (check FLY_API_TOKEN / app / container)"
	[ -s "$out" ] || die "dump is empty — table names or DB wrong? ($PG_DB / $TABLES)"
}

# sha256 the artifact with whatever tool the host has, printing just the hash.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		die "no sha256sum/shasum on host"
	fi
}

main() {
	preflight
	stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
	raw="$BACKUP_DIR/vault42-envelopes-$stamp.sql"
	gz="$raw.gz"
	tmp="$raw.partial"
	trap 'rm -f "$tmp"' EXIT INT TERM

	fetch_dump "$tmp"
	mv "$tmp" "$raw"
	gzip -f "$raw" || die "gzip failed"
	trap - EXIT INT TERM

	digest="$(sha256_of "$gz")"
	bytes="$(wc -c <"$gz" | tr -d ' ')"
	note "done — ZK envelopes are safe to copy off-fly"
	printf 'path:   %s\n' "$gz"
	printf 'bytes:  %s\n' "$bytes"
	printf 'sha256: %s\n' "$digest"
}

main "$@"
