#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m107-passkeys.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M107 — Track-D D2c PASSKEYS / WebAuthn gate. gotrue has NO passkey support;
# D2c adds server-side WebAuthn registration + authentication ceremonies, driven
# by the maintained github.com/go-webauthn/webauthn library, flag-gated OFF by
# default (PASSKEYS_ENABLED). It exercises a tenant-control binary built FROM
# CURRENT source — the EXACT D2c code — against a SOFTWARE AUTHENTICATOR also
# built from CURRENT source, so the full cryptographic ceremony runs end-to-end:
#
#   tenant-control (Go, PASSKEYS_ENABLED=1, RP_ID=localhost, ORIGIN=http://localhost)
#       │  POST /v1/auth/passkeys/register/begin  -> {challenge_id, publicKey}
#       ▼
#   m107-authenticator register (Go, in-memory ES256 key)
#       │  signs the creation challenge, emits the attestation response
#       ▼
#   POST /v1/auth/passkeys/register/finish  -> 200 {verified, credential_id}
#                                              (credential stored, sign_count=row)
#       │  POST /v1/auth/passkeys/login/begin   -> {challenge_id, publicKey}
#       ▼
#   m107-authenticator login (signs the assertion challenge with the SAME key)
#       │
#       ▼
#   POST /v1/auth/passkeys/login/finish  -> 200 {access_token} (a session JWT)
#                                           + sign_count incremented
#
#   (A · POSITIVE) register U1 -> login/begin -> the software authenticator signs
#       the challenge -> login/finish => 200 + a session JWT whose `sub` is U1 and
#       which VERIFIES under the same GoTrue HS256 secret; the credential's
#       sign_count is INCREMENTED in webauthn_credentials.
#   (B · REJECT, LOAD-BEARING) an assertion signed by the WRONG key (a fresh key,
#       not U1's) against U1's credential id -> login/finish => 401. AND a
#       replayed / non-matching challenge (a stale challenge_id) -> 404/401, never
#       a session.
#   (C · REJECT, LOAD-BEARING) user U2 cannot authenticate as U1: U2 starts its
#       OWN login ceremony but the authenticator signs with U1's credential id +
#       U2's key -> login/finish => 401 (the credential id is not one U2 owns AND
#       the signature does not verify) — no cross-user session.
#   (D · FLAG-OFF PARITY) with PASSKEYS_ENABLED unset, EVERY /v1/auth/passkeys/*
#       route is 404 and the webauthn_credentials table is never consulted — byte-
#       identical to today (gotrue has no passkeys). A SECOND tenant-control with
#       the flag unset is booted (after STOPPING the enabled one) to prove it.
#
# ISOLATED by design (mirrors m105/m104/m87): scratch postgres (prelude + REAL 050)
# + two tenant-control binaries built FROM CURRENT source + a software
# authenticator built FROM CURRENT source, ALL on a PRIVATE network, every name
# suffixed with $$, an EXIT-trap removing EVERYTHING. It NEVER touches a
# mini-baas-* container/network/image/volume and NEVER edits docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
GO_DIR="${INFRA_DIR}/src/control-plane"
MIG_DIR="${INFRA_DIR}/scripts/migrations/postgresql"
MIGRATION_005="${MIG_DIR}/005_add_tenant_table.sql"
MIGRATION_032="${MIG_DIR}/032_tenants.sql"
MIGRATION_050="${MIG_DIR}/050_webauthn_credentials.sql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M107] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M107] FAIL — $*"; exit 1; }

PG_IMAGE="${M107_PG_IMAGE:-postgres:16-alpine}"
GO_IMAGE="${M107_GO_IMAGE:-golang:1.25-bookworm}"
TC_IMG="m107-tc-$$:scratch"
AUTH_IMG="m107-auth-$$:scratch"
NET="m107net-$$"
PG="m107-pg-$$"
TC_ON="m107-tc-on-$$"      # PASSKEYS_ENABLED=1   (A/B/C)
TC_OFF="m107-tc-off-$$"    # PASSKEYS_ENABLED unset (D · flag-off parity)
# UNIQUE port pair for this gate (others default 19106/19107 / 19108/19109).
PORT_ON="${M107_PORT_ON:-19110}"
PORT_OFF="${M107_PORT_OFF:-19111}"
PGPW="postgres"
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
SVC_TOKEN="m107-internal-service-token-$$"
JWT_SECRET="m107-gotrue-hs256-secret-$$-do-not-use"
RP_ID="localhost"
RP_ORIGIN="http://localhost"
USER_1="11111111-1111-1111-1111-111111111111"
USER_2="22222222-2222-2222-2222-222222222222"
# This gate authorizes the begin routes with the control-plane SERVICE TOKEN
# (admin), so there is no tenant header: the credentials are stored untenanted
# (tenant_id='') and the cross-user wall (C) is the WebAuthn ownership check, not
# a tenant scope. A tenant-scoped variant would set X-Baas-Tenant-Id; the
# service-token path is the simpler, equally load-bearing surface for the gate.
WORK="$(mktemp -d)"
BODY_TMP="${WORK}/body.json"

