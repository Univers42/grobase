#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m101-quota-realtenant.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M101 — Track-B quota enforcement against a REALISTIC tenant identity. This is
# the NON-VACUOUS successor to m80 and the BILLING TRUTH-GATE: m80 seeds a
# minimal tenants table where id == slug == tenant_id, so the UUID-id / slug
# split that exists in production (migration 032) is NEVER exercised — its join
# matches by construction. m101 seeds the REAL shape:
#
#   tenants.id   = a UUID            (the primary key)
#   tenants.slug = 't-<uuidnodashes>' (the public identity; migration 032 backfill)
#   tenant_usage.tenant_id = the SLUG (what the data plane stamps from the signed
#                                      envelope — NOT the UUID)
#
# So the guard's join (quotaguard.usageByTenantSQL) MUST be on tenants.slug =
# tenant_usage.tenant_id to resolve the tenant's real plan. This gate is a
# REGRESSION GUARD on that exact bug:
#
#   OVER tenant: plan=nano (query.count cap 100000), usage = 100001 (1 over).
#     · FIXED join (t.slug): plan resolves to 'nano' → cap 100000 → 100001 > cap
#       → tenant ∈ quota:over → request 402. ✅
#     · BROKEN join (t.id::text = u.tenant_id, the pre-fix code): slug ≠ UUID →
#       NO match → plan '' → manifest default_package = 'essential' (cap
#       2,000,000) → 100001 < 2,000,000 → NOT over → request 200. ❌ gate FAILS.
#
# i.e. a real nano tenant 1 request over their cap is silently billed/served
# under the essential cap when the join is wrong. m101 fails the old code and
# passes the fixed code — that is what makes it non-vacuous.
#
#   (A) ENFORCE arm (both flags ON): OVER(slug) → 402 quota_exceeded (LOAD-BEARING);
#       UNDER(slug) → 200.
#   (B) PARITY arm (DATA_PLANE_QUOTA_ENFORCEMENT unset): OVER + UNDER both 200 —
#       flag-OFF is byte-identical regardless of the over-quota set.
#
# ISOLATED by design (mirrors m80): scratch postgres (migration-040 prelude +
# the REAL 040) + redis + a data-plane-router and Go orchestrator built FROM
# CURRENT source, on a PRIVATE network, every name suffixed $$, an EXIT-trap
# removing EVERYTHING. It NEVER touches a mini-baas-* container/network/image/
# volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/src/data-plane-router"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIGRATION_040="${INFRA_DIR}/scripts/migrations/postgresql/040_tenant_usage.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M101] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M101] FAIL — $*"; exit 1; }

REDIS_IMAGE="${M101_REDIS_IMAGE:-redis:7-alpine}"
PG_IMAGE="${M101_PG_IMAGE:-postgres:16-alpine}"
DPR_IMG="m101-dpr-$$:scratch"
ORCH_IMG="m101-orch-$$:scratch"
NET="m101net-$$"
PG="m101-pg-$$"
REDIS="m101-redis-$$"
ORCH="m101-orch-on-$$"     # QuotaGuard (enforcement ON)
DPR_ON="m101-dpr-on-$$"    # (A) ENFORCE arm router
DPR_OFF="m101-dpr-off-$$"  # (B) PARITY  arm router
PORT_ON="${M101_PORT_ON:-18982}"
PORT_OFF="${M101_PORT_OFF:-18983}"
PGPW="postgres"
SVC_TOKEN="m101-internal-service-token-$$"

# REAL identity split: a UUID primary key and a DISTINCT slug. The usage rows and
# the request identity use the SLUG; tenants.id is the UUID. id != slug by
# construction (the whole point of the gate).
UUID_OVER="550e8400-e29b-41d4-a716-446655440000"
UUID_UNDER="11111111-2222-3333-4444-555555555555"
SLUG_OVER="t-550e8400e29b41d4a716446655440000"   # = 't-' || replace(uuid,'-','')
SLUG_UNDER="t-11111111222233334444555555555555"
PROBE_TABLE="m101_probe"
METRIC="query.count"
NANO_CAP=100000          # nano query.count cap (packages.json source of truth)
DEFAULT_CAP=2000000      # essential = default_package cap (the broken-join trap)
OVER_QTY=$((NANO_CAP + 1))   # 100001: over nano (real), under essential (default)
UNDER_QTY=50
REFRESH_MS="${M101_REFRESH_MS:-700}"     # LOW so the data plane refreshes fast
GUARD_MS="${M101_GUARD_MS:-700}"         # LOW so the guard re-evaluates fast
REDIS_INNET="redis://${REDIS}:6379"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${ORCH}" "${PG}" "${REDIS}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" "${ORCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
redis_cli() { docker exec -i "${REDIS}" redis-cli "$@"; }

# Build the /v1/query envelope for a `list` against the bare probe table, as a
# given tenant identity. identity.tenant_id is the SLUG (what enforcement keys
# on AND what we seeded usage under) — they match by construction.
#   $1 = tenant slug
payload_list() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m101","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$1" "$1" "$1" "${DB_INNET}" "${PROBE_TABLE}"
}

