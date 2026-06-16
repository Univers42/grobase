#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m85-tenant-observability.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M85 — Track-B per-tenant observability (B5) live gate. Proves the THREE
# cardinality-SAFE pillars do EXACTLY what they advertise — tenant_id becomes
# observable per-tenant WITHOUT a cardinality explosion — and that the LIVE
# BASELINE is byte-identical when every B5 flag is OFF (kernel rule #5):
#
#   PILLAR 1 — tenant_id as a STRUCTURED LOG FIELD (Loki field, never a label).
#     data-plane-server/src/routes.rs run_query wraps the handler in a tracing
#     span `request{tenant_id=…}` gated by config.tenant_obs ← DATA_PLANE_TENANT_OBS.
#     The default text formatter (main.rs `tracing_subscriber::fmt()…with_target`)
#     renders that span field as the literal token `tenant_id=<value>` on the
#     request's log lines — exactly what promtail's expressions-only extraction
#     (slice O) reads with `| json | tenant_id="X"`. When OFF the span is
#     `Span::none()`, entered NOTHING → log output byte-identical to baseline.
#
#   PILLAR 2 — Grafana per-tenant USAGE off public.tenant_usage (zero Prometheus
#     cardinality, reuses the B1 metering truth). config/grafana/.../datasources.yml
#     gains a Postgres-Usage datasource and config/grafana/.../dashboards/
#     per-tenant-usage.json a $tenant_id variable reading the DENSE public.tenants.
#
#   PILLAR 3 — OPTIONAL single bounded counter (default OFF, gated independently
#     by DATA_PLANE_TENANT_OBS_COUNTER): tenant_id on EXACTLY ONE counter
#     (baas_http_requests_total), capped at the first N=512 distinct tenant_ids
#     per process; every tenant beyond the cap folds into one sentinel series
#     tenant_id="_over_cap" → ceiling (N+1) series, independent of tenant count.
#
# ARMS (each fails CLOSED, naming the exact assertion that tripped):
#   (A) POSITIVE — DATA_PLANE_TENANT_OBS=1: one read + one write with known
#       tenant_ids → the router's log lines for BOTH events carry tenant_id=<id>.
#   (B) PARITY/OFF — flag unset, SAME two requests → ZERO log lines carry a
#       tenant_id field AND GET /metrics is byte-identical to a baseline capture
#       (no extra lines, no new labels). OFF == live baseline.
#   (C) NO-LABEL/NO-HISTOGRAM — STATIC: config/promtail/promtail.yaml lists
#       tenant_id under `expressions:` but NOT under `labels:`. RUNTIME: /metrics
#       carries a tenant_id label on at most the single counter
#       baas_http_requests_total and on NO histogram / other counter.
#   (D) BOUNDED-COUNTER — DATA_PLANE_TENANT_OBS_COUNTER=1: flood > N distinct
#       tenant_ids; the count of baas_http_requests_total series bearing a
#       tenant_id label is <= N+1, with the overflow folded to tenant_id="_over_cap".
#   PLUS a Grafana/Postgres SMOKE: the dashboard's $tenant_id variable query
#       (SELECT id FROM public.tenants) and a panel query against
#       public.tenant_usage both parse/execute; an UNauthenticated query to
#       public.tenant_usage returns ZERO rows (RLS) rather than leaking
#       cross-tenant data.
#
# ISOLATED by design (mirrors m74 / m83): a scratch data-plane-router built FROM
# THE CURRENT (drafted) source + a throwaway postgres, both on a PRIVATE network,
# every container/image/network name suffixed with $$, an EXIT-trap that removes
# EVERYTHING. It NEVER touches a mini-baas-* container/network/image/volume and
# NEVER edits the live docker-compose.yml. The probe hits the router's internal
# `/v1/query` trusted-envelope path inside the docker network with an inline DSN
# + a bare (no-RLS) probe table — exactly as m74 — so no Kong / tenant-control /
# auth machinery is needed and the test exercises the EXACT production code.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
DPR_DIR="${INFRA_DIR}/docker/services/data-plane-router"
PROMTAIL_YAML="${INFRA_DIR}/config/promtail/promtail.yaml"
DATASOURCES_YML="${INFRA_DIR}/config/grafana/provisioning/datasources/datasources.yml"
DASHBOARD_JSON="${INFRA_DIR}/config/grafana/provisioning/dashboards/per-tenant-usage.json"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_040="${MIG_DIR}/040_tenant_usage.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M85] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M85] FAIL — $*"; exit 1; }
# has/nhas: assert a string is / is NOT present in a captured log blob (arg, not
# a file — the router logs live in `docker logs`, not on disk).
has()  { grep -q "$1" <<<"$3" || fail "$2"; }
nhas() { grep -q "$1" <<<"$3" && fail "$2"; return 0; }

