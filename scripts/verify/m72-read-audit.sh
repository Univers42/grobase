#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m72-read-audit.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M72 — G-ReadAudit (A6) live gate. Proves DATA_PLANE_AUDIT_READS does EXACTLY
# what it advertises, and that the LIVE BASELINE is byte-identical when OFF.
#
# The audited hook (data-plane-server/src/routes.rs run_query):
#     if !is_mutation && state.config.audit_reads {
#         tracing::info!(target: "audit", event = "read", tenant=…, engine=…,
#                        op=…, resource=…, returned_rows = result.rows.len());
#     }
# OFF by default (config.rs audit_reads ← DATA_PLANE_AUDIT_READS, default false)
# → the read path emits NOTHING extra and stays off the hot path.
#
# ISOLATED by design (mirrors m59's isolated-ephemeral style): a scratch
# data-plane-router built FROM THE CURRENT (drafted, uncommitted) source + a
# throwaway postgres, both on a PRIVATE network, every container/image/network
# name suffixed with $$, an EXIT-trap that removes EVERYTHING. It NEVER touches a
# mini-baas-* container, network, image, or volume — safe while the live stack is
# up. The compose project is implicit (plain `docker run`, no project name that
# could collide with mini-baas-*).
#
# The probe hits the router's internal `/v1/query` trusted-envelope path inside
# the docker network (no host ports for the data path — only loopback-bound
# 127.0.0.1 publish for the test's own curl), with an inline DSN + hand-built
# tier mask — exactly as m28 — so no Kong / tenant-control / auth machinery is
# needed and the test exercises the EXACT production audit code.
#
#   (A) POSITIVE: a fresh router with DATA_PLANE_AUDIT_READS=true serves ONE real
#       list → its container logs MUST contain EXACTLY ONE event="read" line, and
#       that line's returned_rows MUST equal the ACTUAL row count served.
#   (B) PARITY:   an IDENTICAL fresh router with the flag OFF serves the SAME read
#       → its logs MUST contain ZERO event="read" lines (live baseline untouched).
#
# Fails (exit≠0) if A is absent / count≠1 / returned_rows mismatches, or if B
# emits ANY event="read" line. Each fail names the exact assertion that tripped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DPR_DIR="${BAAS_DIR}/src/data-plane-router"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M72] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M72] FAIL — $*"; exit 1; }
# has/nhas: assert a string is / is NOT present in a captured log blob (arg, not
# a file — the router logs live in `docker logs`, not on disk).
has()  { grep -q "$1" <<<"$3" || fail "$2"; }
nhas() { grep -q "$1" <<<"$3" && fail "$2"; return 0; }

PG_IMAGE="${M72_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m72-dpr-$$:scratch"
NET="m72net-$$"
PG="m72-pg-$$"
DPR_ON="m72-dpr-on-$$"     # (A) POSITIVE arm router (flag ON)
DPR_OFF="m72-dpr-off-$$"   # (B) PARITY   arm router (flag OFF/unset)
PORT_ON="${M72_PORT_ON:-18972}"
PORT_OFF="${M72_PORT_OFF:-18973}"
PGPW="postgres"
TABLE="m72_audit_probe"
TENANT="m72-tenant-$$"
ROWS=5                                       # exact seeded row count → returned_rows
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# Build the /v1/query envelope: identity + mount(inline DSN + optional mask) +
# operation. Identical contract to m28 — the internal trusted-envelope path. The
# `service_role`/`admin` identity + bare (no-RLS) probe table means a `list`
# returns ALL seeded rows deterministically, so returned_rows is predictable.
payload() { # $1=op  $2=mask-json(or null)  -> stdout
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m72","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":%s,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"%s"}}' \
    "${TENANT}" "${TENANT}" "${TENANT}" "$2" "${DSN_INNET}" "$1" "${TABLE}"
}

# POST a query to a router on 127.0.0.1:$port; echo the HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

# tracing's text formatter styles field names with ANSI escapes, so a raw
# `docker logs` interleaves them inside `event="read"` and a literal grep misses.
# Strip CSI sequences before asserting on the structured key=value fields.
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

# ── 0) build the scratch DPR image FROM THE CURRENT (drafted) source ──────────
step "0/6 build scratch data-plane-router from CURRENT source (contains THE A6 build)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch DPR image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + throwaway postgres with EXACTLY ${ROWS} seeded rows ─
step "1/6 boot isolated postgres (${PG}) on private net (${NET}); seed ${ROWS} rows"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint inits then RESTARTS postgres once ("ready" twice). A query
# can land in the shutdown window between the two — wait for the SECOND "ready",
# then retry the seed so it can never race the post-init restart.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state (line: PG ready loop)"
  sleep 0.5
done
# Bare table (NO RLS policy enabled) so the RLS GUC the router sets has no effect
# and `list` returns ALL ${ROWS} rows → returned_rows is exact & deterministic.
seed() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${TABLE} (
  id text PRIMARY KEY, owner_id text, tenant_id text, label text);
