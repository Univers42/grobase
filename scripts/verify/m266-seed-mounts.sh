#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m266-seed-mounts.sh — a restored seed's mounts open on this machine         #
#                                                                              #
#  Each mount's DSN is sealed with the source's engine password. vault-restore #
#  kept the engines on this machine's logins, so on 2026-11-04 every mount on  #
#  a platform engine answered 502 with the stack healthy and `make all` green. #
#  Hermetic: docker and curl are stubbed, nothing is started.                  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT" || exit 1
rc=0
ok() { printf '  ✓ %s\n' "$1"; }
fail() {
  printf '[M266] FAIL — %s\n' "$1"
  rc=1
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
GROBASE_ROOT="$ROOT"
export GROBASE_ROOT
# shellcheck source=../lib/lib-mount-rebind.sh
. scripts/lib/lib-mount-rebind.sh

printf 'VAULT_ENC_KEY=from-env\n' >"$T/env"
engines='[{"Name":"/mini-baas-postgres","Config":{"Env":["POSTGRES_USER=postgres","POSTGRES_PASSWORD=here"]},"Args":[]},
{"Name":"/mini-baas-redis","Config":{"Env":[]},"Args":[]}]'
stack='[{"Name":"/mini-baas-tenant-control","Config":{"Env":["VAULT_ENC_KEY=from-container"]},"Args":[]},
{"Name":"/mini-baas-postgres","Config":{"Env":["POSTGRES_USER=postgres","POSTGRES_PASSWORD=here"]},"Args":[]}]'
split='[{"Name":"/a","Config":{"Env":["VAULT_ENC_KEY=one"]},"Args":[]},{"Name":"/b","Config":{"Env":["VAULT_ENC_KEY=two"]},"Args":[]}]'
config() { # <inspect json> <envkey> <jq filter on the result>
  printf '%s' "$1" | jq -c --rawfile srcenv "$T/env" --argjson envkey "$2" "$(rebind_config_program)" 2>/dev/null | jq -r "$3" 2>/dev/null
}

# ── the config ──────────────────────────────────────────────────────────────
check "engines alone: the target key is .env's" "$(config "$engines" true .target_key)" from-env
check "... the logins are the running engine's" \
  "$(config "$engines" true '.targets[] | select(.engine=="postgresql") | .password')" here
check "a running stack's key wins over .env's" "$(config "$stack" true .target_key)" from-container
check "import path: no key in a container still refuses" "$(config "$engines" false .target_key)" ""
check "two keys in use refuse, whichever path" "$(config "$split" true .target_key)" ""
check "no reseat asked: an empty map, the import path unchanged" "$(config "$stack" false '.reseat | length')" 0
reseats=$(awk '/^reseat_mounts\(\) \{/,/^}/' scripts/ops/vault-restore.sh)
eval "$reseats"
check "contracts name their mounts' databases" "$(reseat_mounts | jq -r '."website-pg" + " " + ."vault42-pg"')" "website vault42"
check "... and only contracts do" "$(reseat_mounts | jq -r 'has("gourmand-app-db")')" false
check "... the smoke contract is not a real mount" "$(reseat_mounts | jq -r 'keys | map(select(startswith("_"))) | length')" 0

# ── the restore ─────────────────────────────────────────────────────────────
cat >"$T/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
ps) echo abc ;;
inspect) cat "$FIXTURE" ;;
run)
  IFS= read -r line
  printf '%s\n' "$line" >"$SEEN"
  [ "${REBIND:-ok}" = ok ] || { echo 'mount-rebind: row r1 refused' >&2; exit 2; }
  cat
  echo '{"blocks":1,"rows":[{"id":"r1","engine":"mysql","outcome":"rebound: target password written"}]}' >&2
  ;;
