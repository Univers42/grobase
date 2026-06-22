#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    e2e-rbac-scope-keys.sh                             :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/22 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/22 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# CROSS-REPO LIVE E2E — the org/team/group + per-environment + zero-knowledge
# scope-key flow driven through 42ctl against a flagged-on stack (grobase +
# vault42-server). This is the GA-verification harness: the *components* are
# already proven in isolation (grobase gates m162/m166/m168/m170/m172; vault42
# v14 decryption + v15 rotation integration tests), and this exercises them
# TOGETHER over the wire, the way an operator/customer uses them.
#
# It is NOT a self-contained gate (it does not build a scratch stack): it asserts
# against a stack you bring up first (the prerequisites below), so a single
# command reproduces the whole demo + asserts each leg.
#
# ── PREREQUISITES ─────────────────────────────────────────────────────────────
#  1. grobase up with the RBAC flags ON (e.g. an .env with):
#       ORG_MODEL_ENABLED=1 RBAC_HIERARCHY_ENABLED=1 ENVIRONMENTS_ENABLED=1
#       GROUPS_ENABLED=1 INVITES_ENABLED=1 USER_PUBKEYS_ENABLED=1 EMAIL_OTP_ENABLED=1
#       GOTRUE_JWT_SECRET=<shared>
#     then `make up EDITION=full` (migrations 001..083 applied via `make migrate`).
#  2. vault42-server up with VAULT42_SCOPE_KEYS_ENABLED=1, GrobaseStore pointed at
#     the same grobase (GROBASE_QUERY_URL/ANON_KEY/APP_KEY/DB_ID, JWT_SECRET=the
#     shared GOTRUE_JWT_SECRET), gRPC reachable at $V42_ADDR.
#  3. `42ctl` on PATH (cargo build from feat/rbac-org-team-group-verbs), three
#     profiles/identities (admin, sergio, vadim) — see keys init / config endpoint.
#
# ── KNOBS ─────────────────────────────────────────────────────────────────────
GROBASE="${GROBASE:-http://localhost:8000}"          # Kong public gateway
V42_ADDR="${V42_ADDR:-https://localhost:8443}"       # vault42-server gRPC
CTL="${CTL:-42ctl}"
PROJECT="${PROJECT:-app}"                              # an existing org-bound project (uuid via --project)
set -euo pipefail

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[E2E] $*"; }
ok() { green "  ✓ $*"; }
fail() { red "[E2E] FAIL — $*"; exit 1; }
run() { "$@" || fail "command failed: $*"; }

# admin/sergio/vadim drive distinct 42ctl profiles (FT_PROFILE) bound to distinct identities.
ADMIN="${ADMIN_PROFILE:-admin}"
SERGIO="${SERGIO_PROFILE:-sergio}"
VADIM="${VADIM_PROFILE:-vadim}"
ctl() { local p="$1"; shift; FT_PROFILE="$p" "${CTL}" "$@"; }

step "0/9 preflight: grobase + vault42 reachable, 42ctl present"
command -v "${CTL}" >/dev/null || fail "42ctl not on PATH (cargo build it from feat/rbac-org-team-group-verbs)"
curl -fsS -o /dev/null "${GROBASE}/auth/v1/health" 2>/dev/null || curl -fsS -o /dev/null "${GROBASE}/" 2>/dev/null || fail "grobase not reachable at ${GROBASE}"
ok "grobase + 42ctl present (vault42 at ${V42_ADDR})"

step "1/9 admin: create org Univers42 + team core + envs prod/dev"
ORG="$(ctl "${ADMIN}" org create --slug univers42 --name Univers42 --json 2>/dev/null | jq -r .id)"
[ -n "${ORG}" ] || fail "org create returned no id"
TEAM="$(ctl "${ADMIN}" team create --org "${ORG}" --slug core --name Core --json 2>/dev/null | jq -r .id)"
ctl "${ADMIN}" env create --project "${PROJECT}" --name prod
ctl "${ADMIN}" env create --project "${PROJECT}" --name dev
ok "org ${ORG}, team ${TEAM}, envs prod+dev"

