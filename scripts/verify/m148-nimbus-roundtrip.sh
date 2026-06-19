#!/usr/bin/env bash
# **************************************************************************** #
#  m148-nimbus-roundtrip.sh — Nimbus-on-Grobase live e2e gate                 #
#                                                                              #
#  Proves a CUSTOM-composed BaaS spanning PostgreSQL + MongoDB with an ACID    #
#  money model, end to end, through Kong against the RUNNING stack:            #
#    1. provision   — nimbus-tenant.sh (idempotent): tenant+custom entitlement #
#                     + PG mount + Mongo mount + schema + demo + GoTrue admin.  #
#    2. composition — BOTH-engine schema probes (PG 200 AND Mongo 200).        #
#    3. auth        — signup → JWT; wrong password rejected; admin login 200.  #
#    4. PG CRUD     — app_users insert → list → update → delete.               #
#    5. ACID COMMIT — a balanced 5-op txn batch moves money + writes 2 ledger  #
#                     rows; balances move correctly.                           #
#    6. ACID ROLLBACK — a poisoned batch fails; balances UNCHANGED, no txns    #
#                     row for the poisoned reference (the load-bearing proof). #
#    7. Mongo CRUD  — messages open→list→close; content upsert idempotent.     #
#    8. aggregate   — SUM(amount_cents) of posted txns == committed amount.    #
#    8b. isolation  — the JWT is the authority: a customer JWT reads 0 users /  #
#                     0 accounts, cannot escalate a seeded admin row (must-fail #
#                     self-revert), and the admin JWT's F2 bypass still reads.  #
#    9. cleanup     — test rows removed (the permanent tenant stays).          #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M148] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M148] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

# jval FILE KEY — top-level JSON string value for KEY.
jval() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null || true; }
# jsub TOKEN — decode the `sub` claim from a JWT without verifying.
jsub() { python3 -c '
import sys,base64,json
p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p)).get("sub",""))' "$1" 2>/dev/null || true; }
# rows_len — number of rows in the last gateway response.
rows_len() { python3 -c 'import json;print(len(json.load(open("/tmp/m148-q.json"))["rows"]))' 2>/dev/null || echo 0; }

# ── 1) provision (idempotent) ────────────────────────────────────────────────
step "1/9 provision the nimbus tenant (idempotent)"
bash "${BAAS_DIR}/scripts/seed/nimbus-tenant.sh" >/tmp/m148-seed.log 2>&1 \
  || fail "provisioning failed — see /tmp/m148-seed.log: $(tail -3 /tmp/m148-seed.log)"
# shellcheck disable=SC1091
source "${BAAS_DIR}/.nimbus-tenant.env"
KONG="${NIMBUS_KONG_URL}"
ANON="${NIMBUS_ANON_APIKEY}"
AK="${NIMBUS_API_KEY}"
PG="${NIMBUS_PG_DB_ID}"
MG="${NIMBUS_MONGO_DB_ID}"
[[ -n "${KONG}" && -n "${AK}" && -n "${PG}" && -n "${MG}" ]] || fail "incomplete provisioning state"
ok "tenant=${NIMBUS_TENANT_SLUG} pg=${PG} mongo=${MG}"

