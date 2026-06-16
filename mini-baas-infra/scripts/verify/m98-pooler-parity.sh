#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m98-pooler-parity.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M98 — Track-C / C1 CONNECTION-POOLER consume + pooled-vs-direct parity live gate.
# Proves the Rust PG adapter, when `DATA_PLANE_POOLER_URL` is set, dials a
# transaction-mode pooler (pgbouncer) instead of the direct DSN — returning
# row-for-row IDENTICAL results to a DIRECT-DSN router on the same data, while the
# per-request RLS GUCs (cross-owner isolation) SURVIVE the pooled checkout. UNSET
# → the EXACT current direct path (byte-parity).
#
#   data-plane-router (Rust, DATA_PLANE_POOLER_URL=postgres://…@pgbouncer:6432/…
#                            + DATA_PLANE_STATEMENT_CACHE=off)
#     │  open_pool: repoint the resolved DSN's host:port → the pooler endpoint
#     │             (db/user/password/sslmode preserved); RecyclingMethod::Clean
#     │             so no session state survives a txn-mode pooled checkout.
#     ▼  every /v1/query: BEGIN → apply_rls_context (app.current_user_id GUC) → op
#   pgbouncer (POOL_MODE=transaction)  ──►  postgres  (RLS policy keyed on the GUC)
#
#   (POSITIVE)  the SAME CRUD set (insert / get / list / aggregate) through the
#               POOLED router returns bodies byte-identical to the DIRECT router on
#               the SAME data → `diff` of the normalized responses is EMPTY.
#   (REJECT · LOAD-BEARING) through the POOLED router, owner A's `list` returns ONLY
#               A's rows — owner B's rows are NOT visible. If the RLS GUC did NOT
#               survive the txn-mode pooler, A would see B's rows (or all rows); the
#               gate asserts the cross-owner read is correctly scoped. A vacuous
#               happy-path-only gate is rejected — this proves isolation, not "200".
#   (PARITY)    `DATA_PLANE_POOLER_URL` UNSET → the DIRECT router. Its responses are
#               the baseline the POSITIVE arm is diffed against → flag-OFF is the
#               proven byte-identical path.
#
# RLS is REAL here (not owner_id-predicate injection): the probe table ENABLEs row
# level security with a policy `USING (owner_id = current_setting('app.current_user_id'))`
# and the data plane connects as a NON-superuser role `app_user` (superusers bypass
# RLS), so the policy actually bites — which is exactly what must hold through the pooler.
#
# ISOLATED by design (mirrors m80): scratch postgres + pgbouncer + a data-plane-router
# built FROM CURRENT source, ALL on a PRIVATE network, every name suffixed with $$,
# an EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits the live docker-compose.yml. The data path uses the
# router's internal trusted-envelope /v1/query (no Kong / auth), so the EXACT
# production adapter code runs.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M98] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M98] FAIL — $*"; exit 1; }

