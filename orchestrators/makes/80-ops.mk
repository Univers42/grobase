# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    80-ops.mk                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:35 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:37 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

preflight: ## Run pre-deployment checks
	@bash scripts/ci/preflight-check.sh
hooks: ## Activate git hooks
	@if [ -d .git ]; then git config --local core.hooksPath $(HOOKS_DIR); chmod +x $(HOOKS_DIR)/* 2>/dev/null || true; echo -e "  $(_G)✓$(_0) hooks → $(HOOKS_DIR)"; else echo "  • not a git repo"; fi
update: ## Update git submodules
	@git submodule update --remote --merge && echo -e "$(_G)✓ Submodules updated$(_0)"


backup-now: ## Take a one-off Postgres backup right now (pg-backup `once` → MinIO)
	@echo -e "$(_B)Running an on-demand backup (pg-backup once)…$(_0)"
	@docker compose --profile backups run --rm pg-backup once \
		&& echo -e "$(_G)✓ backup complete — under the configured MinIO bucket$(_0)"

restore-verify: ## Prove a backup restores (dump→drop→restore→checksum, scratch DB; tenant data untouched)
	@bash scripts/verify/m47-backup-restore.sh

cloud-flags-print: ## Print the managed-cloud flag manifest (B7.1 single flip point — OPT-IN, no behaviour)
	@cat infra/config/cloud/flags.env.example
	@echo ""
	@echo -e "$(_D)Opt-in: the default stack ignores this manifest (all flags default OFF in code = byte-parity).$(_0)"
	@echo -e "$(_D)Promotion ladder (staging→canary→prod): infra/config/cloud/README.md$(_0)"

# ── Cloud edition (managed-cloud, all flags ON, mock Stripe) ─────────────────
# The env-only overlay docker-compose.cloud.yml + infra/config/cloud/flags.env.cloud
# layered onto the default compose with the EDITION=prod planes + the `cloud`
# profile (stripe-mock). OPT-IN: a non-cloud `make up` never passes these `-f`s,
# so the default stack stays byte-parity (kernel #5). Design: wiki/cloud-edition-design.md.
CLOUD_FILES     := -f $(COMPOSE_FILE) -f orchestrators/compose/docker-compose.cloud.yml
CLOUD_PROFILES  := --profile control-plane --profile go-control-plane \
                   --profile rust-data-plane --profile adapter-plane \
                   --profile background --profile storage --profile realtime \
                   --profile observability --profile ops --profile backups \
                   --profile cloud

cloud-up: _require-compose _rm-stale ## Boot the FULL managed-cloud stack locally (all cloud flags ON, mock Stripe)
	@echo -e "$(_B)Starting CLOUD edition (all managed-cloud flags ON, mock Stripe) → prod planes + cloud profile$(_0)"
	@eval "$$(bash scripts/ops/resolve-ports.sh 2>/dev/null || true)"; \
	  docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) up -d $(SERVICE)
	@echo -e "$(_G)✓ Cloud edition up (infra/config/cloud/flags.env.cloud layered; stripe-mock in the cloud profile)$(_0)"

cloud-down: _require-compose ## Stop the cloud edition (overlay + cloud profile)
	@docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) down
	@echo -e "$(_G)✓ Cloud edition down$(_0)"
