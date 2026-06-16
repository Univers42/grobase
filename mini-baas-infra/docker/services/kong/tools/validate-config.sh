# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    validate-config.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: docker/services/kong/tools/validate-config.sh
# Description: Validate the Kong declarative configuration file (kong.yml)
# Usage: ./validate-config.sh
set -euo pipefail

echo "Validating Kong configuration …"
docker compose exec kong kong config parse /usr/local/kong/kong.yml
echo "Kong configuration is valid."
