#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M7] FAIL: $*"; exit 1; }
step()  { cyan "[M7] ${*}"; }
pass()  { green "[M7] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do [[ "${arg}" == "--live" ]] && LIVE=1; done

step "checking M7 stub engines have been removed (catalog truth)"
# The 6 stubs (jdbc/cassandra/neo4j/elasticsearch/qdrant/influx) were deleted
# during the audit cleanup — they returned NotImplemented on most ops, so
# advertising them in /engines misled SDK consumers. Re-introducing any of
# them requires a real Rust adapter, not a TS stub. M7 now asserts the
# stubs stay gone and the QueryModule/Service no longer reference them.
MODULE="${BAAS_DIR}/src/apps/query-router/src/query/query.module.ts"
SERVICE="${BAAS_DIR}/src/apps/query-router/src/query/query.service.ts"
for engine in jdbc cassandra neo4j elasticsearch qdrant influx; do
  file="${BAAS_DIR}/src/apps/query-router/src/engines/${engine}.engine.ts"
  [[ -f "${file}" ]] && fail "${file} should be deleted post-audit (was a stub)"
done
for class in JdbcEngine CassandraEngine Neo4jEngine ElasticsearchEngine QdrantEngine InfluxEngine; do
  if grep -qE "\\b${class}\\b" "${MODULE}" "${SERVICE}"; then
    fail "${class} still referenced post-deletion"
  fi
done
pass "M7 stub engines deleted from source + wiring"

step "checking tenant_databases engine constraint migration kept"
MIG="${BAAS_DIR}/scripts/migrations/postgresql/021_extend_engine_check.sql"
[[ -f "${MIG}" ]] || fail "missing ${MIG}"
# Migration stays so existing tenant_databases rows from earlier deployments
# remain readable. A user attempting to REGISTER a jdbc/cassandra/etc mount
# now fails late (engine not executable) — that's the correct UX vs silently
# accepting then breaking on first query.
for engine in jdbc cassandra neo4j elasticsearch qdrant influx; do
  grep -q "'${engine}'" "${MIG}" || fail "021 migration missing ${engine}"
done
pass "tenant_databases constraint preserved for historical rows"

if [[ ${LIVE} -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq required for --live mode"

  step "live: /engines advertises the 5 real adapters (no stubs)"
  body=$(docker compose -f "${COMPOSE_FILE}" exec -T query-router \
    node -e "fetch('http://127.0.0.1:4001/engines').then(async (r) => { if (!r.ok) process.exit(1); console.log(await r.text()); }).catch(() => process.exit(1));") \
    || fail "GET /engines inside query-router failed"
  for engine in postgresql mongodb mysql redis http; do
    echo "${body}" | jq -e --arg engine "${engine}" '.engines | index($engine)' >/dev/null \
      || fail "real engine ${engine} not advertised"
  done
  # The deleted stubs MUST NOT appear (catalog matches reality).
  for stub in jdbc cassandra neo4j elasticsearch qdrant influx; do
    if echo "${body}" | jq -e --arg engine "${stub}" '.engines | index($engine)' >/dev/null; then
      fail "stub engine ${stub} should not be advertised post-deletion"
    fi
  done
  pass "/engines lists 5 Rust-backed adapters and no stubs"

  # G6: /capabilities (proxied live from the Rust data plane) must list the same
  # 5 engines as /engines — the SDK introspection surface stays self-consistent.
  step "live: /capabilities lists the same 5 engines as /engines (G6)"
  caps=$(docker compose -f "${COMPOSE_FILE}" exec -T query-router \
    node -e "fetch('http://127.0.0.1:4001/capabilities').then(async (r) => { if (!r.ok) process.exit(1); console.log(await r.text()); }).catch(() => process.exit(1));") \
    || fail "GET /capabilities inside query-router failed"
  for engine in postgresql mongodb mysql redis http; do
    echo "${caps}" | jq -e --arg engine "${engine}" '.engines[] | select(.engine == $engine)' >/dev/null \
      || fail "/capabilities missing engine ${engine}"
  done
  pass "/capabilities lists the same 5 Rust-backed engines as /engines"
fi

green "[M7] OK — all milestone-7 deliverables verified"