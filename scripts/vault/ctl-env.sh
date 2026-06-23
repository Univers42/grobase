#!/bin/sh
# ctl-env.sh push|pull [extra 42ctl flags] — sync this repo's *.env*/*.secrets tree
# to/from the REMOTE vault42 (fly) using the published 42ctl image, no clone/cargo.
#
# The keystore passphrase is read with terminal echo OFF, straight into an env var:
# it never echoes, never appears in argv (so not in `ps` or shell history), and is
# forwarded only into the container via `-e FT_PASSPHRASE`. Because the passphrase
# comes from the env, the docker run needs NO `-it`, so there is no interactive
# prompt to hang on. RUST_LOG=info prints each file as it is encrypted/uploaded.
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

exec docker run --rm \
	-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
	-e RUST_LOG="${RUST_LOG:-info}" \
	-v "$CTL_CFG_DIR:/cfg" -v "$REPO_DIR:/work" -w /work \
	"$CTL_IMAGE" "$verb" --project "$PROJECT" "$@"
