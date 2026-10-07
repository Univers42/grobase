#!/bin/sh
# grobase-team-setup.sh — provision the vault42 structure grobase's secrets live in.
#
#   org <-- exists already, never created twice
#     team
#       project
#         environment  (local dev staging prod)
#           scope key  (X25519; sealed per environment)
#           grant      (team role, per environment)
#
# IDEMPOTENT BY CONSTRUCTION: every step lists or probes before it creates, and a
# "already exists" answer (HTTP 409) is success, not failure. Run it twice and the
# second run creates nothing. That is the whole point — this structure was first
# provisioned by hand, which is not a thing anyone can repeat or audit.
#
# It never DELETES. A name collision is reported and the script stops: an org or
# project may hold another member's data, and in a zero-knowledge store a deletion
# cannot be undone.
#
# Ponytail: idempotence is per STEP, not transactional. Interrupted midway it leaves
# the earlier steps in place, which is why re-running is the recovery path. The one
# step that is not purely additive is `env init`, which self-heals an interrupted
# bootstrap by advancing the key epoch — expected, and it prints when it does.
#
# usage: grobase-team-setup.sh [--project NAME] [--org SLUG] [--team SLUG] [--envs "a b"]
#        grobase-team-setup.sh --help
# exit:  0 provisioned (or already in place) · 1 a step failed · 2 misuse
#        3 no keystore / not logged in
set -eu

# shellcheck disable=SC1007  # `CDPATH= cd` intentionally clears CDPATH for the cd
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007  # same
REPO_DIR="${REPO_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)}"
export REPO_DIR
# shellcheck source=lib-ctl.sh
. "$SCRIPT_DIR/lib-ctl.sh"

ORG="${VAULT_ENV_ORG:-univers-42}"
ORG_NAME="${VAULT42_ORG_NAME:-Univers42}"
TEAM="${VAULT42_TEAM:-transcendence}"
TEAM_NAME="${VAULT42_TEAM_NAME:-Transcendence}"
PROJECT="${VAULT_ENV_PROJECT:-grobase}"
ENVS="${VAULT42_ENVS:-local dev staging prod}"
# Env-scoped roles. Least privilege: the team rotates dev freely, production is
# admin-only, so a compromised teammate laptop cannot rewrite prod secrets.
WRITE_ENVS="${VAULT42_WRITE_ENVS:-local dev}"

usage() {
  sed -n '/^# usage:/,/^#        3 no keystore/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --help | -h)
    usage
    exit 0
    ;;
  --org)
    ORG="${2:?--org needs a slug}"
    shift 2
    ;;
  --team)
    TEAM="${2:?--team needs a slug}"
    shift 2
    ;;
  --project)
    PROJECT="${2:?--project needs a name}"
    shift 2
    ;;
  --envs)
    ENVS="${2:?--envs needs a list}"
    shift 2
    ;;
  *)
    printf 'unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

say() { printf '\033[0;36m▶ %s\033[0m\n' "$1" >&2; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$1" >&2; }
note() { printf '  · %s\n' "$1" >&2; }
die() {
  printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2
  exit "${2:-1}"
}

# ── identity ─────────────────────────────────────────────────────────────────
ctl_ensure_profile
ctl_require_keystore || exit 3
ctl_read_passphrase

# A session AND a contract are both needed: the authority issues the session (accounts,
# orgs, projects) and the gRPC store requires a contract bound to it. Missing either
# produces errors that read like permission problems.
ctl auth status 2>/dev/null | grep -q 'logged in' ||
  die "not logged in — make ctl42 ARGS=\"auth login --password --email <you>\"" 3

# ── org: find, never create a second one ─────────────────────────────────────
# There is no list-orgs endpoint, so existence is probed by trying to create: 409
# means it is already there, which is the normal path on every run after the first.
say "org ${ORG} (${ORG_NAME})"
if out=$(ctl org create --slug "$ORG" --name "$ORG_NAME" 2>&1); then
  ok "created org ${ORG}"
else
  case "$out" in
  *409*) ok "org ${ORG} already exists" ;;
  *) die "org ${ORG}: ${out}" ;;
  esac
