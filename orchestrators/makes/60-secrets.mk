# ========================================================================== #
##@ Secrets & Vault
# ========================================================================== #
secrets: ## Generate all secrets → .env
	@bash scripts/secrets/generate-secrets.sh
secrets-validate: ## Validate required secrets exist
	@bash scripts/secrets/validate-secrets.sh
secrets-rotate: ## Rotate JWT secret (GROUP=jwt|tenant-dsn|all)
	@bash scripts/secrets/rotate-jwt.sh
check-secrets: ## Scan source for hardcoded secrets
	@bash scripts/ci/check-secrets.sh
env: ## Generate .env from template
	@bash scripts/env/generate-env.sh
certs: ## Generate localhost TLS cert/key into certs (idempotent; the waf reads them as Docker secrets)
	@bash scripts/certs/generate-localhost-cert.sh
vault-init: _require-compose ## Run Vault init/unseal/seed
	@$(DC) --profile control-plane run --rm vault-init
vault-status: _require-compose ## Check Vault seal status
	@docker exec mini-baas-vault vault status -address=http://127.0.0.1:8200 2>/dev/null || echo -e "$(_R)Vault not running$(_0)"
vault-rotate: _require-compose ## Rotate Vault secrets (GROUP=jwt|postgres|mongo|minio|kong|all)
	@docker exec mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}

