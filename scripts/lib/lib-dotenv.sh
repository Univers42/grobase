#!/usr/bin/env bash
# lib-dotenv.sh — what a dotenv KEY line is, and which credentials never go into .env.
#
# Sourced, never executed (scripts/env/assemble-env.sh). One definition of the key
# syntax for config.env, .env.secrets, .env.local and the assembled .env, so the
# orphan check and the withholding rules can never disagree about what a key is.
# Every helper prints key NAMES only; a value is never echoed to a terminal.

# ── key syntax, one definition, for all four files ──────────────────────────
# A key line is an optional `export ` then a POSIX name then `=`. Anything else
# is not a key: notably the `# KEY= (withheld by ...)` lines this script itself
# writes back into `.env`, which would otherwise read as orphans on the next run.
# `KEY=`, `KEY=""` and `KEY=''` are assignments with an EMPTY value and never
# count as an orphan (compose would render them empty anyway).
KEY_RE='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='

# Strip one matching pair of surrounding quotes; "" and '' become empty.
# Ponytail: assumes one plain quote pair — a value that legitimately starts and
# ends with the same quote but is NOT quoted (`x'y`) loses a character. Fine for
# dotenv lines, wrong for hand-mangled ones.
unquote() {
  local v="$1"
  case "$v" in
  '"'*'"' | "'"*"'") v="${v:1:${#v}-2}" ;;
  esac
  printf '%s' "$v"
}

# key_of LINE — the key name LINE assigns, or nothing if it assigns none. The
# `export ` prefix is dropped: .env.secrets carries bare KEY=value lines and a
# name is what every message in assemble-env.sh prints.
key_of() {
  # `|| true` because grep exits 1 on a line that assigns nothing, and pipefail
  # would turn that everyday case into a dead script.
  printf '%s' "$1" | grep -oE "$KEY_RE" |
    sed -E 's/^[[:space:]]*//; s/^export[[:space:]]+//; s/=$//' || true
}

# assigns FILE KEY — whether FILE has a non-comment assignment for KEY. A
# `KEY=` or `KEY=""` counts as assigned: the key is spoken for, only its value
# is blank, and the layer that still names it is not an orphan.
assigns() {
  [ -f "$1" ] || return 1
  grep -qE "^[[:space:]]*(export[[:space:]]+)?$2=" "$1"
}

# env_value FILE KEY — the effective value of KEY in FILE (last assignment wins,
# like every dotenv reader). Empty if unset, commented out or `KEY=`.
env_value() {
  [ -f "$1" ] || return 0
  local line
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" | tail -1 || true)"
  [ -n "$line" ] || return 0
  unquote "${line#*=}"
}

# raw_value FILE KEY — the KEY=... line itself, quoting and all. A migration writes
# THIS, not env_value: unquoting and re-emitting drops the quoting that keeps a
# value containing a space or a `#` in one piece.
raw_value() {
  [ -f "$1" ] || return 0
  grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" || true
}

# set_rhs KEY FILE... — the right-hand side of KEY exactly as written (quotes and
# all) in the first FILE whose last assignment of KEY is non-empty; nothing if no
# file sets it. Layers are passed highest-priority first. Verbatim, because the
# caller re-emits it: re-quoting would change what compose decodes.
set_rhs() {
  local key="$1" file line
  shift
  for file in "$@"; do
    [ -f "$file" ] || continue
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -1 || true)"
    [ -n "$(unquote "${line#*=}")" ] || continue
    printf '%s' "${line#*=}"
    return 0
  done
}

# bare_line LINE — LINE without leading blanks and without an `export ` prefix.
# .env.secrets is a bare KEY=value layer, and the quoting of the original value
# has to survive the round trip: rewriting `KEY="a b"` as `KEY=a b` changes it.
bare_line() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^export[[:space:]]+//'
}

# names_of LINE... — the key names of KEY=value lines, sorted, space separated,
# one line. Every message goes through it: a name is safe to print, the value
# behind it is not. Buckets therefore hold LINES, never bare names — a bare name
# has no `=` for key_of to find and would print as nothing at all.
# Ponytail: sorts and de-duplicates, so two keys sharing a name print once — fine
# here (a duplicate assignment is one key) but it hides a double assignment.
names_of() {
  local line
  # No `printf '\n'` between lines: key_of's output already ends in one, and the
  # extra blank line sorts to the front and paste turns it into a leading space.
  for line in "$@"; do
    key_of "$line"
  done | sort -u | paste -sd' ' -
}

# ── credentials that stay on the host ──────────────────────────────────────
# .env is handed to every container (`env_file: [.env]` in the plane files, vendor
# playground apps included) and every `make env` re-injects it. A token pasted into
# .env.local therefore reached the whole stack (found 2026-09-21).
#   GH_TOKEN_KEYS  a GitHub token, matched by key name or by value shape (ghp_/
#     gho_/ghu_/ghs_/ghr_ classic, github_pat_ fine-grained). Its only consumer in
#     this repo runs on the HOST (scripts/vault/vault-session.mjs) and reads
#     ~/.grobase-gh-pat, mode 600.
#   HOST_ONLY_KEYS a credential no compose service consumes: the deploy targets
#     (FLY_TOKEN, VERCEL_TOKEN — orchestrators/makes/85-fly.mk reads both straight
#     out of .env.local) and the CI/publish credentials (NPM_TOKEN, DOCKER_PAT,
#     DOCKER_LOGIN).
# SONAR_TOKEN is NOT in either list: orchestrators/makes/70-langtiers.mk:53 reads
# it out of .env. Only key NAMES are echoed; the value is never printed.
# Withholding leaves a `# KEY= (...)` comment, which KEY_RE does not match, so a
# withheld key never counts as an orphan on the next run.
GH_TOKEN_KEYS='GITHUB_TOKEN|GITHUB_PAT|GH_TOKEN|GH_PAT|VAULT_GITHUB_TOKEN|GHCR_TOKEN|CR_PAT'
HOST_ONLY_KEYS='FLY_TOKEN|VERCEL_TOKEN|NPM_TOKEN|DOCKER_PAT|DOCKER_LOGIN'
GH_TOKEN_SHAPE='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'

# is_host_only KEY / is_gh_token KEY VALUE — the two withholding rules, defined
# once: local_layer applies them to .env.local and the secrets restore in
# assemble-env.sh refuses to inject the same credential through .env.secrets.
is_host_only() {
  printf '%s' "$1" | grep -qE "^(${HOST_ONLY_KEYS})$"
}
is_gh_token() {
  printf '%s' "$1" | grep -qE "^(${GH_TOKEN_KEYS})$" ||
    printf '%s' "$2" | grep -qE "^[\"']?(${GH_TOKEN_SHAPE})"
}
