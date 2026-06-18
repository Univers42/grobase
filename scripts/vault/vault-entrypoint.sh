# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    vault-entrypoint.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/vault-entrypoint.sh
# Generic entrypoint wrapper: fetches secrets from Vault using AppRole
# credentials, exports them as environment variables, then exec's the CMD.
#
# Required env vars:
#   VAULT_ADDR      — e.g. http://vault:8200
#   VAULT_ROLE_ID   — AppRole role ID
#   VAULT_SECRET_ID — AppRole secret ID
#   VAULT_PATHS     — space-separated list of KV paths to read
#                      e.g. "secret/mini-baas/core secret/mini-baas/postgres"
#
# If VAULT_ADDR is unset, this script is a no-op pass-through (local dev).
set -euo pipefail

# ── Fallback: no Vault → just exec the command ────────────────────
if [[ -z "${VAULT_ADDR:-}" ]]; then
  exec "$@"
fi

echo "[vault-entrypoint] Authenticating with Vault at ${VAULT_ADDR}…"

# ── Authenticate via AppRole ──────────────────────────────────────
TOKEN_RESPONSE=$(curl -sf \
  --retry 5 --retry-delay 2 --retry-connrefused \
  "${VAULT_ADDR}/v1/auth/approle/login" \
  -d "{\"role_id\":\"${VAULT_ROLE_ID}\",\"secret_id\":\"${VAULT_SECRET_ID}\"}")

VAULT_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.auth.client_token')

if [[ -z "${VAULT_TOKEN}" || "${VAULT_TOKEN}" == "null" ]]; then
  echo "[vault-entrypoint] ERROR: Failed to authenticate with Vault" >&2
  echo "[vault-entrypoint] Falling back to env vars" >&2
  exec "$@"
fi

# ── Read each secret path and export key=value pairs ──────────────
for path in ${VAULT_PATHS:-}; do
  echo "[vault-entrypoint] Reading ${path}…"
  RESPONSE=$(curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/${path}" 2>/dev/null || echo '{}')

  # KV v2 nests data under .data.data
  KEYS=$(echo "${RESPONSE}" | jq -r '.data.data // empty | keys[]' 2>/dev/null || true)

  for key in ${KEYS}; do
    value=$(echo "${RESPONSE}" | jq -r ".data.data[\"${key}\"]")
    ENV_KEY=$(echo "${key}" | tr '[:lower:]' '[:upper:]')
    export "${ENV_KEY}=${value}"
  done
done

echo "[vault-entrypoint] Secrets loaded, starting application…"
exec "$@"