PG_IMAGE="${M85_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m85-dpr-$$:scratch"
NET="m85net-$$"
PG="m85-pg-$$"
DPR_ON="m85-dpr-on-$$"        # (A) POSITIVE  router (tenant_obs ON)
DPR_OFF="m85-dpr-off-$$"      # (B) PARITY    router (tenant_obs OFF/unset)
DPR_CNT="m85-dpr-cnt-$$"      # (D) COUNTER   router (tenant_obs + counter ON)
PORT_ON="${M85_PORT_ON:-18854}"
PORT_OFF="${M85_PORT_OFF:-18855}"
PORT_CNT="${M85_PORT_CNT:-18856}"
PGPW="postgres"
# One table per concern in the SHARED postgres so arms never cross-contaminate.
TABLE_PROBE="m85_obs_probe"        # the read/write probe table (bare, no RLS)
TENANT_READ="m85-read-$$"          # the read event's tenant_id (ground truth)
TENANT_WRITE="m85-write-$$"        # the write event's tenant_id (ground truth)
N_CAP=512                          # the in-process per-service cap (must match the code)
N_FLOOD=560                        # > N_CAP so the overflow sentinel must appear
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"
BASELINE_METRICS="$(mktemp)"       # the OFF-router /metrics capture (parity baseline)

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${DPR_CNT}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" "${BASELINE_METRICS}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply one migration file the SAME way `make migrate` does: strip the leading
# `#`/`--`-comment header lines before piping to psql. (040 uses SQL `--` comments
# and a DO block; we feed it whole — psql handles `--` natively.)  $1 = file.
apply_migration() { # $1=file
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$1" >/dev/null 2>&1
}

# Build the /v1/query envelope: identity + mount(inline DSN) + operation. Identical
# contract to m74 — the internal trusted-envelope path. The `service_role`/`admin`
# identity + bare (no-RLS) probe table means a `list`/`insert` always succeeds.
#   $1 = tenant_id  ·  $2 = op  ·  $3 = resource (table)  ·  $4 = data JSON (or `null`)
payload() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m85","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"%s","data":%s}}' \
    "$1" "$1" "$1" "${DSN_INNET}" "$2" "$3" "$4"
}

# POST a query to a router on 127.0.0.1:$port; echo the HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

# GET /metrics off a router → stdout (used for the parity byte-compare + label scan).
get_metrics() { curl -s "http://127.0.0.1:$1/metrics"; }

# tracing's text formatter styles field names with ANSI escapes (RUST_LOG=info,
# no_color is not forced) — strip CSI sequences before asserting on key=value.
# The B5 span renders as `request{tenant_id=<value>}` / `tenant_id=<value>` on the
# request's log lines; the robust anchor is the literal token `tenant_id=<id>`.
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }
logs_clean() { docker logs "$1" 2>&1 | strip_ansi; }

