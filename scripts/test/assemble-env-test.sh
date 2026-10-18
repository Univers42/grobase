#!/usr/bin/env bash
# Prove that `make env` (scripts/env/assemble-env.sh) never loses a key and never
# hands a host-only token to the 96 containers that read `.env`.
#
# WHY
#   `.env` is derived from config.env < .env.secrets < .env.local, but the only
#   copy of a developer's API keys lived in `.env`, which the script rewrites
#   wholesale. Measured 2026-10-13: a `.env` held 10 keys its `.env.local` no
#   longer had, and the next `make env` would have dropped them without a word.
#   The same rewrite re-minted database passwords whenever `.env.secrets` was
#   absent, which an initialized volume then rejects.
#
# WHAT IT CHECKS, each scenario in its own scratch tree (mktemp) so the real
#   .env / .env.secrets / .env.local are never read or written
#   A. 4 legacy checks + GITHUB_PAT: a GitHub token never reaches `.env`
#   1. a key orphaned from `.env.local` is REFUSED, `.env` byte-identical
#   2. ENV_ORPHANS=carry keeps it, and a second run finds nothing to carry
#   3. ENV_ORPHANS=drop assembles without it; `.env.prev` still holds it
#   4. ENV_ORPHANS=bogus exits non-zero
#   5. a secret only the old `.env` held is NOT re-minted (flat legacy file)
#   6. a key removed from config.env is dropped on purpose, never refused
#   7. carry still runs the OPTIONAL_KEYS migration when `.env.local` is new
#   8. a host-only token is withheld (`export` form too), named, never refused
#   9. an empty value (`KEY=`, `KEY=""`, `KEY=''`) is not an orphan
#   10. a secret that disagrees with `.env.secrets` warns by NAME, never refuses
#   11. a host-only token in the `.env.secrets` section is NOT restored there
#   12. no fixture value is EVER printed, in any scenario
#   13. a flat legacy .env (no markers) refuses a key no layer holds, too
#   14. TITAN_EMAIL/TITAN_PASSWORD in .env.local derive six keys, in a final section
#   15. an explicit SMTP_HOST (mailpit included) is kept; no Titan relay keys
#   16. an explicit SMTP_PASS/SMTP_USER that differs is refused, by name; equal passes
#   17. a rerun is byte-identical; the derived section is no orphan, never carried
#   18. no TITAN_* line in .env, the password only on the SMTP_PASS line, never printed
#   19. no TITAN_* set: .env is exactly config + secrets + local, no derived section
#   20. a password with $ # quotes, a space and a backslash survives docker compose
#   21. a key the TITAN alias re-derives is no orphan; a real orphan, an SMTP_PORT
#       beside an explicit SMTP_HOST, and an SMTP_PASS with no alias are still refused
# MUTANT
#   ASSEMBLE_ENV_SH=<old script> bash scripts/test/assemble-env-test.sh
#   runs the same scenarios against the previous script and goes red — that is
#   the proof the scenarios are load-bearing (git show HEAD:scripts/env/assemble-env.sh).
#
# USAGE
#   bash scripts/test/assemble-env-test.sh      (make env-test)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSEMBLE="${ASSEMBLE_ENV_SH:-$ROOT/scripts/env/assemble-env.sh}"

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

# Fixtures use obviously fake values. Every one of these is in some scenario, and
# scenario 11 proves none of them EVER reaches stdout or stderr: the script names
# keys, never values.
SENTINEL='fake-sentinel-9c1d4a-not-a-real-value'
NEEDLES=(
  "$SENTINEL"
  'fake-pat-4b8e-not-a-real-value'
  'fake-fly-7d2c-not-a-real-value'
  'fake-vercel-1a5f-not-a-real-value'
  'fake-old-2c7e-not-a-real-value'
  'fake-new-5a19-not-a-real-value'
  'fake-titan-pw-3e8b-not-a-real-value'
  'fake-other-pw-6d02-not-a-real-value'
)
TITAN_PW='fake-titan-pw-3e8b-not-a-real-value'
OTHER_PW='fake-other-pw-6d02-not-a-real-value'
TITAN_MAIL='ops@titan.example.test'

fail=0
scenario=''
red=0
failed_scenarios=()

# Every failure is collected, not short-circuited: one red run must show every
# scenario that is broken, not just the first.
bad() {
  echo "FAIL [$scenario] $1"
  fail=1
  case " ${failed_scenarios[*]:-} " in
  *" $scenario "*) ;;
  *) failed_scenarios+=("$scenario") ;;
  esac
}

