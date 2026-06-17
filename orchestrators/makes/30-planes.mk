# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    30-planes.mk                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 23:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 23:00:02 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

define PLANE_RULES
up-$(1): _require-compose ## (generated) start the '$(1)' plane on a running core
	@echo -e "$(_B)+ plane $(_W)$(1)$(_0) → $(_C)$(PROFILES_$(1))$(_0)"
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) up -d $$(SERVICE)

down-$(1): _require-compose ## (generated) stop the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) stop $$(SERVICE)

restart-$(1): _require-compose ## (generated) restart the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) restart $$(SERVICE)

logs-$(1): _require-compose ## (generated) follow the '$(1)' plane logs
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) logs -f --tail=100 $$(SERVICE)
endef
$(foreach p,$(PLANES),$(eval $(call PLANE_RULES,$(p))))

observe: up-observability ## Alias: start the observability plane
	@echo -e "  Grafana: http://localhost:3030   Prometheus: http://localhost:9090"

planes: ## List planes and the profiles they activate
	@echo -e "$(_W)$(_C)Planes$(_0)  (use: make up-<plane> / down-<plane> / logs-<plane>)"
	@$(foreach p,$(PLANES),printf "  $(_G)%-14s$(_0) $(_D)%s$(_0)\n" "$(p)" "$(PROFILES_$(p))";)

editions: ## List editions and the planes they include
	@echo -e "$(_W)$(_C)Editions$(_0)  (use: make up EDITION=<name>)"
	@$(foreach e,$(EDITIONS),printf "  $(_G)%-10s$(_0) $(_D)%s$(_0)\n" "$(e)" "$(if $(EDITION_$(e)),$(EDITION_$(e)),core only)";)

packages: ## List service-tier packages and the planes they include (Phase 4)
	@echo -e "$(_W)$(_C)Packages$(_0)  (use: make up PACKAGE=<tier> ADDONS=\"<plane>…\")"
	@$(foreach p,$(PACKAGES),printf "  $(_G)%-10s$(_0) $(_D)%s$(_0)\n" "$(p)" "$(PACKAGE_$(p))";)
	@echo -e "  $(_D)source of truth: infra/config/packages/packages.json (capability masks + limits + engines)$(_0)"

doctor: ## Environment sanity check
	@echo -e "$(_B)Doctor$(_0)"
	@command -v docker >/dev/null 2>&1 && echo "  ✓ docker" || echo "  ✗ docker"
	@docker compose version >/dev/null 2>&1 && echo "  ✓ compose v2" || echo "  ✗ compose v2"
	@[ -f .env ] && echo "  ✓ .env present" || echo "  • .env missing (run: make env)"
	@echo "  • EDITION=$(EDITION) → profiles: $(ACTIVE_PROFILES)"
