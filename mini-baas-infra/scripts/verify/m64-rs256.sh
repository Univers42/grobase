#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m64-rs256.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M64 — G-RS256 (A6) headline residual. Proves the tenant-control USER-JWT
# verifier can validate RS256 tokens against a served JWKS behind a flag
# (JWT_ALG=RS256 + JWKS_URL), DEFAULTING to HS256 so the live issuer path is
# byte-identical when the flag is OFF. PROVE-ON-SCRATCH ONLY — this gate NEVER
# flips the live issuer/gotrue/Kong/compose; the LIVE RS256 cutover is human-held
# (see wiki/security-residuals-runbook.md §G-RS256).
#
# The seam under test (internal/tenants/jwt.go NewJWTVerifier + jwks.go):
#   JWT_ALG="" | "HS256"  -> HS256 with the shared GOTRUE_JWT_SECRET (default)
#   JWT_ALG="RS256"       -> verify-only against rotating RSA pubkeys at JWKS_URL,
#                            PINNED to one alg (algorithm-confusion class closed).
# Exercised through the REAL HTTP handler POST /v1/tenants/me/bootstrap, which
# calls rt.jwt.Verify(Authorization) and returns 401 {"error":"invalid_token"}
# on any verify failure, or 201 with a fresh API key on success.
#
# ISOLATED by design (mirrors m72): a scratch tenant-control built FROM CURRENT
# SOURCE + a throwaway postgres + a node:22-alpine RSA signer/JWKS endpoint, all
# on a PRIVATE network, every container/image/network/volume name suffixed with
# $$, an EXIT-trap that removes EVERYTHING. It NEVER touches a mini-baas-*
# container/network/image/volume — safe while the live stack is up. No compose
# project name that could collide with mini-baas-* (plain `docker run`).
#
#   (ON·ACCEPT)  JWT_ALG=RS256 + JWKS_URL: a token signed by the JWKS private key
#                -> 201 + an API key (the RS256 path verifies & is ACCEPTED).
#   (ON·REJECT)  load-bearing: an HS256-forgery signed with the RSA modulus bytes
#                (the classic RS->HS confusion), a wrong-key RS256 token, an
#                unknown-kid token, and an alg=none token -> EACH 401 invalid_token.
#   (OFF·PARITY) no JWT_ALG (default HS256): a token signed with the shared
#                JWT_SECRET -> 201 (HS256 verify byte-identical to today), AND an
#                RS256 token -> 401 (OFF really is pinned-HS256, behavior unchanged).
#
# Fails (exit!=0) naming the exact assertion that tripped if any arm misbehaves.
# A gate that proved only the happy path would be VACUOUS — the REJECT arm here
# reads the REAL 401 from the wire, not a self-reported value.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CP_DIR="${BAAS_DIR}/go/control-plane"
CLAUDE_DIR="$(cd "${BAAS_DIR}/../.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M64] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M64] FAIL — $*"; exit 1; }

# ── identifiers — all $$-suffixed, all isolated from the live mini-baas-* stack ─
NODE_IMAGE="${M64_NODE_IMAGE:-node:22-alpine}"
PG_IMAGE="${M64_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m64-tc-$$:scratch"
NET="m64net-$$"
PG="m64-pg-$$"
SIGNER="m64-jwks-$$"
TC_ON="m64-tc-on-$$"     # ON  arm: JWT_ALG=RS256 + JWKS_URL
TC_OFF="m64-tc-off-$$"   # OFF arm: default HS256 (parity)
PORT_ON="${M64_PORT_ON:-18964}"
PORT_OFF="${M64_PORT_OFF:-18965}"
PORT_SIGNER="${M64_PORT_SIGNER:-18966}"
PGPW="postgres"
# A strong, non-placeholder service token (LoadConfig refuses the weak default).
SVC_TOKEN="m64-internal-service-token-$$-not-the-placeholder"
# The shared HS256 secret used by the OFF/parity arm + the issuer it pins to.
JWT_SECRET="m64-shared-hs256-secret-$$-deterministic"
ISSUER="https://m64-issuer.test/auth/v1"
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
JWKS_INNET="http://${SIGNER}:8080/.well-known/jwks.json"
SCRATCH="/mnt/storage/bench/m64-$$"          # host-side temp on the BIG disk only
BODY="${SCRATCH}/body.json"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" "${SIGNER}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -rf "${SCRATCH}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${SCRATCH}" || fail "cannot create scratch ${SCRATCH} on /mnt/storage (line: mkdir SCRATCH)"

