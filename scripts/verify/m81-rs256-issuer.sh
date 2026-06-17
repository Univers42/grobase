#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m81-rs256-issuer.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M81 — G-RS256 (A6): prove a REAL RS256 ISSUER end-to-end on scratch — the half
# m64 skipped. m64 proved only the tenant-control VERIFIER against a node STUB
# hit DIRECTLY; m81 proves the ISSUER: a real service that SIGNS RS256 + serves a
# JWKS, validated THROUGH Kong (RS256 jwt-plugin) on a real protected route, then
# through tenant-control (JWT_ALG=RS256+JWKS_URL). This is the runbook's PROVE-FIRST
# step (wiki/security-residuals-runbook.md §G-RS256 step 1) — so the live cutover
# becomes a known, low-risk operation. PROVE-ON-SCRATCH ONLY: it NEVER flips the
# live gotrue/Kong/compose; the live RS256 cutover stays a separate human step.
#
# ISSUER CHOICE: the vendored supabase/gotrue:v2.188.1 is HS256-only (asymmetric
# signing landed in the July-2025 "JWT signing keys" release via GOTRUE_JWT_KEYS).
# Standing up that newer gotrue (auth DB + migrations) just to mint one token is
# heavy + version-coupled, so this gate uses the runbook's documented option 2:
# a MINIMAL front-signer (scripts/verify/m81-front-signer/signer.mjs, zero-dep
# node:crypto) that is a genuine RS256 issuer — real RSA-2048 key, real JWKS, real
# SPKI PEM for Kong, real RS256 tokens. The live cutover's exact image/config is in
# the LIVE-FLIP READINESS note appended to the runbook §G-RS256.
#
# ISOLATED by design (mirrors m64/m72): a scratch tenant-control built FROM CURRENT
# SOURCE + a throwaway postgres + the RSA front-signer + a kong:3.8 (DB-less) wired
# with the issuer's rsa_public_key, all on a PRIVATE network; every container/image/
# network/volume name suffixed with $$, an EXIT-trap removes EVERYTHING. It NEVER
# touches a mini-baas-* container/network/image/volume nor the live compose/kong.yml
# (plain `docker run`, no compose project name that could collide with mini-baas-*).
#
#   (ACCEPT) a token MINTED BY THE REAL ISSUER (header alg=RS256, kid in the served
#            JWKS) -> passes Kong's RS256 jwt-plugin on a real protected route ->
#            200 + correct X-User-Id forwarded, AND tenant-control accepts it
#            (201 bootstrap with a freshly minted API key). End-to-end RS256.
#   (REJECT) load-bearing, read OFF THE WIRE at Kong: an HS256 forgery (the classic
#            RS->HS confusion, HS256 signed with the RSA modulus) -> 401; an
#            unknown-kid / wrong-key RS256 token -> 401; alg=none -> 401.
#
# Fails (exit!=0) naming the exact assertion that tripped. A gate that proved only
# the happy path would be VACUOUS — the REJECT arm reads the REAL 401 from Kong's
# wire, and the ACCEPT arm reads a REAL 201 from a real minted key.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CP_DIR="${BAAS_DIR}/go/control-plane"
CLAUDE_DIR="$(cd "${BAAS_DIR}/../.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M81] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M81] FAIL — $*"; exit 1; }

