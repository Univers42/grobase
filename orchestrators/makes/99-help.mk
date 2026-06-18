# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    99-help.mk                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:17 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:20 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

help: ## Show this help
	@echo ""
	@echo -e "$(_W)$(_C)$(PROJECT) — layer/edition orchestrator$(_0)"
	@echo -e "$(_D)EDITION=$(EDITION)  ·  make planes  ·  make editions  ·  make doctor$(_0)"
	@awk 'BEGIN {FS=":.*##"} \
		/^##@/ { printf "\n$(_W)%s$(_0)\n", substr($$0,5) } \
		/^[a-zA-Z0-9_%.-]+:.*##/ { printf "  $(_G)%-22s$(_0) $(_D)%s$(_0)\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo -e "$(_D)Generated per-plane verbs: up-<plane> down-<plane> restart-<plane> logs-<plane>$(_0)"
	@echo ""
