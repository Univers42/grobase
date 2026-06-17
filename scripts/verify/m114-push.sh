#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m114-push.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M114 — Track-E PUSH / MESSAGING (Firebase FCM-parity) live gate. A tenant
# registers push SUBSCRIPTIONS (channel webhook | fcm — both an outbound HTTP
# POST to a configured target_url, so 'fcm' is a pluggable FCM-compatible
# endpoint, no real FCM SDK) and SENDS a notification that fans out to every
# matching subscription. It reuses internal/webhooks' outbound-HTTP delivery
# discipline (per-request timeout + an SSRF guard that refuses private/loopback/
# link-local targets). Flag-gated OFF by default (PUSH_ENABLED).
#
# It exercises a tenant-control binary built FROM CURRENT source (the EXACT
# Track-E push code) as the sender, a from-source mock HTTP SINK as the
# subscriber, and a scratch postgres:
#
#   tenant-control (Go, PUSH_ENABLED=1)   X-Service-Token: …  (admin)
#       POST   /v1/tenants/{id}/push/subscriptions        register -> 201
#       GET    /v1/tenants/{id}/push/subscriptions        list     -> 200
#       DELETE /v1/tenants/{id}/push/subscriptions/{subId} revoke  -> 204
#       POST   /v1/tenants/{id}/push/send {title,body}    fan-out  -> 200
#
#   (A · POSITIVE) register a webhook subscription pointing at the SINK; POST
#       /push/send -> the sink RECEIVES the notification payload (title + body
#       present); the send result reports delivered>=1.
#   (B · REJECT, LOAD-BEARING) (1) cross-tenant: a T2 caller's send/list cannot
#       see or deliver to T1's subscription — the sink gets NO T1 payload from a
#       T2 send, T2's list is empty, and T1's subscription is UNCHANGED (still
#       deliverable). (2) SSRF: a subscription whose target_url is an INTERNAL
#       address (http://169.254.169.254/ AND the pg container) is REJECTED at
#       register time (400 blocked_target), no row stored, no delivery.
#   (C · FLAG-OFF PARITY) a SECOND tenant-control with PUSH_ENABLED unset: every
#       /v1/tenants/{id}/push/* route 404 WHILE base admin GET /v1/tenants 200,
#       and push_subscriptions has 0 rows — byte-identical to today.
#
# ISOLATED by design (mirrors m109/m111): scratch postgres (prelude + REAL 005 +
# 032 + 056) + two tenant-control binaries + one mock-sink, ALL built FROM
# CURRENT source, on a PRIVATE network, every name suffixed with $$, an EXIT-trap
# removing EVERYTHING. It NEVER touches a mini-baas-* container/network/image/
# volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_056="${MIG_DIR}/056_push_subscriptions.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M114] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M114] FAIL — $*"; exit 1; }