# ── the inline RSA signer + JWKS endpoint (node:22-alpine, zero npm deps) ──────
# It generates ONE RSA keypair (kid=m64-key-1) + a SECOND unrelated key, serves
# the first key's public half at /.well-known/jwks.json, and mints tokens on
# demand. base64url + a hand-built JWS keeps it dependency-free (no jose/PyJWT).
SIGNER_JS="${SCRATCH}/signer.mjs"
cat > "${SIGNER_JS}" <<'NODEEOF'
import http from 'node:http';
import crypto from 'node:crypto';

const KID = 'm64-key-1';
const b64url = (b) => Buffer.from(b).toString('base64url');
// The real signing key (its public half is published in the JWKS) + a SECOND,
// unrelated RSA key whose tokens must be REJECTED (wrong-key arm).
const real = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

// JWKS doc for the REAL key only (n,e from its public JWK export).
const jwk = real.publicKey.export({ format: 'jwk' });
const jwks = { keys: [{ kty: 'RSA', kid: KID, alg: 'RS256', use: 'sig', n: jwk.n, e: jwk.e }] };

const claims = (sub) => ({
  sub, email: sub + '@m64.test', role: 'authenticated',
  aud: 'authenticated', iss: process.env.M64_ISSUER || 'https://m64-issuer.test/auth/v1',
  iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600,
});
const jws = (header, payload, signFn) => {
  const h = b64url(JSON.stringify(header));
  const p = b64url(JSON.stringify(payload));
  const sig = signFn(`${h}.${p}`);
  return `${h}.${p}.${sig}`;
};
const rsSign = (key, data) => crypto.sign('RSA-SHA256', Buffer.from(data), key).toString('base64url');
const hsSign = (secret, data) => crypto.createHmac('sha256', secret).update(data).digest('base64url');

const tokens = {
  // ACCEPT arm: valid RS256, correct kid, signed by the published key.
  valid: () => jws({ alg: 'RS256', typ: 'JWT', kid: KID }, claims('m64-user-valid'),
    (d) => rsSign(real.privateKey, d)),
  // REJECT: RS256 but signed by an UNRELATED key (kid matches the JWKS key, but
  // the signature won't verify against the published modulus).
  wrongkey: () => jws({ alg: 'RS256', typ: 'JWT', kid: KID }, claims('m64-attacker'),
    (d) => rsSign(other.privateKey, d)),
  // REJECT: RS256, valid signature, but a kid that is NOT in the JWKS.
  unknownkid: () => jws({ alg: 'RS256', typ: 'JWT', kid: 'no-such-kid' }, claims('m64-attacker'),
    (d) => rsSign(real.privateKey, d)),
  // REJECT: the classic RS->HS algorithm-confusion forgery — an HS256 token
  // signed using the RSA public modulus bytes as the HMAC secret.
  hsforge: () => {
    const n = Buffer.from(jwk.n, 'base64url'); // the public modulus the attacker knows
    return jws({ alg: 'HS256', typ: 'JWT' }, claims('m64-attacker'), (d) => hsSign(n, d));
  },
  // REJECT: alg=none (empty signature).
  none: () => `${b64url(JSON.stringify({ alg: 'none', typ: 'JWT' }))}.${b64url(JSON.stringify(claims('m64-attacker')))}.`,
  // PARITY (OFF arm accept): a legit HS256 token signed with the SHARED secret.
  hs256: () => jws({ alg: 'HS256', typ: 'JWT' }, claims('m64-user-hs'),
    (d) => hsSign(process.env.M64_JWT_SECRET || 'unset', d)),
};

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/.well-known/jwks.json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(jwks));
  }
  const m = u.pathname.match(/^\/token\/(\w+)$/);
  if (m && tokens[m[1]]) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end(tokens[m[1]]());
  }
  res.writeHead(404); res.end('nope');
}).listen(8080, () => console.error('m64-signer up on :8080'));
NODEEOF

