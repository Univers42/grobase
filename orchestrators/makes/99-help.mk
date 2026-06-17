# ========================================================================== #
##@ Help
# ========================================================================== #
help: ## Show this help
	@echo ""
	@echo -e "$(_W)$(_C)$(PROJECT) — layer/edition orchestrator$(_0)"
	@echo -e "$(_D)EDITION=$(EDITION)  ·  make planes  ·  make editions  ·  make doctor$(_0)"
	@awk 'BEGIN {FS=":.*##"} \
		/^##@/ { printf "\n$(_W)%s$(_0)\n", substr($$0,5) } \
		/^[a-zA-Z0-9_%.-]+:.*##/ { printf "  $(_G)%-22s$(_0) $(_D)%s$(_0)\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo -e "$(_D)Generated per-plane verbs: up-<plane> down-<plane> restart-<plane> logs-<plane>$(_0)"
	@echo ""

.PHONY: all all-full clean fclean re up down restart ps logs pull build health \
        bench-startup bench-load bench-capacity bench-mem bench-compare scale-seed scale-teardown observe planes editions doctor tests test-postgres test-offers test-edge \
        verify-all parity waf-test migrate migrate-mongo migrate-mysql migrate-all \
        migrate-status seed-mongo seed-live-demo secrets secrets-validate secrets-rotate \
        check-secrets env certs vault-init vault-status vault-rotate nestjs-ci \
        sonar-coverage sonar-scan \
        rust-data-plane-check rust-data-plane-build go-control-plane-check \
        rust-realtime-check rust-realtime-test rust-realtime-build _rust-toolchain \
        go-control-plane-build preflight hooks update help \
        quickstart release-binaries release-images release-check _require-version \
        backup-now restore-verify cloud-flags-print cloud-up cloud-down \
        _require-docker _require-compose _rm-stale