PG_IMAGE="${M114_PG_IMAGE:-postgres:16-alpine}"
TC_IMG="m114-tc-$$:scratch"
SINK_IMG="m114-sink-$$:scratch"
NET="m114net-$$"
PG="m114-pg-$$"
SINK="m114-sink-$$"
TC_ON="m114-tc-on-$$"      # PUSH_ENABLED=1    (A · positive / B · reject)
TC_OFF="m114-tc-off-$$"    # PUSH_ENABLED unset (C · parity)
PORT_ON="${M114_PORT_ON:-19132}"
PORT_OFF="${M114_PORT_OFF:-19133}"
SINK_PORT="${M114_SINK_PORT:-19134}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m114-internal-service-token-$$"
TENANT_1="m114-tenant-one-$$"   # owns the webhook subscription -> the sink
TENANT_2="m114-tenant-two-$$"   # the cross-tenant attacker (must see NOTHING of T1)
WORK="$(mktemp -d)"
BODY_TMP="${WORK}/body.json"
SINK_DIR="${M114_SINK_DIR:-/mnt/storage/bench/m114-sink-$$}"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${SINK}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${SINK_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" "${SINK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Service-token admin request. $1=method $2=port $3=path $4=body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}

# json_str: extract a top-level JSON string field off BODY_TMP. Tolerates 0 matches.
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*"'"$1"'":"//; s/"$//'; }
# json_num: extract a top-level JSON numeric field off BODY_TMP.
json_num() { { grep -o "\"$1\":[0-9]\+" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*://'; }

wait_ready() { # $1=container $2=port $3=path
  local i path="${3:-/health/live}"
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2${path}" 2>/dev/null)" =~ ^(200|204)$ ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# The sink records every POSTed body to /data/received.log (one JSON body per
# line). GET /count -> number of recorded bodies; GET /dump -> the bodies.
sink_count() { curl -s "http://127.0.0.1:${SINK_PORT}/count" 2>/dev/null | tr -d '[:space:]'; }
sink_dump()  { curl -s "http://127.0.0.1:${SINK_PORT}/dump" 2>/dev/null; }
sink_reset() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SINK_PORT}/reset" 2>/dev/null; }

# ── 0a) build tenant-control FROM CURRENT source ───────────────────────────────
step "0a/10 build tenant-control FROM CURRENT source (the EXACT Track-E push code)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3090 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted push code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 0b) build the mock HTTP SINK FROM CURRENT source ───────────────────────────
step "0b/10 build a from-source mock HTTP sink (records POSTed bodies)"
mkdir -p "${WORK}/sink"
cat > "${WORK}/sink/main.go" <<'GO'
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
)

// A deliberately tiny sink: POST /* appends the request body (one per line) to an
// in-memory log; GET /count returns the count; GET /dump returns the bodies; GET
// /reset clears them. It is the push subscriber the gate delivers notifications to.
func main() {
	var (
		mu     sync.Mutex
		bodies []string
	)
	port := os.Getenv("SINK_PORT")
	if port == "" {
		port = "8080"
	}
	http.HandleFunc("/count", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(w, "%d", len(bodies))
	})
	http.HandleFunc("/dump", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		for _, b := range bodies {
			fmt.Fprintln(w, b)
		}
	})
	http.HandleFunc("/reset", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		bodies = nil
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			bodies = append(bodies, string(b))
			mu.Unlock()
		}
		w.WriteHeader(http.StatusOK)
	})
	_ = http.ListenAndServe(":"+port, nil)
}
GO
cat > "${WORK}/sink/Dockerfile" <<'DOCKER'
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY main.go .
RUN go env -w GOFLAGS=-mod=mod && go mod init sink >/dev/null 2>&1 || true
RUN CGO_ENABLED=0 go build -o /sink main.go
FROM gcr.io/distroless/static-debian12
COPY --from=build /sink /sink
ENTRYPOINT ["/sink"]
DOCKER
DOCKER_BUILDKIT=1 docker build -q -t "${SINK_IMG}" "${WORK}/sink" >/dev/null \
  || fail "mock sink image build failed (line: docker build SINK)"
ok "mock sink built (records POSTed notification bodies)"

# ── 1) isolated net + postgres (TCP-ready) ─────────────────────────────────────
step "1/10 boot isolated net (${NET}): postgres + mock sink"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# Boot the sink (reachable in-net as http://${SINK}:8080, and host-mapped for the gate).
docker run -d --name "${SINK}" --network "${NET}" \
  -e SINK_PORT=8080 -p "127.0.0.1:${SINK_PORT}:8080" "${SINK_IMG}" >/dev/null
wait_ready "${SINK}" "${SINK_PORT}" "/count" || fail "mock sink not ready (line: wait_ready SINK)"
ok "mock sink up (in-net http://${SINK}:8080, host 127.0.0.1:${SINK_PORT})"

