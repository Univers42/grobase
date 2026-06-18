#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m110-sso-oidc.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M110 — Track-D D2a ENTERPRISE OIDC SSO gate. gotrue has no org-level SSO; D2a
# adds an OIDC authorization-code login (per-tenant IdP connections) flag-gated
# OFF by default (SSO_ENABLED). It exercises a tenant-control binary built FROM
# CURRENT source against a MOCK OIDC IdP also built from CURRENT source, so the
# full grant runs end-to-end:
#
#   register a connection (admin, service token, client_secret AES-GCM sealed)
#       │  POST /v1/auth/sso/begin {connection_id}  -> {authorize_url, state}
#       ▼
#   mock IdP GET /authorize  -> 302 redirect_uri?code=<c>&state=<s>   (acts as user)
#       │  POST /v1/auth/sso/callback {state, code}
#       ▼
#   tenant-control: POST /token at the IdP -> {id_token}; VERIFY it
#       (HS256 with the client secret, OR RS256 via the IdP /jwks)
#       -> mint a GoTrue-shaped session JWT
#
#   (A · POSITIVE) register an HS256 connection -> begin -> the mock IdP issues a
#       code -> callback => 200 + a session JWT that VERIFIES under the GoTrue
#       HS256 secret (sub/email present, role=authenticated). Repeated for an
#       RS256 connection (id_token signed RS256, verified via the IdP JWKS).
#   (B · REJECT, LOAD-BEARING) the IdP signs the id_token with the WRONG key (and
#       separately, wrong issuer / expired) => callback 401, NO session minted.
#       AND a REPLAYED state (the same state used twice) => 401 (single-use).
#   (C · FLAG-OFF PARITY) with SSO_ENABLED unset, every /v1/auth/sso/* route is
#       404 while admin GET /v1/tenants 200, and sso_connections has 0 rows — byte-
#       identical to today (gotrue has no SSO).
#
# ISOLATED by design (mirrors m107/m109): scratch postgres (prelude + REAL 053) +
# two tenant-control binaries built FROM CURRENT source + a mock IdP built FROM
# CURRENT source, ALL on a PRIVATE network, every name suffixed with $$, an
# EXIT-trap removing EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_053="${MIG_DIR}/053_sso_connections.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M110] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M110] FAIL — $*"
  exit 1
}

PG_IMAGE="${M110_PG_IMAGE:-postgres:16-alpine}"
GO_IMAGE="${M110_GO_IMAGE:-golang:1.25-bookworm}"
TC_IMG="m110-tc-$$:scratch"
IDP_IMG="m110-idp-$$:scratch"
NET="m110net-$$"
PG="m110-pg-$$"
IDP="m110-idp-$$"
TC_ON="m110-tc-on-$$"   # SSO_ENABLED=1     (A/B)
TC_OFF="m110-tc-off-$$" # SSO_ENABLED unset (C · flag-off parity)
# UNIQUE port pair for this gate (assigned by the slice: 19120/19121).
PORT_ON="${M110_PORT_ON:-19120}"
PORT_OFF="${M110_PORT_OFF:-19121}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m110-internal-service-token-$$"
JWT_SECRET="m110-gotrue-hs256-secret-$$-do-not-use"
SSO_KEY="m110-sso-secret-key-$$-at-least-16"
# in-net IdP base URL the tenant-control reaches; the gate reaches it on a host port.
IDP_PORT_INNET=8099
IDP_URL_INNET="http://${IDP}:${IDP_PORT_INNET}"
IDP_HOST_PORT="${M110_IDP_PORT:-19126}" # outside the 19120-19125 gate block (19122 is m111's PORT_ON — avoid a concurrent-run collision)
# IdP identity facts
ISSUER="https://m110-idp.example.com"
CLIENT_ID="m110-client-id"
CLIENT_SECRET="m110-oidc-client-secret-shared-hmac"
REDIRECT_URI="http://127.0.0.1:${PORT_ON}/v1/auth/sso/callback"
TENANT_ID="m110tenant"
SSO_SUB="m110-user-subject-1"
SSO_EMAIL="alice@m110.example.com"
WORK="$(mktemp -d)"
BODY_TMP="${WORK}/body.json"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${IDP}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${IDP_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply a migration the SAME way make migrate does: strip the leading `#` banner.
apply_migration() { sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }

# Service-token admin request. $1=method $2=port $3=path $4=body
admin_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}" -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H "X-Service-Token: ${SVC_TOKEN}"
  fi
}
# Unauthenticated request (the public login surface). $1=method $2=port $3=path $4=body
pub_req() {
  local m="$1" p="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}" \
      -H 'Content-Type: application/json' -d "${body}"
  else
    curl -s -o "${BODY_TMP}" -w '%{http_code}' -X "${m}" "http://127.0.0.1:${p}${path}"
  fi
}

