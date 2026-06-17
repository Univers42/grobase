# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    vault-admin-cred-lost.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
cd "$REPO_ROOT"

fail() {
  printf '[vault-admin] %s\n' "$*" >&2
  exit 1
}

env_value() {
  local key="$1"
  local file line value
  for file in .env.local .env apps/baas/.env.local apps/baas/mini-baas-infra/.env; do
    [[ -f "$file" ]] || continue
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)"
    [[ -n "$line" ]] || continue
    value="${line#*=}"
    value="${value%$'\r'}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf '%s\n' "$value"
    return 0
  done
  return 1
}

json_value() {
  local json="$1"
  local key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg key "$key" '.[$key] // empty'
  else
    node -e 'const fs = require("node:fs"); const key = process.argv[1]; const data = JSON.parse(fs.readFileSync(0, "utf8")); process.stdout.write(data[key] || "");' "$key" <<<"$json"
  fi
}

prompt_if_missing() {
  local var_name="$1"
  local prompt="$2"
  local secret="${3:-false}"
  local value="${!var_name:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fail "missing $var_name; run from a terminal or export it before make admin-cred-lost"
  fi
  printf '%s' "$prompt" >&2
  if [[ "$secret" == 'true' ]]; then
    read -r -s value
    printf '\n' >&2
  else
    read -r value
  fi
  printf '%s' "$value"
}

write_env_line() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$value"
}

VAULT_APP="${FLY_VAULT_APP:-track-binocle-vault}"
VAULT_URL="${FLY_VAULT_URL:-https://${VAULT_APP}.fly.dev}"
VAULT_PREFIX="${VAULT_ENV_PREFIX:-secret/data/track-binocle/env}"
ADMIN_FILE="${VAULT_ADMIN_TOKEN_FILE:-.vault/track-binocle-admin.env}"
RECEIPT_FILE="${ADMIN_CRED_LOST_RECEIPT_FILE:-.vault/admin-cred-lost-receipt.env}"
REMOTE_SCRIPT="${ADMIN_CRED_LOST_REMOTE_SCRIPT:-apps/baas/scripts/vault-generate-root-token.sh}"

RECOVERY_EMAIL="${EMAIL_RECUP_ADMIN_VAULT:-$(env_value EMAIL_RECUP_ADMIN_VAULT || true)}"
if [[ -z "$RECOVERY_EMAIL" || "$RECOVERY_EMAIL" != *@* ]]; then
  fail 'EMAIL_RECUP_ADMIN_VAULT must be set in .env.local, .env, or the shell before recovery'
fi

if [[ -z "${FLY_API_TOKEN:-}" ]]; then
  FLY_API_TOKEN="$(env_value FLY_API_TOKEN || true)"
  if [[ -n "$FLY_API_TOKEN" ]]; then
    export FLY_API_TOKEN
  fi
fi

EXPECTED_PHRASE="recover-admin-vault:${VAULT_APP}:${RECOVERY_EMAIL}"

printf '[vault-admin] recovery mailbox: %s\n' "$RECOVERY_EMAIL"
printf '[vault-admin] confirmation phrase: %s\n' "$EXPECTED_PHRASE"
printf '[vault-admin] this regenerates a Vault root/admin token using Fly operator access and the stored unseal key; old secrets are not printed.\n'

CONFIRM_EMAIL="$(prompt_if_missing ADMIN_CRED_LOST_CONFIRM_EMAIL 'Type EMAIL_RECUP_ADMIN_VAULT to continue: ')"
if [[ "$CONFIRM_EMAIL" != "$RECOVERY_EMAIL" ]]; then
  fail 'recovery email confirmation did not match EMAIL_RECUP_ADMIN_VAULT'
fi

CONFIRM_PHRASE="$(prompt_if_missing ADMIN_CRED_LOST_CONFIRM 'Type the confirmation phrase shown above: ')"
if [[ "$CONFIRM_PHRASE" != "$EXPECTED_PHRASE" ]]; then
  fail 'confirmation phrase did not match'
fi

PASSPHRASE="$(prompt_if_missing ADMIN_CRED_LOST_PASSPHRASE 'Type a local recovery passphrase for this operation: ' true)"
if [[ "${#PASSPHRASE}" -lt 12 ]]; then
  fail 'ADMIN_CRED_LOST_PASSPHRASE must be at least 12 characters'