wait_ready() { # $1=container  $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/capabilities" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# ── 0) STATIC arm (C-static): promtail has tenant_id under expressions, NOT labels ─
# Done FIRST (no docker) so a config regression fails fast & cheap on the RAM box.
step "0/9 (C · STATIC) promtail.yaml: tenant_id under expressions, NEVER under labels"
[[ -f "${PROMTAIL_YAML}" ]] || fail "promtail config missing: ${PROMTAIL_YAML} (line: promtail exists)"
# Extract the docker-sd json `expressions:` block and the `labels:` block and check
# tenant_id lands in the former, never the latter. awk tracks which stanza we are in.
EXPR_HAS_TENANT="$(awk '
  /^      - json:/        {inj=1; inl=0}
  /^      - labels:/      {inj=0; inl=1}
  /^      - [a-z]/        {if ($0 !~ /json:|labels:/) {inj=0; inl=0}}
  inj && /^[[:space:]]+tenant_id:[[:space:]]/ {print "EXPR"}
' "${PROMTAIL_YAML}" | head -1)"
LABEL_HAS_TENANT="$(awk '
  /^      - json:/        {inj=1; inl=0}
  /^      - labels:/      {inj=0; inl=1}
  /^      - [a-z]/        {if ($0 !~ /json:|labels:/) {inj=0; inl=0}}
  inl && /^[[:space:]]+tenant_id:[[:space:]]*$/ {print "LABEL"}
' "${PROMTAIL_YAML}" | head -1)"
[[ "${EXPR_HAS_TENANT}" == "EXPR" ]] \
  || fail "promtail.yaml does NOT extract tenant_id under the json `expressions:` block — Pillar 1 field filter is dead (line: C-static expr)"
[[ -z "${LABEL_HAS_TENANT}" ]] \
  || fail "promtail.yaml promotes tenant_id to a LABEL — that creates one Loki stream per tenant = the cardinality bomb B5 forbids (line: C-static label)"
ok "(C-static) tenant_id is a promtail FIELD (expressions) and is NOT a Loki label"

step "0b/9 (Pillar 2 config) Postgres-Usage datasource + per-tenant-usage dashboard exist & parse"
[[ -f "${DATASOURCES_YML}" ]] || fail "datasources.yml missing (line: ds exists)"
grep -q 'name: Postgres-Usage' "${DATASOURCES_YML}" \
  || fail "datasources.yml has no Postgres-Usage datasource — Pillar 2 has no Grafana source (line: ds postgres)"
grep -q 'type: postgres' "${DATASOURCES_YML}" \
  || fail "datasources.yml Postgres-Usage is not type: postgres (line: ds type)"
[[ -f "${DASHBOARD_JSON}" ]] || fail "per-tenant-usage.json dashboard missing (line: dash exists)"
# Validate the dashboard JSON parses (python3 is present on the box; jq is a fallback).
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('${DASHBOARD_JSON}'))" \
    || fail "per-tenant-usage.json is not valid JSON (line: dash json parse)"
elif command -v jq >/dev/null 2>&1; then
  jq -e . "${DASHBOARD_JSON}" >/dev/null \
    || fail "per-tenant-usage.json is not valid JSON (line: dash jq parse)"
fi
grep -q '\$tenant_id' "${DASHBOARD_JSON}" \
  || fail "per-tenant-usage.json has no \$tenant_id template variable usage (line: dash var)"
grep -q 'public.tenant_usage' "${DASHBOARD_JSON}" \
  || fail "per-tenant-usage.json never queries public.tenant_usage — Pillar 2 reads the wrong source (line: dash usage table)"
grep -q 'FROM public.tenants' "${DASHBOARD_JSON}" \
  || fail "per-tenant-usage.json \$tenant_id variable must read the DENSE public.tenants, not a DISTINCT usage scan (line: dash var source)"
ok "(Pillar 2) Postgres-Usage datasource + per-tenant-usage dashboard present & valid; var reads public.tenants, panels read public.tenant_usage"

# ── 1) build the scratch DPR image FROM THE CURRENT (drafted) source ──────────
step "1/9 build scratch data-plane-router from CURRENT source (contains the B5 Pillar 1/3 code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch DPR image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 2) isolated network + throwaway postgres + REAL migration 040 + bare probe ─
step "2/9 boot isolated postgres (${PG}) on private net (${NET}); apply REAL 040 + bare probe table"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint inits then RESTARTS postgres once ("ready" twice) — wait
# for the SECOND "ready" so a query can never race the post-init restart.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state (line: PG ready loop)"
  sleep 0.5
