#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m227-waf-app-content.sh — what a user typed reaches the app's tables; the   #
#  same text anywhere else is still an attack; the internet never reaches a    #
#  private route                                                               #
#                                                                              #
#  osionos stores page blocks, chat messages and comments in osionos_* tables  #
#  through PostgREST. A code block holding `console.log(` scored 15 (CRS       #
#  934100 + 941390) and every save of that page was refused (2026-10-11, VM    #
#  WAF log). Rule 10110 (infra/docker/services/waf/conf/exclusions.conf)       #
#  lifts the injection families' ARGS inspection on WRITES to those tables     #
#  only; rule 10120 on POST /admin/v1/migrate, whose body is SQL (942350       #
#  read `; INSERT INTO` as injection, 2026-10-12). Rule 10130 refuses Kong's   #
#  ip-restricted routes to a request Tailscale Funnel marked: Funnel reaches   #
#  the WAF from loopback, which Kong's allow list admits (2026-10-12). Rule    #
#  10140 lifts them on the SQL runner's json.sql alone (POST                   #
#  /query/v1/<uuid>/sql-ro): 942100 read `grobase query run`'s SELECT as       #
#  injection (2026-10-12).                                                     #
#                                                                              #
#  Rule 10150 lifts the XSS checks and 921130 on the html of POST              #
#  /email/v1/send, and on nothing else (the text part keeps full inspection):  #
#  the verification mail scored 20 (941100, 941160, 941260, 921130, all on     #
#  json.html) and every mail from outside the VM was refused (2026-10-17, b2b  #
#  WAF log). Who may call the route is not decided here: this gate's kong      #
#  answers 200 to everyone. The anon key is refused at Kong (m206's email      #
#  leg) only on a tree carrying the email acl (grobase bbe8995f,               #
#  feat/titan-mail); the tree of rule 10150 (on a42a8077) does NOT carry it,   #
#  so there the route is open to the anon key and 10150 must not reach a       #
#  deployment before that acl does.                                            #
#  Rule 10160 lifts 930120 on ARGS:scope of GET /auth/v1/callback: Google     #
#  echoes `.../auth/userinfo.profile` there, 930120 read it as the file        #
#  `.profile` and every Google sign-in was refused (2026-10-27, b2b WAF log).  #
#  The WAF's nginx.conf raises ModSecurity's argument (10,000) and body        #
#  (1 MiB) limits on /rest/v1/osionos_object_databases alone: a database is    #
#  saved whole, one JSON leaf per argument, and a 36-row CRM (~1,500 leaves)   #
#  was refused by 200007 on every save (2026-10-21, b2b WAF log).              #
#  It raises the body limit to 2 MiB on the hydrawn_boards document paths and  #
#  1 MiB on hydrawn_thumbnails: the osionos bridge stores a whiteboard as one  #
#  mongo-api document and a 200 KB board was refused by 200002 (2026-10-28,    #
#  live WAF probe). Rule 10170 lifts the injection families and 921130 on the  #
#  board's scene alone; 10171-10173 refuse more than 32 arguments, or any      #
#  other argument or name over 1 KiB, on those paths before CRS reads them (an #
#  8.5 MiB title took 7.5 s and OOM-killed a worker, 2026-10-28).              #
#                                                                              #
#  This gate boots the WAF image with the tree's exclusions file on a private  #
#  network whose `kong` answers 200, then:                                     #
#    CONTENT   POST/PATCH to osionos_pages / osionos_chat_messages carrying JS,#
#              SQL, XSS, shell, PHP, ../, {{ }}, a metadata URL → 200          #
#              and an object database titled `HTTP/2 vs HTTP/3`, or holding   #
#              `<html>` / `<meta`, on osionos_object_databases (921130) → 200  #
#              and a page holding a pasted `curl -i` answer, a title with      #
#              `\nSet-Cookie:` (921120) → 200                                  #
#              and a 3,000-leaf, 180 KB object database, POST and PATCH → 200  #
#              and a profile key on osionos_bridge_identities (930120 read     #
#              `json.profile.headline` as the file .profile) → 200             #
#              and a migration of DDL + INSERTs to /admin/v1/migrate → 200     #
#              and a raw statement to /query/v1/<uuid>/sql-ro → 200            #
#              and every mail the site gateway sends, to /email/v1/send → 200 #
#              (fixtures/m227-email-bodies.json: opposite-osiris               #
#              src/email-templates, the four account messages through          #
#              scripts/auth/mail-templates.mjs and the sign-in alert, account  #
#              created and three newsletter mails through the gateway's own    #
#              renderer, a fake signed link)                                   #
#    CONTROLS  the same path read with SQLi in its query string, written with  #
#              <script> in a header or a method `PO`; the same body to another #
#              table, to an rpc, and through osionos_pages%3F/../secrets       #
#              (%3f, %253F), a read of ?title=eq.HTTP/2 or of a `\nSet-Cookie:` #
#              title (921120), a `<html` cookie, a value with                 #
#              `GET /x HTTP/1.1` (921110, the boundary 10110 keeps) → 403,    #
#              and the upstream never sees `secrets`;                          #
#              the mail with <script> in to, subject, text, listUnsubscribe,   #
#              the query string, or in `Subject` / `TO` (Go matches JSON keys      #
#              without case, so a lifted value must not reach a header), as a GET or PUT, to /email/v1/send-x,         #
#              /send/, /send%3F/../x or /rest/v1/some_table → 403              #
#              the migration as a PUT, to /admin/v1/migrate-x, …/migrate/,     #
#              …/migrate%3F/../tenants, …/migrate/../provision,              #
#              …/migrate%2F..%2Fprovision, /admin/v1/rotate (the relay to      #
#              tenant-control, ADR 0008) or /admin/v1/tenants → 403            #
#              the statement as a PUT, to …/sql-ro-x, to a non-uuid database, #
#              through …/sql-ro%3F/../../execute, in another argument, or as   #
#              payload.sql of /query/v1/execute → 403                          #
#              the large database with a request line in its last leaf, and a  #
#              read of osionos_object_databases with SQLi in its query → 403   #
#    LIMITS    the large database to osionos_pages, to a suffixed or %3F       #
#              path, and a 12,000-leaf database → 400 (each other path keeps   #
#              the image's 1,000 arguments and 128 KB)                         #
#    FUNNEL    every ip-restricted path read out of kong.yml, sent with        #
#              Tailscale-Funnel-Request, and /%61dmin, /admin//v1, ../admin    #
#              and a migration POST → 403; the same paths without the header,  #
#              and auth, rest, realtime, an osionos write and a raw statement  #
#              with it → 200                                                   #
#    PEER      rule 10131 (ADR 0002 C2): with the image's operator-addresses   #
#              file, the same private paths from a non-operator peer — plain,  #
#              and with a forged X-Real-IP / X-Forwarded-For of 127.0.0.1 —    #
#              → 403, public routes → 200; the other legs list the probe's     #
#              own container as operator so their routes stay reachable        #
#    AUDIT     every probe carries a marker apikey and Bearer token; the       #
#              audit entries (stdout, shipped to Loki) must not hold it        #
#    MUTANTS   the file without rule 10110 MUST refuse the code block and the  #
#              profile, without rule 10120 the migration, without rule 10140   #
#              the statement, without rule 10150 (or only its 921130 line, or  #
#              only its XSS line, on json.html) the mails, without rule 10130 MUST pass the Funnel   #
#              probes, without rule 10131 the non-operator probes, and audit   #
#              parts ABIJDEFHZ MUST                                            #
#              leak the marker, and nginx.conf without the object-database     #
#              location MUST refuse the large database; else the gate is       #
#              blind and fails                                                 #
#  Needs docker, the WAF image and node:20-alpine already present (nothing is  #
#  pulled); otherwise SKIP, exit 77, never 0. A throwaway TLS pair is minted   #
#  in the temp dir. Containers, network and temp dir go in an EXIT trap.       #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WAF_CONF="${ROOT}/infra/docker/services/waf/conf"
# One entry per message opposite-osiris's gateway sends through /email/v1/send, rendered from its
# src/email-templates (confirmEmail, resetPassword, passwordChanged, accountExists through
# renderMessage() of scripts/auth/mail-templates.mjs; the rest through auth-gateway.mjs's
# renderEmailTemplate substitution), link https://localhost:4322/auth/confirm#token_hash=abc&type=signup&sig=def.
# The gateway sends no listUnsubscribe (account-mail.mjs and auth-gateway.mjs never set it), so
# no entry carries one; the listUnsubscribe control adds it.
MAIL_FIXTURE="${SCRIPT_DIR}/fixtures/m227-email-bodies.json"
EXCL="${M227_EXCLUSIONS:-${WAF_CONF}/exclusions.conf}"
KONG_YML="${ROOT}/infra/docker/services/kong/conf/kong.yml"
WAF_IMG="${M227_WAF_IMAGE:-ghcr.io/univers42/grobase-waf:latest}"
NODE_IMG="${M227_NODE_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
CRS_EXCL=/etc/modsecurity.d/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf
TAG="m227gate$$"
# Sent as every probe's apikey and Bearer token: the audit log must never hold it.
MARKER="m227-credential-marker-$$"
NET="${TAG}-net"
WORK="$(mktemp -d)"
FAILED=0
# One content probe per fixture message (probe() names them content-email-<key>).
EMAIL_LABELS=(
  content-email-confirmEmail content-email-resetPassword content-email-passwordChanged
  content-email-accountExists content-email-loginAlertSuccess content-email-loginAlertFailed
  content-email-accountCreated content-email-newsletterConfirm
  content-email-newsletterWelcome content-email-newsletterUnsubscribe
)

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

