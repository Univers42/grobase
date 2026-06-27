#!/usr/bin/env bash
#
# restore-databases.sh — load the snapshot archives into a freshly-started
# grobase stack (the counterpart to snapshot-databases.sh).
#
# DESTRUCTIVE: drops/replaces existing databases with the snapshot contents.
# Refuses to run without explicit confirmation.
#
# Usage:
#   make -C apps/grobase up          # bring the stack up first
#   CONFIRM=1 ./restore-databases.sh # then load the data
#
# Reassembles any split *.partNN files automatically before restoring.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IN="$HERE/archives"
NET="mini-baas_mini-baas"
TOOLS_MONGO="mongo:7"
TOOLS_AWS="amazon/aws-cli"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have_container() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

if [ "${CONFIRM:-0}" != "1" ] && [ "${1:-}" != "--yes" ]; then
  echo "This OVERWRITES databases in the running stack with the snapshot." >&2
  echo "Re-run with CONFIRM=1 (or --yes) once the stack is up." >&2
  exit 2
fi

# reassemble_parts: cat any <file>.partNN back into <file>.
reassemble_parts() {
  local base
  for base in $(find "$IN" -name '*.part00' | sed 's/\.part00$//' | sort -u); do
    [ -f "$base" ] || { cat "$base".part* > "$base" && ok "reassembled $(basename "$base")"; }
  done
}