PG_IMAGE="${M98_PG_IMAGE:-postgres:16-alpine}"
PGB_IMAGE="${M98_PGB_IMAGE:-edoburu/pgbouncer:latest}"
DPR_IMG="m98-dpr-$$:scratch"
NET="m98net-$$"
PG="m98-pg-$$"
PGB="m98-pgbouncer-$$"
DPR_DIRECT="m98-dpr-direct-$$"   # (PARITY) no pooler URL → direct DSN baseline
DPR_POOLED="m98-dpr-pooled-$$"   # (POSITIVE/REJECT) pooler URL set → dials pgbouncer
PORT_DIRECT="${M98_PORT_DIRECT:-18982}"
PORT_POOLED="${M98_PORT_POOLED:-18983}"
PGPW="postgres"
APP_USER="app_user"              # NON-superuser → RLS actually bites
APP_PW="app_pw"
TENANT="m98-tenant-$$"
OWNER_A="m98-owner-a-$$"
OWNER_B="m98-owner-b-$$"
PROBE_TABLE="m98_probe"
# In-network DSNs. Direct → postgres:5432 as app_user; pooled → pgbouncer:6432.
DB_DIRECT="postgres://${APP_USER}:${APP_PW}@${PG}:5432/postgres"
POOLER_URL="postgres://${APP_USER}:${APP_PW}@${PGB}:6432/postgres"
BODY_TMP="$(mktemp)"
DIRECT_OUT="$(mktemp)"
POOLED_OUT="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_DIRECT}" "${DPR_POOLED}" "${PGB}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${DIRECT_OUT}" "${POOLED_OUT}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Build a /v1/query envelope as a given owner. The identity's user_id IS the RLS
# principal (apply_rls_context sets app.current_user_id from it), and owner_id on
# inserted rows is stamped from it — so the policy `owner_id = app.current_user_id`
# scopes reads to exactly that owner.
#   $1 = dsn  $2 = owner_id (== user_id)  $3 = op  $4 = data-json-or-null  $5 = filter-json-or-null
payload() {
  local dsn="$1" owner="$2" op="$3" data="$4" filter="$5"
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m98","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"%s","data":%s,"filter":%s}}' \
    "${TENANT}" "${owner}" "${TENANT}" "${dsn}" "${op}" "${PROBE_TABLE}" "${data}" "${filter}"
}

# POST a /v1/query; echo HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

# Normalize a JSON body for cross-router parity diff: COMPACT single-line, sorted
# keys, so (a) key order / whitespace noise never masks a real divergence, and
# (b) each captured response is EXACTLY one line — so per-label assertions grep an
# unambiguous record. Falls back to the raw body if python3 is unavailable.
norm() { # reads BODY_TMP
  python3 -c 'import json,sys
try:
    print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",",":")))
except Exception:
    print(open(sys.argv[1]).read().replace(chr(10)," "))' "${BODY_TMP}" 2>/dev/null || tr -d "\n" < "${BODY_TMP}"
}

# Count how many times an owner id appears in a compact JSON line (the "owner_id"
# field repeats once per returned row). $1=line  $2=owner_id. ALWAYS exits 0 (a
# zero count is `grep` exit 1, which under `set -o pipefail` would abort the
# script — so the count is taken with grep's status swallowed).
count_owner() {
  local n
  n="$(printf '%s' "$1" | grep -o "\"owner_id\":\"$2\"" | wc -l | tr -d '[:space:]')" || true
  printf '%s' "${n:-0}"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/capabilities" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 required for the parity diff (line: python3 check)"

# ── 0) build the scratch DPR FROM CURRENT (C1) source ─────────────────────────
step "0/8 build scratch data-plane-router from CURRENT source (the C1 pooler-consume code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed — gate must exercise the C1 seam (line: docker build DPR)"
ok "scratch image built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + postgres (trust so the pooler's trust auth works) ────
step "1/8 boot isolated net (${NET}): postgres (HOST_AUTH=trust)"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" \
  -e POSTGRES_PASSWORD="${PGPW}" -e POSTGRES_HOST_AUTH_METHOD=trust "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "postgres up (trust auth)"

# ── 2) seed: NON-superuser app_user + RLS probe table + rows for TWO owners ────
step "2/8 seed app_user (non-superuser) + RLS probe table + rows for ${OWNER_A} and ${OWNER_B}"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
-- A NON-superuser role: superusers bypass RLS, so the policy only bites for this role.
DO \$r\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN PASSWORD '${APP_PW}' NOSUPERUSER NOBYPASSRLS;
  END IF;
END \$r\$;
GRANT ALL ON SCHEMA public TO ${APP_USER};
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (
  id text PRIMARY KEY, label text, owner_id text NOT NULL);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.${PROBE_TABLE} TO ${APP_USER};
ALTER TABLE public.${PROBE_TABLE} ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.${PROBE_TABLE} FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS m98_owner_scope ON public.${PROBE_TABLE};
-- The data plane sets app.current_user_id per request (apply_rls_context); the
-- policy scopes every row to the calling principal. This is what must SURVIVE
-- the transaction-mode pooled checkout.
CREATE POLICY m98_owner_scope ON public.${PROBE_TABLE}
  USING (owner_id = current_setting('app.current_user_id', true))
  WITH CHECK (owner_id = current_setting('app.current_user_id', true));
