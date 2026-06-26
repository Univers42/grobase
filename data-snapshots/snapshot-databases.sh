#!/usr/bin/env bash
#
# snapshot-databases.sh — dump every grobase data-plane engine to portable,
# compressed archives suitable for committing (size-checked for GitHub) and
# restoring on a fresh stack via restore-databases.sh.
#
# Captures: PostgreSQL, MySQL, MongoDB, MSSQL, DynamoDB(-local), MinIO objects.
# Deliberately EXCLUDED: vault42 (zero-knowledge secrets) and redis (cache).
#
# Credentials are read from each container's own env at runtime and never echoed.
# Run with the grobase stack UP (make -C apps/grobase up).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/archives"
NET="mini-baas_mini-baas"
GH_LIMIT_MB=95           # split any single archive larger than this (GitHub hard cap is 100MB)
PG_EXCLUDE="vault42"     # never dump the ZK secret store
TOOLS_MONGO="mongo:7"   # stock mongo image bundles mongodump/mongorestore
TOOLS_AWS="amazon/aws-cli"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

have_container() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# dump_postgres: one compressed custom-format dump per database (+ roles ref).
dump_postgres() {
  local c=mini-baas-postgres d
  have_container "$c" || { warn "postgres not running — skipped"; return; }
  hdr "PostgreSQL ($c)"
  docker exec "$c" sh -lc 'pg_dumpall -U postgres --globals-only --no-role-passwords' \
    | gzip -9 > "$OUT/postgres/globals.sql.gz" && ok "globals.sql.gz (roles, no passwords)"
  local dbs
  dbs=$(docker exec "$c" sh -lc "psql -U postgres -tAc \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('$PG_EXCLUDE')\"")
  for d in $dbs; do
    if [ "$d" = "postgres" ]; then
      docker exec "$c" sh -lc "pg_dump -U postgres -Fc --no-owner --no-privileges -d postgres" \
        > "$OUT/postgres/db-postgres.dump" && ok "db-postgres.dump"
    else
      docker exec "$c" sh -lc "pg_dump -U postgres -Fc --create --no-owner --no-privileges -d '$d'" \
        > "$OUT/postgres/db-$d.dump" && ok "db-$d.dump"
    fi
  done
}