post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/capabilities" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

wait_log() { # $1=container  $2=needle  $3=tries
  local i
  for i in $(seq 1 "${3:-60}"); do
    docker logs "$1" 2>&1 | grep -q "$2" && return 0
    docker inspect "$1" >/dev/null 2>&1 || return 1
    sleep 0.5
  done
  return 1
}

# ── 0) build the scratch DPR + orchestrator FROM CURRENT (drafted) source ──────
step "0/7 build scratch data-plane-router + Go orchestrator from CURRENT source (the B2 code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed (line: docker build DPR)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=orchestrator --build-arg PORT=3060 \
  -t "${ORCH_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch orchestrator image build failed (line: docker build ORCH)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + redis + postgres (prelude + REAL migration 040) ──────
step "1/7 boot isolated net (${NET}): redis + postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${REDIS}" --network "${NET}" "${REDIS_IMAGE}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 60); do redis_cli PING 2>/dev/null | grep -q PONG && break; [[ $i -eq 60 ]] && fail "scratch redis never PONGed (line: redis ready)"; sleep 0.5; done
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
ok "redis + postgres up"

step "1b/7 apply migration-040 PRELUDE then the REAL 040"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "${MIGRATION_040}" >/dev/null 2>&1 \
  || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")" == "0" ]] || fail "tenant_usage should start EMPTY (line: 040 empty check)"
ok "migration 040 applied — public.tenant_usage exists and is empty"

# ── 2) seed: REALISTIC tenants (uuid id + DISTINCT slug, both nano) + usage ─────
step "2/7 seed REALISTIC tenants (uuid id ≠ slug, both nano) + tenant_usage(OVER=${OVER_QTY}>${NANO_CAP}, UNDER=${UNDER_QTY}) keyed by SLUG"
WINDOW_NOW="$(date -u +%Y-%m-01)"   # current month start = the period the guard sums over
seed() {
  psql_q >/dev/null 2>&1 <<SQL
-- REAL tenants shape (migration 032): id is a UUID, slug is the public identity
-- derived as 't-'||replace(id,'-',''). The data plane stamps the SLUG into
-- tenant_usage.tenant_id, so the guard MUST join tenants.slug = tenant_usage.tenant_id.
CREATE TABLE IF NOT EXISTS public.tenants (
  id   uuid PRIMARY KEY,
  slug text UNIQUE NOT NULL,
  plan text);
INSERT INTO public.tenants(id, slug, plan) VALUES
  ('${UUID_OVER}'::uuid, '${SLUG_OVER}','nano'),
  ('${UUID_UNDER}'::uuid,'${SLUG_UNDER}','nano')
  ON CONFLICT (id) DO UPDATE SET plan = EXCLUDED.plan, slug = EXCLUDED.slug;
-- Usage keyed by the SLUG (as the data plane writes it). OVER exceeds the nano
-- cap (100000); UNDER is well below. Note OVER (100001) is UNDER the essential
-- default cap (2,000,000) — so a broken UUID join would let it through (200).
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${SLUG_OVER}', '${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${OVER_QTY},  'm101-over-$$'),
  ('${SLUG_UNDER}','${METRIC}', '${WINDOW_NOW}T00:00:00Z', ${UNDER_QTY}, 'm101-under-$$')
  ON CONFLICT (idempotency_key) DO NOTHING;
-- A bare (no-RLS) table the data plane lists; one row so a served read returns 200.
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, label text);
INSERT INTO public.${PROBE_TABLE}(id, label) VALUES ('p1','ok') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done

