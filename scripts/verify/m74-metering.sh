#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m74-metering.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M74 — Track-B metering B1a live gate. Proves DATA_PLANE_METERING (gated under
# the master METERING_ENABLED) does EXACTLY what it advertises — per-tenant usage
# counters in the Rust data plane — and that the LIVE BASELINE is byte-identical
# when OFF.
#
# The metered hooks (data-plane-server/src/routes.rs run_query, siblings of the
# audit emits at :905 / :935):
#     if state.config.metering && is_mutation {
#         state.usage.record(&audit_tenant, "write.rows", result.affected_rows);
#     }
#     if state.config.metering && !is_mutation {
#         state.usage.record(&audit_tenant, "query.count", 1);
#         state.usage.record(&audit_tenant, "query.rows", result.rows.len());
#     }
# A background flusher (usage.rs::spawn_flusher, the outbox.rs into_background
# precedent) drains the in-memory aggregate every DATA_PLANE_METERING_FLUSH_MS and
# emits ONE structured event per (tenant, metric) window:
#     tracing::info!(target: "usage", tenant=…, metric=…, qty=…, window_ms=…)
# OFF by default (config.rs metering ← METERING_ENABLED && DATA_PLANE_METERING,
# both default false) → the request path never calls `record`, the flusher is
# NEVER spawned, and the path is byte-parity with today (no `usage` event ever).
#
# ISOLATED by design (mirrors m72 / m59 isolated-ephemeral style): a scratch
# data-plane-router built FROM THE CURRENT (drafted, uncommitted) source + a
# throwaway postgres, both on a PRIVATE network, every container/image/network
# name suffixed with $$, an EXIT-trap that removes EVERYTHING. It NEVER touches a
# mini-baas-* container, network, image, or volume — safe while the live stack is
# up. The compose project is implicit (plain `docker run`, no project name that
# could collide with mini-baas-*).
#
# The probe hits the router's internal `/v1/query` trusted-envelope path inside
# the docker network (no host ports for the data path — only loopback-bound
# 127.0.0.1 publish for the test's own curl), with an inline DSN + a bare (no-RLS)
# probe table — exactly as m72 — so no Kong / tenant-control / auth machinery is
# needed and the test exercises the EXACT production metering code.
#
# DATA_PLANE_METERING_FLUSH_MS is set LOW (800 ms) so a flush window fires DURING
# the test; the gate then waits past one window before reading `docker logs`.
#
#   (A) POSITIVE: a router with METERING_ENABLED=1 DATA_PLANE_METERING=1 serves
#       ONE real read (list → ROWS=5 rows) and ONE real write (a batch of M=3
#       inserts → affected_rows=3). After > FLUSH_MS, its logs MUST contain
#       target="usage" events with EXACTLY:
#         metric=query.count qty=1   (one read)
#         metric=query.rows  qty=5   (the served row count, the ground truth)
#         metric=write.rows  qty=3   (the batch affected_rows, the ground truth)
#       each carrying tenant=<the probe tenant>. Every qty is asserted against the
#       INDEPENDENTLY-KNOWN truth (ROWS / M / 1), never a self-reported number.
#   (B) PARITY:   an IDENTICAL router with the flags OFF/unset serves the SAME
#       read+write (both 200, same rows) → its logs MUST contain ZERO target="usage"
#       lines (grep -c == 0). This proves OFF == byte-parity baseline.
#
# Fails (exit≠0) on any missing/wrong qty in A, or ANY usage line in B. Each fail
# names the exact assertion that tripped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DPR_DIR="${BAAS_DIR}/docker/services/data-plane-router"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M74] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M74] FAIL — $*"; exit 1; }
# has/nhas: assert a string is / is NOT present in a captured log blob (arg, not
# a file — the router logs live in `docker logs`, not on disk).
has()  { grep -q "$1" <<<"$3" || fail "$2"; }
nhas() { grep -q "$1" <<<"$3" && fail "$2"; return 0; }

