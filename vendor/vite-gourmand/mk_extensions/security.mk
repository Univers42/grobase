##@ Security

.PHONY: security-audit security-secrets security-headers security-deps security-https security-all

security-audit: ## Run npm audit on Back and View packages
	@$(SCRIPTS_PATH)/security/audit.sh

security-secrets: ## Scan source code for hardcoded secrets and tokens
	@$(SCRIPTS_PATH)/security/secrets.sh

security-headers: ## Check HTTP security headers (URL=http://localhost:3000)
	@URL="$(URL)" $(SCRIPTS_PATH)/security/headers.sh

security-deps: ## Check for known vulnerable dependencies
	@$(SCRIPTS_PATH)/security/deps.sh

security-https: ## Verify production HTTPS, CA certificate, redirects, and HSTS
	@$(SCRIPTS_PATH)/security/verify-production-https.sh

security-all: security-audit security-secrets security-deps ## Run all security checks
