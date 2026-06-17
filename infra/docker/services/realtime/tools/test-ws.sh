# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    test-ws.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/realtime/tools/test-ws.sh
# Description: WebSocket connectivity & health test for realtime-agnostic
# Usage: ./test-ws.sh
set -euo pipefail

HEALTH_URL="${HEALTH_URL:-http://localhost:4000/v1/health}"
WS_URL="${WS_URL:-ws://localhost:4000/v1/ws}"

echo "==> Health check: ${HEALTH_URL}"
curl -sf "${HEALTH_URL}" | python3 -m json.tool 2>/dev/null || curl -sf "${HEALTH_URL}"
echo

echo "==> WebSocket connection test: ${WS_URL}"
if command -v wscat &>/dev/null; then
  echo '{"action":"subscribe","channel":"test"}' \
    | wscat -c "${WS_URL}" --wait 3
elif command -v curl &>/dev/null; then
  curl -i -N \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    "${WS_URL}" &
  WS_PID=$!
  sleep 3
  kill "${WS_PID}" 2>/dev/null || true
else
  echo "ERROR: Neither wscat nor curl found. Install one of them."
  exit 1
fi

echo "WebSocket test complet
