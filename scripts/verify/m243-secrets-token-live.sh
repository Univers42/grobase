#!/usr/bin/env bash
# m243-secrets-token-live.sh — ADR 0023 F1, live: a deployed function reads its
# per-function secret whichever token the runtime resolves it with.
#
#   scoped  the .env as `make env` writes it: FUNCTION_SECRETS_TOKEN set, the same
#           value in functions-runtime and webhook-dispatcher → the secret arrives.
#   legacy  FUNCTION_SECRETS_TOKEN rendered empty in both (a .env from before the
#           key) → the runtime falls back to the shared token → the secret arrives.
#   wrong   only the runtime gets a different scoped token → no secret, and the
#           runtime's 401 log names the variable it sent, never its value.
#
# Each leg recreates functions-runtime and webhook-dispatcher from images already
# built (m197's CI step builds both from this commit); the trap puts both back on
# the .env as it is. The fixture secret is a throwaway value, not a credential.
# Token values are compared by sha256 inside this script and never printed.
#
# Needs the stack's postgres up (migration 037 is applied when missing) and .env.
# Caveat: proves the resolve path the runtime takes at invoke, not the cloud
# jail's relay (m197 covers that hop) and not helm, whose envFrom hands every pod
# the whole secret.

set -euo pipefail
cd "$(dirname "$0")/../.."
# Both services are profile-gated; compose 2.36 resolves a profiled service by
# name only when its profile is active.
DC=(docker compose -f docker-compose.yml --profile functions --profile control-plane)
RT=mini-baas-functions
WD=mini-baas-webhook-dispatcher
TENANT="m243s$$"
FIXTURE="m243-fixture-$$"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}

# recreate starts the services after `--` with the env assignments before it
# (FUNCTION_SECRETS_TOKEN taken from .env when none is given).
recreate() {
  local assign=()
  while [ "$1" != -- ]; do assign+=("$1") && shift; done
  shift
  env -u FUNCTION_SECRETS_TOKEN "${assign[@]}" "${DC[@]}" up -d --no-deps --no-build --force-recreate --wait "$@" \
    >/dev/null 2>&1 || fail "could not recreate $*: $("${DC[@]}" logs --tail 5 "$@" 2>&1 | tail -n 5)"
}
restore() { recreate -- functions-runtime webhook-dispatcher; }
trap restore EXIT

# token_hash prints sha256 of variable $2 in container $1's env ("empty" / "unset").
token_hash() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | awk -F= -v k="$2" '
    $1 == k { v = substr($0, length(k) + 2); found = 1 } END { if (!found) print "unset"; else if (v == "") print "empty"; else print v }' |
    { read -r v && case "${v}" in unset | empty) echo "${v}" ;; *) printf %s "${v}" | sha256sum | cut -c1-16 ;; esac }
}

# in_rt fetches from inside the runtime container: $1 method, $2 URL, $3 body.
in_rt() {
  docker exec -e M="$1" -e U="$2" -e B="${3:-}" -e T="${TENANT}" "${RT}" deno eval '
    const r = await fetch(Deno.env.get("U"), { method: Deno.env.get("M"), body: Deno.env.get("B") || undefined,
      headers: { "content-type": "application/json", "x-baas-tenant-id": Deno.env.get("T") } });
    console.log(r.status);
    console.log(await r.text());' 2>&1
}

# has_secret stores a secret for function $1, deploys $1 reading it, invokes it
# and prints the function's verdict (true when the secret arrived).
has_secret() {
  local r code
  r="$(in_rt POST http://webhook-dispatcher:3025/v1/function-secrets \
    "$(jq -nc --arg v "${FIXTURE}" --arg f "$1" '{key: "M243_KEY", value: $v, function_name: $f}')")"
  [ "$(head -n1 <<<"${r}")" = 201 ] || fail "store the fixture secret for $1: ${r:0:200}"
  # Without its secrets a function is not granted the env key at all: Deno throws
  # NotCapable on the read, which counts as "not arrived".
  code="export default () => { let has = false; try { has = Deno.env.get('M243_KEY') === '${FIXTURE}'; } catch { has = false; } return { status: 200, body: { has } }; };"
  r="$(in_rt POST http://127.0.0.1:3060/v1/functions "$(jq -nc --arg n "$1" --arg c "${code}" '{name: $n, code: $c}')")"
  [ "$(head -n1 <<<"${r}")" = 201 ] || fail "deploy $1: ${r:0:200}"
  r="$(in_rt POST "http://127.0.0.1:3060/v1/functions/$1/invoke" '{}')"
  [ "$(head -n1 <<<"${r}")" = 200 ] || fail "invoke $1: ${r:0:200}"
  tail -n +2 <<<"${r}" | jq -r '.has'
}

if [ "$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
  "SELECT to_regclass('public.function_secrets') IS NOT NULL")" != t ]; then
  docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f - \
    <scripts/migrations/postgresql/037_function_secrets.sql >/dev/null || fail "could not apply migration 037"
  recreate -- webhook-dispatcher
fi

printf '\033[1m• scoped: FUNCTION_SECRETS_TOKEN from .env in both\033[0m\n'
recreate -- functions-runtime webhook-dispatcher
rt="$(token_hash "${RT}" FUNCTION_SECRETS_TOKEN)"
case "${rt}" in unset | empty) fail "functions-runtime has FUNCTION_SECRETS_TOKEN ${rt} — run make env" ;; esac
[ "$(token_hash "${WD}" FUNCTION_SECRETS_TOKEN)" = "${rt}" ] || fail "the two holders differ on FUNCTION_SECRETS_TOKEN"
[ "$(has_secret m243scoped)" = true ] || fail "the secret did not arrive with the scoped token"
ok "same scoped token in both holders; the function read its secret"

printf '\033[1m• legacy: FUNCTION_SECRETS_TOKEN rendered empty in both\033[0m\n'
recreate FUNCTION_SECRETS_TOKEN= -- functions-runtime webhook-dispatcher
[ "$(token_hash "${RT}" FUNCTION_SECRETS_TOKEN)" = empty ] && [ "$(token_hash "${WD}" FUNCTION_SECRETS_TOKEN)" = empty ] ||
  fail "FUNCTION_SECRETS_TOKEN is not empty in the legacy leg"
[ "$(has_secret m243legacy)" = true ] || fail "the secret did not arrive through the shared-token fallback"
ok "empty scoped token on both sides; the shared token resolved the secret"

printf '\033[1m• wrong: the runtime alone sends another scoped token\033[0m\n'
recreate -- webhook-dispatcher
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
recreate "FUNCTION_SECRETS_TOKEN=m243-wrong-$$" -- functions-runtime
[ "$(has_secret m243wrong)" = false ] || fail "a wrong scoped token still resolved the secret"
logs="$(docker logs --since "${since}" "${RT}" 2>&1)"
grep -qF 'secret resolve failed: HTTP 401 (token from FUNCTION_SECRETS_TOKEN)' <<<"${logs}" ||
  fail "the runtime's 401 log does not name the token source"
! grep -qF "m243-wrong-$$" <<<"${logs}" || fail "the runtime logged the token value"
ok "401, no secret, the log names FUNCTION_SECRETS_TOKEN and not its value"

printf '\033[32mm243 secrets-token live checks passed\033[0m\n'