# cleanup: remove every container, the network and the temp dir this run made. Containers go by
# name prefix, not a list: mutant 10140 was added without joining the list and leaked a container
# (and so the network) on every run.
cleanup() {
  docker ps -aq --filter "name=^${TAG}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
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
  [ -f "${KONG_YML}" ] || skip "${KONG_YML} not found"
}

# kong_private_paths: every route path of a kong.yml service that carries ip-restriction, one
# per line, from both `paths: [/a, /b]` and the block form. These are the routes Kong keeps to
# private sources, which rule 10130 must refuse when they arrive through Tailscale Funnel.
# Caveat: a line scanner, not a YAML parser. It reads a service as everything from its
# `  - name:` line to the next one, so an ip-restriction anywhere in a service marks all of
# its routes (over-reporting, which only adds probes); a path written any other way than
# those two forms is missed. It matched a full YAML parse of kong.yml (12 paths, 2026-10-12).
kong_private_paths() {
  awk '
    function flush() { if (restricted) for (i = 1; i <= n; i++) print p[i]; n = 0; restricted = 0 }
    /^  - name: / || /^[a-z_]+:/ { flush(); block = 0 }
    /^ +paths: *\[/ { s = $0; sub(/.*paths: *\[/, "", s); sub(/\].*/, "", s); gsub(/[ "]/, "", s)
      k = split(s, a, ","); for (j = 1; j <= k; j++) p[++n] = a[j]; block = 0; next }
    /^ +paths: *$/ { block = 1; next }
    block && /^ +- *"?\// { s = $0; sub(/^ +- */, "", s); gsub(/[ "]/, "", s); p[++n] = s; next }
    { block = 0 }
    /name: ip-restriction/ { restricted = 1 }
    END { flush() }' "${KONG_YML}" | sort -u
}