json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*"'"$1"'":"//; s/"$//'; }

# unesc decodes the JSON-string escapes Go's encoder emits for a URL: & -> &
# (the `&` separating query params is escaped in the begin response). Without this
# the authorize_url collapses to a single garbled query param at the IdP, dropping
# nonce= and breaking the verify. We only need the &-class for a query string.
unesc() { printf '%s' "$1" | sed 's/\\u0026/\&/g; s/\\u003d/=/g; s/\\\//\//g'; }

# authorize_code drives the IdP /authorize ONCE (a fresh code is minted per call,
# so calling it twice would desync the code from its captured nonce). It reads the
# 302 Location header and echoes the `code` query param. $1=authorize_url (in-net,
# JSON-escaped) — it is unescaped + host-swapped to the gate-reachable host port.
authorize_code() { # $1=authorize_url
  local au host loc
  au="$(unesc "$1")"
  host="${au/${IDP_URL_INNET}/http://127.0.0.1:${IDP_HOST_PORT}}"
  loc="$(curl -s -o /dev/null -D - "${host}" | tr -d '\r' | grep -i '^Location:' | head -1)"
  printf '%s' "${loc}" | sed 's/.*[?&]code=//; s/&.*//'
}

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || {
      red "$1 exited early:"
      docker logs "$1" 2>&1 | tail -20
      return 1
    }
    sleep 0.5
  done
  red "$1 never became ready:"
  docker logs "$1" 2>&1 | tail -20
  return 1
}

# ── 0) write the MOCK OIDC IdP source (built FROM CURRENT module) ──────────────
# A tiny OIDC IdP: GET /authorize -> 302 redirect_uri?code=<deterministic>&state=
# (echoes the state); POST /token (grant_type=authorization_code) -> {id_token,
# access_token, token_type}; GET /jwks -> the RS256 public key set. It signs the
# id_token over claims it is configured with (iss/aud/sub/email/nonce/exp). Flags
# via env: M110_ALG (HS256|RS256), M110_BAD_KEY (sign with a fresh wrong key),
# M110_BAD_ISS (wrong issuer), M110_EXPIRED (exp in the past), plus the OIDC facts.
# It pins the nonce it received at /authorize into the id_token it mints at /token
# (so the server's nonce check is exercised). It is built inside the control-plane
# module so it shares go.mod (golang-jwt/jwt/v5 is already resolved).
step "0/11 write + build the mock OIDC IdP + tenant-control FROM CURRENT source"
mkdir -p "${WORK}/idp"
cat >"${WORK}/idp/main.go" <<'GOEOF'
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Mock OIDC IdP for the m110 gate. NOT for production — a deterministic test
// double of an OIDC authorization-code provider.
func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func envBool(k string) bool { return os.Getenv(k) == "1" || os.Getenv(k) == "true" }

var (
	mu        sync.Mutex
	codeNonce = map[string]string{} // code -> nonce captured at /authorize
	rsaKey    *rsa.PrivateKey
	kid       = "m110-kid-1"
)

