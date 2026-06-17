#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m122-read-replica-routing.sh                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M122 — S8 read-replica routing MECHANISM. This gate proves the ROUTING
# DECISION only: a pure READ (op=list) on a mount that carries a read-replica
# DSN is served from the REPLICA's OWN pool when DATA_PLANE_READ_REPLICA is ON,
# while WRITES and (flag-OFF) everything stay on the PRIMARY. We are NOT proving
# real streaming replication, replication-lag SLOs, or latency-under-lag — those
# are infra-blocked (they need a real replica/WAL stream) and are EXPLICITLY OUT
# OF SCOPE. To make the routing decision OBSERVABLE we stand up TWO INDEPENDENT
# scratch postgres DBs (a "primary" and a "replica") whose probe table holds a
# DIFFERING sentinel row (served_by='primary' vs served_by='replica'), so the
# DB that actually served a read is revealed by which sentinel comes back. (A
# real replica would carry the SAME bytes as the primary — here the deliberate
# divergence is the routing probe; we say so loudly in the output.)
#
# The data-plane-router is driven DIRECTLY at /v1/query (like m101/m121) — the
# envelope carries inline_dsn=PRIMARY and replica_inline_dsn=REPLICA, so this
# gate touches NO Go control plane and NO adapter-registry: it exercises ONLY
# the Rust routing mechanism added in S8.
#
# Arms (data-plane-router booted with DATA_PLANE_ROUTER_PRODUCT_MODE=enabled):
#   ENFORCE / ROUTED  (flag ON, DATA_PLANE_READ_REPLICA=1):
#     - READ  (op=list)   -> 200 AND body sentinel == 'replica'  (read hit the
#                            REPLICA pool).
#     - WRITE (op=insert) -> 2xx; the new row is then found on the PRIMARY (psql)
#                            and ABSENT on the replica (writes stay primary).
#     - READ again        -> 200 AND sentinel still == 'replica' (reads keep
#                            hitting the replica; the write did not move them).
#   PARITY  (flag OFF):
#     - READ  (op=list)   -> 200 AND body sentinel == 'primary' (the replica DSN
#                            is IGNORED = today's behaviour, byte-parity).
#
# NON-VACUITY (fails on pre-S8 HEAD): `replica_inline_dsn` is an UNKNOWN field on
# HEAD (the struct has no such field), and there is no routing branch at all — so
# the flag-ON assertion "the read sees the 'replica' sentinel" CANNOT pass on
# HEAD (the read would be served by the primary inline_dsn and return 'primary',
# or the envelope would be rejected). The gate therefore fails on HEAD and only
# the S8 code makes it green.
#
# ISOLATED by design (mirrors m121): two scratch postgres + a data-plane-router
# built FROM CURRENT source, on a PRIVATE network, every name suffixed $$, an
# EXIT-trap force-removing EVERYTHING (net + containers + images + tmp). It NEVER
# touches a mini-baas-*/track-binocle-* container/network/image/volume and NEVER
# edits the live docker-compose.yml. No host ports for the data path beyond the
# loopback-bound publish for the one probe (the router).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                 # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                      # apps/baas
DPR_DIR="${INFRA_DIR}/src/data-plane-router"
MIGRATIONS="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M122] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M122] FAIL — $*"; exit 1; }

PG_IMAGE="${M122_PG_IMAGE:-postgres:16-alpine}"
DPR_IMG="m122-dpr-$$:scratch"
NET="m122net-$$"
PRIMARY="m122-pg-primary-$$"
REPLICA="m122-pg-replica-$$"
DPR="m122-dpr-$$"                  # data-plane-router under test
PORT_DPR="${M122_PORT_DPR:-18993}"
PGPW="postgres"
PROBE_TABLE="m122_probe"

# A single REAL tenant identity (UUID used as both id + slug elsewhere; here it is
# only an opaque envelope field — no control plane is involved).
UUID_T="cccc1111-2222-3333-4444-555566667777"

