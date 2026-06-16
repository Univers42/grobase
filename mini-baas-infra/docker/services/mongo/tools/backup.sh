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
# Description: Create a MongoDB backup using mongodump in archive format
# Usage: ./backup.sh
set -euo pipefail

BACKUP_FILE="mongo_backup_$(date +%Y%m%d).archive"

echo "Creating MongoDB backup: ${BACKUP_FILE}"
docker compose exec mongo mongodump --archive > "${BACKUP_FILE}"
echo "Backup saved to ${BACKUP_FILE}"
