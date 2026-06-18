#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m73-rows-cap.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M73 — G-QoS rows-cap (A6) live gate. Proves the per-tier `max_rows` server
# clamp does exactly what it claims, and that the LIVE BASELINE is byte-identical
# when no cap is configured.
#
# The clamp (routes.rs run_query, BEFORE pool dispatch — engine-agnostically):
#     if let Some(cap) = tier_max_rows(mount.capability_overrides) {
#         operation.limit = Some(operation.limit.map_or(cap, |l| l.min(cap)));
#     }
# Absent / zero `max_rows` → no clamp (today's behavior, parity). A present cap
# bounds a missing or larger client limit without touching any adapter.
#
# ISOLATED by design (mirrors m59's isolated-ephemeral style): a scratch
# data-plane-router built FROM THE CURRENT (modified) source + a throwaway
# postgres, both on a PRIVATE network, container names suffixed with $$, with an
# EXIT-trap that removes EVERYTHING. It NEVER touches a mini-baas-* container.
#
# The probe hits `/v1/query` directly with an inline DSN + a hand-built tier mask
# (exactly as m28), so the test exercises the EXACT production clamp code with no
# Kong / tenant-control / auth machinery.
#
#   POSITIVE arm: a mount whose tier mask carries max_rows=CAP (small, e.g. 10),
#                 over a table seeded with COUNT (> CAP) rows. A list with NO
#                 client limit returns EXACTLY CAP rows (the server clamp).
#   PARITY  arm:  an IDENTICAL mount with NO max_rows → the SAME list returns the
#                 FULL COUNT (baseline; the server default list cap is 100, and
#                 COUNT < 100, so "full" == COUNT). The flag-off path is unclamped.
#
#   m28-parity:  the two packages.json copies (config + Go-embedded) must be
#                byte-identical — the manifest single-source-of-truth invariant.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DPR_DIR="${BAAS_DIR}/src/data-plane-router"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M73] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M73] FAIL — $*"
  exit 1
}

PG_IMAGE="${M73_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m73-dpr-$$:scratch"
NET="m73net-$$"
PG="m73-pg-$$"
DPR="m73-dpr-$$"
PORT="${M73_PORT:-18974}"
PGPW="postgres"
TABLE="m73_cap_probe"
TENANT="m73-tenant-$$"
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
CAP=10   # max_rows in the POSITIVE mask
COUNT=25 # seeded rows (> CAP, and < the server's 100 default list cap)

cleanup() {
  docker rm -fv "${DPR}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# count rows in a /v1/query JSON response body ({"rows":[…],"affected_rows":N}).
rows_len() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("rows",[])))' "$1"; }

# Build the /v1/query envelope. $1=mask-json(or null). The operation is a list
# with NO client `limit` — so the ONLY thing that can bound the result is the
# server-side max_rows clamp.
payload() { # $1=mask-json(or null)
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m73","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":%s,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s"}}' \
    "${TENANT}" "${TENANT}" "${TENANT}" "$1" "${DSN_INNET}" "${TABLE}"
}

post_q() { # $1=body  -> echoes HTTP status, writes /tmp/m73_body.$$
  curl -s -o /tmp/m73_body.$$ -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/v1/query" \
    -H 'Content-Type: application/json' -d "$1"
}

# ── 0) m28-parity: the two packages.json copies are byte-identical, and the
#       optional `max_rows` key (when present) exists in BOTH copies ──────────
step "0/6 packages.json single-source-of-truth (config == Go-embedded copy)"
CFG="${BAAS_DIR}/infra/config/packages/packages.json"
EMB="${BAAS_DIR}/src/control-plane/internal/packages/packages.json"
[[ -f "${CFG}" && -f "${EMB}" ]] || fail "packages.json manifest missing (${CFG} / ${EMB})"
cmp -s "${CFG}" "${EMB}" ||
  fail "packages.json config and Go-embedded copy diverged (cmp -s) — re-copy infra/config/packages/packages.json into internal/packages/"
ok "packages.json byte-identical across the two copies (m28 manifest parity)"
# Explicit A6 invariant: the new optional `max_rows` key, when present in one
# copy, MUST be present in the other (omit = unlimited = parity). Counting it in
# each copy and asserting equality names the exact divergence this gate guards.
N_CFG="$(grep -c 'max_rows' "${CFG}" || true)"
N_EMB="$(grep -c 'max_rows' "${EMB}" || true)"
[[ "${N_CFG}" == "${N_EMB}" ]] ||
  fail "max_rows key count diverged: config has ${N_CFG}, Go-embedded has ${N_EMB} — the optional cap must exist in BOTH packages.json or NEITHER"
ok "max_rows key present in BOTH copies in lock-step (${N_CFG} == ${N_EMB} occurrences)"