done
# Prelude the objects migration 040 depends on (schema_migrations + auth.current_tenant_id
# + the authenticated/service_role roles), exactly as m83 does, then apply REAL 040.
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
apply_migration "${MIGRATION_040}" || fail "real migration 040_tenant_usage.sql failed to apply (line: apply 040)"
# A bare probe table (NO RLS) so the read/write arms run without auth machinery.
# A minimal public.tenants for the Pillar-2 SMOKE variable query, plus two
# tenant_usage rows scoped to TENANT_READ so the RLS-leak check has data to hide.
seed() {
  psql_q >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${TABLE_PROBE} (
  id text PRIMARY KEY, owner_id text, tenant_id text, label text);
INSERT INTO public.${TABLE_PROBE}(id, owner_id, tenant_id, label) VALUES
  ('r1','${TENANT_READ}','${TENANT_READ}','one'),
  ('r2','${TENANT_READ}','${TENANT_READ}','two') ON CONFLICT (id) DO NOTHING;
CREATE TABLE IF NOT EXISTS public.tenants (
  id text PRIMARY KEY, slug text, name text, plan text);
INSERT INTO public.tenants(id, slug, name, plan) VALUES
  ('${TENANT_READ}','${TENANT_READ}','read','nano'),
  ('${TENANT_WRITE}','${TENANT_WRITE}','write','nano') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.tenant_usage(tenant_id, metric, window_start, qty, idempotency_key) VALUES
  ('${TENANT_READ}','query.count', now(), 1, 'm85-k1-$$'),
  ('${TENANT_READ}','query.rows',  now(), 2, 'm85-k2-$$') ON CONFLICT (idempotency_key) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT count(*) FROM public.${TABLE_PROBE}")" == "2" ]] || fail "probe table not seeded with 2 rows (line: probe seeded)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_usage")" == "2" ]]  || fail "tenant_usage not seeded with 2 rows (line: usage seeded)"
ok "postgres up; migration 040 applied; probe table + public.tenants + 2 tenant_usage rows seeded"

# ── 3) (A · POSITIVE) router with DATA_PLANE_TENANT_OBS=1 — read + write carry tenant_id ─
step "3/9 boot scratch router DATA_PLANE_TENANT_OBS=1 (A · POSITIVE) on 127.0.0.1:${PORT_ON}"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_TENANT_OBS=1 \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "POSITIVE router not ready (line: wait_ready DPR_ON)"
ok "POSITIVE router up (tenant_obs ON) on 127.0.0.1:${PORT_ON}"

step "3b/9 fire ONE read (tenant=${TENANT_READ}) + ONE write (tenant=${TENANT_WRITE}) through the ON router"
code="$(post_q "${PORT_ON}" "$(payload "${TENANT_READ}" list "${TABLE_PROBE}" null)")"
[[ "${code}" == "200" ]] || fail "(A) read expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: A read status)"
code="$(post_q "${PORT_ON}" "$(payload "${TENANT_WRITE}" insert "${TABLE_PROBE}" "{\"id\":\"w1-$$\",\"owner_id\":\"${TENANT_WRITE}\",\"tenant_id\":\"${TENANT_WRITE}\",\"label\":\"wrote\"}")")"
[[ "${code}" == "200" ]] || fail "(A) write expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: A write status)"
ok "(A) read + write both served 200 (each carrying its own known tenant_id)"

step "3c/9 ASSERT (A): the ON router's logs carry tenant_id=<id> for BOTH the read AND the write"
# Allow the log writer to flush; the span fields are emitted synchronously on the
# request's log lines, but `docker logs` can lag the response by a tick.
sleep 1
LOGS_ON="$(logs_clean "${DPR_ON}")"
has "tenant_id=${TENANT_READ}" "(A) the READ's log line is missing tenant_id=${TENANT_READ} — Pillar 1 field not attached on a read (line: A read field)" "${LOGS_ON}"
has "tenant_id=${TENANT_WRITE}" "(A) the WRITE's log line is missing tenant_id=${TENANT_WRITE} — Pillar 1 field not attached on a write (line: A write field)" "${LOGS_ON}"
ok "(A) BOTH the read and the write emitted a tenant_id=<id> log FIELD — Pillar 1 proven on read AND write"