# ── harness ────────────────────────────────────────────────────────────────
# A scratch tree is a minimal repo: the script under test, the real
# generate-env.sh (the script reads its generated-key list from it) and the
# real config.env. The tree is named after $scenario, which the caller sets: a
# command substitution runs in a subshell, so the name cannot travel back.
new_tree() {
  local dir="$work/$scenario"
  mkdir -p "$dir/scripts/env" "$dir/scripts/lib"
  cp "$ASSEMBLE" "$dir/scripts/env/assemble-env.sh"
  cp "$ROOT/scripts/lib/lib-dotenv.sh" "$dir/scripts/lib/lib-dotenv.sh"
  cp "$ROOT/scripts/env/generate-env.sh" "$dir/scripts/env/generate-env.sh"
  cp "$ROOT/config.env" "$dir/config.env"
  printf '%s' "$dir"
}

run_env() {
  local dir="$1"
  shift
  set +e
  env "$@" bash "$dir/scripts/env/assemble-env.sh" >"$dir/stdout" 2>"$dir/stderr"
  rc=$?
  set -e
}

# write_old_env <tree> <config-body> <secrets-body> <local-body>
# Builds the `.env` a previous `make env` run would have written, markers and
# all: the orphan check reads those markers to tell a local override from a
# config value.
write_old_env() {
  local dir="$1"
  {
    echo "# ASSEMBLED by 'make env' on 2026-01-01T00:00:00Z — DO NOT EDIT THIS FILE."
    echo
    echo "# ========== config.env =========="
    cat "$2"
    echo
    echo "# ========== .env.secrets =========="
    cat "$3"
    echo
    echo "# ========== .env.local =========="
    cat "$4"
  } >"$dir/.env"
  chmod 600 "$dir/.env"
}

# write_secrets <tree> / write_local <tree> — the two optional layers.
write_secrets() {
  printf 'JWT_SECRET=%s\nPOSTGRES_PASSWORD=%s\n' "$SENTINEL" "$SENTINEL" >"$1/.env.secrets"
  chmod 600 "$1/.env.secrets"
}
write_local() {
  printf '# developer overrides\nLLM_API_KEY=%s\n' "$SENTINEL" >"$1/.env.local"
  chmod 600 "$1/.env.local"
}

# orphan_tree — the fixture behind scenarios 1-4 and 7: a running stack whose
# `.env.local` lost TWO keys the old `.env` still carries, so the name lists are
# never exercised with a single name.
orphan_tree() {
  local dir config_body secrets_body local_body
  dir="$(new_tree)"
  config_body="$dir/config.body"
  secrets_body="$dir/secrets.body"
  local_body="$dir/local.body"
  cat "$ROOT/config.env" >"$config_body"
  printf 'JWT_SECRET=%s\nPOSTGRES_PASSWORD=%s\n' "$SENTINEL" "$SENTINEL" >"$secrets_body"
  # ORPHAN_LOCAL_KEY and SECOND_LOCAL_KEY live in the old `.env` only:
  # .env.local lost them.
  printf 'LLM_API_KEY=%s\nORPHAN_LOCAL_KEY=%s\nSECOND_LOCAL_KEY=%s\n' \
    "$SENTINEL" "$SENTINEL" "$SENTINEL" >"$local_body"
  write_old_env "$dir" "$config_body" "$secrets_body" "$local_body"
  write_secrets "$dir"
  write_local "$dir"
  rm -f "${config_body:?}" "${secrets_body:?}" "${local_body:?}"
  printf '%s' "$dir"
}

# ── A. legacy: GitHub tokens never enter .env ──────────────────────────────
scenario=github-token
t="$(new_tree)"
mkdir -p "$t/scripts/env"
printf 'JWT_SECRET=not-a-real-secret\n' >"$t/.env.secrets"
# Fake tokens: the documented shapes, with no real value behind them. GITHUB_PAT
# carries a value that is NOT token-shaped (vault-env.mjs manages that key), so
# only the KEY NAME can withhold it — the shape check cannot be what passes it.
cat >"$t/.env.local" <<'EOF'
# a comment survives
LLM_API_KEY=keep-me
GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyzAB
SOME_OTHER_NAME=github_pat_11AAAAAAA0123456789abcdefghijklmnopqrstuv
GH_PAT="ghp_0123456789abcdefghijklmnopqrstuvwxyzCD"
GITHUB_PAT=fake-pat-4b8e-not-a-real-value
EOF
run_env "$t"
[ "$rc" = 0 ] || bad "assemble-env.sh exited non-zero (the rest of .env.local is valid)"
grep -q '^LLM_API_KEY=keep-me$' "$t/.env" 2>/dev/null ||
  bad "a legitimate .env.local key did not reach .env"
if grep -qE 'ghp_|github_pat_' "$t/.env" 2>/dev/null; then
  bad "a GitHub token reached .env"
