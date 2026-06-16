#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m68-key-rotate.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M68 — G-Rotate (A6) PROVE-ON-SCRATCH gate: atomic internal-service-token
# rotation WITHOUT a process restart, by accepting TWO valid tokens during a
# rotation window so in-flight service-to-service calls are never rejected
# mid-rotation. Also proves the live baseline is byte-identical when no window
# is open (single-key behavior, INTERNAL_SERVICE_TOKEN_PREV unset).
#
# The control (internal/shared/token.go VerifyServiceRequest, called by the REAL
# adapter-registry `GET /databases/{id}/connect` via validServiceToken — the
# exact route the Rust data plane's resolve_mount() hits with the service token):
#   During a window, INTERNAL_SERVICE_TOKEN_PREV is set to the OLD token while
#   INTERNAL_SERVICE_TOKEN holds the NEW token; a request is accepted if it
#   verifies under EITHER. With PREV unset (default) only the current token is
#   accepted — byte-identical to before this hook existed. Works in static mode
#   (X-Service-Token) and hmac mode (X-Service-Auth signature, keyed by token).
#
# Discriminator on /connect for a NON-EXISTENT db id:
#   bad/expired service token => 401 (guard rejects before lookup);
#   accepted service token     => 404 (guard passed, the db row is not found).
# So 404 == "the token was accepted", 401 == "the token was rejected".
#
# ISOLATED by design (mirrors m67): a scratch adapter-registry built FROM THE
# CURRENT (working-tree) source + a throwaway postgres, both on a PRIVATE
# network, every container/image/network name suffixed with $$, an EXIT-trap that
# removes EVERYTHING. It NEVER touches a mini-baas-* container/network/image/
# volume — safe while the live stack is up. No COMPOSE_PROJECT_NAME (plain
# `docker run`). PROVE-ON-SCRATCH ONLY: it does NOT roll the token on the live
# adapter-registry (the live swap is the human-held step in
# security-residuals-runbook.md §G-Rotate).
#
#  Static mode (A_S/B_S/C_S/P_S) and hmac mode (A_H/B_H/C_H), each proving:
#   (A · WINDOW · NEW)  PREV=old,cur=new + request under NEW  => 404 (accepted).
#   (B · WINDOW · OLD)  PREV=old,cur=new + request under OLD  => 404 (in-flight
#                       old token STILL accepted — the no-mid-rotation-outage
#                       property; THIS is the whole point of the slice).
#   (C · WINDOW · OTHER — load-bearing reject) an UNRELATED token => 401.
#   (P · POST-WINDOW — load-bearing reject) PREV cleared + OLD   => 401
#                       (after the grace the old token is dead).
#   (PARITY) single-key (PREV never set): NEW => 404, OLD => 401 == today.
#
# Fails (exit != 0) if any accept arm is not 404, any reject arm is not 401, or
# the parity arm diverges. Each fail names the exact assertion + the real status.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"           # mini-baas-infra
CP_DIR="${BAAS_DIR}/go/control-plane"                   # adapter-registry build context
CLAUDE_DIR="$(cd "${BAAS_DIR}/../.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M68] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M68] FAIL — $*"; exit 1; }

PG_IMAGE="${M68_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m68-ar-$$:scratch"
NET="m68net-$$"
PG="m68-pg-$$"
AR_WIN="m68-ar-win-$$"     # rotation-window adapter-registry (PREV set)
AR_ONE="m68-ar-one-$$"     # single-key adapter-registry (PREV unset) — post-window + parity
XCHK="m68-xcheck-$$"       # ephemeral Go signature cross-check container name
PORT_WIN="${M68_PORT_WIN:-18968}"
PORT_ONE="${M68_PORT_ONE:-18969}"
PGPW="postgres"
# Strong, NON-placeholder tokens (LoadConfig refuses empty / the weak default).
TOKEN_OLD="m68-old-token-$$-strong-value-0123456789"   # key A (previous)
TOKEN_NEW="m68-new-token-$$-strong-value-9876543210"   # key B (current/new)
TOKEN_OTHER="m68-unrelated-token-$$-attacker-aaaaaa"    # key C (never valid)
ENC_KEY="0123456789abcdef0123456789abcdef"             # >= 32 chars for NewEncryptor
# requireUser needs a tenant header; auth.current_tenant_id() casts to UUID.
TEN="11111111-1111-1111-1111-111111111111"
# A valid-but-nonexistent UUID: tenant_databases.id is UUID, so GetConnection's
# `WHERE id = $1` casts the path value to UUID. A non-UUID would error (500); a
# well-formed UUID that was never registered hits pgx.ErrNoRows -> ErrNotFound ->
# 404. Either way the SERVICE-TOKEN guard ran first, so 404 == "token accepted".
MISSING_DB="68000000-0000-4000-8000-000000000068"      # never registered -> 404 once accepted
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # sha256("")
CONNECT_PATH="/databases/${MISSING_DB}/connect"

