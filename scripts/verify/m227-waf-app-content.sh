#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m227-waf-app-content.sh — what a user typed reaches the app's tables; the   #
#  same text anywhere else is still an attack                                  #
#                                                                              #
#  osionos stores page blocks, chat messages and comments in osionos_* tables  #
#  through PostgREST. A code block holding `console.log(` scored 15 (CRS       #
#  934100 + 941390) and every save of that page was refused (2026-10-11, VM    #
#  WAF log). Rule 10110 (infra/docker/services/waf/conf/exclusions.conf)       #
#  lifts the injection families' ARGS inspection on WRITES to those tables     #
#  only; rule 10120 on POST /admin/v1/migrate, whose body is SQL (942350       #
#  read `; INSERT INTO` as injection, 2026-10-12). It boots the WAF image      #
#  with the tree's exclusions file on a private network whose `kong`           #
#  answers 200, then:                                                          #
#    CONTENT   POST/PATCH to osionos_pages / osionos_chat_messages carrying JS,#
#              SQL, XSS, shell, PHP, ../, {{ }}, a metadata URL → 200          #
#              and a profile key on osionos_bridge_identities (930120 read     #
#              `json.profile.headline` as the file .profile) → 200             #
#              and a migration of DDL + INSERTs to /admin/v1/migrate → 200     #
#    CONTROLS  the same path read with SQLi in its query string, written with  #
#              <script> in a header or a method `PO`; the same body to another #
#              table, to an rpc, and through osionos_pages%3F/../secrets       #
#              (%3f, %253F) → 403, and the upstream never sees `secrets`;      #
#              the migration as a PUT, to /admin/v1/migrate-x, …/migrate/,     #
#              …/migrate%3F/../tenants or /admin/v1/tenants → 403              #
#    AUDIT     every probe carries a marker apikey and Bearer token; the       #
#              audit entries (stdout, shipped to Loki) must not hold it        #
#    MUTANTS   the file without rule 10110 MUST refuse the code block and the  #
#              profile, without rule 10120 the migration, and audit parts      #
#              ABIJDEFHZ MUST leak the marker; else the gate is blind and fails#
#  Needs docker, the WAF image and node:20-alpine already present (nothing is  #
#  pulled); otherwise SKIP, exit 77, never 0. A throwaway TLS pair is minted   #
#  in the temp dir. Containers, network and temp dir go in an EXIT trap.       #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WAF_CONF="${ROOT}/infra/docker/services/waf/conf"
EXCL="${M227_EXCLUSIONS:-${WAF_CONF}/exclusions.conf}"
WAF_IMG="${M227_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M227_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
CRS_EXCL=/etc/modsecurity.d/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf
TAG="m227gate$$"
# Sent as every probe's apikey and Bearer token: the audit log must never hold it.
MARKER="m227-credential-marker-$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0

ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
bad() {
  printf '\033[0;31m  ✗ %s\033[0m\n' "$*"
  FAILED=1
}
step() { printf '\033[0;36m[M227] %s\033[0m\n' "$*"; }

# skip REASON: print why nothing was proven and exit 77 (a gate that did not look has not passed).
skip() {
  printf '\033[0;33m[M227] SKIP — %s; nothing proven\033[0m\n' "$*"
  exit 77
}

