#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m42-one-mfa.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M42 — binocle-one email + MFA gate, against a real SMTP sink (Mailpit):
#   1. image budget still ≤ 12 MB with lettre + TOTP compiled in;
#   2. email verification: bearer request → code lands in Mailpit → confirm
#      → /me shows verified=true; wrong code 401;
#   3. password reset: code → new password works, old password 401, and the
#      pre-reset refresh token is revoked;
#   4. OTP login: code → session does owner-scoped CRUD; code replay 401;
#   5. TOTP MFA: enroll → confirm (code computed in-gate, RFC 6238) →
#      login returns mfa_required → totp/verify upgrades to a session →
#      recovery code works ONCE; disable requires a live factor;
#   6. idle RSS ≤ 15 MiB.

set -euo pipefail
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
step() { cyan "[M42] $*"; }
fail() {
  red "[M42] FAIL — $*"
  cleanup
  exit 1
}
ok() { green "  ✓ $*"; }

IMAGE="${ONE_IMAGE:-binocle-one}"
NET="m42-net-$$"
MAIL="m42-mailpit-$$"
ONE="m42-one-$$"
PORT="${ONE_PORT:-18942}"
MAIL_PORT="${MAILPIT_HTTP_PORT:-18943}"
KEY="m42-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"
MAPI="http://127.0.0.1:${MAIL_PORT}/api/v1"

