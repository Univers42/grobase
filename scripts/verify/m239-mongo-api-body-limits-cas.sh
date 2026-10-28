#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m239-mongo-api-body-limits-cas.sh — the per-collection JSON limit and the   #
#  PATCH compare-and-swap hold over real HTTP.                                 #
#                                                                              #
#    limits  a scratch Mongo and mongo-api (built from this commit, strict     #
#            identity, MONGO_API_BIG_COLLECTIONS=hydrawn_boards): 1 MB is      #
#            201 on hydrawn_boards for a signed-in caller, also when the name  #
#            is percent-encoded; 413 on another collection, 413 past 8 MB, and #
#            413 for an anonymous caller (the big parser runs before AuthGuard)#
#    cas     PATCH if_field=rev: 200 while rev matches, 409 once it moved,     #
#            404 on an absent id, 400 on an unsafe guard field; an unrelated   #
#            query key is ignored (200), as before the guard existed           #
#    control an anonymous small POST is 401, else the 413 above proves nothing #
#  Caveat: proves this commit's mongo-api alone; Kong and the WAF have their    #
#  own body limits in front of it, not probed here.                            #
#  Needs the mongo and node images locally (nothing pulled) and a docker build #
#  of src/; otherwise SKIP, exit 77, never 0. M239_{API,MONGO,NODE}_IMAGE      #
#  override the images.                                                        #
# **************************************************************************** #
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MONGO_IMG="${M239_MONGO_IMAGE:-mirror.gcr.io/library/mongo:7}"
NODE_IMG="${M239_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
TAG="m239gate$$"
API_IMG="${M239_API_IMAGE:-${TAG}-api}"
ISSUER="https://m239.invalid/auth/v1"

step() { printf '\033[0;36m[M239] %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33m[M239] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}
fail() {
  printf '\033[0;31m[M239] FAIL — %s\033[0m\n' "$*"
  exit 1
}
cleanup() {
  docker rm -f "${TAG}-db" "${TAG}-api" >/dev/null 2>&1 || true
  [ -n "${M239_API_IMAGE:-}" ] || docker rmi -f "${TAG}-api" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v docker >/dev/null || skip "no docker"
for img in "${MONGO_IMG}" "${NODE_IMG}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || skip "image ${img} is not local"
done
if [ -z "${M239_API_IMAGE:-}" ]; then
  step "build mongo-api from this commit"
  timeout 900 docker build -q -t "${API_IMG}" --build-arg APP=mongo-api \
    -f "${ROOT}/src/Dockerfile" "${ROOT}/src" >/dev/null || skip "mongo-api did not build"
fi

SECRET="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
# One loopback-only network namespace (the db's, --network none) holds all three
# containers: nothing is reachable from outside, and no docker network is created.
NS="container:${TAG}-db"
docker run -d --name "${TAG}-db" --network none --memory 512m "${MONGO_IMG}" --quiet \
  >/dev/null || skip "mongo did not start"
docker run -d --name "${TAG}-api" --network "${NS}" --memory 256m \
  -e PORT=3010 -e NODE_OPTIONS=--max-old-space-size=192 \
  -e MONGO_URI="mongodb://127.0.0.1:27017" -e MONGO_DB_NAME=m239 \
  -e JWT_SECRET="${SECRET}" -e GOTRUE_JWT_ISSUER="${ISSUER}" -e IDENTITY_HEADER_MODE=strict \
  -e MONGO_API_BIG_COLLECTIONS=hydrawn_boards "${API_IMG}" >/dev/null || fail "mongo-api did not start"

step "probe limits and compare-and-swap"
docker run --rm -i --network "${NS}" -e BASE="http://127.0.0.1:3010" \
  -e SECRET="${SECRET}" -e ISSUER="${ISSUER}" "${NODE_IMG}" node --input-type=module <<'JS'
import { createHmac, randomUUID } from 'node:crypto';
const { BASE, SECRET, ISSUER } = process.env;
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const head = b64({ alg: 'HS256', typ: 'JWT' });
const now = Math.floor(Date.now() / 1000);
const claims = b64({ sub: randomUUID(), role: 'authenticated', iss: ISSUER, iat: now, exp: now + 600 });
const sig = createHmac('sha256', SECRET).update(`${head}.${claims}`).digest('base64url');
const auth = { authorization: `Bearer ${head}.${claims}.${sig}` };

let failed = 0;
const expect = (label, got, want) => {
  const ok = got === want;
  if (!ok) failed++;
  console.log(`${ok ? '  ✓' : '  ✗'} ${label}: ${got}${ok ? '' : ` (want ${want})`}`);
};
const send = (method, path, body, headers = auth) =>
  fetch(`${BASE}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
const blob = (bytes) => 'x'.repeat(bytes);

for (let i = 0; i < 60; i++) {
  try {
    if ((await fetch(`${BASE}/health/live`)).ok) break;
  } catch {}
  await new Promise((r) => setTimeout(r, 1000));
}

const docs = '/collections/hydrawn_boards/documents';
expect('anonymous small POST', (await send('POST', docs, { data: {} }, {})).status, 401);
expect('anonymous 1 MB POST, big collection', (await send('POST', docs, { data: { b: blob(1e6) } }, {})).status, 413);
const created = await send('POST', docs, { data: { rev: 0, b: blob(1e6) } });
expect('signed-in 1 MB POST, big collection', created.status, 201);
expect('signed-in 1 MB POST, encoded name', (await send('POST', '/collections/hydrawn%5Fboards/documents', { data: { b: blob(1e6) } })).status, 201);
expect('signed-in 1 MB POST, other collection', (await send('POST', '/collections/notes/documents', { data: { b: blob(1e6) } })).status, 413);
expect('signed-in 9 MB POST, big collection', (await send('POST', docs, { data: { b: blob(9 * 1024 * 1024) } })).status, 413);

const id = created.ok ? (await created.json()).id : '000000000000000000000000';
const patch = (query, rev) => send('PATCH', `${docs}/${id}?${query}`, { patch: { rev } });
expect('PATCH rev 0 -> 1', (await patch('if_field=rev&if_value=0', 1)).status, 200);
expect('PATCH stale rev 0', (await patch('if_field=rev&if_value=0', 2)).status, 409);
expect('PATCH with an unrelated query key', (await patch('if_field=rev&if_value=1&cache_bust=7', 2)).status, 200);
expect('PATCH unsafe guard field', (await patch('if_field=__proto__&if_value=2', 3)).status, 400);
expect('PATCH absent id', (await send('PATCH', `${docs}/${'0'.repeat(24)}?if_field=rev&if_value=2`, { patch: { rev: 3 } })).status, 404);
process.exit(failed === 0 ? 0 : 1);
JS
rc=$?
[ "${rc}" -eq 0 ] || {
  docker logs --tail 20 "${TAG}-api" 2>&1 | sed 's/^/    /'
  fail "the limit or compare-and-swap matrix does not hold"
}
step "PASS"