# In-network DSNs to each scratch DB (distinct hosts → distinct pools by DSN).
DB_PRIMARY="postgres://postgres:${PGPW}@${PRIMARY}:5432/postgres"
DB_REPLICA="postgres://postgres:${PGPW}@${REPLICA}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR}" "${REPLICA}" "${PRIMARY}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${DPR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# psql against a named container.
psql_in()  { docker exec -i "$1" psql -U postgres -d postgres -v ON_ERROR_STOP=1; }
psql_val() { docker exec -i "$1" psql -U postgres -d postgres -tAc "$2" 2>/dev/null | tr -d '[:space:]'; }

# A list envelope for the probe table on the PRIMARY mount that ALSO carries a
# read-replica DSN. NO server-side fallback map — the router uses inline_dsn for
# the primary and replica_inline_dsn for the routed read.
payload_list() { # (no args)
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m122-mount","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","replica_inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "${UUID_T}" "${UUID_T}" "${UUID_T}" "${DB_PRIMARY}" "${DB_REPLICA}" "${PROBE_TABLE}"
}

# An insert envelope (a WRITE) — must land on the PRIMARY regardless of the flag.
payload_insert() { # $1 = new row id
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m122-mount","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","replica_inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"insert","resource":"%s","data":{"id":"%s","served_by":"write-marker"}}}' \
    "${UUID_T}" "${UUID_T}" "${UUID_T}" "${DB_PRIMARY}" "${DB_REPLICA}" "${PROBE_TABLE}" "$1"
}

post_q() { # $1=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' --max-time 8 \
    -X POST "http://127.0.0.1:${PORT_DPR}/v1/query" \
    -H 'Content-Type: application/json' -d "$1"
}

wait_dpr() {
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PORT_DPR}/v1/capabilities" 2>/dev/null && return 0
    docker inspect -f '{{.State.Running}}' "${DPR}" 2>/dev/null | grep -q true || {
      red "data-plane-router exited:"; docker logs "${DPR}" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "data-plane-router never became ready:"; docker logs "${DPR}" 2>&1 | tail -20; return 1
}

# Apply a postgresql migration that may carry a 42-school '#'-banner header. '#'
# is NOT a psql comment (only '--' is), so strip leading '#' lines on apply under
# ON_ERROR_STOP=1 (learned in m121). Unused here (we create the probe table bare,
# no adapterregistry) but kept ready per the spec's banner-strip discipline.
apply_mig() { # $1=container  $2=migration-file
  grep -v '^#' "${MIGRATIONS}/$2" | docker exec -i "$1" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1
}

# ── 0) build scratch data-plane-router FROM CURRENT source (the S8 code) ───────
step "0/7 build scratch data-plane-router from CURRENT source (the S8 routing code)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed (line: docker build DPR)"
ok "scratch image built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + TWO independent postgres (primary + replica) ────────────
step "1/7 boot isolated net (${NET}): postgres PRIMARY + postgres REPLICA (two independent DBs)"
docker network create "${NET}" >/dev/null
docker run -d --name "${PRIMARY}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
docker run -d --name "${REPLICA}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for c in "${PRIMARY}" "${REPLICA}"; do
  for i in $(seq 1 80); do
    [[ "$(docker logs "${c}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
    [[ $i -eq 80 ]] && fail "scratch postgres ${c} never reached steady state (line: PG ready loop)"
    sleep 0.5
  done
done
ok "both scratch postgres up (NOTE: two INDEPENDENT DBs — proving the routing decision, not real replication)"

# ── 2) seed the SAME probe schema in BOTH, with a DIFFERING sentinel ──────────
# Same id/schema in both DBs so a list returns one sentinel row; the served_by
# value reveals WHICH database served the read.
step "2/7 seed probe table in BOTH DBs — primary row served_by='primary', replica row served_by='replica'"
seed() { # $1=container  $2=sentinel
  # The probe table carries an `owner_id` column because the shared_rls write
  # path injects `owner_id` from the verified identity on INSERT (postgres
  # run_insert). It is nullable + there is NO RLS policy on this bare table, so
  # the read path (run_list, which relies on RLS, not a WHERE owner filter)
  # returns the sentinel regardless of owner — exactly like m121's bare probe.
  psql_in "$1" >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, served_by text, owner_id text);
INSERT INTO public.${PROBE_TABLE}(id, served_by) VALUES ('sentinel','$2')
  ON CONFLICT (id) DO UPDATE SET served_by = EXCLUDED.served_by;
SQL
}
for i in $(seq 1 20); do seed "${PRIMARY}" "primary" && break; [[ $i -eq 20 ]] && fail "primary seed never committed (line: primary seed loop)"; sleep 0.5; done
for i in $(seq 1 20); do seed "${REPLICA}" "replica" && break; [[ $i -eq 20 ]] && fail "replica seed never committed (line: replica seed loop)"; sleep 0.5; done
[[ "$(psql_val "${PRIMARY}" "SELECT served_by FROM public.${PROBE_TABLE} WHERE id='sentinel'")" == "primary" ]] \
  || fail "primary sentinel not seeded (line: verify primary sentinel)"
[[ "$(psql_val "${REPLICA}" "SELECT served_by FROM public.${PROBE_TABLE} WHERE id='sentinel'")" == "replica" ]] \
  || fail "replica sentinel not seeded (line: verify replica sentinel)"
ok "probe table seeded in both DBs with differing sentinels (primary≠replica)"

# ── 3) ENFORCE ARM: data-plane-router WITH DATA_PLANE_READ_REPLICA=1 ──────────
step "3/7 boot data-plane-router WITH DATA_PLANE_READ_REPLICA=1 (routing ON) on 127.0.0.1:${PORT_DPR}"
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_READ_REPLICA=1 \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DPR}:4011" "${DPR_IMG}" >/dev/null
wait_dpr || fail "data-plane-router (flag ON) not ready (line: wait_dpr ON)"
ok "data-plane-router up with DATA_PLANE_READ_REPLICA=1"

