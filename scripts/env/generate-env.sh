# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    generate-env.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 by dlesieur                  ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# Mint the GENERATED secrets into .env.secrets (gitignored, mode 600). This file
# holds ONLY auto-generated, high-entropy values + the DSNs that embed them —
# never config (config.env) and never external API keys (.env.local). `make env`
# (scripts/env/assemble-env.sh) concatenates the three into .env.
set -euo pipefail

TOPUP=0
if [[ "${1:-}" == "--topup" ]]; then
  TOPUP=1
  shift
fi
SECRETS_FILE="${1:-.env.secrets}"
FORCE="${FORCE:-0}"

if [[ -f "$SECRETS_FILE" && "$FORCE" != "1" && "$TOPUP" != "1" ]]; then
  echo "Error: $SECRETS_FILE already exists — keeping it (use FORCE=1 to mint fresh, or --topup to add only what is missing)." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "Error: openssl is required but not installed." >&2
  exit 1
fi

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
  return 0
}

gen_alnum() {
  local length="$1" out=""
  while [[ "${#out}" -lt "$length" ]]; do
    out+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:length}"
  return 0
}

jwt_hs256() {
  local secret="$1" role="$2" iat exp header payload sig h p
  iat="$(date +%s)"
  exp="$((iat + 157680000))" # 5 years
  header='{"alg":"HS256","typ":"JWT"}'
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$iat" "$exp")
  h="$(printf '%s' "$header" | b64url)"
  p="$(printf '%s' "$payload" | b64url)"
  sig="$(printf '%s' "$h.$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
  printf '%s.%s.%s' "$h" "$p" "$sig"
  return 0
}

# Identity/db host+name come from config.env (defaults below match it). The DSNs
# embed the password, so they are minted here alongside it; change POSTGRES_DB in
# config.env and you must re-mint (FORCE=1) so these follow.
PG_USER="postgres"
PG_DB="postgres"
POSTGRES_PASSWORD="$(gen_alnum 24)"
AUTHENTICATOR_PASSWORD="$(gen_alnum 24)"
JWT_SECRET="$(openssl rand -hex 32)"
VAULT_ENC_KEY="$(openssl rand -hex 16)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
MONGO_INITDB_ROOT_PASSWORD="$(gen_alnum 24)"
# Inter-plane service token — DISTINCT from JWT_SECRET (audit O1/O2): a leak of the
# user-auth JWT secret must not also compromise service auth. Minted ONCE here.
ADAPTER_REGISTRY_SERVICE_TOKEN="$(openssl rand -hex 32)"
# Identity-envelope HMAC key (kid:secret) — signs the x-baas-* identity headers the
# api-key middleware stamps after key verify; the downstream verifier accepts any
# configured key. WITHOUT this, api-key tenant auth fails 500 identity_unavailable.
INTERNAL_IDENTITY_HMAC_KEYS="k1:$(openssl rand -hex 32)"
LOG_STREAM_TOKEN="$(gen_alnum 32)"
# Secondary-engine root/app passwords. These previously existed ONLY as literal
# compose defaults, so every stack booted them with a published credential; the
# compose files now require them (${VAR:?}) and they are minted here instead.
# MSSQL enforces complexity (>=8 chars, 3 of upper/lower/digit/symbol), hence the
# explicit symbol+digit suffix rather than a bare alnum run.
MYSQL_ROOT_PASSWORD="$(gen_alnum 24)"
MYSQL_PASSWORD="$(gen_alnum 24)"
MARIADB_ROOT_PASSWORD="$(gen_alnum 24)"
MARIADB_PASSWORD="$(gen_alnum 24)"
MSSQL_SA_PASSWORD="$(gen_alnum 20)aA1%"
# supavisor's Phoenix cookie (pooler / scale / prod overlays). Was a literal default.
SECRET_KEY_BASE="$(openssl rand -hex 32)"
ANON_KEY="$(jwt_hs256 "$JWT_SECRET" "anon")"
SERVICE_ROLE_KEY="$(jwt_hs256 "$JWT_SECRET" "service_role")"
DATABASE_URL="postgres://${PG_USER}:${POSTGRES_PASSWORD}@postgres:5432/${PG_DB}"
PGRST_DB_URI="postgres://authenticator:${AUTHENTICATOR_PASSWORD}@postgres:5432/${PG_DB}"

