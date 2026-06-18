# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    flush.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/redis/tools/flush.sh
# Description: Flush all keys from the Redis instance
# Usage: ./flush.sh
set -euo pipefail

echo "Flushing all Redis data..."
docker compose exec redis redis-cli FLUSHALL
echo "Redis FLUSHALL complete."
