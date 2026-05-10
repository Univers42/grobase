#!/usr/bin/env bash
# File: docker/services/vault/scripts/init-vault.sh
# One-shot bootstrap: initialize Vault, unseal, seed secrets, create AppRoles.
# Run by the vault-init container.
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
KEYS_FILE="/vault/data/.vault-keys.json"

echo "=== Vault Bootstrap ==="

# ── 1. Wait for Vault to be reachable ─────────────────────────────
echo "[*] Waiting for Vault at ${VAULT_ADDR}…"
while true; do
  if vault status -address="${VAULT_ADDR}" >/dev/null 2>&1; then
    break  # Vault is ready (unsealed)
  fi
  # vault status returns 2 when sealed but reachable — that's enough to proceed
  OUTPUT=$(vault status -address="${VAULT_ADDR}" 2>&1) || true
  if echo "${OUTPUT}" | grep -q 'Seal Type'; then
    echo "[*] Vault is reachable (not yet unsealed)"
    break
  fi
  sleep 1
done

# ── 2. Handle stale state: initialized but keys file lost ─────────
INIT_OUTPUT=$(vault status -address="${VAULT_ADDR}" 2>&1) || true
VAULT_INITIALIZED=$(echo "${INIT_OUTPUT}" | grep 'Initialized' | awk '{print $2}')

if [[ "${VAULT_INITIALIZED}" == "true" && ! -f "${KEYS_FILE}" ]]; then
  echo "[!] Vault is initialized but keys file is missing — resetting storage for fresh init…"
  # Wipe vault's file-backend data (preserving our keys dir structure)
  find /vault/data -mindepth 1 ! -name '.vault-keys.json' -exec rm -rf {} + 2>/dev/null || true
  echo "[!] Waiting for Vault to detect clean storage…"
  sleep 3
fi

# ── 3. Initialize if not already ──────────────────────────────────
INIT_OUTPUT2=$(vault status -address="${VAULT_ADDR}" 2>&1) || true
if echo "${INIT_OUTPUT2}" | grep -q 'Initialized.*false'; then
  echo "[*] Initializing Vault (1 key share, threshold 1)…"
  vault operator init \
    -address="${VAULT_ADDR}" \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json > "${KEYS_FILE}"
  chmod 600 "${KEYS_FILE}"
  echo "[+] Vault initialized — keys written to ${KEYS_FILE}"
else
  echo "[=] Vault already initialized"
fi

# The env helper runs as the host user so generated files are not root-owned.
# Keep this local-dev key file readable inside the Docker volume.
chmod 0644 "${KEYS_FILE}" 2>/dev/null || true

# ── 4. Unseal ─────────────────────────────────────────────────────
SEAL_OUTPUT=$(vault status -address="${VAULT_ADDR}" 2>&1) || true
if echo "${SEAL_OUTPUT}" | grep -q 'Sealed.*true'; then
  echo "[*] Unsealing Vault…"
  UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${KEYS_FILE}")
  vault operator unseal -address="${VAULT_ADDR}" "${UNSEAL_KEY}"
  echo "[+] Vault unsealed"
else
  echo "[=] Vault already unsealed"
fi

# ── 5. Authenticate as root ───────────────────────────────────────
ROOT_TOKEN=$(jq -r '.root_token' "${KEYS_FILE}")
export VAULT_TOKEN="${ROOT_TOKEN}"

# ── 6. Enable KV v2 secrets engine ───────────────────────────────
if ! vault secrets list -address="${VAULT_ADDR}" 2>/dev/null | grep -q '^secret/'; then
  echo "[*] Enabling KV v2 secrets engine…"
  vault secrets enable -address="${VAULT_ADDR}" -path=secret -version=2 kv
  echo "[+] KV v2 enabled at secret/"
else
  echo "[=] KV v2 already enabled"
fi

