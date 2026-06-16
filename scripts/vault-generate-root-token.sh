# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    vault-generate-root-token.sh                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR="${VAULT_LOCAL_ADDR:-${VAULT_ADDR:-http://127.0.0.1:8200}}"
VAULT_KEYS_FILE="${VAULT_KEYS_FILE:-/vault/data/.vault-keys.json}"

fail() {
  printf '[vault-admin] %s\n' "$*" >&2
  exit 1
}

command -v vault >/dev/null 2>&1 || fail 'vault CLI is required inside the Vault host'
command -v jq >/dev/null 2>&1 || fail 'jq is required inside the Vault host'

if [[ ! -s "$VAULT_KEYS_FILE" ]]; then
  fail "missing $VAULT_KEYS_FILE; cannot regenerate an admin token without the unseal/recovery key"
fi

old_root_token="$(jq -r '.root_token // empty' "$VAULT_KEYS_FILE")"
unseal_key="$(jq -r '.unseal_keys_b64[0] // empty' "$VAULT_KEYS_FILE")"
if [[ -z "$unseal_key" || "$unseal_key" == 'null' ]]; then
  fail "$VAULT_KEYS_FILE does not contain an unseal key"
fi

status_json=''
for _ in $(seq 1 60); do
  if status_json="$(vault status -format=json 2>/dev/null)" && [[ -n "$status_json" ]]; then
    break
  fi
  if [[ -n "$status_json" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$status_json" ]]; then
  fail "Vault API at $VAULT_ADDR did not become reachable"
fi

if printf '%s' "$status_json" | jq -e '.sealed == true' >/dev/null; then
  printf '[vault-admin] unsealing Vault before root generation\n' >&2
  vault operator unseal "$unseal_key" >/dev/null
fi

vault operator generate-root -cancel >/dev/null 2>&1 || true

init_json="$(vault operator generate-root -init -format=json)"
nonce="$(printf '%s' "$init_json" | jq -r '.nonce // empty')"
otp="$(printf '%s' "$init_json" | jq -r '.otp // empty')"

if [[ -z "$nonce" || -z "$otp" ]]; then
  fail 'Vault did not return a root-generation nonce and OTP'
fi

update_json="$(vault operator generate-root -nonce="$nonce" -format=json "$unseal_key")"
complete="$(printf '%s' "$update_json" | jq -r '.complete // false')"
encoded_token="$(printf '%s' "$update_json" | jq -r '.encoded_token // .encoded_root_token // empty')"

if [[ "$complete" != 'true' || -z "$encoded_token" ]]; then
  fail 'Vault root generation did not complete; check the unseal/recovery key threshold'
fi

decode_output="$(vault operator generate-root -decode="$encoded_token" -otp="$otp")"
root_token="$(printf '%s\n' "$decode_output" | awk '/^(hvs|hvb|s)\./ { print; exit } /Root Token/ { print $NF; exit }')"
if [[ -z "$root_token" ]]; then
  root_token="$(printf '%s' "$decode_output" | tr -d '\r\n')"
fi

if [[ -z "$root_token" ]]; then
  fail 'Vault root token decode returned an empty token'
fi

VAULT_TOKEN="$root_token" vault token lookup -format=json >/dev/null

keys_tmp="${VAULT_KEYS_FILE}.tmp"
jq --arg root_token "$root_token" '.root_token = $root_token' "$VAULT_KEYS_FILE" > "$keys_tmp"
chmod 600 "$keys_tmp"
chown vault:vault "$keys_tmp" 2>/dev/null || true
mv "$keys_tmp" "$VAULT_KEYS_FILE"

if [[ -n "$old_root_token" && "$old_root_token" != "$root_token" ]]; then
  VAULT_TOKEN="$old_root_token" vault token revoke -self >/dev/null 2>&1 || true
fi

jq -n \
  --arg root_token "$root_token" \
  --arg vault_addr "$VAULT_ADDR" \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{ root_token: $root_token, vault_addr: $vault_addr, generated_at: $generated_at }'