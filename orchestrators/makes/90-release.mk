# ========================================================================== #
##@ Release
# ========================================================================== #
# v1.0 release machinery (RELEASE.md is the checklist authority). The GitHub
# pipeline (.github/workflows/baas-release.yml at the monorepo root) fires on
# baas-v* tags; these targets are its local mirror for dry-runs and operators.
VERSION ?=

_require-version:
	@if [ -z "$(VERSION)" ]; then \
		echo -e "$(_R)VERSION is required (e.g. make release-images VERSION=1.0.0)$(_0)"; exit 1; fi

quickstart: ## One command to a running stack: .env → up PACKAGE (default essential) → health
	@[ -f .env ] || $(MAKE) env
	@$(MAKE) up PACKAGE=$(or $(PACKAGE),essential)
	@$(MAKE) health
	@echo ""
	@echo -e "$(_G)$(_W)✓ Grobase BaaS is up$(_0)"
	@p="$$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"; p="$${p:-8000}"; \
		echo -e "  Gateway:  $(_C)http://localhost:$$p$(_0)"; \
		echo -e "  API key:  $(_D)grep '^KONG_PUBLIC_API_KEY=' .env | cut -d= -f2$(_0)"; \
		echo -e "  Try:      $(_D)curl http://localhost:$$p/auth/v1/health -H \"apikey: <key>\"$(_0)"
	@echo -e "  Docs:     $(_D)QUICKSTART.md · DEPLOYMENT.md · SECURITY.md$(_0)"

release-binaries: nano-build one-build ## Release: extract binocle binaries + sha256 → artifacts/release/ (linux-amd64)
	@mkdir -p artifacts/release
	@for ed in nano one; do \
		cid=$$(docker create binocle-$$ed); \
		docker cp "$$cid:/binocle-$$ed" artifacts/release/binocle-$$ed; \
		docker rm -f "$$cid" >/dev/null; \
		chmod +x artifacts/release/binocle-$$ed; \
	done
	@cd artifacts/release && sha256sum binocle-nano binocle-one | tee checksums.txt
	@echo -e "$(_G)✓ binaries in artifacts/release/ (linux-amd64, FROM-scratch static musl)$(_0)"

release-images: _require-version ## Release: bake + push all suite images to GHCR (VERSION=x.y.z)
	@TAG=$(VERSION) docker buildx bake --push --set "*.platform=linux/amd64" -f docker-bake.hcl default
	@echo -e "$(_G)✓ pushed ghcr.io/univers42/mini-baas/*:$(VERSION) (amd64)$(_0)"

release-check: ## Release: run the pre-tag gate checklist (see RELEASE.md)
	@echo -e "$(_B)Pre-tag checklist (RELEASE.md is the authority)$(_0)"
	@$(MAKE) check-secrets
	@git -C "$(CURDIR)" status --porcelain | grep -q . \
		&& echo -e "  $(_R)✗ working tree dirty$(_0)" \
		|| echo -e "  $(_G)✓ working tree clean$(_0)"
	@[ -f scripts/ci/install.sh ] && echo -e "  $(_G)✓ scripts/ci/install.sh present$(_0)" \
		|| echo -e "  $(_R)✗ scripts/ci/install.sh missing (release asset)$(_0)"
	@echo -e "  $(_D)Remaining (manual): make verify-all · CI green · SDK build+test · tag baas-vX.Y.Z$(_0)"