# ── 1b) prelude + REAL 005/032/056 ─────────────────────────────────────────────
step "1b/10 prelude (schema_migrations, auth.current_tenant_id, roles) then REAL 005/032/056"
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
# tenant-control's boot schema-check requires public.tenants (005 + 032).
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
[[ -f "${MIGRATION_056}" ]] || fail "migration 056_push_subscriptions.sql is MISSING — the Track-E push migration must land before m114 (line: 056 exists)"
apply_migration "${MIGRATION_056}" || fail "real migration 056_push_subscriptions.sql failed to apply (line: apply 056)"
[[ "$(psql_val "SELECT to_regclass('public.push_subscriptions') IS NOT NULL")" == "t" ]] \
  || fail "public.push_subscriptions not created by migration 056 (line: 056 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.push_subscriptions")" == "0" ]] \
  || fail "push_subscriptions should start EMPTY (line: 056 empty check)"
# authenticated must be read-only on push_subscriptions (only service_role writes).
HASW="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='push_subscriptions' AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE')")" || HASW="?"
[[ "${HASW}" == "0" ]] || fail "authenticated must NOT have INSERT/UPDATE/DELETE on push_subscriptions, got ${HASW} (line: 056 grants)"
ok "migrations 005 + 032 + 056 applied — push_subscriptions exists + empty, authenticated read-only"

# ── 2) boot the PUSH-ON tenant-control ─────────────────────────────────────────
step "2/10 boot tenant-control PUSH_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PUSH_ENABLED=1 \
  -e PUSH_SECRET_KEY="m114-push-secret-key-$$" \
  -e PUSH_SSRF_ALLOW_HOSTS="${SINK}" \
  -e TENANT_CONTROL_PORT=3090 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3090" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "push-ON tenant-control not ready (line: wait_ready TC_ON)"
docker logs "${TC_ON}" 2>&1 | grep -qi "push .* enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "push never reported enabled (line: TC_ON enabled log)"; }
ok "push-ON tenant-control up (/v1/tenants/{id}/push/* mounted)"

# ── 3) seed two tenants via admin endpoints ────────────────────────────────────
step "3/10 seed T1 + T2 via POST /v1/tenants (X-Service-Token)"
for t in "${TENANT_1}" "${TENANT_2}"; do
  C="$(admin_req POST "${PORT_ON}" /v1/tenants "{\"id\":\"${t}\",\"name\":\"${t}\",\"plan\":\"nano\"}")"
  [[ "${C}" == "201" ]] || fail "seed tenant ${t} expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: seed ${t})"
done
ok "tenants T1 + T2 created (nano)"

# ── 4) (A · POSITIVE) register a webhook subscription -> the sink, then send ────
step "4a/10 (A · POSITIVE) register a webhook subscription for T1 pointing at the in-net sink"
SINK_URL="http://${SINK}:8080/hook"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/subscriptions" \
  "{\"channel\":\"webhook\",\"target_url\":\"${SINK_URL}\",\"label\":\"t1-sink\"}")"
[[ "${C}" == "201" ]] || fail "(A) register expected 201, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A register 201)"
SUB_1="$(json_str id)"
[[ -n "${SUB_1}" ]] || fail "(A) register returned no subscription id — $(head -c 300 "${BODY_TMP}") (line: A sub id)"
grep -q '"channel":"webhook"' "${BODY_TMP}" || fail "(A) registered sub missing channel webhook (line: A channel)"
# The sealed token must NOT leak in the response (write-only); has_token=false here.
grep -q '"has_token":false' "${BODY_TMP}" || fail "(A) webhook sub should report has_token:false (line: A no token)"
[[ "$(psql_val "SELECT count(*) FROM public.push_subscriptions WHERE tenant_id='${TENANT_1}' AND revoked_at IS NULL")" == "1" ]] \
  || fail "(A) T1 subscription not persisted (line: A persisted)"
ok "(A) webhook subscription ${SUB_1} registered for T1 -> ${SINK_URL}"

step "4b/10 (A · POSITIVE) GET list -> exactly T1's one live subscription"
C="$(admin_req GET "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/subscriptions")"
[[ "${C}" == "200" ]] || fail "(A) list expected 200, got ${C} (line: A list 200)"
grep -q "\"id\":\"${SUB_1}\"" "${BODY_TMP}" || fail "(A) list missing ${SUB_1} (line: A list has id)"
ok "(A) GET list -> T1's subscription present"

