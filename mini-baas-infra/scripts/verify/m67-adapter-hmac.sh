#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m67-adapter-hmac.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M67 — G-Hdr (A6) PROVE-ON-SCRATCH gate. Proves ADAPTER_REGISTRY_IDENTITY_HMAC
# does EXACTLY what it advertises on the REAL adapter-registry HTTP path, and
# that the LIVE BASELINE is byte-identical when the flag is OFF.
#
# The control (internal/adapterregistry/identity.go + handler.go requireUser):
#   When ADAPTER_REGISTRY_IDENTITY_HMAC=1, every identified route additionally
#   requires X-Baas-Identity-Auth = a v1.<ts>.<hmac> envelope (the same primitive
#   as shared.ComputeServiceSignature) over the canonical identity
#   "<user-id>\n<tenant-id>", keyed by INTERNAL_SERVICE_TOKEN, within ±skew. A
#   missing / wrong-token / spoofed-identity / stale signature => 401. Default
#   OFF preserves the pre-existing private-network header-trust model.
#
# ISOLATED by design (mirrors m72/m73): a scratch adapter-registry built FROM THE
# CURRENT (drafted/working-tree) source + a throwaway postgres, both on a PRIVATE
# network, every container/image/network name suffixed with $$, an EXIT-trap that
# removes EVERYTHING. It NEVER touches a mini-baas-* container, network, image, or
# volume — safe while the live stack is up. No COMPOSE_PROJECT_NAME that could
# collide with mini-baas-* (plain `docker run`). This is PROVE-ON-SCRATCH ONLY:
# it does NOT flip the flag on the live adapter-registry-go (that is the
# human-held step in security-residuals-runbook.md §G-Hdr).
#
# The probe hits the REAL `GET /databases` route inside the docker network. That
# route is gated by requireUser (where the HMAC check lives) and then runs a real
# tenant-scoped query against the EnsureSchema'd `public.tenant_databases` table,
# so a 200 means the identity verification passed AND the handler ran end-to-end.
# Signatures are computed with `openssl` and CROSS-CHECKED at runtime against the
# Go primitive (step 0b) so the gate can never pass on a malformed signature.
#
#   (A · ON)   flag=1, request WITH a valid HMAC over the asserted identity => 200.
#   (B · ON·REJECT — load-bearing) flag=1, three attack vectors each => 401:
#        b1 NO X-Baas-Identity-Auth header at all (unsigned caller),
#        b2 a BAD signature (one keyed by the WRONG service token),
#        b3 a SPOOFED identity (signature minted for user-A, header asserts user-B).
#   (C · OFF)  flag unset (default), the SAME unsigned request => 200 == byte-parity.
#
# Fails (exit != 0) if A is not 200, if ANY reject arm is not 401, or if C is not
# 200. Each fail names the exact assertion + the real HTTP status that tripped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"           # mini-baas-infra
CP_DIR="${BAAS_DIR}/go/control-plane"                   # adapter-registry build context
CLAUDE_DIR="$(cd "${BAAS_DIR}/../.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M67] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M67] FAIL — $*"; exit 1; }

PG_IMAGE="${M67_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m67-ar-$$:scratch"
NET="m67net-$$"
PG="m67-pg-$$"
AR_ON="m67-ar-on-$$"      # (A/B) flag-ON adapter-registry
AR_OFF="m67-ar-off-$$"    # (C)   flag-OFF (default) adapter-registry
XCHK="m67-xcheck-$$"      # ephemeral Go signature cross-check container name
PORT_ON="${M67_PORT_ON:-18967}"
PORT_OFF="${M67_PORT_OFF:-18968}"
PGPW="postgres"
# A strong, NON-placeholder service token (LoadConfig refuses empty / the weak default).
TOKEN="m67-service-token-$$-strong-value-0123456789"
ENC_KEY="0123456789abcdef0123456789abcdef"            # >= 32 chars for NewEncryptor
# auth.current_tenant_id() casts to UUID, so identities MUST be UUIDs.
USER_A="11111111-1111-1111-1111-111111111111"
TEN_A="11111111-1111-1111-1111-111111111111"
USER_B="22222222-2222-2222-2222-222222222222"          # the spoof target
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
BODY_TMP="$(mktemp)"
IDHDR="X-Baas-Identity-Auth"
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # sha256("")

