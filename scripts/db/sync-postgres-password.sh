# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    sync-postgres-password.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env sh
set -eu

: "${POSTGRES_TARGET_USER:?POSTGRES_TARGET_USER is required}"
: "${POSTGRES_TARGET_PASSWORD:?POSTGRES_TARGET_PASSWORD is required}"

psql -U "$POSTGRES_TARGET_USER" -d "${POSTGRES_TARGET_DB:-postgres}" \
  -v ON_ERROR_STOP=1 \
  -v role="$POSTGRES_TARGET_USER" \
  -v new_password="$POSTGRES_TARGET_PASSWORD" <<'SQL'
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'new_password') \gexec
SQL