-- Deterministic ground truth: 2 rows for A, 1 row for B (seeded as superuser,
-- which bypasses RLS for the seed itself).
INSERT INTO public.${PROBE_TABLE}(id,label,owner_id) VALUES
  ('a1','alpha','${OWNER_A}'),('a2','bravo','${OWNER_A}'),('b1','charlie','${OWNER_B}')
  ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT count(*) FROM public.${PROBE_TABLE} WHERE owner_id='${OWNER_A}'")" == "2" ]] \
  || fail "owner A should have 2 seeded rows (line: verify A seed)"
[[ "$(psql_val "SELECT count(*) FROM public.${PROBE_TABLE} WHERE owner_id='${OWNER_B}'")" == "1" ]] \
  || fail "owner B should have 1 seeded row (line: verify B seed)"
ok "seeded: A=2 rows, B=1 row; RLS FORCEd; app_user is non-superuser (NOBYPASSRLS)"

# ── 3) boot pgbouncer in TRANSACTION mode in front of postgres ────────────────
step "3/8 boot pgbouncer (POOL_MODE=transaction, AUTH_TYPE=trust) → postgres"
docker run -d --name "${PGB}" --network "${NET}" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER=postgres -e DB_NAME=postgres \
  -e AUTH_TYPE=trust -e POOL_MODE=transaction -e LISTEN_PORT=6432 \
  -e MAX_CLIENT_CONN=200 -e DEFAULT_POOL_SIZE=5 \
  -e IGNORE_STARTUP_PARAMETERS="extra_float_digits,search_path,options" \
  "${PGB_IMAGE}" >/dev/null
# Wait until pgbouncer accepts a connection (proxy a trivial query through it).
PGB_OK=
for i in $(seq 1 60); do
  if docker run --rm --network "${NET}" -e PGPASSWORD="${APP_PW}" "${PG_IMAGE}" \
       psql "host=${PGB} port=6432 user=${APP_USER} dbname=postgres sslmode=disable" \
       -tAc 'SELECT 1' 2>/dev/null | grep -q '^1$'; then PGB_OK=1; break; fi
  docker inspect "${PGB}" >/dev/null 2>&1 || { red "pgbouncer exited:"; docker logs "${PGB}" 2>&1 | tail -15; break; }
  sleep 0.5
done
[[ -n "${PGB_OK}" ]] || { red "pgbouncer logs:"; docker logs "${PGB}" 2>&1 | tail -20; fail "pgbouncer never accepted a pooled connection (line: PGB ready)"; }
ok "pgbouncer up in transaction mode; a query proxies through it to postgres"

# ── 4) (PARITY) DIRECT router — pooler URL UNSET → direct DSN baseline ─────────
step "4/8 boot DIRECT router (DATA_PLANE_POOLER_URL UNSET) → byte-parity baseline"
docker run -d --name "${DPR_DIRECT}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DIRECT}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_DIRECT}" "${PORT_DIRECT}" || fail "DIRECT router not ready (line: wait_ready DIRECT)"
ok "DIRECT router up (no pooler) on 127.0.0.1:${PORT_DIRECT}"

# The CRUD set: each line is "label|owner|op|data|filter". get/list/aggregate read
# back the seeded rows; we DO NOT mutate (so direct and pooled see the same data and
# the byte diff is meaningful). owner A only — its rows are the parity payload.
run_set() { # $1=port  $2=dsn  → appends normalized "label::status::body" lines to stdout
  local port="$1" dsn="$2" code
  # list A's rows
  code="$(post_q "${port}" "$(payload "${dsn}" "${OWNER_A}" list null null)")"
  printf 'list_A::%s::%s\n' "${code}" "$(norm)"
  # get a specific A row by id
  code="$(post_q "${port}" "$(payload "${dsn}" "${OWNER_A}" get null '{"id":"a1"}')")"
  printf 'get_a1::%s::%s\n' "${code}" "$(norm)"
  # aggregate count of A's rows (count → no field; aggregate spec is nested)
  code="$(post_q "${port}" '{"identity":{"tenant_id":"'"${TENANT}"'","user_id":"'"${OWNER_A}"'","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m98","tenant_id":"'"${TENANT}"'","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"'"${dsn}"'","isolation":"shared_rls"},"operation":{"op":"aggregate","resource":"'"${PROBE_TABLE}"'","aggregate":{"aggregates":[{"func":"count","alias":"n"}]}}}')"
  printf 'agg_A::%s::%s\n' "${code}" "$(norm)"
}