fi
unset PASSPHRASE

if [[ -n "${FLY_BIN:-}" ]]; then
  FLY_CMD=("$FLY_BIN")
elif command -v flyctl >/dev/null 2>&1; then
  FLY_CMD=(flyctl)
elif command -v fly >/dev/null 2>&1; then
  FLY_CMD=(fly)
elif [[ -n "${FLY_API_TOKEN:-}" ]]; then
  FLY_CMD=(docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly)
else
  fail 'flyctl/fly is not installed and FLY_API_TOKEN is not set; cannot prove Fly owner/operator access'
fi

if [[ ! -f "$REMOTE_SCRIPT" ]]; then
  fail "missing remote helper $REMOTE_SCRIPT"
fi

mkdir -p .vault
chmod 700 .vault 2>/dev/null || true
TMP_JSON="$(mktemp .vault/admin-root-token.XXXXXX.json)"
trap 'rm -f "$TMP_JSON"' EXIT
chmod 600 "$TMP_JSON"

if ! "${FLY_CMD[@]}" auth whoami >/dev/null 2>&1; then
  fail 'Fly authentication failed; log in with flyctl or export a valid FLY_API_TOKEN'
fi

printf '[vault-admin] requesting a fresh Vault admin token from %s\n' "$VAULT_APP"
if ! "${FLY_CMD[@]}" ssh console --app "$VAULT_APP" --command 'bash -se' < "$REMOTE_SCRIPT" > "$TMP_JSON"; then
  fail 'remote Vault admin token regeneration failed; if the unseal key is gone too, use make vault-fly-reset as the destructive reseed path'
fi

JSON_LINE="$(grep -E '^\{' "$TMP_JSON" | tail -n 1 || true)"
if [[ -z "$JSON_LINE" ]]; then
  fail 'remote helper did not return a JSON credential payload'
fi

ROOT_TOKEN="$(json_value "$JSON_LINE" root_token)"
GENERATED_AT="$(json_value "$JSON_LINE" generated_at)"
if [[ -z "$ROOT_TOKEN" || -z "$GENERATED_AT" ]]; then
  fail 'remote helper returned an incomplete credential payload'
fi

umask 077
{
  printf '# Track Binocle Vault admin credential regenerated after lost admin API key.\n'
  printf '# Keep this file private. It is ignored by Git.\n'
  write_env_line VAULT_ADDR "$VAULT_URL"
  write_env_line VAULT_TOKEN "$ROOT_TOKEN"
  write_env_line VAULT_API_KEY "$ROOT_TOKEN"
  write_env_line VAULT_ENV_PREFIX "$VAULT_PREFIX"
  write_env_line VAULT_ADMIN_EMAIL "$RECOVERY_EMAIL"
  write_env_line VAULT_ADMIN_GENERATED_AT "$GENERATED_AT"
} > "$ADMIN_FILE"
chmod 600 "$ADMIN_FILE"

{
  printf '# Track Binocle Vault admin recovery receipt. No Vault token is stored here.\n'
  write_env_line ADMIN_CRED_LOST_EMAIL "$RECOVERY_EMAIL"
  write_env_line ADMIN_CRED_LOST_VAULT_APP "$VAULT_APP"
  write_env_line ADMIN_CRED_LOST_VAULT_ADDR "$VAULT_URL"
  write_env_line ADMIN_CRED_LOST_ENV_PREFIX "$VAULT_PREFIX"
  write_env_line ADMIN_CRED_LOST_CREATED_AT "$GENERATED_AT"
  write_env_line ADMIN_CRED_LOST_ADMIN_FILE "$ADMIN_FILE"
  write_env_line ADMIN_CRED_LOST_READER_FILE "${VAULT_READER_TOKEN_FILE:-.vault/track-binocle-reader.env}"
  write_env_line ADMIN_CRED_LOST_WRITER_FILE "${VAULT_WRITER_TOKEN_FILE:-.vault/track-binocle-writer.env}"
} > "$RECEIPT_FILE"
chmod 600 "$RECEIPT_FILE"

printf '[vault-admin] wrote admin credential file: %s\n' "$ADMIN_FILE"
printf '[vault-admin] wrote recovery receipt: %s\n' "$RECEIPT_FILE"