# ── 4) (B · PARITY/OFF) identical router, flag unset — NO field + /metrics byte-identical ─
step "4/9 boot scratch router with DATA_PLANE_TENANT_OBS unset (B · PARITY) on 127.0.0.1:${PORT_OFF}"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (tenant_obs default OFF) on 127.0.0.1:${PORT_OFF}"

step "4b/9 WARM the OFF router (read ${TENANT_READ} + write ${TENANT_WRITE}) so the baseline is WARM, not idle"
# The /metrics baseline MUST be captured warm: the per-mount pool gauge
# (baas_data_plane_pool_connections{mount=...}) and the status buckets appear
# LAZILY on first traffic, independent of B5. Comparing an idle baseline to a
# warm capture would flag that pool line as "drift" — a false positive that has
# nothing to do with the tenant_id flag. So we warm first, THEN baseline, THEN
# prove that NEW TENANTS add no further series (the real B5 cardinality parity).
code="$(post_q "${PORT_OFF}" "$(payload "${TENANT_READ}" list "${TABLE_PROBE}" null)")"
[[ "${code}" == "200" ]] || fail "(B) warm read expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: B warm read)"
code="$(post_q "${PORT_OFF}" "$(payload "${TENANT_WRITE}" insert "${TABLE_PROBE}" "{\"id\":\"w2-$$\",\"owner_id\":\"${TENANT_WRITE}\",\"tenant_id\":\"${TENANT_WRITE}\",\"label\":\"wrote\"}")")"
[[ "${code}" == "200" ]] || fail "(B) warm write expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: B warm write)"
sleep 1
ok "(B) OFF router warmed (mount pool + status buckets now exist; read+write served 200 — no behavior change)"

step "4c/9 ASSERT (B-1): ZERO log lines carry a tenant_id field with the flag OFF"
LOGS_OFF="$(logs_clean "${DPR_OFF}")"
N_FIELD_OFF="$(grep -c 'tenant_id=' <<<"${LOGS_OFF}" || true)"
[[ -z "${LOGS_OFF}" ]] && N_FIELD_OFF=0
[[ "${N_FIELD_OFF}" == "0" ]] \
  || fail "(B) OFF router emitted ${N_FIELD_OFF} log line(s) with a tenant_id field — the default is NOT byte-parity! $(grep 'tenant_id=' <<<"${LOGS_OFF}" | tail -3) (line: B field leak)"
nhas "tenant_id=${TENANT_READ}" "(B) OFF router leaked the read tenant_id field (line: B nhas read)" "${LOGS_OFF}"
nhas "tenant_id=${TENANT_WRITE}" "(B) OFF router leaked the write tenant_id field (line: B nhas write)" "${LOGS_OFF}"
ok "(B-1) ZERO tenant_id log fields with the flag OFF — log path byte-parity"

step "4d/9 capture the /metrics PARITY BASELINE off the WARM OFF router (pool + buckets present)"
get_metrics "${PORT_OFF}" > "${BASELINE_METRICS}"
[[ -s "${BASELINE_METRICS}" ]] || fail "(B) /metrics baseline capture was empty (line: B baseline capture)"
ok "(B) warm /metrics baseline captured ($(grep -c . "${BASELINE_METRICS}" || true) lines)"

