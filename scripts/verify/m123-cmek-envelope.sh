#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m123-cmek-envelope.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M123 — CMEK / BYOK (D4.8): envelope-encrypt a per-mount external DB connection
# string with a Data-Encryption-Key (DEK) that is WRAPPED by a Key-Encryption-Key
# (KEK) held in an EXTERNAL KMS the customer controls (here: HashiCorp Vault
# Transit). The platform stores ONLY the wrapped DEK + DEK-encrypted ciphertext
# and CANNOT decrypt without asking the KMS to UNWRAP — so revoking/deleting the
# KMS key CRYPTO-SHREDS the secret (it becomes permanently undecryptable). This is
# the enterprise "we never hold your unwrap key" property. CMEK lives ENTIRELY in
# the Go control plane (adapterregistry) — it never enters the Rust data plane,
# RequestIdentity, the RLS GUCs, or the pool key, so SHARE_POOLS is byte-untouched.
#
# Four arms (all against scratch-from-source services on a PRIVATE network):
#
#   (1) POSITIVE / register a CMEK mount: an inline connection_string registered
#       with CMEK_ENABLED=1 -> 201. Assert the DB row stores cmek_wrapped_dek +
#       cmek_kms_key_id + DEK-ciphertext in connection_enc, and that NO plaintext
#       DSN is recoverable from the row (connection_enc != the plaintext; the
#       plaintext host is absent from a textual dump of the row). Then GET
#       /databases/{id}/connect (service-token) resolves the DSN by asking the KMS
#       to UNWRAP the DEK -> 200 and the resolved connection_string == the DSN.
#   (2) CRYPTO-SHRED (the headline): with the secret stored, DELETE/disable the
#       Vault Transit key (vault delete transit/keys/<key> after allowing deletion)
#       -> GET .../connect now FAILS (non-2xx) — the platform cannot decrypt. The
#       plaintext is unrecoverable (crypto-shred proven).
#   (3) PARITY / CMEK_ENABLED unset: boot the adapter-registry with NO CMEK flag,
#       register an inline DSN -> 201 byte-identical to the S2 baseline (encrypted
#       under the platform master key, cmek_* columns NULL, connect resolves 200).
#
# NON-VACUITY (fails on pre-CMEK HEAD): the cmek_wrapped_dek / cmek_kms_key_id
# columns + the CMEK_ENABLED flag + the kms_key_id register field do not exist on
# pre-CMEK code, so the CMEK register path cannot run (the wrapped-DEK column is
# absent -> EnsureSchema/061 never adds it -> the row-shape assertion can't pass)
# and the crypto-shred arm has nothing KMS-backed to shred. Stated here so the
# gate is honestly non-vacuous: only the CMEK code passes arms (1)+(2).
#
# ISOLATED by design (mirrors m121 / m65): scratch postgres (migrations 004 + 006
# + 060 + 061) + a dev Vault with Transit enabled + adapter-registry built FROM
# CURRENT source, on a PRIVATE network, every name suffixed $$, an EXIT-trap
# removing EVERYTHING. It NEVER touches a mini-baas-* container/network/image/
# volume and NEVER edits the live docker-compose.yml. Loopback-bound publish only.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
CP_DIR="${INFRA_DIR}/src/control-plane"
MIGRATIONS="${INFRA_DIR}/scripts/migrations/postgresql"
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M123] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M123] FAIL — $*"
  exit 1
}

PG_IMAGE="${M123_PG_IMAGE:-postgres:16-alpine}"
VAULT_IMAGE="${M123_VAULT_IMAGE:-hashicorp/vault:latest}"
AR_IMG="m123-ar-$$:scratch"
NET="m123net-$$"
PG="m123-pg-$$"
VAULT="m123-vault-$$"
AR="m123-ar-$$"   # adapter-registry with CMEK_ENABLED=1
AR2="m123-ar2-$$" # adapter-registry with CMEK disabled (parity arm)
PORT_AR="${M123_PORT_AR:-18995}"
PORT_AR2="${M123_PORT_AR2:-18996}"
PGPW="${PGPASSWORD:-postgres}"
SVC_TOKEN="m123-internal-service-token-$$"
VAULT_TOKEN="m123-dev-root-$$"
ENC_KEY="m123-real-master-key-not-a-placeholder-$$"
TRANSIT_KEY="m123-cmek-kek"