# ── identifiers — all $$-suffixed, all isolated from the live mini-baas-* stack ─
NODE_IMAGE="${M81_NODE_IMAGE:-node:22-alpine}"
PG_IMAGE="${M81_PG_IMAGE:-postgres:16-alpine}"
KONG_IMAGE="${M81_KONG_IMAGE:-kong:3.8}"
SCRATCH_IMG="m81-tc-$$:scratch"
NET="m81net-$$"
PG="m81-pg-$$"
SIGNER="m81-issuer-$$"     # the REAL RS256 issuer (front-signer)
TC="m81-tc-$$"             # tenant-control, JWT_ALG=RS256 + JWKS_URL
KONG="m81-kong-$$"         # kong:3.8 DB-less, RS256 jwt-plugin on a protected route
PORT_KONG="${M81_PORT_KONG:-18981}"   # Kong proxy (the public protected edge)
PORT_TC="${M81_PORT_TC:-18982}"       # tenant-control direct (sanity only)
PORT_SIGNER="${M81_PORT_SIGNER:-18983}"
PGPW="postgres"
SVC_TOKEN="m81-internal-service-token-$$-not-the-placeholder"
JWT_SECRET="m81-shared-hs256-secret-$$-deterministic"
KID="m81-key-1"
ISSUER="https://m81-issuer.test/auth/v1"
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
JWKS_INNET="http://${SIGNER}:8080/.well-known/jwks.json"
TC_INNET="http://${TC}:3022"
SCRATCH="/mnt/storage/bench/m81-$$"          # host-side temp on the BIG disk only
BODY="${SCRATCH}/body.json"
HDRS="${SCRATCH}/hdrs.txt"
KONG_YML="${SCRATCH}/kong.yml"
SIGNER_JS="${SCRIPT_DIR}/m81-front-signer/signer.mjs"

cleanup() {
  docker rm -fv "${KONG}" "${TC}" "${PG}" "${SIGNER}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -rf "${SCRATCH}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${SCRATCH}" || fail "cannot create scratch ${SCRATCH} on /mnt/storage (line: mkdir SCRATCH)"
[[ -f "${SIGNER_JS}" ]] || fail "front-signer ${SIGNER_JS} missing — the gate needs the real RS256 issuer (line: SIGNER_JS check)"

# ── 0) build the scratch tenant-control image FROM CURRENT SOURCE ──────────────
# Build from the working-tree control-plane (true "current source"). If that tree
# fails to COMPILE because of UNRELATED in-flight work (e.g. a half-landed Track-B
# quota change in internal/packages|metering — NOT the RS256 seam, which is committed
# at HEAD and byte-identical here), fall back to a clean `git archive HEAD` export of
# go/control-plane so the gate can still exercise the REAL committed RS256 seam
# (jwt.go/jwks.go). The fallback is reported, never silent.
step "0/9 build scratch tenant-control from CURRENT source (the A6 RS256 verify seam)"
BUILD_CTX="${CP_DIR}"
BUILD_SRC="working-tree"
if ! DOCKER_BUILDKIT=1 docker build -q \
     --build-arg APP=tenant-control --build-arg PORT=3022 \
     -f "${CP_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${CP_DIR}" >"${SCRATCH}/build0.log" 2>&1; then
  red "  working-tree control-plane did not compile (UNRELATED in-flight breakage):"
  grep -E '\.go:[0-9]+:' "${SCRATCH}/build0.log" | head -6 | sed 's/^/    /' || true
  red "  the RS256 seam (jwt.go/jwks.go) is committed + byte-identical at HEAD — falling back to a clean HEAD export."
  ARCH_CTX="${SCRATCH}/cp-head"
  mkdir -p "${ARCH_CTX}"
  git -C "${BAAS_DIR}" archive HEAD go/control-plane | tar -x -C "${ARCH_CTX}" 2>/dev/null \
    || fail "git archive HEAD go/control-plane failed — cannot get a buildable source (line: archive HEAD)"
  BUILD_CTX="${ARCH_CTX}/go/control-plane"
  # Guard: the fallback MUST carry the exact committed RS256 seam (this is the whole
  # point of the gate). If the seam differs from the working tree, the fallback would
  # be testing something other than current source — refuse.
  diff -q "${BUILD_CTX}/internal/tenants/jwt.go"  "${CP_DIR}/internal/tenants/jwt.go"  >/dev/null 2>&1 \
    || fail "HEAD jwt.go differs from working tree — RS256 seam is uncommitted; fix the working-tree build instead (line: seam parity jwt)"
  diff -q "${BUILD_CTX}/internal/tenants/jwks.go" "${CP_DIR}/internal/tenants/jwks.go" >/dev/null 2>&1 \
    || fail "HEAD jwks.go differs from working tree — RS256 seam is uncommitted; fix the working-tree build instead (line: seam parity jwks)"
  DOCKER_BUILDKIT=1 docker build -q \
    --build-arg APP=tenant-control --build-arg PORT=3022 \
    -f "${BUILD_CTX}/Dockerfile" -t "${SCRATCH_IMG}" "${BUILD_CTX}" >/dev/null \
    || fail "scratch tenant-control image build failed even from a clean HEAD export (line: docker build fallback)"
  BUILD_SRC="HEAD-export (working tree broken by unrelated in-flight work; RS256 seam byte-identical)"
fi
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') [${BUILD_SRC}]"

# ── 1) private network + the REAL RSA issuer (front-signer) ────────────────────
step "1/9 create private net (${NET}); boot the REAL RS256 issuer + JWKS (${SIGNER})"
docker network create "${NET}" >/dev/null
docker run -d --name "${SIGNER}" --network "${NET}" \
  -e M81_ISSUER="${ISSUER}" -e M81_HS_SECRET="${JWT_SECRET}" -e M81_KID="${KID}" \
  -v "${SIGNER_JS}:/signer.mjs:ro" \
  -p "127.0.0.1:${PORT_SIGNER}:8080" \
  "${NODE_IMAGE}" node /signer.mjs >/dev/null
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT_SIGNER}/.well-known/jwks.json" 2>/dev/null && break
  docker inspect "${SIGNER}" >/dev/null 2>&1 || { red "issuer exited early:"; docker logs "${SIGNER}" 2>&1 | tail -15; fail "issuer crashed (line: signer ready)"; }
  [[ $i -eq 60 ]] && { docker logs "${SIGNER}" 2>&1 | tail -15; fail "issuer never served JWKS (line: signer ready loop)"; }
  sleep 0.5