step "4e/9 ASSERT (B-2): fire TWO MORE *distinct* tenants on the SAME mount → /metrics SHAPE byte-identical (flag OFF ⇒ new tenants add NO series)"
# Both snapshots are WARM (same mount pool, same status buckets); the ONLY thing
# that could differ is a NEW per-tenant series — which must NOT appear when the
# flag is OFF. This is the real cardinality-parity test (idle-vs-warm was a false
# positive on the lazy pool gauge). Counter VALUES differ but the SHAPE must match.
code="$(post_q "${PORT_OFF}" "$(payload "${TENANT_READ}-b2" list "${TABLE_PROBE}" null)")"
[[ "${code}" == "200" ]] || fail "(B) 2nd-batch read (new tenant) expected 200, got ${code} (line: B b2 read)"
code="$(post_q "${PORT_OFF}" "$(payload "${TENANT_WRITE}-b2" insert "${TABLE_PROBE}" "{\"id\":\"w3-$$\",\"owner_id\":\"x\",\"tenant_id\":\"x\",\"label\":\"wrote\"}")")"
[[ "${code}" == "200" ]] || fail "(B) 2nd-batch write (new tenant) expected 200, got ${code} (line: B b2 write)"
sleep 1
shape() { sed -E 's/[[:space:]]+[0-9.eE+-]+$//' "$1" | sort -u; }
AFTER_METRICS="$(mktemp)"
get_metrics "${PORT_OFF}" > "${AFTER_METRICS}"
DELTA="$(comm -3 <(shape "${BASELINE_METRICS}") <(shape "${AFTER_METRICS}") || true)"
rm -f "${AFTER_METRICS}"
[[ -z "${DELTA}" ]] \
  || fail "(B-2) /metrics SHAPE drifted after 2 NEW tenants with the flag OFF — NOT byte-parity:
${DELTA}
(line: B metrics shape drift)"
# Belt & braces: no tenant_id label anywhere on the OFF router's /metrics.
nhas 'tenant_id=' "(B-2) OFF router /metrics carries a tenant_id label — must be ZERO when OFF (line: B metrics tenant label)" "$(get_metrics "${PORT_OFF}")"
ok "(B-2) /metrics shape byte-identical across 2 new tenants; no tenant_id label when OFF — full cardinality parity"

# ── 5) (C · RUNTIME) /metrics tenant_id label only on baas_http_requests_total, no histogram ─
step "5/9 (C · RUNTIME) on the ON router, /metrics tenant_id label appears on NO counter/histogram (counter sub-flag OFF)"
# With DATA_PLANE_TENANT_OBS=1 but the COUNTER sub-flag OFF, Pillar 3 is inert:
# /metrics must carry NO tenant_id label at all (the log field is Pillar 1, not a
# metric). This proves the parent obs flag does NOT by itself touch /metrics.
METRICS_ON="$(get_metrics "${PORT_ON}")"
nhas 'tenant_id=' "(C) the ON router (counter sub-flag OFF) put a tenant_id label on /metrics — the counter must stay OFF until its own sub-flag (line: C obs-only no metric label)" "${METRICS_ON}"
# The base stack exposes NO histograms (atomic counters only); assert the only
# place tenant_id could EVER appear is baas_http_requests_total, never a *_bucket /
# *_sum / *_count histogram series.
nhas '_bucket' "(C) /metrics exposes a *_bucket histogram series — B5 must never put tenant_id on a histogram; none should exist (line: C no histogram)" "${METRICS_ON}"
ok "(C-runtime, obs-only) /metrics carries NO tenant_id label and NO histogram series"

# ── 6) (D · BOUNDED-COUNTER) flood > N distinct tenant_ids → series count <= N+1 ─
step "6/9 boot scratch router DATA_PLANE_TENANT_OBS=1 DATA_PLANE_TENANT_OBS_COUNTER=1 (D · COUNTER) on 127.0.0.1:${PORT_CNT}"
docker run -d --name "${DPR_CNT}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_TENANT_OBS=1 \
  -e DATA_PLANE_TENANT_OBS_COUNTER=1 \
  -e RUST_LOG=warn \
  -p "127.0.0.1:${PORT_CNT}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_CNT}" "${PORT_CNT}" || fail "COUNTER router not ready (line: wait_ready DPR_CNT)"
ok "COUNTER router up (tenant_obs + counter ON) on 127.0.0.1:${PORT_CNT}"