step "4b/8 capture DIRECT responses (list/get/aggregate as owner A)"
run_set "${PORT_DIRECT}" "${DB_DIRECT}" > "${DIRECT_OUT}"
D_LIST="$(grep '^list_A::' "${DIRECT_OUT}" || true)"
[[ "${D_LIST}" == list_A::200::* ]] || { red "direct out:"; cat "${DIRECT_OUT}"; fail "DIRECT list_A not 200 (line: direct list 200)"; }
# Direct list must return EXACTLY A's 2 rows and ZERO of B's (RLS already bites
# direct — it's the baseline the pooled arm must reproduce).
D_A="$(count_owner "${D_LIST}" "${OWNER_A}")"; D_B="$(count_owner "${D_LIST}" "${OWNER_B}")"
[[ "${D_A}" == "2" ]] || { red "direct list:"; printf '%s\n' "${D_LIST}"; fail "DIRECT list_A expected A's 2 rows, saw ${D_A} (line: direct A rows)"; }
[[ "${D_B}" == "0" ]] || { red "direct list:"; printf '%s\n' "${D_LIST}"; fail "DIRECT list_A leaked ${D_B} of owner B's rows — RLS not biting even direct (line: direct B leak)"; }
ok "DIRECT captured: list_A=200 with exactly A's 2 rows, 0 of B's (RLS scopes correctly direct)"

# ── 5) swap to the POOLED router. STOP the direct one first (clean handoff) ────
step "5/8 stop DIRECT router; boot POOLED router (DATA_PLANE_POOLER_URL=${PGB}:6432 + STATEMENT_CACHE=off)"
docker rm -fv "${DPR_DIRECT}" >/dev/null 2>&1 || true
docker run -d --name "${DPR_POOLED}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_POOLER_URL="${POOLER_URL}" \
  -e DATA_PLANE_STATEMENT_CACHE=off \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_POOLED}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_POOLED}" "${PORT_POOLED}" || fail "POOLED router not ready (line: wait_ready POOLED)"
ok "POOLED router up (dials pgbouncer) on 127.0.0.1:${PORT_POOLED}"

step "5b/8 capture POOLED responses (SAME CRUD set, SAME owner, SAME data)"
# IMPORTANT: the mount payload still carries the DIRECT inline DSN — the C1 seam in
# open_pool repoints its host:port to the pooler from DATA_PLANE_POOLER_URL. So the
# request bodies are IDENTICAL to the direct arm; only the router env differs. That
# is precisely the parity contract: same request, pooled vs direct, identical body.
run_set "${PORT_POOLED}" "${DB_DIRECT}" > "${POOLED_OUT}"
grep -q 'list_A::200::' "${POOLED_OUT}" || { red "pooled out:"; cat "${POOLED_OUT}"; fail "POOLED list_A not 200 — the pooler path failed (line: pooled list 200)"; }
ok "POOLED captured: list_A=200 (CRUD served THROUGH pgbouncer)"

# ── 6) (POSITIVE) row-for-row parity: diff DIRECT vs POOLED responses ─────────
step "6/8 (POSITIVE) diff DIRECT vs POOLED normalized responses → MUST be empty"
if ! diff -u "${DIRECT_OUT}" "${POOLED_OUT}" > "${BODY_TMP}" 2>&1; then
  red "pooled-vs-direct DIVERGENCE:"; cat "${BODY_TMP}"
  fail "POOLED responses are NOT byte-identical to DIRECT — C1 is not a transport-only optimization (line: parity diff)"