# Prove the identity split is REAL: the UUID id must differ from the slug, else
# the gate would be as vacuous as m80.
[[ "$(psql_val "SELECT (id::text <> slug) FROM public.tenants WHERE slug='${SLUG_OVER}'")" == "t" ]] \
  || fail "tenants.id (uuid) must DIFFER from slug — the gate is vacuous otherwise (line: id≠slug check)"
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${SLUG_OVER}' AND metric='${METRIC}'")" == "${OVER_QTY}" ]] \
  || fail "OVER tenant_usage qty not seeded to ${OVER_QTY} (line: verify OVER seed)"
[[ "$(psql_val "SELECT qty FROM public.tenant_usage WHERE tenant_id='${SLUG_UNDER}' AND metric='${METRIC}'")" == "${UNDER_QTY}" ]] \
  || fail "UNDER tenant_usage qty not seeded to ${UNDER_QTY} (line: verify UNDER seed)"
ok "seeded realistic tenants: id(uuid) ≠ slug; OVER qty=${OVER_QTY} (> nano cap ${NANO_CAP}, < essential default ${DEFAULT_CAP}), UNDER qty=${UNDER_QTY}"

# ── 3) boot the QuotaGuard (orchestrator, QUOTA_ENFORCEMENT=1) ─────────────────
step "3/7 boot Go orchestrator (ORCHESTRATOR_SERVICES=quota-guard, QUOTA_ENFORCEMENT=1, interval=${GUARD_MS}ms)"
docker run -d --name "${ORCH}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e ORCHESTRATOR_SERVICES=quota-guard \
  -e ORCHESTRATOR_PORT=3060 \
  -e METERING_ENABLED=1 \
  -e QUOTA_ENFORCEMENT=1 \
  -e QUOTA_ENFORCEMENT_INTERVAL_MS="${GUARD_MS}" \
  -e LOG_LEVEL=debug \
  "${ORCH_IMG}" >/dev/null
wait_log "${ORCH}" "quota enforcement enabled" 60 \
  || { red "guard logs:"; docker logs "${ORCH}" 2>&1 | tail -20; fail "QuotaGuard never enabled (line: wait_log ORCH enabled)"; }
ok "QuotaGuard enabled — evaluating tenant_usage vs tier quota (joining on slug)"

# The REGRESSION-DISTINGUISHING assertion: with the fixed slug join the OVER
# tenant (nano, 100001) resolves its real nano cap and lands in quota:over. With
# the OLD broken UUID join it would resolve the essential default cap (2,000,000)
# and this set would be EMPTY → the wait below would time out and FAIL the gate.
step "3b/7 wait for QuotaGuard to publish quota:over with the OVER slug (FAILS on the broken UUID join)"
PUBLISHED=
for i in $(seq 1 60); do
  if [[ "$(redis_cli SISMEMBER quota:over "${SLUG_OVER}" 2>/dev/null)" == "1" ]]; then PUBLISHED=1; break; fi
  sleep 0.5
done
[[ -n "${PUBLISHED}" ]] || { red "quota:over members:"; redis_cli SMEMBERS quota:over 2>&1; fail "OVER slug never appeared in quota:over — the join did not resolve the nano plan (this is exactly the slug-vs-UUID bug) (line: wait quota:over)"; }
[[ "$(redis_cli SISMEMBER quota:over "${SLUG_UNDER}" 2>/dev/null)" == "0" ]] \
  || fail "UNDER slug wrongly listed in quota:over — the guard mis-decided (line: UNDER not in set)"
ok "guard published quota:over = {OVER slug}; UNDER absent — the slug join resolved the REAL nano plan"

# ── 4) (A) ENFORCE arm: data plane with DATA_PLANE_QUOTA_ENFORCEMENT=1 ─────────
step "4/7 boot data-plane-router DATA_PLANE_QUOTA_ENFORCEMENT=1 (A · ENFORCE), refresh=${REFRESH_MS}ms"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_QUOTA_ENFORCEMENT=1 \
  -e DATA_PLANE_QUOTA_REFRESH_MS="${REFRESH_MS}" \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "ENFORCE router not ready (line: wait_ready DPR_ON)"
sleep "$(awk "BEGIN{print (${REFRESH_MS}*2/1000)+1}")"
ok "ENFORCE router up (enforcement ON, snapshot refreshing from redis) on 127.0.0.1:${PORT_ON}"

