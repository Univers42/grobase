#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    fly-entrypoint.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
set -euo pipefail

export VAULT_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
VAULT_CONFIG_FILE="${VAULT_CONFIG_FILE:-/vault/config/vault.hcl}"
VAULT_KEYS_FILE="${VAULT_KEYS_FILE:-/vault/data/.vault-keys.json}"

mkdir -p /vault/data
chown -R vault:vault /vault/data

vault server -config="${VAULT_CONFIG_FILE}" &
vault_pid=$!

shutdown() {
  kill -TERM "${vault_pid}" 2>/dev/null || true
  wait "${vault_pid}" 2>/dev/null || true
}
trap shutdown INT TERM

wait_for_api() {
  local status
  for _ in $(seq 1 120); do
    if ! kill -0 "${vault_pid}" 2>/dev/null; then
      wait "${vault_pid}"
      exit $?
    fi
    status="$(curl -sS -o /tmp/vault-health.json -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health" || true)"
    if [[ "${status}" != "000" ]]; then
      return 0
    fi
    sleep 1
  done
  echo '[vault-fly] Vault API did not become reachable' >&2
  exit 1
}

vault_initialized() {
  jq -e '.initialized == true' /tmp/vault-health.json >/dev/null 2>&1
}

vault_sealed() {
  (vault status -format=json 2>/dev/null || true) | jq -e '.sealed == true' >/dev/null 2>&1
}

vault_api_post() {
  local path="$1"
  curl -sS \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --header 'Content-Type: application/json' \
    --request POST \
    --data @- \
    "${VAULT_ADDR}/v1/${path}" >/dev/null
}

ensure_auth_mount() {
  local path="$1"
  local type="$2"
  if ! vault auth list -format=json | jq -e --arg path "${path}/" '.[$path]' >/dev/null; then
    vault auth enable -path="${path}" "${type}" >/dev/null
    echo "[vault-fly] enabled ${path} auth"
  fi
}

wait_for_api

if ! vault_initialized; then
  echo '[vault-fly] initializing Vault'
  vault operator init -key-shares=1 -key-threshold=1 -format=json >"${VAULT_KEYS_FILE}.tmp"
  chmod 600 "${VAULT_KEYS_FILE}.tmp"
  chown vault:vault "${VAULT_KEYS_FILE}.tmp"
  mv "${VAULT_KEYS_FILE}.tmp" "${VAULT_KEYS_FILE}"
fi

if vault_sealed; then
  if [[ ! -s "${VAULT_KEYS_FILE}" ]]; then
    echo "[vault-fly] Vault is sealed and ${VAULT_KEYS_FILE} is missing" >&2
    exit 1
  fi
  echo '[vault-fly] unsealing Vault'
  vault operator unseal "$(jq -r '.unseal_keys_b64[0]' "${VAULT_KEYS_FILE}")" >/dev/null
fi

VAULT_TOKEN="$(jq -r '.root_token' "${VAULT_KEYS_FILE}")"
export VAULT_TOKEN

if ! vault secrets list -format=json | jq -e '."secret/".options.version == "2"' >/dev/null; then
  vault secrets enable -path=secret -version=2 kv >/dev/null 2>&1 || true
fi

for policy_file in /vault/policies/*.hcl; do
  [[ -f "${policy_file}" ]] || continue
  policy_name="$(basename "${policy_file}" .hcl)"
  vault policy write "${policy_name}" "${policy_file}" >/dev/null
  echo "[vault-fly] policy ${policy_name} synced"
done

jwt_path="${VAULT_GITHUB_OIDC_AUTH_PATH:-jwt}"
jwt_role="${VAULT_GITHUB_OIDC_ROLE:-track-binocle-github-actions}"
jwt_repository="${VAULT_GITHUB_OIDC_REPOSITORY:-Univers42/track-binocle}"
jwt_audience="${VAULT_GITHUB_OIDC_AUDIENCE:-vault://track-binocle}"

github_path="${VAULT_GITHUB_AUTH_PATH:-github}"
github_org="${VAULT_GITHUB_ORG:-Univers42}"
github_team="${VAULT_GITHUB_TEAM:-transcendance}"

ensure_auth_mount "${jwt_path}" jwt
jq -n '{ oidc_discovery_url: "https://token.actions.githubusercontent.com", bound_issuer: "https://token.actions.githubusercontent.com" }' |
  vault_api_post "auth/${jwt_path}/config"

jq -n \
  --arg audience "${jwt_audience}" \
  --arg repository "${jwt_repository}" \
  '{ role_type: "jwt", user_claim: "actor", bound_audiences: [$audience], bound_claims: { repository: $repository }, token_policies: ["track-binocle-env-reader"], token_ttl: "1h", token_max_ttl: "1h" }' |
  vault_api_post "auth/${jwt_path}/role/${jwt_role}"
echo "[vault-fly] GitHub Actions role ${jwt_role} synced"

ensure_auth_mount "${github_path}" github
jq -n --arg organization "${github_org}" '{ organization: $organization }' |
  vault_api_post "auth/${github_path}/config"
jq -n '{ value: "track-binocle-env-reader" }' |
  vault_api_post "auth/${github_path}/map/teams/${github_team}"
echo "[vault-fly] GitHub team ${github_org}/${github_team} mapped to track-binocle-env-reader"

wait "${vault_pid}"
