#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m47-backup-restore.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M47 — backup/restore round-trip gate (the drill you run BEFORE you need it).
#
# Proves, against a SCRATCH database it creates itself (never tenant data):
#   1. seed   — scratch DB + marker table with a deterministic checksum row;
#   2. dump   — pg_dump -Fc of the scratch DB (the same form pg-backup takes);
#   3. wipe   — DROP the scratch DB (only the one this run created);
#   4. restore— recreate empty + pg_restore the dump;
#   5. assert — marker rows + checksum byte-identical to the seed.
#
# Cheap + self-contained (runs inside the postgres container, no MinIO needed)
# → safe for verify-all. SKIPs (exit 0) when the postgres container is down.
# The scheduled-backup path (pg-backup → MinIO) reuses the exact same
# pg_dump/pg_restore mechanics this gate proves; see DEPLOYMENT.md §3.

set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M47] $*"; }
ok(){ green "  ✓ $*"; }

PG="mini-baas-postgres"
DB="m47_restore_smoke_$$"
DUMP="/tmp/${DB}.dump"

if ! docker inspect -f '{{.State.Running}}' "${PG}" 2>/dev/null | grep -q true; then
  cyan "[M47] SKIP — ${PG} is not running (start a stack first: make up)"
  exit 0
fi

PSQL=(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" "${PG}" psql -U postgres -v ON_ERROR_STOP=1 -qAt)

cleanup(){
  "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1 || true
  docker exec "${PG}" rm -f "${DUMP}" >/dev/null 2>&1 || true
}
fail(){ red "[M47] FAIL — $*"; cleanup; exit 1; }
trap cleanup EXIT

# ── 1. seed a scratch database with a deterministic marker ───────────────────
step "seed scratch database ${DB}"
"${PSQL[@]}" -d postgres -c "CREATE DATABASE ${DB};" || fail "could not create scratch DB"
"${PSQL[@]}" -d "${DB}" -c "
  CREATE TABLE m47_marker (id int PRIMARY KEY, note text NOT NULL);
  INSERT INTO m47_marker SELECT g, 'm47-row-' || g FROM generate_series(1, 100) g;
" || fail "seed failed"
SEED_SUM="$("${PSQL[@]}" -d "${DB}" -c "SELECT md5(string_agg(id || ':' || note, ',' ORDER BY id)) FROM m47_marker;")"
[ -n "${SEED_SUM}" ] || fail "could not checksum the seed"
ok "100 marker rows, checksum ${SEED_SUM:0:12}…"

# ── 2. dump (custom format — same as the pg-backup service / tools/backup.sh) ─
step "pg_dump -Fc"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" "${PG}" \
  pg_dump -U postgres -Fc -d "${DB}" -f "${DUMP}" || fail "pg_dump failed"
SIZE="$(docker exec "${PG}" stat -c%s "${DUMP}")"
ok "dump written (${SIZE} bytes)"

# ── 3. wipe — drop ONLY the scratch DB this run created ──────────────────────
step "drop scratch database (simulated loss)"
"${PSQL[@]}" -d postgres -c "DROP DATABASE ${DB};" || fail "drop failed"
ok "scratch DB gone"

# ── 4. restore ────────────────────────────────────────────────────────────────
step "recreate + pg_restore"
"${PSQL[@]}" -d postgres -c "CREATE DATABASE ${DB};" || fail "recreate failed"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" "${PG}" \
  pg_restore -U postgres -d "${DB}" "${DUMP}" || fail "pg_restore failed"
ok "restored"

# ── 5. assert byte-identical content ─────────────────────────────────────────
step "assert marker checksum"
COUNT="$("${PSQL[@]}" -d "${DB}" -c "SELECT count(*) FROM m47_marker;")"
RESTORE_SUM="$("${PSQL[@]}" -d "${DB}" -c "SELECT md5(string_agg(id || ':' || note, ',' ORDER BY id)) FROM m47_marker;")"
[ "${COUNT}" = "100" ] || fail "row count ${COUNT} != 100 after restore"
[ "${RESTORE_SUM}" = "${SEED_SUM}" ] || fail "checksum mismatch: ${SEED_SUM} → ${RESTORE_SUM}"
ok "100 rows, checksum identical"

green "[M47] PASS — dump→drop→restore round-trip proven (scratch DB only; tenant data untouched)"