fi
for k in GITHUB_TOKEN SOME_OTHER_NAME GH_PAT GITHUB_PAT; do
  n=$(grep -c "$k looks like a GitHub token" "$t/stderr" 2>/dev/null || true)
  [ "${n:-0}" = 1 ] || bad "$k withheld $n time(s) on stderr, expected once"
done
if grep -q '^GITHUB_PAT=' "$t/.env"; then
  bad "GITHUB_PAT reached .env (matched by key name only, its value is not token-shaped)"
fi
grep -q '^# a comment survives$' "$t/.env" || bad "comments in .env.local no longer pass through"

# ── 1. refuse by default ───────────────────────────────────────────────────
scenario=refuse
t="$(orphan_tree)"
cp "$t/.env" "$t/env.before"
run_env "$t"
[ "$rc" != 0 ] || bad "an orphaned key assembled silently (expected a refusal)"
for k in ORPHAN_LOCAL_KEY SECOND_LOCAL_KEY; do
  grep -q "^  $k\$" "$t/stderr" || bad "the refusal does not name $k on its own line"
done
grep -q 'ENV_ORPHANS=carry' "$t/stderr" || bad "the refusal does not offer ENV_ORPHANS=carry"
grep -q 'ENV_ORPHANS=drop' "$t/stderr" || bad "the refusal does not offer ENV_ORPHANS=drop"
grep -q 'vault-env.mjs' "$t/stderr" || bad "the refusal does not warn about vault-env.mjs"
cmp -s "$t/.env" "$t/env.before" || bad ".env was rewritten despite the refusal"
[ ! -f "$t/.env.prev" ] || bad ".env.prev written despite the refusal"

# ── 2. ENV_ORPHANS=carry ───────────────────────────────────────────────────
scenario=carry
t="$(orphan_tree)"
run_env "$t" ENV_ORPHANS=carry
[ "$rc" = 0 ] || bad "ENV_ORPHANS=carry exited non-zero"
for k in ORPHAN_LOCAL_KEY SECOND_LOCAL_KEY; do
  grep -q "^$k=$SENTINEL\$" "$t/.env" || bad "carry: $k did not reach .env"
  grep -q "^$k=$SENTINEL\$" "$t/.env.local" || bad "carry: $k did not reach .env.local"
  n=$(grep -c "^$k=" "$t/.env.local" || true)
  [ "$n" = 1 ] || bad "carry: .env.local holds $k $n time(s) after a second run"
done
grep -q '^Carried 2 key(s) into .env.local: ORPHAN_LOCAL_KEY SECOND_LOCAL_KEY$' "$t/stderr" ||
  bad "carry: the carried keys are not named on stderr"
[ "$(stat -c '%a' "$t/.env.local")" = 600 ] || bad "carry: .env.local is not mode 600"
grep -q '^# Carried from .env by make env on ' "$t/.env.local" ||
  bad "carry: no dated header above the carried lines"
run_env "$t"
[ "$rc" = 0 ] || bad "the run after a carry still refuses (the keys are in .env.local now)"

# ── 3. ENV_ORPHANS=drop ────────────────────────────────────────────────────
scenario=drop
t="$(orphan_tree)"
run_env "$t" ENV_ORPHANS=drop
[ "$rc" = 0 ] || bad "ENV_ORPHANS=drop exited non-zero"
grep -q '^Dropping 2 orphaned key(s) from .env: ORPHAN_LOCAL_KEY SECOND_LOCAL_KEY$' "$t/stderr" ||
  bad "drop: the dropped keys are not named on stderr"
if grep -qE '^(ORPHAN_LOCAL_KEY|SECOND_LOCAL_KEY)=' "$t/.env"; then
  bad "drop: a dropped key still reached .env"
fi
for k in ORPHAN_LOCAL_KEY SECOND_LOCAL_KEY; do
  grep -q "^$k=$SENTINEL\$" "$t/.env.prev" || bad "drop: .env.prev does not hold $k"
done
[ "$(stat -c '%a' "$t/.env.prev")" = 600 ] || bad "drop: .env.prev is not mode 600"

# ── 4. an unknown ENV_ORPHANS is refused, not guessed ──────────────────────
scenario=orphans-bogus
t="$(orphan_tree)"
cp "$t/.env" "$t/env.before"
run_env "$t" ENV_ORPHANS=bogus
[ "$rc" != 0 ] || bad "ENV_ORPHANS=bogus was accepted"
grep -q 'unknown ENV_ORPHANS=bogus' "$t/stderr" ||
  bad "ENV_ORPHANS=bogus is not reported as unknown (carry or drop)"
cmp -s "$t/.env" "$t/env.before" || bad "ENV_ORPHANS=bogus rewrote .env"

