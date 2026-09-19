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
# Shared-environment coordinates. BOTH set → the TEAM path (`env push`/`env pull`,
# sealed to the ENVIRONMENT's key, so every member the authority granted can read
# the tree). Either unset → the personal path (`push`/`pull`, sealed to the caller
# ALONE and readable by nobody else). That distinction is the whole ballgame: a
# teammate pulling a tree pushed the personal way gets "no manifest for project X"
# no matter what org role they hold, because it is encryption, not RBAC.
ORG="${VAULT_ENV_ORG:-}"
ENVNAME="${VAULT_ENV_NAME:-}"

[ "$#" -ge 1 ] || { printf 'usage: ctl-env.sh push|pull [flags]\n' >&2; exit 2; }
verb="$1"
shift

# The seeded profile is what a machine with no ~/.config/42ctl gets, so these hosts
# must be OUR deployments. vault42.fly.dev and grobase-nano.fly.dev are NOT: they are
# unrelated apps owned by other people that happen to hold the names we wanted. A
# fresh machine seeded with those authenticates against a stranger's authority.
# `blobs` is part of the profile because files above the 4 MiB transport ceiling are
# stored as chunks in the object store — without it a pull silently restores only the
# small files. The credential for it stays OUT of here; it is fetched from the vault
# itself further down (ctl_vault_get).
ensure_profile() {
	mkdir -p "$CTL_CFG_DIR"
	[ -f "$CTL_CFG_DIR/config.json" ] && return 0
	cat >"$CTL_CFG_DIR/config.json" <<-'JSON'
	{"current":"default","profiles":{"default":{
	  "server":"https://vault42-server.fly.dev",
	  "authority":"https://vault42-authority.fly.dev",
	  "grobase":"https://grobase-stack.fly.dev",
	  "blobs":{"endpoint":"https://fly.storage.tigris.dev","bucket":"vault42-seeds","region":"auto"}
	}}}
	JSON
}

