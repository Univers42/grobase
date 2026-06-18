##@ Database (Prisma)

.PHONY: db-migrate db-migrate-deploy db-seed db-reset db-reset-full

db-migrate: ## Run Prisma migrations (dev mode, creates migration files)
	@$(SCRIPTS_PATH)/db/migrate.sh

db-migrate-deploy: ## Run Prisma migrations (production, no prompt)
	@$(SCRIPTS_PATH)/db/migrate.sh deploy

db-seed: ## Run Prisma seed script
	@$(SCRIPTS_PATH)/db/seed.sh

db-reset: ## Reset database via Prisma - DESTRUCTIVE
	@$(SCRIPTS_PATH)/db/reset.sh

db-reset-full: ## Full reset: drop tables, re-apply schemas, seeds, RLS, introspect - DESTRUCTIVE
	@$(SCRIPTS_PATH)/database/reset_database.sh