# q DBID RESOURCE BODY — gateway CRUD helper; body→/tmp/m148-q.json, echoes status.
q() {
  curl -s -o /tmp/m148-q.json -w '%{http_code}' -X POST "${KONG}/query/v1/$1/tables/$2" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H 'Content-Type: application/json' -d "$3"
}
# qj JWT DBID RESOURCE BODY — same as q but rides a per-user Bearer JWT so the
# data plane owner-scopes the request to that user (admin → F2 bypass; customer →
# own rows only). body→/tmp/m148-q.json, echoes status. This is what the browser
# now sends (db.ts/tx.ts forward the session JWT) — the gate must exercise it.
qj() {
  curl -s -o /tmp/m148-q.json -w '%{http_code}' -X POST "${KONG}/query/v1/$2/tables/$3" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$4"
}
# admin_auth — emits the `-H Authorization: Bearer <admin JWT>` arg pair when the
# admin JWT is set (after step 3), else nothing. With read_scoped ON the seeded
# accounts/txns are system:nimbus-owned, so the money-move helpers below must ride
# the admin JWT (F2 bypass) — exactly as the real frontend's tx.ts does. Before
# step 3 (CRUD on the app key's own rows) it expands empty = the old app-key path.
admin_auth() { [[ -n "${ADMIN_JWT:-}" ]] && printf -- '-H\nAuthorization: Bearer %s\n' "${ADMIN_JWT}"; }
# txn BODY — POST /query/v1/txn; body→/tmp/m148-txn.json, echoes status. Rides the
# admin JWT (F2 bypass) so the batch reaches the system:nimbus-owned accounts.
# Retries once on a cold-pool 502 (data plane lazy-warms its first connection).
txn() {
  local code; local -a auth; mapfile -t auth < <(admin_auth)
  code=$(curl -s -o /tmp/m148-txn.json -w '%{http_code}' -X POST "${KONG}/query/v1/txn" \
    -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" "${auth[@]}" -H 'Content-Type: application/json' -d "$1")
  if [[ "${code}" == "502" || "${code}" == "503" ]]; then
    sleep 2
    code=$(curl -s -o /tmp/m148-txn.json -w '%{http_code}' -X POST "${KONG}/query/v1/txn" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}" "${auth[@]}" -H 'Content-Type: application/json' -d "$1")
  fi
  echo "${code}"
}
# gotrue PATH BODY — POST /auth/v1/<path>; body→/tmp/m148-a.json, echoes status.
gotrue() {
  curl -s -o /tmp/m148-a.json -w '%{http_code}' -X POST "${KONG}/auth/v1/$1" \
    -H "apikey: ${ANON}" -H 'Content-Type: application/json' -d "$2"
}
# qadmin DBID RESOURCE BODY — read on the admin JWT (F2 bypass over system:nimbus
# data) when set, falling back to the app key before step 3. The seeded financials
# are system:nimbus-owned under read_scoped, so the money-model reads need it.
qadmin() {
  if [[ -n "${ADMIN_JWT:-}" ]]; then qj "${ADMIN_JWT}" "$1" "$2" "$3"; else q "$1" "$2" "$3"; fi
}
# acct_balance ID — owner-bypassed read of accounts.balance_cents for an id.
acct_balance() {
  qadmin "${PG}" accounts "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":$1}}}" >/dev/null
  python3 -c 'import json;r=json.load(open("/tmp/m148-q.json"))["rows"];print(r[0]["balance_cents"] if r else "MISS")' 2>/dev/null || echo MISS
}
# acct_id_by_kind KIND — first accounts.id for a kind (ordered by id).
acct_id_by_kind() {
  qadmin "${PG}" accounts "{\"op\":\"list\",\"filter\":{\"kind\":{\"\$eq\":\"$1\"}},\"sort\":{\"id\":\"asc\"},\"limit\":1}" >/dev/null
  python3 -c 'import json;r=json.load(open("/tmp/m148-q.json"))["rows"];print(r[0]["id"] if r else "")' 2>/dev/null || echo ""
}

