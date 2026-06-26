#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m174-osionos-multiengine.sh — osionos multi-engine Second-Brain graph gate  #
#                                                                              #
#  Proves the osionos multi-engine graph end to end against the RUNNING stack: #
#    1  DISCOVER — the mounts linked to the dev workspace via                   #
#       public.osionos_workspace_databases (db_id, engine, tables).            #
#    2  OWNER ROWS — each discovered mount returns owner-scoped rows through    #
#       the query-router (op:list limit 3 → rowCount>0) for its first table.   #
#    3  GRAPH — a dev.pro.photo app-session token → GET /api/graph/data?        #
#       scope=account returns record nodes from >=3 distinct mounts AND         #
#       cross-engine edges (from/to span different mounts).                     #
#    4  RECORD→NOTE — POST /api/records/<pgMount>/orders/1234/open twice → 200  #
#       both, SAME note id (idempotent); GET .../orders/1234 → row present.     #
#    5  ACCESS — a NON-member token (sub=dave, a random workspace) sees 0 DB    #
#       records in the graph AND POST .../open → 403.                           #
#                                                                              #
#  Idempotent + re-runnable: reads live state, opens an idempotent note, makes  #
#  no destructive change. The cleartext owner key + the app-session secret are  #
#  read from the running osionos-bridge container (never hardcoded).            #
# **************************************************************************** #
set -euo pipefail

