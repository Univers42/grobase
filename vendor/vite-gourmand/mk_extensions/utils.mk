##@ Utilities

.PHONY: status doctor env-show env-check summary

status: ## Show project status overview (containers, servers, env)
	@$(SCRIPTS_PATH)/utils/status.sh

doctor: ## Check development environment health (Docker, Node, ports)
	@$(SCRIPTS_PATH)/utils/doctor.sh

env-show: ## Print environment variables with values masked
	@$(SCRIPTS_PATH)/utils/env.sh show

env-check: ## Verify all required environment variables are set
	@$(SCRIPTS_PATH)/utils/env.sh check

summary: ## Print running service URLs and quick-reference commands
	@printf '\n'
	@printf '  Frontend  -> http://localhost:%s\n' $(FRONTEND_PORT)
	@printf '  Backend   -> http://localhost:%s/api\n' $(BACKEND_PORT)
	@printf '  API Docs  -> http://localhost:%s/api/docs\n' $(BACKEND_PORT)
	@printf '\n'
	@printf '  PostgreSQL -> Supabase (cloud)\n'
	@printf '  MongoDB    -> Atlas (cloud)\n'
	@printf '\n'
	@printf '  make stop      Stop containers\n'
	@printf '  make shell     Open shell in container\n'
	@printf '  make logs      View logs\n'
	@printf '  make fclean    Full cleanup\n'
	@printf '  make help      All commands\n'
	@printf '\n'
	@printf '  Logs: tail -f /tmp/backend.log\n'
	@printf '        tail -f /tmp/frontend.log\n'
	@printf '\n'
