##@ Diagnostics

.PHONY: diagnostic diagnostic-rgpd diagnostic-rgaa diagnostic-code diagnostic-perf

diagnostic: ## Run all diagnostic checks (RGPD, RGAA, code, perf)
	@CHECK=all $(SCRIPTS_PATH)/diagnostic/run.sh

diagnostic-rgpd: ## Check RGPD compliance
	@CHECK=rgpd $(SCRIPTS_PATH)/diagnostic/run.sh

diagnostic-rgaa: ## Check RGAA accessibility compliance
	@CHECK=rgaa $(SCRIPTS_PATH)/diagnostic/run.sh

diagnostic-code: ## Check code quality metrics
	@CHECK=code $(SCRIPTS_PATH)/diagnostic/run.sh

diagnostic-perf: ## Check performance indicators
	@CHECK=perf $(SCRIPTS_PATH)/diagnostic/run.sh