restore_postgres() {
  local c=mini-baas-postgres f db pw
  have_container "$c" || { warn "postgres not running — skipped"; return; }
  hdr "PostgreSQL"
  pw=$(docker exec "$c" printenv POSTGRES_PASSWORD 2>/dev/null)
  [ -f "$IN/postgres/globals.sql.gz" ] && \
    gunzip -c "$IN/postgres/globals.sql.gz" | docker exec -i -e PGPASSWORD="$pw" "$c" psql -U postgres -v ON_ERROR_STOP=0 -q >/dev/null 2>&1 && ok "roles (existing ignored)"
  for f in "$IN"/postgres/db-*.dump; do
    [ -f "$f" ] || continue
    db=$(basename "$f" .dump); db=${db#db-}
    if [ "$db" = "postgres" ]; then
      docker exec -i -e PGPASSWORD="$pw" "$c" pg_restore --clean --if-exists --no-owner --no-privileges -d postgres < "$f" >/dev/null 2>&1
    else
      docker exec -i -e PGPASSWORD="$pw" "$c" pg_restore --create --clean --if-exists --no-owner --no-privileges -d postgres < "$f" >/dev/null 2>&1
    fi
    ok "restored $db"
  done
}

restore_mysql() {
  local c=mini-baas-mysql f
  have_container "$c" || { warn "mysql not running — skipped"; return; }
  hdr "MySQL"
  for f in "$IN"/mysql/*.sql.gz; do
    [ -f "$f" ] || continue
    gunzip -c "$f" | docker exec -i "$c" sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' 2>/dev/null \
      && ok "restored $(basename "$f" .sql.gz)"
  done
}

restore_mongo() {
  local c=mini-baas-mongo f uri
  have_container "$c" || { warn "mongo not running — skipped"; return; }
  hdr "MongoDB"
  uri=$(docker exec "$c" sh -lc 'printf "mongodb://%s:%s@mini-baas-mongo:27017/?authSource=admin" "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"')
  for f in "$IN"/mongodb/*.archive.gz; do
    [ -f "$f" ] || continue
    docker run --rm -i --network "$NET" "$TOOLS_MONGO" \
      mongorestore --uri="$uri" --gzip --archive --drop < "$f" >/dev/null 2>&1 \
      && ok "restored $(basename "$f" .archive.gz)"
  done
}

restore_mssql() {
  local c=mini-baas-mssql f db
  have_container "$c" || { warn "mssql not running — skipped"; return; }
  hdr "MSSQL"
  local SQLCMD='/opt/mssql-tools18/bin/sqlcmd -C'
  for f in "$IN"/mssql/*.bak.gz; do
    [ -f "$f" ] || continue
    db=$(basename "$f" .bak.gz)
    gunzip -c "$f" > "/tmp/$db.bak"
    docker cp "/tmp/$db.bak" "$c:/tmp/$db.bak" >/dev/null && rm -f "/tmp/$db.bak"
    local moves
    moves=$(docker exec "$c" sh -lc "$SQLCMD -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -h-1 -W -Q \"SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK='/tmp/$db.bak'\" 2>/dev/null" \
      | awk -v d="$db" '{n=$1; t=$3} t=="L"{printf ", MOVE N'\''%s'\'' TO N'\''/var/opt/mssql/data/%s.ldf'\''",n,n} t=="D"{printf ", MOVE N'\''%s'\'' TO N'\''/var/opt/mssql/data/%s.mdf'\''",n,n}')
    docker exec "$c" sh -lc "$SQLCMD -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -Q \"RESTORE DATABASE [$db] FROM DISK='/tmp/$db.bak' WITH REPLACE$moves\"" >/dev/null 2>&1 \
      && ok "restored $db" || warn "mssql $db restore failed (check MOVE paths)"
    docker exec "$c" sh -lc "rm -f /tmp/$db.bak"
  done
}

restore_dynamodb() {
  local c=mini-baas-dynamodb-local
  have_container "$c" || { warn "dynamodb not running — skipped"; return; }
  hdr "DynamoDB"
  local ep="http://mini-baas-dynamodb-local:8000"
  local work; work=$(mktemp -d)
  python3 - "$IN/dynamodb" "$work" <<'PY'
import gzip, json, os, sys
src, work = sys.argv[1], sys.argv[2]
tables = sorted(f[:-len(".schema.json.gz")] for f in os.listdir(src) if f.endswith(".schema.json.gz"))
for t in tables:
    sch = json.load(gzip.open(os.path.join(src, f"{t}.schema.json.gz")))
    create = {
        "TableName": sch["TableName"],
        "AttributeDefinitions": sch["AttributeDefinitions"],
        "KeySchema": sch["KeySchema"],
        "BillingMode": "PAY_PER_REQUEST",
    }
    json.dump(create, open(os.path.join(work, f"{t}.create.json"), "w"))
    items = json.load(gzip.open(os.path.join(src, f"{t}.items.json.gz"))).get("Items", [])
    for i in range(0, len(items), 25):
        batch = {sch["TableName"]: [{"PutRequest": {"Item": it}} for it in items[i:i+25]]}
        json.dump(batch, open(os.path.join(work, f"{t}.batch.{i//25:04d}.json"), "w"))
    print(t, len(items))
PY
  local t
  for t in $(ls "$work"/*.create.json 2>/dev/null | sed 's#.*/##; s/\.create\.json$//'); do
    docker run --rm --network "$NET" -v "$work":/work -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local -e AWS_DEFAULT_REGION=us-east-1 "$TOOLS_AWS" \
      dynamodb create-table --cli-input-json "file:///work/$t.create.json" --endpoint-url "$ep" >/dev/null 2>&1
    local b
    for b in "$work/$t".batch.*.json; do
      [ -f "$b" ] || continue
      docker run --rm --network "$NET" -v "$work":/work -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local -e AWS_DEFAULT_REGION=us-east-1 "$TOOLS_AWS" \
        dynamodb batch-write-item --request-items "file:///work/$(basename "$b")" --endpoint-url "$ep" >/dev/null 2>&1
    done
    ok "restored $t"
  done
  rm -rf "$work"
}

restore_minio() {
  local c=mini-baas-minio
  have_container "$c" || { warn "minio not running — skipped"; return; }
  hdr "MinIO"
  [ -f "$IN/minio/objects.tar.gz" ] || { warn "no minio archive"; return; }
  cat "$IN/minio/objects.tar.gz" | docker exec -i "$c" sh -lc 'tar -C /data -xzf -' \
    && ok "restored objects (restart minio to pick up: docker restart mini-baas-minio)"
}

main() {
  printf '\033[1mgrobase data restore ←\033[0m %s\n' "$IN"
  reassemble_parts
  restore_postgres
  restore_mysql
  restore_mongo
  restore_mssql
  restore_dynamodb
  restore_minio
  hdr "Done — restart app services if needed (docker restart mini-baas-minio mini-baas-realtime)"
}

main "$@"