# ── 5. a secret only the old .env held is carried, never re-minted ────────
scenario=secrets-carry
t="$(new_tree)"
# Legacy flat .env: no section markers at all, the pre-.env.secrets layout.
cat >"$t/.env" <<EOF
# hand-written before .env.secrets existed
MSSQL_SA_PASSWORD=$SENTINEL
JWT_SECRET=$SENTINEL
EOF
chmod 600 "$t/.env"
run_env "$t"
[ "$rc" = 0 ] || bad "the flat-legacy secrets run exited non-zero"
grep -q "^MSSQL_SA_PASSWORD=$SENTINEL\$" "$t/.env.secrets" 2>/dev/null ||
  bad ".env.secrets did not keep the old MSSQL_SA_PASSWORD (it was re-minted)"
grep -q "^MSSQL_SA_PASSWORD=$SENTINEL\$" "$t/.env" ||
  bad ".env lost the old MSSQL_SA_PASSWORD"

# ── 6. a key removed from config.env is dropped, never refused ─────────────
scenario=config-removal
t="$(new_tree)"
printf '# a flag that config.env used to carry\nLEGACY_FEATURE_FLAG=1\n' >"$t/config.body"
printf 'JWT_SECRET=%s\n' "$SENTINEL" >"$t/secrets.body"
printf '# no local overrides\n' >"$t/local.body"
write_old_env "$t" "$t/config.body" "$t/secrets.body" "$t/local.body"
write_secrets "$t"
write_local "$t"
run_env "$t"
[ "$rc" = 0 ] || bad "a key removed from config.env refused the run"
grep -q '^Dropped 1 key(s) removed from config.env: LEGACY_FEATURE_FLAG$' "$t/stderr" ||
  bad "the dropped config key is not named on stderr as removed from config.env"
if grep -q '^LEGACY_FEATURE_FLAG=' "$t/.env"; then
  bad "a key removed from config.env was carried anyway"
fi

# ── 7. carry still migrates OPTIONAL_KEYS into a new .env.local ────────────
# GOOGLE_CLIENT_ID sits in the CONFIG section, and config.env spells it empty, so
# the orphan check lets it through and only the OPTIONAL_KEYS migration can put a
# value into the new .env.local. In the local section it would be carried as an
# orphan instead and the assertion below would pass without the migration.
scenario=carry-fresh-local
t="$(new_tree)"
printf '# a config that stays\nAPP_FEATURE_FLAGS=fake-on\nGOOGLE_CLIENT_ID=%s\n' "$SENTINEL" >"$t/config.body"
printf 'JWT_SECRET=%s\n' "$SENTINEL" >"$t/secrets.body"
printf 'ORPHAN_LOCAL_KEY=%s\n' "$SENTINEL" >"$t/local.body"
write_old_env "$t" "$t/config.body" "$t/secrets.body" "$t/local.body"
write_secrets "$t"
run_env "$t" ENV_ORPHANS=carry
[ "$rc" = 0 ] || bad "carry with no .env.local exited non-zero"
grep -q "^GOOGLE_CLIENT_ID=$SENTINEL\$" "$t/.env.local" ||
  bad "carry: the OPTIONAL_KEYS migration no longer runs"
grep -q "^ORPHAN_LOCAL_KEY=$SENTINEL\$" "$t/.env.local" ||
  bad "carry: the orphan was not carried into the new .env.local"

# ── 8. host-only tokens are withheld, and never refused ────────────────────
scenario=host-only
t="$(new_tree)"
write_secrets "$t"
# VERCEL_TOKEN carries the `export ` prefix on purpose: the key regex above must
# apply to .env.local too, or `export FLY_TOKEN=x` walks straight into .env.
printf '# deploy tokens, host-only\nFLY_TOKEN=%s\nexport VERCEL_TOKEN=%s\nLLM_API_KEY=%s\n' \
  'fake-fly-7d2c-not-a-real-value' 'fake-vercel-1a5f-not-a-real-value' "$SENTINEL" >"$t/.env.local"
chmod 600 "$t/.env.local"
run_env "$t"
[ "$rc" = 0 ] || bad "a host-only key failed the run (the rest of .env.local is valid)"
if grep -qE '^(export[[:space:]]+)?(FLY_TOKEN|VERCEL_TOKEN)=' "$t/.env"; then
  bad "a host-only token reached .env (every container reads it)"
fi
for k in FLY_TOKEN VERCEL_TOKEN; do
  grep -q "^# $k= (host-only" "$t/.env" ||
    bad "no withheld comment line stands where $k was"
  grep -q "$k is host-only" "$t/stderr" || bad "$k is not named on stderr"