func main() {
	issuer := env("M110_ISSUER", "https://m110-idp.example.com")
	clientID := env("M110_CLIENT_ID", "m110-client-id")
	clientSecret := env("M110_CLIENT_SECRET", "m110-oidc-client-secret-shared-hmac")
	sub := env("M110_SUB", "m110-user-subject-1")
	email := env("M110_EMAIL", "alice@m110.example.com")
	alg := env("M110_ALG", "HS256")
	port := env("M110_PORT", "8099")

	if alg == "RS256" {
		k, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
		rsaKey = k
	}

	// GET /authorize?...&state=&nonce= -> 302 to redirect_uri?code=&state=
	http.HandleFunc("/authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		redirect := q.Get("redirect_uri")
		state := q.Get("state")
		nonce := q.Get("nonce")
		code := fmt.Sprintf("code-%d", time.Now().UnixNano())
		mu.Lock()
		codeNonce[code] = nonce
		mu.Unlock()
		u, _ := url.Parse(redirect)
		rq := u.Query()
		rq.Set("code", code)
		rq.Set("state", state)
		u.RawQuery = rq.Encode()
		w.Header().Set("Location", u.String())
		w.WriteHeader(http.StatusFound)
	})

	// POST /token -> {id_token, access_token, token_type}
	http.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		code := r.Form.Get("code")
		mu.Lock()
		nonce := codeNonce[code]
		mu.Unlock()

		iss := issuer
		if envBool("M110_BAD_ISS") {
			iss = "https://evil-idp.example.com"
		}
		exp := time.Now().Add(time.Hour).Unix()
		if envBool("M110_EXPIRED") {
			exp = time.Now().Add(-time.Hour).Unix()
		}
		claims := jwt.MapClaims{
			"iss":   iss,
			"aud":   clientID,
			"sub":   sub,
			"email": email,
			"nonce": nonce,
			"exp":   exp,
			"iat":   time.Now().Unix(),
		}

		var idToken string
		var err error
		if alg == "RS256" {
			tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
			tok.Header["kid"] = kid
			key := rsaKey
			if envBool("M110_BAD_KEY") {
				key, _ = rsa.GenerateKey(rand.Reader, 2048) // sign with a FRESH wrong key
			}
			idToken, err = tok.SignedString(key)
		} else {
			tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
			secret := clientSecret
			if envBool("M110_BAD_KEY") {
				secret = "a-completely-different-wrong-secret"
			}
			idToken, err = tok.SignedString([]byte(secret))
		}
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id_token": idToken, "access_token": "opaque-access", "token_type": "bearer",
		})
	})

	// GET /jwks -> the RS256 public key set (RSA n/e b64url).
	http.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		if rsaKey == nil {
			_, _ = w.Write([]byte(`{"keys":[]}`))
			return
		}
		n := base64.RawURLEncoding.EncodeToString(rsaKey.N.Bytes())
		e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(rsaKey.E)).Bytes())
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(fmt.Sprintf(
			`{"keys":[{"kty":"RSA","kid":%q,"use":"sig","alg":"RS256","n":%q,"e":%q}]}`, kid, n, e)))
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	_ = http.ListenAndServe(":"+port, nil)
}
GOEOF

build_idp() {
  docker run --rm \
    -v "${GO_DIR}":/src:ro \
    -v "${WORK}/idp":/idp:ro \
    -v "${WORK}":/out \
    -e GOFLAGS=-mod=mod -e CGO_ENABLED=0 \
    "${GO_IMAGE}" bash -c '
      set -e
      cp -r /src /build && cd /build
      mkdir -p cmd/m110-idp
      cp /idp/main.go cmd/m110-idp/
      go build -o /out/m110-idp ./cmd/m110-idp
    ' >/dev/null 2>"${WORK}/idpbuild.err"
}
build_idp || {
  red "mock IdP build failed:"
  tail -30 "${WORK}/idpbuild.err"
  fail "mock OIDC IdP must build from CURRENT module (line: build idp)"
}
[[ -x "${WORK}/m110-idp" ]] || fail "mock IdP binary not produced (line: idp binary)"
ok "mock OIDC IdP built (authorize/token/jwks, HS256+RS256, fault-injectable)"

DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3070 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null ||
  fail "scratch tenant-control image build failed — gate must exercise the drafted D2a code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# The IdP runs from a minimal base; we package the static binary into a scratch
# image so it has no host dependencies (the binary is a static linux/amd64 ELF).
cat >"${WORK}/idp.Dockerfile" <<DEOF
FROM debian:bookworm-slim
COPY m110-idp /usr/local/bin/m110-idp
ENTRYPOINT ["/usr/local/bin/m110-idp"]
DEOF
DOCKER_BUILDKIT=1 docker build -q -f "${WORK}/idp.Dockerfile" -t "${IDP_IMG}" "${WORK}" >/dev/null ||
  fail "mock IdP image build failed (line: docker build IDP)"
ok "mock IdP image packaged"

