# ========================================================================== #
##@ 42 Classics
# ========================================================================== #
all: ## Build images & start the default EDITION
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory up

all-full: ## Build & start the FULL edition
	@$(MAKE) --no-print-directory EDITION=full all

clean: down ## Stop the current edition (alias for down)

fclean: _require-compose ## Destructive: stop everything, prune containers/volumes/images/cache
	@echo -e "$(_Y)$(_W)Running destructive Docker cleanup…$(_0)"
	@$(DC) $(call flags_of,$(PLANES)) down --volumes --remove-orphans 2>/dev/null || true
	@ids=$$(docker ps -aq); [ -z "$$ids" ] || docker rm -f $$ids >/dev/null 2>&1 || true
	@docker system prune -af --volumes >/dev/null 2>&1 || true
	@docker builder prune -af >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ Full Docker clean complete$(_0)"

re: ## Full reset: fclean then rebuild & start (honours EDITION)
	@$(MAKE) --no-print-directory fclean
	@$(MAKE) --no-print-directory all

