#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m216-vault-team-path.sh — the env tree is SHARED, and only with us          #
#                                                                              #
#  vault42 sharing is encryption, not RBAC: a tree pushed the personal way is   #
#  sealed to one keypair, so a teammate pulling it gets "no manifest for        #
#  project X" whatever org role they hold. That failure looks like a            #
#  permissions bug and is not one, so the default must be the team path.        #
#                                                                              #
#   TEAM      ctl-env.sh resolves org + environment by default (team path);     #
#             only VAULT_ENV_PERSONAL=1 falls back to sealed-to-me-alone.       #
#   SCOPE     a team push seals vendor/ to the pusher — other apps              #
#             credentials are not grobase team material.                       #
#   HOSTS     no profile seeds a host we do not own. vault42.fly.dev,           #
#             grobase-nano.fly.dev and grobase-stack.fly.dev are dead, and the  #
#             first two are other people apps: a fresh machine seeded with      #
#             them sends its account email to a stranger authority.             #
#   KEYSTORE  the identity lives outside the worktree — 42ctl own scanner       #
#             walks a keystore left in the repo and the push dies.              #
#   MUTANTS   each check refuses the way back in.                              #
#                                                                              #
#  Static only: no network, no stack, no credential read, no value printed.     #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CTL="${ROOT}/scripts/vault/ctl-env.sh"
OPS="${ROOT}/orchestrators/makes/80-ops.mk"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
arm_rc=0
step() {
  printf '%s[M216] %s%s\n' "${_B}" "$1" "${_0}"
  arm_rc=0
}
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M216] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
  arm_rc=1
}

# Hosts we do not own, or that no longer resolve. A profile seeding one of these is
# the defect: `keys recover` would send the account email to whoever owns it.
FOREIGN='vault42\.fly\.dev|grobase-nano\.fly\.dev|grobase-stack\.fly\.dev'
# Where a profile may legitimately point.
OURS='vault42-server\.fly\.dev|vault42-authority\.fly\.dev'

for f in "${CTL}" "${OPS}"; do
  [ -f "${f}" ] || {
    fail "missing ${f#"${ROOT}"/}"
    exit 1
  }
done

team_arm() {
  step "TEAM — the shared path is the default"
  grep -qE '^ORG="\$\{VAULT_ENV_ORG:-[a-z0-9-]+\}"' "${CTL}" ||
    fail "ctl-env.sh does not default VAULT_ENV_ORG to an org"
  grep -qE '^ENVNAME="\$\{VAULT_ENV_NAME:-\$\{GROBASE_ENV:-[a-z]+\}\}"' "${CTL}" ||
    fail "ctl-env.sh does not resolve the environment from GROBASE_ENV"
  grep -q 'VAULT_ENV_PERSONAL' "${CTL}" ||
    fail "ctl-env.sh offers no VAULT_ENV_PERSONAL escape hatch"
  # The personal path must be reachable ONLY through that variable: if either
  # coordinate is still blank by default, every push is silently personal again.
  awk '/^if \[ "\$\{VAULT_ENV_PERSONAL:-0\}" = 1 \]; then/,/^fi$/' "${CTL}" |
    grep -q 'ORG=""' ||
    fail "VAULT_ENV_PERSONAL=1 does not clear the org (personal path unreachable)"
  [ "${arm_rc}" -eq 0 ] && ok "team path default: org + environment resolved, VAULT_ENV_PERSONAL=1 opts out"
}

scope_arm() {
  step "SCOPE — a team push does not share other apps credentials"
  grep -q 'VENDOR_PRIVATE=' "${CTL}" || fail "ctl-env.sh defines no vendor private pattern"
  grep -qE -- '--private "\$VENDOR_PRIVATE"' "${CTL}" ||
    fail "ctl-env.sh never passes --private for vendor/ on a push"
  # --private exists only on the env verbs; passing it to a personal push is an error.
  awk '/if \[ "\$verb" = push \]; then/,/fi/' "${CTL}" | grep -q 'private' ||
    fail "the vendor seal is not scoped to the push verb"
  # An approximation that is presented as an exclusion would be a lie: the ponytail
  # note must say --private bounds who can read, not whether the bytes travel.
  grep -qiE '^# Ponytail:.*(private marks|does not exclude)' "${CTL}" ||
    grep -qiE 'private bounds WHO|does not exclude them from the upload' "${CTL}" ||
    fail "the vendor seal has no ponytail note stating it marks rather than excludes"
  [ "${arm_rc}" -eq 0 ] && ok "vendor/ sealed to the pusher on a team push, limitation documented"
}

