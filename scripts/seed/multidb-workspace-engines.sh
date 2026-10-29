# shellcheck shell=bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    multidb-workspace-engines.sh                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# The ten engines' seed_<engine> and teardown steps for multidb-workspace.sh,
# which sources this file and provides the driver (line/act/gate), the naming
# (DB, TABLES_STD, TABLES_NS, COUNTS) and the apply-only plumbing (pg, crdb, my,
# ms, mongo_run, ddb*, register, assoc, gw_rows…). Every step goes through act
# or gate, so plan mode prints it and only --apply runs it. Not runnable alone.

# ── per-engine seed steps ────────────────────────────────────────────────────
# seed_tail LABEL TABLES CHECK… — register is done; check it answers, then associate.
seed_tail() {
  local label="$1" tables="$2"
  shift 2
  act "check the mount answers ($*)" "$@" &&
    act "associate target=${DB}_${CUR} with workspace ${WS} as '${label}' (tables ${tables})" assoc "${label}" "${tables}"
}
seed_postgresql() {
  local dsn
  dsn="postgres://$(urlenc "${PG_USER:-}"):$(urlenc "${PG_PASS:-}")@postgres:5432/${DB}"
  gate "mini-baas-postgres healthy, POSTGRES_PASSWORD set" pg_ready || return 0
  act "create database target=${DB} if absent" pg_ensure_db || return 0
  act "create tables ${TABLES_STD} if absent and load rows if absent (${COUNTS}) — ON CONFLICT DO NOTHING" pg_load "${DB}" || return 0
  act "register mount target=${DB}_postgresql (postgres://…@postgres:5432/${DB})" register postgresql "${dsn}" || return 0
  seed_tail "MDW · PostgreSQL" "${TABLES_STD}" check_schema
}
pg_ready() { ma_ready mini-baas-postgres && need PG_PASS POSTGRES_PASSWORD; }
pg_ensure_db() { pg -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB}'" | grep -q 1 || pg -d postgres -c "CREATE DATABASE ${DB}"; }
pg_load() { "${GEN[@]}" sql-pg | pg -d "$1" >/dev/null; }
seed_cockroachdb() {
  gate "mini-baas-cockroach healthy (insecure single node, root)" ma_ready mini-baas-cockroach || return 0
  act "create database target=${DB} if absent" crdb -e "CREATE DATABASE IF NOT EXISTS ${DB}" || return 0
  act "create tables ${TABLES_STD} if absent and load rows if absent (${COUNTS}) — ON CONFLICT DO NOTHING" crdb_load || return 0
  act "register mount target=${DB}_cockroachdb (postgres://root@cockroach:26257/${DB})" \
    register cockroachdb "postgres://root@cockroach:26257/${DB}?sslmode=disable" || return 0
  seed_tail "MDW · CockroachDB" "${TABLES_STD}" check_schema
}
crdb_load() { "${GEN[@]}" sql-pg | crdb -d "${DB}" >/dev/null; }
# seed_mysqlish ENGINE CONTAINER CLIENT HOST ENV-PREFIX LABEL — mysql and mariadb.
seed_mysqlish() {
  local engine="$1" c="$2" bin="$3" host="$4" pfx="$5" label="$6"
  MY_USER="" MY_PASS="" MY_ROOT=""
  if ((APPLY)); then
    MY_USER="$(_lt_env "${c}" "${pfx}_USER")" MY_PASS="$(_lt_env "${c}" "${pfx}_PASSWORD")"
    MY_ROOT="$(_lt_env "${c}" "${pfx}_ROOT_PASSWORD")"
  fi
  gate "${c} healthy, ${pfx}_USER/${pfx}_PASSWORD/${pfx}_ROOT_PASSWORD set" my_ready "${c}" "${pfx}" || return 0
  act "create database target=${DB} if absent, grant it to ${pfx}_USER" \
    my "${c}" "${bin}" MY_ROOT -e "CREATE DATABASE IF NOT EXISTS ${DB} CHARACTER SET utf8mb4; GRANT ALL PRIVILEGES ON ${DB}.* TO '${MY_USER}'@'%';" || return 0
  act "create tables ${TABLES_STD} if absent and load rows if absent (${COUNTS}) — INSERT IGNORE" my_load "${c}" "${bin}" || return 0
  act "register mount target=${DB}_${engine} (mysql://…@${host}:3306/${DB})" \
    register "${engine}" "mysql://$(urlenc "${MY_USER}"):$(urlenc "${MY_PASS}")@${host}:3306/${DB}" || return 0
  seed_tail "${label}" "${TABLES_STD}" check_schema
}
my_ready() { ma_ready "$1" && need MY_USER "$2_USER" && need MY_PASS "$2_PASSWORD" && need MY_ROOT "$2_ROOT_PASSWORD" && [[ "${MY_USER}" =~ ^[A-Za-z0-9_]+$ ]]; }
my_load() { "${GEN[@]}" sql-mysql | my "$1" "$2" MY_ROOT "${DB}"; }
seed_mysql() { seed_mysqlish mysql mini-baas-mysql mysql mysql MYSQL "MDW · MySQL"; }
seed_mariadb() { seed_mysqlish mariadb mini-baas-mariadb mariadb mariadb MARIADB "MDW · MariaDB"; }
seed_mongodb() {
  gate "mini-baas-mongo healthy, MONGO_INITDB_ROOT_USERNAME/PASSWORD set" mongo_ready || return 0
  act "upsert-if-absent documents into ${TABLES_STD} of database target=${DB} (${COUNTS}) — \$setOnInsert" mongo_run mongo-js || return 0
  act "register mount target=${DB}_mongodb (mongodb://…@mongo:27017/${DB})" register mongodb "${MONGO_URI}" || return 0
  seed_tail "MDW · MongoDB" "${TABLES_STD}" check_schema
}
mongo_ready() {
  ma_ready mini-baas-mongo || return 1
  local u p
  u="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_USERNAME)" p="$(_lt_env mini-baas-mongo MONGO_INITDB_ROOT_PASSWORD)"
  need u MONGO_INITDB_ROOT_USERNAME && need p MONGO_INITDB_ROOT_PASSWORD &&
    MONGO_URI="mongodb://$(urlenc "${u}"):$(urlenc "${p}")@mongo:27017/${DB}?authSource=admin"
}
seed_redis() {
  gate "mini-baas-redis healthy and redis in the router's engines" redis_ready || return 0
  act "register mount target=${DB}_redis (redis://redis:6379, no auth in compose)" register redis "redis://redis:6379" || return 0
  act "insert-if-absent hashes into ${TABLES_NS} (${COUNTS}) via /query/v1 op=insert; key = <owner>:<resource>:<id>" gw_rows_str insert || return 0
  seed_tail "MDW · Redis" "${TABLES_NS}" check_list "${TABLES_NS%%,*}"
}
redis_ready() { ma_ready mini-baas-redis && has_engine redis; }
gw_rows_str() { "${GEN[@]}" "$([[ "$1" == insert ]] && echo rows-str || echo ids-str)" "${DB}" | gw_rows "$1"; }
seed_sqlite() {
  gate "sqlite in the running router's engines (file inside the router container)" has_engine sqlite || return 0
  act "register mount target=${DB}_sqlite (sqlite:///tmp/${DB}.db)" register sqlite "sqlite:///tmp/${DB}.db" || return 0
  act "check the mount answers (check_schema)" check_schema || return 0
  act "create tables ${TABLES_STD} via /schema/ddl op=create_table (409/exists = present)" sqlite_ddl || return 0
  act "insert-if-absent rows (${COUNTS}) via /query/v1 op=insert; the data plane stamps owner_id" sqlite_rows || return 0
  act "associate target=${DB}_sqlite with workspace ${WS} as 'MDW · SQLite' (tables ${TABLES_STD})" assoc "MDW · SQLite" "${TABLES_STD}"
}
sqlite_ddl() { "${GEN[@]}" sqlite-ddl | gw_ddl; }
sqlite_rows() { "${GEN[@]}" rows-int | gw_rows insert; }
seed_mssql() {
  MS_PASS=""
  ((!APPLY)) || MS_PASS="$(_lt_env mini-baas-mssql MSSQL_SA_PASSWORD)"
  gate "mini-baas-mssql healthy, MSSQL_SA_PASSWORD set (no fallback) and free of '@'" mssql_ready || return 0
  act "create database target=${DB} if absent" ms -Q "IF DB_ID('${DB}') IS NULL CREATE DATABASE ${DB};" || return 0
  act "create tables ${TABLES_STD} if absent and load rows if absent (${COUNTS}) — IF NOT EXISTS" mssql_load || return 0
  # Raw password, unlike the url-crate engines: mssql_config (data-plane-pool
  # mssql/adapter.rs) splits user:pass@host literally and never percent-decodes,
  # so an encoded '%' logs in with the wrong password and the check times out.
  # Caveat: a password containing '@' cannot be expressed in this DSN.
  act "register mount target=${DB}_mssql (mssql://sa:…@mssql:1433/${DB})" register mssql "mssql://sa:${MS_PASS}@mssql:1433/${DB}" || return 0
  seed_tail "MDW · MSSQL" "${TABLES_STD}" check_schema
}
mssql_ready() { ma_ready mini-baas-mssql && need MS_PASS MSSQL_SA_PASSWORD && [[ "${MS_PASS}" != *@* ]]; }
mssql_load() { "${GEN[@]}" sql-mssql | ms -d "${DB}" >/dev/null; }
seed_http() {
  gate "MDW_HTTP_BASE_URL is a public http(s) URL (SSRF guard refuses in-stack hosts); unset ⇒ skip" http_ready || return 0
  act "register mount target=${DB}_http ({\"baseUrl\": MDW_HTTP_BASE_URL})" register http "{\"baseUrl\":\"${MDW_HTTP_BASE_URL:-}\"}" || return 0
  line "load rows: none — an http mount's rows live upstream; this seeder writes nothing outside grobase"
  seed_tail "MDW · HTTP" "${TABLES_STD}" check_list mdw_churn
}
http_ready() { [[ "${MDW_HTTP_BASE_URL:-}" =~ ^https?://[^\"[:space:]]+$ ]]; }
seed_dynamodb() {
  gate "mini-baas-dynamodb-local healthy and dynamodb in the router's engines (cargo feature)" dynamo_ready || return 0
  act "register mount target=${DB}_dynamodb (4xx ⇒ DYNAMODB_ENGINE_ENABLED off: skip)" \
    register dynamodb "dynamodb://local?endpoint=${DDB_ENDPOINT}&region=us-east-1&access_key=fake&secret_key=fake" || return 0
  act "create tables ${TABLES_NS} if absent (owner_pk HASH + id RANGE) via aws-cli" ddb_create || return 0
  act "insert-if-absent items (${COUNTS}) via /query/v1 op=insert (attribute_not_exists)" gw_rows_str insert || return 0
  seed_tail "MDW · DynamoDB" "${TABLES_NS}" check_list "${TABLES_NS%%,*}"
}
dynamo_ready() { ma_ready mini-baas-dynamodb-local && has_engine dynamodb; }

# ── per-engine teardown: only the mdw_<ws> names this script creates ─────────
teardown_engine() {
  act "look up mount target=${DB}_${CUR} by name" lookup || return 0
  act "remove the association of target=${DB}_${CUR} from workspace ${WS} (by db_id)" td_unassoc || true
  case "${CUR}" in
  redis | dynamodb) act "delete rows of ${TABLES_NS//,/ } by fixed id (target=${TABLES_NS//,/ target=})" td_rows || true ;;
  sqlite) act "drop tables target=${TABLES_STD//,/ target=} via /schema/ddl" td_sqlite || true ;;
  esac
  act "deregister mount target=${DB}_${CUR}" td_deregister || true
  case "${CUR}" in
  postgresql) act "drop database target=${DB} (WITH FORCE)" pg -d postgres -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" ;;
  cockroachdb) act "drop database target=${DB} CASCADE" crdb -e "DROP DATABASE IF EXISTS ${DB} CASCADE" ;;
  mysql) act "drop database target=${DB}" my mini-baas-mysql mysql MY_ROOT -e "DROP DATABASE IF EXISTS ${DB}" ;;
  mariadb) act "drop database target=${DB}" my mini-baas-mariadb mariadb MY_ROOT -e "DROP DATABASE IF EXISTS ${DB}" ;;
  mongodb) act "drop database target=${DB}" mongo_run mongo-drop "${DB}" ;;
  mssql) act "drop database target=${DB}" ms -Q "IF DB_ID('${DB}') IS NOT NULL BEGIN ALTER DATABASE ${DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ${DB}; END" ;;
  dynamodb) act "delete tables target=${TABLES_NS//,/ target=}" ddb_drop ;;
  redis | sqlite | http) : ;;
  esac
}
td_unassoc() { [[ -z "${MOUNT_ID}" ]] || unassoc; }
td_rows() { [[ -z "${MOUNT_ID}" ]] || gw_rows_str delete; }
td_sqlite() { [[ -z "${MOUNT_ID}" ]] || sqlite_drop; }
td_deregister() { [[ -z "${MOUNT_ID}" ]] || ma_deregister "${MOUNT_ID}"; }
teardown_gate() {
  case "${CUR}" in
  postgresql) gate "mini-baas-postgres healthy" ma_ready mini-baas-postgres ;;
  cockroachdb) gate "mini-baas-cockroach healthy" ma_ready mini-baas-cockroach ;;
  mysql) gate "mini-baas-mysql healthy, MYSQL_ROOT_PASSWORD set" td_my_ready mini-baas-mysql MYSQL ;;
  mariadb) gate "mini-baas-mariadb healthy, MARIADB_ROOT_PASSWORD set" td_my_ready mini-baas-mariadb MARIADB ;;
  mongodb) gate "mini-baas-mongo healthy, root credentials set" mongo_ready ;;
  mssql) gate "mini-baas-mssql healthy, MSSQL_SA_PASSWORD set" td_ms_ready ;;
  dynamodb) gate "mini-baas-dynamodb-local healthy" ma_ready mini-baas-dynamodb-local ;;
  redis | sqlite | http) gate "control plane reachable (mount lookup only)" true ;;
  esac
}
td_my_ready() { ma_ready "$1" && MY_ROOT="$(_lt_env "$1" "$2_ROOT_PASSWORD")" && need MY_ROOT "$2_ROOT_PASSWORD"; }
td_ms_ready() { MS_PASS="$(_lt_env mini-baas-mssql MSSQL_SA_PASSWORD)" && mssql_ready; }