PG_IMAGE="${M74_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m74-dpr-$$:scratch"
NET="m74net-$$"
PG="m74-pg-$$"
DPR_ON="m74-dpr-on-$$"     # (A) POSITIVE arm router (metering ON)
DPR_OFF="m74-dpr-off-$$"   # (B) PARITY   arm router (metering OFF/unset)
PORT_ON="${M74_PORT_ON:-18974}"
PORT_OFF="${M74_PORT_OFF:-18975}"
PGPW="postgres"
# Per-arm probe tables in the SHARED postgres so the two arms are fully isolated:
# the ON arm's 3 writes can never inflate the OFF arm's list (and vice-versa), so
# each arm's read deterministically returns EXACTLY ${ROWS}. The request shape is
# otherwise identical (op/data/identity/mask) — only the resource name scopes the
# arm, the natural way to give each arm its own deterministic ground truth.
TABLE_ON="m74_usage_probe_on"
TABLE_OFF="m74_usage_probe_off"
TENANT="m74-tenant-$$"
ROWS=5                    # exact seeded row count → query.rows qty
M=3                       # batch insert items → write.rows qty (affected_rows)
FLUSH_MS="${M74_FLUSH_MS:-800}"   # LOW so a flush fires during the test
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR_ON}" "${DPR_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# Build the /v1/query envelope: identity + mount(inline DSN) + operation. Identical
# contract to m72 — the internal trusted-envelope path. The `service_role`/`admin`
# identity + bare (no-RLS) probe table means a `list` returns ALL seeded rows
# deterministically, so query.rows qty is predictable.
#   $1 = op  ·  $2 = resource (table)  ·  $3 = data JSON (or the literal `null`)
payload() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"m74","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"inline","reference":"-","version":"1"},"capability_overrides":null,"inline_dsn":"%s","isolation":"shared_rls"},"operation":{"op":"%s","resource":"%s","data":%s}}' \
    "${TENANT}" "${TENANT}" "${TENANT}" "${DSN_INNET}" "$1" "$2" "$3"
}

# Build the batch `data` array: M insert sub-operations into the given table.
# run_batch totals affected_rows across items → exactly M → write.rows qty == M.
#   $1 = table
batch_data() { # $1=table
  local t="$1"
  printf '['
  for i in $(seq 1 "${M}"); do
    [[ $i -gt 1 ]] && printf ','
    printf '{"op":"insert","resource":"%s","data":{"id":"w%s","owner_id":"%s","tenant_id":"%s","label":"wrote%s"}}' \
      "${t}" "$i" "${TENANT}" "${TENANT}" "$i"
  done
  printf ']'
}

# POST a query to a router on 127.0.0.1:$port; echo the HTTP status, body→BODY_TMP.
post_q() { # $1=port  $2=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/query" \
    -H 'Content-Type: application/json' -d "$2"
}

# tracing's text formatter styles field names with ANSI escapes, so a raw
# `docker logs` interleaves them. Strip CSI sequences before asserting on the
# structured key=value fields.
#
# Emit shape (data-plane-server/src/usage.rs emit_window):
#     tracing::info!(target: "usage", tenant=…, metric=…, qty=…, window_ms=…,
#                    "usage window")
# The DEFAULT text formatter (main.rs `tracing_subscriber::fmt()…with_target(true)`)
# renders `target:"usage"` as a `usage:` MODULE PREFIX — NOT a `target="usage"`
# field — followed by the message + fields, e.g.:
#     INFO usage: usage window tenant=… metric=query.rows qty=5 window_ms=800
# So the robust, unique anchor for a usage event is the message `usage window`
# (only `emit_window` emits it) PLUS the `metric=`/`qty=` fields. (This differs
# from m72, whose `event="read"` is a tracing FIELD on the `audit` target, hence
# greppable as `event="read"`; here `usage` is the target, rendered as a prefix.)
USAGE_ANCHOR='usage window'
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

# Assert EXACTLY ONE usage line for `metric` carrying the right tenant, and that
# its qty equals the independently-known truth.
#   $1 = metric  ·  $2 = expected-qty (ground truth)  ·  $3 = log blob
assert_usage() {
  local metric="$1" want="$2" blob="$3" lines line n
  lines="$(grep "${USAGE_ANCHOR}" <<<"${blob}" | grep "metric=${metric}" || true)"
  n="$(grep -c . <<<"${lines}" || true)"
  # grep -c on an empty string still reports 1 (one empty line) — normalize.
  [[ -z "${lines}" ]] && n=0
  [[ "${n}" == "1" ]] \
    || fail "metric=${metric}: expected EXACTLY 1 usage line, found ${n} — $(tail -3 <<<"${lines}") (line: assert_usage ${metric} count)"
  line="${lines}"
  has "tenant=${TENANT}" "metric=${metric} usage line missing tenant=${TENANT} — line: ${line} (line: assert_usage ${metric} tenant)" "${line}"
  has "qty=${want}" "metric=${metric} qty != ground truth (${want}) — line: ${line} (line: assert_usage ${metric} qty)" "${line}"
  ok "(A) metric=${metric} qty=${want} tenant=${TENANT} — matches the independently-known truth"
}

