# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:10 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 23:01:23 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #


.DEFAULT_GOAL := help

include $(sort $(wildcard orchestrators/makes/*.mk))

all:
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory up

all-full:
	@$(MAKE) --no-print-directory EDITION=full all

clean: clean-project ## Project clean: THIS project's images/containers/networks/build-caches — KEEPS all data volumes + other projects (was a global nuke; now scoped)

fclean: fclean-project ## DANGER: clean + WIPE this project's OWN data volumes (mini-baas_*). Needs CONFIRM=1. Other projects untouched, NO global prune.

re: ## Rebuild this project: clean (KEEP data) → build → up
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory all

rebuild: re ## Alias of re — automatic clean + build + up (data preserved)

# Full test matrix — every kind of test in the project, in one go. Order:
# unit (no stack) → quality/supply-chain → live integration → sonar → bench
# (bench restarts the stack, so it runs LAST). Each kind is a target in
# orchestrators/makes/100-test.mk. Prints a green/red summary; non-zero on any fail.
TEST_TARGETS := test-go test-rust-data test-rust-realtime test-nestjs test-sdk \
                test-lint test-deps test-scan \
                test-conformance test-scripts test-postman test-waf test-gates \
                test-sonar test-bench

tests: ## Run the FULL test matrix (Go·Rust·TS·SDK·lint·deps·scan·conformance·scripts·postman·waf·gates·sonar·bench)
	@echo -e "$(_W)▶ full test matrix — $(words $(TEST_TARGETS)) kinds$(_0)"; \
	pass=0; fail=0; failed=""; start=$$(date +%s); \
	for t in $(TEST_TARGETS); do \
		echo -e "\n$(_B)════════ $$t ════════$(_0)"; \
		if $(MAKE) --no-print-directory $$t; then echo -e "$(_G)✓ $$t$(_0)"; pass=$$((pass+1)); \
		else echo -e "$(_R)✗ $$t$(_0)"; fail=$$((fail+1)); failed="$$failed $$t"; fi; \
	done; \
	echo -e "\n$(_W)──────── test matrix: $$pass passed / $$fail failed (in $$(( $$(date +%s) - start ))s) ────────$(_0)"; \
	if [ $$fail -eq 0 ]; then echo -e "$(_G)✓ ALL GREEN ($(words $(TEST_TARGETS))/$(words $(TEST_TARGETS)))$(_0)"; \
	else echo -e "$(_R)✗ FAILED:$$failed$(_0)"; exit 1; fi

.PHONY: tests test-go test-rust test-rust-data test-rust-realtime test-nestjs test-sdk \
        test-lint test-deps test-scan test-sonar test-bench test-conformance \
        test-scripts test-smoke test-postman test-waf test-gates \
        all all-full clean fclean re up down restart ps logs pull build health \
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
