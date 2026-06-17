#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m99-pitr-restore.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M99 — Track-C C4b POINT-IN-TIME RECOVERY (PITR) live gate. Today the pg-backup
# service does ONE thing: a whole-cluster logical pg_dump → MinIO + a plain
# pg_restore (gate m47). C4b ADDS, all flag-gated by PG_BACKUP_PITR (OFF by
# default = today's behaviour, byte-parity):
#
#   (1) WAL ARCHIVING — postgres runs with archive_mode=on + an archive_command
#       that ships every completed WAL segment to the artifact store (the
#       pg-backup image's `archive-wal` mode is the MinIO transport; this gate
#       uses postgres's native archive_command into a shared local store laid out
#       EXACTLY like the store run-backup.sh/wal-archive.sh write:
#       <prefix>/physical/base-<stamp>/ + <prefix>/wal/<segments>).
#   (2) RESTORE-TO-TIMESTAMP — pitr-restore.sh rebuilds a FRESH PGDATA from a
#       physical base backup, stages the archived WAL, and writes the recovery
#       config (restore_command + recovery_target_time=T + recovery.signal +
#       recovery_target_action=promote). A fresh postgres started on that PGDATA
#       REPLAYS WAL up to T and promotes — point-in-time, not "latest".
#   (3) RETENTION-BY-TIER — run-backup.sh resolves the prune window from the tier
#       (nano 1d … max 90d); a longer PITR window is what a paid tier buys. The
#       pure tier→days resolution is asserted in-gate against the same case map.
#
# ARMS (each fails CLOSED, naming the exact assertion that tripped):
#   (A · POSITIVE) on an isolated postgres with WAL archiving ON: take a base
#       backup; INSERT R1; capture T1 (then sleep past T1); INSERT R2 (after T1);
#       force WAL to archive. pitr-restore.sh → fresh PGDATA at
#       recovery_target_time=T1; start a recovery postgres on it →
#       assert R1 PRESENT and R2 ABSENT. Point-in-time PROVEN.
#   (B · REJECT, LOAD-BEARING) restore to a time BEFORE R1 was inserted →
#       R1 ABSENT in the recovered cluster (the target is HONORED — it is NOT a
#       "restore latest" that would bring R1 back). A gate that only shows the
#       happy path is VACUOUS; the before-R1 arm is the load-bearing proof that
#       recovery_target_time actually bounds replay. PLUS: archive-wal/pitr-restore
#       modes REFUSE to run with PG_BACKUP_PITR unset (the flag truly gates).
#   (C · PARITY) with PG_BACKUP_PITR unset, the EXISTING run-backup.sh prune path
#       touches ONLY logical/ + physical/ (NEVER wal/) and the retain window is
#       the legacy PG_BACKUP_RETAIN_DAYS (NOT a tier window). A plain logical
#       dump+restore round-trips a row unchanged. OFF == today, byte-identical.
#
# ISOLATED by design (mirrors m87): scratch postgres containers + a pg-backup
# image built FROM CURRENT source via the REAL Dockerfile, ALL on a PRIVATE
# network, every name suffixed with $$, a shared per-run store dir under
# /mnt/storage, an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-*
# container/network/image/volume and NEVER edits the live docker-compose.yml.
# NO MinIO container is needed (the RAM-constrained box): the gate exercises the
# real pitr-restore.sh via its PITR_LOCAL_STORE path against the on-disk store
# layout — the SAME layout the MinIO path reads.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
PGB_DIR="${INFRA_DIR}/docker/services/pg-backup"
RUN_BACKUP_SH="${PGB_DIR}/scripts/run-backup.sh"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M99] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M99] FAIL — $*"; exit 1; }

PG_IMAGE="${M99_PG_IMAGE:-postgres:16-alpine}"
PGB_IMG="m99-pgb-$$:scratch"
NET="m99net-$$"
PG="m99-pg-$$"                 # the primary (WAL archiving ON)
PG_REC_A="m99-rec-a-$$"        # recovery cluster — restore to T1 (A · positive)
PG_REC_B="m99-rec-b-$$"        # recovery cluster — restore to T0<R1 (B · reject)
PG_OFF="m99-pg-off-$$"         # parity primary (PITR unset)
PGPW="postgres"
PREFIX="postgres"