# cleanup: remove every container, the network and the temp dir this run made.
cleanup() {
  docker rm -f "${TAG}-kong" "${TAG}-waf" "${TAG}-mut10110" "${TAG}-mut10120" "${TAG}-mutaudit" >/dev/null 2>&1 || true
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

# start_waf NAME EXCLUSIONS [VAR=VALUE]: boot the WAF with the tree's nginx.conf and EXCLUSIONS
# as CRS's REQUEST-900 file, and the optional environment override; wait for /waf-health.
# nginx (uid 101) reads the throwaway key, hence 0644.
# conf.d is a directory mount: the entrypoint rewrites default.conf with `sed -i` (see m198).
start_waf() {
  local name="$1" dir="${WORK}/confd-$1" i
  mkdir -p "${dir}" && cp "${WAF_CONF}/nginx.conf" "${dir}/default.conf" && chmod -R a+rwX "${dir}"
  cp "$2" "${WORK}/excl-$1.conf" && chmod 0644 "${WORK}/excl-$1.conf"
  docker run -d --name "${name}" --network "${NET}" ${3:+-e "$3"} \
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
  docker exec -e WAF="$1" -e MARKER="${MARKER}" "${TAG}-kong" node -e '
    const http = require("http");
    const send = (method, path, body) => new Promise((done) => {
      const data = body ? JSON.stringify(body) : "";
      const extra = body === null ? { "X-Note": "<script>alert(document.cookie)</script>" } : {};
      const r = http.request({ host: process.env.WAF, port: 80, method, path, headers: { Host: "localhost",
        apikey: process.env.MARKER, Authorization: "Bearer " + process.env.MARKER,
        "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), ...extra } },
        (s) => { s.resume(); s.on("end", () => done(s.statusCode)); });
      r.on("error", (e) => done("error:" + e.code));
      r.end(data);
    });
    const code = { content: [{ type: "code", content: "console.log(\"hi\"); fetch(url).then((r) => r.json())" }] };
    const prose = { title: "select * from users where id = \u00271\u0027 or \u00271\u0027=\u00271\u0027",
      content: [{ content: "<script>alert(1)</script> $(rm -rf /) <?php system($_GET[\"x\"]); ?> ../../etc/passwd {{7*7}} http://169.254.169.254/latest/meta-data/" }] };
    const migration = { identity: { tenant_id: "t1", source: "service_token", roles: ["service_role"] },
      mount: { id: "m1", tenant_id: "t1", engine: "postgresql", name: "db" }, name: "0002_notes",
      statements: ["CREATE TABLE IF NOT EXISTS notes (id int PRIMARY KEY, body text);\n" +
        "INSERT INTO notes (id, body) VALUES (1, \u0027a\u0027), (2, \u0027b\u0027);\n" +
        "CREATE OR REPLACE FUNCTION note_count() RETURNS bigint AS $$ SELECT count(*) FROM notes $$ LANGUAGE sql;"] };
    const probes = [
      ["content-post-code", "POST", "/rest/v1/osionos_pages", code],
      ["content-patch-code", "PATCH", "/rest/v1/osionos_pages?id=eq.6f1c0f5e-0000-4000-8000-000000000001", code],
      ["content-post-prose", "POST", "/rest/v1/osionos_pages", prose],
      ["content-chat-code", "POST", "/rest/v1/osionos_chat_messages", { body: "console.log(x)" }],
      ["content-patch-profile", "PATCH", "/rest/v1/osionos_bridge_identities?user_id=eq.6f1c0f5e-0000-4000-8000-000000000002", { profile: { headline: "Founder" } }],
      ["control-other-table-profile", "PATCH", "/rest/v1/secrets?id=eq.1", { profile: { headline: "Founder" } }],
      ["control-read-sqli", "GET", "/rest/v1/osionos_pages?title=eq.1%27%20or%20%271%27=%271", undefined],
      ["control-header-xss", "POST", "/rest/v1/osionos_pages", null],
      ["control-other-table", "POST", "/rest/v1/secrets", code],
      ["control-rpc", "POST", "/rest/v1/rpc/osionos_x", code],
      ["control-encoded-3F", "POST", "/rest/v1/osionos_pages%3F/../secrets", code],
      ["control-encoded-3f", "POST", "/rest/v1/osionos_pages%3f/../secrets", code],
      ["control-encoded-253F", "POST", "/rest/v1/osionos_pages%253F/../secrets", code],
      ["control-method-PO", "PO", "/rest/v1/osionos_pages", code],
      ["content-migrate-sql", "POST", "/admin/v1/migrate", migration],
      ["control-migrate-put", "PUT", "/admin/v1/migrate", migration],
      ["control-migrate-suffix", "POST", "/admin/v1/migrate-x", migration],
      ["control-migrate-slash", "POST", "/admin/v1/migrate/", migration],
      ["control-migrate-encoded", "POST", "/admin/v1/migrate%3F/../tenants", migration],
      ["control-migrate-tenants", "POST", "/admin/v1/tenants", migration],
    ];
    (async () => { for (const [label, m, p, b] of probes) console.log((await send(m, p, b)) + " " + label); })();'
}

# logs_have NAME TEXT: container NAME's log holds TEXT. Read whole first: under pipefail,
# `docker logs | grep -q` reads 141 once grep stops early on a long log, so a hit reads as a miss.
logs_have() {
  local out
  out="$(docker logs "$1" 2>&1)"
  grep -qF -- "$2" <<<"${out}"
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

step "0/5 preconditions"
preconditions
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "${WORK}/tls-key.pem" -out "${WORK}/tls.pem" >/dev/null 2>&1 && chmod 0644 "${WORK}"/tls*.pem ||
  skip "could not mint a throwaway TLS pair"
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  require("http").createServer((q, r) => { console.log(q.method + " " + q.url); q.resume(); q.on("end", () => r.end("upstream")); }).listen(8000);' >/dev/null ||
  skip "could not start the upstream"

step "1/5 WAF with ${EXCL#"${ROOT}"/}"
start_waf "${TAG}-waf" "${EXCL}" || {
  bad "the WAF did not become healthy with this exclusions file"
  exit 1
}
results="$(probe "${TAG}-waf")"
step "2/5 what a user typed reaches the app's tables"
expect_all "${results}" content- 200
step "3/5 the same text anywhere else is still refused"
expect_all "${results}" control- 403
if logs_have "${TAG}-kong" secrets; then
  bad "the upstream received a request for /rest/v1/secrets — the exclusion opened a path past the WAF"
else
  ok "the upstream never received a request for /rest/v1/secrets"
fi

step "4/5 the audit log holds no credential"
if ! logs_have "${TAG}-waf" '{"transaction":'; then
  bad "the WAF wrote no audit entry for the refused probes — this leg is blind"
elif logs_have "${TAG}-waf" "${MARKER}"; then
  bad "the audit log holds a request's apikey / Authorization (MODSEC_AUDIT_LOG_PARTS keeps B or I)"
else
  ok "audit entries written, none holds the apikey or Authorization the probes sent"
fi

# mutant RULE LABEL...: the file without RULE's paragraph (its comment and its SecRule, which
# no blank line separates) must refuse every LABEL, else that probe cannot see the false positive.
mutant() {
  local rule="$1" file="${WORK}/mutant-$1.conf" got label out
  shift
  awk -v id="id:${rule}," 'BEGIN { RS = ""; ORS = "\n\n" } index($0, id) == 0' "${EXCL}" >"${file}"
  if cmp -s "${EXCL}" "${file}" || grep -q "id:${rule}," "${file}"; then
    bad "mutant: rule ${rule} was not found as one paragraph — rebuild this leg"
    return
  fi
  if ! start_waf "${TAG}-mut${rule}" "${file}"; then
    bad "mutant: the WAF did not start without rule ${rule}"
    return
  fi
  out="$(probe "${TAG}-mut${rule}")"
  for label in "$@"; do
    got="$(awk -v l="${label}" '$2 == l { print $1 }' <<<"${out}")"
    [ "${got}" = 403 ] && ok "without ${rule}: ${label} refused (403) — the probe sees the false positive" ||
      bad "without ${rule}: ${label} answered '${got}', not 403 — the probe is blind"
  done
}

step "5/5 mutants: without its rule, each content probe MUST be refused; with headers in the audit, the marker MUST leak"
mutant 10110 content-post-code content-patch-profile
mutant 10120 content-migrate-sql
if ! start_waf "${TAG}-mutaudit" "${EXCL}" MODSEC_AUDIT_LOG_PARTS=ABIJDEFHZ; then
  bad "mutant: the WAF did not start with the old audit parts"
else
  probe "${TAG}-mutaudit" >/dev/null
  logs_have "${TAG}-mutaudit" "${MARKER}" && ok "with parts ABIJDEFHZ the marker leaks — the audit leg sees a leak" ||
    bad "with parts ABIJDEFHZ the marker did not leak — the audit leg is blind"
fi

[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M227] FAIL — app content or a migration is refused, an exclusion reaches past its path, or the audit log holds a credential\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M227] PASS — osionos_* writes carry code, migrations carry SQL; other paths stay inspected; no credential in the audit\033[0m\n'