esac
STUB
chmod +x "$T/bin/docker"
printf '%s' "$engines" >"$T/inspect.json"
printf 'SELECT 1;\n' | gzip >"$T/postgres-all.sql.gz"
cp "$T/env" "$T/dotenv"
block=$(awk '/^rebind_seed_mounts\(\) \{/,/^}/' scripts/ops/vault-restore.sh)
restore() { # <ok|fail> -> rc, in a subshell so the stubbed die stays here
  # shellcheck disable=SC2030 # that subshell is the point
  (
    reseat_mounts() { printf '{}'; }
    cd "$T" || exit 9
    cp dotenv .env
    die() {
      printf 'die: %s\n' "$*"
      exit 1
    }
    note() { printf '%s\n' "$*"; }
    STATE_DIR="$T/first/run" SEED_DIR="$T"
    export FIXTURE="$T/inspect.json" SEEN="$T/seen" REBIND="$1" PATH="$T/bin:$PATH"
    eval "$block"
    rebind_seed_mounts
  ) >"$T/out" 2>&1
  printf '%s' "$?"
}
check "the rewrite succeeds" "$(restore ok)" 0
check "... the dump lands in the file the replay reads" "$(cat "$T/first/run/postgres-rebound.sql")" "SELECT 1;"
check "... each outcome is reported" "$(grep -c '^postgres: mounts: 1 rebound' "$T/out")" 1
check "... no secret reaches the output" "$(grep -cE 'from-env|here' "$T/out")" 0
check "... the report is kept, by row" "$(jq -r '.rows[0].id' "$T/first/run/mounts-rebound.json")" r1
check "... the tool got the config first" "$(jq -r .source_key "$T/seen")" from-env
check "a refused row stops the restore" "$(restore fail)" 1
check "... and says why" "$(grep -c 'row r1 refused' "$T/out")" 1
check "... and leaves no half file" "$([ -e "$T/first/run/postgres-rebound.sql" ] && echo left || echo gone)" gone

body=$(awk '/^restore_postgres\(\) \{/,/^}/' scripts/ops/vault-restore.sh)
line_of() { printf '%s\n' "$body" | grep -n "$1" | head -n1 | cut -d: -f1; }
check "rebinding precedes the destructive clear" \
  "$([ "$(line_of '^  rebind_seed_mounts')" -lt "$(line_of '^  clear_postgres_db')" ] && echo yes)" yes
check "a reseated mount's database is made after the replay" \
  "$([ "$(line_of '^  pg_strip_role_passwords')" -lt "$(line_of '^  ensure_reseated_databases')" ] && echo yes)" yes
check "what was retired goes once the replay has loaded it" \
  "$([ "$(line_of '^  pg_strip_role_passwords')" -lt "$(line_of '^  retire_seed_tenants')" ] && echo yes)" yes
check "the replay never reads the seed as it came" "$(printf '%s\n' "$body" | grep -c 'SEED_DIR/postgres-all')" 0

