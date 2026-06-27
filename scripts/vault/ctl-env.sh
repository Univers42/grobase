#!/bin/sh
# ctl-env.sh push|pull [extra 42ctl flags] — sync this repo's *.env*/*.secrets tree
# to/from the REMOTE vault42 (fly) using the published 42ctl image, no clone/cargo.
#
# The keystore passphrase is read with terminal echo OFF, straight into an env var:
# it never echoes, never appears in argv (so not in `ps` or shell history), and is
# forwarded only into the container via `-e FT_PASSPHRASE`. Because the passphrase
# comes from the env, the docker run needs NO `-it`, so there is no interactive
# prompt to hang on. The push is otherwise SILENT, so the wrapper prints the
# candidate file list up front + a 5s liveness heartbeat + a ✓/✗ status with timing.
set -eu

CTL_IMAGE="${CTL_IMAGE:-docker.io/dlesieur/42ctl:latest}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
REPO_DIR="${REPO_DIR:-$PWD}"
PROJECT="${VAULT_ENV_PROJECT:-grobase}"

[ "$#" -ge 1 ] || { printf 'usage: ctl-env.sh push|pull [flags]\n' >&2; exit 2; }
verb="$1"
shift

ensure_profile() {
	mkdir -p "$CTL_CFG_DIR"
	[ -f "$CTL_CFG_DIR/config.json" ] && return 0
	printf '%s\n' '{"current":"default","profiles":{"default":{"server":"https://vault42.fly.dev","authority":"https://grobase-nano.fly.dev","grobase":"https://grobase-stack.fly.dev"}}}' >"$CTL_CFG_DIR/config.json"
}

# read_passphrase prompts on stderr and reads with terminal echo disabled, so the
# passphrase is never shown and never lands in argv/history. stty is restored even
# if read is interrupted.
read_passphrase() {
	printf 'vault42 keystore passphrase: ' >&2
	stty -echo 2>/dev/null || true
	trap 'stty echo 2>/dev/null || true' EXIT INT TERM
	read -r FT_PASSPHRASE
	stty echo 2>/dev/null || true
	trap - EXIT INT TERM
	printf '\n' >&2
	export FT_PASSPHRASE
}

ensure_profile
[ -f "$CTL_CFG_DIR/keystore.v42" ] || {
	printf 'no keystore at %s — run `make ctl-remote ARGS="keys recover --email <you>"` first\n' "$CTL_CFG_DIR/keystore.v42" >&2
	exit 1
}
read_passphrase

# Preview the *.env*/*.secrets tree about to be pushed, so the scope is visible up
# front (42ctl prints nothing per-file during the encrypt+upload; the vault filters
# vendored/ignored paths further, so this is the candidate set, not the exact upload).
if [ "$verb" = "push" ]; then
	printf '\n[vault42] scanning %s for *.env*/*.secrets…\n' "$REPO_DIR" >&2
	candidates=$(cd "$REPO_DIR" && find . \
		\( -name node_modules -o -name .git -o -name target -o -name dist -o -name build \
		   -o -name .claude -o -name .vault -o -path '*/vendor/*' -o -path '*/baas.bak/*' \) -prune -o \
		-type f \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '*.secrets' -o -name '*.secret' \) -print \
		2>/dev/null | sed 's#^\./##' | sort)
	printf '%s\n' "$candidates" | sed '/^$/d; s/^/  + /' >&2
	n=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
	printf '[vault42] %s candidate file(s) → encrypting locally + uploading to project=%s …\n' "$n" "$PROJECT" >&2
fi

# Liveness heartbeat: the transfer is network-bound and 42ctl is quiet, so emit
# elapsed seconds every 5s — you can always tell it is working, not stuck.
_t0=$(date +%s)
( while :; do sleep 5; printf '[vault42] … working (%ss elapsed)\n' "$(( $(date +%s) - _t0 ))" >&2; done ) &
_hb=$!
# shellcheck disable=SC2064
trap "kill $_hb 2>/dev/null || true" EXIT INT TERM

set +e
docker run --rm --user "$(id -u):$(id -g)" \
	-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
	-e RUST_LOG="${RUST_LOG:-info}" \
	-v "$CTL_CFG_DIR:/cfg" -v "$REPO_DIR:/work" -w /work \
	"$CTL_IMAGE" "$verb" --project "$PROJECT" "$@"
_rc=$?
set -e

kill "$_hb" 2>/dev/null || true
trap - EXIT INT TERM
_dt=$(( $(date +%s) - _t0 ))
if [ "$_rc" -eq 0 ]; then
	printf '[vault42] ✓ %s completed in %ss\n' "$verb" "$_dt" >&2
else
	printf '[vault42] ✗ %s FAILED (exit %s) after %ss — see the error above\n' "$verb" "$_rc" "$_dt" >&2
fi
exit "$_rc"