# ── 4) ENFORCE: READ must be served by the REPLICA pool ──────────────────────
step "4/7 (ENFORCE) READ (op=list) with flag ON → MUST be 200 + sentinel=='replica'"
R_CODE=
for i in $(seq 1 20); do
  R_CODE="$(post_q "$(payload_list)")"
  [[ "${R_CODE}" == "200" ]] && break
  sleep 0.5
done
[[ "${R_CODE}" == "200" ]] \
  || fail "(ENFORCE) read expected 200, got ${R_CODE} — $(head -c 400 "${BODY_TMP}") (line: ENFORCE read 200)"
grep -q '"served_by":"replica"\|"served_by": "replica"' "${BODY_TMP}" \
  || fail "(ENFORCE) read did NOT hit the replica — body had no served_by=replica: $(head -c 400 "${BODY_TMP}") (line: ENFORCE read replica)"
grep -q '"served_by":"primary"\|"served_by": "primary"' "${BODY_TMP}" \
  && fail "(ENFORCE) read returned the PRIMARY sentinel — routing did not select the replica: $(head -c 400 "${BODY_TMP}") (line: ENFORCE read not-primary)"
ok "(ENFORCE) flag-ON read served from the REPLICA pool (sentinel=replica)"

# ── 5) ENFORCE: WRITE must land on the PRIMARY (not the replica) ─────────────
step "5/7 (ENFORCE) WRITE (op=insert) with flag ON → new row on PRIMARY, ABSENT on replica"
WROW="w-$$-1"
W_CODE="$(post_q "$(payload_insert "${WROW}")")"
[[ "${W_CODE}" == "200" || "${W_CODE}" == "201" ]] \
  || fail "(ENFORCE) write expected 2xx, got ${W_CODE} — $(head -c 400 "${BODY_TMP}") (line: ENFORCE write 2xx)"
[[ "$(psql_val "${PRIMARY}" "SELECT count(*) FROM public.${PROBE_TABLE} WHERE id='${WROW}'")" == "1" ]] \
  || fail "(ENFORCE) the written row is NOT on the PRIMARY — writes must stay primary (line: ENFORCE write on primary)"
[[ "$(psql_val "${REPLICA}" "SELECT count(*) FROM public.${PROBE_TABLE} WHERE id='${WROW}'")" == "0" ]] \
  || fail "(ENFORCE) the written row LEAKED onto the replica — writes must NOT touch the replica (line: ENFORCE write not on replica)"