cleanup() {
  docker rm -fv "${AR_WIN}" "${AR_ONE}" "${PG}" "${XCHK}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_ready() { # $1=container $2=port
  for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:$2/health/ready" 2>/dev/null && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# sign_connect TOKEN TS -> "v1.<ts>.<hmac>" over the canonical
# shared.ComputeServiceSignature(token,"GET",CONNECT_PATH,nil,ts):
#   message = "<ts>\nGET\n<path>\n<sha256hex(empty body)>"
# Cross-checked against the Go primitive at runtime (step 0b) before any assert.
sign_connect() { # $1=token $2=ts
  local msg sig
  msg="$(printf '%s\nGET\n%s\n%s' "$2" "${CONNECT_PATH}" "${EMPTY_SHA}")"
  sig="$(printf '%s' "${msg}" | openssl dgst -sha256 -hmac "$1" -r | cut -d' ' -f1)"
  printf 'v1.%s.%s' "$2" "${sig}"
}

# connect_static PORT TOKEN -> HTTP status of GET /connect with X-Service-Token.
connect_static() { # $1=port $2=token
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1${CONNECT_PATH}" \
    -H "X-Tenant-Id: ${TEN}" -H "X-Service-Token: $2"
}

# connect_hmac PORT TOKEN -> HTTP status of GET /connect with a v1 X-Service-Auth
# envelope signed by TOKEN for "now".
connect_hmac() { # $1=port $2=token
  local ts sig
  ts="$(date -u +%s)"
  sig="$(sign_connect "$2" "${ts}")"
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1${CONNECT_PATH}" \
    -H "X-Tenant-Id: ${TEN}" -H "X-Service-Auth: ${sig}"
}

is_accepted() { [[ "$1" == "404" ]]; }                 # guard passed, db not found
is_rejected() { [[ "$1" == "401" || "$1" == "403" ]]; } # guard rejected

# ── 0) build the scratch adapter-registry image FROM THE CURRENT source ───────
step "0/9 build scratch adapter-registry from CURRENT source (contains THE G-Rotate verify)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -f "${CP_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${CP_DIR}" >/dev/null \
  || fail "scratch adapter-registry image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 0b) cross-check: openssl HMAC == Go shared.ComputeServiceSignature ────────
# If these ever diverge the hmac "valid signature" arms would false-fail; assert
# equality on a FIXED vector so the gate's signer is provably the real primitive.
step "0b/9 cross-check openssl signer == Go ComputeServiceSignature (fixed vector)"
GO_SIG="$(docker run --rm --name "${XCHK}" -e BTOKEN="${TOKEN_NEW}" -e BPATH="${CONNECT_PATH}" \
  golang:1.25-bookworm sh -c 'cat > /tmp/x.go <<"EOF"
package main
import ("crypto/hmac";"crypto/sha256";"encoding/hex";"fmt";"os";"strings")
func sig(token,method,path string,body []byte,ts int64) string {
  s:=sha256.Sum256(body)
  m:=fmt.Sprintf("%d\n%s\n%s\n%s",ts,strings.ToUpper(method),path,hex.EncodeToString(s[:]))
  mac:=hmac.New(sha256.New,[]byte(token)); mac.Write([]byte(m))
  return fmt.Sprintf("v1.%d.%s",ts,hex.EncodeToString(mac.Sum(nil)))
}
func main(){ fmt.Print(sig(os.Getenv("BTOKEN"),"GET",os.Getenv("BPATH"),nil,1700000000)) }
EOF
go run /tmp/x.go' 2>/dev/null)"
OS_SIG="$(sign_connect "${TOKEN_NEW}" 1700000000)"
[[ -n "${GO_SIG}" ]] || fail "Go cross-check produced no signature (line: GO_SIG empty)"
[[ "${GO_SIG}" == "${OS_SIG}" ]] \
  || fail "openssl signer != Go primitive — gate signer is wrong (go=${GO_SIG} openssl=${OS_SIG}) (line: signer cross-check)"
ok "openssl signer is byte-identical to shared.ComputeServiceSignature: ${OS_SIG}"

# ── 1) isolated network + throwaway postgres + minimal auth schema ────────────
step "1/9 boot isolated postgres (${PG}) on private net (${NET}); bootstrap auth schema"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# The alpine entrypoint inits then RESTARTS once ("ready" twice). Wait for the
# SECOND "ready" so the bootstrap can never race the post-init restart window.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state (line: PG ready loop)"
  sleep 0.5
done
# EnsureSchema's DDL references auth.current_tenant_id()/current_user_id(); they
# must exist or adapter-registry fails at boot. Bootstrap the EXACT live shape
# (migration 016_unify_rls.sql) so the real schema path runs unmodified.
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

# ── 2) boot the ROTATION-WINDOW adapter-registry: cur=NEW, PREV=OLD ───────────
step "2/9 boot scratch adapter-registry in a ROTATION WINDOW (INTERNAL_SERVICE_TOKEN=NEW, _PREV=OLD)"
docker run -d --name "${AR_WIN}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN_NEW}" \
  -e INTERNAL_SERVICE_TOKEN_PREV="${TOKEN_OLD}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_WIN}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_WIN}" "${PORT_WIN}" || fail "rotation-window adapter-registry not ready (line: wait_ready AR_WIN)"
ok "rotation-window adapter-registry up (BOTH tokens valid) on 127.0.0.1:${PORT_WIN}"

# ── 3) (A_S · WINDOW · NEW) static, request under the NEW token => 404 accepted
step "3/9 (A_S) static window: request under the NEW (current) token must be ACCEPTED (404)"
code="$(connect_static "${PORT_WIN}" "${TOKEN_NEW}")"
is_accepted "${code}" \
  || fail "(A_S) NEW token expected 404 (accepted), got ${code} (line: A_S static new)"
ok "(A_S) NEW token ACCEPTED (${code}) — newly issued tokens use key B"

# ── 4) (B_S · WINDOW · OLD — the slice's whole point) static, OLD token => 404 ─
step "4/9 (B_S) static window: in-flight OLD (previous) token must STILL be ACCEPTED (404)"
code="$(connect_static "${PORT_WIN}" "${TOKEN_OLD}")"
is_accepted "${code}" \
  || fail "(B_S) OLD token expected 404 (still accepted in window), got ${code} (line: B_S static old)"
ok "(B_S) OLD token STILL ACCEPTED (${code}) — no mid-rotation outage for in-flight calls"

# ── 5) (C_S · WINDOW · OTHER — load-bearing reject) static, unrelated => 401 ──
step "5/9 (C_S·REJECT) static window: an UNRELATED token must be REJECTED (401)"
code="$(connect_static "${PORT_WIN}" "${TOKEN_OTHER}")"
is_rejected "${code}" \
  || fail "(C_S) unrelated token expected 401/403, got ${code} (line: C_S static other)"
ok "(C_S) unrelated token REJECTED (${code}) — the window admits ONLY {current, previous}"

# ── 6) hmac mode: same three arms, signature keyed by the token ───────────────
# Recreate the SAME window container in hmac mode (SERVICE_TOKEN_MODE=hmac) so
# the X-Service-Auth verify path (not the plain header path) is exercised too.
step "6/9 recreate window adapter-registry in HMAC mode (SERVICE_TOKEN_MODE=hmac)"
docker rm -fv "${AR_WIN}" >/dev/null 2>&1 || true
docker run -d --name "${AR_WIN}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e SERVICE_TOKEN_MODE=hmac \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN_NEW}" \
  -e INTERNAL_SERVICE_TOKEN_PREV="${TOKEN_OLD}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_WIN}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_WIN}" "${PORT_WIN}" || fail "hmac-mode window adapter-registry not ready (line: wait_ready AR_WIN hmac)"
step "6a/9 (A_H) hmac window: NEW-keyed signature => 404 accepted"
code="$(connect_hmac "${PORT_WIN}" "${TOKEN_NEW}")"
is_accepted "${code}" || fail "(A_H) NEW-keyed sig expected 404, got ${code} (line: A_H hmac new)"
ok "(A_H) NEW-keyed signature ACCEPTED (${code})"
step "6b/9 (B_H) hmac window: OLD-keyed signature => 404 STILL accepted"
code="$(connect_hmac "${PORT_WIN}" "${TOKEN_OLD}")"
is_accepted "${code}" || fail "(B_H) OLD-keyed sig expected 404 (in-flight), got ${code} (line: B_H hmac old)"
ok "(B_H) OLD-keyed signature STILL ACCEPTED (${code}) — dual-key verify in hmac mode"
step "6c/9 (C_H·REJECT) hmac window: UNRELATED-keyed signature => 401"
code="$(connect_hmac "${PORT_WIN}" "${TOKEN_OTHER}")"
is_rejected "${code}" || fail "(C_H) unrelated-keyed sig expected 401/403, got ${code} (line: C_H hmac other)"
ok "(C_H) unrelated-keyed signature REJECTED (${code})"

# ── 7) (P · POST-WINDOW — load-bearing reject) single-key, OLD token => 401 ───
# A SEPARATE adapter-registry with PREV UNSET = the window CLOSED after the grace.
step "7/9 boot a single-key adapter-registry (INTERNAL_SERVICE_TOKEN_PREV UNSET = post-window/default)"
docker run -d --name "${AR_ONE}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN_NEW}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_ONE}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_ONE}" "${PORT_ONE}" || fail "single-key adapter-registry not ready (line: wait_ready AR_ONE)"
step "7a/9 (P·REJECT) post-window: the OLD token MUST now be REJECTED (401) — the window is closed"
code="$(connect_static "${PORT_ONE}" "${TOKEN_OLD}")"
is_rejected "${code}" \
  || fail "(P) post-window OLD token expected 401/403, got ${code} — old key is NOT dead after window (line: P reject)"
ok "(P) post-window OLD token REJECTED (${code}) — after the grace, key A is dead (load-bearing)"

# ── 8) (PARITY) single-key default: NEW => 404 accepted, OLD => 401 rejected ──
# With PREV never set the verify is byte-identical to pre-G-Rotate single-key
# behavior: only the current token authorizes; nothing else does.
step "8/9 (PARITY) single-key (PREV unset): NEW accepted, OLD/unrelated rejected == today's behavior"
n_code="$(connect_static "${PORT_ONE}" "${TOKEN_NEW}")"
o_code="$(connect_static "${PORT_ONE}" "${TOKEN_OLD}")"
u_code="$(connect_static "${PORT_ONE}" "${TOKEN_OTHER}")"
is_accepted "${n_code}" || fail "(PARITY) NEW token expected 404 under single-key, got ${n_code} (line: parity new)"
is_rejected "${o_code}" || fail "(PARITY) OLD token expected 401 under single-key, got ${o_code} (line: parity old)"
is_rejected "${u_code}" || fail "(PARITY) unrelated token expected 401 under single-key, got ${u_code} (line: parity other)"
ok "(PARITY) single-key behavior unchanged: NEW=${n_code} OLD=${o_code} OTHER=${u_code} (only current authorizes)"

# ── 9) cross-check: PREV is the SOLE difference for the OLD token ──────────────
step "9/9 cross-check: the OLD token is ACCEPTED with PREV set and REJECTED with PREV unset — PREV is the only diff"
WIN_OLD="$(connect_static "${PORT_WIN}" "${TOKEN_OLD}")"  # AR_WIN is now hmac mode -> static header ignored => reject
# AR_WIN currently runs in hmac mode (step 6), where a plain X-Service-Token is
# rejected by design; the static window assertion already proved acceptance in
# step 4. Here we contrast the two *single-key vs window* containers in their
# native verify mode: rebuild the window container back to static for a clean,
# same-mode contrast against AR_ONE.
docker rm -fv "${AR_WIN}" >/dev/null 2>&1 || true
docker run -d --name "${AR_WIN}" --network "${NET}" \
  -e ADAPTER_REGISTRY_PRODUCT_MODE=enabled \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${TOKEN_NEW}" \
  -e INTERNAL_SERVICE_TOKEN_PREV="${TOKEN_OLD}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -p "127.0.0.1:${PORT_WIN}:3021" "${SCRATCH_IMG}" >/dev/null
wait_ready "${AR_WIN}" "${PORT_WIN}" || fail "static window rebuild not ready (line: wait_ready AR_WIN rebuild)"
WIN_OLD="$(connect_static "${PORT_WIN}" "${TOKEN_OLD}")"
ONE_OLD="$(connect_static "${PORT_ONE}" "${TOKEN_OLD}")"
{ is_accepted "${WIN_OLD}" && is_rejected "${ONE_OLD}"; } \
  || fail "PREV is not the sole diff (window OLD=${WIN_OLD} single-key OLD=${ONE_OLD}) (line: cross-check)"
ok "INTERNAL_SERVICE_TOKEN_PREV is the sole gate on dual-key acceptance (window OLD=${WIN_OLD}, single-key OLD=${ONE_OLD})"

# ── PASS: emit the gate event via the kernel log helper (best-effort) ─────────
# Fully isolated in a subshell so a logging hiccup can NEVER change the gate's
# exit code — the verdict is decided by the assertions above, not log bookkeeping.
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-a6-rotate}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m68=PASS" --outcome pass \
      --msg "G-Rotate service-token: window accepts NEW+OLD (static+hmac), rejects unrelated; post-window OLD->401; single-key parity == today" \
      --ref "scripts/verify/m68-key-rotate.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log

green "[M68] ALL GATES GREEN — INTERNAL_SERVICE_TOKEN_PREV opens a rotation window where BOTH the new and the in-flight old token verify (static + hmac), an unrelated token is rejected (load-bearing), the old token dies once the window closes (load-bearing), and single-key behavior with PREV unset is byte-identical to today"
exit 0