step "2/9 admin: bootstrap the prod scope key (env-init) + grant team writer on prod"
run ctl "${ADMIN}" vault env-init --org "${ORG}" --project "${PROJECT}" --env prod
run ctl "${ADMIN}" team grant-project --org "${ORG}" --team "${TEAM}" --project "${PROJECT}" --env prod --role writer
ok "prod scope key bootstrapped; team core granted writer on prod"

step "3/9 admin: seal a prod secret + a dev secret"
echo -n "postgres://prod-db" | run ctl "${ADMIN}" vault set-env --org "${ORG}" --project "${PROJECT}" --env prod DATABASE_URL
echo -n "postgres://dev-db"  | run ctl "${ADMIN}" vault set-env --org "${ORG}" --project "${PROJECT}" --env dev DATABASE_URL
ok "prod + dev secrets sealed to their env scope keys"

step "4/9 invite sergio to the team; sergio accepts + enrolls his pubkey"
TOK="$(ctl "${ADMIN}" team invite --org "${ORG}" --team "${TEAM}" --email sergio@example.com --json 2>/dev/null | jq -r .token)"
[ -n "${TOK}" ] || fail "team invite returned no token"
run ctl "${SERGIO}" invite accept --token "${TOK}"
run ctl "${SERGIO}" keys enroll --org "${ORG}"          # publish sergio's X25519 pubkey
ok "sergio joined team core (+org) and published his pubkey"

step "5/9 admin: sync-keys (provision the prod scope key to the team's members)"
run ctl "${ADMIN}" vault sync-keys --org "${ORG}" --project "${PROJECT}" --env prod
ctl "${ADMIN}" vault scope-status --org "${ORG}" --project "${PROJECT}" --env prod
ok "sync-keys wrapped the prod scope key to sergio"

step "6/9 (POSITIVE) sergio reads the prod secret"
GOT="$(ctl "${SERGIO}" vault get-env --org "${ORG}" --project "${PROJECT}" --env prod DATABASE_URL 2>/dev/null || true)"
[ "${GOT}" = "postgres://prod-db" ] || fail "sergio could not read prod secret (got '${GOT}')"
ok "sergio decrypts prod/DATABASE_URL — per-env grant + provisioning works"

step "7/9 (REJECT) sergio canNOT read the dev secret (granted only on prod)"
if ctl "${SERGIO}" vault get-env --org "${ORG}" --project "${PROJECT}" --env dev DATABASE_URL >/dev/null 2>&1; then
  fail "PER-ENV ISOLATION BROKEN — sergio (prod-only) read a dev secret"
fi
ok "sergio is denied dev — per-environment isolation holds"

step "8/9 (REJECT) vadim (never granted/provisioned) canNOT read prod"
if ctl "${VADIM}" vault get-env --org "${ORG}" --project "${PROJECT}" --env prod DATABASE_URL >/dev/null 2>&1; then
  fail "DENY-BY-DEFAULT BROKEN — an unprovisioned identity read prod"
fi
ok "vadim is denied prod — deny-by-default + provisioning gate hold"

step "9/9 (REVOKE+ROTATE) drop sergio from the team, rotate prod, sergio blocked on new revisions"
# remove sergio's team membership in grobase, then rotate the prod scope key.
ctl "${ADMIN}" team remove-member --org "${ORG}" --team "${TEAM}" --user "$(ctl "${SERGIO}" auth whoami --json 2>/dev/null | jq -r .user_id)" 2>/dev/null || true
run ctl "${ADMIN}" vault rotate-scope --org "${ORG}" --project "${PROJECT}" --env prod
echo -n "postgres://prod-db-rotated" | run ctl "${ADMIN}" vault set-env --org "${ORG}" --project "${PROJECT}" --env prod DATABASE_URL
if ctl "${SERGIO}" vault get-env --org "${ORG}" --project "${PROJECT}" --env prod DATABASE_URL 2>/dev/null | grep -q rotated; then
  fail "FORWARD SECRECY BROKEN — removed sergio read a post-rotation revision"
fi
ok "after revoke+rotate, removed sergio cannot read the new prod revision (forward-secure)"

green "[E2E] ALL GREEN — org/team + per-environment + zero-knowledge scope-key flow end-to-end:"
green "[E2E]   invite -> accept -> grant -> sync-keys -> member decrypts prod, NOT dev;"
green "[E2E]   unprovisioned denied; revoke + rotate-scope = forward-secure."
exit 0