cleanup() {
  docker rm -fv "${TC_ON}" "${TC_OFF}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${TC_IMG}" "${AUTH_IMG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# shellcheck disable=SC2120  # "$@" passthrough is intentional (house psql_q helper); callers pipe heredocs
psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# Apply a migration the SAME way make migrate does: strip the leading `#` 42-banner
# lines before piping to psql (the body uses `--` SQL comments psql tolerates).
apply_migration() { # $1=file
  sed '/^#/d' "$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1
}

# Service-token admin request (begin routes accept it). $1=method $2=port $3=path $4=body
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

# json_str: extract a top-level JSON string field off BODY_TMP. Tolerates 0 matches.
json_str() { { grep -o "\"$1\":\"[^\"]*\"" "${BODY_TMP}" 2>/dev/null || true; } | head -1 | sed 's/.*"'"$1"'":"//; s/"$//'; }

wait_ready() { # $1=container $2=port
  local i
  for i in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/health/live" 2>/dev/null)" == "200" ]] && return 0
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never became ready:"; docker logs "$1" 2>&1 | tail -20; return 1
}

# ── 0) write the SOFTWARE AUTHENTICATOR source (built FROM CURRENT module) ─────
# A real virtual authenticator: it generates an ES256 (P-256) key, and for
# `register` emits a WebAuthn attestation response (fmt="none"), for `login` emits
# an assertion response signed over authData||sha256(clientDataJSON). Flags:
#   --mode register|login  --rp <rpid>  --origin <origin>
#   --in <begin.json>      (the server's begin response: {challenge_id, publicKey})
#   --key <file>           (login: read the private key saved at register)
#   --out-key <file>       (register: save the private key)
#   --cred-id <b64url>     (login: override the asserted credential id — cross-user)
#   --wrong-key            (login: sign with a FRESH key, not the registered one)
# It prints the credential `response` object JSON to stdout (the gate wraps it
# with the challenge_id for the finish call). go-webauthn parses it verbatim.
step "0/12 write + build the software authenticator + tenant-control FROM CURRENT source"
mkdir -p "${WORK}/auth"
cat > "${WORK}/auth/main.go" <<'GOEOF'
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"os"

	"github.com/fxamacker/cbor/v2"
)