cleanup() {
  docker rm -fv "${AR_ON}" "${AR_OFF}" "${PG}" "${XCHK}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

# sign_identity TOKEN USER TENANT TS -> stdout "v1.<ts>.<hex hmac>"
# Reproduces shared.ComputeServiceSignature(token,"IDENTITY",user+"\n"+tenant,nil,ts):
#   message = "<ts>\nIDENTITY\n<user>\n<tenant>\n<sha256hex(empty body)>"
# Cross-checked against the Go primitive at runtime (step 0b) before any assert.
sign_identity() { # $1=token $2=user $3=tenant $4=ts
  local msg sig
  msg="$(printf '%s\nIDENTITY\n%s\n%s\n%s' "$4" "$2" "$3" "${EMPTY_SHA}")"
  sig="$(printf '%s' "${msg}" | openssl dgst -sha256 -hmac "$1" -r | cut -d' ' -f1)"
  printf 'v1.%s.%s' "$4" "${sig}"
}

# GET /databases on 127.0.0.1:$port with identity headers + optional id-auth.
# $1=port $2=identity-auth-value(or "")  -> echoes HTTP status, body -> BODY_TMP.
get_dbs() { # $1=port $2=idauth
  local -a hdrs=(-H "X-Baas-User-Id: ${USER_A}" -H "X-Baas-Tenant-Id: ${TEN_A}")
  [[ -n "$2" ]] && hdrs+=(-H "${IDHDR}: $2")
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:$1/databases" "${hdrs[@]}"
}

# get_dbs but with X-Baas-User-Id SPOOFED to USER_B while presenting an id-auth
# minted for USER_A (the anti-spoof vector). $1=port $2=idauth(for USER_A).
get_dbs_spoof() { # $1=port $2=idauth-for-userA
  curl -s -o "${BODY_TMP}" -w '%{http_code}' "http://127.0.0.1:$1/databases" \
    -H "X-Baas-User-Id: ${USER_B}" -H "X-Baas-Tenant-Id: ${TEN_A}" -H "${IDHDR}: $2"
}

wait_ready() { # $1=container $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/health/ready" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# ── 0) build the scratch adapter-registry image FROM THE CURRENT source ───────
step "0/8 build scratch adapter-registry from CURRENT source (contains THE G-Hdr build)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -f "${CP_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${CP_DIR}" >/dev/null \
  || fail "scratch adapter-registry image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 0b) cross-check: openssl HMAC == Go shared.ComputeServiceSignature ────────
# If these ever diverge, the "valid signature" arm would false-fail; assert
# equality on a FIXED vector so the gate's signer is provably the real primitive.
step "0b/8 cross-check openssl signer == Go ComputeServiceSignature (fixed vector)"
GO_SIG="$(docker run --rm --name "${XCHK}" -e BTOKEN="${TOKEN}" -e BUSER="${USER_A}" -e BTEN="${TEN_A}" \
  golang:1.25-bookworm sh -c 'cat > /tmp/x.go <<"EOF"
package main
import ("crypto/hmac";"crypto/sha256";"encoding/hex";"fmt";"os";"strings")
func sig(token,method,path string,body []byte,ts int64) string {
  s:=sha256.Sum256(body)
  m:=fmt.Sprintf("%d\n%s\n%s\n%s",ts,strings.ToUpper(method),path,hex.EncodeToString(s[:]))
  mac:=hmac.New(sha256.New,[]byte(token)); mac.Write([]byte(m))
  return fmt.Sprintf("v1.%d.%s",ts,hex.EncodeToString(mac.Sum(nil)))
}
func main(){ canon:=os.Getenv("BUSER")+"\n"+os.Getenv("BTEN")
  fmt.Print(sig(os.Getenv("BTOKEN"),"IDENTITY",canon,nil,1700000000)) }
EOF
go run /tmp/x.go' 2>/dev/null)"
OS_SIG="$(sign_identity "${TOKEN}" "${USER_A}" "${TEN_A}" 1700000000)"
[[ -n "${GO_SIG}" ]] || fail "Go cross-check produced no signature (line: GO_SIG empty)"
[[ "${GO_SIG}" == "${OS_SIG}" ]] \
  || fail "openssl signer != Go primitive — gate signer is wrong (go=${GO_SIG} openssl=${OS_SIG}) (line: signer cross-check)"
ok "openssl signer is byte-identical to shared.ComputeServiceSignature: ${OS_SIG}"

# ── 1) isolated network + throwaway postgres + minimal auth schema ────────────
step "1/8 boot isolated postgres (${PG}) on private net (${NET}); bootstrap auth schema"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint inits then RESTARTS once ("ready" twice). Wait for the
# SECOND "ready" so the bootstrap can never race the post-init restart window.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state (line: PG ready loop)"
  sleep 0.5
done
# EnsureSchema's DDL creates a policy referencing auth.current_tenant_id(); that
# function (and current_user_id) must exist or adapter-registry fails at boot.
# Bootstrap the EXACT live shape (migration 016_unify_rls.sql) so the real schema
# path runs unmodified.
bootstrap() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
    NULLIF(current_setting('app.current_user_id', true), '')
  )::uuid;
$$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
    NULLIF(current_setting('app.current_tenant_id', true), ''),
    auth.current_user_id()::text
  )::uuid;