step "4c/10 (A · POSITIVE) POST /push/send -> the sink RECEIVES the notification (title+body)"
[[ "$(sink_reset)" == "200" ]] || fail "(A) could not reset sink (line: A sink reset)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/send" \
  '{"title":"M114 Build done","body":"deploy ok"}')"
[[ "${C}" == "200" ]] || fail "(A) send expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A send 200)"
A_MATCHED="$(json_num matched)"; A_DELIVERED="$(json_num delivered)"
[[ "${A_MATCHED}" == "1" ]] || fail "(A) send matched=${A_MATCHED}, want 1 (line: A matched)"
[[ "${A_DELIVERED}" == "1" ]] || fail "(A) send delivered=${A_DELIVERED}, want 1 — the sink was not reached (line: A delivered)"
# The sink must have recorded exactly one body carrying the title + body.
SINK_N=""
for i in $(seq 1 20); do SINK_N="$(sink_count)"; [[ "${SINK_N}" == "1" ]] && break; sleep 0.3; done
[[ "${SINK_N}" == "1" ]] || fail "(A) sink recorded ${SINK_N} bodies, want 1 (line: A sink count)"
sink_dump | grep -q "M114 Build done" || fail "(A) sink body missing the notification title (line: A sink title)"
sink_dump | grep -q "deploy ok" || fail "(A) sink body missing the notification body (line: A sink body)"
ok "(A) send delivered to the sink; payload carries title + body"

# ── 5) (B · REJECT 1: cross-tenant) ────────────────────────────────────────────
step "5a/10 (B · LOAD-BEARING) cross-tenant: T2's list does NOT see T1's subscription"
C="$(admin_req GET "${PORT_ON}" "/v1/tenants/${TENANT_2}/push/subscriptions")"
[[ "${C}" == "200" ]] || fail "(B) T2 list expected 200, got ${C} (line: B t2 list 200)"
grep -q "\"id\":\"${SUB_1}\"" "${BODY_TMP}" \
  && fail "(B) T2's list LEAKED T1's subscription ${SUB_1} — cross-tenant breach! (line: B t2 no leak)"
# T2 has no subscriptions of its own -> empty array.
[[ "$(cat "${BODY_TMP}")" == "[]" || "$(json_str id)" == "" ]] \
  || fail "(B) T2 list not empty — $(head -c 200 "${BODY_TMP}") (line: B t2 empty)"
ok "(B) T2's list is empty — T1's subscription is invisible to T2"

step "5b/10 (B · LOAD-BEARING) cross-tenant: a T2 SEND delivers to ZERO subscriptions (the sink gets NOTHING)"
[[ "$(sink_reset)" == "200" ]] || fail "(B) could not reset sink before T2 send (line: B sink reset)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_2}/push/send" \
  '{"title":"M114 T2 INTRUSION","body":"should never arrive"}')"
[[ "${C}" == "200" ]] || fail "(B) T2 send expected 200, got ${C} (line: B t2 send 200)"
B_MATCHED="$(json_num matched)"
[[ "${B_MATCHED}" == "0" ]] || fail "(B) T2 send matched=${B_MATCHED}, want 0 — T2 reached T1's subscription! (line: B t2 matched 0)"
# Give any (erroneous) delivery a beat, then prove the sink saw nothing.
sleep 1
B_SINK="$(sink_count)"
[[ "${B_SINK}" == "0" ]] \
  || fail "(B) the sink received ${B_SINK} bodies from a T2 send — CROSS-TENANT DELIVERY LEAK! (line: B t2 sink zero)"
sink_dump | grep -q "M114 T2 INTRUSION" \
  && fail "(B) the T2 intrusion payload reached T1's sink — breach! (line: B t2 no intrusion)"
# T1's subscription is UNCHANGED (still live + deliverable).
[[ "$(psql_val "SELECT count(*) FROM public.push_subscriptions WHERE id='${SUB_1}'::uuid AND revoked_at IS NULL")" == "1" ]] \
  || fail "(B) T1's subscription was mutated by a T2 action (line: B t1 unchanged)"