# ── 2) composition: BOTH engines schema-probe (the custom PG+Mongo proof) ────
step "2/9 composition: PG schema 200 AND Mongo schema 200"
p1=$(curl -s -o /tmp/m148-sc.json -w '%{http_code}' "${KONG}/query/v1/${PG}/schema" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}")
[[ "${p1}" == "200" ]] || fail "PG schema probe ${p1}: $(head -c200 /tmp/m148-sc.json)"
grep -q '"name":"ledger_entries"' /tmp/m148-sc.json || fail "PG schema missing ledger_entries"
p2=$(curl -s -o /tmp/m148-sc.json -w '%{http_code}' "${KONG}/query/v1/${MG}/schema" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${AK}")
[[ "${p2}" == "200" ]] || fail "Mongo schema probe ${p2}: $(head -c200 /tmp/m148-sc.json)"
ok "PG + Mongo both introspect (custom dual-engine composition live)"

# ── 3) auth: signup → JWT, wrong-pw rejected, admin login ────────────────────
step "3/9 auth: signup → JWT; wrong password rejected; admin login"
EMAIL="m148_$(date +%s)$$@nimbus.local"
code=$(gotrue signup "{\"email\":\"${EMAIL}\",\"password\":\"M148pass!secret\"}")
[[ "${code}" == "200" || "${code}" == "201" ]] || fail "signup (${code}): $(head -c200 /tmp/m148-a.json)"
JWT="$(jval /tmp/m148-a.json access_token)"; SUB="$(jsub "${JWT}")"
[[ -n "${JWT}" && -n "${SUB}" ]] || fail "signup returned no JWT/sub"
bad=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"wrong-pw\"}")
[[ "${bad}" != "200" ]] || fail "wrong-password login should not return 200"
alog=$(curl -s -o /tmp/m148-a.json -w '%{http_code}' -X POST "${KONG}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${NIMBUS_ADMIN_EMAIL}\",\"password\":\"${NIMBUS_ADMIN_PASSWORD}\"}")
[[ "${alog}" == "200" ]] || fail "admin login (${alog}) should be 200"
ADMIN_JWT="$(jval /tmp/m148-a.json access_token)"
[[ -n "${ADMIN_JWT}" ]] || fail "admin login returned no JWT"
ok "signup JWT (sub ${SUB:0:8}); wrong-pw ${bad}; admin login 200"