// b64u is base64url no-padding (the WebAuthn wire encoding).
func b64u(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func die(msg string, err error) {
	fmt.Fprintf(os.Stderr, "authenticator: %s: %v\n", msg, err)
	os.Exit(2)
}

// beginEnvelope is the server begin response we read. We only need the nested
// publicKey.challenge (+ rp.id for sanity); the rest is opaque options.
type beginEnvelope struct {
	ChallengeID string `json:"challenge_id"`
	PublicKey   struct {
		Challenge string `json:"challenge"` // base64url
		RP        struct {
			ID string `json:"id"`
		} `json:"rp"`
		RPID string `json:"rpId"` // assertion options carry rpId here
	} `json:"publicKey"`
}

// coseES256 builds the COSE_Key (CBOR map) for an ES256 P-256 public key.
//   1:2 (kty EC2) · 3:-7 (alg ES256) · -1:1 (crv P-256) · -2:x · -3:y
func coseES256(pub *ecdsa.PublicKey) []byte {
	x := pub.X.Bytes()
	y := pub.Y.Bytes()
	x = leftPad(x, 32)
	y = leftPad(y, 32)
	m := map[int]interface{}{
		1:  2,  // kty: EC2
		3:  -7, // alg: ES256
		-1: 1,  // crv: P-256
		-2: x,
		-3: y,
	}
	// COSE keys use integer map keys; cbor.Marshal of map[int]interface{} works.
	enc, err := cbor.Marshal(m)
	if err != nil {
		die("cose marshal", err)
	}
	return enc
}

func leftPad(b []byte, n int) []byte {
	if len(b) >= n {
		return b
	}
	out := make([]byte, n)
	copy(out[n-len(b):], b)
	return out
}

// authData builds the authenticator data:
//   rpIdHash(32) || flags(1) || signCount(4) [ || attestedCredData when attested ].
// flags: UP(0x01) + UV(0x04) [ + AT(0x40) on registration ].
func authData(rpID string, signCount uint32, attested []byte) []byte {
	h := sha256.Sum256([]byte(rpID))
	flags := byte(0x01 | 0x04) // UP + UV
	if len(attested) > 0 {
		flags |= 0x40 // AT
	}
	out := make([]byte, 0, 37+len(attested))
	out = append(out, h[:]...)
	out = append(out, flags)
	out = append(out, byte(signCount>>24), byte(signCount>>16), byte(signCount>>8), byte(signCount))
	out = append(out, attested...)
	return out
}

// attestedCredentialData: aaguid(16) || credIdLen(2) || credId || cosePubKey.
func attestedCredData(credID, cose []byte) []byte {
	out := make([]byte, 0, 16+2+len(credID)+len(cose))
	out = append(out, make([]byte, 16)...) // AAGUID all-zero ("none" attestation)
	out = append(out, byte(len(credID)>>8), byte(len(credID)))
	out = append(out, credID...)
	out = append(out, cose...)
	return out
}

func clientDataJSON(typ, challenge, origin string) []byte {
	// crossOrigin omitted (defaults false); field ORDER does not matter to the
	// verifier (it parses JSON), but we keep the canonical order.
	m := map[string]interface{}{"type": typ, "challenge": challenge, "origin": origin}
	b, err := json.Marshal(m)
	if err != nil {
		die("clientData marshal", err)
	}
	return b
}

func main() {
	mode := flag.String("mode", "", "register|login")
	rp := flag.String("rp", "localhost", "rp id")
	origin := flag.String("origin", "http://localhost", "origin")
	in := flag.String("in", "", "begin response json file")
	keyFile := flag.String("key", "", "login: private key PEM file")
	outKey := flag.String("out-key", "", "register: write private key PEM here")
	credIDOverride := flag.String("cred-id", "", "login: override asserted credential id (b64url)")
	wrongKey := flag.Bool("wrong-key", false, "login: sign with a fresh (wrong) key")
	signCount := flag.Uint("sign-count", 1, "authenticator sign counter")
	flag.Parse()

	raw, err := os.ReadFile(*in)
	if err != nil {
		die("read begin", err)
	}
	var env beginEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		die("parse begin", err)
	}
	challenge := env.PublicKey.Challenge
	if challenge == "" {
		die("begin", fmt.Errorf("no challenge in begin response"))
	}

	switch *mode {
	case "register":
		priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			die("genkey", err)
		}
		// random 32-byte credential id.
		credID := make([]byte, 32)
		if _, err := rand.Read(credID); err != nil {
			die("credid", err)
		}
		cose := coseES256(&priv.PublicKey)
		ad := authData(*rp, uint32(*signCount), attestedCredData(credID, cose))
		// attestationObject = CBOR{ fmt:"none", attStmt:{}, authData }.
		attObj := map[string]interface{}{
			"fmt":      "none",
			"attStmt":  map[string]interface{}{},
			"authData": ad,
		}
		attCBOR, err := cbor.Marshal(attObj)
		if err != nil {
			die("attobj marshal", err)
		}
		cdj := clientDataJSON("webauthn.create", challenge, *origin)
		resp := map[string]interface{}{
			"id":    b64u(credID),
			"rawId": b64u(credID),
			"type":  "public-key",
			"response": map[string]interface{}{
				"attestationObject": b64u(attCBOR),
				"clientDataJSON":    b64u(cdj),
			},
			"clientExtensionResults": map[string]interface{}{},
		}
		if *outKey != "" {
			der, _ := x509.MarshalECPrivateKey(priv)
			pemBytes := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
			if err := os.WriteFile(*outKey, pemBytes, 0600); err != nil {
				die("write key", err)
			}
		}
		out, _ := json.Marshal(resp)
		fmt.Println(string(out))

	case "login":
		var priv *ecdsa.PrivateKey
		if *wrongKey {
			priv, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				die("genkey", err)
			}
		} else {
			pemBytes, err := os.ReadFile(*keyFile)
			if err != nil {
				die("read key", err)
			}
			blk, _ := pem.Decode(pemBytes)
			if blk == nil {
				die("pem", fmt.Errorf("no PEM block"))
			}
			priv, err = x509.ParseECPrivateKey(blk.Bytes)
			if err != nil {
				die("parse key", err)
			}
		}
		// credential id: from the registered key file's sibling .cid, or override.
		credIDB64 := *credIDOverride
		if credIDB64 == "" && *keyFile != "" {
			cidRaw, err := os.ReadFile(*keyFile + ".cid")
			if err == nil {
				credIDB64 = string(cidRaw)
			}
		}
		if credIDB64 == "" {
			die("login", fmt.Errorf("no credential id (need --cred-id or a .cid sidecar)"))
		}
		credID, err := base64.RawURLEncoding.DecodeString(credIDB64)
		if err != nil {
			die("decode cred id", err)
		}
		ad := authData(*rp, uint32(*signCount), nil) // no attested cred data on assertion
		cdj := clientDataJSON("webauthn.get", challenge, *origin)
		cdjHash := sha256.Sum256(cdj)
		signed := append(append([]byte{}, ad...), cdjHash[:]...)
		digest := sha256.Sum256(signed)
		// ECDSA signature in ASN.1 DER (the WebAuthn assertion signature form).
		r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
		if err != nil {
			die("sign", err)
		}
		der := marshalECDSASig(r, s)
		resp := map[string]interface{}{
			"id":    b64u(credID),
			"rawId": b64u(credID),
			"type":  "public-key",
			"response": map[string]interface{}{
				"authenticatorData": b64u(ad),
				"clientDataJSON":    b64u(cdj),
				"signature":         b64u(der),
			},
			"clientExtensionResults": map[string]interface{}{},
		}
		out, _ := json.Marshal(resp)
		fmt.Println(string(out))

	default:
		die("mode", fmt.Errorf("want register|login, got %q", *mode))
	}
}