fi

say "team ${TEAM} (${TEAM_NAME})"
if out=$(ctl team create --org "$ORG" --slug "$TEAM" --name "$TEAM_NAME" 2>&1); then
  ok "created team ${TEAM}"
else
  case "$out" in
  *409*) ok "team ${TEAM} already exists" ;;
  *) die "team ${TEAM}: ${out}" ;;
  esac
fi

say "project ${PROJECT}"
if out=$(ctl project create --org "$ORG" --slug "$PROJECT" --name "$PROJECT" 2>&1); then
  ok "created project ${PROJECT}"
else
  case "$out" in
  *409*) ok "project ${PROJECT} already exists" ;;
  *) die "project ${PROJECT}: ${out}" ;;
  esac
fi

# ── environments + their scope keys ──────────────────────────────────────────
# `env create` is additive; `env init` generates the X25519 scope keypair, publishes
# the PUBLIC half to the environment row and self-wraps the private half to the
# caller. Without init an environment exists but nothing can be sealed into it.
say "environments: ${ENVS}"
for e in $ENVS; do
  if out=$(ctl env create --project "$PROJECT" --name "$e" 2>&1); then
    ok "created environment ${e}"
  else
    case "$out" in
    *409* | *exists*) note "environment ${e} already exists" ;;
    *) die "env ${e}: ${out}" ;;
    esac
  fi
done

say "scope keys"
for e in $ENVS; do
  # `env init` REFUSES an environment that already has a scope key, because a second
  # init would orphan the wraps of every provisioned member. For this script that
  # refusal IS the success condition — the key exists, which is all we wanted. Only
  # `env keys rotate` may replace one, and that is a deliberate operator act (it
  # re-seals everything), never something a provisioning re-run should do.
  if out=$(ctl env init --org "$ORG" --project "$PROJECT" --env "$e" 2>&1); then
    case "$out" in
    *"never received"*) note "${e}: completed an interrupted bootstrap (epoch advanced)" ;;
    *) : ;;
    esac
    ok "scope key created for ${e}"
  else
    case "$out" in
    *"already has a scope key"*)
      note "${e}: scope key already present ($(printf '%s' "$out" |
        sed -n 's/.*\(epoch [0-9]*\).*/\1/p'))"
      ;;
    *) die "env init ${e}: ${out}" ;;
    esac
  fi
done

# ── grants: env-scoped, least privilege ──────────────────────────────────────
say "team grants (write: ${WRITE_ENVS}; read: everything else)"
for e in $ENVS; do
  role='read'
  for w in $WRITE_ENVS; do
    [ "$e" = "$w" ] && role='write'
  done
  if out=$(ctl team grant --org "$ORG" --team "$TEAM" --project "$PROJECT" \
    --env "$e" --role "$role" 2>&1); then
    ok "${TEAM} ${role} on ${e}"
  else
    case "$out" in
    *409* | *exists*) note "${TEAM} already granted on ${e}" ;;
    *) die "grant ${e}: ${out}" ;;
    esac
  fi
done

# ── wrap the scope keys to the members who may read them ─────────────────────
# A grant says a member MAY read; the wrap is what lets them. sync-keys wraps each
# environment's scope key to every authorized member who has published a public key.
# A member who has not run `keys enroll` cannot be wrapped to — their key does not
# exist yet — so they are named rather than silently skipped.
say "wrapping scope keys to enrolled members"
for e in $ENVS; do
  out=$(ctl env keys sync --org "$ORG" --project "$PROJECT" --env "$e" 2>&1) || {
    note "sync ${e}: ${out}"
    continue
  }
  ok "${e}: $(printf '%s' "$out" | tr '\n' ' ')"
done

printf '\n'
ok "org ${ORG} / team ${TEAM} / project ${PROJECT} — environments: ${ENVS}"
note "members still to run: 42ctl keys enroll --org ${ORG}   (then re-run this script)"
note "push the tree:  make vault-push-env        (GROBASE_ENV picks the environment)"
