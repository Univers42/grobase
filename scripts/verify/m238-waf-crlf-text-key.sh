#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m238-waf-crlf-text-key.sh — a CR/LF in a text key never splits a response   #
#  header, now that rule 10110 lets CRS 921120 pass app writes (m227).         #
#                                                                              #
#    live    a throwaway WAF (the tree's nginx.conf + exclusions.conf) → Kong  #
#            (repo kong.yml) → PostgREST (repo image) → scratch Postgres with  #
#            osionos_probe (text key) and osionos_probe_pair (composite key):  #
#            POST return=headers-only/representation/minimal, an on_conflict   #
#            upsert, a composite key and a PATCH, each value holding           #
#            "\r\nSet-Cookie:" — every answer is 2xx with no Set-Cookie, no    #
#            injected header and no bare LF in the head; Location keeps the    #
#            key percent-encoded                                               #
#    control a raw upstream that does split its Location header must be        #
#            flagged by the same check, else the check is blind                #
#  Caveat: proves the PostgREST, Kong and WAF images of this commit only; a    #
#  route that reflects body text into a header elsewhere is not probed.        #
#  Needs jq, the kong, waf and postgrest images, the Postgres image and        #
#  node:20-alpine locally (nothing pulled); otherwise SKIP, exit 77, never 0.  #
#  M238_{KONG,WAF,REST,PG,NODE}_IMAGE override the images.                     #
# **************************************************************************** #
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/lib-kong-scratch.sh
. "${ROOT}/scripts/lib/lib-kong-scratch.sh"
WAF_CONF="${ROOT}/infra/docker/services/waf/conf"
CRS_EXCL=/etc/modsecurity.d/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf
PG_IMG="${M238_PG_IMAGE:-mirror.gcr.io/library/postgres:16-alpine}"
NODE_IMG="${M238_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
TAG="m238gate$$"
WORK="$(mktemp -d)"