// marshalECDSASig encodes (r,s) as an ASN.1 DER ECDSA-Sig-Value.
func marshalECDSASig(r, s *big.Int) []byte {
	der, err := asn1Marshal(r, s)
	if err != nil {
		die("asn1", err)
	}
	return der
}
GOEOF

# A tiny asn1 helper in its own file (keeps main.go free of encoding/asn1 quirks).
cat > "${WORK}/auth/asn1.go" <<'GOEOF'
package main

import (
	"encoding/asn1"
	"math/big"
)

type ecdsaSig struct{ R, S *big.Int }

func asn1Marshal(r, s *big.Int) ([]byte, error) {
	return asn1.Marshal(ecdsaSig{R: r, S: s})
}
GOEOF

# Build the authenticator INSIDE the control-plane module so it shares go.mod
# (go-webauthn's fxamacker/cbor is already a resolved dependency). We copy the
# two files into a throwaway cmd dir of the module, build, and extract the binary.
build_authenticator() {
  docker run --rm \
    -v "${GO_DIR}":/src:ro \
    -v "${WORK}/auth":/auth:ro \
    -v "${WORK}":/out \
    -e GOFLAGS=-mod=mod \
    -e CGO_ENABLED=0 \
    "${GO_IMAGE}" bash -c '
      set -e
      cp -r /src /build && cd /build
      mkdir -p cmd/m107-authenticator
      cp /auth/main.go /auth/asn1.go cmd/m107-authenticator/
      go build -o /out/m107-authenticator ./cmd/m107-authenticator
    ' >/dev/null 2>"${WORK}/authbuild.err"
}
build_authenticator || { red "authenticator build failed:"; tail -30 "${WORK}/authbuild.err"; fail "software authenticator must build from CURRENT module (line: build authenticator)"; }
[[ -x "${WORK}/m107-authenticator" ]] || fail "authenticator binary not produced (line: authenticator binary)"
ok "software authenticator built (ES256 virtual authenticator, fmt=none)"

# Run the authenticator binary (it is a static linux/amd64 ELF; run it in a tiny
# container so we never depend on the host arch/glibc). $@ passes flags.
authn() { docker run --rm -v "${WORK}":/w -w /w "${GO_IMAGE}" /w/m107-authenticator "$@"; }

DOCKER_BUILDKIT=1 docker build -q --build-arg APP=tenant-control --build-arg PORT=3070 \
  -t "${TC_IMG}" "${GO_DIR}" >/dev/null \
  || fail "scratch tenant-control image build failed — gate must exercise the drafted D2c code (line: docker build TC)"
ok "tenant-control built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres (TCP-ready, not just socket) ─────────────────────
step "1/12 boot isolated net (${NET}): postgres"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  if docker exec "${PG}" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 \
     && [[ "$(psql_val 'SELECT 1')" == "1" ]]; then break; fi
  [[ $i -eq 80 ]] && { docker logs "${PG}" 2>&1 | tail -20; fail "scratch postgres never reached TCP-ready"; }
  sleep 0.5
done
ok "postgres up + TCP-ready (SELECT 1 ok)"

# ── 1b) prelude (schema_migrations, auth.current_tenant_id, roles) then REAL 050 ─
step "1b/12 prelude (schema_migrations, auth.current_tenant_id, roles) then REAL 050_webauthn_credentials"
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
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
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
# tenant-control's boot schema-check requires public.tenants (005 + 032) — apply
# the base tenant schema before the D2c migration, exactly as m105/m106 do.
apply_migration "${MIGRATION_005}" || fail "real migration 005_add_tenant_table.sql failed to apply (line: apply 005)"
apply_migration "${MIGRATION_032}" || fail "real migration 032_tenants.sql failed to apply (line: apply 032)"
[[ -f "${MIGRATION_050}" ]] || fail "migration 050_webauthn_credentials.sql is MISSING — the D2c migration must land before m107 (line: 050 exists)"
apply_migration "${MIGRATION_050}" || fail "real migration 050_webauthn_credentials.sql failed to apply (line: apply 050)"
[[ "$(psql_val "SELECT to_regclass('public.webauthn_credentials') IS NOT NULL")" == "t" ]] \
  || fail "public.webauthn_credentials not created by migration 050 (line: 050 table check)"
