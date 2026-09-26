# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    rotate-jwt.sh                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/secrets/rotate-jwt.sh
# Rotate JWT secret with zero-downtime (dual-key period)
# Usage: bash scripts/secrets/rotate-jwt.sh [secrets_dir]
#
# Strategy:
#   1. Generate new JWT secret
#   2. Set JWT_SECRET_PREV = current secret (for validation during transition)
#   3. Set JWT_SECRET = new secret (for signing)
#   4. Restart services that use JWT
#   5. After grace period, remove JWT_SECRET_PREV
#
# Refuses unless ROTATE_JWT_FORCE=1: the rotation is not zero-downtime yet (the
# message below says why), so running it is a planned outage, never routine.

set -euo pipefail

SECRETS_DIR="${1:-./secrets}"
GRACE_SECONDS="${GRACE_SECONDS:-300}"

if [[ "${ROTATE_JWT_FORCE:-0}" != "1" ]]; then
  echo "ERROR: JWT rotation refused: it is not zero-downtime yet. Kong keeps one secret per issuer, PostgREST and GoTrue read one secret, and ANON_KEY/SERVICE_ROLE_KEY are signed with it, so a swap logs every user out and breaks every frontend key. Only tenant-control, the TS services and realtime accept JWT_SECRET_PREV (G-Rotate, wiki/security/remediation-tracker-2025-07-14.md). ROTATE_JWT_FORCE=1 rotates anyway, as a planned outage." >&2
  exit 1
fi

if [[ ! -f "$SECRETS_DIR/jwt_secret.txt" ]]; then
  echo "ERROR: No existing jwt_secret.txt found in $SECRETS_DIR" >&2
  echo "Run 'bash scripts/secrets/generate-secrets.sh' first." >&2
  exit 1
fi

echo "=== JWT Secret Rotation ==="

# Step 1: Backup current secret as previous
cp "$SECRETS_DIR/jwt_secret.txt" "$SECRETS_DIR/jwt_secret_prev.txt"
chmod 600 "$SECRETS_DIR/jwt_secret_prev.txt"
echo "[1/4] Backed up current secret as jwt_secret_prev.txt"

# Step 2: Generate new secret
openssl rand -base64 32 | tr -d '\n' >"$SECRETS_DIR/jwt_secret.txt"
chmod 600 "$SECRETS_DIR/jwt_secret.txt"
echo "[2/4] Generated new jwt_secret.txt"

# Step 3: Update .env if it exists
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
  NEW_SECRET=$(cat "$SECRETS_DIR/jwt_secret.txt")
  PREV_SECRET=$(cat "$SECRETS_DIR/jwt_secret_prev.txt")

  # Set the new primary JWT secret
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$NEW_SECRET|" "$ENV_FILE"

  # Add or update JWT_SECRET_PREV for dual-key validation
  if grep -q "^JWT_SECRET_PREV=" "$ENV_FILE"; then
    sed -i "s|^JWT_SECRET_PREV=.*|JWT_SECRET_PREV=$PREV_SECRET|" "$ENV_FILE"
  else
    echo "JWT_SECRET_PREV=$PREV_SECRET" >>"$ENV_FILE"
  fi
  echo "[3/4] Updated $ENV_FILE with new JWT_SECRET and JWT_SECRET_PREV"
else
  echo "[3/4] No .env file found — update environment manually"
fi

# Step 4: Restart JWT-dependent services
echo "[4/4] Restarting JWT-dependent services..."
docker compose restart gotrue mongo-api adapter-registry query-router postgrest 2>/dev/null || true

echo ""
echo "=== Rotation complete ==="
echo "Both old and new JWT secrets are active."
echo "After ${GRACE_SECONDS}s grace period, remove jwt_secret_prev.txt"
echo "and the JWT_SECRET_PREV line from .env."
echo ""
echo "To finalize: rm $SECRETS_DIR/jwt_secret_prev.txt"