# ── 7. Write policies ────────────────────────────────────────────
echo "[*] Writing policies…"
vault policy write -address="${VAULT_ADDR}" mini-baas /vault/policies/mini-baas.hcl
vault policy write -address="${VAULT_ADDR}" admin /vault/policies/admin.hcl
echo "[+] Policies written"

# ── 8. Enable AppRole auth ───────────────────────────────────────
if ! vault auth list -address="${VAULT_ADDR}" 2>/dev/null | grep -q '^approle/'; then
  echo "[*] Enabling AppRole auth…"
  vault auth enable -address="${VAULT_ADDR}" approle
  echo "[+] AppRole enabled"
else
  echo "[=] AppRole already enabled"
fi

# ── 9. Seed secrets from environment ─────────────────────────────
echo "[*] Seeding secrets…"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/core \
  jwt_secret="${JWT_SECRET:-}" \
  vault_enc_key="${VAULT_ENC_KEY:-}" \
  adapter_registry_service_token="${ADAPTER_REGISTRY_SERVICE_TOKEN:-}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/postgres \
  user="${POSTGRES_USER:-postgres}" \
  password="${POSTGRES_PASSWORD:-postgres}" \
  database="${POSTGRES_DB:-postgres}" \
  url="postgres://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD:-postgres}@postgres:5432/${POSTGRES_DB:-postgres}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/mongo \
  username="${MONGO_INITDB_ROOT_USERNAME:-mongo}" \
  password="${MONGO_INITDB_ROOT_PASSWORD:-mongo}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/minio \
  access_key="${MINIO_ROOT_USER:-minioadmin}" \
  secret_key="${MINIO_ROOT_PASSWORD:-minioadmin}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/kong \
  public_api_key="${KONG_PUBLIC_API_KEY:-}" \
  service_api_key="${KONG_SERVICE_API_KEY:-}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/smtp \
  host="${SMTP_HOST:-mailpit}" \
  port="${SMTP_PORT:-1025}" \
  user="${SMTP_USER:-}" \
  pass="${SMTP_PASS:-}"

vault kv put -address="${VAULT_ADDR}" secret/mini-baas/oauth \
  google_client_id="${GOOGLE_CLIENT_ID:-}" \
  google_client_secret="${GOOGLE_CLIENT_SECRET:-}" \
  github_client_id="${GITHUB_CLIENT_ID:-}" \
  github_client_secret="${GITHUB_CLIENT_SECRET:-}" \
  fortytwo_client_id="${FORTYTWO_CLIENT_ID:-}" \
  fortytwo_client_secret="${FORTYTWO_CLIENT_SECRET:-}"

echo "[+] All secrets seeded"

# ── 10. Create per-service AppRoles ────────────────────────────────
echo "[*] Creating service AppRoles…"

SERVICES="kong gotrue postgrest mongo-api adapter-registry query-router email-service storage-router permission-engine schema-service postgres db-bootstrap project-db-init pg-meta supavisor osionos-bridge osionos-app auth-gateway opposite-osiris"

for svc in ${SERVICES}; do
  vault write -address="${VAULT_ADDR}" "auth/approle/role/${svc}" \
    token_policies="mini-baas" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    secret_id_ttl="0"

  ROLE_ID=$(vault read -address="${VAULT_ADDR}" -format=json "auth/approle/role/${svc}/role-id" | jq -r '.data.role_id')
  SECRET_ID=$(vault write -address="${VAULT_ADDR}" -format=json -f "auth/approle/role/${svc}/secret-id" | jq -r '.data.secret_id')

  vault kv put -address="${VAULT_ADDR}" "secret/mini-baas/approle/${svc}" \
    role_id="${ROLE_ID}" \
    secret_id="${SECRET_ID}"

  echo "  [+] ${svc}: role_id=${ROLE_ID:0:8}…"
done

echo "[+] All AppRoles created"
echo ""
echo "=== Vault Bootstrap Complete ==="
echo "Root token stored in: ${KEYS_FILE}"
echo "Unseal key stored in: ${KEYS_FILE}"