[[ "$(psql_val "SELECT count(*) FROM public.webauthn_credentials")" == "0" ]] \
  || fail "webauthn_credentials should start EMPTY (line: 050 empty check)"
# Append/manage-only at the grant layer: authenticated must NOT have INSERT/UPDATE/DELETE.
HASW="$(psql_val "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='webauthn_credentials' AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE')")" || HASW="?"
[[ "${HASW}" == "0" ]] || fail "authenticated must NOT have INSERT/UPDATE/DELETE on webauthn_credentials, got ${HASW} (line: 050 grants)"
ok "migration 050 applied — webauthn_credentials exists, empty, authenticated read-only"

# ── 2) boot the PASSKEYS-ON tenant-control ─────────────────────────────────────
step "2/12 boot tenant-control PASSKEYS_ENABLED=1 on 127.0.0.1:${PORT_ON} (A · positive / B · reject / C · reject)"
docker run -d --name "${TC_ON}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e PASSKEYS_ENABLED=1 \
  -e PASSKEYS_RP_ID="${RP_ID}" \
  -e PASSKEYS_RP_ORIGINS="${RP_ORIGIN}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_ON}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_ON}" "${PORT_ON}" || fail "passkeys-ON tenant-control not ready (line: wait_ready TC_ON)"
{ docker logs "${TC_ON}" 2>&1 || true; } | grep -q "passkeys / WebAuthn enabled" \
  || { docker logs "${TC_ON}" 2>&1 | tail -20; fail "passkeys never reported enabled (line: TC_ON enabled log)"; }
ok "passkeys-ON tenant-control up (/v1/auth/passkeys/* mounted)"

# ── 3) (A · POSITIVE) register a passkey for U1 ────────────────────────────────
step "3/12 (A) register/begin for U1, software authenticator signs, register/finish => 200 + credential stored"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/register/begin \
  "{\"user_id\":\"${USER_1}\",\"name\":\"u1@example.com\",\"display_name\":\"User One\"}")"
[[ "${C}" == "200" ]] || fail "(A) register/begin expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A reg begin)"
cp "${BODY_TMP}" "${WORK}/reg_begin.json"
REG_CH="$(json_str challenge_id)"
[[ -n "${REG_CH}" ]] || fail "(A) register/begin did not return a challenge_id — $(head -c 300 "${BODY_TMP}") (line: A reg challenge)"
grep -q '"challenge"' "${WORK}/reg_begin.json" || fail "(A) register/begin missing publicKey.challenge (line: A reg pkchallenge)"
# Software authenticator builds the attestation response, saves U1's private key.
authn --mode register --rp "${RP_ID}" --origin "${RP_ORIGIN}" \
  --in /w/reg_begin.json --out-key /w/u1.key > "${WORK}/reg_resp.json" \
  || { red "authenticator register failed"; cat "${WORK}/reg_resp.json" 2>/dev/null; fail "(A) authenticator register (line: A authn register)"; }