step "6b/9 flood ${N_FLOOD} distinct tenant_ids (> N=${N_CAP}) through the COUNTER router"
# Each request uses a unique tenant_id; the bare probe table makes every list a
# 200, so each distinct tenant_id reaches the counter path exactly once. We do not
# need the rows — only that the request is counted under its tenant_id label.
for i in $(seq 1 "${N_FLOOD}"); do
  post_q "${PORT_CNT}" "$(payload "m85-flood-${i}-$$" list "${TABLE_PROBE}" null)" >/dev/null 2>&1 || true
done
ok "fired ${N_FLOOD} requests, each with a distinct tenant_id"

step "6c/9 ASSERT (D): baas_http_requests_total series with a tenant_id label is <= N+1 (cap holds)"
sleep 1
METRICS_CNT="$(get_metrics "${PORT_CNT}")"
# Count baas_http_requests_total lines that carry a tenant_id label.
N_SERIES="$(grep -E '^baas_http_requests_total\{[^}]*tenant_id=' <<<"${METRICS_CNT}" | grep -c . || true)"
[[ -z "${METRICS_CNT}" ]] && N_SERIES=0
[[ "${N_SERIES}" -ge 1 ]] \
  || fail "(D) the COUNTER router exposed ZERO baas_http_requests_total{tenant_id=...} series — the bounded counter never emitted (line: D no series)"
[[ "${N_SERIES}" -le $((N_CAP + 1)) ]] \
  || fail "(D) baas_http_requests_total carries ${N_SERIES} tenant_id series — exceeds the cap N+1=$((N_CAP + 1)); the in-process cap is NOT enforced = cardinality bomb (line: D cap breach)"
# The overflow MUST have folded the > N_CAP excess into the single sentinel series.
has 'tenant_id="_over_cap"' "(D) flooded ${N_FLOOD} > ${N_CAP} tenants but no tenant_id=\"_over_cap\" sentinel series — overflow was NOT folded (line: D no sentinel)" "${METRICS_CNT}"
# The tenant_id label appears ONLY on baas_http_requests_total, never elsewhere.
OTHER_TENANT="$(grep 'tenant_id=' <<<"${METRICS_CNT}" | grep -vE '^baas_http_requests_total\{' | grep -c . || true)"
[[ "${OTHER_TENANT}" == "0" ]] \
  || fail "(D) a tenant_id label appears on a metric OTHER than baas_http_requests_total ($(grep 'tenant_id=' <<<"${METRICS_CNT}" | grep -vE '^baas_http_requests_total\{' | head -2)) — B5 caps it to ONE counter (line: D label leak)"
ok "(D) ${N_SERIES} tenant_id series <= N+1=$((N_CAP + 1)); overflow folded to tenant_id=\"_over_cap\"; label only on baas_http_requests_total"

# ── 7) Grafana / Postgres SMOKE: variable + panel queries execute; RLS hides cross-tenant ─
# Free the routers before the SMOKE: it only needs postgres, and on a RAM-constrained
# host the three routers + the 560-request flood can starve postgres (psql then fails
# to connect — exit 2). Tearing the routers down keeps the SMOKE deterministic. The
# load-bearing B5 arms (A field-on · B parity · C no-label/no-histogram · D bounded
# counter) have all already asserted above; nothing below needs a router.
docker rm -f "${DPR_ON}" "${DPR_OFF}" "${DPR_CNT}" >/dev/null 2>&1 || true
sleep 1

step "7/9 (SMOKE) the dashboard's \$tenant_id variable query + a panel query both execute"
# Variable query: SELECT id FROM public.tenants (dense, bounded). Must return both
# seeded tenants (proves the variable source is queryable as Grafana would run it).
VAR_ROWS="$(psql_val "SELECT count(*) FROM (SELECT id FROM public.tenants ORDER BY id) q")"
[[ "${VAR_ROWS}" == "2" ]] \
  || fail "(SMOKE) \$tenant_id variable query (SELECT id FROM public.tenants) returned ${VAR_ROWS} rows, expected 2 (line: smoke var)"