# ── 0) build the scratch DPR image FROM THE CURRENT (drafted) source ──────────
step "0/7 build scratch data-plane-router from CURRENT source (contains THE B1a build)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch DPR image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + throwaway postgres with EXACTLY ${ROWS} seeded rows ─
step "1/7 boot isolated postgres (${PG}) on private net (${NET}); seed ${ROWS} rows"
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
# Two bare tables (NO RLS policy enabled) so the RLS GUC the router sets has no
# effect and `list` returns ALL ${ROWS} rows → query.rows qty is exact &
# deterministic. ONE table per arm so the ON arm's M writes can never inflate the
# OFF arm's read (the bug a single shared table would cause). The batch insert
# writes M MORE rows (ids w1..wM) into the ARM's OWN table but query.rows is
# measured by the read fired BEFORE the write, so it sees exactly ${ROWS} rows.
seed() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.${TABLE_ON} (
  id text PRIMARY KEY, owner_id text, tenant_id text, label text);
CREATE TABLE IF NOT EXISTS public.${TABLE_OFF} (
  id text PRIMARY KEY, owner_id text, tenant_id text, label text);
INSERT INTO public.${TABLE_ON}(id, owner_id, tenant_id, label) VALUES
  ('r1','${TENANT}','${TENANT}','one'),('r2','${TENANT}','${TENANT}','two'),
  ('r3','${TENANT}','${TENANT}','three'),('r4','${TENANT}','${TENANT}','four'),
  ('r5','${TENANT}','${TENANT}','five') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.${TABLE_OFF}(id, owner_id, tenant_id, label) VALUES
  ('r1','${TENANT}','${TENANT}','one'),('r2','${TENANT}','${TENANT}','two'),
  ('r3','${TENANT}','${TENANT}','three'),('r4','${TENANT}','${TENANT}','four'),
  ('r5','${TENANT}','${TENANT}','five') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "seed never committed (line: seed loop)"; sleep 0.5; done
for T in "${TABLE_ON}" "${TABLE_OFF}"; do
  SEEDED="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.${T}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${SEEDED}" == "${ROWS}" ]] || fail "expected ${ROWS} seeded rows in ${T}, found '${SEEDED}' (line: SEEDED count ${T})"
done
ok "postgres up; ${TABLE_ON} & ${TABLE_OFF} each seeded with EXACTLY ${ROWS} rows"

# ── 2) (A) POSITIVE arm: a router with metering ON + a LOW flush window ────────
step "2/7 boot scratch router with METERING_ENABLED=1 DATA_PLANE_METERING=1 (A · POSITIVE), flush=${FLUSH_MS}ms"
docker run -d --name "${DPR_ON}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e METERING_ENABLED=1 \
  -e DATA_PLANE_METERING=1 \
  -e DATA_PLANE_METERING_FLUSH_MS="${FLUSH_MS}" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_ON}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_ON}" "${PORT_ON}" || fail "POSITIVE router not ready (line: wait_ready DPR_ON)"
ok "POSITIVE router up (metering ON) on 127.0.0.1:${PORT_ON}"

step "2b/7 fire ONE real read (list → ${ROWS} rows) through the POSITIVE router"
code="$(post_q "${PORT_ON}" "$(payload list "${TABLE_ON}" null)")"
[[ "${code}" == "200" ]] || fail "POSITIVE list expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: POSITIVE read status)"
SERVED="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED}" == "${ROWS}" ]] || fail "POSITIVE list returned ${SERVED} rows, expected ${ROWS} — $(head -c 300 "${BODY_TMP}") (line: SERVED count)"
ok "ONE read served 200 with all ${ROWS} rows (ground truth for query.rows)"

step "2c/7 fire ONE real write (batch of ${M} inserts → affected_rows=${M}) through the POSITIVE router"
code="$(post_q "${PORT_ON}" "$(payload batch "${TABLE_ON}" "$(batch_data "${TABLE_ON}")")")"
[[ "${code}" == "200" ]] || fail "POSITIVE batch write expected 200, got ${code} — $(head -c 400 "${BODY_TMP}") (line: POSITIVE write status)"
# Confirm the write genuinely affected M rows (so write.rows ground truth is real).
WROTE="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.${TABLE_ON} WHERE id LIKE 'w%'" 2>/dev/null | tr -d '[:space:]')"
[[ "${WROTE}" == "${M}" ]] || fail "POSITIVE batch wrote ${WROTE} rows, expected ${M} (write must really persist) — $(head -c 300 "${BODY_TMP}") (line: WROTE count)"
ok "ONE batch write affected ${M} rows (ground truth for write.rows)"

# ── 3) (A) wait past one flush window, then ASSERT the three usage events ──────
step "3/7 wait > flush window (${FLUSH_MS}ms) so the background flusher emits the usage events"
# Sleep ~3 windows + slack so at least one full drain-and-emit cycle has run.
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*3 + 1}")"
LOGS_ON="$(logs_clean "${DPR_ON}")"
N_USAGE_ON="$(grep -c "${USAGE_ANCHOR}" <<<"${LOGS_ON}" || true)"
[[ "${N_USAGE_ON}" -ge 3 ]] \
  || fail "expected ≥3 \"${USAGE_ANCHOR}\" (usage) lines (query.count/query.rows/write.rows), found ${N_USAGE_ON} — $(grep "${USAGE_ANCHOR}" <<<"${LOGS_ON}" | tail -5) (line: N_USAGE_ON < 3)"