# ── 0) build the scratch tenant-control image FROM CURRENT SOURCE ──────────────
step "0/8 build scratch tenant-control from CURRENT source (contains the A6 RS256 seam)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=tenant-control --build-arg PORT=3022 \
  -f "${CP_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${CP_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — the gate must exercise the real seam (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) private network + the RSA signer/JWKS endpoint ─────────────────────────
step "1/8 create private net (${NET}); boot the RSA signer + JWKS endpoint (${SIGNER})"
docker network create "${NET}" >/dev/null
docker run -d --name "${SIGNER}" --network "${NET}" \
  -e M64_ISSUER="${ISSUER}" -e M64_JWT_SECRET="${JWT_SECRET}" \
  -v "${SIGNER_JS}:/signer.mjs:ro" \
  -p "127.0.0.1:${PORT_SIGNER}:8080" \
  "${NODE_IMAGE}" node /signer.mjs >/dev/null
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT_SIGNER}/.well-known/jwks.json" 2>/dev/null && break
  docker inspect "${SIGNER}" >/dev/null 2>&1 || { red "signer exited early:"; docker logs "${SIGNER}" 2>&1 | tail -15; fail "signer crashed (line: signer ready)"; }
  [[ $i -eq 60 ]] && { docker logs "${SIGNER}" 2>&1 | tail -15; fail "signer never served JWKS (line: signer ready loop)"; }
  sleep 0.5
done
# The served JWKS MUST be a real RSA sig key with the expected kid (sanity: the
# verify path resolves keys by kid from THIS document).
JWKS_DOC="$(curl -fsS "http://127.0.0.1:${PORT_SIGNER}/.well-known/jwks.json")"
grep -q '"kid":"m64-key-1"' <<<"${JWKS_DOC}" || fail "JWKS missing kid m64-key-1 — ${JWKS_DOC} (line: jwks kid)"
grep -q '"kty":"RSA"'       <<<"${JWKS_DOC}" || fail "JWKS key is not RSA — ${JWKS_DOC} (line: jwks kty)"
ok "JWKS endpoint serving an RSA sig key (kid=m64-key-1)"

# ── 2) throwaway postgres with the MINIMAL bootstrap schema ────────────────────
# Only the columns the selfBootstrap path touches (Create + IssueKey +
# findOrCreateForUser + findActiveKeyByName) — no full migration chain needed.
# EnsureSchema only requires public.tenants to exist; the plan-check ALTER is
# non-fatal. A real accept therefore yields a real 201 with a minted key.
step "2/8 boot throwaway postgres (${PG}); apply the minimal tenants/keys schema"
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

# ── helper: boot a scratch tenant-control with a given JWT_ALG/JWKS_URL ────────
boot_tc() { # $1=container  $2=port  $3=JWT_ALG(or "")  $4=JWKS_URL(or "")
  docker run -d --name "$1" --network "${NET}" \
    -e TENANT_CONTROL_HOST=0.0.0.0 -e TENANT_CONTROL_PORT=3022 \
    -e TENANT_CONTROL_PRODUCT_MODE=enabled \
    -e DATABASE_URL="${DSN_INNET}" \
    -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
    -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
    -e GOTRUE_JWT_ISSUER="${ISSUER}" \
    -e JWT_ALG="$3" -e JWKS_URL="$4" \
    -e LOG_LEVEL=info \
    -p "127.0.0.1:$2:3022" "${SCRATCH_IMG}" >/dev/null
}
wait_tc() { # $1=container  $2=port  — tenant-control has no /health; probe a known route
  for i in $(seq 1 60); do
    # GET /v1/tenants is admin-gated but the server answering at all (any HTTP
    # status, even 401/404) proves it booted + bound the port.
    curl -fsS -o /dev/null "http://127.0.0.1:$2/v1/keys/verify" 2>/dev/null && return 0
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/v1/tenants" 2>/dev/null || echo 000)"
    [[ "${code}" != "000" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}
# POST a bootstrap with the given bearer token; echo HTTP status, body->$BODY.
post_bootstrap() { # $1=port  $2=token
  curl -s -o "${BODY}" -w '%{http_code}' -X POST "http://127.0.0.1:$1/v1/tenants/me/bootstrap" \
    -H "Authorization: Bearer $2" -H 'Content-Length: 0'
}
tok() { curl -fsS "http://127.0.0.1:${PORT_SIGNER}/token/$1"; }  # mint a token by kind

# ── 3) ON arm: boot tenant-control with JWT_ALG=RS256 + JWKS_URL ───────────────
step "3/8 boot scratch tenant-control with JWT_ALG=RS256 + JWKS_URL (ON arm)"
boot_tc "${TC_ON}" "${PORT_ON}" "RS256" "${JWKS_INNET}"
wait_tc "${TC_ON}" "${PORT_ON}" || fail "ON-arm tenant-control not ready (line: wait_tc TC_ON)"
# Confirm it actually came up in RS256 mode (boot log line names the verifier).
docker logs "${TC_ON}" 2>&1 | grep -q "jwt verifier enabled" || fail "ON arm did not enable the jwt verifier (line: TC_ON verifier log)"
ok "ON-arm tenant-control up (JWT_ALG=RS256) on 127.0.0.1:${PORT_ON}"

# ── 4) ON·ACCEPT: a valid RS256 token verifies via the JWKS -> 201 + a key ─────
step "4/8 ON·ACCEPT — RS256 token signed by the JWKS key -> POST /me/bootstrap"
code="$(post_bootstrap "${PORT_ON}" "$(tok valid)")"
[[ "${code}" == "201" ]] \
  || fail "ON·ACCEPT expected 201, got ${code} — $(head -c 400 "${BODY}") (line: ON accept status)"
# A real accept mints a real key — the body carries the api_key + a tenant.
grep -q '"key"' "${BODY}" || grep -q '"api_key"' "${BODY}" \
  || fail "ON·ACCEPT 201 but no minted key in the body — $(head -c 400 "${BODY}") (line: ON accept body)"
ok "valid RS256 token ACCEPTED — 201 with a freshly minted API key (the RS256 verify path works)"

# ── 5) ON·REJECT (load-bearing): forgeries/wrong-key/unknown-kid/none -> 401 ───
step "5/8 ON·REJECT (load-bearing) — every attack token must be 401 invalid_token"
assert_reject() { # $1=kind  $2=human label
  local c; c="$(post_bootstrap "${PORT_ON}" "$(tok "$1")")"
  [[ "${c}" == "401" ]] || fail "ON·REJECT ${2}: expected 401, got ${c} — $(head -c 300 "${BODY}") (line: reject ${1} status)"
  grep -q '"invalid_token"' "${BODY}" || grep -q '"unauthorized"' "${BODY}" \
    || fail "ON·REJECT ${2}: 401 but not an auth-error body — $(head -c 300 "${BODY}") (line: reject ${1} body)"
  ok "${2} REJECTED — 401 (read off the wire)"
}
assert_reject hsforge    "RS->HS algorithm-confusion forgery (HS256 signed with the RSA modulus)"
assert_reject wrongkey   "RS256 token signed by an UNRELATED key (signature mismatch)"
assert_reject unknownkid "RS256 token with a kid absent from the JWKS"
assert_reject none       "alg=none downgrade"
# Cross-check the rejects are NOT a blanket 401 (i.e. the ON arm CAN say 201) —
# already proven in step 4, so the reject arm is discriminating, not vacuous.
ok "all four attack classes REJECTED with 401 while a valid token got 201 — reject arm is load-bearing"

# ── 6) OFF/PARITY arm: default HS256 (no JWT_ALG) ──────────────────────────────
step "6/8 boot an IDENTICAL scratch tenant-control with NO JWT_ALG (OFF/default = HS256)"
boot_tc "${TC_OFF}" "${PORT_OFF}" "" ""
wait_tc "${TC_OFF}" "${PORT_OFF}" || fail "OFF-arm tenant-control not ready (line: wait_tc TC_OFF)"
ok "OFF-arm tenant-control up (default HS256) on 127.0.0.1:${PORT_OFF}"

# ── 7) OFF·PARITY accept: an HS256 token signed with the shared secret -> 201 ──
step "7/8 OFF·PARITY — HS256 token signed with the shared JWT_SECRET -> 201 (baseline unchanged)"
code="$(post_bootstrap "${PORT_OFF}" "$(tok hs256)")"
[[ "${code}" == "201" ]] \
  || fail "OFF·PARITY HS256 accept expected 201, got ${code} — $(head -c 400 "${BODY}") (line: OFF accept status)"
ok "default HS256 verify still ACCEPTS a shared-secret token — 201 (live issuer path byte-identical)"

# ── 8) OFF·PARITY reject: an RS256 token must be 401 on the HS256 arm ──────────
# Proves the flag is the ONLY thing that enables RS256: with it OFF the verifier
# is pinned to HS256 and rejects RS256 (no silent dual-alg / no behavior drift).
step "8/8 OFF·PARITY — an RS256 token on the HS256 arm must be REJECTED 401"
code="$(post_bootstrap "${PORT_OFF}" "$(tok valid)")"
[[ "${code}" == "401" ]] \
  || fail "OFF·PARITY RS256 must be 401 (HS256-pinned), got ${code} — $(head -c 300 "${BODY}") (line: OFF reject status)"
grep -q '"invalid_token"' "${BODY}" \
  || fail "OFF·PARITY RS256 reject: 401 but not invalid_token — $(head -c 300 "${BODY}") (line: OFF reject body)"
ok "default arm is pinned to HS256 — an RS256 token is REJECTED (JWT_ALG is the sole gate; OFF = byte-parity)"

# ── PASS (logged via .claude/lib/log.sh) ──────────────────────────────────────
green "[M64] ALL GATES GREEN — JWT_ALG=RS256+JWKS_URL verifies a JWKS-signed RS256 token (201) and REJECTS RS->HS forgery / wrong-key / unknown-kid / alg=none (401); default (no JWT_ALG) stays pinned-HS256 = byte-parity live issuer (HS256 accepted, RS256 rejected). PROVE-ON-SCRATCH; live issuer NOT flipped."

if [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]]; then
  AGENT_RUN="${AGENT_RUN:-m64-$$}" AGENT_TASK="${AGENT_TASK:-A6-rs256}" \
  AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_PHASE="${AGENT_PHASE:-PROVE}" \
  bash -c 'source "'"${CLAUDE_DIR}"'/lib/log.sh"
    log_event REPORT --outcome PASS --gate m64=PASS \
      --ref scripts/verify/m64-rs256.sh \
      --msg "G-RS256: RS256/JWKS verify accepts JWKS-signed token + rejects forgery/wrong-key/unknown-kid/none (401); default HS256 byte-parity (RS256 rejected). prove-on-scratch, live issuer not flipped" \
      --data "{\"flag\":\"JWT_ALG=RS256+JWKS_URL\",\"offIsParity\":true,\"reject_arm\":\"401\",\"scope\":\"scratch-only\"}"' \
    >/dev/null 2>&1 || true
fi