ok "(B) T2 send matched 0 subscriptions, the sink got nothing, T1 unchanged — the per-tenant wall holds"

# ── 6) (B · REJECT 2: SSRF) internal targets are refused at register time ──────
step "6/10 (B · LOAD-BEARING) SSRF guard: registering an INTERNAL target_url is rejected (400), no row, no delivery"
PRE_COUNT="$(psql_val "SELECT count(*) FROM public.push_subscriptions")"
# 6a) the cloud metadata link-local address.
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/subscriptions" \
  '{"channel":"webhook","target_url":"http://169.254.169.254/latest/meta-data/","label":"ssrf-metadata"}')"
[[ "${C}" == "400" ]] \
  || fail "(B) SSRF metadata target expected 400, got ${C} — the SSRF guard did not fire — $(head -c 300 "${BODY_TMP}") (line: B ssrf metadata 400)"
grep -qi 'blocked_target\|ssrf\|private\|internal\|link-local' "${BODY_TMP}" \
  || fail "(B) SSRF 400 body missing a blocked-target message — $(head -c 300 "${BODY_TMP}") (line: B ssrf metadata msg)"
# 6b) the in-cluster postgres container (private/resolved-internal).
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/subscriptions" \
  "{\"channel\":\"webhook\",\"target_url\":\"http://${PG}:5432/\",\"label\":\"ssrf-pg\"}")"
[[ "${C}" == "400" ]] \
  || fail "(B) SSRF pg-container target expected 400, got ${C} — the SSRF guard did not fire — $(head -c 300 "${BODY_TMP}") (line: B ssrf pg 400)"
# No blocked subscription was stored.
POST_COUNT="$(psql_val "SELECT count(*) FROM public.push_subscriptions")"
[[ "${PRE_COUNT}" == "${POST_COUNT}" ]] \
  || fail "(B) a blocked SSRF target was STORED (before=${PRE_COUNT} after=${POST_COUNT}) — the guard must reject before insert (line: B ssrf no row)"
ok "(B) SSRF guard refuses 169.254.169.254 AND the pg container (400 blocked_target); no row stored, no delivery"

# ── 7) revoke -> the subscription is no longer a delivery target ────────────────
step "7/10 (A · POSITIVE) DELETE the subscription -> 204; a subsequent send matches 0"
C="$(admin_req DELETE "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/subscriptions/${SUB_1}")"
[[ "${C}" == "204" ]] || fail "(A) revoke expected 204, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A revoke 204)"
[[ "$(psql_val "SELECT count(*) FROM public.push_subscriptions WHERE id='${SUB_1}'::uuid AND revoked_at IS NOT NULL")" == "1" ]] \
  || fail "(A) revoke did not soft-delete the subscription (line: A revoked row)"
[[ "$(sink_reset)" == "200" ]] || fail "(A) could not reset sink before post-revoke send (line: A sink reset 2)"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_1}/push/send" '{"title":"post-revoke","body":"nobody home"}')"
[[ "${C}" == "200" ]] || fail "(A) post-revoke send expected 200, got ${C} (line: A post-revoke send)"
[[ "$(json_num matched)" == "0" ]] || fail "(A) post-revoke send matched != 0 — a revoked sub still delivered (line: A revoked matched 0)"
ok "(A) DELETE -> 204; post-revoke send matches 0 (revoked sub is no longer a target)"

# ── 8) (C · FLAG-OFF PARITY) boot with PUSH_ENABLED unset ──────────────────────
step "8a/10 (C · FLAG-OFF PARITY) STOP the ON container; boot with PUSH_ENABLED unset (same DB)"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
SUB_BEFORE="$(psql_val "SELECT count(*) FROM public.push_subscriptions")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e TENANT_CONTROL_PORT=3090 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3090" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "push-OFF tenant-control not ready (line: wait_ready TC_OFF)"
docker logs "${TC_OFF}" 2>&1 | grep -qi "push .* disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "OFF tenant-control did not report push disabled (flag default not OFF?) (line: TC_OFF disabled log)"; }
ok "push-OFF tenant-control up (PUSH_ENABLED unset)"