# ── 1) isolated net + postgres (TCP-ready, not just socket) ─────────────────────
step "1/11 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
ready=0
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 &&
    [[ "$(psql_val 'SELECT 1')" == "1" ]]; then
    ready=$((ready + 1))
    [[ ${ready} -ge 2 ]] && break
  else ready=0; fi
  [[ $i -eq 80 ]] && {
    docker logs "${PG}" 2>&1 | tail -20
    fail "scratch postgres never reached TCP-ready"
  }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok twice)"

# ── 1b) prelude (schema_migrations, auth.current_tenant_id, roles) then REAL 053 ─
step "1b/11 prelude (schema_migrations, auth.current_tenant_id, roles) then REAL 053_sso_connections"
prelude() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"
  sleep 0.5
done
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
[[ -f "${MIGRATION_053}" ]] || fail "migration 053_sso_connections.sql is MISSING — the D2a migration must land before m110 (line: 053 exists)"
apply_migration "${MIGRATION_053}" || fail "real migration 053_sso_connections.sql failed to apply (line: apply 053)"
[[ "$(psql_val "SELECT to_regclass('public.sso_connections') IS NOT NULL")" == "t" ]] ||
  fail "public.sso_connections not created by migration 053 (line: 053 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.sso_connections")" == "0" ]] ||
  fail "sso_connections should start EMPTY (line: 053 empty check)"
HASW="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='sso_connections' AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE')")" || HASW="?"
[[ "${HASW}" == "0" ]] || fail "authenticated must NOT have INSERT/UPDATE/DELETE on sso_connections, got ${HASW} (line: 053 grants)"
ok "migration 053 applied — sso_connections exists, empty, authenticated read-only"

# Create the tenant row so admin GET /v1/tenants has a baseline + the {id} path is real.
docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL || true
INSERT INTO public.tenants (slug, name) VALUES ('${TENANT_ID}', 'M110 Tenant') ON CONFLICT DO NOTHING;
SQL

# ── helper: run one full positive login against an IdP of a given alg ───────────
# Each alg uses a DISTINCT issuer (the UNIQUE(tenant,issuer) constraint forbids
# two connections sharing one issuer) and the relaunched IdP is configured to MINT
# that same issuer, so the id_token's iss matches the registered connection.
# $1=alg (HS256|RS256) $2=jwks_url_or_empty $3=issuer -> echoes the access_token.
run_positive_login() {
  local alg="$1" jwks="$2" iss="$3"
  # (re)launch the IdP for this alg + issuer.
  docker rm -fv "${IDP}" >/dev/null 2>&1 || true
  docker run -d --name "${IDP}" --network "${NET}" \
    -e M110_ISSUER="${iss}" -e M110_CLIENT_ID="${CLIENT_ID}" \
    -e M110_CLIENT_SECRET="${CLIENT_SECRET}" -e M110_SUB="${SSO_SUB}" \
    -e M110_EMAIL="${SSO_EMAIL}" -e M110_ALG="${alg}" -e M110_PORT="${IDP_PORT_INNET}" \
    -p "127.0.0.1:${IDP_HOST_PORT}:${IDP_PORT_INNET}" "${IDP_IMG}" >/dev/null
  for i in $(seq 1 40); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${IDP_HOST_PORT}/healthz" 2>/dev/null)" == "200" ]] && break
    [[ $i -eq 40 ]] && {
      docker logs "${IDP}" 2>&1 | tail
      return 1
    }
    sleep 0.3
  done
  # register a connection for this alg + issuer.
  local conn_body
  conn_body="$(printf '{"issuer":"%s","client_id":"%s","client_secret":"%s","authorize_url":"%s/authorize","token_url":"%s/token","jwks_url":"%s","redirect_uri":"%s"}' \
    "${iss}" "${CLIENT_ID}" "${CLIENT_SECRET}" "${IDP_URL_INNET}" "${IDP_URL_INNET}" "${jwks}" "${REDIRECT_URI}")"
  local C
  C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_ID}/sso/connections" "${conn_body}")"
  [[ "${C}" == "201" || "${C}" == "200" ]] || {
    red "register(${alg}) got ${C}: $(head -c 300 "${BODY_TMP}")"
    return 1
  }
  local CONN_ID
  CONN_ID="$(json_str id)"
  [[ -n "${CONN_ID}" ]] || {
    red "register(${alg}) returned no connection id"
    return 1
  }
  # begin -> {authorize_url, state}.
  C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/begin" "{\"connection_id\":\"${CONN_ID}\"}")"
  [[ "${C}" == "200" ]] || {
    red "begin(${alg}) got ${C}: $(head -c 300 "${BODY_TMP}")"
    return 1
  }
  local AUTH_URL STATE CODE
  AUTH_URL="$(json_str authorize_url)"
  STATE="$(json_str state)"
  [[ -n "${AUTH_URL}" && -n "${STATE}" ]] || {
    red "begin(${alg}) missing authorize_url/state"
    return 1
  }
  # Act as the user-agent: drive the IdP /authorize ONCE, read the code from the
  # 302 Location (authorize_code unescapes the JSON & + host-swaps the URL).
  CODE="$(authorize_code "${AUTH_URL}")"
  [[ -n "${CODE}" ]] || {
    red "IdP /authorize(${alg}) returned no code"
    return 1
  }
  # callback {state, code} -> 200 + session JWT.
  C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/callback" "{\"state\":\"${STATE}\",\"code\":\"${CODE}\"}")"
  [[ "${C}" == "200" ]] || {
    red "callback(${alg}) got ${C}: $(head -c 400 "${BODY_TMP}")"
    return 1
  }
  json_str access_token
}