done
grep -qi 'rotate' "$t/stderr" &&
  bad "the host-only message borrows the GitHub 'rotate' wording (it must not)" || true
run_env "$t"
[ "$rc" = 0 ] || bad "the run after a host-only withholding still refuses"
for k in FLY_TOKEN VERCEL_TOKEN; do
  grep -q "^\(export[[:space:]]\+\)\?$k=" "$t/.env.local" ||
    bad "$k left .env.local — its host tool reads it from there"
done

# ── 9. an empty value is an assignment, not an orphan ──────────────────────
scenario=empty-values
t="$(new_tree)"
cat "$ROOT/config.env" >"$t/config.body"
printf 'JWT_SECRET=%s\n' "$SENTINEL" >"$t/secrets.body"
printf '%s\n' 'BLANK_KEY=' 'EMPTY_DOUBLE_QUOTED_KEY=""' "EMPTY_SINGLE_QUOTED_KEY=''" >"$t/local.body"
write_old_env "$t" "$t/config.body" "$t/secrets.body" "$t/local.body"
write_secrets "$t"
write_local "$t"
run_env "$t"
[ "$rc" = 0 ] || bad "an empty value was treated as a lost key (KEY=, KEY=\"\", KEY='')"

# ── 10. a secret that disagrees warns by name, never refuses ────────────────
scenario=secrets-drift
t="$(new_tree)"
cat "$ROOT/config.env" >"$t/config.body"
printf 'MSSQL_SA_PASSWORD=fake-old-2c7e-not-a-real-value\n' >"$t/secrets.body"
printf '# no local overrides\n' >"$t/local.body"
write_old_env "$t" "$t/config.body" "$t/secrets.body" "$t/local.body"
printf 'JWT_SECRET=%s\nMSSQL_SA_PASSWORD=fake-new-5a19-not-a-real-value\n' "$SENTINEL" >"$t/.env.secrets"
chmod 600 "$t/.env.secrets"
write_local "$t"
run_env "$t"
[ "$rc" = 0 ] || bad "a rotated secret refused the run (FORCE=1 rotation is legitimate)"
grep -q '^Warning: MSSQL_SA_PASSWORD — the old .env and .env.secrets disagree\.$' "$t/stderr" ||
  bad "the disagreement is not named on stderr"
grep -qi 'warning' "$t/stderr" || bad "the disagreement is not reported as a warning"
grep -q '^MSSQL_SA_PASSWORD=fake-new-5a19-not-a-real-value$' "$t/.env" ||
  bad "the old .env value won over .env.secrets"
grep -q '^MSSQL_SA_PASSWORD=fake-old-2c7e-not-a-real-value$' "$t/.env" &&
  bad "the stale old .env value was assembled" || true

# ── 11. a host-only token in the SECRETS section is not restored ────────────
# .env.secrets feeds .env, so restoring one there is the same leak with an extra
# hop — the migration must refuse it, not carry it.
scenario=host-only-in-secrets
t="$(new_tree)"
cat "$ROOT/config.env" >"$t/config.body"
printf 'MSSQL_SA_PASSWORD=%s\nFLY_TOKEN=%s\n' "$SENTINEL" 'fake-fly-7d2c-not-a-real-value' >"$t/secrets.body"
printf '# no local overrides\n' >"$t/local.body"
write_old_env "$t" "$t/config.body" "$t/secrets.body" "$t/local.body"
run_env "$t"
[ "$rc" = 0 ] || bad "a host-only token in the secrets section failed the run"
if grep -q 'FLY_TOKEN' "$t/.env.secrets" 2>/dev/null; then
  bad "a host-only token was restored into .env.secrets (it feeds .env)"
fi
if grep -qE '^FLY_TOKEN=' "$t/.env"; then
  bad "a host-only token reached .env through .env.secrets"
fi
grep -q 'FLY_TOKEN' "$t/stderr" || bad "the skipped FLY_TOKEN is not named on stderr"
grep -q "^MSSQL_SA_PASSWORD=$SENTINEL\$" "$t/.env.secrets" 2>/dev/null ||
  bad "refusing the host-only token also skipped the real secret beside it"

# ── 13. a flat legacy .env never drops a key no layer holds ─────────────────
# No section markers means no provenance, but a key that is neither generated nor
# held by any layer is the same silent-loss case as an orphaned local override.
scenario=flat-legacy-orphan
t="$(new_tree)"
cat >"$t/.env" <<EOF
# hand-written before .env.secrets existed
MSSQL_SA_PASSWORD=$SENTINEL
LEGACY_API_KEY=$SENTINEL
EOF
chmod 600 "$t/.env"
cp "$t/.env" "$t/env.before"
run_env "$t"
[ "$rc" != 0 ] || bad "a flat legacy key no layer holds was dropped silently (expected a refusal)"
grep -q '^  LEGACY_API_KEY$' "$t/stderr" || bad "the refusal does not name LEGACY_API_KEY"
if grep -q '^  MSSQL_SA_PASSWORD$' "$t/stderr"; then
  bad "a generated key was refused instead of restored"
