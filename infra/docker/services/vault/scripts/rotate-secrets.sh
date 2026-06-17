#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    rotate-secrets.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
# File: docker/services/vault/scripts/rotate-secrets.sh
# Automated Vault secret rotation with zero-downtime service restarts.
#
# Usage:
#   bash docker/services/vault/scripts/rotate-secrets.sh [secret_group]
#
# Groups:
#   all       Rotate all rotatable secrets (default)
#   jwt       Rotate JWT secret only (dual-key transition)
#   postgres  Rotate PostgreSQL password
#   mongo     Rotate MongoDB credentials
#   minio     Rotate MinIO credentials
#   kong      Rotate Kong API keys
#   smtp      Rotate SMTP credentials
#
# Environment:
#   VAULT_ADDR           Vault address (default: http://localhost:8200)
#   VAULT_TOKEN          Root/admin token (reads from .vault-keys.json if unset)
#   GRACE_SECONDS        Dual-key grace period for JWT (default: 300)
#   DRY_RUN              Set to "1" to preview without applying (default: 0)
#
# Prerequisites:
#   - Vault is unsealed and reachable
#   - `vault`, `jq`, `openssl` are available
#   - Docker Compose stack is accessible (for service restarts)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────
export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
KEYS_FILE="${KEYS_FILE:-/vault/data/.vault-keys.json}"
LOCAL_KEYS="${LOCAL_KEYS:-.vault-keys.json}"
GRACE_SECONDS="${GRACE_SECONDS:-300}"
DRY_RUN="${DRY_RUN:-0}"
GROUP="${1:-all}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; return 0; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; return 0; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; return 0; }
step() { echo -e "${BOLD}── $* ──${NC}"; return 0; }

# ─── Auth ─────────────────────────────────────────────────────────
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  for kf in "$KEYS_FILE" "$LOCAL_KEYS"; do
    if [[ -f "$kf" ]]; then
      export VAULT_TOKEN
      VAULT_TOKEN=$(jq -r '.root_token' "$kf")
      break
    fi
  done
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  err "VAULT_TOKEN not set and no .vault-keys.json found"
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────
gen_secret() { openssl rand -base64 "${1:-32}" | tr -d '\n'; return 0; }
gen_hex()    { openssl rand -hex "${1:-32}"; return 0; }

vault_put() {
  local path="$1"; shift
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY RUN: vault kv put $path $*"
    return 0
  fi
  vault kv put -address="$VAULT_ADDR" "$path" "$@" >/dev/null
  return 0
}

vault_get() {
  local path="$1" field="$2"
  vault kv get -address="$VAULT_ADDR" -format=json "$path" 2>/dev/null \
    | jq -r ".data.data.${field} // empty"
  return 0
}

restart_services() {
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY RUN: would restart $*"
    return 0
  fi
  log "Restarting: $*"
  docker compose restart "$@" 2>/dev/null || true
  return 0
}

update_env_var() {
  local key="$1" value="$2" env_file="${3:-.env}"
  if [[ ! -f "$env_file" ]]; then return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY RUN: $key=<redacted> in $env_file"
    return 0
  fi
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
  return 0
}

# ─── JWT Rotation (with dual-key grace period) ───────────────────
rotate_jwt() {
  step "Rotating JWT secret"

  local old_jwt new_jwt
  old_jwt=$(vault_get "secret/mini-baas/core" "jwt_secret")
  new_jwt=$(gen_secret 32)

  # Store previous secret so services can verify tokens signed with the old key
  vault_put "secret/mini-baas/core" \
    jwt_secret="$new_jwt" \
    jwt_secret_prev="$old_jwt" \
    vault_enc_key="$(vault_get secret/mini-baas/core vault_enc_key)" \
    adapter_registry_service_token="$(vault_get secret/mini-baas/core adapter_registry_service_token)"

  update_env_var "JWT_SECRET" "$new_jwt"
  update_env_var "PREV_JWT_SECRET" "$old_jwt"

  restart_services kong gotrue postgrest mongo-api adapter-registry query-router
  log "JWT rotated — dual-key active for ${GRACE_SECONDS}s"
  log "After grace period, remove PREV_JWT_SECRET from .env"
  return 0
}

# ─── PostgreSQL Password Rotation ────────────────────────────────
rotate_postgres() {
  step "Rotating PostgreSQL password"

  local user new_pass
  user=$(vault_get "secret/mini-baas/postgres" "user")
  new_pass=$(gen_secret 24)

  if [[ "$DRY_RUN" != "1" ]]; then
    # Change password in PostgreSQL itself
    docker compose exec -T postgres psql -U "$user" -d postgres \
      -c "ALTER USER ${user} PASSWORD '${new_pass}';" 2>/dev/null || {
      err "Failed to update PostgreSQL password — aborting"
      return 1
    }
  fi

  vault_put "secret/mini-baas/postgres" \
    user="$user" \
    password="$new_pass" \
    database="$(vault_get secret/mini-baas/postgres database)" \
    url="postgres://${user}:${new_pass}@postgres:5432/$(vault_get secret/mini-baas/postgres database)"

  update_env_var "POSTGRES_PASSWORD" "$new_pass"

  restart_services postgrest gotrue pg-meta
  log "PostgreSQL password rotated"
  return 0
}