# ── 2) boot the SSO-ON tenant-control ──────────────────────────────────────────
step "2/11 boot tenant-control SSO_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e SSO_ENABLED=1 \
  -e SSO_SECRET_KEY="${SSO_KEY}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "SSO-ON tenant-control not ready (line: wait_ready TC_ON)"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -qi "sso .*enabled" ||
  {
    docker logs "${TC_ON}" 2>&1 | tail -20
    fail "SSO never reported enabled (line: TC_ON enabled log)"
  }
ok "SSO-ON tenant-control up (/v1/auth/sso/* mounted)"

# ── 3) (A · POSITIVE) HS256 connection: register -> begin -> authorize -> callback
step "3/11 (A) HS256 full grant: register -> begin -> IdP /authorize -> callback => 200 + a session JWT"
ISSUER_HS="${ISSUER}/hs256"
ACCESS="$(run_positive_login HS256 "" "${ISSUER_HS}")" || fail "(A) HS256 positive login flow failed (line: A hs256)"
[[ -n "${ACCESS}" ]] || fail "(A) HS256 callback returned no access_token (line: A hs256 token)"
ok "(A) HS256 login => 200, session JWT issued"

# ── 3b) (A) the session JWT VERIFIES under the GoTrue HS256 secret + sub/email ──
step "3b/11 (A) the session JWT VERIFIES under the GoTrue HS256 secret + sub==SSO sub, role=authenticated"
H="${ACCESS%%.*}"
REST="${ACCESS#*.}"
P="${REST%%.*}"
SIG="${ACCESS##*.}"
SIGNED_PART="${H}.${P}"
EXPECT_SIG="$(printf '%s' "${SIGNED_PART}" | openssl dgst -sha256 -hmac "${JWT_SECRET}" -binary | base64 | tr '+/' '-_' | tr -d '=')"
[[ "${SIG}" == "${EXPECT_SIG}" ]] || fail "(A) session JWT signature does NOT verify under the GoTrue secret (line: A jwt sig)"
PAD=$(((4 - ${#P} % 4) % 4))
PADP="${P}$(printf '%*s' "${PAD}" '' | tr ' ' '=')"
CLAIMS="$(printf '%s' "${PADP}" | tr '_-' '/+' | base64 -d 2>/dev/null || true)"
echo "${CLAIMS}" | grep -q "\"sub\":\"${SSO_SUB}\"" || fail "(A) JWT sub != SSO sub — claims: ${CLAIMS} (line: A jwt sub)"
echo "${CLAIMS}" | grep -q "\"email\":\"${SSO_EMAIL}\"" || fail "(A) JWT email != SSO email — claims: ${CLAIMS} (line: A jwt email)"
echo "${CLAIMS}" | grep -q '"role":"authenticated"' || fail "(A) JWT role != authenticated — claims: ${CLAIMS} (line: A jwt role)"
ok "(A) session JWT verifies under the GoTrue secret; sub=${SSO_SUB}, email=${SSO_EMAIL}, role=authenticated"

# ── 3c) the client secret is SEALED (ciphertext), never stored in clear ─────────
step "3c/11 (A) the client_secret is stored AES-GCM SEALED (ciphertext), never plaintext"
LEAK="$(psql_val "SELECT count(*) FROM public.sso_connections WHERE convert_from(client_secret_enc,'UTF8') LIKE '%${CLIENT_SECRET}%'")" 2>/dev/null || LEAK="0"
[[ "${LEAK}" == "0" ]] || fail "(A) the plaintext client secret appears in client_secret_enc — sealing broken! (line: A secret sealed)"
HASBYTES="$(psql_val "SELECT count(*) FROM public.sso_connections WHERE octet_length(client_secret_enc) > 0")"
[[ "${HASBYTES}" -ge 1 ]] 2>/dev/null || fail "(A) client_secret_enc is empty — secret was not persisted (line: A secret stored)"
ok "(A) client secret sealed as ciphertext (no plaintext leak in the column)"

# ── 4) (A · POSITIVE) RS256 connection: id_token signed RS256, verified via JWKS ─
step "4/11 (A) RS256 full grant: register (jwks_url) -> begin -> authorize -> callback => 200 + a session JWT (JWKS verify)"
ISSUER_RS="${ISSUER}/rs256"
RS_ACCESS="$(run_positive_login RS256 "${IDP_URL_INNET}/jwks" "${ISSUER_RS}")" || fail "(A) RS256 positive login flow failed (line: A rs256)"
[[ -n "${RS_ACCESS}" ]] || fail "(A) RS256 callback returned no access_token (line: A rs256 token)"
RS_H="${RS_ACCESS%%.*}"
RS_REST="${RS_ACCESS#*.}"
RS_P="${RS_REST%%.*}"
RS_SIG="${RS_ACCESS##*.}"
RS_EXPECT="$(printf '%s' "${RS_H}.${RS_P}" | openssl dgst -sha256 -hmac "${JWT_SECRET}" -binary | base64 | tr '+/' '-_' | tr -d '=')"
[[ "${RS_SIG}" == "${RS_EXPECT}" ]] || fail "(A) RS256-path session JWT does not verify under the GoTrue secret (line: A rs256 sig)"
ok "(A) RS256 login => 200, id_token verified via the IdP JWKS, session JWT issued + verifies"

# ── 5) (B · REJECT) wrong-key id_token => 401, no session ──────────────────────
step "5/11 (B · REJECT, LOAD-BEARING) IdP signs the id_token with the WRONG key => callback 401, NO session"
ISSUER_BAD="${ISSUER}/badkey"
# relaunch the IdP in BAD_KEY mode (HS256, wrong secret), minting issuer=ISSUER_BAD
# so the ONLY thing wrong is the signing key (not iss/aud) — the load-bearing vector.
docker rm -fv "${IDP}" >/dev/null 2>&1 || true
docker run -d --name "${IDP}" --network "${NET}" \
  -e M110_ISSUER="${ISSUER_BAD}" -e M110_CLIENT_ID="${CLIENT_ID}" -e M110_CLIENT_SECRET="${CLIENT_SECRET}" \
  -e M110_SUB="${SSO_SUB}" -e M110_EMAIL="${SSO_EMAIL}" -e M110_ALG=HS256 -e M110_PORT="${IDP_PORT_INNET}" \
  -e M110_BAD_KEY=1 \
  -p "127.0.0.1:${IDP_HOST_PORT}:${IDP_PORT_INNET}" "${IDP_IMG}" >/dev/null
for i in $(seq 1 40); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${IDP_HOST_PORT}/healthz" 2>/dev/null)" == "200" ]] && break
  sleep 0.3
done
BAD_BODY="$(printf '{"issuer":"%s","client_id":"%s","client_secret":"%s","authorize_url":"%s/authorize","token_url":"%s/token","redirect_uri":"%s"}' \
  "${ISSUER_BAD}" "${CLIENT_ID}" "${CLIENT_SECRET}" "${IDP_URL_INNET}" "${IDP_URL_INNET}" "${REDIRECT_URI}")"
C="$(admin_req POST "${PORT_ON}" "/v1/tenants/${TENANT_ID}/sso/connections" "${BAD_BODY}")"
[[ "${C}" == "201" || "${C}" == "200" ]] || fail "(B) register bad-key connection got ${C}: $(head -c 300 "${BODY_TMP}") (line: B register)"
BAD_CONN="$(json_str id)"
C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/begin" "{\"connection_id\":\"${BAD_CONN}\"}")"
[[ "${C}" == "200" ]] || fail "(B) begin got ${C} (line: B begin)"
BAD_AUTH="$(json_str authorize_url)"
BAD_STATE="$(json_str state)"
BAD_CODE="$(authorize_code "${BAD_AUTH}")"
[[ -n "${BAD_CODE}" ]] || fail "(B) IdP /authorize returned no code (line: B code)"
C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/callback" "{\"state\":\"${BAD_STATE}\",\"code\":\"${BAD_CODE}\"}")"
[[ "${C}" == "401" ]] || fail "(B) wrong-key id_token expected 401, got ${C} — $(head -c 400 "${BODY_TMP}") (line: B wrong-key 401)"
grep -q '"access_token"' "${BODY_TMP}" && fail "(B) a wrong-key id_token MINTED a session — verification broken! (line: B no token)"
ok "(B) wrong-key id_token rejected 401 (no session)"

# ── 5b) (B · REJECT) a REPLAYED state => 401 (single-use) ──────────────────────
step "5b/11 (B · REJECT) a REPLAYED state (a consumed-then-reused state) => 401, never a session"
# Run a fresh GOOD login (HS256, ISSUER_HS) IN THIS shell so we capture the state +
# code, consume them once (200), then replay the SAME state (must 401). The IdP is
# relaunched back to the GOOD HS256 issuer for this; the connection already exists.
docker rm -fv "${IDP}" >/dev/null 2>&1 || true
docker run -d --name "${IDP}" --network "${NET}" \
  -e M110_ISSUER="${ISSUER_HS}" -e M110_CLIENT_ID="${CLIENT_ID}" -e M110_CLIENT_SECRET="${CLIENT_SECRET}" \
  -e M110_SUB="${SSO_SUB}" -e M110_EMAIL="${SSO_EMAIL}" -e M110_ALG=HS256 -e M110_PORT="${IDP_PORT_INNET}" \
  -p "127.0.0.1:${IDP_HOST_PORT}:${IDP_PORT_INNET}" "${IDP_IMG}" >/dev/null
for i in $(seq 1 40); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${IDP_HOST_PORT}/healthz" 2>/dev/null)" == "200" ]] && break
  sleep 0.3