# The credential id the authenticator chose (top-level "id"), saved as a sidecar
# so the login step asserts the same credential.
REG_CID="$(grep -o '"id":"[^"]*"' "${WORK}/reg_resp.json" | head -1 | sed 's/"id":"//; s/"$//')"
[[ -n "${REG_CID}" ]] || fail "(A) authenticator did not emit a credential id (line: A authn cid)"
printf '%s' "${REG_CID}" > "${WORK}/u1.key.cid"
# finish: {challenge_id, response:<the authenticator response>}.
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${REG_CH}" "$(cat "${WORK}/reg_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/register/finish "${FIN_BODY}")"
[[ "${C}" == "200" ]] || fail "(A) register/finish expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: A reg finish)"
grep -q '"verified":true' "${BODY_TMP}" || fail "(A) register/finish not verified — $(head -c 400 "${BODY_TMP}") (line: A reg verified)"
# The credential is durably stored for U1, sign_count seeded from the attestation.
[[ "$(psql_val "SELECT count(*) FROM public.webauthn_credentials WHERE user_id='${USER_1}'")" == "1" ]] \
  || fail "(A) U1's credential not persisted to webauthn_credentials (line: A cred stored)"
SIGN_BEFORE="$(psql_val "SELECT sign_count FROM public.webauthn_credentials WHERE user_id='${USER_1}'")"
ok "(A) U1 passkey registered + stored (sign_count=${SIGN_BEFORE})"

# ── 4) (A · POSITIVE) login U1: begin -> sign -> finish => 200 + session JWT ───
step "4/12 (A) login/begin U1, authenticator signs the challenge, login/finish => 200 + a valid session JWT"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/begin "{\"user_id\":\"${USER_1}\"}")"
[[ "${C}" == "200" ]] || fail "(A) login/begin expected 200, got ${C} — $(head -c 300 "${BODY_TMP}") (line: A login begin)"
cp "${BODY_TMP}" "${WORK}/login_begin.json"
LOGIN_CH="$(json_str challenge_id)"
[[ -n "${LOGIN_CH}" ]] || fail "(A) login/begin did not return a challenge_id (line: A login challenge)"
authn --mode login --rp "${RP_ID}" --origin "${RP_ORIGIN}" \
  --in /w/login_begin.json --key /w/u1.key --sign-count 2 > "${WORK}/login_resp.json" \
  || { red "authenticator login failed"; cat "${WORK}/login_resp.json" 2>/dev/null; fail "(A) authenticator login (line: A authn login)"; }
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${LOGIN_CH}" "$(cat "${WORK}/login_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/finish "${FIN_BODY}")"
[[ "${C}" == "200" ]] || fail "(A) login/finish expected 200, got ${C} — $(head -c 500 "${BODY_TMP}") (line: A login finish)"
ACCESS="$(json_str access_token)"
[[ -n "${ACCESS}" ]] || fail "(A) login/finish returned no access_token — $(head -c 400 "${BODY_TMP}") (line: A access token)"
LOGIN_SUB="$(json_str user_id)"
[[ "${LOGIN_SUB}" == "${USER_1}" ]] || fail "(A) session user_id '${LOGIN_SUB}' != U1 (line: A session sub)"
ok "(A) login => 200, session JWT issued for U1"

# Verify the JWT really verifies under the SAME HS256 secret (decode + check sig
# via a tiny openssl HMAC over header.payload). This proves the session is real,
# not a placebo string.
step "4b/12 (A) the session JWT VERIFIES under the GoTrue HS256 secret + sub==U1"
H="${ACCESS%%.*}"; REST="${ACCESS#*.}"; P="${REST%%.*}"; SIG="${ACCESS##*.}"
SIGNED_PART="${H}.${P}"
EXPECT_SIG="$(printf '%s' "${SIGNED_PART}" | openssl dgst -sha256 -hmac "${JWT_SECRET}" -binary | base64 | tr '+/' '-_' | tr -d '=')"
[[ "${SIG}" == "${EXPECT_SIG}" ]] || fail "(A) session JWT signature does NOT verify under the GoTrue secret (got ${SIG} want ${EXPECT_SIG}) (line: A jwt sig)"
# decode the payload (add base64 padding) and assert sub==U1, role authenticated.
PAD=$(( (4 - ${#P} % 4) % 4 )); PADP="${P}$(printf '%*s' "${PAD}" '' | tr ' ' '=')"
CLAIMS="$(printf '%s' "${PADP}" | tr '_-' '/+' | base64 -d 2>/dev/null || true)"
echo "${CLAIMS}" | grep -q "\"sub\":\"${USER_1}\"" || fail "(A) JWT sub != U1 — claims: ${CLAIMS} (line: A jwt sub)"
echo "${CLAIMS}" | grep -q '"role":"authenticated"' || fail "(A) JWT role != authenticated — claims: ${CLAIMS} (line: A jwt role)"
ok "(A) session JWT verifies under the GoTrue secret; sub=U1, role=authenticated"

# ── 5) (A) sign_count INCREMENTED after the verified login ─────────────────────
step "5/12 (A) the credential sign_count was INCREMENTED by the verified login"
SIGN_AFTER="$(psql_val "SELECT sign_count FROM public.webauthn_credentials WHERE user_id='${USER_1}'")"
[[ -n "${SIGN_AFTER}" && "${SIGN_AFTER}" -gt "${SIGN_BEFORE}" ]] 2>/dev/null \
  || fail "(A) sign_count not incremented: before=${SIGN_BEFORE} after=${SIGN_AFTER} (line: A sign_count bump)"
ok "(A) sign_count ${SIGN_BEFORE} -> ${SIGN_AFTER} (replay/clone evidence advanced)"

# ── 6) (B · REJECT) an assertion signed by the WRONG key -> 401 ────────────────
step "6/12 (B · REJECT, LOAD-BEARING) login/finish with an assertion signed by the WRONG key => 401"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/begin "{\"user_id\":\"${USER_1}\"}")"
[[ "${C}" == "200" ]] || fail "(B) login/begin expected 200, got ${C} (line: B login begin)"
cp "${BODY_TMP}" "${WORK}/b_begin.json"
B_CH="$(json_str challenge_id)"
# wrong key, but the SAME (registered) credential id (sidecar via --key path).
authn --mode login --rp "${RP_ID}" --origin "${RP_ORIGIN}" \
  --in /w/b_begin.json --wrong-key --cred-id "${REG_CID}" --sign-count 3 > "${WORK}/b_resp.json" \
  || fail "(B) authenticator (wrong-key) failed to emit a response (line: B authn)"
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${B_CH}" "$(cat "${WORK}/b_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/finish "${FIN_BODY}")"
[[ "${C}" == "401" ]] || fail "(B) wrong-key assertion expected 401, got ${C} — $(head -c 400 "${BODY_TMP}") (line: B wrong-key 401)"
grep -q '"access_token"' "${BODY_TMP}" && fail "(B) a wrong-key assertion MINTED a session — verification broken! (line: B no token)"
ok "(B) wrong-key assertion rejected 401 (no session)"

# ── 6b) (B · REJECT) a REPLAYED / stale challenge -> 404 (single-use) ──────────
step "6b/12 (B · REJECT) a REPLAYED challenge id (already consumed in step 4) => 404, never a session"
# Re-use step 4's challenge_id + response (both already consumed at finish).
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${LOGIN_CH}" "$(cat "${WORK}/login_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/finish "${FIN_BODY}")"
[[ "${C}" == "404" || "${C}" == "401" ]] \
  || fail "(B) replayed challenge expected 404/401, got ${C} — $(head -c 300 "${BODY_TMP}") (line: B replay)"
grep -q '"access_token"' "${BODY_TMP}" && fail "(B) a REPLAYED challenge minted a session — single-use broken! (line: B replay no token)"
ok "(B) replayed/consumed challenge rejected ${C} (single-use enforced, no session)"

# ── 7) (C · REJECT) U2 cannot authenticate as U1 with U1's cred id + U2's key ──
step "7/12 (C · REJECT, LOAD-BEARING) U2 cannot auth as U1: U2 ceremony + U1's credential id + U2's key => 401"
# First register a passkey for U2 (so U2 has its own credential + ceremony).
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/register/begin \
  "{\"user_id\":\"${USER_2}\",\"name\":\"u2@example.com\"}")"
[[ "${C}" == "200" ]] || fail "(C) U2 register/begin expected 200, got ${C} (line: C u2 reg begin)"
cp "${BODY_TMP}" "${WORK}/u2_reg_begin.json"
U2_REG_CH="$(json_str challenge_id)"
authn --mode register --rp "${RP_ID}" --origin "${RP_ORIGIN}" \
  --in /w/u2_reg_begin.json --out-key /w/u2.key > "${WORK}/u2_reg_resp.json" \
  || fail "(C) authenticator register U2 (line: C u2 authn register)"
U2_CID="$(grep -o '"id":"[^"]*"' "${WORK}/u2_reg_resp.json" | head -1 | sed 's/"id":"//; s/"$//')"
printf '%s' "${U2_CID}" > "${WORK}/u2.key.cid"
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${U2_REG_CH}" "$(cat "${WORK}/u2_reg_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/register/finish "${FIN_BODY}")"
[[ "${C}" == "200" ]] || fail "(C) U2 register/finish expected 200, got ${C} — $(head -c 400 "${BODY_TMP}") (line: C u2 reg finish)"
# U2 begins its OWN login ceremony.
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/begin "{\"user_id\":\"${USER_2}\"}")"
[[ "${C}" == "200" ]] || fail "(C) U2 login/begin expected 200, got ${C} (line: C u2 login begin)"
cp "${BODY_TMP}" "${WORK}/c_begin.json"
C_CH="$(json_str challenge_id)"
# The attacker asserts U1's credential id (REG_CID) but signs with U2's key.
authn --mode login --rp "${RP_ID}" --origin "${RP_ORIGIN}" \
  --in /w/c_begin.json --key /w/u2.key --cred-id "${REG_CID}" --sign-count 5 > "${WORK}/c_resp.json" \
  || fail "(C) authenticator (cross-user) failed to emit a response (line: C authn)"
FIN_BODY="$(printf '{"challenge_id":"%s","response":%s}' "${C_CH}" "$(cat "${WORK}/c_resp.json")")"
C="$(admin_req POST "${PORT_ON}" /v1/auth/passkeys/login/finish "${FIN_BODY}")"
[[ "${C}" == "401" ]] || fail "(C) cross-user assertion expected 401, got ${C} — $(head -c 400 "${BODY_TMP}") (line: C cross-user 401)"
grep -q '"access_token"' "${BODY_TMP}" && fail "(C) U2 authenticated as U1 with U1's credential id — CROSS-USER AUTH! (line: C no token)"
ok "(C) U2 cannot auth as U1 (U1's cred id not owned by U2 + U2's key does not verify) — 401, no session"

# ── 8) (D · FLAG-OFF PARITY) flag unset -> every /v1/auth/passkeys/* route 404 ─
step "8/12 (D · FLAG-OFF PARITY) STOP the ENABLED container; boot with PASSKEYS_ENABLED unset (same DB)"
docker rm -fv "${TC_ON}" >/dev/null 2>&1 || true
CRED_BEFORE="$(psql_val "SELECT count(*) FROM public.webauthn_credentials")"
docker run -d --name "${TC_OFF}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e GOTRUE_JWT_SECRET="${JWT_SECRET}" \
  -e TENANT_CONTROL_PORT=3070 \
  -e TENANT_CONTROL_PRODUCT_MODE=enabled \
  -e LOG_LEVEL=debug \
  -p "127.0.0.1:${PORT_OFF}:3070" "${TC_IMG}" >/dev/null
wait_ready "${TC_OFF}" "${PORT_OFF}" || fail "passkeys-OFF tenant-control not ready (line: wait_ready TC_OFF)"
{ docker logs "${TC_OFF}" 2>&1 || true; } | grep -q "passkeys / WebAuthn disabled" \
  || { docker logs "${TC_OFF}" 2>&1 | tail -20; fail "OFF tenant-control did not report passkeys disabled (flag default not OFF?) (line: TC_OFF disabled log)"; }
ok "passkeys-OFF tenant-control up (PASSKEYS_ENABLED unset)"

step "9/12 (D) EVERY /v1/auth/passkeys/* route 404 with the flag OFF (byte-parity — gotrue has no passkeys)"
for path in \
  "/v1/auth/passkeys/register/begin" \
  "/v1/auth/passkeys/register/finish" \
  "/v1/auth/passkeys/login/begin" \
  "/v1/auth/passkeys/login/finish"; do
  C="$(admin_req POST "${PORT_OFF}" "${path}" '{"user_id":"x"}')"
  [[ "${C}" == "404" ]] \
    || fail "(D) PARITY: ${path} with PASSKEYS_ENABLED off expected 404 (route absent), got ${C} — $(head -c 200 "${BODY_TMP}") (line: D 404 ${path})"
done
ok "(D) all four passkeys routes 404 with the flag OFF"

step "10/12 (D) the base admin surface STILL works on the OFF router (proves only passkeys is gated)"
C="$(admin_req GET "${PORT_OFF}" "/v1/tenants")"
[[ "${C}" == "200" ]] \
  || fail "(D) PARITY: base admin GET /v1/tenants expected 200 on OFF router, got ${C} — $(head -c 200 "${BODY_TMP}") (line: D admin 200)"
ok "(D) base admin GET /v1/tenants => 200 — the baseline is untouched; only passkeys is flag-gated"

step "11/12 (D) the OFF router NEVER consulted webauthn_credentials (count unchanged, no new rows)"
CRED_AFTER="$(psql_val "SELECT count(*) FROM public.webauthn_credentials")"
[[ "${CRED_AFTER}" == "${CRED_BEFORE}" ]] \
  || fail "(D) PARITY: webauthn_credentials changed under the OFF router (before=${CRED_BEFORE} after=${CRED_AFTER}) (line: D no writes)"
ok "(D) webauthn_credentials unchanged (${CRED_AFTER}) — the table is never touched with the flag OFF"

# ── summarize ──────────────────────────────────────────────────────────────────
step "12/12 summary"
green "[M107] (A) POSITIVE: register U1 (stored, sign_count=${SIGN_BEFORE}) -> login/begin -> software authenticator signs -> login/finish 200, session JWT VERIFIES under the GoTrue secret (sub=U1, role=authenticated); sign_count ${SIGN_BEFORE}->${SIGN_AFTER}"
green "[M107] (B) REJECT:   wrong-key assertion => 401 (no session); replayed/consumed challenge => 404/401 (single-use, no session)"
green "[M107] (C) REJECT:   U2 + U1's credential id + U2's key => 401 — no cross-user session"
green "[M107] (D) PARITY:   PASSKEYS_ENABLED off => all /v1/auth/passkeys/* 404 while admin GET /v1/tenants 200; webauthn_credentials never touched — byte-identical to today (gotrue has no passkeys)"

# ── emit the gate event via the kernel log helper (best-effort) ─────────────────
step "log GATE m107=PASS"
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d2c-passkeys}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m107=PASS" --outcome pass \
      --msg "D2c passkeys/WebAuthn: software authenticator drives the full go-webauthn ceremony — register U1 (stored) -> login/begin -> sign -> login/finish 200 + session JWT verifies under GoTrue HS256 (sub=U1), sign_count incremented; wrong-key 401, replayed challenge 404, U2-as-U1 401 (load-bearing); PASSKEYS_ENABLED OFF -> all /v1/auth/passkeys/* 404 while admin 200, credentials table never touched (byte-parity, gotrue has no passkeys)" \
      --ref "scripts/verify/m107-passkeys.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M107] ALL GATES GREEN — D2c passkeys: the WebAuthn registration + authentication ceremonies work end-to-end (real software authenticator), reject wrong-key / replay / cross-user, and are byte-parity (routes 404) when OFF"
exit 0