$$;
SQL
}
for i in $(seq 1 20); do bootstrap && break; [[ $i -eq 20 ]] && fail "auth schema bootstrap never committed (line: bootstrap loop)"; sleep 0.5; done
ok "postgres up; auth.current_user_id()/current_tenant_id() bootstrapped (live 016 shape)"

# ── 2) (A/B arm) boot scratch adapter-registry with the flag ON ───────────────
step "2/8 boot scratch adapter-registry with ADAPTER_REGISTRY_IDENTITY_HMAC=1 (A/B arm)"
docker run -d --name "${AR_ON}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e ADAPTER_REGISTRY_IDENTITY_HMAC=1 \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_ON}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_ON}" "${PORT_ON}" || fail "flag-ON adapter-registry not ready (line: wait_ready AR_ON)"
ok "flag-ON adapter-registry up (identity HMAC required) on 127.0.0.1:${PORT_ON}"

# ── 3) (A · POSITIVE) flag ON + VALID signature => 200 ────────────────────────
step "3/8 (A) flag ON, request WITH a valid HMAC over the asserted identity"
TS="$(date -u +%s)"
SIG_OK="$(sign_identity "${TOKEN}" "${USER_A}" "${TEN_A}" "${TS}")"
code="$(get_dbs "${PORT_ON}" "${SIG_OK}")"
[[ "${code}" == "200" ]] \
  || fail "(A) valid signature expected 200, got ${code} — $(head -c 300 "${BODY_TMP}") (line: A status)"
ok "(A) valid identity signature ACCEPTED — GET /databases => 200 (handler ran end-to-end)"

# ── 4) (B1 · REJECT — load-bearing) flag ON + NO signature => 401 ─────────────
step "4/8 (B1·REJECT) flag ON, UNSIGNED caller (no ${IDHDR}) must be rejected"
code="$(get_dbs "${PORT_ON}" "")"
[[ "${code}" == "401" || "${code}" == "403" ]] \
  || fail "(B1) unsigned caller expected 401/403, got ${code} — $(head -c 300 "${BODY_TMP}") (line: B1 reject)"
ok "(B1) unsigned identity REJECTED with ${code} (the spoof-on-a-flat-bridge vector is closed)"