# start_waf NAME EXCLUSIONS [VAR=VALUE]: boot the WAF with the tree's nginx.conf and EXCLUSIONS
# as CRS's REQUEST-900 file, and the optional environment override; wait for /waf-health.
# M227_BLOCKING_PARANOIA=N runs every WAF at that paranoia level (the baas VM runs 2, the image 1).
# NGINX_CONF replaces the tree's nginx.conf (the object-database location mutant).
# OPERATORS names the operator-addresses file rule 10131 reads (default: the probe container's own
# address, so private routes stay reachable; the PEER leg passes the image's file).
# nginx (uid 101) reads the throwaway key, hence 0644.
# conf.d is a directory mount: the entrypoint rewrites default.conf with `sed -i` (see m198).
start_waf() {
  local name="$1" dir="${WORK}/confd-$1" i
  mkdir -p "${dir}" && cp "${NGINX_CONF:-${WAF_CONF}/nginx.conf}" "${dir}/default.conf" && chmod -R a+rwX "${dir}"
  cp "$2" "${WORK}/excl-$1.conf" && chmod 0644 "${WORK}/excl-$1.conf"
  docker run -d --name "${name}" --network "${NET}" ${M227_BLOCKING_PARANOIA:+-e "BLOCKING_PARANOIA=${M227_BLOCKING_PARANOIA}"} ${3:+-e "$3"} \
    -v "${dir}:/etc/nginx/conf.d" \
    -v "${WORK}/excl-$1.conf:${CRS_EXCL}:ro" \
    -v "${OPERATORS:-${WORK}/operators-probe.txt}:/etc/modsecurity.d/operator-addresses.txt:ro" \
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
# "<status> <label>" line each. A null body sends `<script>` in a header instead. Each path
# of PRIVATE (kong_private_paths) is sent twice: as Funnel delivers it and as the tailnet does.
probe() {
  docker exec -e WAF="$1" -e MAILS="$(cat "${MAIL_FIXTURE}")" -e MARKER="${MARKER}" -e PRIVATE="${PRIVATE}" "${TAG}-kong" node -e '
    const http = require("http");
    const send = (method, path, body, headers) => new Promise((done) => {
      const data = body ? JSON.stringify(body) : "";
      const extra = body === null ? { "X-Note": "<script>alert(document.cookie)</script>" } : {};
      const r = http.request({ host: process.env.WAF, port: 80, method, path, headers: { Host: "localhost",
        apikey: process.env.MARKER, Authorization: "Bearer " + process.env.MARKER,
        "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), ...extra, ...headers } },
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
    const odb = (value) => ({ owner_id: "6f1c0f5e-0000-4000-8000-000000000003", db_key: "http-lessons",
      state: { pages: { "http-lessons-r019": { properties: { "http-lessons-title": value } } } } });
    const odbPath = "/rest/v1/osionos_object_databases?on_conflict=owner_id,db_key";
    const odbPatch = "/rest/v1/osionos_object_databases?db_key=eq.http-lessons";
    const title = odb("HTTP/2 vs HTTP/3");
    // A database saved whole: ROWS records of 10 leaves each (3,000 leaves is ~180 KB).
    const bigOdb = (rows) => { const pages = {};
      for (let i = 0; i < rows; i++) { const properties = {};
        for (let k = 0; k < 9; k++) properties["prop-" + k] = "value " + i + "-" + k + " " + "x".repeat(40);
        pages["page-" + i] = { id: "page-" + i, properties }; }
      return { owner_id: "6f1c0f5e-0000-4000-8000-000000000003", db_key: "crm-deals", state: { pages } }; };
    const large = bigOdb(300);
    const sqli = "SELECT COUNT(*) AS n FROM projects WHERE name = \u0027a\u0027 OR \u00271\u0027=\u00271\u0027 UNION SELECT 1";
    const runner = "/query/v1/59939f19-7e8d-4876-a57f-61b3e7bb37be/sql-ro";
    const raw = { sql: sqli };
    const mails = JSON.parse(process.env.MAILS);
    const mail = mails.confirmEmail;
    const script = "<script>alert(1)</script>";
    const mailPath = "/email/v1/send";
    const oauthCallback = "/auth/v1/callback";
    // The query Google sent on the refused sign-in (2026-10-27), with a fake code and state.
    const googleCallback = "state=7538a86d-3cf3-45aa-a18c-eea0c3071013&iss=https%3A%2F%2Faccounts.google.com" +
      "&code=4%2F0AUn6Hd8fake&scope=email%20profile%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.profile" +
      "%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.email%20openid&authuser=0&prompt=consent";
    const funnel = { "Tailscale-Funnel-Request": "?1" };
    // A hydrawn board as the osionos bridge stores it: the scene is one JSON string. Pictures are
    // seeded bytes (a PNG signature, then a sha256 chain) so every run sends the same base64.
    const seeded = (n) => { const out = Buffer.alloc(n); let h = Buffer.from("m227");
      for (let o = 0; o < n; o += 32) { h = require("crypto").createHash("sha256").update(h).digest(); h.copy(out, o); }
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(out); return out; };
    const drawn = ["console.log(\"hi\"); fetch(url).then((r) => r.json())", sqli, script, "HTTP/2 vs HTTP/3",
      "<html><meta charset=utf-8>", "../../etc/passwd", "{{7*7}}", "http://169.254.169.254/latest/meta-data/",
      "$(rm -rf /) <?php system($_GET[\"x\"]); ?>", "document.cookie = \"a=1\""];
    const scene = (pictureBytes) => JSON.stringify({ type: "hydrawn", version: 1,
      elements: drawn.map((text, i) => ({ id: "e" + i, type: "text", x: i * 10, y: 0, width: 200, height: 24, text })),
      files: pictureBytes ? { p1: { mimeType: "image/png", dataURL: "data:image/png;base64," + seeded(pictureBytes).toString("base64") } } : {} });
    const board = (sceneText, extra) => ({ data: { slug: "k3x9-plan", title: "Plan", scene: sceneText, element_count: drawn.length,
      entry_count: 0, rev: 1, thumbnail_at: null, deleted_at: null, ...extra } });
    const wbDocs = "/mongo/v1/collections/hydrawn_boards/documents";
    const wbId = "6720a1b2c3d4e5f6a7b8c9d0";
    const wbSave = wbDocs + "/" + wbId + "?if_field=rev&if_value=1&fields=slug,title,rev";
    const thumbs = "/mongo/v1/collections/hydrawn_thumbnails/documents";
    const hostile = scene(0);
    const wbLarge = board(scene(1500000));
    const wbOver = board(scene(1600000));
    const png = seeded(512 * 1024).toString("base64");
    const wbDrift = [wbDocs + "-x", wbDocs + "/", wbDocs + "%3F/../x", "/mongo/v1/collections/hydrawn_boards//documents",
      "/mongo/v1/collections/hydrawn_boards%2Fdocuments", "/mongo/v1/collections/x/../hydrawn_boards/documents",
      wbDocs + "/%2e%2e/" + wbId, wbDocs + ";x", wbDocs + "/" + wbId.toUpperCase(), wbDocs + "/" + wbId.slice(1),
      wbDocs + "/" + wbId + "a", "/mongo/v1/collections/hydrawn_boards/Documents", "/mongo/v1/collections/HYDRAWN_BOARDS/documents",
      wbDocs + "%00", wbDocs + "/" + wbId + "/x", "/mongo/v1/collections/hydrawn_boards_x/documents"];
    const probes = [
      ["content-post-code", "POST", "/rest/v1/osionos_pages", code],
      ["content-patch-code", "PATCH", "/rest/v1/osionos_pages?id=eq.6f1c0f5e-0000-4000-8000-000000000001", code],
      ["content-post-prose", "POST", "/rest/v1/osionos_pages", prose],
      ["content-chat-code", "POST", "/rest/v1/osionos_chat_messages", { body: "console.log(x)" }],
      ["content-patch-profile", "PATCH", "/rest/v1/osionos_bridge_identities?user_id=eq.6f1c0f5e-0000-4000-8000-000000000002", { profile: { headline: "Founder" } }],
      ["content-odb-protocol-title", "POST", odbPath, title],
      ["content-odb-html-tag", "PATCH", odbPatch, odb("<html>")],
      ["content-odb-meta-tag", "PATCH", odbPatch, odb("<meta charset=utf-8>")],
      ["content-odb-header-lines", "POST", odbPath, odb("a\nSet-Cookie: x=1")],
      ["content-page-pasted-response", "POST", "/rest/v1/osionos_pages",
        { content: [{ type: "code", content: "HTTP/1.1 308 Permanent Redirect\r\nLocation: https://example.com/\r\nContent-Length: 0" }] }],
      ["content-odb-large", "POST", odbPath, large],
      ["content-odb-large-patch", "PATCH", odbPatch, large],
      ["control-odb-large-split", "POST", odbPath, { ...large, tail: "GET /index.html HTTP/1.1" }],
      ["control-odb-read-sqli", "GET", "/rest/v1/osionos_object_databases?title=eq.1%27%20or%20%271%27=%271", undefined],
      ["limit-odb-large-pages", "POST", "/rest/v1/osionos_pages", large],
      ["limit-odb-large-suffix", "POST", "/rest/v1/osionos_object_databases_x", large],
      ["limit-odb-large-encoded", "POST", "/rest/v1/osionos_object_databases%3F/../osionos_pages", large],
      ["limit-odb-over-cap", "POST", odbPath, bigOdb(1200)],
      ["control-odb-other-table", "POST", "/rest/v1/secrets", title],
      ["control-odb-rpc", "POST", "/rest/v1/rpc/osionos_x", title],
      ["control-odb-encoded", "POST", "/rest/v1/osionos_object_databases%3F/../secrets", title],
      ["control-odb-read", "GET", "/rest/v1/osionos_pages?title=eq.HTTP/2", undefined],
      ["control-odb-cookie", "POST", odbPath, odb("plain"), { Cookie: "note=<html" }],
      ["control-read-header-split", "GET", "/rest/v1/osionos_pages?title=eq.a%0ASet-Cookie:%20x=1", undefined],
      ["control-odb-request-line", "POST", odbPath, odb("GET /index.html HTTP/1.1")],
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
      ["control-migrate-dotdot", "POST", "/admin/v1/migrate/../provision", migration],
      ["control-migrate-encoded-slash", "POST", "/admin/v1/migrate%2F..%2Fprovision", migration],
      ["control-rotate-sql", "POST", "/admin/v1/rotate", migration],
      ["content-query-sql", "POST", runner, raw],
      ["control-query-put", "PUT", runner, raw],
      ["control-query-suffix", "POST", runner + "-x", raw],
      ["control-query-not-uuid", "POST", "/query/v1/projects/sql-ro", raw],
      ["control-query-encoded", "POST", runner + "%3F/../../execute", raw],
      ["control-query-other-arg", "POST", runner, { sql: "SELECT 1", note: sqli }],
      ["control-query-execute", "POST", "/query/v1/execute", { database_id: "59939f19-7e8d-4876-a57f-61b3e7bb37be", action: "select", resource: "projects", payload: { sql: sqli } }],
      ...Object.entries(mails).map(([name, message]) => ["content-email-" + name, "POST", mailPath, message]),
      ["control-email-to-script", "POST", mailPath, { ...mail, to: script }],
      ["control-email-subject-script", "POST", mailPath, { ...mail, subject: script }],
      ["control-email-text-script", "POST", mailPath, { ...mail, text: script }],
      ["control-email-Subject-script", "POST", mailPath, { ...mail, Subject: script }],
      ["control-email-TO-script", "POST", mailPath, { ...mail, TO: script }],
      ["control-email-unsubscribe-script", "POST", mailPath, { ...mail, listUnsubscribe: script }],
      ["control-email-query-script", "POST", mailPath + "?x=" + script, mail],
      ["control-email-get", "GET", mailPath, mail],
      ["control-email-put", "PUT", mailPath, mail],
      ["control-email-suffix", "POST", mailPath + "-x", mail],
      ["control-email-slash", "POST", mailPath + "/", mail],
      ["control-email-encoded", "POST", mailPath + "%3F/../x", mail],
      ["control-email-elsewhere", "POST", "/rest/v1/some_table", mail],
      ["content-oauth-google-callback", "GET", oauthCallback + "?" + googleCallback, undefined],
      ["control-oauth-code-profile", "GET", oauthCallback + "?state=s&code=%2Fhome%2Fu%2F.profile", undefined],
      ["control-oauth-scope-traversal", "GET", oauthCallback + "?state=s&code=c&scope=..%2F..%2Fetc%2Fpasswd", undefined],
      ["control-oauth-post", "POST", oauthCallback + "?" + googleCallback, { code: "c" }],
      ["control-oauth-suffix", "GET", oauthCallback + "-x?" + googleCallback, undefined],
      ["control-oauth-slash", "GET", oauthCallback + "/?" + googleCallback, undefined],
      ["control-oauth-encoded", "GET", oauthCallback + "%3F/../token?" + googleCallback, undefined],
      ["control-oauth-elsewhere", "GET", "/auth/v1/token?" + googleCallback, undefined],
      ["content-wb-post-scene", "POST", wbDocs, board(hostile)],
      ["content-wb-patch-scene", "PATCH", wbSave, { patch: { scene: hostile, rev: 2, element_count: drawn.length } }],
      ["content-wb-large", "POST", wbDocs, wbLarge],
      ["content-wb-large-patch", "PATCH", wbSave, { patch: { scene: wbLarge.data.scene, rev: 2 } }],
      ["content-wb-thumbnail", "POST", thumbs, { data: { slug: "k3x9-plan", png } }],
      ["content-wb-thumbnail-patch", "PATCH", thumbs + "/" + wbId + "?fields=slug", { patch: { png } }],
      ["control-wb-title", "POST", wbDocs, board(hostile, { title: script })],
      ["control-wb-other-arg", "POST", wbDocs, board(hostile, { note: script })],
      ["control-wb-query", "PATCH", wbSave + "&x=" + encodeURIComponent(script), { patch: { scene: hostile } }],
      ["control-wb-header", "POST", wbDocs, null],
      ["control-wb-case", "POST", wbDocs, { Data: { scene: hostile } }],
      ["control-wb-nested", "POST", wbDocs, { data: { scene: { text: script } } }],
      ["control-wb-get", "GET", wbDocs, board(hostile)],
      ["control-wb-put", "PUT", wbDocs + "/" + wbId, { patch: { scene: hostile } }],
      ["control-wb-delete", "DELETE", wbDocs + "/" + wbId, { patch: { scene: hostile } }],
      ["control-wb-thumbnail-scene", "POST", thumbs, board(script)],
      ["control-wb-other-collection", "POST", "/mongo/v1/collections/notes/documents", board(hostile)],
      ...wbDrift.map((p) => ["drift-wb-scene:" + p, "POST", p, board(hostile)]),
      ...wbDrift.map((p) => ["drift-wb-large:" + p, "POST", p, wbLarge]),
      ["limit-wb-over-cap", "POST", wbDocs, wbOver],
      ["limit-wb-thumbnail-over-cap", "POST", thumbs, { data: { slug: "k3x9-plan", png: seeded(800 * 1024).toString("base64") } }],
      ["limit-wb-thumbnail-board-size", "POST", thumbs, wbLarge],
      ["limit-wb-other-collection", "POST", "/mongo/v1/collections/notes/documents", { data: { png } }],
      ["limit-wb-other-collection-200k", "POST", "/mongo/v1/collections/notes/documents", { data: { png: png.slice(0, 200000) } }],
      ["limit-wb-arguments", "POST", wbDocs, { data: Object.fromEntries(Array.from({ length: 1001 }, (_, i) => ["k" + i, i])) }],
      ["limit-wb-arguments-33", "POST", wbDocs, board(hostile, Object.fromEntries(Array.from({ length: 25 }, (_, i) => ["k" + i, i])))],
      ["limit-wb-title-1k", "POST", wbDocs, board(hostile, { title: "a".repeat(1025) })],
      ["limit-wb-patch-title-1k", "PATCH", wbSave, { patch: { scene: hostile, title: "a".repeat(1025) } }],
      ["limit-wb-key-1k", "POST", wbDocs, board(hostile, { ["k".repeat(1025)]: 1 })],
      ["limit-wb-board-png", "POST", wbDocs, board(hostile, { png: "A".repeat(2048) })],
      ["limit-wb-thumbnail-1k", "POST", thumbs, { data: { slug: "k3x9-plan", png, note: "a".repeat(1025) } }],
      ["public-funnel-query", "POST", runner, raw, funnel],
      ["funnel-encoded-a", "GET", "/%61dmin/v1/tenants", undefined, funnel],
      ["funnel-double-slash", "GET", "/admin//v1/tenants", undefined, funnel],
      ["funnel-dotdot", "GET", "/rest/v1/../../admin/v1/keys", undefined, funnel],
      ["funnel-migrate-post", "POST", "/admin/v1/migrate", migration, funnel],
      ["public-funnel-auth", "GET", "/auth/v1/health", undefined, funnel],
      ["public-funnel-rest", "GET", "/rest/v1/osionos_pages?select=id", undefined, funnel],
      ["public-funnel-write", "POST", "/rest/v1/osionos_pages", code, funnel],
      ["public-funnel-realtime", "GET", "/realtime/v1/websocket", undefined, funnel],
      ...process.env.PRIVATE.split("\n").filter(Boolean).flatMap((p) => [
        ["funnel-kong:" + p, "GET", p, undefined, funnel], ["tailnet-kong:" + p, "GET", p, undefined, {}],
        ["xrealip-kong:" + p, "GET", p, undefined, { "X-Real-IP": "127.0.0.1", "X-Forwarded-For": "127.0.0.1" }]]),
    ];
    (async () => { for (const [label, m, p, b, h] of probes) console.log((await send(m, p, b, h)) + " " + label); })();'
}

# expect_refused RESULTS PREFIX: every probe whose label starts with PREFIX was refused, by the
# WAF's 403 or by a 400 (nginx's raw-URI guard, or ModSecurity's body limit).
expect_refused() {
  local line got n=0
  while read -r got line; do
    case "${line}" in "$2"*) ;; *) continue ;; esac
    n=$((n + 1))
    case "${got}" in 400 | 403) ok "${line}: ${got}" ;; *) bad "${line}: ${got}, want 400 or 403" ;; esac
  done <<<"$1"
  [ "${n}" -gt 0 ] || bad "no '$2' probe ran"
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

step "0/6 preconditions"
preconditions
echo "WAF image: ${WAF_IMG} $(docker image inspect --format '{{.Id}}' "${WAF_IMG}")"
PRIVATE="$(kong_private_paths)"
[ -n "${PRIVATE}" ] || bad "no ip-restricted path found in ${KONG_YML#"${ROOT}"/} — the Funnel leg is blind"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "${WORK}/tls-key.pem" -out "${WORK}/tls.pem" >/dev/null 2>&1 && chmod 0644 "${WORK}"/tls*.pem ||
  skip "could not mint a throwaway TLS pair"
docker network create "${NET}" >/dev/null || skip "could not create a docker network"
docker run -d --name "${TAG}-kong" --network "${NET}" --network-alias kong "${NODE_IMG}" node -e '
  require("http").createServer((q, r) => { console.log(q.method + " " + q.url); q.resume(); q.on("end", () => r.end("upstream")); }).listen(8000);' >/dev/null ||
  skip "could not start the upstream"
printf '127.0.0.1\n%s\n' "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${TAG}-kong")" >"${WORK}/operators-probe.txt"
chmod 0644 "${WORK}/operators-probe.txt"

step "1/6 WAF with ${EXCL#"${ROOT}"/}"
start_waf "${TAG}-waf" "${EXCL}" || {
  bad "the WAF did not become healthy with this exclusions file"
  exit 1
}
results="$(probe "${TAG}-waf")"
step "2/6 what a user typed reaches the app's tables"
expect_all "${results}" content- 200
step "3/6 the same text anywhere else is still refused"
expect_all "${results}" control- 403
# /admin/v1/function-secrets is a real route the tailnet probes reach on purpose.
if docker logs "${TAG}-kong" 2>&1 | awk '/secrets/ && !/\/admin\/v1\/function-secrets/ { n++ } END { exit !n }'; then
  bad "the upstream received a request for /rest/v1/secrets — the exclusion opened a path past the WAF"
else
  ok "the upstream never received a request for /rest/v1/secrets"
fi

step "3b/6 a whole object database fits its path's limits; every other path keeps the image's"
expect_all "${results}" limit- 400

step "3c/6 a whiteboard path that only normalises to the board paths gets neither the lift nor the limit"
expect_refused "${results}" drift-

step "4/6 the internet never reaches a private route; the tailnet and the public routes still do"
expect_all "${results}" funnel- 403
expect_all "${results}" tailnet- 200
expect_all "${results}" xrealip- 200
expect_all "${results}" public- 200

step "4b/6 a non-operator peer never reaches a private route, forged headers or not (rule 10131)"
if OPERATORS="${WAF_CONF}/operator-addresses.txt" start_waf "${TAG}-peer" "${EXCL}"; then
  peer="$(probe "${TAG}-peer")"
  expect_all "${peer}" tailnet- 403
  expect_all "${peer}" xrealip- 403
  expect_all "${peer}" funnel- 403
  expect_all "${peer}" public- 200
else
  bad "the WAF did not start with the image's operator-addresses file"
fi

step "5/6 the audit log holds no credential"
if ! logs_have "${TAG}-waf" '{"transaction":'; then
  bad "the WAF wrote no audit entry for the refused probes — this leg is blind"
elif logs_have "${TAG}-waf" "${MARKER}"; then
  bad "the audit log holds a request's apikey / Authorization (MODSEC_AUDIT_LOG_PARTS keeps B or I)"
else
  ok "audit entries written, none holds the apikey or Authorization the probes sent"
fi

# mutant RULE WANT LABEL...: the file without RULE's paragraph (its comment and its SecRule, which
# no blank line separates) must answer WANT to every LABEL, else that probe cannot see what the
# rule changes: 403 for an exclusion's false positive, 200 for a refusal's hole.
mutant() {
  local rule="$1" want="$2" file="${WORK}/mutant-$1.conf" got label out
  shift 2
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
    [ "${got}" = "${want}" ] && ok "without ${rule}: ${label} answered ${want} — the probe sees what the rule changes" ||
      bad "without ${rule}: ${label} answered '${got}', not ${want} — the probe is blind"
  done
}

# line_mutant PATTERN WANT LABEL...: the file with only the ctl actions matching PATTERN neutralised
# must answer WANT to every LABEL. Catches a 921130 probe that stays green because 10110's tag
# removals, not the 921130 line, let it through. An action is replaced, not deleted: deleting the
# last action of a chain leaves a dangling `,\` and the WAF fails to load.
line_mutant() {
  local pattern="$1" want="$2" file="${WORK}/linemut.conf" got label out
  shift 2
  LINE_MUTANTS=$((${LINE_MUTANTS:-0} + 1))
  local name="${TAG}-mutline${LINE_MUTANTS}"
  sed -E "s|ctl:[^,\"]*${pattern}[^,\"]*|ctl:auditEngine=RelevantOnly|" "${EXCL}" >"${file}"
  if cmp -s "${EXCL}" "${file}" || grep -q -- "${pattern}" "${file}"; then
    bad "line mutant: '${pattern}' was not found — rebuild this leg"
    return
  fi
  if ! start_waf "${name}" "${file}"; then
    bad "line mutant: the WAF did not start without '${pattern}'"
    return
  fi
  out="$(probe "${name}")"
  for label in "$@"; do
    got="$(awk -v l="${label}" '$2 == l { print $1 }' <<<"${out}")"
    [ "${got}" = "${want}" ] && ok "without the '${pattern}' line: ${label} answered ${want} — the probe sees that line" ||
      bad "without the '${pattern}' line: ${label} answered '${got}', not ${want} — the probe is blind"
  done
}

step "6/6 mutants: without its rule, each content probe MUST be refused and each Funnel probe MUST pass; with headers in the audit, the marker MUST leak"
mutant 10110 403 content-post-code content-patch-profile content-odb-protocol-title content-odb-html-tag content-odb-meta-tag
line_mutant 921130\;ARGS 403 content-odb-protocol-title content-odb-html-tag content-odb-meta-tag
line_mutant 921120\;ARGS 403 content-odb-header-lines content-page-pasted-response
mutant 10120 403 content-migrate-sql
mutant 10140 403 content-query-sql public-funnel-query
mutant 10150 403 "${EMAIL_LABELS[@]}"
line_mutant 921130\;ARGS:json.html 403 "${EMAIL_LABELS[@]}"
line_mutant 'attack-xss;ARGS:json.html' 403 "${EMAIL_LABELS[@]}"
mutant 10160 403 content-oauth-google-callback
mutant 10170 403 content-wb-post-scene content-wb-patch-scene
line_mutant '921130;ARGS:json.data.scene' 403 content-wb-post-scene
line_mutant '921130;ARGS:json.patch.scene' 403 content-wb-patch-scene
mutant 10171 200 limit-wb-arguments-33
mutant 10172 200 limit-wb-title-1k limit-wb-patch-title-1k limit-wb-key-1k limit-wb-board-png
mutant 10173 200 limit-wb-thumbnail-1k
OPERATORS="${WAF_CONF}/operator-addresses.txt" mutant 10131 200 tailnet-kong:/admin/v1/tenants tailnet-kong:/meta/v1 tailnet-kong:/realtime/v1/publish xrealip-kong:/admin/v1/tenants
mutant 10130 200 funnel-kong:/admin/v1/tenants funnel-kong:/meta/v1 funnel-kong:/realtime/v1/publish funnel-encoded-a funnel-double-slash funnel-migrate-post
awk '/^    location = \/rest\/v1\/osionos_object_databases \{/ { skip = 1 } !skip { print } skip && /^    \}/ { skip = 0 }' \
  "${WAF_CONF}/nginx.conf" >"${WORK}/nginx-no-odb.conf"
if cmp -s "${WAF_CONF}/nginx.conf" "${WORK}/nginx-no-odb.conf" || grep -q 'osionos_object_databases {' "${WORK}/nginx-no-odb.conf"; then
  bad "mutant: the object-database location was not found in nginx.conf — rebuild this leg"
elif ! NGINX_CONF="${WORK}/nginx-no-odb.conf" start_waf "${TAG}-mutodb" "${EXCL}"; then
  bad "mutant: the WAF did not start without the object-database location"
else
  out="$(probe "${TAG}-mutodb")"
  for label in content-odb-large content-odb-large-patch; do
    got="$(awk -v l="${label}" '$2 == l { print $1 }' <<<"${out}")"
    [ "${got}" = 400 ] && ok "without the object-database location: ${label} answered 400 — the probe sees the raised limits" ||
      bad "without the object-database location: ${label} answered '${got}', not 400 — the probe is blind"
  done
fi
awk '/^    location ~ "\^\/mongo\/v1\/collections\/hydrawn_/ { skip = 1 } !skip { print } skip && /^    \}/ { skip = 0 }' \
  "${WAF_CONF}/nginx.conf" >"${WORK}/nginx-no-wb.conf"
if cmp -s "${WAF_CONF}/nginx.conf" "${WORK}/nginx-no-wb.conf" || grep -q 'collections/hydrawn_' "${WORK}/nginx-no-wb.conf"; then
  bad "mutant: the whiteboard locations were not found in nginx.conf — rebuild this leg"
elif ! NGINX_CONF="${WORK}/nginx-no-wb.conf" start_waf "${TAG}-mutwb" "${EXCL}"; then
  bad "mutant: the WAF did not start without the whiteboard locations"
else
  out="$(probe "${TAG}-mutwb")"
  for label in content-wb-large content-wb-large-patch content-wb-thumbnail content-wb-thumbnail-patch; do
    got="$(awk -v l="${label}" '$2 == l { print $1 }' <<<"${out}")"
    [ "${got}" = 400 ] && ok "without the whiteboard locations: ${label} answered 400 — the probe sees the raised limits" ||
      bad "without the whiteboard locations: ${label} answered '${got}', not 400 — the probe is blind"
  done
fi
if ! start_waf "${TAG}-mutaudit" "${EXCL}" MODSEC_AUDIT_LOG_PARTS=ABIJDEFHZ; then
  bad "mutant: the WAF did not start with the old audit parts"
else
  probe "${TAG}-mutaudit" >/dev/null
  logs_have "${TAG}-mutaudit" "${MARKER}" && ok "with parts ABIJDEFHZ the marker leaks — the audit leg sees a leak" ||
    bad "with parts ABIJDEFHZ the marker did not leak — the audit leg is blind"
fi

[ "${FAILED}" -eq 0 ] || {
  printf '\033[0;31m[M227] FAIL — app content, a migration, a raw statement or a mail is refused, an exclusion reaches past its path, Funnel reaches a private route, or the audit log holds a credential\033[0m\n' >&2
  exit 1
}
printf '\033[0;32m[M227] PASS — osionos_* writes carry code, migrations, raw statements and mails carry their SQL or HTML; other paths stay inspected; Funnel reaches no private route; no credential in the audit\033[0m\n'
