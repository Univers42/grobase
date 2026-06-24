##@ Database Inspection

.PHONY: db-status db-query psql mongosh supabase-counts

db-status: ## Show database connection status and row counts per table
	@$(SCRIPTS_PATH)/db/status.sh

db-query: ## Run a raw SQL query: make db-query SQL="SELECT * FROM users LIMIT 5"
	@SQL="$(SQL)" $(SCRIPTS_PATH)/db/query.sh

psql: ## Open an interactive PostgreSQL shell (local Docker)
	@$(SCRIPTS_PATH)/docker/psql.sh

mongosh: ## Open an interactive MongoDB shell (local Docker)
	@$(SCRIPTS_PATH)/docker/mongosh.sh

supabase-counts: ## Show row counts for all Supabase tables
	@. $(BACKEND_PATH)/.env && psql "$$DIRECT_URL" -c \
		"SELECT relname AS table_name, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