fi
cmp -s "$t/.env" "$t/env.before" || bad ".env was rewritten despite the refusal"
[ ! -f "$t/.env.secrets" ] || bad ".env.secrets written despite the refusal"
run_env "$t" ENV_ORPHANS=carry
[ "$rc" = 0 ] || bad "carry on a flat legacy .env exited non-zero"
grep -q "^LEGACY_API_KEY=$SENTINEL\$" "$t/.env.local" 2>/dev/null ||
  bad "carry: LEGACY_API_KEY did not reach .env.local"
grep -q "^MSSQL_SA_PASSWORD=$SENTINEL\$" "$t/.env.secrets" 2>/dev/null ||
  bad "carry: MSSQL_SA_PASSWORD was not restored into .env.secrets"

# derived_of <tree> — the lines of .env after the derived marker.
derived_of() { sed -n "/^# ========== derived (TITAN_\* aliases) ==========\$/,\$p" "$1/.env"; }
# body_of <tree> — .env without its timestamped first line.
body_of() { tail -n +2 "$1/.env"; }

# titan_tree <local-body> — a fresh tree with synthetic secrets and the given .env.local.
titan_tree() {
  local dir
  dir="$(new_tree)"
  write_secrets "$dir"
  printf '%s\n' "$1" >"$dir/.env.local"
  chmod 600 "$dir/.env.local"
  printf '%s' "$dir"
}

# ── 14. TITAN_* in .env.local derive six keys ───────────────────────────────
scenario=titan-derive
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW")"
run_env "$t"
[ "$rc" = 0 ] || bad "assemble with TITAN_* exited $rc"
d="$(derived_of "$t")"
for want in "SMTP_USER=$TITAN_MAIL" "SMTP_PASS=$TITAN_PW" "EMAIL_FROM=$TITAN_MAIL" \
  SMTP_HOST=smtp.titan.email SMTP_PORT=465 SMTP_SECURE=true; do
  grep -qxF "$want" <<<"$d" || bad "derived section lacks ${want%%=*}"
done
[ "$(grep -cE "^[A-Z_]+=" <<<"$d")" = 6 ] || bad "derived section holds $(grep -cE "^[A-Z_]+=" <<<"$d") assignments, expected 6"

# ── 15. an explicit SMTP_HOST wins, mailpit included ────────────────────────
for host in mailpit smtp.other.example.test; do
  scenario=titan-host-$host
  t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW
SMTP_HOST=$host")"
  run_env "$t"
  [ "$rc" = 0 ] || bad "explicit SMTP_HOST=$host: exit $rc"
  d="$(derived_of "$t")"
  for k in SMTP_HOST SMTP_PORT SMTP_SECURE; do
    if grep -q "^$k=" <<<"$d"; then bad "$k derived although SMTP_HOST=$host is explicit"; fi
  done
  grep -qxF "SMTP_USER=$TITAN_MAIL" <<<"$d" || bad "SMTP_USER not derived next to an explicit SMTP_HOST"
  tail -1 <(grep '^SMTP_HOST=' "$t/.env") | grep -qxF "SMTP_HOST=$host" || bad "effective SMTP_HOST is not $host"
done

# ── 16. a differing explicit SMTP_PASS / SMTP_USER is refused by name ───────
scenario=titan-conflict
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW
SMTP_PASS=$OTHER_PW
SMTP_USER=other@titan.example.test")"
run_env "$t"
[ "$rc" = 1 ] || bad "a conflicting SMTP_PASS/SMTP_USER exited $rc, expected 1"
grep -q 'SMTP_USER' "$t/stderr" && grep -q 'SMTP_PASS' "$t/stderr" || bad "the refusal does not name both keys"
[ ! -f "$t/.env" ] || bad ".env written despite the refusal"
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW
SMTP_PASS=\"$TITAN_PW\"
SMTP_USER=$TITAN_MAIL")"
run_env "$t"
[ "$rc" = 0 ] || bad "an explicit SMTP_PASS/SMTP_USER equal to the alias was refused (exit $rc)"
n="$(grep -c '^SMTP_PASS=' "$t/.env")"
[ "$n" = 1 ] || bad "equal explicit SMTP_PASS: $n assignments in .env, expected 1 (not duplicated)"