# top_up appends only the keys ABSENT from an existing secrets file and rotates
# nothing already there. This is the upgrade path: a checkout whose .env.secrets
# predates a newly-required key had no way forward, because `make env` only mints
# when the file is missing and FORCE=1 re-mints POSTGRES_PASSWORD and
# MONGO_INITDB_ROOT_PASSWORD, which an initialized volume then rejects. The compose
# error said "run make env" and running it changed nothing.
#
# Values come from the same generators above, so a topped-up file is
# indistinguishable from a freshly minted one. Only key NAMES are printed.
top_up() {
  local added=() k v
  for k in POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD JWT_SECRET VAULT_ENC_KEY \
    MINIO_ROOT_PASSWORD MONGO_INITDB_ROOT_PASSWORD ADAPTER_REGISTRY_SERVICE_TOKEN \
    INTERNAL_IDENTITY_HMAC_KEYS LOG_STREAM_TOKEN ANON_KEY SERVICE_ROLE_KEY \
    KONG_PUBLIC_API_KEY KONG_SERVICE_API_KEY DATABASE_URL PGRST_DB_URI \
    ADAPTER_REGISTRY_DATABASE_URL MYSQL_ROOT_PASSWORD MYSQL_PASSWORD \
    MARIADB_ROOT_PASSWORD MARIADB_PASSWORD MSSQL_SA_PASSWORD SECRET_KEY_BASE; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?${k}=" "$SECRETS_FILE" && continue
    v="${!k:-}"
    [[ -n "$v" ]] || continue
    printf '%s=%s\n' "$k" "$v" >>"$SECRETS_FILE"
    added+=("$k")
  done
  chmod 600 "$SECRETS_FILE"
  if [[ "${#added[@]}" -eq 0 ]]; then
    echo "$SECRETS_FILE already has every generated key — nothing to add."
  else
    printf 'Added %s missing key(s) to %s: %s\n' \
      "${#added[@]}" "$SECRETS_FILE" "${added[*]}"
    echo "Existing values were NOT rotated."
  fi
}

if [[ "$TOPUP" == "1" && -f "$SECRETS_FILE" ]]; then
  top_up
  exit 0
fi

cat >"$SECRETS_FILE" <<EOF
# Generated by scripts/env/generate-env.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# AUTO-GENERATED SECRETS — gitignored, mode 600. Do not hand-edit or commit.
# Regenerate with: FORCE=1 bash scripts/env/generate-env.sh  (then re-run make env,
# and rotate any already-initialized DB password to match — see db-bootstrap).

# Database (passwords; identity/name are in config.env)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
AUTHENTICATOR_PASSWORD=${AUTHENTICATOR_PASSWORD}
DATABASE_URL=${DATABASE_URL}
PGRST_DB_URI=${PGRST_DB_URI}
ADAPTER_REGISTRY_DATABASE_URL=${DATABASE_URL}

# Auth / inter-plane
JWT_SECRET=${JWT_SECRET}
ADAPTER_REGISTRY_SERVICE_TOKEN=${ADAPTER_REGISTRY_SERVICE_TOKEN}
INTERNAL_IDENTITY_HMAC_KEYS=${INTERNAL_IDENTITY_HMAC_KEYS}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
# Kong key-auth credentials ARE the JWTs (supabase-js sends them as apikey + Bearer)
KONG_PUBLIC_API_KEY=${ANON_KEY}
KONG_SERVICE_API_KEY=${SERVICE_ROLE_KEY}

# Storage / vault / mongo / logging
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}
LOG_STREAM_TOKEN=${LOG_STREAM_TOKEN}

# Secondary engines (mysql / mariadb / mssql) — opt-in planes, but the compose
# files require these, so they are always minted (an unset one fails the render).
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
MARIADB_PASSWORD=${MARIADB_PASSWORD}
MSSQL_SA_PASSWORD=${MSSQL_SA_PASSWORD}

# Connection pooler (supavisor) — pooler/scale/prod overlays require it.
SECRET_KEY_BASE=${SECRET_KEY_BASE}
EOF

chmod 600 "$SECRETS_FILE"
echo "Minted $SECRETS_FILE"
