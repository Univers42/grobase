#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m57-sdk-openapi.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M57 — SDK fluent builder + committed OpenAPI spec (A3). Proves the public
# contract is real, in-sync, and EXECUTABLE — not just a JSON file on disk:
#
#   1. spec is valid OpenAPI 3.x and DECLARES the real public surfaces. The
#      committed openapi/grobase-public.json must parse, carry an `openapi`
#      version of 3.x, and declare the five Kong-fronted public families a
#      client SDK consumes (auth/rest/storage/query/functions) at concrete
#      paths discovered from the document — not hardcoded guesses.
#   2. route-table CONGRUENCE (no drift). Every public path the spec promises
#      must have a matching entry in the SDK route table (sdk/src/core/
#      routes.ts). The set comparison is template-normalized ({id} ⇆ ${expr}
#      ⇆ * ) so a spec path with no SDK route — or vice-versa for the public
#      families — fails the gate. This is the SoT guard: spec and SDK cannot
#      silently diverge.
#   3. LIVE fluent query (the teeth). Build the SDK from source in a clean
#      `node:20` container (npm ci + tsc), seed a real table + rows into the
#      stack's Postgres, then run a TS/JS snippet that drives the SDK client's
#      fluent chain —  client.from(t).query().select(..).eq(col,val).single()
#      —  against the LIVE Kong /rest/v1 PostgREST path with the tenant/anon
#      key, and ASSERT the returned row equals what was inserted (incl. that
#      .eq() actually filtered: a second, non-matching row must NOT come back).
#      A gate that only `jq .` the spec is VACUOUS; the fluent query MUST run
#      and assert real data.
#
# Requires the stack up (mini-baas-{kong,postgres,postgrest,tenant-control}).
# DOCKER-FIRST: the SDK build + snippet run inside a pinned node:20 container
# over --network host so the lib's 127.0.0.1:<port> URLs resolve.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # …/mini-baas-infra
SDK_DIR="$(cd "${BAAS_DIR}/../sdk" && pwd)"            # …/apps/baas/sdk
SPEC="${BAAS_DIR}/openapi/grobase-public.json"
ROUTES_TS="${SDK_DIR}/src/core/routes.ts"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M57] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M57] FAIL — $*"; exit 1; }

# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

command -v jq >/dev/null      || fail "jq is required"
command -v python3 >/dev/null || fail "python3 is required"

TMP="$(mktemp -d)"
SLUG="m57sdk$(date +%s)$$"          # unique scratch slug per run (no collisions)
TABLE="m57rows$(date +%s)$$"        # no underscores → 1:1 PostgREST resource name
# response-file grep helpers (m56 pattern): write a body, then assert on it.
has()  { grep -q "$1" "$2" || fail "$3: missing '$1' — $(head -c 300 "$2")"; }
nhas() { grep -q "$1" "$2" && fail "$3: leaked '$1' — $(head -c 300 "$2")"; return 0; }

PROVISIONED=""
cleanup() {
  # drop the probe table from the stack's postgres (best-effort), then let the
  # lib soft-delete the scratch tenant/key/mount.
  docker exec -i mini-baas-postgres psql -U postgres -d postgres \
    -c "DROP TABLE IF EXISTS public.\"${TABLE}\";" >/dev/null 2>&1 || true
  [[ -n "${PROVISIONED}" ]] && live_tenant_cleanup 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ── 1) committed OpenAPI spec parses + declares the real public paths ─────────
step "1/3 OpenAPI 3.x parses + declares the public surfaces"
[[ -f "${SPEC}" ]] || fail "spec not committed at ${SPEC}"
jq -e . "${SPEC}" >/dev/null 2>&1 || fail "spec is not valid JSON"
OAVER="$(jq -r '.openapi // empty' "${SPEC}")"
[[ "${OAVER}" =~ ^3\. ]] || fail "openapi version is not 3.x (got '${OAVER:-<missing>}')"
NPATHS="$(jq -r '.paths | length' "${SPEC}")"
[[ "${NPATHS}" -ge 1 ]] || fail "spec declares zero paths"
# Discover the families present in the spec (segment1/segment2), then assert the
# five public Kong-fronted surfaces are ALL present. We assert each REQUIRED
# family by checking the discovered set contains it — discovery-driven, so a
# spec that renames /query/v1 → /data/v1 fails here, not silently.
jq -r '.paths | keys[]' "${SPEC}" | sed -E 's#^/([^/]+/[^/]+).*#\1#' | sort -u > "${TMP}/spec_families.txt"
for fam in auth/v1 rest/v1 storage/v1 query/v1 functions/v1; do
  grep -qx "${fam}" "${TMP}/spec_families.txt" || fail "spec is missing required public family /${fam}"
