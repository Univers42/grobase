# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    restore.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/postgres/tools/restore.sh
# Description: Restore a PostgreSQL backup from a custom-format dump file
# Usage: ./restore.sh <backup_file.dump>
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup_file.dump>"
  exit 1
fi

BACKUP_FILE="$1"

if [[ ! -f "${BACKUP_FILE}" ]]; then
  echo "Error: file '${BACKUP_FILE}' not found" >&2
  exit 1
fi

echo "Restoring PostgreSQL from ${BACKUP_FILE}..."
docker compose exec -T postgres pg_restore -U postgres -d postgres < "${BACKUP_FILE}"
echo "Restore complete."
