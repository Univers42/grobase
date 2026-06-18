# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    create-user.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/gotrue/tools/create-user.sh
# Description: Create a test user via the GoTrue auth API
# Usage: ./create-user.sh [email] [password]
set -euo pipefail

EMAIL="${1:-test@example.com}"
PASSWORD="${2:-password123}"
AUTH_URL="${AUTH_URL:-http://localhost:8000/auth/v1/signup}"
ANON_KEY="${ANON_KEY:-}"

echo "Creating user: ${EMAIL}"
curl -s -X POST "${AUTH_URL}" \
  -H "Content-Type: application/json" \
  -H "apikey: ${ANON_KEY}" \
  -d "{\"email\": \"${EMAIL}\", \"password\": \"${PASSWORD}\"}" | jq .

echo "User signup request sent."