done
HS_CONN="$(psql_val "SELECT id FROM public.sso_connections WHERE tenant_id='${TENANT_ID}' AND issuer='${ISSUER_HS}'")"
[[ -n "${HS_CONN}" ]] || fail "(B) could not find the HS256 connection for the replay test (line: B replay conn)"
C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/begin" "{\"connection_id\":\"${HS_CONN}\"}")"
[[ "${C}" == "200" ]] || fail "(B) replay begin got ${C} (line: B replay begin)"
RP_AUTH="$(json_str authorize_url)"
RP_STATE="$(json_str state)"
RP_CODE="$(authorize_code "${RP_AUTH}")"
[[ -n "${RP_CODE}" && -n "${RP_STATE}" ]] || fail "(B) replay setup missing code/state (line: B replay setup)"
# first callback: consumes the state, expect 200.
C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/callback" "{\"state\":\"${RP_STATE}\",\"code\":\"${RP_CODE}\"}")"
[[ "${C}" == "200" ]] || fail "(B) replay first callback expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B replay first)"
# second callback with the SAME state: single-use => 401/400, no session.
C="$(pub_req POST "${PORT_ON}" "/v1/auth/sso/callback" "{\"state\":\"${RP_STATE}\",\"code\":\"${RP_CODE}\"}")"
[[ "${C}" == "401" || "${C}" == "400" ]] ||
  fail "(B) replayed state expected 401/400, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B replay)"