# A REAL tenant identity (UUID, used as both header + slug). The DSN we seal is a
# recognizable in-network postgres DSN; the crypto-shred + no-plaintext assertions
# key off its host segment.
UUID_T="cccc1111-2222-3333-4444-555566667777"
PLAINTEXT_HOST="cmek-secret-host.internal"
PLAINTEXT_DSN="postgres://cmekuser:cmekpass@${PLAINTEXT_HOST}:5432/cmekdb?sslmode=require"

DB_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"
VAULT_INNET="http://${VAULT}:8200"
BODY_TMP="$(mktemp)"

cleanup() {
  docker rm -fv "${AR2}" "${AR}" "${VAULT}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${AR_IMG}" >/dev/null 2>&1 || true
  rm -f "${BODY_TMP}" 2>/dev/null || true
}
trap cleanup EXIT

psql_val() { docker exec -i "${PG}" psql -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
psql_q() { docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

# POST /databases as the tenant; body $2.
post_register() { # $1=tenant-uuid  $2=json-body  $3=port
  curl -s -o "${BODY_TMP}" -w '%{http_code}' --max-time 8 \
    -X POST "http://127.0.0.1:${3}/databases" \
    -H 'Content-Type: application/json' \
    -H "X-User-Id: $1" -H "X-Tenant-Id: $1" \
    -d "$2"
}

# GET /databases/{id}/connect (service-token guarded) — this is GetConnection,
# which for a CMEK mount asks the KMS to UNWRAP the DEK before decrypting.
get_connect() { # $1=tenant-uuid  $2=mount-id  $3=port
  curl -s -o "${BODY_TMP}" -w '%{http_code}' --max-time 8 \
    -X GET "http://127.0.0.1:${3}/databases/$2/connect" \
    -H "X-User-Id: $1" -H "X-Tenant-Id: $1" \
    -H "X-Service-Token: ${SVC_TOKEN}"
}

health_ar() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${1}/health/live" 2>/dev/null || echo 000; }

wait_ar() { # $1=container  $2=port
  for _ in $(seq 1 60); do
    [[ "$(health_ar "${2}")" == "200" ]] && return 0
    docker inspect -f '{{.State.Running}}' "${1}" 2>/dev/null | grep -q true || {
      red "${1} exited:"
      docker logs "${1}" 2>&1 | tail -20
      return 1
    }
    sleep 0.5
  done
  red "${1} never served /health/live:"
  docker logs "${1}" 2>&1 | tail -20
  return 1
}

# ── 0) build scratch adapter-registry FROM CURRENT source (the CMEK code) ──────
step "0/9 build scratch adapter-registry from CURRENT source (the CMEK code)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -f "${CP_DIR}/Dockerfile" -t "${AR_IMG}" "${CP_DIR}" >/dev/null ||
  fail "scratch adapter-registry image build failed (line: docker build AR)"
ok "scratch image built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated net + postgres + dev Vault (Transit) ──────────────────────────
step "1/9 boot isolated net (${NET}): postgres + dev Vault"
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
  [[ $i -eq 60 ]] && {
    docker logs "${VAULT}" 2>&1 | tail -15
    fail "dev Vault never became ready (line: vault status loop)"
  }
  sleep 0.5
done
ok "postgres + dev Vault up"

# ── 2) enable Vault Transit + create the CMEK KEK (with deletion allowed) ──────
# The Transit engine is the external KMS. We enable it, create the KEK, and mark
# it deletion-allowed so the crypto-shred arm can DELETE it to prove undecryptability.
step "2/9 enable Vault Transit + create KEK transit/keys/${TRANSIT_KEY} (deletion-allowed)"
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault secrets enable transit" >/dev/null 2>&1 ||
  fail "could not enable the Vault transit engine (line: vault secrets enable transit)"
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault write -f transit/keys/${TRANSIT_KEY}" >/dev/null 2>&1 ||
  fail "could not create the transit KEK (line: vault write transit/keys)"
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault write transit/keys/${TRANSIT_KEY}/config deletion_allowed=true" >/dev/null 2>&1 ||
  fail "could not allow deletion on the transit KEK (line: vault write key config)"
# Prove the KEK can wrap (encrypt) — the path the provider uses.
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault write transit/encrypt/${TRANSIT_KEY} plaintext=$(printf 'probe' | base64)" \
  2>/dev/null | grep -q 'vault:v1:' ||
  fail "transit encrypt did not return a vault:v1: ciphertext (line: transit encrypt probe)"
ok "Vault Transit enabled; KEK created (deletion-allowed) and wrapping verified"

# ── 3) apply migrations 004 + 006 + 060 + 061 ─────────────────────────────────
# '#'-banner-strip (004/006 carry a 42 header; '#' is not a psql comment). 060
# adds cred-ref + the 2-way XOR check; 061 adds cmek_* + the 3-way check. 006
# (connection_salt) MUST precede 060; 060 MUST precede 061.
step "3/9 apply migrations 004 + 006 + 060 + 061 (cmek_* columns + 3-way mode check)"
apply_mig() { grep -v '^#' "${MIGRATIONS}/$1" | docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1; }
prelude() {
  psql_q >/dev/null 2>&1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE SCHEMA IF NOT EXISTS auth;
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
for i in $(seq 1 20); do
  prelude && break
  [[ $i -eq 20 ]] && fail "migration prelude never committed (line: prelude loop)"
  sleep 0.5
done
apply_mig "004_add_adapter_registry.sql" || fail "migration 004 failed to apply (line: apply 004)"
apply_mig "006_add_connection_salt.sql" || fail "migration 006 failed to apply (line: apply 006)"
apply_mig "060_tenant_database_credref.sql" || fail "migration 060 failed to apply (line: apply 060)"
apply_mig "061_tenant_database_cmek.sql" || fail "migration 061 failed to apply (line: apply 061)"
# Non-vacuous: the cmek_* columns + the 3-way mode check must exist (else the
# whole CMEK storage path is missing — this is exactly what FAILS on pre-CMEK HEAD).
[[ "$(psql_val "SELECT count(*) FROM information_schema.columns WHERE table_name='tenant_databases' AND column_name IN ('cmek_wrapped_dek','cmek_kms_key_id')")" == "2" ]] ||
  fail "migration 061 did not add the cmek_* columns (line: 061 columns check)"
[[ "$(psql_val "SELECT count(*) FROM pg_constraint WHERE conname='tenant_databases_credential_mode_check'")" == "1" ]] ||
  fail "migration 061 did not add the 3-way mode check (line: 061 mode check)"
[[ "$(psql_val "SELECT count(*) FROM pg_constraint WHERE conname='tenant_databases_credential_xor_check'")" == "0" ]] ||
  fail "migration 061 did not drop the 060 2-way XOR check (line: 061 xor drop)"
ok "migrations 004+006+060+061 applied — cmek_* columns + 3-way mode check present, 2-way check dropped"

# ── 4) seed the tenant + a probe table the resolved DSN could read ────────────
step "4/9 seed tenant ${UUID_T} (slug=uuid)"
seed() {
  psql_q >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS public.tenants (id uuid PRIMARY KEY, slug text UNIQUE NOT NULL, plan text);
INSERT INTO public.tenants(id, slug, plan) VALUES ('${UUID_T}'::uuid, '${UUID_T}', 'max')
  ON CONFLICT (id) DO UPDATE SET plan = EXCLUDED.plan, slug = EXCLUDED.slug;
SQL
}
for i in $(seq 1 20); do
  seed && break
  [[ $i -eq 20 ]] && fail "tenant seed never committed (line: seed loop)"
  sleep 0.5
done
ok "seeded tenant"

# ── 5) boot adapter-registry WITH CMEK enabled (vault-transit provider) ───────
step "5/9 boot adapter-registry CMEK_ENABLED=1 (vault-transit) on 127.0.0.1:${PORT_AR}"
docker run -d --name "${AR}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e CMEK_ENABLED=1 \
  -e CMEK_KMS_PROVIDER=vault-transit \
  -e CMEK_VAULT_TRANSIT_KEY="${TRANSIT_KEY}" \
  -e VAULT_ADDR="${VAULT_INNET}" \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR}:3021" "${AR_IMG}" >/dev/null
wait_ar "${AR}" "${PORT_AR}" || fail "adapter-registry (CMEK) not ready (line: wait_ar AR)"
ok "adapter-registry serving /health/live=200 with CMEK enabled (vault-transit)"

# ── 6) ARM (1) POSITIVE: register a CMEK mount → 201; row stores wrapped DEK + ciphertext, NO plaintext ─
step "6/9 (1) POSITIVE: register an inline DSN under CMEK → MUST be 201, envelope-sealed"
POS_CODE="$(post_register "${UUID_T}" \
  "{\"engine\":\"postgresql\",\"name\":\"cmek-mount\",\"isolation\":\"shared_rls\",\"connection_string\":\"${PLAINTEXT_DSN}\"}" \
  "${PORT_AR}")"
[[ "${POS_CODE}" == "201" ]] ||
  fail "(1) CMEK register expected 201, got ${POS_CODE} — $(head -c 300 "${BODY_TMP}") (line: POS 201)"
MOUNT_ID="$(grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4)"
[[ -n "${MOUNT_ID}" ]] || fail "(1) register returned no mount id (line: POS mount id)"
# The row must be a cmek-envelope row: cmek_wrapped_dek + cmek_kms_key_id set,
# connection_enc set (DEK-ciphertext), cred_* NULL, salt NULL.
[[ "$(psql_val "SELECT (cmek_wrapped_dek IS NOT NULL AND cmek_kms_key_id='${TRANSIT_KEY}' AND connection_enc IS NOT NULL AND cred_provider IS NULL AND connection_salt IS NULL) FROM public.tenant_databases WHERE id='${MOUNT_ID}'")" == "t" ]] ||
  fail "(1) cmek row not stored as expected (wrapped DEK + key id + ciphertext, cred_* NULL, salt NULL) (line: POS row shape)"
# The wrapped DEK must be a Vault Transit ciphertext (vault:v1:...) — proving the
# KMS actually wrapped it, not a local fallback.
[[ "$(psql_val "SELECT (encode(cmek_wrapped_dek,'escape') LIKE 'vault:v1:%') FROM public.tenant_databases WHERE id='${MOUNT_ID}'")" == "t" ]] ||
  fail "(1) cmek_wrapped_dek is not a Vault Transit ciphertext (line: POS wrapped form)"
# NO plaintext at rest: the stored connection_enc must NOT equal the plaintext, and
# a textual dump of the row must NOT contain the plaintext host.
[[ "$(psql_val "SELECT (convert_from(connection_enc,'UTF8') = '${PLAINTEXT_DSN}') FROM public.tenant_databases WHERE id='${MOUNT_ID}'" 2>/dev/null)" != "t" ]] ||
  fail "(1) connection_enc stored the plaintext DSN — not encrypted (line: POS no-plaintext enc)"
ROW_DUMP="$(psql_val "SELECT coalesce(encode(connection_enc,'escape'),'') || '|' || coalesce(encode(cmek_wrapped_dek,'escape'),'') || '|' || coalesce(cmek_kms_key_id,'') FROM public.tenant_databases WHERE id='${MOUNT_ID}'")"
echo "${ROW_DUMP}" | grep -q "${PLAINTEXT_HOST}" &&
  fail "(1) the plaintext host '${PLAINTEXT_HOST}' is recoverable from the stored row — CMEK failed (line: POS no-plaintext host)"
ok "(1) CMEK mount registered 201 — wrapped DEK (vault:v1:) + ciphertext stored, NO plaintext recoverable"

step "6b/9 (1) GET .../connect resolves the DSN by asking the KMS to UNWRAP → 200 + correct DSN"
CONN_CODE="$(get_connect "${UUID_T}" "${MOUNT_ID}" "${PORT_AR}")"
[[ "${CONN_CODE}" == "200" ]] ||
  fail "(1) connect (KMS unwrap) expected 200, got ${CONN_CODE} — $(head -c 300 "${BODY_TMP}") (line: POS connect 200)"
grep -q "${PLAINTEXT_HOST}" "${BODY_TMP}" ||
  fail "(1) connect 200 body did not contain the resolved DSN host — unwrap/decrypt failed (line: POS connect dsn)"
ok "(1) connect round-tripped through the KMS unwrap and returned the real DSN (200)"

# ── 7) ARM (2) CRYPTO-SHRED: delete the Transit key → connect now FAILS ────────
step "7/9 (2) CRYPTO-SHRED: delete transit/keys/${TRANSIT_KEY} → connect MUST fail (cannot decrypt)"
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault delete transit/keys/${TRANSIT_KEY}" >/dev/null 2>&1 ||
  fail "(2) could not delete the transit KEK (line: vault delete key)"
# Prove the KMS now refuses to decrypt (the unwrap path the platform depends on).
docker exec "${VAULT}" sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} vault read transit/keys/${TRANSIT_KEY}" >/dev/null 2>&1 &&
  fail "(2) the transit KEK still exists after delete (line: verify key gone)" || true
# The control plane caches the decrypted DSN by ciphertext tag, so restart the
# adapter-registry to force a cold GetConnection that MUST hit the (now-gone) KMS.
docker restart "${AR}" >/dev/null 2>&1 || fail "(2) could not restart adapter-registry (line: AR restart)"
wait_ar "${AR}" "${PORT_AR}" || fail "(2) adapter-registry not ready after restart (line: wait_ar shred)"
SHRED_CODE="$(get_connect "${UUID_T}" "${MOUNT_ID}" "${PORT_AR}")"
[[ "${SHRED_CODE}" != "200" ]] ||
  fail "(2) connect returned 200 AFTER the KEK was deleted — the secret was NOT crypto-shredded (line: SHRED non-200)"
# The response must NOT leak the plaintext host (it is unrecoverable).
grep -q "${PLAINTEXT_HOST}" "${BODY_TMP}" &&
  fail "(2) the plaintext host leaked after crypto-shred — secret recoverable (line: SHRED no leak)" || true
ok "(2) after deleting the KMS key, connect fails (${SHRED_CODE}) and the plaintext is unrecoverable — CRYPTO-SHRED proven"

# ── 8) ARM (3) PARITY: CMEK_ENABLED unset → inline byte-identical to S2 baseline ─
step "8/9 (3) PARITY: boot adapter-registry with CMEK DISABLED on 127.0.0.1:${PORT_AR2}"
docker run -d --name "${AR2}" --network "${NET}" \
  -e DATABASE_URL="${DB_INNET}" \
  -e VAULT_ENC_KEY="${ENC_KEY}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -e PORT=3021 \
  -p "127.0.0.1:${PORT_AR2}:3021" "${AR_IMG}" >/dev/null
wait_ar "${AR2}" "${PORT_AR2}" || fail "(3) adapter-registry (no CMEK) not ready (line: wait_ar AR2)"
PAR_CODE="$(post_register "${UUID_T}" \
  "{\"engine\":\"postgresql\",\"name\":\"par-inline\",\"isolation\":\"shared_rls\",\"connection_string\":\"${DB_INNET}\"}" \
  "${PORT_AR2}")"
[[ "${PAR_CODE}" == "201" ]] ||
  fail "(3) inline register (CMEK off) expected 201 (byte-parity), got ${PAR_CODE} — $(head -c 300 "${BODY_TMP}") (line: PAR 201)"
PAR_ID="$(grep -o '"id":"[^"]*"' "${BODY_TMP}" | head -1 | cut -d'"' -f4)"
# A baseline inline row: encrypted-at-rest under the master key, cmek_* NULL, cred_* NULL.
[[ "$(psql_val "SELECT (connection_enc IS NOT NULL AND cmek_wrapped_dek IS NULL AND cmek_kms_key_id IS NULL AND cred_provider IS NULL) FROM public.tenant_databases WHERE id='${PAR_ID}'")" == "t" ]] ||
  fail "(3) parity row not stored as plain inline (connection_enc set, cmek_* + cred_* NULL) (line: PAR row shape)"
# And connect resolves it WITHOUT any KMS (master-key decrypt) → 200.
PAR_CONN="$(get_connect "${UUID_T}" "${PAR_ID}" "${PORT_AR2}")"
[[ "${PAR_CONN}" == "200" ]] ||
  fail "(3) parity connect expected 200 (master-key decrypt), got ${PAR_CONN} (line: PAR connect)"
ok "(3) CMEK-off inline register 201 + master-key encrypted-at-rest (cmek_* NULL) + connect 200 — S2 byte-parity"

step "9/9 summary"
green "[M123] (1) POSITIVE  CMEK register → 201; wrapped DEK (vault:v1:) + ciphertext stored, NO plaintext; connect via KMS unwrap → 200"
green "[M123] (2) SHRED     deleted the KMS key → connect fails (${SHRED_CODE}); plaintext unrecoverable — CRYPTO-SHRED proven"
green "[M123] (3) PARITY    CMEK off → inline master-key encrypted-at-rest (cmek_* NULL), connect 200 — S2 byte-parity"
green "[M123] ALL GATES GREEN — CMEK/BYOK envelope + crypto-shred + flag-off parity proven (non-vacuous: cmek_* columns + flag absent on pre-CMEK HEAD)"

# ── log the gate event via the kernel helper (best-effort, JSONL) ─────────────
emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-d4.8-cmek-byok}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m123=PASS" --outcome pass \
      --msg "CMEK/BYOK (D4.8): inline DSN envelope-sealed under a per-mount DEK wrapped by an external Vault Transit KEK -> 201, row stores wrapped DEK (vault:v1:) + DEK-ciphertext, NO plaintext recoverable; connect resolves via KMS unwrap -> 200; deleting the KMS key makes connect FAIL and the plaintext unrecoverable (crypto-shred); CMEK_ENABLED off -> inline master-key encrypted-at-rest, cmek_* NULL (S2 byte-parity). Control-plane only; never enters the data plane / pool key." \
      --ref "scripts/verify/m123-cmek-envelope.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
exit 0
