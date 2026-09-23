# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    backup.sh                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/mongo/tools/backup.sh
# Description: Create a MongoDB backup (gzip archive) of every database.
# Usage: ./backup.sh [--db NAME]
#
# This used to run `docker compose exec mongo mongodump --archive`: the image
# had no mongodump (and the call had no credentials), so it never produced a
# backup. It now delegates to scripts/ops/engine-backup.sh, which gate m188
# round-trips; restore with `engine-backup.sh restore mongo <file>`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
BACKUP_FILE="mongo_backup_$(date +%Y%m%d%H%M%S).archive.gz"
echo "Creating MongoDB backup: ${BACKUP_FILE}"
bash "${ROOT}/scripts/ops/engine-backup.sh" dump mongo "${BACKUP_FILE}" "$@"
echo "Backup saved to ${BACKUP_FILE}"