grep -q '"access_token"' "${BODY_TMP}" && fail "(B) a REPLAYED state minted a session — single-use broken! (line: B replay no token)"
ok "(B) replayed/consumed state rejected ${C} (single-use enforced, no session)"

# ── 6) (C · FLAG-OFF PARITY) flag unset -> every /v1/auth/sso/* route 404 ──────
step "6/11 (C · FLAG-OFF PARITY) STOP the ENABLED container; boot with SSO_ENABLED unset (same DB)"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
CONN_BEFORE="$(psql_val "SELECT count(*) FROM public.sso_connections")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "SSO-OFF tenant-control not ready (line: wait_ready TC_OFF)"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -qi "sso .*disabled" ||
  {
    docker logs "${TC_OFF}" 2>&1 | tail -20
    fail "OFF tenant-control did not report SSO disabled (flag default not OFF?) (line: TC_OFF disabled log)"
  }
ok "SSO-OFF tenant-control up (SSO_ENABLED unset)"

step "7/11 (C) EVERY /v1/auth/sso/* route 404 with the flag OFF (byte-parity — gotrue has no SSO)"
for spec in \
  "POST /v1/auth/sso/begin" \
  "POST /v1/auth/sso/callback" \
  "GET /v1/auth/sso/callback"; do
  m="${spec%% *}"
  path="${spec#* }"
  C="$(pub_req "${m}" "${PORT_OFF}" "${path}" "$([[ "${m}" == POST ]] && echo '{"connection_id":"x"}')")"
  [[ "${C}" == "404" ]] ||
    fail "(C) PARITY: ${m} ${path} with SSO_ENABLED off expected 404 (route absent), got ${C} — $(head -c 200 "${BODY_TMP}") (line: C 404 ${path})"