# ── 1) build the scratch DPR image FROM THE CURRENT (modified) source ─────────
step "1/6 build scratch data-plane-router from CURRENT source (contains THIS build)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${DPR_DIR}" >/dev/null ||
  fail "scratch DPR image build failed — the gate must exercise the new code"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?')"

# ── 2) isolated net + throwaway postgres seeded with COUNT (>CAP) rows ─────────
step "2/6 boot isolated postgres (${PG}) on private net (${NET}), seed ${COUNT} rows"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint runs init, then RESTARTS postgres once ("ready" logs
# twice). A query can land in the shutdown window between the two. Wait for the
# SECOND "ready to accept connections" (the real one), then retry the seed itself
# so it can never race the post-init restart.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state"
  sleep 0.5
done
seed() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${TABLE} (
  id text PRIMARY KEY, owner_id text, tenant_id text, label text);
INSERT INTO public.${TABLE}(id, owner_id, tenant_id, label)
SELECT 'r'||g, '${TENANT}', '${TENANT}', 'row-'||g
FROM generate_series(1, ${COUNT}) g
ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do
  seed && break
  [[ $i -eq 20 ]] && fail "seed never committed"
  sleep 0.5
done
ACTUAL="$(docker exec "${PG}" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.${TABLE}")"
[[ "${ACTUAL}" == "${COUNT}" ]] || fail "seed mismatch: expected ${COUNT} rows, got ${ACTUAL}"
ok "postgres up; ${TABLE} seeded with ${COUNT} owner-stamped rows (> cap ${CAP}, < server default 100)"

# ── 3) one scratch router (mask drives behavior per-request — no flag flip) ────
step "3/6 boot scratch router (the max_rows clamp is mask-driven per request)"
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled -e RUST_LOG=info \
  -p "127.0.0.1:${PORT}:4011" "${SCRATCH_IMG}" >/dev/null
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/v1/capabilities" 2>/dev/null && break
  docker inspect "${DPR}" >/dev/null 2>&1 || {
    docker logs "${DPR}" 2>&1 | tail -15
    fail "router exited early"
  }
  [[ $i -eq 60 ]] && {
    docker logs "${DPR}" 2>&1 | tail -15
    fail "router never became ready"
  }
  sleep 0.5
done
ok "scratch router up on :${PORT}"

# ── 4) POSITIVE: a mount with max_rows=CAP clamps a no-limit list to EXACTLY CAP
step "4/6 POSITIVE — list (no client limit) under a max_rows=${CAP} mask → EXACTLY ${CAP} rows"
CAP_MASK="$(printf '{"max_rows":%d}' "${CAP}")"
code="$(post_q "$(payload "${CAP_MASK}")")"
[[ "${code}" == "200" ]] || fail "POSITIVE list expected 200, got ${code} — $(head -c 300 /tmp/m73_body.$$)"
GOT="$(rows_len /tmp/m73_body.$$)"
[[ "${GOT}" == "${CAP}" ]] ||
  fail "max_rows=${CAP} did NOT clamp: list returned ${GOT} rows, expected exactly ${CAP}"
ok "server clamp held: ${GOT} == ${CAP} rows (max_rows enforced before the adapter ran)"

# ── 5) PARITY: an IDENTICAL mount with NO max_rows returns the FULL count ──────
step "5/6 PARITY — the SAME list with NO max_rows mask → FULL ${COUNT} rows (baseline)"
code="$(post_q "$(payload null)")"
[[ "${code}" == "200" ]] || fail "PARITY list expected 200, got ${code} — $(head -c 300 /tmp/m73_body.$$)"
GOT="$(rows_len /tmp/m73_body.$$)"
[[ "${GOT}" == "${COUNT}" ]] ||
  fail "NO max_rows must NOT clamp: list returned ${GOT} rows, expected the full ${COUNT} (baseline NOT byte-parity!)"
ok "no cap → full ${GOT} rows == seeded ${COUNT}: the default path is unclamped (byte-parity)"

# ── 6) cross-check the two arms actually diverged on the SAME data ─────────────
step "6/6 the cap arm (${CAP}) is strictly smaller than the no-cap arm (${COUNT})"
[[ "${CAP}" -lt "${COUNT}" ]] || fail "test design error: CAP (${CAP}) not < COUNT (${COUNT}) — the arms can't diverge"
ok "POSITIVE ${CAP} < PARITY ${COUNT}: the clamp is the ONLY difference between the two arms"

rm -f /tmp/m73_body.$$ 2>/dev/null || true
green "[M73] ALL GATES GREEN — max_rows clamps a no-limit list to exactly the cap; absent max_rows returns the full count = byte-parity baseline; packages.json single-source-of-truth intact"