# dump_mysql: per-database SQL dump, gzipped.
dump_mysql() {
  local c=mini-baas-mysql d
  have_container "$c" || { warn "mysql not running — skipped"; return; }
  hdr "MySQL ($c)"
  local dbs
  dbs=$(docker exec "$c" sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (\"mysql\",\"information_schema\",\"performance_schema\",\"sys\")" 2>/dev/null')
  for d in $dbs; do
    docker exec "$c" sh -lc "mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines --triggers --databases '$d' 2>/dev/null" \
      | gzip -9 > "$OUT/mysql/$d.sql.gz" && ok "$d.sql.gz"
  done
}

# dump_mongo: per-database gzipped BSON archive via an external tools image.
dump_mongo() {
  local c=mini-baas-mongo d uri
  have_container "$c" || { warn "mongo not running — skipped"; return; }
  hdr "MongoDB ($c)"
  uri=$(docker exec "$c" sh -lc 'printf "mongodb://%s:%s@mini-baas-mongo:27017/?authSource=admin" "$MONGO_INITDB_ROOT_USERNAME" "$MONGO_INITDB_ROOT_PASSWORD"')
  local dbs
  dbs=$(docker exec "$c" sh -lc 'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "db.adminCommand(\"listDatabases\").databases.forEach(d=>print(d.name))"' \
        | grep -vxE 'admin|config|local')
  for d in $dbs; do
    docker run --rm --network "$NET" "$TOOLS_MONGO" \
      mongodump --uri="$uri" --db="$d" --gzip --archive 2>/dev/null \
      > "$OUT/mongodb/$d.archive.gz" && ok "$d.archive.gz"
  done
}

# dump_mssql: native BACKUP per user database, copied out and gzipped.
dump_mssql() {
  local c=mini-baas-mssql d
  have_container "$c" || { warn "mssql not running — skipped"; return; }
  hdr "MSSQL ($c)"
  local SQLCMD='/opt/mssql-tools18/bin/sqlcmd -C'
  local dbs
  dbs=$(docker exec "$c" sh -lc "$SQLCMD -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -h-1 -W -Q \"SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id>4\"" 2>/dev/null)
  for d in $dbs; do
    [ -n "$d" ] || continue
    docker exec "$c" sh -lc "$SQLCMD -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -Q \"BACKUP DATABASE [$d] TO DISK=N'/tmp/$d.bak' WITH INIT, FORMAT\"" >/dev/null 2>&1 \
      && docker cp "$c:/tmp/$d.bak" "$OUT/mssql/$d.bak" >/dev/null \
      && docker exec "$c" sh -lc "rm -f /tmp/$d.bak" \
      && gzip -9 -f "$OUT/mssql/$d.bak" \
      && ok "$d.bak.gz" || warn "mssql $d backup failed"
  done
}

# dump_dynamodb: schema + full item scan per table (gzipped JSON).
dump_dynamodb() {
  local c=mini-baas-dynamodb-local
  have_container "$c" || { warn "dynamodb not running — skipped"; return; }
  hdr "DynamoDB ($c)"
  local ep="http://mini-baas-dynamodb-local:8000"
  local aws=(docker run --rm --network "$NET" -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local -e AWS_DEFAULT_REGION=us-east-1 "$TOOLS_AWS")
  local tables t
  tables=$("${aws[@]}" dynamodb list-tables --endpoint-url "$ep" --output text --query 'TableNames[]' 2>/dev/null)
  for t in $tables; do
    "${aws[@]}" dynamodb describe-table --table-name "$t" --endpoint-url "$ep" \
      --query 'Table.{TableName:TableName,KeySchema:KeySchema,AttributeDefinitions:AttributeDefinitions}' --output json \
      | gzip -9 > "$OUT/dynamodb/$t.schema.json.gz"
    "${aws[@]}" dynamodb scan --table-name "$t" --endpoint-url "$ep" --output json \
      | gzip -9 > "$OUT/dynamodb/$t.items.json.gz" && ok "$t (schema+items)"
  done
}

# dump_minio: raw object tree (small) as a gzipped tar.
dump_minio() {
  local c=mini-baas-minio
  have_container "$c" || { warn "minio not running — skipped"; return; }
  hdr "MinIO ($c)"
  docker exec "$c" sh -lc 'tar -C /data -czf - .' > "$OUT/minio/objects.tar.gz" && ok "objects.tar.gz"
}

# split_large: break any archive above the GitHub limit into <limit parts.
split_large() {
  hdr "GitHub size guard (>${GH_LIMIT_MB}MB → split)"
  local f sz
  while IFS= read -r f; do
    sz=$(( $(stat -c%s "$f") / 1048576 ))
    if [ "$sz" -gt "$GH_LIMIT_MB" ]; then
      split -b "${GH_LIMIT_MB}m" -d "$f" "$f.part" && rm -f "$f" \
        && ok "split $(basename "$f") (${sz}MB) into parts"
    fi
  done < <(find "$OUT" -type f ! -name '*.part*')
  ok "all archives within GitHub per-file limit"
}

# build_manifest: machine-readable index (engine, file, size, sha256).
build_manifest() {
  hdr "Manifest"
  python3 - "$OUT" <<'PY'
import hashlib, json, os, sys, datetime
out = sys.argv[1]
files = []
for root, _, names in os.walk(out):
    for n in sorted(names):
        if n == "MANIFEST.json":
            continue
        p = os.path.join(root, n)
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        files.append({
            "engine": os.path.basename(root),
            "file": os.path.relpath(p, out),
            "bytes": os.path.getsize(p),
            "sha256": h.hexdigest(),
        })
manifest = {
    "stack": "mini-baas (grobase)",
    "created_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "excluded": ["vault42 (zero-knowledge secrets)", "redis (cache)"],
    "total_bytes": sum(f["bytes"] for f in files),
    "files": files,
}
with open(os.path.join(out, "MANIFEST.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
print(f"  wrote MANIFEST.json — {len(files)} files, "
      f"{manifest['total_bytes']/1048576:.1f} MB total")
PY
}

main() {
  printf '\033[1mgrobase data snapshot →\033[0m %s\n' "$OUT"
  dump_postgres
  dump_mysql
  dump_mongo
  dump_mssql
  dump_dynamodb
  dump_minio
  split_large
  build_manifest
  hdr "Done"
  du -sh "$OUT"
}

main "$@"