# ── the mounts open ─────────────────────────────────────────────────────────
cat >"$T/bin/curl" <<'STUB'
#!/bin/sh
echo '[{"id":"a1","engine":"mysql","name":"shop"},{"id":"b2","engine":"mssql","name":"finance"}]'
STUB
chmod +x "$T/bin/curl"
probe=$(awk '/^probe_mounts\(\) \{/,/^}/' scripts/seed/osionos-extra-engines.sh)
probe_with() { # <code for b2> -> rc
  # shellcheck disable=SC2031 # each subshell sets its own PATH
  (
    step() { :; }
    cyan() { :; }
    warn() { printf 'warn: %s\n' "$*"; }
    pass() { printf 'pass: %s\n' "$*"; }
    fail() {
      printf 'fail: %s\n' "$*"
      exit 1
    }
    engine_check() { if [ "$1" = b2 ]; then printf '%s' "$B2"; else printf 200; fi; }
    B2="$1" KONG_URL=x SERVICE_KEY=x TENANT=t PATH="$T/bin:$PATH"
    : >/tmp/xeng-gw.json
    eval "$probe"
    probe_mounts
  ) >"$T/out" 2>&1
  printf '%s' "$?"
}
check "every mount answers: the probe passes" "$(probe_with 200)" 0
check "a 502 fails the seed" "$(probe_with 502)" 1
check "... naming the mount" "$(grep -c 'finance (mssql, b2)' "$T/out")" 1
check "a 403 is this key's rights, not a dead login" "$(probe_with 403)" 0
tables=$(awk '/^sqlite_has_tables\(\) \{/,/^}/' scripts/seed/osionos-extra-engines.sh)
sqlite_with() { # <json the schema answers with> -> rc
  # shellcheck disable=SC2030,SC2031 # each subshell is its own case
  (
    pass() { :; }
    fail() { exit 1; }
    engine_check() {
      printf '%s' "$BODY" >/tmp/xeng-gw.json
      printf 200
    }
    BODY="$1" SQLITE_DB_ID=s1
    eval "$tables"
    sqlite_has_tables
  ) >/dev/null 2>&1
  printf '%s' "$?"
}
check "a mount with no tables fails the seed" "$(sqlite_with '{"resources":[]}')" 1
check "... the same mount with its tables passes" "$(sqlite_with '{"resources":[{"name":"restaurant"}]}')" 0
plane=$(awk '/^wait_query_plane\(\) \{/,/^}/' scripts/seed/osionos-extra-engines.sh)
plane_with() { # <the answers, one per call; the last repeats> -> rc
  # shellcheck disable=SC2030,SC2031 # each subshell is its own case
  (
    fail() {
      printf 'fail: %s\n' "$*"
      exit 1
    }
    sleep() { :; }
    printf '%s\n' $1 >"$T/answers"
    gw() {
      head -n1 "$T/answers"
      [ "$(wc -l <"$T/answers")" -eq 1 ] || sed -i 1d "$T/answers"
    }
    KONG_URL=x
    eval "$plane"
    wait_query_plane
  ) >"$T/out" 2>&1
  printf '%s' "$?"
}
check "a router still booting is waited for" "$(plane_with '000 502 502 200')" 0
check "... and any answer from it counts" "$(plane_with '502 401')" 0
check "a router that never answers fails the seed" "$(plane_with 502)" 1
check "... naming the route" "$(grep -c 'query/v1/capabilities -> 502' "$T/out")" 1
run_section=$(awk '/^# ── run/,0' scripts/seed/osionos-extra-engines.sh)
check "the wait comes before any mount is opened" "$(printf '%s\n' "$run_section" | grep -n '^wait_query_plane\|^seed_sqlite' | head -n1 | cut -d: -f2)" wait_query_plane
rows=$(awk '/^sqlite_load_rows\(\) \{/,/^}/' scripts/seed/osionos-extra-engines.sh)
rows_with() { # <the code every insert gets> -> rc; two tables, three rows
  # shellcheck disable=SC2030,SC2031 # each subshell is its own case
  (
    warn() { printf 'warn: %s\n' "$*"; }
    sleep() { :; }
    CODE="$1" ANON_KEY=x APP_KEY=x KONG_URL=x SQLITE_DB_ID=x
    curl() {
      echo x >>"$T/calls"
      printf '%s' "$CODE"
    }
    : >"$T/calls"
    eval "$rows"
    printf 'restaurant\t{}\nmenu\t{}\ndish\t{}\n' | sqlite_load_rows
  ) >"$T/out" 2>&1
  printf '%s' "$?"
}
check "every row loaded: the load passes" "$(rows_with 201)" 0
check "a row already there is not a failure" "$(rows_with 409)" 0
check "a refused row fails the load" "$(rows_with 400)" 1
check "... after trying the others" "$(grep -c '^warn: sqlite: insert' "$T/out")" 3
check "a broken mount fails the load" "$(rows_with 502)" 1
check "... at the first row, on bounded retries" "$(wc -l <"$T/calls")" 6
check "migrate-mongo authenticates" "$(grep -c 'authenticationDatabase admin mini_baas --file' orchestrators/makes/50-migrate.mk)" 1
check "... and stops at a failed file" "$(awk '/^migrate-mongo:/,/applied/' orchestrators/makes/50-migrate.mk | grep -c '@set -e')" 1
check "after a restore only sqlite is loaded" \
  "$(awk '/^# ── run/,0' scripts/seed/osionos-extra-engines.sh | sed -n '/AFTER_RESTORE/,/^fi/p' | grep -c 'seed_mssql\|seed_dynamo\|seed_edges')" 0

exit "$rc"