hosts_arm() {
  step "HOSTS — no profile seeds a host we do not own"
  local f hits
  # Only the files that WRITE a profile matter; prose may name a dead host while
  # explaining why it is dead, so the seeded JSON is what is checked.
  for f in "${CTL}" "${OPS}"; do
    hits="$(grep -nE '"(server|authority|grobase)":[[:space:]]*"https://('"${FOREIGN}"')' "${f}" || true)"
    [ -z "${hits}" ] || fail "${f##*/} seeds a dead/foreign host: $(cut -d: -f1 <<<"${hits}" | tr '\n' ' ')"
  done
  grep -qE "${OURS}" "${CTL}" || fail "ctl-env.sh seeds no owned server host"
  grep -qE "CTL_SERVER[[:space:]]*\?=[[:space:]]*https://(${OURS})" "${OPS}" ||
    fail "80-ops.mk CTL_SERVER does not default to an owned host"
  grep -qE "CTL_AUTHORITY[[:space:]]*\?=[[:space:]]*https://(${OURS})" "${OPS}" ||
    fail "80-ops.mk CTL_AUTHORITY does not default to an owned host"
  [ "${arm_rc}" -eq 0 ] && ok "every seeded profile points at vault42-server / vault42-authority"
}

keystore_arm() {
  step "KEYSTORE — the identity lives outside the worktree"
  grep -qE '^CTL_CFG_DIR[[:space:]]*:=[[:space:]]*\$\(HOME\)' "${OPS}" ||
    fail "80-ops.mk keeps the 42ctl state inside the repo (CTL_CFG_DIR is not under \$(HOME))"
  # A keystore committed, or left where a push scanner walks it, is the defect.
  local tracked
  tracked="$(git -C "${ROOT}" ls-files | grep -E '(^|/)(keystore\.v42|\.42ctl/)' || true)"
  [ -z "${tracked}" ] || fail "42ctl identity material is tracked: $(tr '\n' ' ' <<<"${tracked}")"
  git -C "${ROOT}" check-ignore -q .42ctl 2>/dev/null ||
    fail ".42ctl is not gitignored"
  git -C "${ROOT}" check-ignore -q keystore.v42 2>/dev/null ||
    fail "keystore.v42 is not gitignored"
  [ "${arm_rc}" -eq 0 ] && ok "identity under \$HOME, nothing tracked, .42ctl and keystore.v42 ignored"
}

# mutants_arm applies each defect to a COPY and requires the matching check to see it.
mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local work ctl ops
  work="$(mktemp -d)" || return
  trap 'rm -rf "${work}"' RETURN
  ctl="${work}/ctl-env.sh"
  ops="${work}/80-ops.mk"

  sed 's#^ORG="\${VAULT_ENV_ORG:-[a-z0-9-]*}"#ORG="${VAULT_ENV_ORG:-}"#' "${CTL}" >"${ctl}"
  grep -qE '^ORG="\$\{VAULT_ENV_ORG:-[a-z0-9-]+\}"' "${ctl}" &&
    fail "mutant survived: a blank default org is not caught" ||
    ok "refused: the org default emptied (every push silently personal)"

  sed 's#--private "\$VENDOR_PRIVATE"##' "${CTL}" >"${ctl}"
  grep -qE -- '--private "\$VENDOR_PRIVATE"' "${ctl}" &&
    fail "mutant survived: the vendor seal removed is not caught" ||
    ok "refused: the vendor --private seal removed"

  sed 's#https://vault42-authority\.fly\.dev#https://grobase-nano.fly.dev#' "${OPS}" >"${ops}"
  grep -qE "CTL_AUTHORITY[[:space:]]*\?=[[:space:]]*https://(${OURS})" "${ops}" &&
    fail "mutant survived: a foreign authority host is not caught" ||
    ok "refused: CTL_AUTHORITY pointed at a stranger authority"

  sed 's#^CTL_CFG_DIR[[:space:]]*:=.*#CTL_CFG_DIR  := $(CURDIR)/.42ctl#' "${OPS}" >"${ops}"
  grep -qE '^CTL_CFG_DIR[[:space:]]*:=[[:space:]]*\$\(HOME\)' "${ops}" &&
    fail "mutant survived: a keystore back inside the worktree is not caught" ||
    ok "refused: the identity moved back into the repo"
}

team_arm
scope_arm
hosts_arm
keystore_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M216] PASS — the env tree is shared with the team, and only with us%s\n' "${_G}" "${_0}"
else
  printf '%s[M216] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
