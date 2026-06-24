##@ Database Tools

.PHONY: db-generate db-studio db-push db-connect db-security

db-generate: ## Regenerate Prisma client from schema
	@$(SCRIPTS_PATH)/db/generate.sh

db-studio: ## Open Prisma Studio (browser UI for database)
	@$(SCRIPTS_PATH)/db/studio.sh

db-push: ## Push schema changes to database without migration history
	cd $(BACKEND_PATH) && npx prisma db push --schema=$(PRISMA_SCHEMA)

db-connect: ## Connect to Supabase PostgreSQL via psql
	@$(SCRIPTS_PATH)/db/connect.sh

db-security: ## Apply RLS and security policies to Supabase (non-destructive)
	@. $(BACKEND_PATH)/.env && psql "$$DIRECT_URL" -v ON_ERROR_STOP=1 \
		-f $(BACKEND_PATH)/src/Model/sql/schemas/security_rls.sql
	@printf 'RLS and security policies applied.\n'