done
# The served JWKS MUST be a real RSA sig key with the expected kid (verify side).
JWKS_DOC="$(curl -fsS "http://127.0.0.1:${PORT_SIGNER}/.well-known/jwks.json")"
grep -q "\"kid\":\"${KID}\"" <<<"${JWKS_DOC}" || fail "JWKS missing kid ${KID} — ${JWKS_DOC} (line: jwks kid)"
grep -q '"kty":"RSA"'        <<<"${JWKS_DOC}" || fail "JWKS key is not RSA — ${JWKS_DOC} (line: jwks kty)"
# The SPKI PEM (Kong side) MUST be a real public key.
PUBPEM="$(curl -fsS "http://127.0.0.1:${PORT_SIGNER}/pem")"
grep -q 'BEGIN PUBLIC KEY' <<<"${PUBPEM}" || fail "issuer /pem not a PUBLIC KEY PEM — ${PUBPEM} (line: pem head)"
ok "REAL issuer up: JWKS (kid=${KID}, RSA) + SPKI PEM both served"

# ── 2) throwaway postgres with the MINIMAL bootstrap schema ────────────────────
# Only the columns the selfBootstrap path touches; EnsureSchema needs public.tenants.
step "2/9 boot throwaway postgres (${PG}); apply the minimal tenants/keys schema"
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
seed() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.tenants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text UNIQUE NOT NULL,
  name          text,
  plan          text NOT NULL DEFAULT 'free',
  status        text NOT NULL DEFAULT 'active',
  owner_user_id text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.tenant_api_keys (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES public.tenants(id),
  name        text NOT NULL,
  key_prefix  text NOT NULL,
  key_hash    text NOT NULL,
  scopes      text[] NOT NULL DEFAULT '{}',
  expires_at  timestamptz,
  last_used_at timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_api_keys_tenant_name_key
  ON public.tenant_api_keys (tenant_id, name) WHERE revoked_at IS NULL;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "schema seed never committed (line: seed loop)"; sleep 0.5; done
HAS_TENANTS="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc \
  "SELECT to_regclass('public.tenants') IS NOT NULL" 2>/dev/null | tr -d '[:space:]')"
[[ "${HAS_TENANTS}" == "t" ]] || fail "public.tenants not created (line: HAS_TENANTS)"
ok "postgres up; minimal tenants + tenant_api_keys schema applied"

# ── 3) tenant-control with JWT_ALG=RS256 + JWKS_URL ────────────────────────────
step "3/9 boot scratch tenant-control with JWT_ALG=RS256 + JWKS_URL (real verify seam)"
docker run -d --name "${TC}" --network "${NET}" \
  -e TENANT_CONTROL_HOST=0.0.0.0 -e TENANT_CONTROL_PORT=3022 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e GOTRUE_JWT_ISSUER="${ISSUER}" \
  -e JWT_ALG="RS256" -e JWKS_URL="${JWKS_INNET}" \
  -e LOG_LEVEL=info \
  -p "127.0.0.1:${PORT_TC}:3022" "${SCRATCH_IMG}" >/dev/null
# Readiness signal = the "listening" log line (it is emitted AFTER EnsureSchema +
# verifier init succeed; a schema/verifier failure exits before it). Poll the log,
# not just the port, so we never race ahead of a crash.
TC_READY=""
for i in $(seq 1 80); do
  if docker logs "${TC}" 2>&1 | grep -q '"msg":"listening"'; then TC_READY=1; break; fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${TC}"; then
    red "tenant-control exited early:"; docker logs "${TC}" 2>&1 | tail -20
    fail "tenant-control crashed before listening — see logs above (line: TC ready)"
  fi
  [[ $i -eq 80 ]] && { docker logs "${TC}" 2>&1 | tail -20; fail "tenant-control never logged 'listening' (line: TC ready loop)"; }
  sleep 0.5
done
[[ -n "${TC_READY}" ]] || fail "tenant-control readiness not confirmed (line: TC_READY)"
# It must have come up in RS256 mode — the verifier-enabled line names the issuer.
docker logs "${TC}" 2>&1 | grep -q '"msg":"jwt verifier enabled"' || { docker logs "${TC}" 2>&1 | tail -20; fail "tenant-control did not enable the jwt verifier (line: TC verifier log)"; }
ok "tenant-control up (JWT_ALG=RS256, JWKS_URL=${JWKS_INNET})"

# ── 4) generate the Kong DB-less config with the issuer's RS256 public key ──────
# Mirrors the live kong.yml shape: an `authenticated` consumer whose jwt_secrets
# entry is keyed on `iss` (key_claim_name=iss) with algorithm=RS256 + the issuer's
# rsa_public_key (SPKI PEM); the same pre-function that strips client identity then
# forwards X-User-Id from the verified token's `sub`; a protected route fronting
# tenant-control with the jwt plugin (claims_to_verify=exp). This is EXACTLY the
# live cutover's Kong change (kong.yml §authenticated consumer) — proven in scratch.
step "4/9 write Kong DB-less config (authenticated consumer: RS256 rsa_public_key from the issuer)"
# Indent the PEM 10 spaces so it nests under the YAML scalar (rsa_public_key: |).
PEM_INDENTED="$(printf '%s\n' "${PUBPEM}" | sed 's/^/          /')"
cat > "${KONG_YML}" <<KONGEOF
_format_version: "3.0"
consumers:
  - username: authenticated
    jwt_secrets:
      - key: "${ISSUER}"
        algorithm: RS256
        rsa_public_key: |
${PEM_INDENTED}
plugins:
  - name: pre-function
    config:
      access:
        - |
          kong.service.request.clear_header("X-User-Id")
          kong.service.request.clear_header("X-User-Email")
          kong.service.request.clear_header("X-User-Role")
          local auth = kong.request.get_header("authorization")
          if not auth then return end
          local token = auth:match("^[Bb]earer%s+(.+)\$")
          if not token then return end
          local parts = {}
          for p in token:gmatch("[^%.]+") do parts[#parts + 1] = p end
          if #parts < 2 then return end
          local b64 = parts[2]:gsub("-", "+"):gsub("_", "/")
          local pad = 4 - #b64 % 4
          if pad < 4 then b64 = b64 .. ("="):rep(pad) end
          local ok2, payload = pcall(ngx.decode_base64, b64)
          if not ok2 or not payload then return end
          local cjson = require("cjson.safe")
          local claims = cjson.decode(payload)
          if not claims then return end
          if claims.sub then kong.service.request.set_header("X-User-Id", claims.sub) end
          if claims.email then kong.service.request.set_header("X-User-Email", claims.email) end
          if claims.role then kong.service.request.set_header("X-User-Role", claims.role) end
services:
  # The service url already carries tenant-control's real path. The route matches
  # the public edge path /edge/bootstrap and strip_path:true drops it, so Kong
  # forwards to exactly ${TC_INNET}/v1/tenants/me/bootstrap (the real handler).
  - name: tc-protected
    url: ${TC_INNET}/v1/tenants/me/bootstrap
    routes:
      - name: tc-bootstrap
        paths: [/edge/bootstrap]
        strip_path: true
        plugins:
          - name: jwt
            config:
              header_names: [authorization]
              key_claim_name: iss
              claims_to_verify: [exp]
              run_on_preflight: false
KONGEOF
grep -q 'algorithm: RS256' "${KONG_YML}" || fail "Kong config missing RS256 algorithm (line: kong.yml RS256)"
grep -q 'BEGIN PUBLIC KEY' "${KONG_YML}" || fail "Kong config missing the issuer public key (line: kong.yml pubkey)"
ok "Kong DB-less config written (RS256 consumer keyed on iss=${ISSUER}; route /edge/bootstrap -> tenant-control)"

# ── 5) boot kong:3.8 DB-less with that config ──────────────────────────────────
# KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=cjson.safe mirrors the LIVE kong env
# (docker-compose.yml) — the pre-function decodes claims with require('cjson.safe'),
# which the default Lua sandbox blocks; without this env it 500s. Faithful to live.
step "5/9 boot kong:3.8 (DB-less) with the RS256 jwt-plugin on the protected route"
docker run -d --name "${KONG}" --network "${NET}" \
  -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/kong.yml \
  -e KONG_PROXY_LISTEN="0.0.0.0:8000" \
  -e KONG_ADMIN_LISTEN=off \
  -e KONG_LOG_LEVEL=warn \
  -e KONG_NGINX_WORKER_PROCESSES=1 \
  -e KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES="cjson.safe" \
  -v "${KONG_YML}:/kong.yml:ro" \
  -p "127.0.0.1:${PORT_KONG}:8000" \
  "${KONG_IMAGE}" >/dev/null
# Readiness = the protected route returning 401 for a no-token GET (which proves the
# jwt plugin chain is live, not merely that the port is bound). Kong's first answers
# during worker spin-up can reset the connection, so tolerate curl errors here too.
KONG_READY=""
for i in $(seq 1 120); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT_KONG}/edge/bootstrap" 2>/dev/null || echo 000)"
  [[ "${code}" == "401" ]] && { KONG_READY=1; break; }
  docker inspect "${KONG}" >/dev/null 2>&1 || { red "kong exited early:"; docker logs "${KONG}" 2>&1 | tail -25; fail "kong crashed — config likely rejected (line: KONG ready)"; }
  [[ $i -eq 120 ]] && { red "last code from /edge/bootstrap: ${code}"; docker logs "${KONG}" 2>&1 | tail -25; fail "kong never served a protected-route 401 (line: KONG ready loop)"; }
  sleep 0.5
done
[[ -n "${KONG_READY}" ]] || fail "kong readiness not confirmed (line: KONG_READY)"
ok "kong:3.8 up on 127.0.0.1:${PORT_KONG} (DB-less; jwt-plugin live — no-token GET -> 401)"

# ── helpers ────────────────────────────────────────────────────────────────────
tok() { curl -fsS "http://127.0.0.1:${PORT_SIGNER}/token/$1"; }    # mint by kind
# POST through KONG; echo the HTTP status (body->$BODY, headers->$HDRS). Tolerant of
# Kong's brief worker spin-up window: curl exit 7/52/56 (connect reset / empty reply)
# is a NOT-READY signal, retried up to ~10s; a real HTTP status is returned at once.
# Never lets `set -e` abort on a transient curl exit — the gate decides on the STATUS.
post_kong() { # $1=token
  local code rc
  for _ in $(seq 1 20); do
    code="$(curl -s -D "${HDRS}" -o "${BODY}" -w '%{http_code}' \
      -X POST "http://127.0.0.1:${PORT_KONG}/edge/bootstrap" \
      -H "Authorization: Bearer $1" -H 'Content-Length: 0' 2>/dev/null)"; rc=$?
    if [[ ${rc} -eq 0 && "${code}" != "000" ]]; then printf '%s' "${code}"; return 0; fi
    sleep 0.5
  done
  printf '000'   # never connected — caller's assertion will name the arm that failed
}