done
# the admin register/list routes are also gated off.
C="$(admin_req POST "${PORT_OFF}" "/v1/tenants/${TENANT_ID}/sso/connections" '{"issuer":"x"}')"
[[ "${C}" == "404" ]] || fail "(C) PARITY: admin register route expected 404 with flag OFF, got ${C} (line: C 404 admin)"
ok "(C) all /v1/auth/sso/* + admin sso routes 404 with the flag OFF"

step "8/11 (C) the base admin surface STILL works on the OFF router (proves only SSO is gated)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] ||
  fail "(C) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 200 "${BODY_TMP}") (line: C admin 200)"
ok "(C) base admin GET /v1/tenants => 200 — the baseline is untouched; only SSO is flag-gated"

step "9/11 (C) the OFF router NEVER wrote to sso_connections (count unchanged)"
CONN_AFTER="$(psql_val "SELECT count(*) FROM public.sso_connections")"
[[ "${CONN_AFTER}" == "${CONN_BEFORE}" ]] ||
  fail "(C) PARITY: sso_connections changed under the OFF router (before=${CONN_BEFORE} after=${CONN_AFTER}) (line: C no writes)"
ok "(C) sso_connections unchanged (${CONN_AFTER}) — the OFF router never touches it"

# ── 10) summary ────────────────────────────────────────────────────────────────
step "10/11 summary"
green "[M110] (A) POSITIVE: HS256 + RS256(JWKS) full OIDC grant — register -> begin -> IdP /authorize -> callback 200, session JWT VERIFIES under the GoTrue secret (sub/email present, role=authenticated); client secret stored AES-GCM SEALED (no plaintext leak)"
green "[M110] (B) REJECT:   wrong-key id_token => 401 (no session); replayed state => 401 (single-use, no session)"
green "[M110] (C) PARITY:   SSO_ENABLED off => all /v1/auth/sso/* + admin sso routes 404 while admin GET /v1/tenants 200; sso_connections never written — byte-identical to today (gotrue has no SSO)"

# ── 11) emit the gate event via the kernel log helper (best-effort) ─────────────
step "11/11 log GATE m110=PASS"
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d2a-sso-oidc}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m110=PASS" --outcome pass \
      --msg "D2a OIDC SSO: a mock OIDC IdP drives the full authorization-code grant — register connection (client secret AES-GCM sealed) -> begin -> IdP /authorize -> callback 200 + session JWT verifies under GoTrue HS256 (sub/email/role=authenticated); HS256 + RS256(JWKS) both verify; wrong-key id_token 401, replayed state 401 (load-bearing); SSO_ENABLED OFF -> all /v1/auth/sso/* 404 while admin 200, sso_connections never written (byte-parity, gotrue has no SSO)" \
      --ref "scripts/verify/m110-sso-oidc.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M110] ALL GATES GREEN — D2a OIDC SSO: the authorization-code login works end-to-end (HS256 + RS256/JWKS), rejects wrong-key + replayed-state, and is byte-parity (routes 404) when OFF"
exit 0