step "8b/10 (C) EVERY /v1/tenants/{id}/push/* route 404 with the flag OFF"
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_1}/push/subscriptions" \
  "{\"channel\":\"webhook\",\"target_url\":\"http://${SINK}:8080/hook\"}")"
[[ "${C}" == "404" ]] || fail "(C) PARITY: POST /push/subscriptions off expected 404, got ${C} (line: C 404 register)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants/${TENANT_1}/push/subscriptions")"
[[ "${C}" == "404" ]] || fail "(C) PARITY: GET /push/subscriptions off expected 404, got ${C} (line: C 404 list)"
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_1}/push/send" '{"title":"x","body":"y"}')"
[[ "${C}" == "404" ]] || fail "(C) PARITY: POST /push/send off expected 404, got ${C} (line: C 404 send)"
C="$(admin_req DELETE "${PORT_OFF}" "/v1/tenants/${TENANT_1}/push/subscriptions/${SUB_1}")"
[[ "${C}" == "404" ]] || fail "(C) PARITY: DELETE /push/subscriptions/{id} off expected 404, got ${C} (line: C 404 revoke)"
ok "(C) all /v1/tenants/{id}/push/* routes 404 with the flag OFF"

step "8c/10 (C) the base admin surface STILL works on the OFF router (only push is gated)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] \
  || fail "(C) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 200 "${BODY_TMP}") (line: C admin 200)"
ok "(C) base admin GET /v1/tenants => 200 — baseline untouched; only push is flag-gated"

step "8d/10 (C) the OFF router NEVER wrote push_subscriptions (count unchanged)"
SUB_AFTER="$(psql_val "SELECT count(*) FROM public.push_subscriptions")"
[[ "${SUB_BEFORE}" == "${SUB_AFTER}" ]] \
  || fail "(C) PARITY: push_subscriptions changed under the OFF router (before=${SUB_BEFORE} after=${SUB_AFTER}) (line: C no writes)"
ok "(C) push_subscriptions unchanged (${SUB_AFTER}) — never touched with the flag OFF"

# ── 9) summary ─────────────────────────────────────────────────────────────────
step "9/10 summary"
green "[M114] (A) POSITIVE:  register webhook sub -> POST /push/send delivers the notification (title+body) to the sink (matched=1, delivered=1); list shows it; DELETE 204 then send matches 0"
green "[M114] (B) REJECT:    cross-tenant T2 list empty + T2 send matched 0 (sink got nothing, T1 unchanged); SSRF guard refuses 169.254.169.254 + the pg container (400 blocked_target, no row) — LOAD-BEARING"
green "[M114] (C) PARITY:    PUSH_ENABLED off => all /v1/tenants/{id}/push/* 404 while admin GET /v1/tenants 200; push_subscriptions never touched — byte-identical to today"

# ── 10) emit the gate event via the kernel log helper (best-effort) ─────────────
step "10/10 log GATE m114=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-e-push-messaging}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m114=PASS" --outcome pass \
      --msg "Track-E push/messaging (FCM-parity): register a webhook subscription -> POST /push/send fans the notification out to the sink (title+body present, matched=1/delivered=1) -> list 200 -> DELETE 204 (post-revoke send matches 0); LOAD-BEARING cross-tenant: a T2 send matches 0 + the sink receives nothing + T1 unchanged; SSRF guard refuses 169.254.169.254 + the pg container (400 blocked_target, no row stored); PUSH_ENABLED OFF -> all /v1/tenants/{id}/push/* 404 while admin GET /v1/tenants 200, push_subscriptions never touched (byte-parity)" \
      --ref "scripts/verify/m114-push.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M114] ALL GATES GREEN — Track-E push: register/list/send/revoke work end-to-end (delivery to the sink), reject cross-tenant + SSRF (the two security walls), and are byte-parity (routes 404) when OFF"
exit 0
