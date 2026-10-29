#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m249-type-round-trip.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 19:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 19:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate (G7): every engine reports and round-trips each normalized type.
#
# Static (no stack): the binary codec, the PG string binds and each engine's
# normalizer golden table carry the G7 variants, and the four public type lists
# (Rust enum, TS DDL allowlist, JS SDK union, openapi) agree on the DDL set.
#
# Live (BAAS_VERIFY_LIVE=1, BAAS_KONG_URL, BAAS_API_KEY, M249_MOUNTS=engine=uuid,…):
# m249-type-round-trip.mjs adds one column per type on a scratch table per mount,
# writes a value, reads it back and checks the described type. Redis, http and
# dynamodb have no DDL and are not listed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POOL="${ROOT}/src/data-plane-router/crates/data-plane-pool/src"
CORE="${ROOT}/src/data-plane-router/crates/data-plane-core/src"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
need() {
  grep -Eq "$2" "$1" || fail "$3 (expected /$2/ in ${1#"$ROOT"/})"
}

step "static: one binary text form, tested"
need "${CORE}/binary.rs" 'pub fn hex_bytes' "hex_bytes missing"
need "${CORE}/binary.rs" 'fn non_hex_text_is_not_binary' "parse_hex_bytes refusal test missing"
for f in mysql/convert.rs sqlite/convert.rs mssql/convert.rs postgres/cell.rs; do
  need "${POOL}/${f}" 'hex_bytes' "${f} does not render binary through hex_bytes"
done
need "${POOL}/postgres/convert.rs" 'fn g7_strings_bind_into_int8_numeric_bytea_and_time' "PG string-bind test missing"
pass "binary renders as \\x hex on pg/mysql/sqlite/mssql; PG binds strings into int8/numeric/bytea/time"

step "static: each normalizer emits the G7 variants"
need "${POOL}/postgres/ddl.rs" '"int8" => NormalizedType::Bigint' "pg int8 is not Bigint"
need "${POOL}/mysql/schema.rs" '"bigint" => NormalizedType::Bigint' "mysql bigint is not Bigint"
need "${POOL}/sqlite/exec.rs" 'fn normalize_sqlite_type_reads_declared_affinity' "sqlite normalizer test missing"
need "${POOL}/mssql/convert.rs" 'NormalizedType::Bigint' "mssql has no Bigint arm"
need "${POOL}/mongo/convert.rs" '"binData" => NormalizedType::Binary' "mongo binData is not Binary"
pass "pg · mysql · sqlite · mssql · mongo"

step "static: the DDL type list agrees across Rust, TS, SDK and openapi"
ddl_set='array bigint binary boolean date datetime decimal enum float integer interval json text time uuid'
ts=$(sed -n '/SCHEMA_DDL_COLUMN_TYPES = \[/,/\] as const/p' "${ROOT}/src/apps/query-router/src/query/dto/schema-ddl.dto.ts" |
  grep -Eo "'[a-z]+'" | tr -d "'" | sort | xargs)
[ "${ts}" = "${ddl_set}" ] || fail "TS SCHEMA_DDL_COLUMN_TYPES = ${ts}"
api=$(python3 -c 'import json,sys
spec = json.load(open(sys.argv[1]))
def walk(n):
    if isinstance(n, dict):
        if n.get("description") == "Target normalized type": yield n["enum"]
        for v in n.values(): yield from walk(v)
    elif isinstance(n, list):
        for v in n: yield from walk(v)
print(" ".join(sorted(next(walk(spec)))))' "${ROOT}/infra/config/openapi/query-router.json")
[ "${api}" = "${ddl_set}" ] || fail "openapi DDL enum = ${api}"
need "${ROOT}/sdks/js/src/types.ts" "'objectid' \\| 'geometry' \\| 'vector' \\| 'unknown'" "SDK DdlColumnType must exclude the describe-only types"
pass "${ddl_set}"

node --check "${ROOT}/scripts/verify/m249-type-round-trip.mjs"
pass "live probe parses"

if [ "${BAAS_VERIFY_LIVE:-0}" != "1" ]; then
  printf '\n\033[33m! live round trip skipped (set BAAS_VERIFY_LIVE=1 and M249_MOUNTS)\033[0m\n'
  printf '\033[32mm249 static checks passed\033[0m\n'
  exit 0
fi

step "live: one value per type per mount"
node "${ROOT}/scripts/verify/m249-type-round-trip.mjs" || fail "a type did not round-trip (see the FAIL lines)"
printf '\033[32mm249 passed (static + live)\033[0m\n'
