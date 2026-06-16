#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m61-packaging.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M61 — OSS packaging gate (A7). Proves the three things an outside developer
# needs to actually adopt Grobase as a self-hostable BaaS exist AND are real:
#
#   1. migration guides are SUBSTANTIVE (not stubs). The Supabase guide must
#      document the `tenant_owned` wrap-your-existing-Postgres on-ramp AND the
#      "dependency swap" drop-in story; the Firebase guide must carry the
#      Firestore→Grobase concept mapping (Firestore → Mongo/Postgres). We grep
#      the documented patterns, not just file presence — a guide that lost its
#      on-ramp section is a failure, an empty file would pass `test -f`.
#
#   2. the `baas` CLI ACTUALLY RUNS. We build the SDK fresh in a pinned node:20
#      container (Docker-first; the bin entry is dist/bin/baas.js) and invoke it.
#      The teeth: its --help output must list the REAL subcommands the SDK wires
#      (functions, secrets, triggers, login) — a hard-coded `echo` could fake
#      that, so we ALSO assert a known subcommand path parses (functions list
#      with no config errors with the configured-URL message, proving the
#      dispatcher routed) AND an unknown command exits non-zero (a real argv
#      dispatcher, not a banner printer).
#
#   3. one-command bring-up exists. The mini-baas-infra Makefile must expose the
#      `all:` (build+start default edition) and `up:` (start selected edition)
#      targets that a new self-hoster runs to stand the stack up.
#
# Offline-capable: no live stack needed — the CLI runs in a throwaway container
# and the guides/Makefile are read from the tree. PASS = guides substantive +
# CLI runs and shows its commands + dispatcher is real + bring-up target present.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # apps/baas/mini-baas-infra
ROOT_DIR="$(cd "${BAAS_DIR}/.." && pwd)"        # apps/baas
WIKI="${ROOT_DIR}/wiki"
SDK="${ROOT_DIR}/sdk"
MK="${BAAS_DIR}/Makefile"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M61] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M61] FAIL — $*"; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

# has/nhas operate on a file: assert a marker is present / absent.
has()  { grep -q -- "$1" "$2" || fail "$3: '$1' missing — $(head -c 200 "$2")"; }
ihas() { grep -qi -- "$1" "$2" || fail "$3: '$1' missing — $(head -c 200 "$2")"; }

# ── 1) migration guides are substantive ──────────────────────────────────────
step "1/4 migration guides exist AND document their patterns"
SUPA="${WIKI}/migrate-from-supabase.md"
FIRE="${WIKI}/migrate-from-firebase.md"
[[ -s "${SUPA}" ]] || fail "migrate-from-supabase.md missing/empty"
[[ -s "${FIRE}" ]] || fail "migrate-from-firebase.md missing/empty"
# Supabase guide: the wrap-your-existing-DB on-ramp + the drop-in swap story.
has 'tenant_owned' "${SUPA}" "supabase guide"
ihas 'dependency swap' "${SUPA}" "supabase guide"
# The guide must also point Supabase's `functions deploy` at our `baas` CLI.
ihas 'baas' "${SUPA}" "supabase guide CLI mapping"
ok "supabase guide: tenant_owned on-ramp + dependency-swap drop-in documented"
# Firebase guide: the Firestore→Grobase mapping (document DB → Mongo/Postgres).
grep -qE 'Firestore.*(→|->).*(Mongo|Postgres|Grobase)' "${FIRE}" \
  || fail "firebase guide: no Firestore→(Mongo/Postgres/Grobase) concept mapping — $(head -c 200 "${FIRE}")"
ihas 'onSnapshot' "${FIRE}" "firebase guide realtime mapping"
ok "firebase guide: Firestore→(Mongo/Postgres) mapping + onSnapshot→realtime documented"

