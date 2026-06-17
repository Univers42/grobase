#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m121-credref-vault-enforce.sh                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M121 — G-Vault (S2): a tenant may register an external DB mount as a Vault
# credential REFERENCE instead of an inline plaintext DSN, and a tenant whose
# package security_mode=max is FORBIDDEN from registering an inline plaintext DSN
# at all. This is the PER-REQUEST DSN-RESOLUTION proof — distinct from m65, which
# only proves the BOOT-time master-credential fail-closed (VAULT_ENC_KEY). m121
# proves the runtime path: the control plane stores a credential_ref (no
# encryption), and the Rust data plane resolves the REAL DSN from Vault at query
# time via its existing VaultProvider (credential.rs).
#
# Three arms (all against scratch-from-source services on a PRIVATE network):
#
#   (1) NEGATIVE / max + inline plaintext: a max-security tenant POSTs
#       /databases with an inline `connection_string` -> HTTP 403
#       (plaintext_dsn_forbidden); assert ZERO rows land in tenant_databases.
#   (2) POSITIVE / max + credential_ref: the SAME max tenant POSTs with
#       `credential_ref{provider:vault, reference:<path>}` (the dev Vault holds
#       the real DSN at that path) -> 201; then a real /v1/query as that mount
#       (credential_ref, NO inline_dsn) resolves the DSN FROM VAULT and serves
#       200 against a probe table reachable only via that resolved DSN.
#   (3) PARITY / baseline + inline plaintext: a non-max tenant POSTs with an
#       inline `connection_string` -> 201 (today's behaviour unchanged).
#
# NON-VACUITY (fails on today's HEAD): the NEGATIVE arm's 403 cannot happen
# without the new max-mode plaintext rejection (Register would 201), and the
# POSITIVE arm's Vault resolution cannot happen without the new credential_ref
# field + GetConnection surfacing it / the resolver invoking the VaultProvider —
# so on the pre-S2 code the registration of a credential_ref is rejected as a
# missing connection_string (validation 400) and the positive query never
# reaches Vault. Both arms break on HEAD; only the S2 code passes.
#
# ISOLATED by design (mirrors m65 / m101): scratch postgres (migration 004 +
# 060) + a dev Vault + adapter-registry + data-plane-router built FROM CURRENT
# source, on a PRIVATE network, every name suffixed $$, an EXIT-trap removing
# EVERYTHING. It NEVER touches a mini-baas-* container/network/image/volume and
# NEVER edits the live docker-compose.yml. No host ports for the data path —
# only loopback-bound publish for the two probes.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                 # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                      # apps/baas
CP_DIR="${INFRA_DIR}/src/control-plane"
DPR_DIR="${INFRA_DIR}/src/data-plane-router"
MIGRATIONS="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M121] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M121] FAIL — $*"; exit 1; }

PG_IMAGE="${M121_PG_IMAGE:-postgres:16-alpine}"
VAULT_IMAGE="${M121_VAULT_IMAGE:-hashicorp/vault:latest}"
AR_IMG="m121-ar-$$:scratch"
DPR_IMG="m121-dpr-$$:scratch"
NET="m121net-$$"
PG="m121-pg-$$"
VAULT="m121-vault-$$"
AR="m121-ar-$$"           # adapter-registry (PACKAGE_ENFORCEMENT=1)
DPR="m121-dpr-$$"         # data-plane-router (VaultProvider configured)
PORT_AR="${M121_PORT_AR:-18991}"
PORT_DPR="${M121_PORT_DPR:-18992}"
PGPW="postgres"
SVC_TOKEN="m121-internal-service-token-$$"
VAULT_TOKEN="m121-dev-root-$$"
ENC_KEY="m121-real-master-key-not-a-placeholder-$$"
PROBE_TABLE="m121_probe"

# Two REAL tenant identities. tenant_databases.tenant_id is UUID (migration 004),
# and packageForTenant resolves plan via tenants.slug = <the header value>, so we
# use a UUID as BOTH the identity header AND the slug for each tenant.
UUID_MAX="aaaa1111-2222-3333-4444-555566667777"
UUID_BASE="bbbb1111-2222-3333-4444-555566667777"
# Vault KV v2 path the credential_ref points at (under the default prefix
# `data-plane/dsn`, field `dsn`). validate_ref_segment forbids '/', so the
# reference is a single clean segment.
VAULT_REF="m121-tenant-max-dsn"