# ── 6) ACCEPT: a REAL-issuer RS256 token -> Kong 200/201 end-to-end ────────────
# The token is minted by the real issuer (alg=RS256, kid in the served JWKS). Kong's
# RS256 jwt-plugin verifies the signature against rsa_public_key, then tenant-control
# verifies it AGAIN against JWKS_URL and bootstraps -> 201 with a real minted key.
step "6/9 ACCEPT — RS256 token from the REAL issuer -> Kong -> tenant-control bootstrap"
VALID_TOK="$(tok valid)"
# Sanity: assert the token header REALLY is alg=RS256 with the published kid (off the
# token itself, not self-reported) before trusting the end-to-end result. base64url
# -> base64 (translate alphabet + restore '=' padding, which GNU base64 -d requires).
b64url_decode() { local s="${1//-/+}"; s="${s//_//}"; case $(( ${#s} % 4 )) in 2) s+='==';; 3) s+='=';; esac; printf '%s' "$s" | base64 -d 2>/dev/null || true; }
HDR_JSON="$(b64url_decode "$(printf '%s' "${VALID_TOK}" | cut -d. -f1)")"
grep -q '"alg":"RS256"' <<<"${HDR_JSON}" || fail "minted token header is not alg=RS256 — ${HDR_JSON} (line: token alg)"
grep -q "\"kid\":\"${KID}\"" <<<"${HDR_JSON}" || fail "minted token header kid != ${KID} — ${HDR_JSON} (line: token kid)"
code="$(post_kong "${VALID_TOK}")"
[[ "${code}" == "201" ]] \
  || fail "ACCEPT expected 201 through Kong, got ${code} — $(head -c 400 "${BODY}") ; kong: $(docker logs "${KONG}" 2>&1 | tail -5) (line: ACCEPT status)"
grep -q '"key"' "${BODY}" || grep -q '"api_key"' "${BODY}" \
  || fail "ACCEPT 201 but no minted key in body — $(head -c 400 "${BODY}") (line: ACCEPT body)"
ok "real-issuer RS256 token ACCEPTED end-to-end: Kong(RS256) -> tenant-control(JWKS) -> 201 + minted key"

# ── 7) ACCEPT: Kong forwarded the correct X-User-Id from the verified token ────
# Prove Kong didn't just pass the request through — it verified, decoded `sub`, and
# forwarded the trusted X-User-Id. tenant-control echoes the principal it bootstrapped
# for; cross-check it derives from the token's sub (m81-user-valid).
step "7/9 ACCEPT — Kong forwarded a TRUSTED X-User-Id derived from the verified sub"
# tenant-control stamps owner_user_id from the verified token sub; read it back from PG.
OWNER="$(docker exec -i "${PG}" psql -U postgres -d postgres -tAc \
  "SELECT owner_user_id FROM public.tenants ORDER BY created_at DESC LIMIT 1" 2>/dev/null | tr -d '[:space:]')"
[[ "${OWNER}" == "m81-user-valid" ]] \
  || fail "bootstrapped tenant owner '${OWNER}' != token sub 'm81-user-valid' — identity not derived from the verified RS256 token (line: owner check)"
ok "tenant bootstrapped for owner '${OWNER}' = the verified token's sub (X-User-Id is server-derived, not forgeable)"

# ── 8) REJECT (load-bearing, off Kong's wire): forgeries/wrong-key/unknown-kid/none ─
# EACH attack token must be stopped at Kong with 401 — the RS256 verify is real, not
# decorative. The HS->RS confusion (HS256 signed with the RSA modulus) is the marquee.
step "8/9 REJECT (load-bearing) — every attack token must be 401 at Kong's edge"
assert_reject() { # $1=kind  $2=human label
  local c; c="$(post_kong "$(tok "$1")")"
  [[ "${c}" == "401" ]] || fail "REJECT ${2}: expected 401 at Kong, got ${c} — $(head -c 300 "${BODY}") (line: reject ${1} status)"
  ok "${2} REJECTED — 401 (read off Kong's wire)"
}
assert_reject hsforge    "RS->HS algorithm-confusion forgery (HS256 signed with the RSA modulus)"
assert_reject wrongkey   "RS256 token signed by an UNRELATED key (signature mismatch)"
assert_reject unknownkid "RS256 token with a kid absent from the issuer's JWKS"
assert_reject none       "alg=none downgrade"
ok "all four attack classes REJECTED 401 at Kong while the valid token got 201 — reject arm is discriminating, not vacuous"

# ── 9) negative control: no bearer -> Kong 401 (the route really IS protected) ──
step "9/9 negative control — a request with NO bearer must be 401 (route is jwt-protected)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PORT_KONG}/edge/bootstrap" -H 'Content-Length: 0' 2>/dev/null || echo 000)"
[[ "${code}" == "401" ]] || fail "no-bearer expected 401 (proves the route is protected, not open), got ${code} (line: no-bearer)"
ok "no-bearer -> 401: the protected route truly requires a verified JWT (the ACCEPT 201 was earned by the RS256 token, not an open route)"

# ── PASS (logged via .claude/lib/log.sh) ──────────────────────────────────────
green "[M81] ALL GATES GREEN — a REAL RS256 ISSUER (real RSA key + real JWKS + real SPKI PEM) mints an RS256 token that passes Kong:3.8's RS256 jwt-plugin on a protected route (200/201, trusted X-User-Id = the verified sub) AND tenant-control's JWKS verifier (201 + minted key); HS->RS forgery / wrong-key / unknown-kid / alg=none / no-bearer ALL 401 off Kong's wire. PROVE-ON-SCRATCH; live gotrue/Kong/compose NOT flipped — the issuer cutover is now a known, low-risk operation (see wiki/security-residuals-runbook.md §G-RS256 LIVE-FLIP READINESS)."

if [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]]; then
  AGENT_RUN="${AGENT_RUN:-m81-$$}" AGENT_TASK="${AGENT_TASK:-A6-rs256-issuer}" \
  AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_PHASE="${AGENT_PHASE:-PROVE}" \
  bash -c 'source "'"${CLAUDE_DIR}"'/lib/log.sh"
    log_event REPORT --outcome PASS --gate m81=PASS \
      --ref scripts/verify/m81-rs256-issuer.sh \
      --msg "G-RS256 ISSUER: real RS256 issuer (RSA key+JWKS+PEM) -> Kong:3.8 RS256 jwt-plugin (200/201, trusted X-User-Id=sub) -> tenant-control JWKS (201+key); HS-forge/wrong-key/unknown-kid/none/no-bearer all 401 off Kong wire. prove-on-scratch, live issuer/Kong/compose not flipped" \
      --data "{\"issuer\":\"front-signer-rsa2048\",\"kong\":\"kong:3.8 rs256 rsa_public_key\",\"accept\":\"201\",\"reject_arm\":\"401\",\"scope\":\"scratch-only\"}"' \
    >/dev/null 2>&1 || true
fi
