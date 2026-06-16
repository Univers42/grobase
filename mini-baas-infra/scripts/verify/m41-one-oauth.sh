#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m41-one-oauth.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M41 — binocle-one OAuth2/OIDC gate. Proves the GENERIC authorization-code +
# PKCE flow end-to-end against a real (mock) OIDC issuer in a sibling
# container — discovery, /authorize redirect, code→token exchange with the
# S256 challenge actually verified by the issuer, userinfo, and our side:
#   1. /providers lists the configured provider;
#   2. start (json=1) yields an auth URL carrying state + S256 challenge;
#   3. issuer redirects back; callback returns a session (JWT + refresh);
#   4. state is single-use — replaying the callback 401s;
#   5. the OAuth user's JWT does owner-scoped CRUD on /data/v1;
#   6. a second login with the same identity maps to the SAME account;
#   7. account linking: an existing password account with the provider-verified
#      email is linked, not duplicated.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M41] $*"; }
fail(){ red "[M41] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${ONE_IMAGE:-binocle-one}"
NET="m41-net-$$"
MOCK="m41-oidc-$$"
ONE="m41-one-$$"
PORT="${ONE_PORT:-18941}"
MOCK_PORT="${MOCK_OIDC_PORT:-19461}"
KEY="m41-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"
ISSUER="http://${MOCK}:9460"

cleanup(){
  docker rm -fv "${ONE}" "${MOCK}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

req(){ # method path auth body → body<TAB>status
  local method="$1" path="$2" auth="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${auth}" ]] && args+=(-H "${auth}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of(){ awk -F'\t' '{print $NF}' <<<"$1"; }
jget(){ # python-expr response → value  (expr sees the parsed body as `d`)
  python3 -c "import sys,json;d=json.loads(sys.stdin.read().rsplit('\t',1)[0]);print($1)" <<<"$2"
}

step "0/7 boot mock issuer + binocle-one on a shared network"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make one-build)"
docker network create "${NET}" >/dev/null
docker run -d --name "${MOCK}" --network "${NET}" -p "${MOCK_PORT}:9460" \
  -e ISSUER="${ISSUER}" \
  -v "${HERE}/mock-oidc.py:/mock-oidc.py:ro" \
  python:3.12-alpine python /mock-oidc.py >/dev/null
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:${MOCK_PORT}/.well-known/openid-configuration" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "mock issuer never came up"
  sleep 0.5
done
docker run -d --name "${ONE}" --network "${NET}" -p "${PORT}:8090" \
  -e NANO_ADMIN_KEY="${KEY}" \
  -e ONE_OAUTH_OIDC_ISSUER="${ISSUER}" \
  -e ONE_OAUTH_OIDC_CLIENT_ID="mock-client" \
  -e ONE_OAUTH_OIDC_CLIENT_SECRET="mock-secret" \
  -e ONE_PUBLIC_URL="http://127.0.0.1:${PORT}" \
  "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "binocle-one never came up"
  sleep 0.5
done
ok "issuer + server up (issuer reachable as ${ISSUER} in-network)"

step "1/7 providers list shows oidc"
R=$(req GET /one/v1/auth/oauth/providers "")
grep -q '"oidc"' <<<"$R" || fail "providers: $R"
ok "oidc enabled"

step "2/7 start: auth URL carries state + S256 PKCE challenge"
R=$(req GET "/one/v1/auth/oauth/oidc/start?json=1" "")
[[ "$(status_of "$R")" == "200" ]] || fail "start: $R"
AUTH_URL=$(jget "d['auth_url']" "$R")
grep -q "code_challenge=" <<<"$AUTH_URL" || fail "no PKCE challenge: $AUTH_URL"
grep -q "code_challenge_method=S256" <<<"$AUTH_URL" || fail "not S256: $AUTH_URL"
grep -q "state=" <<<"$AUTH_URL" || fail "no state: $AUTH_URL"
ok "PKCE S256 + state present"

# The issuer URL uses the container-network hostname; the gate drives the
# browser leg from the host, so rewrite it to the published port.
authorize(){ # auth-url → callback-url (the issuer's 302 Location)
  local host_url="${1//${MOCK}:9460/127.0.0.1:${MOCK_PORT}}"
  curl -s -o /dev/null -w '%{redirect_url}' "${host_url}"
}

step "3/7 authorize → callback → session"
CB_URL=$(authorize "${AUTH_URL}")
grep -q "code=" <<<"$CB_URL" || fail "issuer redirect has no code: $CB_URL"
CB_PATH="/${CB_URL#*://*/}"
R=$(req GET "${CB_PATH}" "")
[[ "$(status_of "$R")" == "200" ]] || fail "callback: $R"
TOK=$(jget "d['token']" "$R")
UID_CAROL=$(jget "d['user']['id']" "$R")
EMAIL=$(jget "d['user']['email']" "$R")
[[ "${EMAIL}" == "carol@idp.dev" ]] || fail "wrong email: ${EMAIL}"
[[ -n "${TOK}" && -n "${UID_CAROL}" ]] || fail "no token/user: $R"
ok "carol@idp.dev signed in via OIDC (user ${UID_CAROL})"

step "4/7 state is single-use (replay 401s)"
R=$(req GET "${CB_PATH}" "")
[[ "$(status_of "$R")" == "401" ]] || fail "replayed callback must 401: $R"
ok "replay rejected"

step "5/7 OAuth JWT does owner-scoped CRUD on /data/v1"
req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, body TEXT)"}' >/dev/null
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK}" '{"db_id":"main","operation":{"op":"insert","resource":"notes","data":{"id":"c1","body":"carol oauth note"}}}')
[[ "$(status_of "$R")" == "200" ]] || fail "insert as carol: $R"
R=$(req POST /data/v1/query "Authorization: Bearer ${TOK}" '{"db_id":"main","operation":{"op":"list","resource":"notes"}}')
grep -q "carol oauth note" <<<"$R" || fail "carol can't read her note: $R"
R=$(req POST /nano/v1/raw "X-Baas-Api-Key: ${KEY}" '{"db_id":"main","statement":"SELECT owner_id FROM notes","expect_rows":true}')
grep -q "\"owner_id\":\"user:${UID_CAROL}\"" <<<"$R" || fail "row not stamped user:${UID_CAROL}: $R"
ok "owner-scoped CRUD, rows stamped user:${UID_CAROL}"