# ─── MongoDB Credential Rotation ─────────────────────────────────
rotate_mongo() {
  step "Rotating MongoDB credentials"

  local user new_pass
  user=$(vault_get "secret/mini-baas/mongo" "username")
  new_pass=$(gen_secret 24)

  if [[ "$DRY_RUN" != "1" ]]; then
    docker compose exec -T mongo mongosh --quiet \
      -u "$user" -p "$(vault_get secret/mini-baas/mongo password)" \
      --authenticationDatabase admin \
      --eval "db.getSiblingDB('admin').changeUserPassword('${user}', '${new_pass}')" \
      2>/dev/null || {
      err "Failed to update MongoDB password — aborting"
      return 1
    }
  fi

  vault_put "secret/mini-baas/mongo" \
    username="$user" \
    password="$new_pass"

  update_env_var "MONGO_INITDB_ROOT_PASSWORD" "$new_pass"

  restart_services mongo-api query-router realtime
  log "MongoDB credentials rotated"
  return 0
}

# ─── MinIO Credential Rotation ───────────────────────────────────
rotate_minio() {
  step "Rotating MinIO credentials"

  local new_access new_secret
  new_access="minioadmin"  # MinIO access key typically stays the same
  new_secret=$(gen_secret 24)

  vault_put "secret/mini-baas/minio" \
    access_key="$new_access" \
    secret_key="$new_secret"

  update_env_var "MINIO_ROOT_PASSWORD" "$new_secret"

  restart_services minio storage-router
  log "MinIO credentials rotated"
  return 0
}

# ─── Kong API Key Rotation ───────────────────────────────────────
rotate_kong() {
  step "Rotating Kong API keys"

  local new_public new_service
  new_public=$(gen_secret 24)
  new_service=$(gen_secret 32)

  vault_put "secret/mini-baas/kong" \
    public_api_key="$new_public" \
    service_api_key="$new_service"

  update_env_var "KONG_PUBLIC_API_KEY" "$new_public"
  update_env_var "KONG_SERVICE_API_KEY" "$new_service"

  restart_services kong
  log "Kong API keys rotated"
  warn "Update all API consumers with new keys!"
  return 0
}

# ─── SMTP Credential Rotation ────────────────────────────────────
rotate_smtp() {
  step "Rotating SMTP credentials"

  local new_user new_pass
  new_user="${SMTP_USER:-}"
  new_pass="${SMTP_PASS:-}"

  if [[ -z "$new_user" || -z "$new_pass" ]]; then
    warn "SMTP credentials must be provided via SMTP_USER and SMTP_PASS env vars"
    warn "These come from your email provider — cannot be auto-generated"
    return 0
  fi

  vault_put "secret/mini-baas/smtp" \
    host="$(vault_get secret/mini-baas/smtp host)" \
    port="$(vault_get secret/mini-baas/smtp port)" \
    user="$new_user" \
    pass="$new_pass"

  update_env_var "SMTP_USER" "$new_user"
  update_env_var "SMTP_PASS" "$new_pass"

  restart_services email-service newsletter-service gotrue
  log "SMTP credentials rotated"
  return 0
}

# ─── AppRole Secret ID Rotation ──────────────────────────────────
rotate_approles() {
  step "Rotating AppRole secret IDs"

  local services="kong gotrue postgrest mongo-api adapter-registry query-router email-service storage-router permission-engine schema-service"

  for svc in $services; do
    if [[ "$DRY_RUN" == "1" ]]; then
      warn "DRY RUN: would rotate AppRole for ${svc}"
      continue
    fi

    # Generate new secret ID (old ones remain valid until TTL expires)
    local secret_id role_id
    role_id=$(vault read -address="$VAULT_ADDR" -format=json \
      "auth/approle/role/${svc}/role-id" 2>/dev/null | jq -r '.data.role_id // empty')

    if [[ -z "$role_id" ]]; then
      warn "AppRole ${svc} not found — skipping"
      continue
    fi

    secret_id=$(vault write -address="$VAULT_ADDR" -format=json -f \
      "auth/approle/role/${svc}/secret-id" | jq -r '.data.secret_id')

    vault_put "secret/mini-baas/approle/${svc}" \
      role_id="$role_id" \
      secret_id="$secret_id"

    log "  ${svc}: new secret_id=${secret_id:0:8}…"
  done

  log "All AppRole secret IDs rotated"
  return 0
}

# ─── Main ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ mini-BaaS Vault Secret Rotation ═══${NC}"
echo -e "  Group:   ${BOLD}${GROUP}${NC}"
echo -e "  Vault:   ${VAULT_ADDR}"
echo -e "  Dry run: ${DRY_RUN}"
echo ""

case "$GROUP" in
  jwt)       rotate_jwt ;;
  postgres)  rotate_postgres ;;
  mongo)     rotate_mongo ;;
  minio)     rotate_minio ;;
  kong)      rotate_kong ;;
  smtp)      rotate_smtp ;;
  approles)  rotate_approles ;;
  all)
    rotate_jwt
    rotate_postgres
    rotate_mongo
    rotate_minio
    rotate_kong
    rotate_approles
    ;;
  *)
    err "Unknown group: $GROUP"
    echo "Available: all jwt postgres mongo minio kong smtp approles"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}═══ Rotation Complete ═══${NC}"
[[ "$DRY_RUN" == "1" ]] && warn "This was a dry run — no changes applied"
