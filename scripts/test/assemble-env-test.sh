#!/usr/bin/env bash
# Prove that `make env` never carries a GitHub token into .env.
#
# WHY
#   .env is handed to every container (`env_file: [.env]` appears in every
#   plane file), so a PAT in .env.local reached the whole stack, vendor
#   playground apps included, and every `make env` put it back. assemble-env.sh
#   now withholds token-shaped lines. This test is the mutant for that fix:
#   run it against the previous script and it goes red
#   (ASSEMBLE_ENV_SH=<(git show <old>:scripts/env/assemble-env.sh)).
#
# WHAT IT CHECKS, in a scratch tree so the real .env is never touched
#   1. a legitimate .env.local key still reaches .env
#   2. no ghp_/github_pat_ value reaches .env, whatever the key is called
#   3. every withheld key is named on stderr, once
#   4. the script still exits 0 (the rest of .env.local is valid)
#
# USAGE
#   bash scripts/test/assemble-env-test.sh      (make env-test)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSEMBLE="${ASSEMBLE_ENV_SH:-$ROOT/scripts/env/assemble-env.sh}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts/env"
cp "$ASSEMBLE" "$work/scripts/env/assemble-env.sh"
cp "$ROOT/scripts/env/generate-env.sh" "$work/scripts/env/"
cp "$ROOT/config.env" "$work/config.env"
printf 'JWT_SECRET=not-a-real-secret\n' >"$work/.env.secrets"
# Fake tokens: the documented shapes, with no real value behind them.
cat >"$work/.env.local" <<'EOF'
# a comment survives
LLM_API_KEY=keep-me
GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyzAB
SOME_OTHER_NAME=github_pat_11AAAAAAA0123456789abcdefghijklmnopqrstuv
GH_PAT="ghp_0123456789abcdefghijklmnopqrstuvwxyzCD"
EOF

fail=0
if ! bash "$work/scripts/env/assemble-env.sh" >/dev/null 2>"$work/stderr"; then
  echo "FAIL: assemble-env.sh exited non-zero (the rest of .env.local is valid)"
  fail=1
fi
grep -q '^LLM_API_KEY=keep-me$' "$work/.env" 2>/dev/null ||
  {
    echo "FAIL: a legitimate .env.local key did not reach .env"
    fail=1
  }
if grep -qE 'ghp_|github_pat_' "$work/.env" 2>/dev/null; then
  echo "FAIL: a GitHub token reached .env:"
  grep -nE 'ghp_|github_pat_' "$work/.env" | sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/\1<redacted>/'
  fail=1
fi
for k in GITHUB_TOKEN SOME_OTHER_NAME GH_PAT; do
  n=$(grep -c "$k looks like a GitHub token" "$work/stderr" 2>/dev/null || true)
  [ "${n:-0}" = 1 ] || {
    echo "FAIL: $k withheld $n time(s) on stderr, expected once"
    fail=1
  }
done
grep -q '^# a comment survives$' "$work/.env" ||
  {
    echo "FAIL: comments in .env.local no longer pass through"
    fail=1
  }

if [ "$fail" = 0 ]; then
  echo "ok: assemble-env withholds GitHub tokens (3 withheld, 1 legitimate key kept, exit 0)"
fi
exit "$fail"