# In-network DSNs.
DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
VAULT_INNET="http://${VAULT}:8200"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${DPR}" "${AR}" "${VAULT}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${AR_IMG}" "${DPR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_q()   { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

# POST /databases as a given tenant identity (X-User-Id header), body $2.
post_register() { # $1=tenant-uuid  $2=json-body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' --max-time 8 \
    -X POST "http://127.0.0.1:${PORT_AR}/databases" \
    -H 'Content-Type: application/json' \
    -H "X-User-Id: $1" -H "X-Tenant-Id: $1" \
    -d "$2"
}

# POST a /v1/query list envelope for a credential_ref (Vault-backed) mount — NO
# inline_dsn, so the data plane MUST resolve the DSN from Vault via the
# VaultProvider keyed by credential_ref.provider="vault".
#   $1 = tenant uuid   $2 = mount id   $3 = vault reference
payload_credref_list() {
  printf '{"identity":{"tenant_id":"%s","user_id":"%s","roles":["service_role"],"scopes":["admin"],"source":"test"},"mount":{"id":"%s","tenant_id":"%s","engine":"postgresql","name":"probe","credential_ref":{"provider":"vault","reference":"%s","version":""},"capability_overrides":null,"inline_dsn":null,"isolation":"shared_rls"},"operation":{"op":"list","resource":"%s","data":null}}' \
    "$1" "$1" "$2" "$1" "$3" "${PROBE_TABLE}"
}

post_q() { # $1=body
  curl -s -o "${BODY_TMP}" -w '%{http_code}' --max-time 8 \
    -X POST "http://127.0.0.1:${PORT_DPR}/v1/query" \
    -H 'Content-Type: application/json' -d "$1"
}

health_ar() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT_AR}/health/live" 2>/dev/null || echo 000; }

wait_ar() {
  for _ in $(seq 1 60); do
    [[ "$(health_ar)" == "200" ]] && return 0
    docker inspect -f '{{.State.Running}}' "${AR}" 2>/dev/null | grep -q true || {
      red "adapter-registry exited:"; docker logs "${AR}" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "adapter-registry never served /health/live:"; docker logs "${AR}" 2>&1 | tail -20; return 1
}

wait_dpr() {
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PORT_DPR}/v1/capabilities" 2>/dev/null && return 0
    docker inspect -f '{{.State.Running}}' "${DPR}" 2>/dev/null | grep -q true || {
      red "data-plane-router exited:"; docker logs "${DPR}" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "data-plane-router never became ready:"; docker logs "${DPR}" 2>&1 | tail -20; return 1
}

# ── 0) build scratch adapter-registry + data-plane-router FROM CURRENT source ──
step "0/8 build scratch adapter-registry + data-plane-router from CURRENT source (the S2 code)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -f "${CP_DIR}/Dockerfile" -t "${AR_IMG}" "${CP_DIR}" >/dev/null \
  || fail "scratch adapter-registry image build failed (line: docker build AR)"
DOCKER_BUILDKIT=1 docker build -q -f "${DPR_DIR}/Dockerfile" -t "${DPR_IMG}" "${DPR_DIR}" >/dev/null \
  || fail "scratch data-plane-router image build failed (line: docker build DPR)"
ok "both scratch images built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + dev Vault ────────────────────────────────────
step "1/8 boot isolated net (${NET}): postgres + dev Vault"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
docker run -d --name "${VAULT}" --network "${NET}" --cap-add IPC_LOCK \
  -e VAULT_DEV_ROOT_TOKEN_ID="${VAULT_TOKEN}" \
  -e VAULT_DEV_LISTEN_ADDRESS="0.0.0.0:8200" \
  "${VAULT_IMAGE}" >/dev/null
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "scratch postgres never reached steady state (line: PG ready loop)"
  sleep 0.5
done
for i in $(seq 1 60); do
  docker exec "${VAULT}" sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault status" >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && { docker logs "${VAULT}" 2>&1 | tail -15; fail "dev Vault never became ready (line: vault status loop)"; }
  sleep 0.5
done
ok "postgres + dev Vault up"

# ── 2) write the REAL DSN into Vault KV v2 at data-plane/dsn/<ref> field dsn ───
# The dev server mounts KV v2 at `secret/` by default; the VaultProvider reads
# {addr}/v1/secret/data/{prefix=data-plane/dsn}/{reference} field {dsn}. We store
# the in-network postgres DSN so a Vault-resolved query actually connects.
step "2/8 seed Vault KV v2: secret/data-plane/dsn/${VAULT_REF} {dsn=<postgres DSN>}"
# The `vault kv` CLI takes the MOUNT-prefixed path (`secret/<path>`); it maps that
# to the KV-v2 REST path `secret/data/<path>` that the VaultProvider reads. Omitting
# `secret/` makes the CLI try to resolve a mount literally named "data-plane" → 403.
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault kv put secret/data-plane/dsn/${VAULT_REF} dsn='${DB_INNET}'" \
  >/dev/null 2>&1 \
  || fail "failed to write the DSN secret into dev Vault (line: vault kv put)"
# Prove it reads back (the path the VaultProvider will hit: secret/data/data-plane/dsn/<ref>).
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault kv get -field=dsn secret/data-plane/dsn/${VAULT_REF}" \
  2>/dev/null | grep -q "postgres://" \
  || fail "Vault did not return the seeded DSN at secret/data-plane/dsn/${VAULT_REF} (line: vault kv get)"
ok "Vault holds the real DSN at the reference the credential_ref will name"

# ── 3) apply migration 004 (tenant_databases) + 006 (connection_salt) + 060 (cred-ref) ──
step "3/8 apply migration 004 (tenant_databases) + 006 (connection_salt) + 060 (cred-ref columns + XOR check)"
# NOTE: migrations 004 + 006 carry a 42-school '#'-banner header; '#' is NOT a psql
# comment (only '--' is), so applying them raw under ON_ERROR_STOP=1 dies with
# "syntax error at or near #". Strip leading '#' lines on apply. 060 starts with
# '--' (already valid) but is stripped identically for uniformity. 006 adds
# connection_salt, which 060's XOR CHECK references — it MUST precede 060.
apply_mig() { grep -v '^#' "${MIGRATIONS}/$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1; }
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
-- adapter-registry EnsureSchema's RLS policy calls auth.current_tenant_id();
-- seed a stub so EnsureSchema completes (test scaffolding, not part of S2).
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('app.current_user_id', true) $fn$;
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role;  END IF;
END $r$;
SQL
}
for i in $(seq 1 20); do prelude && break; [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"; sleep 0.5; done
apply_mig "004_add_adapter_registry.sql" \
  || fail "migration 004 failed to apply (line: apply 004)"
apply_mig "006_add_connection_salt.sql" \
  || fail "migration 006 failed to apply (line: apply 006)"
apply_mig "060_tenant_database_credref.sql" \
  || fail "migration 060 failed to apply (line: apply 060)"
# Prove 060 actually shaped the table (non-vacuous: the cred-ref columns + the
# XOR constraint must exist, else the whole S2 storage path is missing).
[[ "$(psql_val "SELECT count(*) FROM information_schema.columns WHERE table_name='tenant_databases' AND column_name IN ('cred_provider','cred_reference','cred_version')")" == "3" ]] \
  || fail "migration 060 did not add the cred_* columns (line: 060 columns check)"
[[ "$(psql_val "SELECT count(*) FROM pg_constraint WHERE conname='tenant_databases_credential_xor_check'")" == "1" ]] \
  || fail "migration 060 did not add the credential XOR check (line: 060 xor check)"
[[ "$(psql_val "SELECT is_nullable FROM information_schema.columns WHERE table_name='tenant_databases' AND column_name='connection_enc'")" == "YES" ]] \
  || fail "migration 060 did not make connection_enc nullable (line: 060 nullable check)"
[[ "$(psql_val "SELECT count(*) FROM information_schema.columns WHERE table_name='tenant_databases' AND column_name='connection_salt'")" == "1" ]] \
  || fail "migration 006 did not add connection_salt (line: 006 column check)"
ok "migration 004 + 006 + 060 applied — connection_salt present, cred_* columns + XOR check present, connection_enc nullable"

# ── 4) seed realistic tenants: a MAX tenant + a BASELINE tenant + probe table ──
step "4/8 seed tenants (max + baseline) keyed by slug; a probe table the resolved DSN can read"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
-- packageForTenant resolves plan via tenants.slug = <header value>. We use the
-- tenant UUID as the slug so the registration header resolves the plan.
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY, slug text UNIQUE NOT NULL, plan text);
INSERT INTO public.tenants(id, slug, plan) VALUES
  ('${UUID_MAX}'::uuid,  '${UUID_MAX}',  'max'),
  ('${UUID_BASE}'::uuid, '${UUID_BASE}', 'essential')
  ON CONFLICT (id) DO UPDATE SET plan = EXCLUDED.plan, slug = EXCLUDED.slug;
-- A bare (no-RLS) table the data plane lists once the DSN resolves from Vault.
CREATE TABLE IF NOT EXISTS public.${PROBE_TABLE} (id text PRIMARY KEY, label text);
INSERT INTO public.${PROBE_TABLE}(id, label) VALUES ('p1','ok') ON CONFLICT (id) DO NOTHING;
SQL
}
for i in $(seq 1 20); do seed && break; [[ $i -eq 20 ]] && fail "tenant seed never committed (line: seed loop)"; sleep 0.5; done
[[ "$(psql_val "SELECT plan FROM public.tenants WHERE slug='${UUID_MAX}'")" == "max" ]] \
  || fail "max tenant plan not seeded (line: verify max plan)"
[[ "$(psql_val "SELECT plan FROM public.tenants WHERE slug='${UUID_BASE}'")" == "essential" ]] \
  || fail "baseline tenant plan not seeded (line: verify baseline plan)"
ok "seeded max + baseline tenants + probe table"

# ── 5) boot adapter-registry (PACKAGE_ENFORCEMENT=1 → security_mode resolved) ──
step "5/8 boot adapter-registry (PACKAGE_ENFORCEMENT=1) on 127.0.0.1:${PORT_AR}"
docker run -d --name "${AR}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PACKAGE_ENFORCEMENT=1 \
  -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR}:3021" "${AR_IMG}" >/dev/null
wait_ar || fail "adapter-registry not ready (line: wait_ar)"
ok "adapter-registry serving /health/live=200 (tiering ON → security_mode enforced)"

# ── 6) ARM (1) NEGATIVE: max tenant + inline plaintext DSN → 403, ZERO rows ────
step "6/8 (1) NEGATIVE: max tenant registers an INLINE plaintext DSN → MUST be 403 + 0 rows"
NEG_CODE="$(post_register "${UUID_MAX}" \
  '{"engine":"postgresql","name":"neg-inline","connection_string":"postgres://attacker:plain@somewhere:5432/db","isolation":"shared_rls"}')"
[[ "${NEG_CODE}" == "403" ]] \
  || fail "(1) max + inline plaintext expected 403, got ${NEG_CODE} — $(head -c 300 "${BODY_TMP}") (line: NEG 403)"
grep -q 'plaintext_dsn_forbidden' "${BODY_TMP}" \
  || fail "(1) 403 body missing plaintext_dsn_forbidden — $(head -c 300 "${BODY_TMP}") (line: NEG body)"
[[ "$(psql_val "SELECT count(*) FROM public.tenant_databases WHERE tenant_id='${UUID_MAX}'")" == "0" ]] \
  || fail "(1) a row was inserted despite the 403 — the rejection must precede the insert (line: NEG zero rows)"
ok "(1) max tenant inline plaintext rejected 403 plaintext_dsn_forbidden; ZERO rows inserted"

# ── 7) ARM (2) POSITIVE: max tenant + credential_ref → 201; Vault-resolved query ─
step "7/8 (2) POSITIVE: max tenant registers a credential_ref → MUST be 201"
POS_CODE="$(post_register "${UUID_MAX}" \
  "{\"engine\":\"postgresql\",\"name\":\"pos-credref\",\"isolation\":\"shared_rls\",\"credential_ref\":{\"provider\":\"vault\",\"reference\":\"${VAULT_REF}\",\"version\":\"\"}}")"
[[ "${POS_CODE}" == "201" ]] \
  || fail "(2) max + credential_ref expected 201, got ${POS_CODE} — $(head -c 300 "${BODY_TMP}") (line: POS 201)"
MOUNT_ID="$(grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4)"
[[ -n "${MOUNT_ID}" ]] || fail "(2) register returned no mount id — $(head -c 300 "${BODY_TMP}") (line: POS mount id)"
# The row must be a cred-ref row: cred_provider set, connection_enc NULL.
[[ "$(psql_val "SELECT (cred_provider='vault' AND cred_reference='${VAULT_REF}' AND connection_enc IS NULL) FROM public.tenant_databases WHERE id='${MOUNT_ID}'")" == "t" ]] \
  || fail "(2) cred-ref row not stored as expected (cred_provider/reference set, connection_enc NULL) (line: POS row shape)"
ok "(2) max tenant credential_ref registered 201 — row stores provider+reference, NO ciphertext"

step "7b/8 boot data-plane-router WITH the VaultProvider configured (DATA_PLANE_VAULT_*)"
docker run -d --name "${DPR}" --network "${NET}" \
  -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
  -e DATA_PLANE_VAULT_ADDR="${VAULT_INNET}" \
  -e DATA_PLANE_VAULT_TOKEN="${VAULT_TOKEN}" \
  -e DATA_PLANE_VAULT_DSN_PREFIX="data-plane/dsn" \
  -e DATA_PLANE_VAULT_DSN_FIELD="dsn" \
  -e RUST_LOG=info \
  -p "127.0.0.1:${PORT_DPR}:4011" "${DPR_IMG}" >/dev/null
wait_dpr || fail "data-plane-router not ready (line: wait_dpr)"
ok "data-plane-router up with VaultProvider registered (vault addr+token set)"

step "7c/8 (2) query the cred-ref mount (NO inline_dsn) → DSN resolves FROM VAULT → 200"
Q_CODE=
for i in $(seq 1 20); do
  Q_CODE="$(post_q "$(payload_credref_list "${UUID_MAX}" "${MOUNT_ID}" "${VAULT_REF}")")"
  [[ "${Q_CODE}" == "200" ]] && break
  sleep 0.5
done
[[ "${Q_CODE}" == "200" ]] \
  || fail "(2) Vault-backed query expected 200, got ${Q_CODE} — $(head -c 400 "${BODY_TMP}") (line: POS query 200)"
grep -q '"p1"\|"ok"\|"rows"' "${BODY_TMP}" \
  || fail "(2) 200 body did not look like a served list result — $(head -c 400 "${BODY_TMP}") (line: POS query body)"
ok "(2) data plane resolved the DSN from Vault via the credential_ref and served the read (200)"

# ── 8) ARM (3) PARITY: baseline tenant + inline plaintext DSN → 201 (unchanged) ─
step "8/8 (3) PARITY: baseline tenant registers an INLINE plaintext DSN → MUST be 201 (today's behaviour)"
PAR_CODE="$(post_register "${UUID_BASE}" \
  "{\"engine\":\"postgresql\",\"name\":\"par-inline\",\"connection_string\":\"${DB_INNET}\",\"isolation\":\"shared_rls\"}")"
[[ "${PAR_CODE}" == "201" ]] \
  || fail "(3) baseline + inline plaintext expected 201 (byte-parity), got ${PAR_CODE} — $(head -c 300 "${BODY_TMP}") (line: PAR 201)"
PAR_ID="$(grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4)"
# A baseline inline row stores the encrypted DSN (connection_enc NOT NULL), cred_* NULL.
[[ "$(psql_val "SELECT (connection_enc IS NOT NULL AND cred_provider IS NULL) FROM public.tenant_databases WHERE id='${PAR_ID}'")" == "t" ]] \
  || fail "(3) baseline inline row not stored as encrypted-at-rest (connection_enc set, cred_* NULL) (line: PAR row shape)"
ok "(3) baseline tenant inline plaintext registered 201 + encrypted-at-rest — live baseline byte-parity"

green "[M121] (1) NEGATIVE max+inline → 403 plaintext_dsn_forbidden (0 rows)"
green "[M121] (2) POSITIVE max+credential_ref → 201; data plane resolved DSN FROM VAULT → 200"
green "[M121] (3) PARITY   baseline+inline → 201 (encrypted-at-rest, unchanged)"
green "[M121] ALL GATES GREEN — per-request Vault DSN resolution + max-tier plaintext refusal proven (non-vacuous: fails on pre-S2 HEAD)"

# ── log the gate event via the kernel helper (best-effort, JSONL) ─────────────
emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-s2-credref-vault}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m121=PASS" --outcome pass \
      --msg "S2 G-Vault: max tenant inline plaintext DSN -> 403 (0 rows); max tenant credential_ref{provider=vault} -> 201 and the data plane resolves the real DSN from Vault at query time -> 200; baseline inline -> 201 encrypted-at-rest (byte-parity). Per-request DSN resolution, distinct from m65's boot fail-closed." \
      --ref "scripts/verify/m121-credref-vault-enforce.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
exit 0
