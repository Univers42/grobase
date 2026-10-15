#!/bin/sh
# vault-seed.sh — capture every engine's DATA into ./secrets, the exact file set
# scripts/ops/vault-restore.sh replays. The missing half of the pair.
#
# WHY THIS EXISTS
#
# There was a restore path and no capture path. The seeds in ./secrets were produced by
# hand: `grep -rl postgres-all.sql.gz` across the whole monorepo matches only the two
# scripts that READ them. A restore source nobody can regenerate goes stale exactly the way
# the committed snapshot did — data-snapshots/archives, dated 2026-07-28 and deleted on
# 2026-10-07, carried engines whose coverage no longer matched what a default `make all` ran.
# Unreproducible backups are how you end up with two divergent sources of truth and no way
# to tell which one is right.
#
# COVERAGE IS RECORDED, NOT ASSUMED
#
# Every dump here is `have_container || skip`, because a stack legitimately runs different
# engines per edition: the local default (devlean) runs postgres/mysql/mongo/minio/redis,
# while `GROBASE_EDITION=migrate` adds mssql and dynamodb from the engines-extra profile.
# A capture taken under one edition therefore CANNOT cover the other — and a half-capture
# that looks complete is worse than a missing one, because the restore still "succeeds".
#
# So this writes MANIFEST.json naming exactly which engines were captured and which were
# skipped, and vault-restore.sh / restore-if-empty.sh can refuse to use a seed set that
# does not cover the engines actually running. Silence is the failure mode this whole
# project keeps getting bitten by; coverage is data, not a comment.
#
# NEVER DESTRUCTIVE. Each artefact is written to a temp file and moved into place only on a
# successful dump, so a failed engine leaves the previous good copy intact. Nothing is ever
# deleted — including artefacts this script cannot produce (the local CA, the Inception and
# vite-gourmand archives), which are captured elsewhere and merely checksummed here.
#
# Usage:
#   bash scripts/ops/vault-seed.sh                     # capture into ./secrets
#   SEED_DIR=/tmp/seeds bash scripts/ops/vault-seed.sh # capture somewhere else
#   make -C apps/grobase vault-seed                    # same, via make
#
# Then push them to the vault from the SUPERPROJECT root: make vault42-push-all
set -eu

SEED_DIR="${SEED_DIR:-./secrets}"
NET="${NET:-mini-baas_mini-baas}"
. "$(CDPATH='' cd -- "$(dirname -- "$0")/../lib" && pwd)/lib-netseg.sh"
. "$(CDPATH='' cd -- "$(dirname -- "$0")/../lib" && pwd)/lib-packets.sh"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"
MC_IMAGE="${MC_IMAGE:-ghcr.io/univers42/grobase-mc:latest}"
AWS_IMAGE="${AWS_IMAGE:-amazon/aws-cli}"
CAPTURED=""
SKIPPED=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
note() { printf '[vault-seed] %s\n' "$*" >&2; }
have_container() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# took ENGINE / missed ENGINE REASON — coverage is recorded, never inferred later.
took() {
  CAPTURED="$CAPTURED $1"
  note "$1: captured"
}
missed() {
  SKIPPED="$SKIPPED $1"
  note "$1: SKIPPED ($2)"
}

# commit_if_ok ENGINE TMP DEST — move into place only on a non-empty dump, so a failed
# engine leaves the previous good copy where it was.
commit_if_ok() {
  if [ -s "$2" ]; then
    mv -f "$2" "$3"
    took "$1"
  else
    rm -f "$2"
    missed "$1" "dump was empty or failed"
  fi
}

# commit_archive ENGINE TMP DEST — same, but an EMPTY tar.gz is ~112 bytes and sails past a
# plain `-s` test. Measured: minio "captured" a 112-byte tar holding nothing while the real
# bucket data was 8.6 MiB, and the run reported success — the silent half-capture this
# script exists to make impossible. Archives must contain something.
commit_archive() {
  entries=$(tar -tzf "$2" 2>/dev/null | sed '/^\.\/*$/d' | grep -c . || true)
  if [ "${entries:-0}" -gt 0 ]; then
    mv -f "$2" "$3"
    took "$1"
  else
    rm -f "$2"
    missed "$1" "archive came back empty (0 entries)"
  fi
}