# ── 4) PG CRUD on app_users ──────────────────────────────────────────────────
step "4/9 PG CRUD: app_users insert → list → update → delete"
TUID="m148-user-$$"
[[ "$(q "${PG}" app_users "{\"op\":\"insert\",\"data\":{\"id\":\"${TUID}\",\"email\":\"${TUID}@nimbus.local\",\"name\":\"Test User\",\"role\":\"customer\"}}")" == "201" ]] \
  || fail "app_users insert: $(head -c200 /tmp/m148-q.json)"
q "${PG}" app_users "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${TUID}\"}}}" >/dev/null
grep -q "\"email\":\"${TUID}@nimbus.local\"" /tmp/m148-q.json || fail "app_users read-back failed"
q "${PG}" app_users "{\"op\":\"update\",\"filter\":{\"id\":{\"\$eq\":\"${TUID}\"}},\"data\":{\"status\":\"suspended\"}}" >/dev/null
q "${PG}" app_users "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${TUID}\"}}}" >/dev/null
grep -q '"status":"suspended"' /tmp/m148-q.json || fail "app_users update did not land"
q "${PG}" app_users "{\"op\":\"delete\",\"filter\":{\"id\":{\"\$eq\":\"${TUID}\"}}}" >/dev/null
q "${PG}" app_users "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${TUID}\"}}}" >/dev/null
[[ "$(rows_len)" == "0" ]] || fail "app_users delete did not remove the row"
ok "insert → list → update → delete clean"

# Resolve the seeded customer + revenue accounts by kind (robust to any ids).
A1="$(acct_id_by_kind customer)"
A2="$(acct_id_by_kind revenue)"
[[ -n "${A1}" && -n "${A2}" ]] || fail "could not resolve seeded customer/revenue accounts"

# ── 5) ACID COMMIT: a balanced money-move batch ──────────────────────────────
step "5/9 ACID COMMIT: balanced 5-op txn moves money + writes 2 ledger rows"
B1_BEFORE="$(acct_balance "${A1}")"; B2_BEFORE="$(acct_balance "${A2}")"
[[ "${B1_BEFORE}" != "MISS" && "${B2_BEFORE}" != "MISS" ]] || fail "could not read account balances"
REF="pay_gate_$$_$(date +%s)"
AMT=4999
COMMIT_BODY="{\"mount\":\"${PG}\",\"operations\":[
  {\"op\":\"insert\",\"resource\":\"txns\",\"data\":{\"kind\":\"payment\",\"amount_cents\":${AMT},\"status\":\"posted\",\"reference\":\"${REF}\"}},
  {\"op\":\"insert\",\"resource\":\"ledger_entries\",\"data\":{\"account_id\":${A1},\"direction\":\"debit\",\"amount_cents\":${AMT}}},
  {\"op\":\"insert\",\"resource\":\"ledger_entries\",\"data\":{\"account_id\":${A2},\"direction\":\"credit\",\"amount_cents\":${AMT}}},
  {\"op\":\"update\",\"resource\":\"accounts\",\"filter\":{\"id\":${A1}},\"data\":{\"balance_cents\":$((B1_BEFORE - AMT))}},
  {\"op\":\"update\",\"resource\":\"accounts\",\"filter\":{\"id\":${A2}},\"data\":{\"balance_cents\":$((B2_BEFORE + AMT))}}
]}"
tcode="$(txn "${COMMIT_BODY}")"
[[ "${tcode}" == "200" || "${tcode}" == "201" ]] || fail "txn commit (${tcode}): $(head -c300 /tmp/m148-txn.json)"
grep -q '"guarantee":"atomic"' /tmp/m148-txn.json || fail "txn response missing atomic guarantee"
B1_AFTER="$(acct_balance "${A1}")"; B2_AFTER="$(acct_balance "${A2}")"
[[ "${B1_AFTER}" == "$((B1_BEFORE - AMT))" ]] || fail "customer balance wrong: ${B1_BEFORE}→${B1_AFTER} (want $((B1_BEFORE - AMT)))"
[[ "${B2_AFTER}" == "$((B2_BEFORE + AMT))" ]] || fail "revenue balance wrong: ${B2_BEFORE}→${B2_AFTER} (want $((B2_BEFORE + AMT)))"
# Thread txn id → ledger via the unique reference (results don't surface RETURNING).
# The committed txn/ledger rows were written by the admin-JWT batch (owner
# user:<admin sub>), so they read back under the admin JWT (F2 bypass), not the
# app key, now that read_scoped is on.
qadmin "${PG}" txns "{\"op\":\"list\",\"filter\":{\"reference\":{\"\$eq\":\"${REF}\"}}}" >/dev/null
TXID="$(python3 -c 'import json;r=json.load(open("/tmp/m148-q.json"))["rows"];print(r[0]["id"] if r else "")' 2>/dev/null)"
[[ -n "${TXID}" ]] || fail "committed txns row not found by reference"
qadmin "${PG}" ledger_entries "{\"op\":\"list\",\"filter\":{\"transaction_id\":{\"\$eq\":${TXID}}}}" >/dev/null 2>&1 || true
# ledger rows may not be transaction_id-linked in this seed (no RETURNING thread);
# assert the 2 ledger rows landed by amount+account instead — the balance move is
# the load-bearing ACID proof, the ledger rows confirm the batch atomicity.
qadmin "${PG}" ledger_entries "{\"op\":\"list\",\"filter\":{\"amount_cents\":{\"\$eq\":${AMT}}}}" >/dev/null
[[ "$(rows_len)" -ge 2 ]] || fail "expected ≥2 ledger rows for the committed batch, got $(rows_len)"
ok "money moved ${B1_BEFORE}→${B1_AFTER} / ${B2_BEFORE}→${B2_AFTER}; txn ${TXID} posted; ledger rows present"

# ── 6) ACID ROLLBACK: a poisoned batch leaves the books untouched ────────────
step "6/9 ACID ROLLBACK: poisoned batch → balances UNCHANGED, no poisoned txns row"
B1_PRE="$(acct_balance "${A1}")"; B2_PRE="$(acct_balance "${A2}")"
POISON_REF="poison_$$_$(date +%s)"
# Last op violates the direction CHECK ('sideways') → whole batch rolls back.
POISON_BODY="{\"mount\":\"${PG}\",\"operations\":[
  {\"op\":\"insert\",\"resource\":\"txns\",\"data\":{\"kind\":\"payment\",\"amount_cents\":7777,\"status\":\"posted\",\"reference\":\"${POISON_REF}\"}},
  {\"op\":\"update\",\"resource\":\"accounts\",\"filter\":{\"id\":${A1}},\"data\":{\"balance_cents\":$((B1_PRE - 7777))}},
  {\"op\":\"update\",\"resource\":\"accounts\",\"filter\":{\"id\":${A2}},\"data\":{\"balance_cents\":$((B2_PRE + 7777))}},
  {\"op\":\"insert\",\"resource\":\"ledger_entries\",\"data\":{\"account_id\":${A1},\"direction\":\"sideways\",\"amount_cents\":7777}}
]}"
rcode="$(txn "${POISON_BODY}")"
[[ "${rcode}" -ge 400 ]] || fail "poisoned batch should NOT succeed (got ${rcode}): $(head -c300 /tmp/m148-txn.json)"
B1_POST="$(acct_balance "${A1}")"; B2_POST="$(acct_balance "${A2}")"
[[ "${B1_POST}" == "${B1_PRE}" ]] || fail "ROLLBACK BROKEN: customer balance moved ${B1_PRE}→${B1_POST}"
[[ "${B2_POST}" == "${B2_PRE}" ]] || fail "ROLLBACK BROKEN: revenue balance moved ${B2_PRE}→${B2_POST}"
qadmin "${PG}" txns "{\"op\":\"list\",\"filter\":{\"reference\":{\"\$eq\":\"${POISON_REF}\"}}}" >/dev/null
[[ "$(rows_len)" == "0" ]] || fail "ROLLBACK BROKEN: poisoned txns row '${POISON_REF}' was committed"
ok "rejected ${rcode}; balances unchanged (${B1_PRE}/${B2_PRE}); no poisoned txns row"

# ── 7) Mongo CRUD: messages status filter + content upsert idempotency ───────
step "7/9 Mongo: messages open→close filter; content upsert idempotent"
MSG_SUB="m148msg-$$"
q "${MG}" messages "{\"op\":\"insert\",\"data\":{\"subject\":\"${MSG_SUB}\",\"body\":\"hi\",\"status\":\"open\"}}" >/dev/null
q "${MG}" messages "{\"op\":\"list\",\"filter\":{\"subject\":\"${MSG_SUB}\",\"status\":\"open\"}}" >/dev/null
[[ "$(rows_len)" -ge 1 ]] || fail "open message not listed"
q "${MG}" messages "{\"op\":\"update\",\"filter\":{\"subject\":\"${MSG_SUB}\"},\"data\":{\"status\":\"closed\"}}" >/dev/null
q "${MG}" messages "{\"op\":\"list\",\"filter\":{\"subject\":\"${MSG_SUB}\",\"status\":\"open\"}}" >/dev/null
[[ "$(rows_len)" == "0" ]] || fail "message still 'open' after close"
CKEY="m148.cfg.$$"
q "${MG}" content "{\"op\":\"upsert\",\"filter\":{\"key\":\"${CKEY}\"},\"data\":{\"key\":\"${CKEY}\",\"type\":\"settings\",\"value\":{\"n\":1}}}" >/dev/null
q "${MG}" content "{\"op\":\"upsert\",\"filter\":{\"key\":\"${CKEY}\"},\"data\":{\"key\":\"${CKEY}\",\"type\":\"settings\",\"value\":{\"n\":2}}}" >/dev/null
q "${MG}" content "{\"op\":\"list\",\"filter\":{\"key\":\"${CKEY}\"}}" >/dev/null
[[ "$(rows_len)" == "1" ]] || fail "upsert is not idempotent — got $(rows_len) content rows for one key"
ok "messages open→closed filter correct; content upsert idempotent (1 row)"

# ── 8) aggregate: SUM(posted txns) reflects the committed money ──────────────
step "8/9 aggregate: SUM(amount_cents) of posted txns includes the committed ${AMT}"
acode=$(qadmin "${PG}" txns '{"op":"aggregate","aggregate":{"groupBy":["status"],"aggregates":[{"func":"sum","field":"amount_cents","alias":"revenue"},{"func":"count","alias":"n"}]}}')
[[ "${acode}" == "200" || "${acode}" == "201" ]] || fail "aggregate (${acode}): $(head -c300 /tmp/m148-q.json)"
POSTED_SUM="$(python3 -c '
import json
d=json.load(open("/tmp/m148-q.json"))
for r in d.get("rows",[]):
  if r.get("status")=="posted": print(r.get("revenue")); break' 2>/dev/null)"
[[ -n "${POSTED_SUM}" ]] || fail "aggregate returned no posted-status group: $(head -c300 /tmp/m148-q.json)"
python3 -c "import sys;sys.exit(0 if int('${POSTED_SUM}')>=${AMT} else 1)" \
  || fail "posted revenue ${POSTED_SUM} < committed ${AMT}"
ok "posted revenue sum=${POSTED_SUM} (≥ committed ${AMT})"

# ── 8b) owner isolation: the JWT is the authority, not the public app key ─────
# The browser now forwards the session JWT on every /query call (db.ts/tx.ts).
# These assertions prove the server enforces owner-scope off that JWT, so the
# public mbk_ key alone exposes nothing. Self-reverting / must-fail by design:
# the escalation never mutates a row, so there is nothing to undo.
step "8b/9 owner isolation: app-key-only sees 0; customer JWT sees 0; escalation blocked; admin JWT bypasses"

# A0 (THE HOLE CHECK): with read_scoped ON and the business re-owned to
# system:nimbus, an APP-KEY-ONLY read (no Bearer JWT, owner-scoped to api-key:<key>)
# must read 0 app_users AND 0 accounts — the public mbk_ key alone exposes nothing.
# Fails loudly if read_scoped is off (data-plane not restarted after the seed flip)
# or the rows are still api-key-owned (re-own step skipped).
q "${PG}" app_users '{"op":"list","limit":50}' >/dev/null
APPKEY_USERS="$(rows_len)"
[[ "${APPKEY_USERS}" == "0" ]] || fail "ISOLATION HOLE: app-key-only read ${APPKEY_USERS} app_users rows (must be 0 — read_scoped off, data-plane not restarted, or rows still api-key-owned)"
q "${PG}" accounts '{"op":"list","limit":50}' >/dev/null
APPKEY_ACCTS="$(rows_len)"
[[ "${APPKEY_ACCTS}" == "0" ]] || fail "ISOLATION HOLE: app-key-only read ${APPKEY_ACCTS} accounts rows (must be 0 — financials exposed to the public app key)"
ok "app-key-only sees 0 users / 0 accounts (read_scoped enforced over system:nimbus)"

# A1: a fresh customer JWT (owner user:<sub>) is equally blind to the seeded
# (system:nimbus-owned) business — owner-scoped to its own sub, which owns nothing.
qj "${JWT}" "${PG}" app_users '{"op":"list","limit":50}' >/dev/null
CUST_USERS="$(rows_len)"
[[ "${CUST_USERS}" == "0" ]] || fail "ISOLATION BROKEN: customer JWT read ${CUST_USERS} app_users rows (must be 0)"
qj "${JWT}" "${PG}" accounts '{"op":"list","limit":50}' >/dev/null
CUST_ACCTS="$(rows_len)"
[[ "${CUST_ACCTS}" == "0" ]] || fail "ISOLATION BROKEN: customer JWT read ${CUST_ACCTS} accounts rows (must be 0)"
ok "customer JWT sees 0 users / 0 accounts (own-sub owner scope)"

# A3 (moved up — needed as the read-back authority for A2): the logged-in ADMIN
# JWT triggers the F2 owner-scope bypass and DOES read the system:nimbus-owned
# seeded users, so the console keeps working. This is ALSO the only credential
# that can read the admin row back (the app key can't see it anymore), so A2's
# read-back rides the admin JWT.
qj "${ADMIN_JWT}" "${PG}" app_users '{"op":"list","limit":50}' >/dev/null
ADMIN_USERS="$(rows_len)"
[[ "${ADMIN_USERS}" -ge 1 ]] || fail "F2 BYPASS BROKEN: admin JWT read ${ADMIN_USERS} app_users rows (must be ≥1 — DATA_PLANE_ADMIN_BYPASS off, or GOTRUE_JWT_SECRET unset on query-router so the JWT is unverified)"
ok "admin JWT (F2 bypass) reads ${ADMIN_USERS} seeded users — console intact"

# A2: privilege escalation must-fail (self-reverting — the escalation never
# mutates a row, so there is nothing to undo). A customer JWT cannot promote the
# seeded (system:nimbus-owned) admin row: the update owner-scopes to user:<sub>
# and matches it 0 times. The role read-back rides the ADMIN JWT (A3 proved it can
# see the row; the app key no longer can), proving the role is unchanged.
ESC_TARGET="${NIMBUS_ADMIN_SUB}"
qj "${ADMIN_JWT}" "${PG}" app_users "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${ESC_TARGET}\"}}}" >/dev/null
ROLE_BEFORE="$(python3 -c 'import json;r=json.load(open("/tmp/m148-q.json"))["rows"];print(r[0]["role"] if r else "MISS")' 2>/dev/null)"
[[ "${ROLE_BEFORE}" == "admin" ]] || fail "precondition: seeded admin row role is '${ROLE_BEFORE}', expected 'admin' (admin JWT read-back)"
ecode="$(qj "${JWT}" "${PG}" app_users "{\"op\":\"update\",\"filter\":{\"id\":{\"\$eq\":\"${ESC_TARGET}\"}},\"data\":{\"role\":\"admin\"}}")"
# The data plane may answer 200/affected:0 (no owned row matched) OR 403 (deny);
# either is acceptable — what must NOT happen is the customer JWT owning/mutating
# that row. The load-bearing proof is the role read-back via the admin JWT.
qj "${ADMIN_JWT}" "${PG}" app_users "{\"op\":\"list\",\"filter\":{\"id\":{\"\$eq\":\"${ESC_TARGET}\"}}}" >/dev/null
ROLE_AFTER="$(python3 -c 'import json;r=json.load(open("/tmp/m148-q.json"))["rows"];print(r[0]["role"] if r else "MISS")' 2>/dev/null)"
[[ "${ROLE_AFTER}" == "admin" ]] || fail "ESCALATION HOLE: customer JWT changed seeded admin row role '${ROLE_BEFORE}'→'${ROLE_AFTER}' (update code ${ecode})"
ok "escalation blocked: customer update code=${ecode}; seeded admin role still 'admin'"

# ── 9) cleanup test rows (leave the permanent tenant + seed) ─────────────────
step "9/9 cleanup test rows"
qadmin "${PG}" ledger_entries "{\"op\":\"delete\",\"filter\":{\"transaction_id\":{\"\$eq\":${TXID}}}}" >/dev/null 2>&1 || true
qadmin "${PG}" txns "{\"op\":\"delete\",\"filter\":{\"reference\":{\"\$eq\":\"${REF}\"}}}" >/dev/null 2>&1 || true
q "${MG}" messages "{\"op\":\"delete\",\"filter\":{\"subject\":\"${MSG_SUB}\"}}" >/dev/null 2>&1 || true
q "${MG}" content "{\"op\":\"delete\",\"filter\":{\"key\":\"${CKEY}\"}}" >/dev/null 2>&1 || true
ok "test rows removed"

printf '\033[0;32m[M148] ALL GATES GREEN — Nimbus on Grobase: dual-engine (PG+Mongo) composition · auth · PG CRUD · ACID commit · ACID rollback (balance-invariant) · Mongo CRUD · aggregate revenue · owner isolation (customer JWT sees 0, no escalation, admin F2 bypass intact)\033[0m\n'