INSERT INTO public.${TABLE}(id, owner_id, tenant_id, label) VALUES
  ('r1','${TENANT}','${TENANT}','one'),
  ('r2','${TENANT}','${TENANT}','two'),
  ('r3','${TENANT}','${TENANT}','three'),
  ('r4','${TENANT}','${TENANT}','four'),
  ('r5','${TENANT}','${TENANT}','five')
ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
SEEDED="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.${TABLE}" 2>/dev/null | tr -d '[:space:]')"
[[ "${SEEDED}" == "${ROWS}" ]] || fail "expected ${ROWS} seeded rows, found '${SEEDED}' (line: SEEDED count)"
ok "postgres up; ${TABLE} seeded with EXACTLY ${ROWS} rows"

# ── 2) (A) POSITIVE arm: a router with DATA_PLANE_AUDIT_READS=true ────────────
step "2/6 boot scratch router with DATA_PLANE_AUDIT_READS=true (A · POSITIVE)"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_AUDIT_READS=true \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "POSITIVE router not ready (line: wait_ready DPR_ON)"
ok "POSITIVE router up (audit_reads ON) on 127.0.0.1:${PORT_ON}"

step "2b/6 fire EXACTLY ONE real read (list) through the POSITIVE router"
code="$(post_q "${PORT_ON}" "$(payload list null)")"
[[ "${code}" == "200" ]] || fail "POSITIVE list expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: POSITIVE post_q status)"
# Confirm the read genuinely returned the seeded rows (so returned_rows is real).
SERVED="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED}" == "${ROWS}" ]] || fail "POSITIVE list returned ${SERVED} rows, expected ${ROWS} — $(head -c 300 "${BODY_TMP}") (line: SERVED count)"
ok "ONE read served 200 with all ${ROWS} rows"

# ── 3) (A) ASSERT: EXACTLY ONE audit line, returned_rows == actual count ──────
step "3/6 ASSERT (A): exactly ONE event=\"read\" line, returned_rows=${ROWS}"
sleep 0.5
LOGS_ON="$(logs_clean "${DPR_ON}")"
N_READ_ON="$(grep -c 'event="read"' <<<"${LOGS_ON}" || true)"
[[ "${N_READ_ON}" == "1" ]] \
  || fail "expected EXACTLY 1 event=\"read\" line, found ${N_READ_ON} — $(grep 'event="read"' <<<"${LOGS_ON}" | tail -3) (line: N_READ_ON != 1)"
AUDIT_LINE="$(grep 'event="read"' <<<"${LOGS_ON}")"
has "resource=${TABLE}"  "audit line does not name resource=${TABLE} — line: ${AUDIT_LINE} (line: resource assertion)"  "${AUDIT_LINE}"
has "returned_rows=${ROWS}" "audit returned_rows != actual served row count (${ROWS}) — line: ${AUDIT_LINE} (line: returned_rows assertion)" "${AUDIT_LINE}"
ok "(A) exactly ONE event=\"read\" with resource=${TABLE} returned_rows=${ROWS} — matches the served count"

# ── 4) (B) PARITY arm: an IDENTICAL router with the flag OFF (default) ─────────
step "4/6 boot scratch router with DATA_PLANE_AUDIT_READS unset (B · PARITY/default)"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (audit_reads default OFF) on 127.0.0.1:${PORT_OFF}"

step "4b/6 fire the SAME read through the PARITY router"
code="$(post_q "${PORT_OFF}" "$(payload list null)")"
[[ "${code}" == "200" ]] || fail "PARITY list expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: PARITY post_q status)"
SERVED_OFF="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED_OFF}" == "${ROWS}" ]] || fail "PARITY list returned ${SERVED_OFF} rows, expected ${ROWS} (read must still work) — $(head -c 300 "${BODY_TMP}") (line: SERVED_OFF count)"
ok "the same read still serves 200 with all ${ROWS} rows (no behavior change)"

# ── 5) (B) ASSERT: ZERO read-audit lines with the flag OFF (byte-parity) ──────
step "5/6 ASSERT (B): ZERO event=\"read\" lines (live baseline untouched)"
sleep 0.5
LOGS_OFF="$(logs_clean "${DPR_OFF}")"
N_READ_OFF="$(grep -c 'event="read"' <<<"${LOGS_OFF}" || true)"
[[ "${N_READ_OFF}" == "0" ]] \
  || fail "PARITY router emitted ${N_READ_OFF} event=\"read\" line(s) — the default is NOT byte-parity! $(grep 'event="read"' <<<"${LOGS_OFF}" | tail -3) (line: N_READ_OFF != 0)"
nhas 'event="read"' "PARITY router leaked a read-audit line with the flag OFF (line: nhas event=read)" "${LOGS_OFF}"
ok "(B) ZERO event=\"read\" lines with the flag OFF — live baseline is byte-parity"

# ── 6) cross-check: the two arms differ ONLY by the audit line ────────────────
step "6/6 cross-check: ON emitted 1, OFF emitted 0 — the flag is the only difference"
[[ "${N_READ_ON}" == "1" && "${N_READ_OFF}" == "0" ]] \
  || fail "arm counts inconsistent (ON=${N_READ_ON}, OFF=${N_READ_OFF}) (line: cross-check)"
ok "DATA_PLANE_AUDIT_READS is the sole gate on the read-audit emission"

green "[M72] ALL GATES GREEN — DATA_PLANE_AUDIT_READS=on emits EXACTLY ONE event=\"read\" audit per served read with returned_rows=${ROWS} (the real count); OFF (default) emits ZERO = byte-parity live baseline"