guard() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  mkdir -p "$SEED_DIR" || die "cannot create $SEED_DIR"
}

# Seeds carry DATA, never credentials. A whole-instance dump otherwise ships the source
# machine's role SCRAM hashes, MongoDB users and MariaDB grant tables into the shared vault,
# and replaying them onto another machine overwrites its passwords and locks every app out
# of its own databases — measured, see scripts/ops/vault-restore.sh. The restore side filters
# them too (so older seeds are safe); keeping them out of the capture means they are never
# stored in the vault at all. Mongo cannot exclude admin users from a whole-instance
# mongodump, so that one is filtered only at restore.
seed_postgres() {
  have_container mini-baas-postgres || {
    missed postgres "container not running"
    return 0
  }
  t="$SEED_DIR/.postgres-all.sql.gz.tmp"
  docker exec mini-baas-postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_USER" --clean --no-role-passwords' 2>/dev/null |
    gzip -9 >"$t" || true
  commit_if_ok postgres "$t" "$SEED_DIR/postgres-all.sql.gz"
}

seed_mysql() {
  have_container mini-baas-mysql || {
    missed mysql "container not running"
    return 0
  }
  t="$SEED_DIR/.mysql-all.sql.gz.tmp"
  # Application schemas only: --all-databases would include the `mysql` grant tables.
  # MYSQL_PWD rather than -p so the password is not in the container's process list.
  docker exec mini-baas-mysql sh -c \
    'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
		 dbs=$(mysql -u root -N -e "SELECT schema_name FROM information_schema.schemata
		   WHERE schema_name NOT IN (\"mysql\",\"information_schema\",\"performance_schema\",\"sys\")")
		 [ -n "$dbs" ] && mysqldump -u root --databases $dbs --single-transaction --routines --events' \
    2>/dev/null | gzip -9 >"$t" || true
  commit_if_ok mysql "$t" "$SEED_DIR/mysql-all.sql.gz"
}

seed_mongo() {
  have_container mini-baas-mongo || {
    missed mongo "container not running"
    return 0
  }
  MU="$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_USERNAME)"
  MP="$(docker exec mini-baas-mongo printenv MONGO_INITDB_ROOT_PASSWORD)"
  export MU MP
  t="$SEED_DIR/.mongo.archive.gz.tmp"
  docker run --rm --network "$(engine_net mini-baas-mongo "$NET")" -e MU -e MP --entrypoint sh "$MONGO_IMAGE" -c \
    'mongodump --host mini-baas-mongo --port 27017 --username "$MU" --password "$MP" \
		 --authenticationDatabase admin --archive --gzip' 2>/dev/null >"$t" || true
  commit_if_ok mongo "$t" "$SEED_DIR/mongo.archive.gz"
}

# minio: mirror OUT to a staging dir, then tar it. restore_minio untars and mirrors back,
# so the tar's top-level entries must be bucket directories — mirror produces exactly that.
# The mirror lands in the mc container's own layer (/home/mc is its uid's) and leaves through
# `docker cp`, never a bind mount: a -v path names a directory on the DAEMON's host, so under
# DOCKER_HOST=ssh://<data center> the mirror filled a directory over there and this side
# tarred an empty stage (2026-10-12: "minio: SKIPPED (archive came back empty)").
# `mc mirror` refuses a target that does not exist and the image (scratch) has no mkdir, so
# the empty stage goes in first: docker cp gives /home/mc/out the stage's owner and 0777
# mode, which mc's uid 1001 can write.
# The container has a fixed name because its env holds the MinIO root credentials: an
# interrupted run leaves it behind, and the next run removes it before creating its own.
# Only a mirror AND a copy-out that both succeeded are tarred — a partial copy-out would
# otherwise replace the last good minio.tar.gz.
seed_minio() {
  have_container mini-baas-minio || {
    missed minio "container not running"
    return 0
  }
  stage="$(mktemp -d)"
  MC_HOST_seed="http://$(docker exec mini-baas-minio printenv MINIO_ROOT_USER):$(docker exec mini-baas-minio printenv MINIO_ROOT_PASSWORD)@mini-baas-minio:9000"
  export MC_HOST_seed
  ctr=vault-seed-mc
  docker rm -f "$ctr" >/dev/null 2>&1 || true
  chmod 0777 "$stage"
  mirrored=0
  if docker create --name "$ctr" --network "$NET" -e MC_HOST_seed -e HOME=/tmp \
    --tmpfs /tmp:rw,size=16m "$MC_IMAGE" mirror --quiet seed /home/mc/out >/dev/null 2>&1 &&
    docker cp "$stage/." "$ctr:/home/mc/out" >/dev/null 2>&1 && chmod 0700 "$stage" &&
    docker start -a "$ctr" >/dev/null 2>&1 &&
    docker cp "$ctr:/home/mc/out/." "$stage" >/dev/null 2>&1; then
    mirrored=1
  fi
  docker rm -f "$ctr" >/dev/null 2>&1 || true
  chmod 0700 "$stage"
  if [ "$mirrored" -ne 1 ]; then
    rm -rf "$stage"
    missed minio "mirror or copy-out failed"
    return 0
  fi
  t="$SEED_DIR/.minio.tar.gz.tmp"
  tar -czf "$t" -C "$stage" . 2>/dev/null || true
  rm -rf "$stage"
  commit_archive minio "$t" "$SEED_DIR/minio.tar.gz"
}

# redis: BGSAVE then copy dump.rdb OUT. The restore side needs an RDB because a running
# redis with appendonly on ignores one dropped in — see vault-restore.sh's redis notes.
seed_redis() {
  have_container mini-baas-redis || {
    missed redis "container not running"
    return 0
  }
  docker exec mini-baas-redis redis-cli BGSAVE >/dev/null 2>&1 || true
  n=0
  while [ "$n" -lt 30 ]; do
    if docker exec mini-baas-redis redis-cli INFO persistence 2>/dev/null |
      grep -q '^rdb_bgsave_in_progress:0'; then
      break
    fi
    n=$((n + 1))
    sleep 1
  done
  t="$SEED_DIR/.redis.rdb.tmp"
  docker cp mini-baas-redis:/data/dump.rdb "$t" >/dev/null 2>&1 || true
  commit_if_ok redis "$t" "$SEED_DIR/redis.rdb"
}

# mssql lives in the engines-extra profile, so it is absent under the default edition.
# BACKUP DATABASE per user database (database_id>4 skips the system ones), tarred together.
seed_mssql() {
  have_container mini-baas-mssql || {
    missed mssql "container not running (engines-extra profile)"
    return 0
  }
  sqlcmd='/opt/mssql-tools18/bin/sqlcmd -C'
  stage="$(mktemp -d)"
  dbs=$(docker exec mini-baas-mssql sh -lc \
    "$sqlcmd -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -h-1 -W -Q \"SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id>4\"" 2>/dev/null || true)
  for d in $dbs; do
    [ -n "$d" ] || continue
    docker exec mini-baas-mssql sh -lc \
      "$sqlcmd -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -Q \"BACKUP DATABASE [$d] TO DISK=N'/tmp/$d.bak' WITH INIT, FORMAT\"" >/dev/null 2>&1 &&
      docker cp "mini-baas-mssql:/tmp/$d.bak" "$stage/$d.bak" >/dev/null 2>&1 &&
      docker exec mini-baas-mssql sh -lc "rm -f /tmp/$d.bak" >/dev/null 2>&1 || true
  done
  t="$SEED_DIR/.mssql-all.tar.gz.tmp"
  tar -czf "$t" -C "$stage" . 2>/dev/null || true
  rm -rf "$stage"
  commit_archive mssql "$t" "$SEED_DIR/mssql-all.tar.gz"
}

# dynamodb also lives behind engines-extra (via the hypertube profile).
seed_dynamodb() {
  have_container mini-baas-dynamodb-local || {
    missed dynamodb "container not running (engines-extra profile)"
    return 0
  }
  ep=http://mini-baas-dynamodb-local:8000
  stage="$(mktemp -d)"
  tables=$(docker run --rm --network "$(engine_net mini-baas-dynamodb-local "$NET")" -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 "$AWS_IMAGE" dynamodb list-tables --endpoint-url "$ep" \
    --output text --query 'TableNames[]' 2>/dev/null || true)
  for tb in $tables; do
    [ -n "$tb" ] || continue
    docker run --rm --network "$(engine_net mini-baas-dynamodb-local "$NET")" -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local \
      -e AWS_DEFAULT_REGION=us-east-1 "$AWS_IMAGE" dynamodb describe-table --table-name "$tb" \
      --endpoint-url "$ep" --query 'Table.{TableName:TableName,KeySchema:KeySchema,AttributeDefinitions:AttributeDefinitions}' \
      --output json >"$stage/$tb.schema.json" 2>/dev/null || true
    docker run --rm --network "$(engine_net mini-baas-dynamodb-local "$NET")" -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local \
      -e AWS_DEFAULT_REGION=us-east-1 "$AWS_IMAGE" dynamodb scan --table-name "$tb" \
      --endpoint-url "$ep" --output json >"$stage/$tb.items.json" 2>/dev/null || true
  done
  t="$SEED_DIR/.dynamodb-all.tar.gz.tmp"
  tar -czf "$t" -C "$stage" . 2>/dev/null || true
  rm -rf "$stage"
  commit_archive dynamodb "$t" "$SEED_DIR/dynamodb-all.tar.gz"
}

# The manifest is what lets a restore refuse a seed set that does not cover the engines
# actually running. Written last so it describes what really landed.
write_manifest() {
  cap=$(printf '%s' "$CAPTURED" | tr ' ' '\n' | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd, -)
  skp=$(printf '%s' "$SKIPPED" | tr ' ' '\n' | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd, -)
  # The packets are built BEFORE the file is opened: a manifest that names a dump nobody
  # wrote is the half-capture this script exists to make impossible, so fail instead.
  set --
  for eng in $CAPTURED; do set -- "$@" "$eng"; done
  packets=$(packets_json "$SEED_DIR" "$@") ||
    die "cannot describe the captured packets in $SEED_DIR: a captured dump is missing, or an engine has no artifact name"
  cat >"$SEED_DIR/MANIFEST.json" <<EOF
{
  "created_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "vault-seed.sh",
  "captured": [${cap:-}],
  "skipped": [${skp:-}],
  "manifest_version": 2,
  "packets": ${packets:-[]}
}
EOF
  note "manifest written"
}

# SHA256SUMS lists the seed set: MANIFEST.json and the data archives beside it. The seed dir
# is usually a checkout's ./secrets, which also holds personal credential files (*.env, a
# password store) that a vault push seals to their owner. Listing those published their names
# and hashes to every teammate, whose checkout never receives them and so failed the list
# (2026-10-15: four personal files listed). Written to a temp file and moved, so a failure
# leaves the previous list rather than a partial one.
# Caveat: an archive is recognised by its suffix (.gz .tgz .tar .rdb .zst .bz2 .xz). One in a
# new format with another suffix is left out, and its restore goes unverified until the suffix
# is added here; a credential file given one of these suffixes would be listed.
write_sums() {
  (cd "$SEED_DIR" && find . -maxdepth 1 -type f ! -name '.*' \( -name MANIFEST.json -o -name '*.gz' \
    -o -name '*.tgz' -o -name '*.tar' -o -name '*.rdb' -o -name '*.zst' -o -name '*.bz2' -o -name '*.xz' \) |
    sed 's#^\./##' | sort | xargs sha256sum >.SHA256SUMS.tmp && mv -f .SHA256SUMS.tmp SHA256SUMS) ||
    die "cannot checksum the seed set in $SEED_DIR — SHA256SUMS left as it was"
  note "checksums written"
}

main() {
  guard
  seed_postgres
  seed_mysql
  seed_mongo
  seed_minio
  seed_redis
  seed_mssql
  seed_dynamodb
  # A run that captured nothing describes nothing. Writing MANIFEST.json anyway replaced the
  # last capture's record with "captured: []", which grobase-import refuses and a restore reads
  # as no coverage (2026-10-15: `make vault42-seed` on a host whose stack runs in a VM).
  [ -n "$CAPTURED" ] ||
    die "no engine container is running here, so nothing was captured; MANIFEST.json and SHA256SUMS in $SEED_DIR are unchanged — run this on the machine whose \`docker ps\` lists mini-baas-postgres"
  write_manifest
  write_sums
  note "captured:$CAPTURED"
  if [ -n "$SKIPPED" ]; then
    note "skipped:$SKIPPED — bring those engines up and re-run to cover them"
  fi
  note "done. Push from the superproject root: make vault42-push-all"
}

main "$@"