# ── 17. rerun is byte-identical and the derived section is no orphan ────────
scenario=titan-rerun
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW")"
run_env "$t"
body_of "$t" >"$t/body1"
cp "$t/.env.local" "$t/local1"
run_env "$t"
[ "$rc" = 0 ] || bad "second run exited $rc (orphan refusal?)"
cmp -s <(body_of "$t") "$t/body1" || bad "second run is not byte-identical"
run_env "$t" ENV_ORPHANS=carry
[ "$rc" = 0 ] || bad "carry run exited $rc"
cmp -s "$t/.env.local" "$t/local1" || bad "ENV_ORPHANS=carry changed .env.local (a derived key was carried)"
# the alias moves to .env.secrets and .env.local is recreated: the first-run
# carry-over reads the old .env, whose SMTP_USER/SMTP_PASS are derived
rm "$t/.env.local"
printf 'TITAN_EMAIL=%s\nTITAN_PASSWORD=%s\n' "$TITAN_MAIL" "$TITAN_PW" >>"$t/.env.secrets"
run_env "$t"
[ "$rc" = 0 ] || bad "first-run carry-over exited $rc"
if grep -qE '^(SMTP_|EMAIL_FROM)' "$t/.env.local"; then bad "OPTIONAL_KEYS carry-over copied a derived key into .env.local"; fi
grep -qxF "SMTP_PASS=$TITAN_PW" "$t/.env" || bad "the alias in .env.secrets did not derive SMTP_PASS"
scenario=titan-alias-removed
sed -i '/^TITAN_/d' "$t/.env.secrets"
run_env "$t"
[ "$rc" = 0 ] || bad "removing the alias left an orphan refusal (exit $rc)"
if grep -q "$TITAN_PW" "$t/.env"; then bad "the password stayed in .env after the alias was removed"; fi

# ── 18. TITAN_* never reaches .env, and no value is printed ─────────────────
scenario=titan-no-leak
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW")"
printf 'TITAN_PASSWORD=%s\n' "$TITAN_PW" >>"$t/.env.secrets"
run_env "$t"
if grep -qE '^[[:space:]]*(export[[:space:]]+)?TITAN_[A-Z]*=' "$t/.env"; then bad "a TITAN_* assignment reached .env"; fi
grep -q '^# TITAN_PASSWORD= (alias' "$t/.env" || bad "no TITAN_PASSWORD alias comment in .env"
[ "$(grep -cF "$TITAN_PW" "$t/.env")" = 1 ] || bad "the password appears on $(grep -cF "$TITAN_PW" "$t/.env") lines of .env, expected the SMTP_PASS line only"
for stream in stdout stderr; do
  if grep -qF -e "$TITAN_PW" -e "$TITAN_MAIL" "$t/$stream"; then bad "a TITAN value reached $stream"; fi
done

# ── 19. no TITAN_* set: .env is exactly the three layers ────────────────────
scenario=titan-absent
t="$(titan_tree 'LLM_API_KEY=keep-me
SMTP_PASS=plain-explicit')"
run_env "$t"
{
  echo "# Edit the sources then re-run 'make env':"
  echo "#   config.env (committed) · .env.secrets (generated) · .env.local (yours)"
  echo
  echo "# ========== config.env =========="
  cat "$t/config.env"
  echo
  echo "# ========== .env.secrets =========="
  cat "$t/.env.secrets"
  echo
  echo "# ========== .env.local =========="
  cat "$t/.env.local"
} >"$t/expected"
cmp -s <(tail -n +2 "$t/.env") "$t/expected" || bad "without TITAN_*, .env differs from config + secrets + local"
if grep -q 'derived (TITAN' "$t/.env"; then bad "a derived section was written without TITAN_*"; fi

# ── 20. special characters survive docker compose ───────────────────────────
# compose_value <tree> <KEY> — what compose hands a service for ${KEY}. `config`
# prints a literal `$` as `$$`, undone here.
compose_value() {
  printf 'services:\n  probe:\n    image: scratch\n    environment:\n      V: ${%s}\n' "$2" >"$1/probe.yml"
  docker compose -f "$1/probe.yml" --env-file "$1/.env" config --format json 2>/dev/null |
    jq -r '.services.probe.environment.V' | sed 's/\$\$/$/g'
}
scenario=titan-compose
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "SKIP [$scenario] docker compose unavailable"
else
  # single-quoted (literal) and double-quoted (\$ and \\ escapes); same bytes expected.
  want_a='p$a#s"s\w d'
  want_b="p\$a#s'x\\w d"
  t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD='p\$a#s\"s\\w d'")"
  run_env "$t"
  [ "$(compose_value "$t" SMTP_PASS)" = "$want_a" ] || bad "single-quoted password changed through compose"
  t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=\"p\\\$a#s'x\\\\w d\"")"
  run_env "$t"
  [ "$(compose_value "$t" SMTP_PASS)" = "$want_b" ] || bad "double-quoted password changed through compose"
  [ "$(compose_value "$t" SMTP_USER)" = "$TITAN_MAIL" ] || bad "SMTP_USER changed through compose"
  [ "$(compose_value "$t" SMTP_HOST)" = smtp.titan.email ] || bad "SMTP_HOST changed through compose"