step "3b/7 ASSERT (A): each metric emits ONE usage line with qty == the known truth"
assert_usage "query.count" 1        "${LOGS_ON}"
assert_usage "query.rows"  "${ROWS}" "${LOGS_ON}"
assert_usage "write.rows"  "${M}"    "${LOGS_ON}"
ok "(A) all three metering dimensions emitted the exact ground-truth qty for tenant=${TENANT}"

# ── 4) (B) PARITY arm: an IDENTICAL router with the flags OFF (default) ────────
step "4/7 boot scratch router with METERING flags unset (B · PARITY/default)"
docker run -d --name "${DPR_OFF}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_OFF}:4011" "${SCRATCH_IMG}" >/dev/null
wait_ready "${DPR_OFF}" "${PORT_OFF}" || fail "PARITY router not ready (line: wait_ready DPR_OFF)"
ok "PARITY router up (metering default OFF) on 127.0.0.1:${PORT_OFF}"

step "4b/7 fire the SAME read + write through the PARITY router (must still serve 200)"
code="$(post_q "${PORT_OFF}" "$(payload list "${TABLE_OFF}" null)")"
[[ "${code}" == "200" ]] || fail "PARITY list expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: PARITY read status)"
SERVED_OFF="$(grep -o '"label"' "${BODY_TMP}" | wc -l | tr -d '[:space:]')"
[[ "${SERVED_OFF}" == "${ROWS}" ]] || fail "PARITY list returned ${SERVED_OFF} rows, expected ${ROWS} (read must still work) — $(head -c 300 "${BODY_TMP}") (line: SERVED_OFF count)"
# The OFF arm hits its OWN table (${TABLE_OFF}), seeded identically to ${TABLE_ON},
# so its read returns the same ${ROWS} and its batch write genuinely succeeds with
# 200 — the IDENTICAL mutation path. What proves parity is ZERO usage lines.
code="$(post_q "${PORT_OFF}" "$(payload batch "${TABLE_OFF}" "$(batch_data "${TABLE_OFF}")")")"
[[ "${code}" == "200" ]] \
  || fail "PARITY batch write expected 200, got ${code} — $(head -c 400 "${BODY_TMP}") (line: PARITY write status)"
ok "the same read+write still serve 200 through the PARITY router (no behavior change)"

# ── 5) (B) ASSERT: ZERO usage lines with the flags OFF (byte-parity) ──────────
step "5/7 wait the same window, then ASSERT (B): ZERO usage lines"
sleep "$(awk "BEGIN{printf \"%.1f\", ${FLUSH_MS}/1000*3 + 1}")"
LOGS_OFF="$(logs_clean "${DPR_OFF}")"
N_USAGE_OFF="$(grep -c "${USAGE_ANCHOR}" <<<"${LOGS_OFF}" || true)"
[[ "${N_USAGE_OFF}" == "0" ]] \
  || fail "PARITY router emitted ${N_USAGE_OFF} \"${USAGE_ANCHOR}\" (usage) line(s) — the default is NOT byte-parity! $(grep "${USAGE_ANCHOR}" <<<"${LOGS_OFF}" | tail -5) (line: N_USAGE_OFF != 0)"
nhas "${USAGE_ANCHOR}" "PARITY router leaked a usage line with the flags OFF (line: nhas usage)" "${LOGS_OFF}"
ok "(B) ZERO usage lines with the flags OFF — live baseline is byte-parity"

# ── 6) cross-check: the two arms differ ONLY by the usage events ──────────────
step "6/7 cross-check: ON emitted ${N_USAGE_ON} usage lines, OFF emitted 0 — the flag is the only difference"
[[ "${N_USAGE_ON}" -ge 3 && "${N_USAGE_OFF}" == "0" ]] \
  || fail "arm counts inconsistent (ON=${N_USAGE_ON}, OFF=${N_USAGE_OFF}) (line: cross-check)"
ok "METERING_ENABLED+DATA_PLANE_METERING is the sole gate on the usage emission"

# ── 7) done ───────────────────────────────────────────────────────────────────
step "7/7 all metering assertions hold"
green "[M74] ALL GATES GREEN — METERING ON emits target=\"usage\" with query.count=1, query.rows=${ROWS}, write.rows=${M} (each = the independently-known truth) for tenant=${TENANT}; OFF (default) emits ZERO usage lines = byte-parity live baseline"