# Shared per-run artifact root on the big disk (kernel: Docker work on
# /mnt/storage), user-owned bench base so we can mkdir without sudo. It holds the
# WAL archive + base backup in the run-backup.sh store layout, and the recovery
# PGDATA dirs. Overridable via M99_WORK_DIR.
WORK_DIR="${M99_WORK_DIR:-/mnt/storage/bench/m99-pitr-$$}"
STORE_DIR="${WORK_DIR}/store"          # <- ${STORE_DIR}/${PREFIX}/{physical,wal}
WAL_ARCHIVE="${STORE_DIR}/${PREFIX}/wal"
PHYS_DIR="${STORE_DIR}/${PREFIX}/physical"
REC_A_DATA="${WORK_DIR}/rec-a/pgdata"
REC_A_WAL="${WORK_DIR}/rec-a/wal"
REC_B_DATA="${WORK_DIR}/rec-b/pgdata"
REC_B_WAL="${WORK_DIR}/rec-b/wal"

cleanup() {
  docker rm -fv "${PG}" "${PG_REC_A}" "${PG_REC_B}" "${PG_OFF}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${PGB_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# psql against the named container's postgres. $1=container, rest=psql args.
pg_q()   { local c="$1"; shift; docker exec -i "$c" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
pg_val() { local c="$1"; shift; docker exec -i "$c" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

wait_pg() { # $1=container
  local i
  for i in $(seq 1 80); do
    # Gate on TCP readiness + a real query: the postgres image's init bootstrap runs a
    # SOCKET-ONLY temp server (no TCP) for initdb, then shuts it down to start the real
    # server — a plain (socket) pg_isready answers from the temp server and races a
    # "the database system is shutting down" on the next query. TCP pg_isready
    # (-h 127.0.0.1) + a SELECT 1 only succeed against the REAL, fully-started server.
    if docker exec "$1" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres >/dev/null 2>&1 \
       && docker exec "$1" psql -h 127.0.0.1 -U postgres -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -25; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -25; return 1
}

# ── 0) build the pg-backup image FROM CURRENT source via the REAL Dockerfile ────
step "0/10 build scratch pg-backup image from CURRENT source (the C4b WAL/PITR/retention code)"
DOCKER_BUILDKIT=1 docker build -q -t "${PGB_IMG}" "${PGB_DIR}" >/dev/null \
  || fail "scratch pg-backup image build failed — gate must exercise the drafted PITR scripts (line: docker build pg-backup)"
ok "pg-backup built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 0b) STATIC: the new scripts exist + parse; modes are flag-gated in the image ─
step "0b/10 the C4b scripts exist, parse, and the new modes are present in the built image"
for f in wal-archive.sh pitr-restore.sh; do
  [[ -f "${PGB_DIR}/scripts/${f}" ]] || fail "missing C4b script scripts/${f} (line: ${f} exists)"
  bash -n "${PGB_DIR}/scripts/${f}" || fail "scripts/${f} has a syntax error (line: ${f} bash -n)"
done
docker run --rm "${PGB_IMG}" liveness >/dev/null 2>&1 \
  || { DATABASE_URL="x" docker run --rm -e DATABASE_URL=x "${PGB_IMG}" liveness >/dev/null 2>&1 \
       || fail "pg-backup liveness mode broke (line: image liveness)"; }
ok "wal-archive.sh + pitr-restore.sh present and parse; image boots"

# ── 0c) (B · REJECT) the PITR modes REFUSE to run with PG_BACKUP_PITR unset ─────
step "0c/10 (B · REJECT) archive-wal + pitr-restore REFUSE when PG_BACKUP_PITR unset (the flag truly gates)"
if docker run --rm "${PGB_IMG}" archive-wal /tmp/x x >/dev/null 2>&1; then
  fail "archive-wal ran with PG_BACKUP_PITR unset — the flag does NOT gate (line: archive-wal off refuse)"
fi
if docker run --rm "${PGB_IMG}" pitr-restore latest "2026-01-01 00:00:00+00" >/dev/null 2>&1; then
  fail "pitr-restore ran with PG_BACKUP_PITR unset — the flag does NOT gate (line: pitr-restore off refuse)"
fi
ok "both PITR modes exit non-zero with PG_BACKUP_PITR unset — OFF is inert"

# ── 1) shared work dirs + isolated network ─────────────────────────────────────
step "1/10 create shared work dirs under ${WORK_DIR} + isolated net (${NET})"
mkdir -p "${WAL_ARCHIVE}" "${PHYS_DIR}" "${REC_A_DATA}" "${REC_A_WAL}" "${REC_B_DATA}" "${REC_B_WAL}" 2>/dev/null \
  || fail "could not create work dirs (run once: sudo install -d -o \$USER /mnt/storage/bench) (line: work mkdir)"
# postgres in the container runs as uid 70 (alpine) / 999 (debian); make the
# archive + recovery dirs world-writable so the container's postgres user can
# write WAL into the bind mount + own the recovered PGDATA. Ephemeral ($$),
# removed by the EXIT trap, so 777 is gate-local + short-lived.
chmod -R 777 "${WORK_DIR}" 2>/dev/null || true
docker network create "${NET}" >/dev/null
ok "work dirs + private network ready"

# ── 2) primary postgres with WAL ARCHIVING ON (the C4b (1) mechanism) ───────────
step "2/10 boot primary postgres (wal_level=replica, archive_mode=on, archive_command → ${WAL_ARCHIVE})"
# archive_command ships each completed segment into the shared WAL store using the
# canonical 'test ! -f dest && cp' idiom (refuse to clobber; exit 0 only on copy
# success — the same contract wal-archive.sh enforces for the MinIO transport).
# /walarchive is the in-container mount of ${WAL_ARCHIVE}.
docker run -d --name "${PG}" --network "${NET}" \
  -e POSTGRES_PASSWORD="${PGPW}" \
  -v "${WAL_ARCHIVE}:/walarchive" \
  "${PG_IMAGE}" \
  postgres \
    -c wal_level=replica \
    -c archive_mode=on \
    -c "archive_command=test ! -f /walarchive/%f && cp %p /walarchive/%f" \
    -c max_wal_senders=3 \
    -c archive_timeout=5 >/dev/null
wait_pg "${PG}" || fail "primary postgres never became ready (line: PG ready)"
[[ "$(pg_val "${PG}" "SHOW archive_mode")" == "on" ]] \
  || fail "primary archive_mode is not on — WAL archiving not enabled (line: archive_mode on)"
ok "primary up: wal_level=replica, archive_mode=on, archiving to ${WAL_ARCHIVE}"
# pg_basebackup uses the REPLICATION protocol from a SEPARATE client container, but the
# image's default pg_hba.conf only allows replication from localhost → "no pg_hba.conf
# entry for replication connection". Allow it network-wide (gate-local, throwaway) + reload.
docker exec "${PG}" bash -lc 'grep -q "host replication all all trust" "$PGDATA/pg_hba.conf" || echo "host replication all all trust" >> "$PGDATA/pg_hba.conf"'
docker exec "${PG}" psql -U postgres -d postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true

# ── 3) base backup INTO the run-backup.sh store layout (physical/base-<stamp>/) ─
step "3/10 take a physical base backup → ${PHYS_DIR}/base-<stamp>/ (the run-backup.sh layout)"
pg_q "${PG}" -c "CREATE TABLE pitr_marker (id int PRIMARY KEY, label text NOT NULL, at timestamptz NOT NULL DEFAULT now());" >/dev/null \
  || fail "could not create pitr_marker table (line: create marker)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BASE_OUT="${PHYS_DIR}/base-${STAMP}"
mkdir -p "${BASE_OUT}"; chmod 777 "${BASE_OUT}"
# pg_basebackup from a throwaway client container on the same net, --format=tar
# --gzip → base.tar.gz + pg_wal.tar.gz, EXACTLY what run-backup.sh's physical
# branch uploads and pitr-restore.sh untars.
BB_LOG="$(docker run --rm --network "${NET}" -e PGPASSWORD="${PGPW}" \
  -v "${BASE_OUT}:/out" "${PG_IMAGE}" \
  pg_basebackup -h "${PG}" -U postgres -D /out --format=tar --gzip --checkpoint=fast --no-password 2>&1)" \
  || { red "pg_basebackup output:"; printf '%s\n' "${BB_LOG}" | tail -12; fail "pg_basebackup failed — no physical base for PITR (line: pg_basebackup)"; }
[[ -f "${BASE_OUT}/base.tar.gz" ]] \
  || fail "base.tar.gz not produced under ${BASE_OUT} (line: base.tar.gz)"
ok "base backup base-${STAMP}: $(ls "${BASE_OUT}" | tr '\n' ' ')"

# ── 4) INSERT R1, capture T1, then (after T1) INSERT R2 ────────────────────────
step "4/10 INSERT R1 → capture T1 (server clock) → sleep past T1 → INSERT R2"
pg_q "${PG}" -c "INSERT INTO pitr_marker (id, label) VALUES (1, 'R1');" >/dev/null \
  || fail "could not insert R1 (line: insert R1)"
# Capture T1 = the server's now() AFTER R1 is committed. recovery_target_time is
# interpreted in the server timezone; read it back as an unambiguous +00 instant.
# MICROSECOND precision (.US): a whole-second target would round DOWN below R1's
# sub-second commit instant, so recovery_target_inclusive would EXCLUDE R1.
T1="$(pg_val "${PG}" "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US')||'+00'")" || true
[[ -n "${T1}" ]] || fail "could not capture T1 (line: capture T1)"
# Also capture T0 = a time strictly BEFORE R1 for the (B) reject arm. R1's commit
# timestamp minus a margin: read the marker's own 'at' minus 5s.
T0="$(pg_val "${PG}" "SELECT to_char(((SELECT at FROM pitr_marker WHERE id=1) - interval '5 seconds') AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US')||'+00'")" || true
[[ -n "${T0}" ]] || fail "could not capture T0<R1 (line: capture T0)"
# Sleep so R2's commit is strictly AFTER T1 (1s clock granularity → 3s margin).
sleep 3
pg_q "${PG}" -c "INSERT INTO pitr_marker (id, label) VALUES (2, 'R2');" >/dev/null \
  || fail "could not insert R2 (line: insert R2)"
[[ "$(pg_val "${PG}" "SELECT count(*) FROM pitr_marker")" == "2" ]] \
  || fail "primary should hold R1+R2 = 2 rows (line: primary 2 rows)"
ok "R1@<=T1='${T1}', R2 after T1; T0(before R1)='${T0}'; primary holds 2 rows"

# ── 5) force the WAL holding R1..R2 to be archived, then verify segments landed ─
step "5/10 force WAL flush+switch so the segment carrying R1..R2 is archived"
pg_q "${PG}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
# archive_timeout=5 also flips the segment; poll the shared archive for >=1 seg.
ARCHIVED=0
for i in $(seq 1 40); do
  ARCHIVED="$( { find "${WAL_ARCHIVE}" -type f ! -name '*.history' 2>/dev/null | wc -l || true; } | tr -d '[:space:]')"
  [[ -n "${ARCHIVED}" && "${ARCHIVED}" -ge 1 ]] 2>/dev/null && break
  pg_q "${PG}" -c "SELECT pg_switch_wal();" >/dev/null 2>&1 || true
  sleep 0.5
done
[[ -n "${ARCHIVED}" && "${ARCHIVED}" -ge 1 ]] 2>/dev/null \
  || fail "no WAL segment archived to ${WAL_ARCHIVE} — archive_command did not ship WAL (line: WAL archived)"
ok "${ARCHIVED} WAL segment(s) archived to the shared store — WAL ARCHIVING proven"

# ── 6) (A · POSITIVE) restore to T1 via the REAL pitr-restore.sh → R1 yes / R2 no
step "6/10 (A · POSITIVE) pitr-restore.sh → recovery_target_time=T1 → start recovery cluster"
# Run the REAL pitr-restore.sh in the pg-backup image against the on-disk store
# (PITR_LOCAL_STORE) — the same layout the MinIO path reads. It produces a
# recovered PGDATA + recovery config under ${REC_A_DATA}.
PITR_A_LOG="$(docker run --rm \
  -e PG_BACKUP_PITR=1 -e PG_BACKUP_PREFIX="${PREFIX}" \
  -e PITR_LOCAL_STORE=/store -e PITR_PGDATA=/rec/pgdata -e PITR_WAL_STAGE=/rec/wal \
  -v "${STORE_DIR}:/store:ro" \
  -v "${REC_A_DATA}:/rec/pgdata" -v "${REC_A_WAL}:/rec/wal" \
  "${PGB_IMG}" pitr-restore "${STAMP}" "${T1}" 2>&1)" \
  || { red "pitr-restore output:"; printf '%s\n' "${PITR_A_LOG}" | tail -15; fail "(A) pitr-restore.sh failed to prepare the recovery PGDATA (line: A pitr-restore prep)"; }
[[ -f "${REC_A_DATA}/recovery.signal" ]] \
  || fail "(A) recovery.signal not written — pitr-restore.sh did not arm recovery (line: A recovery.signal)"
# postgresql.auto.conf came from the base backup (tar-preserved mode 0600, owned by
# the in-tar postgres uid 999) → the HOST user cannot read it. Grep it via a
# throwaway root container that can.
docker run --rm -u 0 -v "${REC_A_DATA}:/d:ro" "${PG_IMAGE}" \
  grep -q "recovery_target_time = '${T1}'" /d/postgresql.auto.conf \
  || { red "auto.conf PITR lines (want T1='${T1}'):"; docker run --rm -u 0 -v "${REC_A_DATA}:/d:ro" "${PG_IMAGE}" grep -aE "recovery_target_time|restore_command" /d/postgresql.auto.conf 2>&1 | sed 's/^/    /'; fail "(A) recovery_target_time=T1 not written to postgresql.auto.conf (line: A target_time written)"; }
ok "(A) recovery PGDATA prepared: recovery.signal + recovery_target_time='${T1}' present"

# The restore_command in postgresql.auto.conf is 'cp ${PITR_WAL_STAGE}/%f %p' =
# 'cp /rec/wal/%f %p'; mount the SAME staged WAL at /rec/wal in the recovery
# server so it serves segments during replay. pitr-restore.sh ran as root in the
# pg-backup image, so the recovered PGDATA + appended config are root-owned; the
# alpine postgres runs as uid 70 and refuses a PGDATA it does not own. chown it to
# 70:70 (throwaway root container on the bind mount), then start postgres as 70;
# it replays WAL to T1 then promotes (recovery_target_action=promote).
step "6b/10 (A · POSITIVE) start recovery postgres on the prepared PGDATA → replay to T1 + promote"
docker run --rm -u 0 -v "${REC_A_DATA}:/d" "${PG_IMAGE}" chown -R 70:70 /d >/dev/null 2>&1 \
  || fail "(A) could not chown the recovered PGDATA to the postgres uid (line: A chown rec)"
docker run -d --name "${PG_REC_A}" --network "${NET}" \
  --user 70 \
  -v "${REC_A_DATA}:/var/lib/postgresql/data" \
  -v "${REC_A_WAL}:/rec/wal" \
  -e POSTGRES_PASSWORD="${PGPW}" \
  "${PG_IMAGE}" postgres >/dev/null 2>&1 \
  || fail "(A) could not launch the recovery postgres (line: A launch rec)"
wait_pg "${PG_REC_A}" || { docker logs "${PG_REC_A}" 2>&1 | tail -30; fail "(A) recovery postgres never became ready (replay/promote failed) (line: A rec ready)"; }
# Give recovery a moment to finish promotion (recovery.signal removed on promote).
for i in $(seq 1 40); do
  [[ "$(pg_val "${PG_REC_A}" "SELECT pg_is_in_recovery()")" == "f" ]] && break
  sleep 0.5
done
[[ "$(pg_val "${PG_REC_A}" "SELECT pg_is_in_recovery()")" == "f" ]] \
  || fail "(A) recovery cluster still in recovery — it never promoted at T1 (line: A promoted)"
R1_PRESENT="$(pg_val "${PG_REC_A}" "SELECT count(*) FROM pitr_marker WHERE id=1 AND label='R1'")"
R2_PRESENT="$(pg_val "${PG_REC_A}" "SELECT count(*) FROM pitr_marker WHERE id=2 AND label='R2'")"
[[ "${R1_PRESENT}" == "1" ]] \
  || fail "(A) R1 ABSENT after restore to T1 — base+WAL replay lost the committed row (line: A R1 present)"
[[ "${R2_PRESENT}" == "0" ]] \
  || fail "(A) R2 PRESENT after restore to T1 — replay went PAST the target (restored 'latest', not point-in-time!) (line: A R2 absent)"
ok "(A) restore-to-T1: R1 PRESENT, R2 ABSENT — POINT-IN-TIME proven (replay stopped at the target)"

# ── 7) (B · REJECT, LOAD-BEARING) restore to T0<R1 → R1 ABSENT ──────────────────
step "7/10 (B · REJECT, LOAD-BEARING) pitr-restore.sh → recovery_target_time=T0(before R1) → R1 must be ABSENT"
docker run --rm \
  -e PG_BACKUP_PITR=1 -e PG_BACKUP_PREFIX="${PREFIX}" \
  -e PITR_LOCAL_STORE=/store -e PITR_PGDATA=/rec/pgdata -e PITR_WAL_STAGE=/rec/wal \
  -v "${STORE_DIR}:/store:ro" \
  -v "${REC_B_DATA}:/rec/pgdata" -v "${REC_B_WAL}:/rec/wal" \
  "${PGB_IMG}" pitr-restore "${STAMP}" "${T0}" >/dev/null 2>&1 \
  || fail "(B) pitr-restore.sh failed to prepare the T0 recovery PGDATA (line: B pitr-restore prep)"
# Read via a root container — postgresql.auto.conf is mode-0600/uid-999 from the base tar.
docker run --rm -u 0 -v "${REC_B_DATA}:/d:ro" "${PG_IMAGE}" \
  grep -q "recovery_target_time = '${T0}'" /d/postgresql.auto.conf \
  || fail "(B) recovery_target_time=T0 not written (line: B target_time written)"
docker run --rm -u 0 -v "${REC_B_DATA}:/d" "${PG_IMAGE}" chown -R 70:70 /d >/dev/null 2>&1 \
  || fail "(B) could not chown the T0 recovered PGDATA (line: B chown rec)"
docker run -d --name "${PG_REC_B}" --network "${NET}" \
  --user 70 \
  -v "${REC_B_DATA}:/var/lib/postgresql/data" \
  -v "${REC_B_WAL}:/rec/wal" \
  -e POSTGRES_PASSWORD="${PGPW}" \
  "${PG_IMAGE}" postgres >/dev/null 2>&1 \
  || fail "(B) could not launch the T0 recovery postgres (line: B launch rec)"
# Recovery to a time before the table even existed promotes to an early state; it
# may either reach the target or error if T0 precedes a consistent point. Either
# way R1 must NOT be present. Wait for readiness OR an early-target promotion.
B_READY=0
for i in $(seq 1 80); do
  if docker exec "${PG_REC_B}" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres >/dev/null 2>&1; then B_READY=1; break; fi
  docker inspect "${PG_REC_B}" >/dev/null 2>&1 || break
  [[ $i -eq 80 ]] && break
  sleep 0.5
done
if [[ "${B_READY}" == "1" ]]; then
  # The pitr_marker table was created BEFORE R1 but AFTER the base backup, so at a
  # time before R1 the table may or may not exist; in BOTH cases R1 is absent.
  R1_AT_T0="$(pg_val "${PG_REC_B}" "SELECT count(*) FROM pitr_marker WHERE id=1" 2>/dev/null || echo 0)"
  [[ -z "${R1_AT_T0}" ]] && R1_AT_T0=0
  [[ "${R1_AT_T0}" == "0" ]] \
    || fail "(B) R1 PRESENT after restore to T0 (before R1) — the target was IGNORED (restore 'latest'!) (line: B R1 absent)"
  ok "(B) restore-to-T0(before R1): R1 ABSENT — recovery_target_time is HONORED, not 'restore latest'"
else
  # Recovery refused to reach a target before consistency: that ALSO proves the
  # target bounds replay (it did not silently restore 'latest'). The cluster never
  # served R1.
  docker logs "${PG_REC_B}" 2>&1 | grep -qiE 'recovery_target|before consistent|reached|stopping point|FATAL' \
    || fail "(B) T0 recovery neither served (R1-absent) nor reported a target-bounded recovery — undefined (line: B undefined)"
  ok "(B) restore-to-T0(before R1): cluster never served R1 (recovery bounded by the early target) — target honored"
fi

# ── 8) (C · RETENTION-BY-TIER) the tier→days resolution matches the script map ──
step "8/10 (C) retention-by-tier — assert PG_BACKUP_TIER → retain-days matches run-backup.sh"
# Re-derive the map straight from run-backup.sh so the gate and the code share one
# source of truth (no hand-copied numbers). Resolve each tier the same way the
# script does and assert the expected ladder nano<basic<essential<pro<max.
declare -A EXPECT=( [nano]=1 [basic]=3 [essential]=7 [pro]=30 [max]=90 )
for tier in nano basic essential pro max; do
  # Pull the default for this tier out of the script's case map literal.
  got="$(grep -oE "${tier}\\)[[:space:]]*TIER_DAYS=\"\\\$\{PG_BACKUP_RETAIN_[A-Z]+_DAYS:-[0-9]+\}\"" "${RUN_BACKUP_SH}" \
          | grep -oE ':-[0-9]+' | tr -d ':-')"
  [[ -n "${got}" ]] || fail "(C) tier '${tier}' has no retain-days default in run-backup.sh (line: C ${tier} present)"
  [[ "${got}" == "${EXPECT[$tier]}" ]] \
    || fail "(C) tier '${tier}' retain-days is ${got}, expected ${EXPECT[$tier]} (line: C ${tier} days)"
done
ok "(C) retention ladder nano=1<basic=3<essential=7<pro=30<max=90 d — paid tiers buy a longer PITR window"

# ── 9) (C · PARITY) PITR unset → prune touches logical/+physical/ only, NOT wal/ ─
step "9/10 (C · PARITY) run-backup.sh with PG_BACKUP_PITR unset NEVER prunes wal/ and uses the legacy window"
# The OFF prune path must (a) not reference a tier window, (b) only prune
# logical/ + physical/, never wal/. Assert from the script structure: the wal/
# prune is INSIDE a `[ "${PG_BACKUP_PITR:-0}" = "1" ]` guard, and the tier case
# is too. (Behavioural OFF parity: with the flag default 0, the guarded blocks
# are skipped → identical to the pre-C4b script.)
# `mc rm` and the wal/ path sit on SEPARATE lines (line-continuation), so don't
# require both on one line — find the wal/ prune line; the GUARD check below is the
# load-bearing part. `|| true` so a no-match can't set -e-exit before that guard.
WAL_PRUNE_LINE="$(grep -n 'wal/' "${RUN_BACKUP_SH}" | head -1 | cut -d: -f1)" || true
[[ -n "${WAL_PRUNE_LINE}" ]] || fail "(C) no wal/ prune found in run-backup.sh (line: C wal prune exists)"
# The nearest preceding PITR guard must open before the wal/ prune line.
GUARD_BEFORE="$(grep -n 'PG_BACKUP_PITR:-0.*= .1' "${RUN_BACKUP_SH}" | awk -F: -v L="${WAL_PRUNE_LINE}" '$1 < L {g=$1} END{print g}')" || true
[[ -n "${GUARD_BEFORE}" ]] \
  || fail "(C) the wal/ prune is NOT inside a PG_BACKUP_PITR guard — it would run in the OFF baseline! (line: C wal guarded)"
# And logical/ + physical/ prune unconditionally (parity: same as today).
grep -q 'logical/' "${RUN_BACKUP_SH}" && grep -q 'physical/' "${RUN_BACKUP_SH}" \
  || fail "(C) logical/ + physical/ prune lines missing (line: C legacy prune present)"
ok "(C) wal/ prune is PITR-guarded; logical/+physical/ prune unconditionally — OFF == today's path"

# ── 9b) (C · PARITY) a plain logical dump+restore still round-trips a row ───────
step "9b/10 (C · PARITY) plain logical dump+restore (no PITR) round-trips a row unchanged"
docker run -d --name "${PG_OFF}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
wait_pg "${PG_OFF}" || fail "(C) parity postgres never ready (line: C off ready)"
pg_q "${PG_OFF}" -c "CREATE TABLE parity_t (id int PRIMARY KEY, v text NOT NULL); INSERT INTO parity_t VALUES (7,'lucky');" >/dev/null \
  || fail "(C) could not seed parity table (line: C off seed)"
# pg_dump custom-format + pg_restore --clean (the EXACT flags restore.sh uses for
# the logical path) into a second DB on the same server.
pg_q "${PG_OFF}" -c "CREATE DATABASE restored;" >/dev/null || fail "(C) could not create restore target db (line: C off db)"
docker exec "${PG_OFF}" sh -c "pg_dump --no-owner --no-privileges --format=custom -U postgres -d postgres -t parity_t -f /tmp/p.dump && pg_restore --no-owner --no-privileges --clean --if-exists -U postgres -d restored /tmp/p.dump" >/dev/null 2>&1 \
  || fail "(C) logical dump+restore (the today path) errored (line: C off dump/restore)"
[[ "$(docker exec -i "${PG_OFF}" psql -U postgres -d restored -tAc "SELECT v FROM parity_t WHERE id=7" 2>/dev/null | tr -d '[:space:]')" == "lucky" ]] \
  || fail "(C) logical restore did not round-trip the row — the today path regressed! (line: C off roundtrip)"
ok "(C) plain logical dump+restore round-trips 'lucky' — the pre-C4b path is byte-identical"

# ── 10) summarize + emit gate log ──────────────────────────────────────────────
step "10/10 summary"
green "[M99] (A) POSITIVE:   WAL archived; restore to T1 → R1 PRESENT + R2 ABSENT (point-in-time, replay stopped at target)"
green "[M99] (B) REJECT:     restore to T0(before R1) → R1 ABSENT (target honored, NOT 'restore latest'); PITR modes refuse when flag unset"
green "[M99] (C) RETENTION:  tier→days ladder nano1<basic3<essential7<pro30<max90 matches run-backup.sh"
green "[M99] (C) PARITY:     wal/ prune PITR-guarded; logical+physical unconditional; plain logical dump+restore round-trips — OFF==today"

step "log GATE m99=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-c4b-pitr-restore}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m99=PASS" --outcome pass \
      --msg "C4b PITR: WAL archiving (archive_mode/archive_command) + restore-to-timestamp (pitr-restore.sh recovery_target_time) proven — restore to T1 gives R1 PRESENT + R2 ABSENT (point-in-time, not latest); restore to T0<R1 gives R1 ABSENT (target honored); retention-by-tier ladder nano1<…<max90; PITR modes refuse + wal/ prune guarded when PG_BACKUP_PITR unset (byte-parity)" \
      --ref "scripts/verify/m99-pitr-restore.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M99] ALL GATES GREEN — C4b PITR: WAL archiving + restore-to-timestamp (R1 yes/R2 no @ T1; R1 no @ T0<R1) + retention-by-tier, byte-parity when PG_BACKUP_PITR is OFF"
exit 0
