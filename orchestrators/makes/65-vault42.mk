# Secrets via the shared vault42 CLI (submodule vendor/scripts, config vault42.conf).
#
# TARGET, APPLY, YES (and KIND, ONLY, FILE, KEY) count only when typed on the make command
# line: an exported TARGET=prod or APPLY=1 in a shell profile must never aim or confirm a
# vault write.
# Caveat: `$(origin)` also reports `make -e` / MAKEFLAGS overrides as "command line"; that
# is an explicit operator act, not an ambient one.
#
# VM: no docker0 -> export VAULT42_DOCKER_NETWORK=host. The VM needs its own 42ctl identity,
# granted only grobase envs (operator decision; this tool copies no keystore).
#
# vault42-push: grobase/dev was pushed from a stage of 15 files, not from this checkout, so
# the first `make vault42-push TARGET=dev` is run by the operator, after `make vault42-diff`
# and the C18 drill (push to a throwaway env, `pull --apply` into an empty dir, `diff -r`).
_v42_arg  = $(if $(filter command line,$(origin $(1))),$($(1)))
_V42_SH   = vendor/scripts/vault42/vault42.sh
# CTL_IMAGE is not exported by 80-ops.mk, and the VM has no native 42ctl: without it the CLI
# finds no runner there.
_V42      = CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" bash $(_V42_SH) --config vault42.conf --target $(or $(call _v42_arg,TARGET),dev)
_V42_KIND = $(foreach k,$(call _v42_arg,KIND),--kind $(k))
_V42_REQ  = test -f $(_V42_SH) || { echo "vault42: $(_V42_SH) missing; run: git submodule update --init vendor/scripts" >&2; exit 1; }

##@ Secrets (vault42)
vault42-status: ## vault42 doctor: 42ctl, env, session, key (read-only; VM: VAULT42_DOCKER_NETWORK=host)
	@$(_V42_REQ); $(_V42) doctor
vault42-login: ## vault42 login (FT_EMAIL FT_PASSWORD FT_TENANT from the environment)
	@$(_V42_REQ); $(_V42) login
vault42-list: ## Files the vault holds (KIND=env|secrets|volumes|all)
	@$(_V42_REQ); $(_V42) $(_V42_KIND) list
vault42-diff: ## What a push or pull would change, by size (KIND=)
	@$(_V42_REQ); $(_V42) $(_V42_KIND) diff
vault42-pull: ## Preview the vault's files; APPLY=1 restores (ONLY="a b" KIND=; command line only)
	@$(_V42_REQ); $(_V42) $(_V42_KIND) pull $(if $(call _v42_arg,APPLY),--apply) $(foreach f,$(call _v42_arg,ONLY),--only $(f))
vault42-push: ## Replace the vault tree (FILE="a b" YES=1); the first dev push is the operator's
## Run `make vault42-diff` and the C18 drill first: grobase/dev was pushed from a 15-file stage,
## not from this checkout.
	@$(_V42_REQ); $(_V42) $(_V42_KIND) push $(if $(call _v42_arg,YES),--yes) $(call _v42_arg,FILE)
vault42-secret-get: ## Print one vault secret (KEY=path)
	@$(_V42_REQ); test -n "$(call _v42_arg,KEY)" || { echo "vault42-secret-get: KEY=path required" >&2; exit 2; }; $(_V42) secret get $(call _v42_arg,KEY)
vault42-secret-set: ## Set one vault secret from stdin (KEY=path)
	@$(_V42_REQ); test -n "$(call _v42_arg,KEY)" || { echo "vault42-secret-set: KEY=path required (value on stdin)" >&2; exit 2; }; $(_V42) secret set $(call _v42_arg,KEY)