step "4b/7 (A) request as OVER slug → MUST be 402 (the LOAD-BEARING reject)"
CODE_OVER=
for i in $(seq 1 20); do
  CODE_OVER="$(post_q "${PORT_ON}" "$(payload_list "${SLUG_OVER}")")"
  [[ "${CODE_OVER}" == "402" ]] && break
  sleep 0.5
done
[[ "${CODE_OVER}" == "402" ]] \
  || fail "(A) OVER slug expected 402 (quota exceeded), got ${CODE_OVER} — $(head -c 300 "${BODY_TMP}") (line: A OVER 402)"
grep -q 'quota_exceeded' "${BODY_TMP}" \
  || fail "(A) 402 body missing the quota_exceeded error — $(head -c 300 "${BODY_TMP}") (line: A OVER body)"
ok "(A) OVER slug rejected with 402 quota_exceeded — enforcement is REAL for a realistic tenant"

step "4c/7 (A) request as UNDER slug → MUST be 200 (under quota → served)"
CODE_UNDER="$(post_q "${PORT_ON}" "$(payload_list "${SLUG_UNDER}")")"
[[ "${CODE_UNDER}" == "200" ]] \
  || fail "(A) UNDER slug expected 200, got ${CODE_UNDER} — $(head -c 300 "${BODY_TMP}") (line: A UNDER 200)"
ok "(A) UNDER slug served 200 — enforcement does NOT over-reject"

# ── 5) (B) PARITY arm: data plane with enforcement OFF → BOTH 200 ──────────────
step "5/7 boot data-plane-router with enforcement UNSET (B · PARITY) — same redis, same seeds"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e REDIS_URL="${REDIS_INNET}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${DPR_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (enforcement OFF) on 127.0.0.1:${PORT_OFF}"

step "5b/7 (B) OVER slug through the OFF router → MUST be 200 (flag OFF = byte-parity)"
PCODE_OVER="$(post_q "${PORT_OFF}" "$(payload_list "${SLUG_OVER}")")"
[[ "${PCODE_OVER}" == "200" ]] \
  || fail "(B) PARITY OVER expected 200 (enforcement OFF), got ${PCODE_OVER} — $(head -c 300 "${BODY_TMP}") (line: B OVER 200)"
ok "(B) OVER slug served 200 with enforcement OFF — the over-quota set is NOT consulted"

step "5c/7 (B) UNDER slug through the OFF router → MUST be 200"
PCODE_UNDER="$(post_q "${PORT_OFF}" "$(payload_list "${SLUG_UNDER}")")"
[[ "${PCODE_UNDER}" == "200" ]] \
  || fail "(B) PARITY UNDER expected 200, got ${PCODE_UNDER} — $(head -c 300 "${BODY_TMP}") (line: B UNDER 200)"
ok "(B) UNDER slug served 200 with enforcement OFF — both arms identical = byte-parity"

# ── 6) cross-check + summarize ────────────────────────────────────────────────
step "6/7 cross-check: realistic tenant (uuid id ≠ slug) — ON rejects OVER(402)/serves UNDER(200); OFF serves BOTH(200)"
green "[M101] (A) ENFORCE: OVER(slug)→402 quota_exceeded · UNDER(slug)→200   (slug join resolved the nano plan)"
green "[M101] (B) PARITY:  OVER(slug)→200 · UNDER(slug)→200                  (flag OFF → byte-parity)"
green "[M101] regression: a nano tenant at ${OVER_QTY} would be served (200) under the OLD UUID join (essential default cap ${DEFAULT_CAP}); the slug join enforces it (402)."

# ── 7) emit the gate event via the kernel log helper (best-effort) ─────────────
step "7/7 log GATE m101=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-p0-quota-realtenant}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m101=PASS" --outcome pass \
      --msg "B2 quota enforcement against a REALISTIC tenant (uuid id != slug; tenant_usage keyed by slug): the QuotaGuard slug join resolves the real nano plan, OVER->402 / UNDER->200, OFF->both 200 (byte-parity). Regression guard on the slug-vs-UUID join bug — fails the old t.id::text join." \
      --ref "scripts/verify/m101-quota-realtenant.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M101] ALL GATES GREEN — quota enforcement resolves the REAL tenant plan via the slug join (non-vacuous billing truth-gate)"
exit 0
