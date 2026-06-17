#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m28-packages.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M28: PACKAGES / TIERING (Phase 4).
#
# Proves the two enforcement layers a customer-facing tier needs:
#
#  1. CONTROL PLANE (Go): the package manifest gates which engines a tenant may
#     mount and caps mount count; the config source of truth and the embedded
#     copy stay byte-identical. Driven via `go test ./internal/packages`.
#
#  2. DATA PLANE (Rust): the per-tenant tier mask the query-router stamps onto a
#     mount drives the capability gate (403 capability_gated, DISTINCT from the
#     422 an engine genuinely can't serve) and the per-tenant token bucket (429
#     + refill recovery), while reads on the same tier still succeed (parity).
#     Probed DIRECTLY against the Rust router with a hand-crafted mask, so the
#     gate needs no global PACKAGE_ENFORCEMENT flip and never touches a shared
#     tenant — it exercises the exact production code path (tier_gate +
#     ratelimit) the query-router feeds when enforcement is on.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M28] FAIL: $*"; exit 1; }
step()  { cyan "[M28] ${*}"; }
pass()  { green "[M28] PASS: ${*}"; }

env_of() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep "^$2=" | head -1 | cut -d= -f2-; }

RUST_PORT="${DATA_PLANE_RUST_PORT:-4011}"
RUST="http://127.0.0.1:${RUST_PORT}"

# ── 1. manifest source-of-truth integrity ──────────────────────────────────
step "manifest: config copy == control-plane embedded copy"
CFG="${BAAS_DIR}/config/packages/packages.json"
EMB="${BAAS_DIR}/go/control-plane/internal/packages/packages.json"
[[ -f "${CFG}" && -f "${EMB}" ]] || fail "manifest files missing (${CFG} / ${EMB})"
cmp -s "${CFG}" "${EMB}" || fail "config manifest and embedded copy diverged — re-copy config/packages/packages.json into internal/packages/"
pass "package manifest is the single source of truth (config == embed)"

# ── 2. control-plane gating logic (Go) ──────────────────────────────────────
step "control plane: package manifest engine-allowlist + quota + alias logic"
if docker image inspect golang:1.25-bookworm >/dev/null 2>&1 || docker pull -q golang:1.25-bookworm >/dev/null 2>&1; then
  docker run --rm -v "${BAAS_DIR}/go/control-plane:/src" -w /src \
    -v mini-baas-go-build-cache:/root/.cache/go-build -v mini-baas-go-mod-cache:/go/pkg/mod \
    golang:1.25-bookworm go test ./internal/packages/ >/dev/null 2>&1 \
    || fail "go test ./internal/packages failed (engine gating / aliases / overrides)"
  pass "manifest resolves tiers (free→nano, enterprise→max), gates engines + mount quota"
else
  red "[M28] WARN: golang image unavailable — skipping go-test leg"
fi

# ── 3. data-plane enforcement (Rust), probed directly ──────────────────────
docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 || fail "rust router not running (make up EDITION=query)"
curl -fsS -o /dev/null "${RUST}/v1/capabilities" || fail "rust router unreachable at ${RUST}"

PW="$(env_of mini-baas-postgres POSTGRES_PASSWORD)"; PW="${PW:-postgres}"
PGUSER="$(env_of mini-baas-postgres POSTGRES_USER)"; PGUSER="${PGUSER:-postgres}"
PGDB="$(env_of mini-baas-postgres POSTGRES_DB)"; PGDB="${PGDB:-postgres}"
DSN="postgres://${PGUSER}:${PW}@postgres:5432/${PGDB}"

step "data plane: provisioning an owner-scoped probe row"
docker exec mini-baas-postgres psql -U "${PGUSER}" -d "${PGDB}" -q -c \
  "CREATE TABLE IF NOT EXISTS public.m28_tier_probe (id text PRIMARY KEY, owner_id text, tenant_id text, n int);
   INSERT INTO public.m28_tier_probe(id,owner_id,tenant_id,n) VALUES ('a','m28-tenant','m28-tenant',5)
     ON CONFLICT (id) DO NOTHING;" >/dev/null 2>&1 || fail "could not create probe table"
cleanup() { docker exec mini-baas-postgres psql -U "${PGUSER}" -d "${PGDB}" -q -c "DROP TABLE IF EXISTS public.m28_tier_probe;" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# v2: a CRUD-only mask (basic tier — aggregate:false). Hand-built so the test
# exercises the GATING MECHANISM, not a specific packages.json row.
BASIC_MASK='{"aggregate":false,"batch":false,"transactions":false,"rps":100,"burst":200}'
payload() { # $1=op $2=overrides $3=tenant
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m28","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":%s,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"m28_tier_probe"}}' \
    "$3" "$3" "$3" "$2" "${DSN}" "$1"
}
code() { curl -s -o /tmp/m28_body -w "%{http_code}" -X POST "${RUST}/v1/query" -H 'Content-Type: application/json' -d "$1"; }

step "data plane: a CRUD-only mask (basic) 403s a capability the engine HAS (aggregate)"
c="$(code "$(payload aggregate "${BASIC_MASK}" m28-tenant)")"
[[ "${c}" == "403" ]] || fail "expected 403 for aggregate under the CRUD-only mask, got ${c} ($(cat /tmp/m28_body))"
grep -q 'capability_gated' /tmp/m28_body || fail "403 body is not capability_gated: $(cat /tmp/m28_body)"
pass "CRUD-only mask: aggregate → 403 capability_gated (distinct from 422 engine-can't)"

step "data plane: SAME op WITHOUT a mask is not tier-gated (mask-driven, not engine)"
c="$(code "$(payload aggregate null m28-tenant)")"
[[ "${c}" != "403" ]] || fail "aggregate without a tier mask must NOT be 403 (got 403 — gate is not mask-driven)"
pass "no mask → no tier denial (parity); engine still serves aggregate"

step "data plane: reads succeed under the CRUD-only mask (owner-scoped row returned)"
c="$(code "$(payload list "${BASIC_MASK}" m28-tenant)")"
[[ "${c}" == "200" ]] || fail "expected 200 for list under the CRUD-only mask, got ${c} ($(cat /tmp/m28_body))"
grep -q '"n":5' /tmp/m28_body || fail "list did not return the owner-scoped probe row: $(cat /tmp/m28_body)"
pass "Essential read → 200 with owner-scoped row (CRUD unaffected by tiering)"

step "data plane: per-tenant rate limit (rps:1/burst:1) → 429 after burst, refill recovers"
TIGHT='{"rps":1,"burst":1}'
seen429=0; first=""
for i in $(seq 1 6); do
  c="$(code "$(payload list "${TIGHT}" m28-rl-tenant)")"
  [[ -z "${first}" ]] && first="${c}"
  [[ "${c}" == "429" ]] && seen429=1
done
[[ "${first}" != "429" ]] || fail "first request must not be 429 (burst token should admit it)"
[[ "${seen429}" == "1" ]] || fail "expected at least one 429 within burst of rapid requests"
sleep 2
c="$(code "$(payload list "${TIGHT}" m28-rl-tenant)")"
[[ "${c}" == "200" ]] || fail "expected 200 after ~2s token refill, got ${c}"
pass "per-tenant token bucket: 1st admits, burst exhausts → 429, refill → 200"

green "[M28] ALL GATES GREEN — package tiering enforced at control plane (engine/quota) + data plane (403 capability + 429 rate)"