fi

# ── 21. a key the TITAN alias re-derives is no orphan of the old .env ───────
# Measured 2026-10-17 on the production VM: an .env hand-edited to hold
# SMTP_PASS in no layer, then TITAN_* added to .env.local, was still refused
# for SMTP_PASS although this very run writes it.
# stale_tree <local-body> <old-local-body> — a tree whose old .env holds the
# second body in its .env.local section, as a hand edit would have left it.
stale_tree() {
  local dir
  dir="$(titan_tree "$1")"
  printf '%s\n' "$2" >"$dir/old-local"
  write_old_env "$dir" "$dir/config.env" "$dir/.env.secrets" "$dir/old-local"
  printf '%s' "$dir"
}
scenario=titan-rederived-orphan
t="$(stale_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW" "SMTP_PASS=$TITAN_PW")"
run_env "$t"
[ "$rc" = 0 ] || bad "a key the alias re-derives was refused (exit $rc)"
if grep -q 'SMTP_PASS' "$t/stderr"; then bad "SMTP_PASS named although the alias re-derives it"; fi
grep -qxF "SMTP_PASS=$TITAN_PW" <<<"$(derived_of "$t")" || bad "derived section lacks SMTP_PASS"
if grep -qE '^[[:space:]]*(export[[:space:]]+)?TITAN_[A-Z]*=' "$t/.env"; then bad "a TITAN_* assignment reached .env"; fi

scenario=titan-rederived-plus-orphan
t="$(stale_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW" "SMTP_PASS=$TITAN_PW
FOO_ONLY_HERE=1")"
run_env "$t"
[ "$rc" = 1 ] || bad "a real orphan next to a re-derived key exited $rc, expected 1"
grep -q '^  FOO_ONLY_HERE$' "$t/stderr" || bad "the refusal does not name FOO_ONLY_HERE"
if grep -q 'SMTP_PASS' "$t/stderr"; then bad "the refusal names SMTP_PASS, which the alias re-derives"; fi

scenario=titan-explicit-host-orphan
# config.env ships SMTP_PORT, which would make it no orphan whatever the alias
# does; the scratch copy loses it so only the derived rule is under test.
t="$(titan_tree "TITAN_EMAIL=$TITAN_MAIL
TITAN_PASSWORD=$TITAN_PW
SMTP_HOST=other.example")"
sed -i '/^SMTP_PORT=/d' "$t/config.env"
printf 'SMTP_PORT=2525\n' >"$t/old-local"
write_old_env "$t" "$t/config.env" "$t/.env.secrets" "$t/old-local"
run_env "$t"
[ "$rc" = 1 ] || bad "SMTP_PORT with an explicit SMTP_HOST exited $rc, expected 1"
grep -q '^  SMTP_PORT$' "$t/stderr" || bad "the refusal does not name SMTP_PORT"

scenario=no-titan-orphan
t="$(stale_tree "LLM_API_KEY=keep-me" "SMTP_PASS=$TITAN_PW")"
run_env "$t"
[ "$rc" = 1 ] || bad "an SMTP_PASS orphan without TITAN_* exited $rc, expected 1"
grep -q '^  SMTP_PASS$' "$t/stderr" || bad "the refusal does not name SMTP_PASS"

# ── 12. no fixture value is ever printed ────────────────────────────────────
for tree in "$work"/*/; do
  [ -d "$tree" ] || continue
  for stream in stdout stderr; do
    for needle in "${NEEDLES[@]}"; do
      if grep -qF "$needle" "$tree$stream" 2>/dev/null; then
        echo "FAIL [$scenario] a fixture value reached $tree$stream (names only, never values)"
        red=1
      fi
    done
  done
done

# ── result ─────────────────────────────────────────────────────────────────
if [ "$fail" != 0 ]; then
  echo "FAILED: assemble-env-test.sh — scenarios: ${failed_scenarios[*]}"
  exit 1
fi
if [ "$red" != 0 ]; then
  echo "FAILED: a fixture value was printed (see above)"
  exit 1
fi
echo "ok: assemble-env withholds tokens (github + host-only), refuses/carries/drops"
echo "    orphans, never re-mints a lifted secret, and prints names only"
echo "    (${#NEEDLES[@]} fixture values never printed)"
exit 0
