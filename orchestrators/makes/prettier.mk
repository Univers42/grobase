# ========================================================================== #
##@ Formatters — `make prettiers` runs every technology's canonical formatter
# ========================================================================== #
# The write-side mirror of the test-lint matrix: one target per language, each
# running that language's CANONICAL formatter IN DOCKER (Docker-first), in place.
# `prettiers` runs them all; `prettiers-check` verifies WITHOUT writing (CI gate).
#   go    → gofumpt   (stricter gofmt superset — the project formatter)
#   rust  → cargo fmt (rustfmt; data-plane + realtime workspaces)
#   ts    → prettier  (the project's `npm run format`, honouring src/.prettierrc)
#   shell → shfmt -i 2 (the repo's dominant 2-space style)
#   yaml  → prettier  (compose + config)

PRETTIER_KINDS := prettier-go prettier-rust prettier-ts prettier-shell prettier-yaml

# Pinned, not @latest: gofumpt v0.12 declares `go >= 1.26`, and the toolchain
# image is golang:1.25-bookworm with GOTOOLCHAIN=local, so @latest fails to
# install. v0.8.0 is the newest that builds under Go 1.25. Bump both together.
GOFUMPT_VERSION ?= v0.8.0
# Pinned so a new shfmt release cannot turn CI red on an unchanged tree.
SHFMT_IMG ?= mvdan/shfmt:v3.10.0
# The repo's own shell: vendor/ is third-party code in its authors' style.
SH_OWN = $$(git ls-files '*.sh' ':!:vendor/**')

prettiers: ## Format EVERY technology in place (gofumpt · rustfmt · prettier · shfmt)
	@for t in $(PRETTIER_KINDS); do \
		echo -e "\n$(_B)──────── $$t ────────$(_0)"; \
		$(MAKE) --no-print-directory $$t || exit 1; \
	done; \
	echo -e "\n$(_G)✓ prettiers: all technologies formatted$(_0)"

prettier-go: ## Format Go — gofumpt (control plane, in Docker)
	@docker run --rm -v "$(CURDIR)/src/control-plane":/src -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build golang:1.25-bookworm \
		sh -c 'go install mvdan.cc/gofumpt@$(GOFUMPT_VERSION) >/dev/null && /go/bin/gofumpt -w .' \
		&& echo -e "$(_G)✓ go (gofumpt)$(_0)"

prettier-rust: _rust-toolchain ## Format Rust — cargo fmt (data-plane + realtime, in Docker)
	@$(CARGO_DPR) cargo fmt --all
	@$(CARGO_REALTIME) cargo fmt --all
	@echo -e "$(_G)✓ rust (cargo fmt)$(_0)"

prettier-ts: ## Format TypeScript — prettier via src/.prettierrc (apps/libs, in Docker)
	@$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund >/dev/null 2>&1 && npm run format' \
		&& echo -e "$(_G)✓ ts (prettier)$(_0)"

prettier-shell: ## Format shell — shfmt, 2-space (the repo's dominant style; vendor/ excluded, in Docker)
	@docker run --rm -v "$(CURDIR)":/d -w /d $(SHFMT_IMG) -w -i 2 $(SH_OWN) \
		&& echo -e "$(_G)✓ shell (shfmt)$(_0)"

prettier-yaml: ## Format YAML — prettier (compose + config, in Docker)
	@docker run --rm -v "$(CURDIR)":/repo -w /repo -v mini-baas-npm-cache:/root/.npm $(NODE_IMAGE) \
		sh -c 'npx --yes prettier@3.4.2 --write "orchestrators/compose/**/*.yml" "infra/config/**/*.{yml,yaml}" docker-compose.yml' \
		&& echo -e "$(_G)✓ yaml (prettier)$(_0)"

prettiers-check: _rust-toolchain ## Verify every technology is formatted (no writes; non-zero if not — CI gate)
	@rc=0; \
	echo -e "$(_B)── go ──$(_0)"; \
	docker run --rm -v "$(CURDIR)/src/control-plane":/src -w /src -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build golang:1.25-bookworm \
		sh -c 'go install mvdan.cc/gofumpt@$(GOFUMPT_VERSION) >/dev/null || exit 1; o=$$(/go/bin/gofumpt -l .); [ -z "$$o" ] || { echo "$$o"; exit 1; }' || rc=1; \
	echo -e "$(_B)── rust ──$(_0)"; \
	$(CARGO_DPR) cargo fmt --all --check || rc=1; \
	$(CARGO_REALTIME) cargo fmt --all --check || rc=1; \
	echo -e "$(_B)── ts ──$(_0)"; \
	$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund >/dev/null 2>&1; npx prettier --check "apps/**/*.ts" "libs/**/*.ts"' || rc=1; \
	echo -e "$(_B)── shell ──$(_0)"; \
	o=$$(docker run --rm -v "$(CURDIR)":/d -w /d $(SHFMT_IMG) -l -i 2 $(SH_OWN)); [ -z "$$o" ] || { echo "$$o"; rc=1; }; \
	echo -e "$(_B)── yaml ──$(_0)"; \
	docker run --rm -v "$(CURDIR)":/repo -w /repo -v mini-baas-npm-cache:/root/.npm $(NODE_IMAGE) \
		sh -c 'npx --yes prettier@3.4.2 --check "orchestrators/compose/**/*.yml" "infra/config/**/*.{yml,yaml}" docker-compose.yml' || rc=1; \
	[ $$rc -eq 0 ] && echo -e "$(_G)✓ all formatted$(_0)" || { echo -e "$(_R)✗ formatting needed — run: make prettiers$(_0)"; exit 1; }

.PHONY: prettiers prettiers-check $(PRETTIER_KINDS)
