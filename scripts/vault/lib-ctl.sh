#!/bin/sh
# lib-ctl.sh — the shared 42ctl plumbing: endpoints, identity, passphrase, runner.
#
# Sourced, never executed, and it sets no shell options of its own.
#
# Every vault42 script needs the same four things, and each one is a place to get it
# wrong in a way that is silent or dangerous:
#   · the ENDPOINTS must be ours. vault42.fly.dev, grobase-nano.fly.dev and
#     grobase-stack.fly.dev are dead, and the first two are other people's apps — a
#     profile seeded with them sends `keys recover` to a stranger's authority.
#   · the IDENTITY must live outside the worktree, or 42ctl's own scanner walks the
#     keystore on a push and the transfer dies with "File exists".
#   · the PASSPHRASE must never reach argv (ps, shell history) — read with echo off
#     into the environment.
#   · the RUNNER must pass --user, or the container writes root-owned files into the
#     caller's config directory.
# Gate m216 holds the first two.

CTL_IMAGE="${CTL_IMAGE:-docker.io/dlesieur/42ctl:latest}"
CTL_CFG_DIR="${CTL_CFG_DIR:-$HOME/.config/42ctl}"
CTL_SERVER="${CTL_SERVER:-https://vault42-server.fly.dev}"
CTL_AUTHORITY="${CTL_AUTHORITY:-https://vault42-authority.fly.dev}"
CTL_BLOB_ENDPOINT="${CTL_BLOB_ENDPOINT:-https://fly.storage.tigris.dev}"
CTL_BLOB_BUCKET="${CTL_BLOB_BUCKET:-vault42-seeds}"

# ctl_ensure_profile writes the default profile when none exists, and never touches
# one that does — an operator's own endpoints outrank these defaults.
#
# `grobase` is EMPTY on purpose: it overrides only the email-code and escrow routes
# and defaults to the authority, which serves them.
ctl_ensure_profile() {
  mkdir -p "$CTL_CFG_DIR" && chmod 700 "$CTL_CFG_DIR" 2>/dev/null || true
  [ -f "$CTL_CFG_DIR/config.json" ] && return 0
  cat >"$CTL_CFG_DIR/config.json" <<JSON
{"current":"default","profiles":{"default":{
  "server":"${CTL_SERVER}",
  "authority":"${CTL_AUTHORITY}",
  "grobase":"",
  "blobs":{"endpoint":"${CTL_BLOB_ENDPOINT}","bucket":"${CTL_BLOB_BUCKET}","region":"auto"}
}}}
JSON
}

# ctl_read_passphrase puts the keystore passphrase in FT_PASSPHRASE, reading it with
# terminal echo disabled so it is never shown and never lands in argv or history.
# A pre-set FT_PASSPHRASE / VAULT42_PASSPHRASE wins (CI, and the make wrappers that
# read it from secrets/vault42-admin.env), so there is no prompt to hang on.
ctl_read_passphrase() {
  if [ -n "${FT_PASSPHRASE:-}" ]; then
    export FT_PASSPHRASE
    return 0
  fi
  if [ -n "${VAULT42_PASSPHRASE:-}" ]; then
    FT_PASSPHRASE="$VAULT42_PASSPHRASE"
    export FT_PASSPHRASE
    return 0
  fi
  printf 'vault42 keystore passphrase: ' >&2
  stty -echo 2>/dev/null || true
  trap 'stty echo 2>/dev/null || true' EXIT INT TERM
  read -r FT_PASSPHRASE
  stty echo 2>/dev/null || true
  trap - EXIT INT TERM
  printf '\n' >&2
  export FT_PASSPHRASE
}

# ctl runs 42ctl from its image with the identity mounted and the passphrase passed
# through the environment. Non-interactive: no -it, so nothing can hang on a prompt.
# Mount the repo as /work only when a verb touches files (push/pull) — ctl_work does that.
ctl() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 \
    -e FT_PASSPHRASE -e FT_PASSWORD -e FT_LOGIN_EMAIL -e FT_REGISTER_TOKEN \
    -e RUST_LOG="${RUST_LOG:-warn}" \
    -v "$CTL_CFG_DIR:/cfg" \
    "$CTL_IMAGE" "$@"
}

# ctl_work is ctl with the repo mounted, for the file-moving verbs.
ctl_work() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 \
    -e FT_PASSPHRASE -e FT_PASSWORD -e FT_LOGIN_EMAIL -e FT_REGISTER_TOKEN \
    -e FT_S3_KEY -e FT_S3_SECRET -e RUST_LOG="${RUST_LOG:-info}" \
    -v "$CTL_CFG_DIR:/cfg" -v "${REPO_DIR:-$PWD}:/work" -w /work \
    "$CTL_IMAGE" "$@"
}

# ctl_require_keystore fails with the recovery command rather than a 42ctl error that
# reads like a bug. A machine with no keystore has an identity problem, not a CLI one.
ctl_require_keystore() {
  [ -f "$CTL_CFG_DIR/keystore.v42" ] && return 0
  printf 'no keystore at %s\n' "$CTL_CFG_DIR/keystore.v42" >&2
  printf '  new machine:  make ctl42 ARGS="keys recover --email <you>"   (emailed code)\n' >&2
  printf '  new identity: make ctl42 ARGS="keys init"                    (then keys escrow)\n' >&2
  return 1
}