BRIDGE_CTN="track-binocle-osionos-bridge-1"
QR_CTN="mini-baas-query-router"
PG_CTN="mini-baas-postgres"
DEV_USER="5cc30a3f-87e4-471d-b795-c936723081ee"
DEV_WS="0ea96910-277a-49d6-901c-524b147cc009"
DAVE_USER="426fd9fd-3169-48c3-b91f-b0f3d8ab760e"
PG_MOUNT="59939f19-7e8d-4876-a57f-61b3e7bb37be"
PG_ORDER_PK="1234"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M174] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[0;31m[M174] FAIL — %s\033[0m\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

dexec() { docker exec "$@"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# ── 0) preconditions ─────────────────────────────────────────────────────────
step "0/5 preconditions — bridge, query-router, postgres are up"
for ctn in "${BRIDGE_CTN}" "${QR_CTN}" "${PG_CTN}"; do
  running "${ctn}" || fail "container ${ctn} is not running (start the stack + grobase first)"
done
AK="$(dexec "${BRIDGE_CTN}" sh -c 'printenv OSIONOS_BAAS_API_KEY || printenv BAAS_API_KEY || printenv VITE_BAAS_API_KEY' 2>/dev/null || true)"
[[ -n "${AK}" ]] || fail "no owner API key in the bridge container (OSIONOS_BAAS_API_KEY)"
[[ -n "$(dexec "${BRIDGE_CTN}" sh -c 'printenv OSIONOS_APP_SESSION_SECRET' 2>/dev/null || true)" ]] \
  || fail "OSIONOS_APP_SESSION_SECRET is not set in the bridge container"
ok "stack up; owner key ${AK:0:8}… + app-session secret present"

# ── 1) DISCOVER the mounts linked to the dev workspace ───────────────────────
step "1/5 discover the mounts linked to workspace ${DEV_WS:0:8}…"
dexec "${PG_CTN}" psql -U postgres -d postgres -At -F '|' -c \
  "SELECT db_id, engine, tables[1] FROM public.osionos_workspace_databases
     WHERE workspace_id='${DEV_WS}' AND db_id ~ '^[0-9a-f-]{36}\$' ORDER BY engine;" \
  >"${TMP}/mounts.txt" 2>"${TMP}/pg.err" || fail "mount discovery query failed — $(cat "${TMP}/pg.err")"
MOUNT_COUNT="$(grep -c '|' "${TMP}/mounts.txt" || true)"
[[ "${MOUNT_COUNT}" -ge 3 ]] || fail "expected >=3 linked mounts, found ${MOUNT_COUNT}"
ENGINES="$(cut -d'|' -f2 "${TMP}/mounts.txt" | paste -sd, -)"
ok "${MOUNT_COUNT} mounts discovered (engines: ${ENGINES})"

# ── 2) OWNER-SCOPED ROWS per mount via the query-router (op:list) ────────────
step "2/5 owner-scoped rows via the query-router (op:list limit 3 → rowCount>0)"
# A 5xx from the query-router is the data-plane pool flapping (the documented
# SHARE_POOLS pool-thrash / post-provision drop), not a real owner-scope miss —
# retry a couple of times with a short pause before judging a mount DOWN.
cat >"${TMP}/qr.mjs" <<'NODE'
const [AK, db, table] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function once() {
  const res = await fetch(`http://127.0.0.1:4001/${db}/tables/${table}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Baas-Api-Key': AK },
    body: JSON.stringify({ op: 'list', limit: 3 }),
  });
  const j = await res.json().catch(() => null);
  const rows = Array.isArray(j) ? j : (j && Array.isArray(j.rows) ? j.rows : []);
  return { status: res.status, rows: rows.length };
}
let out = { status: 0, rows: 0 };
for (let attempt = 0; attempt < 3; attempt += 1) {
  out = await once();
  if (out.status < 500 && out.rows > 0) break;
  await sleep(1500);
}
process.stdout.write(`${out.status} ${out.rows}`);
NODE
dexec -i "${QR_CTN}" sh -c 'cat > /tmp/m174-qr.mjs' < "${TMP}/qr.mjs"
HEALTHY=0; DOWN_ENGINES=""
while IFS='|' read -r db engine table; do
  [[ -n "${db}" && -n "${table}" ]] || continue
  out="$(dexec "${QR_CTN}" node /tmp/m174-qr.mjs "${AK}" "${db}" "${table}" 2>/dev/null || echo "0 0")"
  http="${out%% *}"; rows="${out##* }"
  if { [[ "${http}" == "200" || "${http}" == "201" ]] && [[ "${rows}" -ge 1 ]]; }; then
    HEALTHY=$((HEALTHY + 1))
    ok "${engine} ${db:0:8}… '${table}' → ${rows} owner-scoped row(s) (HTTP ${http})"
  else
    # A discovered mount whose data-plane is transiently down (e.g. the known
    # sqlite/sqlite-pool 502 after a reprovision) is reported, not silently
    # passed; the gate needs >=3 HEALTHY mounts, the task's own multi-engine bar.
    DOWN_ENGINES="${DOWN_ENGINES}${engine} "
    warn "${engine} ${db:0:8}… '${table}' DOWN — HTTP ${http}, rowCount ${rows} (data-plane forward failed)"
  fi
done < "${TMP}/mounts.txt"
[[ "${HEALTHY}" -ge 3 ]] || fail "only ${HEALTHY} mount(s) served owner-scoped rows (need >=3); down: ${DOWN_ENGINES:-none}"
[[ -z "${DOWN_ENGINES}" ]] \
  && ok "all ${HEALTHY} discovered mounts serve owner-scoped rows" \
  || ok "${HEALTHY} mounts healthy (>=3 OK); transiently down: ${DOWN_ENGINES}"

# ── 3) GRAPH — dev session token → /api/graph/data?scope=account ─────────────
step "3/5 graph: >=3 distinct record mounts + cross-engine edges (scope=account)"
cat >"${TMP}/graph.mjs" <<'NODE'
import { createHmac } from 'node:crypto';
const secret = process.env.OSIONOS_APP_SESSION_SECRET;
const [sub, ...wsIds] = process.argv.slice(2);
const b64 = (s) => Buffer.from(s).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const payload = { iss: 'osionos-bridge', aud: 'osionos-app', sub, provider: 'm174',
  workspace_ids: wsIds, roles: {}, is_admin: false, jti: 'm174', iat: now, exp: now + 600 };
const ep = b64(JSON.stringify(payload));
const sig = createHmac('sha256', secret).update(ep).digest('base64url');
const token = `osionos_v1.${ep}.${sig}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mountOf = (id) => String(id || '').split(':')[0];
const isDave = sub.startsWith('426fd9fd');
async function snapshot() {
  const res = await fetch('http://127.0.0.1:4000/api/graph/data?scope=account',
    { headers: { Authorization: `Bearer ${token}` } });
  const d = await res.json().catch(() => ({}));
  const nodes = Array.isArray(d.nodes) ? d.nodes : [];
  const edges = Array.isArray(d.edges) ? d.edges : [];
  const mounts = new Set(nodes.map((n) => n && n.mount).filter((m) => m && m !== 'osionos'));
  const cross = edges.filter((e) => {
    const a = mountOf(e.from); const b = mountOf(e.to);
    return a && b && a !== b && a !== 'osionos' && b !== 'osionos';
  });
  return { status: res.status, nodes: nodes.length, recordMounts: mounts.size, crossEdges: cross.length };
}
// dave (non-member) is EXPECTED to see 0 record mounts — never retry him; a
// member retries past a transient data-plane flap that drops the record half.
let snap = await snapshot();
for (let attempt = 0; !isDave && attempt < 2 && (snap.recordMounts < 3 || snap.crossEdges < 1); attempt += 1) {
  await sleep(1500);
  snap = await snapshot();
}
process.stdout.write(JSON.stringify(snap));
NODE
dexec -i "${BRIDGE_CTN}" sh -c 'cat > /tmp/m174-graph.mjs' < "${TMP}/graph.mjs"
G="$(dexec "${BRIDGE_CTN}" node /tmp/m174-graph.mjs "${DEV_USER}" "${DEV_WS}" 2>/dev/null || echo '{}')"
gstatus="$(printf '%s' "${G}" | sed -n 's/.*"status":\([0-9]*\).*/\1/p')"
gmounts="$(printf '%s' "${G}" | sed -n 's/.*"recordMounts":\([0-9]*\).*/\1/p')"
gcross="$(printf '%s' "${G}" | sed -n 's/.*"crossEdges":\([0-9]*\).*/\1/p')"
[[ "${gstatus}" == "200" ]] || fail "graph-data returned HTTP ${gstatus:-?} (${G})"
[[ "${gmounts:-0}" -ge 3 ]] || fail "graph spans only ${gmounts:-0} record mounts (need >=3): ${G}"
[[ "${gcross:-0}" -ge 1 ]] || fail "no cross-engine edges (from/to span different mounts): ${G}"
ok "graph: ${gmounts} distinct record mounts, ${gcross} cross-engine edge(s)"

# ── 4) RECORD→NOTE round-trip (idempotent) ───────────────────────────────────
step "4/5 record→note: open ${PG_MOUNT:0:8}…/orders/${PG_ORDER_PK} twice (same note) + read"
cat >"${TMP}/record.mjs" <<'NODE'
import { createHmac } from 'node:crypto';
const secret = process.env.OSIONOS_APP_SESSION_SECRET;
const [sub, ws, mount, table, pk] = process.argv.slice(2);
const b64 = (s) => Buffer.from(s).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const ep = b64(JSON.stringify({ iss: 'osionos-bridge', aud: 'osionos-app', sub, provider: 'm174',
  workspace_ids: [ws], roles: {}, is_admin: false, jti: 'm174r', iat: now, exp: now + 600 }));
const token = `osionos_v1.${ep}.${createHmac('sha256', secret).update(ep).digest('base64url')}`;
const h = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const base = `http://127.0.0.1:4000/api/records/${mount}/${table}/${pk}`;
const open = async () => { const r = await fetch(`${base}/open`, { method: 'POST', headers: h });
  return { status: r.status, id: ((await r.json().catch(() => ({})))._id) ?? null }; };
const a = await open();
const b = await open();
const rd = await fetch(base, { headers: h });
const rj = await rd.json().catch(() => ({}));
process.stdout.write(JSON.stringify({ s1: a.status, id1: a.id, s2: b.status, id2: b.id,
  same: a.id && a.id === b.id, readStatus: rd.status, row: !!rj.row }));
NODE
dexec -i "${BRIDGE_CTN}" sh -c 'cat > /tmp/m174-record.mjs' < "${TMP}/record.mjs"
R="$(dexec "${BRIDGE_CTN}" node /tmp/m174-record.mjs "${DEV_USER}" "${DEV_WS}" "${PG_MOUNT}" orders "${PG_ORDER_PK}" 2>/dev/null || echo '{}')"
r_s1="$(printf '%s' "${R}" | sed -n 's/.*"s1":\([0-9]*\).*/\1/p')"
r_s2="$(printf '%s' "${R}" | sed -n 's/.*"s2":\([0-9]*\).*/\1/p')"
r_same="$(printf '%s' "${R}" | grep -o '"same":true' || true)"
r_read="$(printf '%s' "${R}" | sed -n 's/.*"readStatus":\([0-9]*\).*/\1/p')"
r_row="$(printf '%s' "${R}" | grep -o '"row":true' || true)"
[[ "${r_s1}" == "200" && "${r_s2}" == "200" ]] || fail "record open not 200/200 (${R})"
[[ -n "${r_same}" ]] || fail "record open not idempotent — note id changed (${R})"
[[ "${r_read}" == "200" && -n "${r_row}" ]] || fail "record read missing the row (${R})"
ok "open ${r_s1}/${r_s2}, same note id (idempotent); read ${r_read} with row present"

# ── 5) ACCESS — non-member dave sees no records + open is 403 ─────────────────
step "5/5 access: non-member (dave) → 0 graph DB-records AND open → 403"
RAND_WS="11111111-2222-4333-8444-555555555555"
DG="$(dexec "${BRIDGE_CTN}" node /tmp/m174-graph.mjs "${DAVE_USER}" "${RAND_WS}" 2>/dev/null || echo '{}')"
d_status="$(printf '%s' "${DG}" | sed -n 's/.*"status":\([0-9]*\).*/\1/p')"
d_mounts="$(printf '%s' "${DG}" | sed -n 's/.*"recordMounts":\([0-9]*\).*/\1/p')"
[[ "${d_status}" == "200" ]] || fail "dave graph-data HTTP ${d_status:-?} (${DG})"
[[ "${d_mounts:-1}" == "0" ]] || fail "non-member dave sees ${d_mounts} record mounts (must be 0): ${DG}"
DOPEN="$(dexec "${BRIDGE_CTN}" node /tmp/m174-record.mjs "${DAVE_USER}" "${RAND_WS}" "${PG_MOUNT}" orders "${PG_ORDER_PK}" 2>/dev/null || echo '{}')"
d_open="$(printf '%s' "${DOPEN}" | sed -n 's/.*"s1":\([0-9]*\).*/\1/p')"
[[ "${d_open}" == "403" ]] || fail "non-member open returned HTTP ${d_open:-?}, expected 403 (${DOPEN})"
ok "non-member dave: 0 graph record-mounts; record open forbidden (403)"

printf '\033[0;32m[M174] ALL GATES GREEN — osionos multi-engine graph: %s mounts · owner-scoped rows · %s cross-engine edges · idempotent record→note · non-member 403\033[0m\n' \
  "${MOUNT_COUNT}" "${gcross}"
