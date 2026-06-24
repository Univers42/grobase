#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    v09-keystore-escrow.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dev.pro.photo@gmail.com>         +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/21 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/21 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# V09 — multi-device keystore ESCROW (P1). A passphrase-wrapped keystore blob is stored
# per email and fetched on a second device after an email-OTP proof confirms mailbox
# control. The blob round-trips BYTE-IDENTICAL (so device B can unlock it with the same
# passphrase), the server holds only ciphertext, and PUT/fetch require a valid proof.
#
# ISOLATED (mirrors m164): scratch postgres (prelude + 005/032/075/076) + a tenant-control
# FROM CURRENT source, names suffixed $$, EXIT-trap cleanup. Never touches mini-baas-*.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
ok() { green "  ✓ $*"; }
fail() { red "[V09] FAIL — $*"; exit 1; }

TC_IMG="v09-tc-$$:scratch"; NET="v09net-$$"; PG="v09-pg-$$"; TC_ON="v09-on-$$"; TC_OFF="v09-off-$$"
PORT_ON=19182; PORT_OFF=19183; PGPW=postgres
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
JWT_SECRET="v09-shared-gotrue-secret-$$"; PEPPER="v09-pepper-$$"
EMAIL="dev@grobase.test"
BLOB="eyJzYWx0IjoiZGVhZGJlZWYiLCJjaXBoZXJ0ZXh0Ijoid3JhcHBlZC1rZXlzdG9yZS1ibG9iLXYwOSJ9"
BODY="$(mktemp)"

cleanup() { docker rm -fv "$TC_ON" "$TC_OFF" "$PG" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; docker image rm -f "$TC_IMG" >/dev/null 2>&1 || true; rm -f "$BODY" 2>/dev/null || true; }
trap cleanup EXIT

psql_v() { docker exec -i "$PG" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
apply() { sed '/^#/d' "$1" | docker exec -i "$PG" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; }
mint() { V_EMAIL="$1" V_SECRET="$JWT_SECRET" python3 - <<'PY'
import os, json, time, hmac, hashlib, base64
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b'=').decode()
h = b(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
p = b(json.dumps({"otp":os.environ["V_EMAIL"],"aud":"otp-proof","exp":int(time.time())+300},separators=(',',':')).encode())
sig = b(hmac.new(os.environ["V_SECRET"].encode(), f"{h}.{p}".encode(), hashlib.sha256).digest())
print(f"{h}.{p}.{sig}")
PY
}
wait_http() { local i; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null)" = 200 ] && return 0; docker inspect "$1" >/dev/null 2>&1 || { docker logs "$1" 2>&1 | tail -15; return 1; }; sleep 0.5; done; docker logs "$1" 2>&1 | tail -15; return 1; }

echo "[V09] 1/5 build tenant-control + scratch postgres + migrations 005/032/075/076"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3020 -t "$TC_IMG" "$GO_DIR" >/dev/null || fail "build failed"
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD="$PGPW" postgres:16-alpine >/dev/null
for i in $(seq 1 90); do docker exec "$PG" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && [ "$(psql_v 'SELECT 1')" = 1 ] && break; [ "$i" = 90 ] && fail "pg never ready"; sleep 0.5; done
docker exec -i "$PG" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid $fn$;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $fn$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id', NULLIF(current_setting('app.current_tenant_id', true), ''), auth.current_user_id()::text)::uuid $fn$;
DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF; END $r$;
SQL
for m in 005_add_tenant_table 032_tenants 075_login_otp 076_login_escrow; do apply "${MIG_DIR}/${m}.sql" || fail "migration $m failed"; done
[ "$(psql_v 'SELECT count(*) FROM public.login_escrow')" = 0 ] || fail "login_escrow should start empty"
ok "migrations applied; login_escrow empty"

echo "[V09] 2/5 boot tenant-control EMAIL_OTP_ENABLED=1"
docker run -d --name "$TC_ON" --network "$NET" -e DATABASE_URL="$DB_INNET" -e INTERNAL_SERVICE_TOKEN="v09-svc-$$" \
  -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e EMAIL_OTP_ENABLED=1 -e KEY_HASH_PEPPER="$PEPPER" \
  -e SMTP_HOST=localhost -e SMTP_PORT=1025 -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e ADAPTER_REGISTRY_URL="" -e LOG_LEVEL=warn -p "127.0.0.1:$PORT_ON:3020" "$TC_IMG" >/dev/null
wait_http "$TC_ON" "$PORT_ON" /health/live || fail "TC not ready"
ok "tenant-control up (/v1/auth/escrow mounted)"

echo "[V09] 3/5 escrow PUT (valid proof) → fetch → BYTE-IDENTICAL"
PROOF="$(mint "$EMAIL")"
C="$(curl -s -o "$BODY" -w '%{http_code}' -X PUT "http://127.0.0.1:$PORT_ON/v1/auth/escrow" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"proof\":\"$PROOF\",\"blob\":\"$BLOB\"}")"
[ "$C" = 200 ] || fail "escrow PUT expected 200, got $C — $(head -c 200 "$BODY")"
[ "$(psql_v "SELECT count(*) FROM public.login_escrow WHERE email='$EMAIL'")" = 1 ] || fail "escrow row not stored"
C="$(curl -s -o "$BODY" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT_ON/v1/auth/escrow/fetch" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"proof\":\"$PROOF\"}")"
[ "$C" = 200 ] || fail "escrow fetch expected 200, got $C — $(head -c 200 "$BODY")"
GOT="$(grep -o '"blob":"[^"]*"' "$BODY" | sed 's/.*://; s/"//g')"
[ "$GOT" = "$BLOB" ] || fail "fetched blob differs from stored (multi-device round-trip broken)"
ok "escrow stored + fetched BYTE-IDENTICAL (device B can unlock it with the passphrase)"

echo "[V09] 4/5 PUT without proof → 401 · fetch with wrong-email proof → 401"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$PORT_ON/v1/auth/escrow" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"blob\":\"$BLOB\"}")" = 401 ] || fail "PUT without proof not rejected"
WRONG="$(mint "someone-else@grobase.test")"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT_ON/v1/auth/escrow/fetch" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"proof\":\"$WRONG\"}")" = 401 ] || fail "fetch with wrong-email proof not rejected"
ok "missing proof → 401; wrong-email proof → 401 (mailbox control enforced)"

echo "[V09] 5/5 flag OFF → /v1/auth/escrow* 404 (byte-parity)"
docker run -d --name "$TC_OFF" --network "$NET" -e DATABASE_URL="$DB_INNET" -e INTERNAL_SERVICE_TOKEN="v09-svc-$$" \
  -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e TENANT_CONTROL_PORT=3020 -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=warn -p "127.0.0.1:$PORT_OFF:3020" "$TC_IMG" >/dev/null
wait_http "$TC_OFF" "$PORT_OFF" /health/live || fail "TC-OFF not ready"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$PORT_OFF/v1/auth/escrow" -H 'Content-Type: application/json' -d '{"email":"x","blob":"y"}')" = 404 ] || fail "escrow PUT with flag OFF expected 404"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT_OFF/v1/auth/escrow/fetch" -H 'Content-Type: application/json' -d '{"email":"x"}')" = 404 ] || fail "escrow fetch with flag OFF expected 404"
ok "flag OFF → escrow routes 404 (byte-parity)"

green "[V09] ALL GATES GREEN — multi-device keystore escrow (byte-identical round-trip, proof-gated, flag-OFF parity)"
exit 0