step() { printf '\033[0;36m[M238] %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33m[M238] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}
fail() {
  printf '\033[0;31m[M238] FAIL — %s\033[0m\n' "$*"
  exit 1
}
cleanup() {
  docker rm -f "${TAG}-db" "${TAG}-rest" "${TAG}-kong" "${TAG}-waf" >/dev/null 2>&1 || true
  docker network rm "${TAG}-net" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# image_of prints M238_<$2>_IMAGE, else the image the base compose files name for service $1.
image_of() {
  local override="M238_$2_IMAGE"
  [ -z "${!override:-}" ] || {
    printf '%s\n' "${!override}"
    return
  }
  (cd "${ROOT}" && docker compose config --format json) | jq -r ".services.$1.image"
}

# The client: every case goes over a raw socket so the head is read byte for
# byte, not through a parser that would fold or reject a split line. With
# CONTROL set it asks a local upstream that splits its header and expects the
# check to flag it.
# shellcheck disable=SC2016 # the node program is single-quoted on purpose.
CLIENT='
const net = require("net");
const send = (host, port, method, path, prefer, body) => new Promise(done => {
  const b = JSON.stringify(body);
  const s = net.connect(port, host, () => s.write(`${method} /rest/v1/${path} HTTP/1.1\r\nHost: probe\r\n` +
    `apikey: scratch-anon\r\nContent-Type: application/json\r\nPrefer: ${prefer}\r\n` +
    `Content-Length: ${Buffer.byteLength(b)}\r\nConnection: close\r\n\r\n${b}`));
  let d = ""; s.on("data", c => d += c); s.on("end", () => done(d)); s.on("error", e => done("ERR " + e.message));
});
const split = head => {
  const lines = head.split("\r\n");
  return lines.filter(l => /^(set-cookie|x-evil)\s*:/i.test(l)).length > 0 || /[^\r]\n/.test(head);
};
const cases = [
  ["POST", "osionos_probe", "return=headers-only", { token: "a\r\nSet-Cookie: x=1", v: "b" }],
  ["POST", "osionos_probe", "return=representation", { token: "c\r\nSet-Cookie: x=2", v: "b" }],
  ["POST", "osionos_probe", "return=minimal", { token: "d\nSet-Cookie: x=3", v: "b" }],
  ["POST", "osionos_probe?on_conflict=token", "resolution=merge-duplicates,return=headers-only",
    { token: "a\r\nSet-Cookie: x=1", v: "e\r\nSet-Cookie: x=4" }],
  ["POST", "osionos_probe_pair", "return=headers-only", { a: "x\r\nSet-Cookie: y=1", b: "c\nX-Evil: 1", v: "z" }],
  ["PATCH", "osionos_probe?token=eq.d", "return=headers-only", { v: "f\r\nSet-Cookie: x=5" }],
];
(async () => {
  if (process.env.CONTROL) {
    net.createServer(c => c.end("HTTP/1.1 201 Created\r\nLocation: /t?token=eq.a\r\nSet-Cookie: x=1\r\n\r\n")).listen(9000);
    const r = await send("127.0.0.1", 9000, "POST", "t", "return=headers-only", { token: "a" });
    console.log(split(r.split("\r\n\r\n")[0]) ? "CONTROL_FLAGGED" : "CONTROL_MISSED");
    process.exit(0);
  }
  let bad = 0;
  for (const [m, p, pr, body] of cases) {
    const r = await send(process.env.WAF, 80, m, p, pr, body);
    const head = r.split("\r\n\r\n")[0], status = head.split("\r\n")[0];
    const ok = /^HTTP\/1\.1 2\d\d/.test(status) && !split(head);
    if (!ok) bad++;
    console.log(`${ok ? "ok" : "BAD"} ${m} ${p} (${pr}): ${status}`);
  }
  console.log(bad ? `CASES_BAD ${bad}` : "CASES_OK");
})();'

command -v jq >/dev/null || skip "jq is required"
command -v openssl >/dev/null || skip "openssl is required"
KONG_IMG="$(image_of kong KONG)" WAF_IMG="$(image_of waf WAF)" REST_IMG="$(image_of postgrest REST)"
for img in "${KONG_IMG}" "${WAF_IMG}" "${REST_IMG}" "${PG_IMG}" "${NODE_IMG}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || skip "${img} not present locally"
done
docker network create --internal "${TAG}-net" >/dev/null || skip "cannot create the network"

step "1/3 boot: scratch Postgres → PostgREST → Kong → WAF"
docker run -d --name "${TAG}-db" --network "${TAG}-net" -e POSTGRES_PASSWORD=scratch \
  --entrypoint docker-entrypoint.sh "${PG_IMG}" postgres >/dev/null || skip "could not start postgres"
for _ in $(seq 1 60); do
  docker exec "${TAG}-db" psql -U postgres -qc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
docker exec -i "${TAG}-db" psql -U postgres -v ON_ERROR_STOP=1 -q >/dev/null <<'SQL' || skip "could not create the probe tables"
create role anon nologin;
create table public.osionos_probe (token text primary key, v text);
create table public.osionos_probe_pair (a text, b text, v text, primary key (a, b));
grant all on public.osionos_probe, public.osionos_probe_pair to anon;
SQL
docker run -d --name "${TAG}-rest" --network "${TAG}-net" --network-alias postgrest \
  -e PGRST_DB_URI="postgres://postgres:scratch@${TAG}-db:5432/postgres" -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_DB_SCHEMAS=public "${REST_IMG}" >/dev/null || skip "could not start postgrest"
kong_scratch_start "${TAG}-kong" "${KONG_IMG}" "${TAG}-net" --network-alias kong || skip "could not start kong"
kong_scratch_wait "${TAG}-kong" || skip "kong never served :8000"
mkdir -p "${WORK}/confd" && cp "${WAF_CONF}/nginx.conf" "${WORK}/confd/default.conf" && chmod -R a+rwX "${WORK}/confd"
cp "${WAF_CONF}/exclusions.conf" "${WORK}/excl.conf"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 1 \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" >/dev/null 2>&1 || skip "openssl could not mint a cert"
# nginx (uid 101) reads the throwaway key and the exclusions, hence 0644.
chmod 0644 "${WORK}/excl.conf" "${WORK}/key.pem" "${WORK}/cert.pem"
docker run -d --name "${TAG}-waf" --network "${TAG}-net" -v "${WORK}/confd:/etc/nginx/conf.d" \
  -v "${WORK}/excl.conf:${CRS_EXCL}:ro" -v "${WORK}/cert.pem:/run/secrets/localhost_cert:ro" \
  -v "${WORK}/key.pem:/run/secrets/localhost_key:ro" "${WAF_IMG}" >/dev/null || skip "could not start the waf"
for _ in $(seq 1 60); do
  docker exec "${TAG}-kong" bash -c "exec 3<>/dev/tcp/${TAG}-waf/80" 2>/dev/null && break
  sleep 1
done

step "2/3 live: CR/LF text keys through the whole chain"
out="$(docker run --rm --network "${TAG}-net" -e WAF="${TAG}-waf" "${NODE_IMG}" node -e "${CLIENT}" 2>&1)"
printf '%s\n' "${out}" | sed 's/^/  /'
grep -qx CASES_OK <<<"${out}" || fail "a CR/LF key was refused or split a header (above)"

step "3/3 control: a split header upstream must be flagged"
out="$(docker run --rm --network none -e CONTROL=1 "${NODE_IMG}" node -e "${CLIENT}" 2>&1)"
grep -qx CONTROL_FLAGGED <<<"${out}" || fail "the split-header check missed a split Location (${out:0:80}) — it is blind"
printf '\033[0;32m[M238] PASS — CR/LF in text keys reaches the database and never splits a header\033[0m\n'