step "6/7 same identity → same account (no duplicates)"
R=$(req GET "/one/v1/auth/oauth/oidc/start?json=1" "")
CB_URL=$(authorize "$(jget "d['auth_url']" "$R")")
R=$(req GET "/${CB_URL#*://*/}" "")
UID2=$(jget "d['user']['id']" "$R")
[[ "${UID2}" == "${UID_CAROL}" ]] || fail "second login created a new account: ${UID2} != ${UID_CAROL}"
ok "identity stable across logins"

step "7/7 verified-email linking to an existing password account"
R=$(req POST /one/v1/auth/register "" '{"email":"dave@local.dev","password":"dave-pass-1234"}')
[[ "$(status_of "$R")" == "201" ]] || fail "register dave: $R"
UID_DAVE=$(jget "d['user']['id']" "$R")
R=$(req GET "/one/v1/auth/oauth/oidc/start?json=1" "")
AUTH_URL="$(jget "d['auth_url']" "$R")&login_hint=dave%40local.dev"
CB_URL=$(authorize "${AUTH_URL}")
R=$(req GET "/${CB_URL#*://*/}" "")
[[ "$(status_of "$R")" == "200" ]] || fail "dave oauth callback: $R"
UID_LINKED=$(jget "d['user']['id']" "$R")
[[ "${UID_LINKED}" == "${UID_DAVE}" ]] || fail "linking failed — new account ${UID_LINKED} instead of ${UID_DAVE}"
R=$(req POST /one/v1/auth/login "" '{"email":"dave@local.dev","password":"dave-pass-1234"}')
[[ "$(status_of "$R")" == "200" ]] || fail "dave's password must still work after linking: $R"
ok "oidc identity linked to dave's password account; password login intact"

green "[M41] ALL GATES GREEN — generic OAuth2/OIDC+PKCE flow proven end-to-end (discovery, S256-verified exchange, single-use state, owner-scoped JWT, identity stability, email linking)"
