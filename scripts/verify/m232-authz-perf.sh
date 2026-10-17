#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m232-authz-perf.sh — the frontier query uses the index (N3) and the Go      #
#  evaluator is fast enough over real postgres (N4).                           #
#                                                                              #
#  N3  EXPLAIN (ANALYZE, FORMAT JSON) of the SAME frontier.sql production runs,#
#      for 500 objects and for 1, as a custom plan and as the generic plan     #
#      pgx reuses after five calls. It must be an Index (Only) Scan on         #
#      authz.tuples with loops = frontier size, and no Seq Scan, Bitmap scan,  #
#      Gather or Parallel node. A row-constructor `= ANY` fails this (2816 ms  #
#      over 235k tuples, devil r2 R7).                                         #
#  N4  authz/bench_integration_test.go drives Store.Check on 245k seeded       #
#      tuples (a 100k-page tree, depth 10) at 1 and 16 clients: a stranger's   #
#      read of one depth-10 page, and a 500-page batch. It also runs a         #
#      one-statement recursive-CTE prefetch for comparison. p50/p95 and the    #
#      connection hold time land in artifacts/bench/m232-authz-perf.json.      #
#                                                                              #
#  KILL CRITERION (end to end: client call to decision, includes the gate,     #
#  the transaction, the model read, every frontier round trip and evaluation): #
#    1 client   single depth-10 check p95 <= 5 ms   (N4: ~0.5-5 ms)           #
#    1 client   500-page batch         p95 <= 25 ms  (spike budget; the        #
#                                       PL/pgSQL evaluator missed it at 45-53) #
#    16 clients zero 503 from the 4-slot gate, single p95 <= 25 ms, batch      #
#                                       p95 <= 125 ms (5x the 1-client bound;  #
#                                       chosen here, N4 gives no 16-client     #
#                                       number)                                #
#  Missing any line kills the Go evaluator design; the fallback is the        #
#  one-statement closure prefetch, whose numbers are in the same artifact.     #
#                                                                              #
#  --self-test swaps in a frontier query that cannot use the index and        #
#  requires the plan assertion to fail.                                        #
#                                                                              #
#  Caveat: one local postgres, warm cache, closed-loop clients, loopback       #
#  socket. A remote database adds one network round trip per frontier level    #
#  (about 11 at depth 10) to the "levels" strategy and one in total to the     #
#  closure strategy, so re-run against the real topology before trusting the   #
#  1-client numbers there. --network host: free ports M232_PG_PORT required.   #
#                                                                              #
# **************************************************************************** #
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane"
AUTHZ_DIR="${CP}/internal/authz"
SCHEMA_SQL="${AUTHZ_SCHEMA_SQL:-${ROOT}/scripts/migrations/postgresql/091_authz_tuples.sql}"
FRONTIER_SQL="${M232_FRONTIER_SQL:-${AUTHZ_DIR}/frontier.sql}"
PG_IMAGE="${M232_PG_IMAGE:-postgres:16-alpine}"
GO_IMG="${GO_IMG:-$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'golang:1\.26' || echo golang:1.26-bookworm)}"
PG_PORT="${M232_PG_PORT:-55432}"
ART="${ROOT}/artifacts/bench/m232-authz-perf.json"
PG="authz-b-m232-pg-$$"
PGPW="pw-$$"
WORK="$(mktemp -d)"

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M232] FAIL: %s\033[0m\n' "$*" >&2
  exit 1
}
trap 'docker rm -fv "${PG}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