cleanup() {
  docker rm -fv "${ONE}" "${MAIL}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

req() { # method path auth body → body<TAB>status
  local method="$1" path="$2" auth="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${auth}" ]] && args+=(-H "${auth}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of() { awk -F'\t' '{print $NF}' <<<"$1"; }
jget() { python3 -c "import sys,json;d=json.loads(sys.stdin.read().rsplit('\t',1)[0]);print($1)" <<<"$2"; }

# Latest 8-digit code Mailpit holds for a recipient (and wipe the inbox after,
# so the next read can't pick up a stale message).
mail_code() { # email → code
  local to="$1" code=""
  for i in $(seq 1 20); do
    code=$(curl -s "${MAPI}/search?query=to:${to}" |
      python3 -c '
import sys, json, re, urllib.request
data = json.load(sys.stdin)
msgs = data.get("messages") or []
if msgs:
    mid = msgs[0]["ID"]
    body = urllib.request.urlopen("'"${MAPI}"'/message/" + mid).read().decode()
    m = re.search(r"code: (\d{8})", body)
    print(m.group(1) if m else "")
' 2>/dev/null) || true
    [[ -n "${code}" ]] && break
    sleep 0.5
  done
  curl -s -X DELETE "${MAPI}/messages" >/dev/null 2>&1 || true
  echo "${code}"
}

step "0/6 boot Mailpit + binocle-one"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make one-build)"
IMG_MB=$(($(docker image inspect --format '{{.Size}}' "${IMAGE}") / 1024 / 1024))
((IMG_MB <= 12)) || fail "image ${IMG_MB} MB > 12 MB budget"
docker network create "${NET}" >/dev/null
docker run -d --name "${MAIL}" --network "${NET}" -p "${MAIL_PORT}:8025" axllent/mailpit >/dev/null
for i in $(seq 1 20); do
  curl -sf "${MAPI}/messages" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "mailpit never came up"
  sleep 0.5
done
docker run -d --name "${ONE}" --network "${NET}" -p "${PORT}:8090" \
  -e NANO_ADMIN_KEY="${KEY}" \
  -e ONE_SMTP_HOST="${MAIL}" -e ONE_SMTP_PORT=1025 -e ONE_SMTP_SECURITY=none \
  -e ONE_SMTP_FROM="binocle <one@local.test>" \
  "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "binocle-one never came up"
  sleep 0.5
done
ok "image ${IMG_MB} MB ≤ 12 MB; mailpit + server up"

step "1/6 email verification round-trip"
R=$(req POST /one/v1/auth/register "" '{"email":"grace@local.dev","password":"grace-pass-123"}')
[[ "$(status_of "$R")" == "201" ]] || fail "register grace: $R"
TOK_G=$(jget "d['token']" "$R")
REF_G=$(jget "d['refresh']" "$R")
[[ "$(jget "d['user']['verified']" "$R")" == "False" ]] || fail "fresh account must be unverified"
R=$(req POST /one/v1/auth/request-verification "Authorization: Bearer ${TOK_G}")
[[ "$(status_of "$R")" == "202" ]] || fail "request-verification: $R"
CODE=$(mail_code "grace@local.dev")
[[ -n "${CODE}" ]] || fail "no verification code arrived in mailpit"
R=$(req POST /one/v1/auth/confirm-verification "" "{\"email\":\"grace@local.dev\",\"code\":\"00000000\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "wrong code must 401: $R"
R=$(req POST /one/v1/auth/confirm-verification "" "{\"email\":\"grace@local.dev\",\"code\":\"${CODE}\"}")
[[ "$(status_of "$R")" == "204" ]] || fail "confirm-verification: $R"
R=$(req GET /one/v1/auth/me "Authorization: Bearer ${TOK_G}")
[[ "$(jget "d['user']['verified']" "$R")" == "True" ]] || fail "/me not verified: $R"
ok "code delivered via SMTP, wrong code 401, verified=true"

step "2/6 password reset revokes sessions"
R=$(req POST /one/v1/auth/request-reset "" '{"email":"grace@local.dev"}')
[[ "$(status_of "$R")" == "202" ]] || fail "request-reset: $R"
CODE=$(mail_code "grace@local.dev")
[[ -n "${CODE}" ]] || fail "no reset code arrived"
R=$(req POST /one/v1/auth/confirm-reset "" "{\"email\":\"grace@local.dev\",\"code\":\"${CODE}\",\"password\":\"grace-NEW-pass-1\"}")
[[ "$(status_of "$R")" == "204" ]] || fail "confirm-reset: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-pass-123"}')
[[ "$(status_of "$R")" == "401" ]] || fail "old password must 401 after reset: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
[[ "$(status_of "$R")" == "200" ]] || fail "new password: $R"
TOK_G=$(jget "d['token']" "$R")
R=$(req POST /one/v1/auth/refresh "" "{\"refresh\":\"${REF_G}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "pre-reset refresh token must be revoked: $R"
# An unknown email must not leak existence (202 either way).
R=$(req POST /one/v1/auth/request-reset "" '{"email":"ghost@local.dev"}')
[[ "$(status_of "$R")" == "202" ]] || fail "unknown email must still 202: $R"
ok "reset works, old password + old refresh dead, no enumeration"

step "3/6 OTP (passwordless) login"
R=$(req POST /one/v1/auth/request-otp "" '{"email":"grace@local.dev"}')
[[ "$(status_of "$R")" == "202" ]] || fail "request-otp: $R"
CODE=$(mail_code "grace@local.dev")
[[ -n "${CODE}" ]] || fail "no otp code arrived"
R=$(req POST /one/v1/auth/login-otp "" "{\"email\":\"grace@local.dev\",\"code\":\"${CODE}\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "login-otp: $R"
TOK_OTP=$(jget "d['token']" "$R")
req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, name TEXT)"}' >/dev/null
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK_OTP}" '{"db_id":"main","operation":{"op":"insert","resource":"items","data":{"id":"g1","name":"via otp"}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "CRUD via OTP session: $R"
R=$(req POST /one/v1/auth/login-otp "" "{\"email\":\"grace@local.dev\",\"code\":\"${CODE}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "otp code replay must 401: $R"
ok "otp login → working session; replay rejected"

step "4/6 TOTP enroll + challenge login"
R=$(req POST /one/v1/auth/totp/enroll "Authorization: Bearer ${TOK_G}")
[[ "$(status_of "$R")" == "200" ]] || fail "enroll: $R"
SECRET=$(jget "d['secret']" "$R")
grep -q "otpauth://totp/" <<<"$R" || fail "no otpauth url: $R"
totp() { python3 -c "
import base64, hashlib, hmac, struct, time
key = base64.b32decode('${SECRET}' + '=' * ((8 - len('${SECRET}') % 8) % 8))
c = int(time.time()) // 30
h = hmac.new(key, struct.pack('>Q', c), hashlib.sha1).digest()
o = h[-1] & 0xF
print('%06d' % ((struct.unpack('>I', h[o:o+4])[0] & 0x7FFFFFFF) % 1000000))
"; }
# Pre-confirmation, login must still be single-factor.
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
grep -q "mfa_required" <<<"$R" && fail "pending (unconfirmed) TOTP must not gate login"
R=$(req POST /one/v1/auth/totp/confirm "Authorization: Bearer ${TOK_G}" "{\"code\":\"$(totp)\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "totp confirm: $R"
RECOVERY=$(jget "d['recovery_codes'][0]" "$R")
[[ -n "${RECOVERY}" ]] || fail "no recovery codes returned: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
[[ "$(jget "d.get('mfa_required')" "$R")" == "True" ]] || fail "login must demand MFA now: $R"
MFA_TOK=$(jget "d['mfa_token']" "$R")
R=$(req POST /one/v1/auth/totp/verify "" "{\"mfa_token\":\"${MFA_TOK}\",\"code\":\"999999\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "wrong TOTP must 401: $R"
R=$(req POST /one/v1/auth/totp/verify "" "{\"mfa_token\":\"${MFA_TOK}\",\"code\":\"$(totp)\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "totp verify: $R"
TOK_MFA=$(jget "d['token']" "$R")
R=$(req GET /one/v1/auth/me "Authorization: Bearer ${TOK_MFA}")
grep -q "grace@local.dev" <<<"$R" || fail "MFA session /me: $R"
ok "TOTP gate live: challenge → code → session (wrong code 401)"

step "5/6 recovery codes are single-use; disable needs a factor"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
MFA_TOK=$(jget "d['mfa_token']" "$R")
R=$(req POST /one/v1/auth/totp/verify "" "{\"mfa_token\":\"${MFA_TOK}\",\"code\":\"${RECOVERY}\"}")
[[ "$(status_of "$R")" == "200" ]] || fail "recovery code login: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
MFA_TOK=$(jget "d['mfa_token']" "$R")
R=$(req POST /one/v1/auth/totp/verify "" "{\"mfa_token\":\"${MFA_TOK}\",\"code\":\"${RECOVERY}\"}")
[[ "$(status_of "$R")" == "401" ]] || fail "recovery code reuse must 401: $R"
R=$(req POST /one/v1/auth/totp/disable "Authorization: Bearer ${TOK_MFA}" '{"code":"000000"}')
[[ "$(status_of "$R")" == "401" ]] || fail "disable without a live factor must 401: $R"
R=$(req POST /one/v1/auth/totp/disable "Authorization: Bearer ${TOK_MFA}" "{\"code\":\"$(totp)\"}")
[[ "$(status_of "$R")" == "204" ]] || fail "totp disable: $R"
R=$(req POST /one/v1/auth/login "" '{"email":"grace@local.dev","password":"grace-NEW-pass-1"}')
grep -q "mfa_required" <<<"$R" && fail "login must be single-factor after disable"
ok "recovery single-use; disable gated by a live factor; MFA off again"

step "6/6 idle RSS ≤ 15 MiB"
sleep 2
MEM_TOKEN=$(docker stats --no-stream --format '{{.MemUsage}}' "${ONE}" | awk '{print $1}')
MEM_MIB=$(awk -v v="${MEM_TOKEN}" 'BEGIN{u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
  if(u=="GiB") printf "%.1f", n*1024; else if(u=="KiB") printf "%.3f", n/1024; else printf "%.1f", n}')
awk -v m="${MEM_MIB}" 'BEGIN{exit !(m<=15)}' || fail "idle RSS ${MEM_MIB} MiB > 15 MiB budget"
ok "idle RSS ${MEM_MIB} MiB ≤ 15 MiB"

green "[M42] ALL GATES GREEN — binocle-one: ${IMG_MB} MB image, ${MEM_MIB} MiB idle — SMTP verification/reset/OTP + RFC 6238 TOTP MFA + recovery codes, all proven live"
