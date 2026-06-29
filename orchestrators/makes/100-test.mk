# ========================================================================== #
##@ Full test matrix (one target per kind; `make tests` runs them ALL)
# ========================================================================== #
# Each test-* target wraps ONE real test mechanism and is pass/fail. The root
# `tests` target runs the whole matrix in one go and prints a green/red summary.
# Source-level targets need no live stack; the "live" group needs `make up`.

# ── source-level unit tests (no live stack) ──────────────────────────────────
test-go: ## Go: vet + go test ./... (control plane, in Docker)
	@$(MAKE) --no-print-directory go-control-plane-check

test-rust-data: ## Rust: cargo test the data-plane workspace (in Docker)
	@$(MAKE) --no-print-directory rust-data-plane-test

test-rust-realtime: ## Rust: cargo test the realtime workspace (in Docker)
	@$(MAKE) --no-print-directory rust-realtime-test

test-rust: test-rust-data test-rust-realtime ## Rust: both workspaces (data-plane + realtime)

test-nestjs: ## TS: tsc + eslint + jest for apps/libs (in Docker)
	@$(MAKE) --no-print-directory nestjs-ci

test-sdk: ## SDKs: js node:test + js catalog (m10) + polyglot compile gates (py/dart m58, swift m62, kotlin m63)
	@rc=0; \
	$(MAKE) --no-print-directory sdk-test || rc=1; \
	for g in m10-sdk m58-sdks-compile m62-sdk-swift m63-sdk-kotlin; do \
		echo -e "$(_B)→ scripts/verify/$$g.sh$(_0)"; bash scripts/verify/$$g.sh || rc=1; done; \
	exit $$rc

# ── quality / supply-chain / security (no live stack) ────────────────────────
# ── Linters: one per language/format. test-lint runs them ALL — STRICT: any
# error OR warning fails. Accepted-style rules are declared in committed project
# configs (.shellcheckrc · .hadolint.yaml · .yamllint), each with justification —
# not silenced inline. So a finding here is a real issue to fix.
LINT_KINDS := test-lint-shell test-lint-rust test-lint-go test-lint-ts test-lint-yaml test-lint-docker test-lint-make

test-lint-shell: ## Lint shell — bash -n (all) + shellcheck (honours .shellcheckrc), warnings fail
	@rc=0; for f in $$(git ls-files '*.sh' 2>/dev/null); do bash -n "$$f" || { echo -e "$(_R)  parse: $$f$(_0)"; rc=1; }; done; \
	if command -v shellcheck >/dev/null 2>&1; then \
		for f in $$(git ls-files '*.sh' 2>/dev/null); do shellcheck "$$f" || rc=1; done; \
	else echo -e "$(_D)  (host shellcheck absent — bash -n only)$(_0)"; fi; \
	[ $$rc -eq 0 ] && echo -e "$(_G)✓ shell$(_0)" || exit 1

test-lint-rust: _rust-toolchain ## Lint Rust — cargo clippy -D warnings (data-plane workspace, in Docker)
	@$(CARGO_DPR) sh -c 'rustup component add clippy >/dev/null 2>&1 || true; cargo clippy --workspace --all-targets -- -D warnings' \
		&& echo -e "$(_G)✓ rust clippy (zero warnings)$(_0)"

test-lint-go: ## Lint Go — go vet + gofmt (control plane, in Docker)
	@docker run --rm -v "$(CURDIR)/src/control-plane":/src -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build golang:1.25-bookworm \
		sh -c 'GOFLAGS=-mod=mod go vet ./... && o=$$(gofmt -l . | grep -v "^vendor/" || true); [ -z "$$o" ] || { echo -e "$(_R)  gofmt needs: $$o$(_0)"; exit 1; }' \
		&& echo -e "$(_G)✓ go vet+fmt$(_0)"

test-lint-ts: ## Lint TypeScript — eslint over apps/libs (in Docker)
	@$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund >/dev/null 2>&1; npx eslint "apps/**/*.ts" "libs/**/*.ts"' \
		&& echo -e "$(_G)✓ ts eslint$(_0)"

test-lint-yaml: ## Lint YAML — yamllint with the committed .yamllint policy (warnings fail, in Docker)
	@docker run --rm -v "$(CURDIR)":/d -w /d cytopia/yamllint:latest -c .yamllint \
		orchestrators/compose infra/config docker-compose.yml \
		&& echo -e "$(_G)✓ yaml$(_0)"