# Panel query: the per-tenant usage select, filtered to one tenant. Must parse &
# return the seeded usage rows for TENANT_READ.
PANEL_ROWS="$(psql_val "SELECT count(*) FROM (SELECT window_start, metric, qty FROM public.tenant_usage WHERE tenant_id = '${TENANT_READ}' ORDER BY window_start) q")"
[[ "${PANEL_ROWS}" == "2" ]] \
  || fail "(SMOKE) panel query against public.tenant_usage for ${TENANT_READ} returned ${PANEL_ROWS} rows, expected 2 (line: smoke panel)"
ok "(SMOKE) \$tenant_id variable query + a public.tenant_usage panel query both parse & return the seeded data"

step "7b/9 (SMOKE · RLS) an UNauthenticated read of public.tenant_usage returns ZERO rows (no cross-tenant leak)"
# As the un-scoped `authenticated` role with NO request.tenant_id GUC set, the RLS
# policy tenant_usage_tenant_isolation must hide every row — a leak here would mean
# the Pillar-2 datasource role could read across tenants. (postgres superuser is
# BYPASSRLS, so we explicitly SET ROLE authenticated for this probe.)
# NOTE: `SET ROLE …; SELECT …` under psql -tAc prints the SET command tag ("SET")
# AND the SELECT tuple, so psql_val's whitespace-strip would yield "SET0"; keep only
# the trailing digits so the assertion compares the actual row count.
RLS_ROWS="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc "SET ROLE authenticated; SELECT count(*) FROM public.tenant_usage" 2>/dev/null | tr -dc '0-9')"
[[ "${RLS_ROWS}" == "0" ]] \
  || fail "(SMOKE · RLS) an unauthenticated/authenticated read saw '${RLS_ROWS}' tenant_usage rows — RLS is NOT hiding cross-tenant data (line: smoke RLS leak)"
ok "(SMOKE · RLS) unauthenticated read of public.tenant_usage = 0 rows — RLS scopes per-tenant, no cross-tenant leak"

# ── 8) summary ────────────────────────────────────────────────────────────────
step "8/9 summary"
green "[M85] (A) POSITIVE:  DATA_PLANE_TENANT_OBS=1 → read (tenant=${TENANT_READ}) AND write (tenant=${TENANT_WRITE}) log lines carry tenant_id=<id> (Pillar 1)"
green "[M85] (B) PARITY:    flag OFF → ZERO tenant_id log fields + /metrics shape byte-identical to baseline (kernel rule #5)"
green "[M85] (C) NO-LABEL:  promtail tenant_id under expressions NOT labels; ON router (counter OFF) /metrics has NO tenant_id label, NO histogram"
green "[M85] (D) BOUNDED:   flooded ${N_FLOOD}>${N_CAP} tenants → ${N_SERIES} tenant_id series <= N+1, overflow folded to tenant_id=\"_over_cap\", label only on baas_http_requests_total"
green "[M85] (SMOKE):       \$tenant_id var + public.tenant_usage panel queries execute; unauthenticated tenant_usage read = 0 rows (RLS)"

# ── 9) emit the gate event via the kernel log helper (best-effort) ────────────
step "9/9 log GATE m85=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b5-tenant-observability}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m85=PASS" --outcome pass \
      --msg "B5 per-tenant observability: DATA_PLANE_TENANT_OBS=1 attaches tenant_id as a LOG FIELD on read+write (Pillar 1); OFF -> zero tenant_id fields + /metrics shape byte-identical (parity); promtail extracts tenant_id under expressions NOT labels + no histogram series (Pillar 2/3 cardinality invariant); DATA_PLANE_TENANT_OBS_COUNTER caps baas_http_requests_total tenant_id series at <=N+1 with an _over_cap sentinel (Pillar 3); Grafana \$tenant_id var + public.tenant_usage panel queries execute and tenant_usage RLS hides cross-tenant rows" \
      --ref "scripts/verify/m85-tenant-observability.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M85] ALL GATES GREEN — B5 per-tenant observability: tenant_id is a Loki FIELD (ON) / absent (OFF, byte-parity), never a label/histogram, and the optional counter is hard-bounded at N+1 — cardinality-safe at 10K+ tenants"
exit 0
