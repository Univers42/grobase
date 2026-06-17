# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    generate-secrets.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/secrets/generate-secrets.sh
# Generate all required secrets with proper entropy
# Usage: bash scripts/secrets/generate-secrets.sh [output_dir]

set -euo pipefail

OUTPUT_DIR="${1:-./secrets}"
mkdir -p "$OUTPUT_DIR"

gen_secret() {
  local length="$1"
  openssl rand -base64 "$length" | tr -d '\n'
  return 0
}

gen_hex() {
  local length="$1"
  openssl rand -hex "$length"
  return 0
}

echo "=== mini-BaaS Secret Generator ==="
echo "Output directory: $OUTPUT_DIR"

# JWT Secret (256-bit)
if [[ ! -f "$OUTPUT_DIR/jwt_secret.txt" ]]; then
  gen_secret 32 > "$OUTPUT_DIR/jwt_secret.txt"
  echo "[+] Generated jwt_secret.txt"
else
  echo "[=] jwt_secret.txt already exists, skipping"
fi

# PostgreSQL password
if [[ ! -f "$OUTPUT_DIR/postgres_password.txt" ]]; then
  gen_secret 24 > "$OUTPUT_DIR/postgres_password.txt"
  echo "[+] Generated postgres_password.txt"
else
  echo "[=] postgres_password.txt already exists, skipping"
fi

# Vault encryption key (256-bit hex for AES-256-GCM)
if [[ ! -f "$OUTPUT_DIR/vault_enc_key.txt" ]]; then
  gen_hex 32 > "$OUTPUT_DIR/vault_enc_key.txt"
  echo "[+] Generated vault_enc_key.txt"
else
  echo "[=] vault_enc_key.txt already exists, skipping"
fi

# Kong API keys
if [[ ! -f "$OUTPUT_DIR/kong_public_api_key.txt" ]]; then
  gen_secret 24 > "$OUTPUT_DIR/kong_public_api_key.txt"
  echo "[+] Generated kong_public_api_key.txt"
else
  echo "[=] kong_public_api_key.txt already exists, skipping"
fi

if [[ ! -f "$OUTPUT_DIR/kong_service_api_key.txt" ]]; then
  gen_secret 32 > "$OUTPUT_DIR/kong_service_api_key.txt"
  echo "[+] Generated kong_service_api_key.txt"
else
  echo "[=] kong_service_api_key.txt already exists, skipping"
fi

# Dashboard password (Grafana, etc.)
if [[ ! -f "$OUTPUT_DIR/dashboard_password.txt" ]]; then
  gen_secret 16 > "$OUTPUT_DIR/dashboard_password.txt"
  echo "[+] Generated dashboard_password.txt"
else
  echo "[=] dashboard_password.txt already exists, skipping"
fi

# MinIO credentials
if [[ ! -f "$OUTPUT_DIR/minio_access_key.txt" ]]; then
  echo "minioadmin" > "$OUTPUT_DIR/minio_access_key.txt"
  gen_secret 24 > "$OUTPUT_DIR/minio_secret_key.txt"
  echo "[+] Generated minio_access_key.txt + minio_secret_key.txt"
else
  echo "[=] minio credentials already exist, skipping"
fi

chmod 600 "$OUTPUT_DIR"/*.txt
echo ""
echo "=== All secrets generated in $OUTPUT_DIR ==="
echo "Run 'bash scripts/secrets/validate-secrets.sh' to verify."