test-lint-docker: ## Lint Dockerfiles — hadolint with the committed .hadolint.yaml policy (warnings fail, in Docker)
	@rc=0; for df in $$(git ls-files '*Dockerfile*' 2>/dev/null | grep -vE 'node_modules|(^|/)vendor/'); do \
		docker run --rm -i -v "$(CURDIR)/.hadolint.yaml":/cfg.yaml hadolint/hadolint hadolint --config /cfg.yaml - < "$$df" \
			|| { echo -e "$(_R)  $$df$(_0)"; rc=1; }; done; \
	[ $$rc -eq 0 ] && echo -e "$(_G)✓ dockerfiles$(_0)" || exit 1

test-lint-make: ## Lint Makefiles — parse-validate (make + every fragment must parse with no warnings)
	@if make -np >/dev/null 2>/tmp/mk-lint.$$$$; then \
		if [ -s /tmp/mk-lint.$$$$ ]; then echo -e "$(_R)  make warnings:$(_0)"; cat /tmp/mk-lint.$$$$; rm -f /tmp/mk-lint.$$$$; exit 1; \
		else rm -f /tmp/mk-lint.$$$$; echo -e "$(_G)✓ make (parses clean, no warnings)$(_0)"; fi; \
	else cat /tmp/mk-lint.$$$$; rm -f /tmp/mk-lint.$$$$; echo -e "$(_R)  Makefile parse error$(_0)"; exit 1; fi

test-lint: ## Lint EVERYTHING (shell·rust·go·ts·yaml·docker·make) — runs all, shows each, summary
	@pass=0; fail=0; failed=""; \
	for t in $(LINT_KINDS); do \
		echo -e "\n$(_B)──────── $$t ────────$(_0)"; \
		if $(MAKE) --no-print-directory $$t; then pass=$$((pass+1)); else fail=$$((fail+1)); failed="$$failed $$t"; fi; \
	done; \
	echo -e "\n$(_W)lint matrix: $$pass clean / $$fail with errors$(_0)"; \
	[ $$fail -eq 0 ] && echo -e "$(_G)✓ ALL LINTERS CLEAN$(_0)" || { echo -e "$(_R)✗ lint errors:$$failed$(_0)"; exit 1; }

test-deps: ## Dependencies: supply-chain CVE scan (cargo-audit + govulncheck)
	@$(MAKE) --no-print-directory audit-deps

test-scan: ## Security scanning: hardcoded-secret scan + security battery (semgrep/etc.)
	@rc=0; \
	$(MAKE) --no-print-directory check-secrets || rc=1; \
	if [ -x scripts/security/run-security-scans.sh ]; then bash scripts/security/run-security-scans.sh || rc=1; \
	else echo -e "$(_D)scripts/security/run-security-scans.sh absent — secret scan only$(_0)"; fi; \
	exit $$rc

test-sonar: ## SonarCloud: regenerate coverage + run the scanner (needs SONAR_TOKEN in env/.env)
	@$(MAKE) --no-print-directory sonar-scan

# ── benchmark (measurement; green = ran + produced an artifact) ──────────────
test-bench: ## Benchmark: footprint of the running stack → artifacts/bench/ (non-disruptive measurement)
	@$(MAKE) --no-print-directory bench-footprint

# ── live-stack integration (need `make up` first) ────────────────────────────
# Discover the live kong host port (8000 may be taken, so resolve-ports bumps it).
_kong_base = http://127.0.0.1:$(shell docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' | grep -E '^[0-9]+$$' || echo 8000)

test-scripts: ## Scripting: the phase smoke suite vs the live stack (auto-discovers kong's host port + a kong-allowed CORS origin)
	@BASE_URL="$(_kong_base)" TEST_ORIGIN="https://localhost:3000" $(MAKE) --no-print-directory test-smoke

test-conformance: ## Engine conformance gate (m27) across the live engines
	@$(MAKE) --no-print-directory conformance

test-postman: ## Postman/newman: offers + edge corpus vs the live stack (builds the htmlextra newman image if missing)
	@docker image inspect mini-baas-newman:local >/dev/null 2>&1 || \
		docker build -q -t mini-baas-newman:local infra/docker/services/newman >/dev/null
	@export BASE_URL="$(_kong_base)"; rc=0; \
	$(MAKE) --no-print-directory test-offers || rc=1; \
	$(MAKE) --no-print-directory test-edge || rc=1; exit $$rc

test-waf: ## WAF: confirm SQLi/XSS are blocked at the edge
	@$(MAKE) --no-print-directory waf-test

test-gates: ## Verify-gate battery (curated --fast set via run-gate-battery)
	@if [ -x scripts/verify/run-gate-battery.sh ]; then bash scripts/verify/run-gate-battery.sh --fast; \
	else $(MAKE) --no-print-directory verify-all; fi