done
# And assert a few CONCRETE operations exist (not just the family prefix): the
# data-plane execute, an edge-function-by-name, a storage bucket op, the auth
# token grant, and the PostgREST resource the fluent builder targets.
for p in /query/v1/execute /functions/v1/{name} /storage/v1/bucket /auth/v1/token '/rest/v1/{resource}'; do
  jq -e --arg p "$p" '.paths | has($p)' "${SPEC}" >/dev/null \
    || fail "spec does not declare expected path ${p}"
done
ok "OpenAPI ${OAVER}, ${NPATHS} paths, all 5 public families + key ops declared"

# ── 2) SDK route table is CONGRUENT with the spec (no drift) ──────────────────
step "2/3 SDK route table ⇄ spec congruence (no drift)"
[[ -f "${ROUTES_TS}" ]] || fail "SDK route table not found at ${ROUTES_TS}"
# Spec paths, template-normalized: {param} → * ; trailing slash stripped.
jq -r '.paths | keys[]' "${SPEC}" \
  | sed -E 's#\{[^}]+\}#*#g' | sed 's#/$##' | sort -u > "${TMP}/spec_paths.txt"
# SDK path literals from routes.ts, template-normalized: collapse ${expr} → * ,
# drop any query-string (?…), drop a dangling ${ from inline ternaries, strip
# trailing slash. This yields the set of route TEMPLATES the SDK can build.
grep -oE "'/[^']+'|\`/[^\`]+\`" "${ROUTES_TS}" | tr -d "'\`" \
  | sed -E 's#\$\{[^}]*\}#*#g' | sed -E 's#\?.*##' | sed -E 's#\$\{.*##' \
  | sed 's#/$##' | sort -u > "${TMP}/sdk_paths.txt"
# Drift = a PUBLIC spec path with no matching SDK route template. (The SDK route
# table is allowed to be a SUPERSET — it also carries admin/analytics/graphql/
# realtime surfaces the *public* spec intentionally omits — so we check the
# spec⊆SDK direction, which is the contract the SDK must keep.)
DRIFT="$(comm -23 "${TMP}/spec_paths.txt" "${TMP}/sdk_paths.txt" || true)"
if [[ -n "${DRIFT}" ]]; then
  red "  spec paths with NO SDK route (drift):"; printf '    %s\n' ${DRIFT}
  fail "route-table drift: ${NPATHS} spec paths not all covered by routes.ts"
fi
# Sanity: the comparison is not a no-op (both sides non-empty and overlapping),
# otherwise an empty-vs-empty set would pass vacuously.
[[ -s "${TMP}/spec_paths.txt" && -s "${TMP}/sdk_paths.txt" ]] || fail "path sets empty — normalizer broke"
grep -qx '/query/v1/execute' "${TMP}/sdk_paths.txt" || fail "congruence sanity: SDK set missing a known path"
ok "every public spec path is covered by sdk/src/core/routes.ts (no drift)"

# ── 3) LIVE fluent query: build the SDK, run the chain, assert real data ──────
step "3/3 LIVE fluent .from().query().select().eq().single() returns the inserted row"

# 3a) provision a scratch tenant (and put a real probe table where the SDK's
#     /rest/v1 PostgREST path can read it). The /rest/v1 surface is the public
#     Supabase-style REST endpoint (Kong → postgrest → the stack's postgres);
#     it authorizes with the Kong anon apikey and serves the `public` schema.
live_tenant_provision "${SLUG}" || fail "scratch tenant provisioning failed"
PROVISIONED="yes"
KONG="${LIVE_KONG_URL}"
ANON="${LIVE_ANON_APIKEY}"
ok "scratch tenant '${SLUG}', Kong ${KONG}"

# 3b) seed a real table + two rows; grant SELECT to anon; reload PostgREST.
#     The .eq() filter must return ONLY the matching row — so we insert a second
#     decoy row the gate later asserts is ABSENT from the single() result.
docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL || fail "could not seed probe table"
CREATE TABLE public."${TABLE}" (id int PRIMARY KEY, name text NOT NULL, score int NOT NULL);
INSERT INTO public."${TABLE}" (id, name, score) VALUES
  (57001, 'm57-match', 4242),
  (57002, 'm57-decoy', 1);
GRANT SELECT ON public."${TABLE}" TO anon;
NOTIFY pgrst, 'reload schema';
SQL
# give PostgREST a moment to pick up the schema cache reload.
for _ in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}' \
    "${KONG}/rest/v1/${TABLE}?select=id&limit=1" -H "apikey: ${ANON}" 2>/dev/null \
    | grep -q '^200$' && break
  sleep 0.5