fi
ok "(POSITIVE) pooled responses are ROW-FOR-ROW identical to direct — C1 is transport-only"

# ── 7) (REJECT · LOAD-BEARING) cross-owner isolation survives the pooler ──────
step "7/8 (REJECT) through the POOLED router, owner B's list must NOT see owner A's rows"
# As owner B: the RLS GUC is re-stamped per request inside the txn; even though the
# previous pooled checkout served owner A, B must see ONLY its own 1 row. If the GUC
# did not survive / leaked across the txn-mode pool, B would see A's rows too.
B_CODE="$(post_q "${PORT_POOLED}" "$(payload "${DB_DIRECT}" "${OWNER_B}" list null null)")"
[[ "${B_CODE}" == "200" ]] || { red "B body:"; head -c 300 "${BODY_TMP}"; fail "(REJECT) owner B list expected 200, got ${B_CODE} (line: B list 200)"; }
B_NORM="$(norm)"
B_OWN_ROWS="$(count_owner "${B_NORM}" "${OWNER_B}")"
B_SEES_A="$(count_owner "${B_NORM}" "${OWNER_A}")"
[[ "${B_OWN_ROWS}" == "1" ]] || { red "B sees:"; printf '%s\n' "${B_NORM}"; fail "(REJECT) owner B expected its 1 row, saw ${B_OWN_ROWS} (line: B own rows)"; }
[[ "${B_SEES_A}" == "0" ]] || { red "B sees:"; printf '%s\n' "${B_NORM}"; fail "(REJECT) CROSS-OWNER LEAK through the pooler: owner B saw ${B_SEES_A} of owner A's rows — the RLS GUC did NOT survive the txn-mode pooled checkout (line: B leak A)"; }
ok "(REJECT · LOAD-BEARING) owner B sees ONLY its 1 row through the pooler — RLS GUC survives txn-mode pooling"

# Re-assert as owner A right after B (back-to-back, different principals, same pool)
# to prove the GUC is per-request, not pinned by the first checkout.
A2_CODE="$(post_q "${PORT_POOLED}" "$(payload "${DB_DIRECT}" "${OWNER_A}" list null null)")"
A2_NORM="$(norm)"
A2_A="$(count_owner "${A2_NORM}" "${OWNER_A}")"
A2_B="$(count_owner "${A2_NORM}" "${OWNER_B}")"
[[ "${A2_CODE}" == "200" && "${A2_A}" == "2" && "${A2_B}" == "0" ]] \
  || { red "A-after-B:"; printf '%s\n' "${A2_NORM}"; fail "(REJECT) A-after-B expected A's 2 rows only (got code=${A2_CODE} A=${A2_A} B=${A2_B}) — GUC pinned across pooled checkouts (line: A after B)"; }
ok "back-to-back A→B→A through one pool: each sees ONLY its own rows (GUC is per-request)"

# ── 8) emit the gate event via the kernel log helper (best-effort) ────────────
step "8/8 cross-check + log GATE m98=PASS"
green "[M98] (POSITIVE) pooled == direct, row-for-row (diff empty)"
green "[M98] (REJECT)   cross-owner RLS GUC survives the txn-mode pooler (B sees only B; A-after-B sees only A)"
green "[M98] (PARITY)   DATA_PLANE_POOLER_URL unset → direct path = the baseline both arms agree on"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-c1-pooler-consume}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m98=PASS" --outcome pass \
      --msg "C1 pooler consume: DATA_PLANE_POOLER_URL repoints the PG adapter DSN to pgbouncer (txn mode) + STATEMENT_CACHE=off recycles Clean; pooled CRUD is row-for-row identical to direct; cross-owner RLS GUC survives the pooled checkout; unset -> direct byte-parity" \
      --ref "scripts/verify/m98-pooler-parity.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M98] ALL GATES GREEN — the PG adapter CONSUMES a transaction-mode pooler with row-for-row parity, RLS isolation survives the pool, and the unset path is byte-identical"
exit 0