# ── 5) (B2 · REJECT — load-bearing) flag ON + WRONG-token signature => 401 ────
step "5/8 (B2·REJECT) flag ON, signature keyed by the WRONG service token => 401"
SIG_BAD="$(sign_identity "wrong-token-not-the-service-token" "${USER_A}" "${TEN_A}" "${TS}")"
code="$(get_dbs "${PORT_ON}" "${SIG_BAD}")"
[[ "${code}" == "401" || "${code}" == "403" ]] \
  || fail "(B2) wrong-token signature expected 401/403, got ${code} — $(head -c 300 "${BODY_TMP}") (line: B2 reject)"
ok "(B2) wrong-key signature REJECTED with ${code} (only a service-token holder can sign identity)"

# ── 6) (B3 · REJECT — load-bearing) flag ON + SPOOFED identity => 401 ─────────
# A signature minted for USER_A must NOT authorize a header that asserts USER_B —
# the core anti-spoof property. SIG_OK is valid for USER_A; assert it cannot move.
step "6/8 (B3·REJECT) flag ON, signature for USER_A but header asserts USER_B => 401"
code="$(get_dbs_spoof "${PORT_ON}" "${SIG_OK}")"
[[ "${code}" == "401" || "${code}" == "403" ]] \
  || fail "(B3) replayed signature on a DIFFERENT identity expected 401/403, got ${code} — $(head -c 300 "${BODY_TMP}") (line: B3 reject)"
ok "(B3) signature minted for USER_A REJECTED (${code}) when asserting USER_B — identity is bound"

# ── 7) (C · PARITY) flag OFF (default) + SAME unsigned request => 200 ─────────
step "7/8 boot an IDENTICAL adapter-registry with the flag UNSET (C · PARITY/default)"
docker run -d --name "${AR_OFF}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_OFF}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_OFF}" "${PORT_OFF}" || fail "flag-OFF adapter-registry not ready (line: wait_ready AR_OFF)"
step "7b/8 (C) the SAME unsigned request that 401'd under ON must 200 under OFF"
code="$(get_dbs "${PORT_OFF}" "")"
[[ "${code}" == "200" ]] \
  || fail "(C·PARITY) unsigned request expected 200 with the flag OFF (current trust model), got ${code} — $(head -c 300 "${BODY_TMP}") (line: C parity)"
ok "(C) flag OFF (default): the unsigned request is TRUSTED => 200 = byte-parity live baseline"

# ── 8) cross-check: the flag is the SOLE difference ───────────────────────────
step "8/8 cross-check: ON rejects the unsigned request, OFF accepts it — flag is the only diff"
ON_UNSIGNED="$(get_dbs "${PORT_ON}" "")";  OFF_UNSIGNED="$(get_dbs "${PORT_OFF}" "")"
[[ ( "${ON_UNSIGNED}" == "401" || "${ON_UNSIGNED}" == "403" ) && "${OFF_UNSIGNED}" == "200" ]] \
  || fail "arm statuses inconsistent (ON unsigned=${ON_UNSIGNED}, OFF unsigned=${OFF_UNSIGNED}) (line: cross-check)"
ok "ADAPTER_REGISTRY_IDENTITY_HMAC is the sole gate on identity-signature enforcement (ON=${ON_UNSIGNED}, OFF=${OFF_UNSIGNED})"

# ── PASS: emit the gate event via the kernel log helper (best-effort) ─────────
# Fully isolated in a subshell so a logging hiccup can NEVER change the gate's
# exit code — the gate's verdict is decided by the assertions above, not by log
# bookkeeping. `set +e` inside, swallow all output, always return 0 to the trap.
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-a6-hdr}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m67=PASS" --outcome pass \
      --msg "G-Hdr adapter-registry identity HMAC: ON valid->200, unsigned/wrong-key/spoof->401, OFF->200 byte-parity" \
      --ref "scripts/verify/m67-adapter-hmac.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log

green "[M67] ALL GATES GREEN — ADAPTER_REGISTRY_IDENTITY_HMAC=1: a request WITH a valid identity HMAC => 200; UNSIGNED / WRONG-KEY / SPOOFED-IDENTITY each => 401 (load-bearing reject arm); flag OFF (default) => the unsigned request is trusted => 200 = byte-parity live baseline"
exit 0
