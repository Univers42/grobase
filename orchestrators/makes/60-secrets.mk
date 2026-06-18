# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    60-secrets.mk                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:47 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:48 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

secrets: ## Generate all secrets → .env
	@bash scripts/secrets/generate-secrets.sh
secrets-validate: ## Validate required secrets exist
	@bash scripts/secrets/validate-secrets.sh
secrets-rotate: ## Rotate JWT secret (GROUP=jwt|tenant-dsn|all)
	@bash scripts/secrets/rotate-jwt.sh
check-secrets: ## Scan source for hardcoded secrets
	@bash scripts/ci/check-secrets.sh
env: ## Assemble .env from config.env + .env.secrets (generated) + .env.local
	@bash scripts/env/assemble-env.sh
env-secrets: ## (Re)mint .env.secrets only (FORCE=1 to overwrite), then run `make env`
	@FORCE=$(FORCE) bash scripts/env/generate-env.sh
env-check: ## Verify mandatory secrets present + enabled features have their keys
	@bash scripts/env/check-env.sh
certs: ## Generate localhost TLS cert/key into certs (idempotent; the waf reads them as Docker secrets)
	@bash scripts/certs/generate-localhost-cert.sh
vault-init: _require-compose ## Run Vault init/unseal/seed
	@$(DC) --profile control-plane run --rm vault-init
vault-status: _require-compose ## Check Vault seal status
	@docker exec mini-baas-vault vault status -address=http://127.0.0.1:8200 2>/dev/null || echo -e "$(_R)Vault not running$(_0)"
vault-rotate: _require-compose ## Rotate Vault secrets (GROUP=jwt|postgres|mongo|minio|kong|all)
	@docker exec mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}