psql_in() { docker exec -i -e PGPORT="${PG_PORT}" "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

# A frontier query that defeats the index on purpose.
if [ "${1:-}" = "--self-test" ]; then
  cat >"${WORK}/bad-frontier.sql" <<'SQL'
SELECT DISTINCT t.object_type, t.object_id, t.relation, t.subject_type, t.subject_id, t.subject_relation
  FROM authz.tuples t
 WHERE t.app = $1
   AND (t.object_type || ':' || t.object_id || ':' || t.relation) = ANY (
         SELECT a || ':' || b || ':' || c FROM unnest($2::text[], $3::text[], $4::text[]) AS f(a, b, c))
 LIMIT $5
SQL
  out="$(M232_SKIP_BENCH=1 M232_FRONTIER_SQL="${WORK}/bad-frontier.sql" bash "$0" 2>&1 </dev/null)" &&
    fail "self-test: the plan assertion PASSED a frontier query that scans the table"
  grep -q 'N3 plan' <<<"${out}" || fail "self-test: failed, but not on the plan assertion: $(tail -3 <<<"${out}")"
  ok "self-test: a non-indexable frontier query fails the N3 plan assertion"
  printf '\033[1;32mm232 self-test PASS\033[0m\n'
  exit 0
fi

start_seeded_postgres() {
  docker run -d --name "${PG}" --network host -e POSTGRES_PASSWORD="${PGPW}" -e PGPORT="${PG_PORT}" \
    "${PG_IMAGE}" -c fsync=off >/dev/null
  local i
  for i in $(seq 1 60); do
    docker exec "${PG}" pg_isready -p "${PG_PORT}" -q 2>/dev/null && break
    sleep 0.5
  done
  [ "${i}" -lt 60 ] || fail "postgres never became ready"
  # 091 expects the platform's roles and ledger; a bare postgres has neither.
  psql_in >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $r$;
SQL
  psql_in <"${SCHEMA_SQL}" >/dev/null
  psql_in <"${AUTHZ_DIR}/testdata/perf_seed.sql" >/dev/null
  ok "postgres up; $(psql_in -tA -c 'SELECT count(*) FROM authz.tuples') tuples seeded (${SCHEMA_SQL##*/})"
}

# explain_json <frontier size> <plan_cache_mode> prints the EXPLAIN JSON for pages 60000.. as wants.
explain_json() {
  local n="$1" mode="$2" types ids rels
  IFS='|' read -r types ids rels < <(psql_in -tA -c "SELECT
    'ARRAY[' || string_agg(quote_literal('page'), ',') || ']::text[]',
    'ARRAY[' || string_agg(quote_literal(g::text), ',') || ']::text[]',
    'ARRAY[' || string_agg(quote_literal('parent'), ',') || ']::text[]'
    FROM generate_series(60000, 60000 + ${n} - 1) g")
  {
    echo "SET plan_cache_mode = ${mode};"
    printf 'PREPARE frontier(text, text[], text[], text[], int) AS\n%s;\n' "$(cat "${FRONTIER_SQL}")"
    echo "EXPLAIN (ANALYZE, FORMAT JSON) EXECUTE frontier('osionos', ${types}, ${ids}, ${rels}, 100000);"
  } | psql_in -tA | grep -v '^SET$\|^PREPARE$'
}

# assert_plan <label> <frontier size> <json>
assert_plan() {
  local label="$1" n="$2" json="$3"
  jq -e '.[0].Plan' <<<"${json}" >/dev/null || fail "N3 plan (${label}): EXPLAIN produced no plan"
  jq -e --argjson n "${n}" '
    [.[0].Plan | .. | objects | select(has("Node Type"))] as $nodes
    | ($nodes | map(select(.["Node Type"] | test("Seq Scan|Bitmap|Gather"))) | length) == 0
    and ($nodes | map(select(."Parallel Aware" == true)) | length) == 0
    and ($nodes | map(select(.["Node Type"] | test("^Index (Only )?Scan$")) | select(."Relation Name" == "tuples")
          | select(."Actual Loops" == $n)) | length) >= 1' <<<"${json}" >/dev/null ||
    {
      jq -c '[.[0].Plan | .. | objects | select(has("Node Type")) | {n: .["Node Type"], r: ."Relation Name", loops: ."Actual Loops", par: ."Parallel Aware"}]' <<<"${json}" >&2
      fail "N3 plan (${label}, frontier ${n}): want Index (Only) Scan on tuples, loops=${n}, no seq/bitmap/parallel"
    }
  ok "N3 plan (${label}, frontier ${n}): index scan, loops=${n}, no seq/bitmap/parallel; $(jq -r '.[0]["Execution Time"]' <<<"${json}") ms"
}

check_plans() {
  local n mode
  for n in 500 1; do
    for mode in force_custom_plan force_generic_plan; do
      assert_plan "${mode#force_}" "${n}" "$(explain_json "${n}" "${mode}")"
    done
  done
}

run_bench() {
  mkdir -p "$(dirname "${ART}")"
  docker run --rm --network host -e CGO_ENABLED=0 -e GOFLAGS=-mod=mod \
    -e AUTHZ_BENCH_DSN="postgres://postgres:${PGPW}@127.0.0.1:${PG_PORT}/postgres" -e AUTHZ_BENCH_OUT=/out/bench.json \
    -v "${CP}:/src" -v "${WORK}:/out" -v /goinfre/dlesieur/.cache/go/mod:/go/pkg/mod \
    -v /goinfre/dlesieur/.cache/go/build:/root/.cache/go-build -w /src "${GO_IMG}" \
    go test -tags authz_bench -run TestBenchmarkAuthz -count=1 ./internal/authz/ >"${WORK}/bench.log" 2>&1 ||
    { tail -20 "${WORK}/bench.log"; fail "N4 bench did not run"; }
  [ -s "${WORK}/bench.json" ] || fail "N4 bench wrote no result"
}

# cell <strategy> <scenario> <clients> <field>
cell() { jq -r --arg s "$1" --arg c "$2" --argjson n "$3" '.results[] | select(.strategy==$s and .scenario==$c and .clients==$n) | .'"$4" "${WORK}/bench.json"; }

# within <label> <value> <limit>: a numeric <= check that prints both numbers.
within() {
  awk -v v="$2" -v l="$3" 'BEGIN { exit !(v <= l) }' || fail "N4 kill criterion: ${1} = ${2} ms > ${3} ms"
  ok "N4 ${1} = ${2} ms <= ${3} ms"
}

judge_bench() {
  within "levels single depth-10, 1 client, p95" "$(cell levels single_depth10 1 p95_ms)" 5
  within "levels batch-500, 1 client, p95" "$(cell levels batch500 1 p95_ms)" 25
  within "levels single depth-10, 16 clients, p95" "$(cell levels single_depth10 16 p95_ms)" 25
  within "levels batch-500, 16 clients, p95" "$(cell levels batch500 16 p95_ms)" 125
  [ "$(jq '[.results[] | select(.strategy=="levels") | .unavailable] | add' "${WORK}/bench.json")" = 0 ] ||
    fail "N4 kill criterion: the 4-slot gate answered 503 at 16 clients"
  ok "N4 no 503 from the gate at 16 clients"
}

# The shipped prefetch is the level frontier; the closure CTE must not beat it by more than the 3% noise floor on any p95.
prefetch_decision() {
  jq '[.results[] | {k: (.scenario + "/" + (.clients|tostring)), s: .strategy, p95: .p95_ms}]
      | group_by(.k) | map({case: .[0].k, levels_p95: (map(select(.s=="levels"))[0].p95), closure_p95: (map(select(.s=="closure"))[0].p95)})
      | map(. + {closure_wins: (.closure_p95 < .levels_p95 * 0.97)})' "${WORK}/bench.json" >"${WORK}/decision.json"
  if jq -e 'any(.[]; .closure_wins)' "${WORK}/decision.json" >/dev/null; then
    printf '  • closure beats levels by >3%% somewhere (see artifact): %s\n' "$(jq -c '[.[]|select(.closure_wins)|.case]' "${WORK}/decision.json")"
  else
    ok "prefetch: levels is within 3% of, or faster than, the one-statement closure everywhere"
  fi
}

write_artifact() {
  jq --slurpfile d "${WORK}/decision.json" --arg pg "$(psql_in -tA -c 'SHOW server_version')" \
    --arg tuples "$(psql_in -tA -c 'SELECT count(*) FROM authz.tuples')" --arg when "$(date -u +%FT%TZ)" \
    '. + {measured_at: $when, postgres: $pg, tuples: ($tuples|tonumber), prefetch_comparison: $d[0],
          kill_criterion_ms: {single_p95_1c: 5, batch500_p95_1c: 25, single_p95_16c: 25, batch500_p95_16c: 125}}' \
    "${WORK}/bench.json" >"${ART}"
  ok "artifact ${ART#"${ROOT}"/}"
}

summarize() {
  jq -r '.results[] | [.strategy, .scenario, (.clients|tostring)+"c", "p50 "+(.p50_ms|tostring), "p95 "+(.p95_ms|tostring),
    "hold p50 "+(.hold_p50_ms|tostring), "hold p95 "+(.hold_p95_ms|tostring), "503s "+(.unavailable|tostring)] | join("  ")' "${WORK}/bench.json"
}

printf '\033[1m── m232: authz frontier plan + evaluator latency ──\033[0m\n'
start_seeded_postgres
check_plans
if [ -n "${M232_SKIP_BENCH:-}" ]; then
  printf '\033[1;32mm232 PASS (plan only)\033[0m\n'
  exit 0
fi
run_bench
prefetch_decision
write_artifact
summarize
judge_bench
printf '\033[1;32mm232 PASS\033[0m — N3 index plan, N4 within the kill criterion\n'
