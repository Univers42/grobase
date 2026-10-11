#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m221-waf-app-content.sh — what a user typed reaches the app's tables; the  #
#  same text anywhere else is still an attack                                #
#                                                                              #
#  osionos stores page blocks, chat messages and comments in osionos_* tables  #
#  through PostgREST. A code block holding `console.log(` scored 15 (CRS       #
#  934100 + 941390) and every save of that page was refused (2026-10-11, VM    #
#  WAF log). Rule 10110 (infra/docker/services/waf/conf/exclusions.conf)       #
#  lifts the injection families' ARGS inspection on WRITES to those tables     #
#  only. It boots the WAF image with the tree's exclusions file on a private   #
#  network whose `kong` answers 200, then:                                     #
#    CONTENT   POST/PATCH to osionos_pages / osionos_chat_messages carrying JS, #
#              SQL, XSS, shell, PHP, ../, {{ }}, a metadata URL → 200          #
#    CONTROLS  the same path read with SQLi in its query string, written with  #
#              <script> in a header or a method `PO`; the same body to another #
#              table, to an rpc, and through osionos_pages%3F/../secrets       #
#              (%3f, %253F) → 403, and the upstream never sees `secrets`       #
#    MUTANT    the file without rule 10110 MUST refuse the code block, else    #
#              the probe is blind and the gate fails                            #
#  Needs docker, the WAF image and node:20-alpine already present (nothing is  #
#  pulled); otherwise SKIP, exit 77, never 0. A throwaway TLS pair is minted   #
#  in the temp dir. Containers, network and temp dir go in an EXIT trap.       #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WAF_CONF="${ROOT}/infra/docker/services/waf/conf"
EXCL="${M221_EXCLUSIONS:-${WAF_CONF}/exclusions.conf}"
WAF_IMG="${M221_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M221_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
CRS_EXCL=/etc/modsecurity.d/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf
TAG="m221gate$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M221] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M221] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup: remove every container, the network and the temp dir this run made.
cleanup() {
  docker rm -f "${TAG}-kong" "${TAG}-waf" "${TAG}-mut" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# preconditions: docker, both images present locally, the files under test, openssl.
preconditions() {
  command -v docker >/dev/null 2>&1 || skip "docker is not available"
  command -v openssl >/dev/null 2>&1 || skip "openssl is not available"
  docker image inspect "${WAF_IMG}" >/dev/null 2>&1 || skip "${WAF_IMG} is not present (make build-svc-waf)"
  docker image inspect "${NODE_IMG}" >/dev/null 2>&1 || skip "${NODE_IMG} is not present"
  [ -f "${EXCL}" ] && [ -f "${WAF_CONF}/nginx.conf" ] || skip "${EXCL} or nginx.conf not found"
}

# start_waf NAME EXCLUSIONS: boot the WAF with the tree's nginx.conf and EXCLUSIONS as CRS's
# REQUEST-900 file; wait for /waf-health. nginx (uid 101) reads the throwaway key, hence 0644.
# conf.d is a directory mount: the entrypoint rewrites default.conf with `sed -i` (see m198).
start_waf() {
  local name="$1" dir="${WORK}/confd-$1" i
  mkdir -p "${dir}" && cp "${WAF_CONF}/nginx.conf" "${dir}/default.conf" && chmod -R a+rwX "${dir}"
  cp "$2" "${WORK}/excl-$1.conf" && chmod 0644 "${WORK}/excl-$1.conf"
  docker run -d --name "${name}" --network "${NET}" \
    -v "${dir}:/etc/nginx/conf.d" \
    -v "${WORK}/excl-$1.conf:${CRS_EXCL}:ro" \
    -v "${WORK}/tls.pem:/run/secrets/localhost_cert:ro" \
    -v "${WORK}/tls-key.pem:/run/secrets/localhost_key:ro" \
    "${WAF_IMG}" >/dev/null || return 1
  for i in $(seq 1 60); do
    docker exec "${TAG}-kong" wget -qO- "http://${name}/waf-health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "${name}" 2>&1 | grep -E 'Rules error|emerg' | tail -3 >&2
  return 1
}

# probe WAF: send every probe through WAF:80 from the upstream container; print one
# "<status> <label>" line each. A null body sends `<script>` in a header instead.
probe() {
  docker exec -e WAF="$1" "${TAG}-kong" node -e '
    const http = require("http");
    const send = (method, path, body) => new Promise((done) => {
      const data = body ? JSON.stringify(body) : "";
      const extra = body === null ? { "X-Note": "<script>alert(document.cookie)</script>" } : {};
      const r = http.request({ host: process.env.WAF, port: 80, method, path, headers: { Host: "localhost",
        "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), ...extra } },
        (s) => { s.resume(); s.on("end", () => done(s.statusCode)); });
      r.on("error", (e) => done("error:" + e.code));
      r.end(data);
    });
    const code = { content: [{ type: "code", content: "console.log(\"hi\"); fetch(url).then((r) => r.json())" }] };
    const prose = { title: "select * from users where id = \u00271\u0027 or \u00271\u0027=\u00271\u0027",
      content: [{ content: "<script>alert(1)</script> $(rm -rf /) <?php system($_GET[\"x\"]); ?> ../../etc/passwd {{7*7}} http://169.254.169.254/latest/meta-data/" }] };
    const probes = [
      ["content-post-code", "POST", "/rest/v1/osionos_pages", code],
      ["content-patch-code", "PATCH", "/rest/v1/osionos_pages?id=eq.6f1c0f5e-0000-4000-8000-000000000001", code],
      ["content-post-prose", "POST", "/rest/v1/osionos_pages", prose],
      ["content-chat-code", "POST", "/rest/v1/osionos_chat_messages", { body: "console.log(x)" }],
      ["control-read-sqli", "GET", "/rest/v1/osionos_pages?title=eq.1%27%20or%20%271%27=%271", undefined],
      ["control-header-xss", "POST", "/rest/v1/osionos_pages", null],
      ["control-other-table", "POST", "/rest/v1/secrets", code],
      ["control-rpc", "POST", "/rest/v1/rpc/osionos_x", code],
      ["control-encoded-3F", "POST", "/rest/v1/osionos_pages%3F/../secrets", code],
      ["control-encoded-3f", "POST", "/rest/v1/osionos_pages%3f/../secrets", code],
      ["control-encoded-253F", "POST", "/rest/v1/osionos_pages%253F/../secrets", code],
      ["control-method-PO", "PO", "/rest/v1/osionos_pages", code],
    ];
    (async () => { for (const [label, m, p, b] of probes) console.log((await send(m, p, b)) + " " + label); })();'
}

# expect_all RESULTS PREFIX STATUS: every probe whose label starts with PREFIX answered STATUS.
expect_all() {
  local line got n=0
  while read -r got line; do
    case "${line}" in "$2"*) ;; *) continue ;; esac
    n=$((n + 1))
    if [ "${got}" = "$3" ]; then ok "${line}: ${got}"; else bad "${line}: ${got}, want $3"; fi
  done <<<"$1"
  [ "${n}" -gt 0 ] || bad "no '$2' probe ran"
}

step "0/4 preconditions"
preconditions
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "${WORK}/tls-key.pem" -out "${WORK}/tls.pem" >/dev/null 2>&1 && chmod 0644 "${WORK}"/tls*.pem ||
  skip "could not mint a throwaway TLS pair"
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  require("http").createServer((q, r) => { console.log(q.method + " " + q.url); q.resume(); q.on("end", () => r.end("upstream")); }).listen(8000);' >/dev/null ||
  skip "could not start the upstream"

step "1/4 WAF with ${EXCL#"${ROOT}"/}"
start_waf "${TAG}-waf" "${EXCL}" || {
  bad "the WAF did not become healthy with this exclusions file"
  exit 1
}
results="$(probe "${TAG}-waf")"
step "2/4 what a user typed reaches the app's tables"
expect_all "${results}" content- 200
step "3/4 the same text anywhere else is still refused"
expect_all "${results}" control- 403
if docker logs "${TAG}-kong" 2>&1 | grep -q secrets; then
  bad "the upstream received a request for /rest/v1/secrets — the exclusion opened a path past the WAF"
else
  ok "the upstream never received a request for /rest/v1/secrets"
fi

step "4/4 mutant: without rule 10110 the code block MUST be refused"
awk '/^SecRule REQUEST_FILENAME "@rx \^\/rest\/v1\/osionos_/ { skip = 1 } skip && /^$/ { skip = 0 } !skip' "${EXCL}" >"${WORK}/mutant.conf"
if cmp -s "${EXCL}" "${WORK}/mutant.conf" || grep -q 'id:10110' "${WORK}/mutant.conf"; then
  bad "mutant: rule 10110 was not found as one block — rebuild this leg"
elif ! start_waf "${TAG}-mut" "${WORK}/mutant.conf"; then
  bad "mutant: the WAF did not start without rule 10110"
else
  got="$(probe "${TAG}-mut" | awk '$2 == "content-post-code" { print $1 }')"
  [ "${got}" = 403 ] && ok "mutant refuses the code block (403) — the probe sees the false positive" ||
    bad "mutant answered '${got}' to the code block, not 403 — the probe is blind"
fi

[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M221] FAIL — app content is refused, or the exclusion reaches past writes to osionos_* tables\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M221] PASS — writes to osionos_* carry code; reads, headers, other tables and rpcs stay inspected\033[0m\n'