ok "(ENFORCE) flag-ON write landed on the PRIMARY and is absent on the replica"

# ── 5b) ENFORCE: a READ after the write still hits the REPLICA ───────────────
step "5b/7 (ENFORCE) READ again after the write → still 200 + sentinel=='replica'"
R2_CODE="$(post_q "$(payload_list)")"
[[ "${R2_CODE}" == "200" ]] \
  || fail "(ENFORCE) second read expected 200, got ${R2_CODE} — $(head -c 400 "${BODY_TMP}") (line: ENFORCE read2 200)"
grep -q '"served_by":"replica"\|"served_by": "replica"' "${BODY_TMP}" \
  || fail "(ENFORCE) second read stopped hitting the replica after a write: $(head -c 400 "${BODY_TMP}") (line: ENFORCE read2 replica)"
ok "(ENFORCE) reads keep hitting the replica after a write (write did not move reads)"

# ── 6) PARITY ARM: restart the router WITHOUT the flag → reads see the PRIMARY ─
step "6/7 (PARITY) restart data-plane-router WITHOUT DATA_PLANE_READ_REPLICA (flag OFF)"
docker rm -fv "${DPR}" >/dev/null 2>&1 || true
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DPR}:4011" "${DPR_IMG}" >/dev/null
wait_dpr || fail "data-plane-router (flag OFF) not ready (line: wait_dpr OFF)"
step "6b/7 (PARITY) READ (op=list) with flag OFF → MUST be 200 + sentinel=='primary' (replica DSN ignored)"
P_CODE=
for i in $(seq 1 20); do
  P_CODE="$(post_q "$(payload_list)")"
  [[ "${P_CODE}" == "200" ]] && break
  sleep 0.5
done
[[ "${P_CODE}" == "200" ]] \
  || fail "(PARITY) read expected 200, got ${P_CODE} — $(head -c 400 "${BODY_TMP}") (line: PARITY read 200)"
grep -q '"served_by":"primary"\|"served_by": "primary"' "${BODY_TMP}" \
  || fail "(PARITY) flag-OFF read did NOT see the primary — the replica DSN must be IGNORED: $(head -c 400 "${BODY_TMP}") (line: PARITY read primary)"
grep -q '"served_by":"replica"\|"served_by": "replica"' "${BODY_TMP}" \
  && fail "(PARITY) flag-OFF read hit the replica — byte-parity broken: $(head -c 400 "${BODY_TMP}") (line: PARITY read not-replica)"
ok "(PARITY) flag-OFF read served from the PRIMARY (replica DSN ignored = today's behaviour)"

# ── 7) summary ────────────────────────────────────────────────────────────────
green "[M122] (ENFORCE) flag ON: READ → replica pool · WRITE → primary (absent on replica) · READ again → replica"
green "[M122] (PARITY)  flag OFF: READ → primary (replica_inline_dsn ignored = byte-parity)"
green "[M122] SCOPE: routing DECISION proven (read→replica / write→primary / OFF→primary). Replication-lag/SLO numbers are infra-blocked → OUT OF SCOPE."
green "[M122] ALL GATES GREEN — read-replica routing mechanism proven (non-vacuous: fails on pre-S8 HEAD, which has no replica_inline_dsn field nor routing branch)"

# ── log the gate event via the kernel helper (best-effort, JSONL) ─────────────
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-s8-read-replica-routing}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m122=PASS" --outcome pass \
      --msg "S8 read-replica routing MECHANISM: flag ON (DATA_PLANE_READ_REPLICA=1) a pure READ on a mount carrying replica_inline_dsn is served from the REPLICA's own /ro pool (sentinel=replica) while a WRITE lands on the PRIMARY (absent on the replica) and a subsequent READ still hits the replica; flag OFF the replica DSN is ignored and the READ is served by the PRIMARY = byte-parity. Routing DECISION only; replication-lag/SLO is infra-blocked = OUT OF SCOPE. Non-vacuous: fails on pre-S8 HEAD (no replica_inline_dsn field, no routing branch)." \
      --ref "scripts/verify/m122-read-replica-routing.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
exit 0