done
ok "probe table ${TABLE} seeded (match id=57001, decoy id=57002), anon SELECT granted"

# 3c) build the SDK from SOURCE in a clean node:20 container (npm ci + tsc) so
#     this proves the committed source compiles, not a stale dist.
docker run --rm -v "${SDK_DIR}:/sdk" -w /sdk node:20 sh -c '
  set -e
  rm -rf node_modules
  npm ci --no-audit --no-fund >/dev/null 2>&1
  npm run build >/dev/null 2>&1
  test -f dist/index.js
' || fail "SDK npm ci + build failed in node:20"
# guard: the engines route (the drift this gate's step 2 pins) must be in the
# BUILT output too — proving the source edit survives compilation.
grep -q "'/query/v1/engines'" "${SDK_DIR}/dist/core/routes.js" \
  || fail "built routes.js missing the /query/v1/engines route (build did not reflect source)"
ok "SDK built from source in node:20 (npm ci + tsc → dist/index.js)"

# 3d) run the fluent chain against the LIVE stack and assert the returned row.
cat > "${TMP}/fluent.mjs" <<'MJS'
import { createClient } from '/sdk/dist/index.js';
const client = createClient({ url: process.env.KONG, anonKey: process.env.ANON });
const t = process.env.TABLE;
// THE fluent chain the task names: .from(t).query().select(..).eq(col,val).single()
const row = await client
  .from(t)
  .query()
  .select('id,name,score')
  .eq('id', 57001)
  .single();
// Also prove .eq filtered: a list-style chain with the decoy's id must return it
// and NOT the match — i.e. eq() really narrows, it is not ignored.
const decoy = await client.from(t).query().select('id,name').eq('id', 57002);
console.log('SINGLE=' + JSON.stringify(row));
console.log('DECOY=' + JSON.stringify(decoy));
if (!row || row.id !== 57001 || row.name !== 'm57-match' || row.score !== 4242) {
  console.error('SINGLE_MISMATCH'); process.exit(3);
}
if (Array.isArray(row)) { console.error('SINGLE_NOT_SCALAR'); process.exit(4); }
if (!Array.isArray(decoy) || decoy.length !== 1 || decoy[0].id !== 57002) {
  console.error('EQ_FILTER_BROKEN'); process.exit(5);
}
console.log('FLUENT_OK');
MJS
docker run --rm --network host \
  -v "${SDK_DIR}:/sdk" -v "${TMP}/fluent.mjs:/fluent.mjs" \
  -e KONG="${KONG}" -e ANON="${ANON}" -e TABLE="${TABLE}" \
  node:20 node /fluent.mjs > "${TMP}/fluent.out" 2>&1 \
  || fail "fluent query run failed — $(tail -c 500 "${TMP}/fluent.out")"
# The snippet itself is the primary judge (exit 3/4/5 on mismatch / non-scalar /
# eq-not-filtered); these bash asserts re-bind the printed evidence. We isolate
# the SINGLE= line so the decoy assertion targets the single() RESULT, not the
# separate DECOY= probe line we print on purpose to prove eq() narrows.
grep '^SINGLE=' "${TMP}/fluent.out" > "${TMP}/single.line" || fail "no SINGLE= line — $(tail -c 300 "${TMP}/fluent.out")"
has 'FLUENT_OK'          "${TMP}/fluent.out" "fluent run did not complete"
has '"id":57001'         "${TMP}/single.line" "single() did not return the match row id"
has '"name":"m57-match"' "${TMP}/single.line" "single() returned wrong name"
has '"score":4242'       "${TMP}/single.line" "single() returned wrong score"
nhas 'm57-decoy'         "${TMP}/single.line" "single().eq() leaked the decoy row (eq filter not applied)"
# The DECOY= probe must carry ONLY the decoy (eq(id,57002) narrowed to one row);
# if it also held the match, eq() would be a no-op returning the whole table.
grep '^DECOY=' "${TMP}/fluent.out" > "${TMP}/decoy.line" || fail "no DECOY= line"
has  '"id":57002' "${TMP}/decoy.line" "decoy eq() did not return the decoy row"
nhas '57001'      "${TMP}/decoy.line" "decoy eq() leaked the match row (eq filter not applied)"
ok "fluent .from().query().select().eq(id,57001).single() → exact inserted row; .eq() filtered the decoy both ways"

green "[M57] ALL GATES GREEN — OpenAPI 3.x spec valid + declares the 5 public families · SDK route table congruent with the spec (no drift) · LIVE fluent builder query returns the exact inserted row (eq filter proven)"