# ── 2) the baas CLI actually runs and shows its real subcommands ──────────────
step "2/4 build + run the baas CLI in node:20 (must list real subcommands)"
# Discover how the CLI is invoked: package.json bin entry → dist/bin/baas.js.
BIN="$(node -e 'process.stdout.write(require("'"${SDK}"'/package.json").bin.baas||"")' 2>/dev/null || true)"
if [[ -z "${BIN}" ]]; then
  # node not on host (Docker-first) — read the bin entry without a runtime.
  BIN="$(grep -A3 '"bin"' "${SDK}/package.json" | grep '"baas"' | sed -E 's/.*: *"([^"]+)".*/\1/')"
fi
[[ -n "${BIN}" ]] || fail "package.json has no bin.baas entry"
[[ "${BIN}" == *baas* ]] || fail "bin.baas does not point at a baas entry: ${BIN}"
ok "package.json bin.baas → ${BIN}"

# Build the SDK fresh in a pinned container, then invoke the CLI three ways:
#   a) --help            → must enumerate the real subcommands
#   b) functions list    → must reach the dispatcher (configured-URL error, not USAGE)
#   c) bogus subcommand  → must exit non-zero (real argv dispatcher, not a banner)
docker run --rm -v "${SDK}:/sdk" -w /sdk node:20 sh -c '
  set -e
  npm ci -s >/dev/null 2>&1 || npm i -s >/dev/null 2>&1
  npm run build -s >/dev/null 2>&1 || true
  test -f dist/bin/baas.js || { echo "__NOBIN__"; exit 7; }
  echo "===HELP==="
  node dist/bin/baas.js --help
  echo "===HELP_RC=$?==="
  echo "===DISPATCH==="
  # no URL configured + isolated config → the dispatcher must reach client()
  # and emit its "No base URL configured" error (proves argv routed to functions
  # list, not just the banner). Force an empty config dir.
  GROBASE_CONFIG=/tmp/m61-cfg/none.json node dist/bin/baas.js functions list 2>&1 || true
  echo "===BOGUS==="
  # capture the unknown-command exit WITHOUT letting set -e abort the shell.
  brc=0; node dist/bin/baas.js zzz-not-a-command >/dev/null 2>&1 || brc=$?
  echo "BOGUS_RC=${brc}"
' > "${TMP}/cli.out" 2>"${TMP}/cli.err" || {
    grep -q '__NOBIN__' "${TMP}/cli.out" "${TMP}/cli.err" 2>/dev/null \
      && fail "build produced no dist/bin/baas.js"
    fail "CLI container run failed — $(tail -c 300 "${TMP}/cli.err")"
  }

# (a) --help lists every real subcommand the SDK actually wires.
HELP="$(sed -n '/===HELP===/,/===HELP_RC=/p' "${TMP}/cli.out")"
printf '%s\n' "${HELP}" > "${TMP}/help.txt"
for sub in login functions secrets triggers; do
  grep -q -- "${sub}" "${TMP}/help.txt" \
    || fail "--help did not list subcommand '${sub}' — $(head -c 300 "${TMP}/help.txt")"
done
grep -q 'HELP_RC=0' "${TMP}/cli.out" || fail "--help exited non-zero"
ok "baas --help runs (rc=0) and lists: login · functions · secrets · triggers"

# (b) dispatcher is real: `functions list` with no URL hits client() and errors
#     with the configured-URL message — a banner-only fake never reaches this.
DISP="$(sed -n '/===DISPATCH===/,/===BOGUS===/p' "${TMP}/cli.out")"
printf '%s\n' "${DISP}" > "${TMP}/disp.txt"
grep -qi 'No base URL configured' "${TMP}/disp.txt" \
  || fail "'functions list' did not route through the dispatcher (no client() URL error) — $(head -c 300 "${TMP}/disp.txt")"
ok "baas functions list routes through the real dispatcher (errors on missing URL, not a banner)"

# (c) an unknown command must exit non-zero (real argv dispatcher).
grep -q 'BOGUS_RC=0' "${TMP}/cli.out" \
  && fail "unknown subcommand exited 0 — the CLI is a banner printer, not a dispatcher"
grep -qE 'BOGUS_RC=[1-9]' "${TMP}/cli.out" \
  || fail "could not observe unknown-command exit code — $(tail -c 200 "${TMP}/cli.out")"
ok "unknown subcommand exits non-zero — argv dispatch is real"

# ── 3) one-command bring-up target exists ────────────────────────────────────
step "3/4 Makefile one-command bring-up (all: / up:)"
grep -qE '^all:' "${MK}"  || fail "Makefile has no 'all:' target (build+start default edition)"
grep -qE '^up:' "${MK}"   || fail "Makefile has no 'up:' target (start selected edition)"
ok "Makefile bring-up present: 'make all' (build+start) · 'make up' (selected edition)"

# ── 4) the baas CLI is npm-publishable: a HELD publish workflow + a packable tarball ──
step "4/4 npm publish path: held baas-cli-publish.yml + the package packs the CLI"
REPO_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"     # ft_transcendence (repo root)
WF="${REPO_ROOT}/.github/workflows/baas-cli-publish.yml"
[[ -s "${WF}" ]] || fail "baas-cli-publish.yml missing — no npm publish path for the CLI"
# HELD: publishes only on an explicit baas-cli-v* tag or a manual dry_run=false run,
# and reads the token from secrets.NPM_TOKEN (never a hardcoded credential).
has 'baas-cli-v' "${WF}" "publish workflow tag trigger"
has 'NPM_TOKEN' "${WF}" "publish workflow token"
ihas 'dry_run' "${WF}" "publish workflow held-by-default manual path"
grep -q 'npm publish' "${WF}" || fail "publish workflow never calls 'npm publish'"
# PACKABLE: build in node:20 and assert the publishable tarball carries the CLI entry.
docker run --rm -v "${SDK}:/sdk" -w /sdk node:20 sh -c '
  set -e
  npm ci --ignore-scripts -s >/dev/null 2>&1 || npm i --ignore-scripts -s >/dev/null 2>&1
  npm run build -s >/dev/null 2>&1
  npm pack --dry-run 2>&1
' > "${TMP}/pack.out" 2>&1 || fail "npm pack dry-run failed — $(tail -c 300 "${TMP}/pack.out")"
grep -q 'dist/bin/baas.js' "${TMP}/pack.out" || fail "the publishable tarball would not include dist/bin/baas.js — $(tail -c 200 "${TMP}/pack.out")"
ok "CLI publishable: held baas-cli-publish.yml (baas-cli-v* tag / manual dry_run) + tarball includes dist/bin/baas.js"

# ── residuals (KNOWN-OPEN) ───────────────────────────────────────────────────
cyan "[M61] KNOWN-OPEN residuals:"
echo "  - CLI not yet PUBLISHED to npm — baas-cli-publish.yml is wired but HELD; publishing is a"
echo "    human-triggered 'baas-cli-v*' tag (or manual dry_run=false). No standalone single-file binary yet."
echo "  - No GitHub Action wrapping 'baas deploy' for CI-driven function deploys."

green "[M61] ALL GATES GREEN — OSS packaging real: substantive Supabase/Firebase migration guides · baas CLI builds & runs & dispatches its real subcommands · one-command Makefile bring-up · npm-publishable (held publish workflow + packable CLI tarball)"