# read_passphrase prompts on stderr and reads with terminal echo disabled, so the
# passphrase is never shown and never lands in argv/history. stty is restored even
# if read is interrupted.
read_passphrase() {
	# Non-interactive (CI / automation): honor a pre-set FT_PASSPHRASE (42ctl's own
	# documented CI env var) or VAULT42_PASSPHRASE as a friendlier alias — no TTY, no
	# prompt to hang on. This is what lets the GitHub Action pull with no mail/OTP.
	if [ -n "${FT_PASSPHRASE:-}" ]; then export FT_PASSPHRASE; return 0; fi
	if [ -n "${VAULT42_PASSPHRASE:-}" ]; then FT_PASSPHRASE="$VAULT42_PASSPHRASE"; export FT_PASSPHRASE; return 0; fi
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
# A LOWER BOUND, not the upload. 42ctl's scanner also descends git repositories parked inside
# skipped directories (vendor/<repo>/.env is stored, vendor/<plain-dir>/.env is not), which
# `find` cannot express without walking every prune candidate — measured 43 here against 50
# actually scanned. Reimplementing a Rust walker in find is how the two drift apart silently,
# so this says "at least" and 42ctl stays the authority. The point is the ORDER of magnitude:
# you are about to send tens of MB, not a handful of dotfiles.
#
# 42ctl takes EVERY regular file under a directory named secrets/ or .secrets/, whatever
# its name, on top of the *.env*/*.secrets patterns — that is how a CA key, a mongo
# rs-keyfile and the engine dumps travel at all (they are named for what they hold, never
# for the fact that they are secret). A preview that lists only the pattern matches
# under-reports the upload by exactly the files that make it big: measured on this monorepo,
# 28 listed against 50 actually scanned and 43 MB actually sent. A preview that understates
# the scope is worse than none — it is the number you check the transfer against.
if [ "$verb" = "push" ]; then
	printf '\n[vault42] scanning %s for *.env*/*.secrets + every file under secrets/…\n' "$REPO_DIR" >&2
	candidates=$(cd "$REPO_DIR" && find . \
		\( -name node_modules -o -name .git -o -name target -o -name dist -o -name build \
		   -o -name .claude -o -name .vault -o -path '*/vendor/*' -o -path '*/baas.bak/*' \) -prune -o \
		-type f \( -name '*.env*' -o -name '*.secrets' -o -name '*.secret' \
		   -o -path '*/secrets/*' -o -path './secrets/*' -o -path '*/.secrets/*' \) -print \
		2>/dev/null | sed 's#^\./##' | sort)
	printf '%s\n' "$candidates" | sed '/^$/d; s/^/  + /' >&2
	n=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
	# `du -k` per file rather than one bulk call: xargs -d/-0 and du -b are GNU-only, and a
	# preview that dies on a non-GNU box is a preview nobody trusts. 50-odd forks, once.
	kb=$(cd "$REPO_DIR" && printf '%s\n' "$candidates" | sed '/^$/d' | \
		while IFS= read -r f; do du -k "$f" 2>/dev/null; done | awk '{t+=$1} END{print t+0}')
	printf '[vault42] at least %s file(s), %s MB → encrypting locally + uploading to project=%s …\n' \
		"$n" "$(( ${kb:-0} / 1024 ))" "$PROJECT" >&2
fi

# A push from the repo ROOT mirrors the tree: --prune drops vault entries whose file
# is gone/now-ignored, so node_modules/vendor noise self-cleans on the next push.
_prune=""
[ "$verb" = "push" ] && _prune="--prune"

# Liveness heartbeat: the transfer is network-bound and 42ctl is quiet, so emit
# elapsed seconds every 5s — you can always tell it is working, not stuck.
_t0=$(date +%s)
( while :; do sleep 5; printf '[vault42] … working (%ss elapsed)\n' "$(( $(date +%s) - _t0 ))" >&2; done ) &
_hb=$!
# shellcheck disable=SC2064
trap "kill $_hb 2>/dev/null || true" EXIT INT TERM

# A file above the transport ceiling (a volume dump) is stored as CHUNKS in an object
# store, and that credential is deliberately not in config.json — it lives in the vault
# itself. Without it the pull dies partway through with "FT_S3_KEY and FT_S3_SECRET are not
# set", which on a fresh machine is the difference between restoring the tree and restoring
# most of it and reporting failure. The credential is a small secret, so fetching it needs
# no object store: one `vault get` before the run that needs it.
#
# Not fatal when absent: a tree with no chunked file pulls perfectly well without it, and a
# vault that has no infra/S3_KEY simply yields empty here.
ctl_vault_get() {
	# In TEAM mode, look in the shared ENVIRONMENT first: a secret set there is
	# readable by every member granted the project, so a new teammate needs no
	# per-person re-share. `42ctl vault get` reads the PERSONAL vault, which on a
	# teammate's machine is empty — they would hit "FT_S3_KEY and FT_S3_SECRET are
	# not set" on the first file above the 4 MiB ceiling and restore only the small
	# half of the tree. Falls back to the personal vault so a machine that has the
	# credential sealed to itself (the original pusher's) keeps working unchanged.
	if [ -n "$ORG" ] && [ -n "$ENVNAME" ]; then
		_v=$(docker run --rm --user "$(id -u):$(id -g)" \
			-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
			-v "$CTL_CFG_DIR:/cfg" "$CTL_IMAGE" \
			env secret get --org "$ORG" --project "$PROJECT" --env "$ENVNAME" "$1" 2>/dev/null || true)
		if [ -n "$_v" ]; then
			printf '%s' "$_v"
			return 0
		fi
	fi
	docker run --rm --user "$(id -u):$(id -g)" \
		-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
		-v "$CTL_CFG_DIR:/cfg" "$CTL_IMAGE" vault get "$1" 2>/dev/null || true
}

if [ -z "${FT_S3_KEY:-}" ] || [ -z "${FT_S3_SECRET:-}" ]; then
	printf '[vault42] fetching the object-store credential from the vault…\n' >&2
	FT_S3_KEY="$(ctl_vault_get infra/S3_KEY)"
	FT_S3_SECRET="$(ctl_vault_get infra/S3_SECRET)"
	export FT_S3_KEY FT_S3_SECRET
	# Say whether it landed — never the value. Empty here and the run dies further down
	# with "FT_S3_KEY and FT_S3_SECRET are not set", which reads as "you forgot to export
	# them" when the real cause is "the vault has no infra/S3_KEY" or "the keystore could
	# not be opened". Same message, three causes: name which one before the failure.
	if [ -n "$FT_S3_KEY" ] && [ -n "$FT_S3_SECRET" ]; then
		printf '[vault42] ✓ object-store credential loaded from the vault (infra/S3_KEY)\n' >&2
	else
		printf '[vault42] ! the vault returned no infra/S3_KEY / infra/S3_SECRET.\n' >&2
		printf '[vault42] ! Files above the 4 MiB ceiling cannot travel. Check with:\n' >&2
		printf '[vault42] !   42ctl vault ls | grep infra/\n' >&2
		printf '[vault42] ! then seal them once: 42ctl vault set infra/S3_KEY / infra/S3_SECRET\n' >&2
	fi
fi

# Build the 42ctl argv for the selected mode. The env verbs take a DIFFERENT flag
# set from the personal ones — neither --prune nor --force exists there — so those
# are dropped with a note rather than allowed to fail the whole transfer. `env pull`
# offers --backup for what --force approximated; it is passed through untouched.
if [ -n "$ORG" ] && [ -n "$ENVNAME" ]; then
	_n=$#
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_a="$1"
		shift
		case "$_a" in
		--prune | --force)
			printf '[vault42] note: %s is not a shared-environment flag — dropped\n' "$_a" >&2
			;;
		*) set -- "$@" "$_a" ;;
		esac
		_i=$((_i + 1))
	done
	printf '[vault42] mode: SHARED environment %s/%s/%s — sealed to the env key\n' \
		"$ORG" "$PROJECT" "$ENVNAME" >&2
	set -- env "$verb" --org "$ORG" --project "$PROJECT" --env "$ENVNAME" "$@"
elif [ -n "$_prune" ]; then
	printf '[vault42] mode: PERSONAL project %s — sealed to you alone\n' "$PROJECT" >&2
	set -- "$verb" --project "$PROJECT" "$_prune" "$@"
else
	printf '[vault42] mode: PERSONAL project %s — sealed to you alone\n' "$PROJECT" >&2
	set -- "$verb" --project "$PROJECT" "$@"
fi

set +e
docker run --rm --user "$(id -u):$(id -g)" \
	-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
	-e FT_S3_KEY -e FT_S3_SECRET \
	-e RUST_LOG="${RUST_LOG:-info}" \
	-v "$CTL_CFG_DIR:/cfg" -v "$REPO_DIR:/work" -w /work \
	"$CTL_IMAGE" "$@"
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
