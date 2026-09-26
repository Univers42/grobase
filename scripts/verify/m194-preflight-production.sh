#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m194-preflight-production.sh — scripts/ops/preflight-production.sh must     #
#  refuse a dev-default env file, accept a hardened one, and never leak a      #
#  value                                                                       #
#                                                                              #
#  Base compose keeps well-known dev credential fallbacks for byte-parity, so  #
#  the check moved into a standalone preflight run against an env file. This   #
#  gate proves it on throwaway files (no live stack, no Docker):               #
#    dev      config.env + dev secrets          -> exit 1, each VAR named      #
#    leak     a sentinel value, also under sh -x / bash -x -> never printed    #
#    hardened random secrets + prod settings    -> exit 0, PASS                #
#    missing  hardened minus JWT_SECRET         -> exit 1, only JWT_SECRET     #
#    parser   export / quotes / ` #` / CRLF / URL-encoded or @-split DSN       #
#             passwords / last-wins / ${..} = UNKNOWN / realtime warn-only     #
#    advisory SECURITY_MODE / API_KEY_ABAC_ENABLED / DATA_PLANE_RATELIMIT_     #
#             BACKEND at dev values or unset -> exit 0 + one `!` line each     #
#    nnp      CONTAINER_NO_NEW_PRIVILEGES=false -> exit 1 named; with          #
#             CONTAINER_NO_NEW_PRIVILEGES_ACK=1 -> exit 0 + `!` line (m208)    #
#    source   `$(touch ...)` in a value is never executed                      #
#    drift    every credential `:-literal` fallback in compose/base/*.yml,     #
#             set as its literal or left unset, is named -> the denylist       #
#             cannot silently fall behind a new compose default                #
#    dsn      every `${NAME:-scheme://user:pw@..}` fallback, nested defaults   #
#             resolved (the *_URL names drift skips, PG_BACKUP_DATABASE_URL    #
#             included), set as that DSN -> named; unset -> named, or the key  #
#             it inherits its password from is named when unset too            #
#    usage    unreadable file -> exit 2                                        #
#                                                                              #
#  Mutant hook: M194_PREFLIGHT=<path> runs the arms against another copy of    #
#  the preflight; a copy that leaks a value, drops a default or resolves       #
#  ${..} must turn this gate red.                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}" || exit 1
PF="${M194_PREFLIGHT:-scripts/ops/preflight-production.sh}"
readonly DSN_AWK='
# fallback returns the text between `${NAME:-` and its matching brace.
function fallback(s,   o, i, c, d) {
	o = index(s, ":-") + 2
	d = 1
	for (i = o; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "$" && substr(s, i + 1, 1) == "{") { d++; i++; continue }
		if (c == "}" && --d == 0) break
	}
	return substr(s, o, i - o)
}
# source returns the key an unset NAME takes its password from: a whole-value
# `${X:-..}` chain or a `${X:-..}` password slot; empty for a literal password.
function source(fb,   v) {
	if (substr(fb, 1, 2) == "${") v = substr(fb, 3)
	else if (match(fb, /:\$\{[A-Za-z0-9_]+:-[^}]*\}@/)) v = substr(fb, RSTART + 3)
	else return ""
	return substr(v, 1, index(v, ":-") - 1)
}
# resolve replaces every nested `${X:-d}` with d, innermost first.
function resolve(v,   d) {
	while (match(v, /\$\{[A-Za-z0-9_]+:-[^${}]*\}/)) {
		d = substr(v, RSTART, RLENGTH)
		sub(/^\$\{[A-Za-z0-9_]+:-/, "", d)
		v = substr(v, 1, RSTART - 1) substr(d, 1, length(d) - 1) substr(v, RSTART + RLENGTH)
	}
	return v
}
{
	fb = fallback($0)
	dsn = resolve(fb)
	if (dsn ~ /^[a-z][a-z0-9+.-]*:\/\/[^\/@:]*:[^\/@]+@/)
		printf "%s\t%s\t%s\n", substr($0, 3, index($0, ":-") - 3), dsn, source(fb)
}
'
T="$(mktemp -d)" || exit 1
trap 'rm -rf "${T}"' EXIT
RC=0
OUT=""
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M194] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M194] FAIL — %s\033[0m\n' "$*" >&2
  [ -z "${OUT}" ] || printf '%s\n' "${OUT}" | sed 's/^/    | /' >&2
  exit 1
}

# rand prints $1 random bytes as lowercase hex.
rand() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

# run_pf runs the preflight on file $1 under shell $2 (default sh), keeping
# the exit code in RC and stdout+stderr in OUT.
run_pf() {
  OUT="$(${2:-sh} "${PF}" "$1" 2>&1 </dev/null)"
  RC=$?
}

# expect_fail asserts exit 1 on file $1 and that every later arg is named.
expect_fail() {
  local f="$1" v
  shift
  run_pf "${f}"
  [ "${RC}" = 1 ] || fail "expected exit 1 on ${f##*/}, got ${RC}"
  for v in "$@"; do
    grep -q "^  ✗ ${v} " <<<"${OUT}" || fail "${f##*/}: ${v} not named"
  done
}

# with_line writes hardened.env plus the line $2 to $T/$1 and prints its path.
with_line() {
  {
    cat "${T}/hardened.env"
    printf '%s\n' "$2"
  } >"${T}/$1"
  printf '%s' "${T}/$1"
}

# compose_fallbacks prints NAME<TAB>literal for every non-empty credential
# `${NAME:-literal}` fallback in the base plane files.
compose_fallbacks() {
  grep -ho -E '\$\{[A-Za-z0-9_]+:-[^}$]+' orchestrators/compose/base/*.yml |
    sed -E 's/^\$\{([A-Za-z0-9_]+):-(.*)$/\1\t\2/' |
    grep -E '^([A-Z0-9_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Z0-9_]*|MINIO_ROOT_[A-Z_]+)'$'\t' |
    grep -v -E '^[A-Z0-9_]*(_MODE|_ENABLED|_URL|_PREFIX|_MS|_TOKENS|_LENGTH|_INTERVAL)'$'\t' |
    sort -u
}

# compose_dsn_fallbacks prints NAME<TAB>dev DSN<TAB>source for every
# `${NAME:-scheme://user:pass@..}` fallback in the base plane files (the *_URL
# names compose_fallbacks drops), nested defaults resolved; see DSN_AWK.
compose_dsn_fallbacks() {
  grep -ho -E '\$\{[A-Za-z0-9_]+:-(\$\{[A-Za-z0-9_]+:-)*[a-z][a-z0-9+.-]*://[^[:space:]]*' \
    orchestrators/compose/base/*.yml | awk "${DSN_AWK}" | sort -u
}

# write_hardened builds a production-shaped env with fresh random secrets,
# plus a random value for every compose credential or DSN fallback name.
write_hardened() {
  local k pg au dsn
  pg="$(rand 16)"
  au="$(rand 16)"
  {
    while IFS=$'\t' read -r k dsn; do
      printf '%s=%s://grobase:%s@db:5432/app\n' "${k}" "${dsn%%://*}" "$(rand 16)"
    done <"${T}/dsns"
    cut -f1 "${T}/fallbacks" | while read -r k; do printf '%s=%s\n' "${k}" "$(rand 16)"; done
    for k in AUTHENTICATOR_PASSWORD ADAPTER_REGISTRY_SERVICE_TOKEN ANON_KEY SERVICE_ROLE_KEY \
      KONG_PUBLIC_API_KEY KONG_SERVICE_API_KEY MINIO_ROOT_PASSWORD MONGO_INITDB_ROOT_PASSWORD \
      LOG_STREAM_TOKEN PG_META_DB_PASSWORD SECRET_KEY_BASE MYSQL_ROOT_PASSWORD MYSQL_PASSWORD \
      MARIADB_ROOT_PASSWORD MARIADB_PASSWORD MSSQL_SA_PASSWORD; do
      printf '%s=%s\n' "${k}" "$(rand 16)"
    done
    printf 'POSTGRES_PASSWORD=%s\nJWT_SECRET=%s\nVAULT_ENC_KEY=%s\n' "${pg}" "$(rand 32)" "$(rand 16)"
    printf 'DATABASE_URL=postgres://postgres:%s@postgres:5432/postgres\n' "${pg}"
    printf 'ADAPTER_REGISTRY_DATABASE_URL=postgres://postgres:%s@postgres:5432/postgres\n' "${pg}"
    printf 'PGRST_DB_URI=postgres://authenticator:%s@postgres:5432/postgres\n' "${au}"
    printf 'MINIO_ROOT_USER=grobase-%s\nMONGO_INITDB_ROOT_USERNAME=grobase-%s\n' "$(rand 4)" "$(rand 4)"
    printf 'INTERNAL_IDENTITY_HMAC_KEYS=k1:%s\n' "$(rand 32)"
    printf 'GOTRUE_MAILER_AUTOCONFIRM=false\nSMTP_HOST=smtp.example.com\n'
    printf 'API_EXTERNAL_URL=https://api.example.com/auth/v1\nGOTRUE_SITE_URL=https://app.example.com\n'
    printf 'REALTIME_NAMESPACE_FALLBACK=deny\nSERVICE_TOKEN_MODE=hmac\n'
    printf 'SECURITY_MODE=max\nAPI_KEY_ABAC_ENABLED=1\nDATA_PLANE_RATELIMIT_BACKEND=redis\n'
    printf 'BACKUP_AGE_RECIPIENTS=age1%s\n' "$(rand 29)"
  } >"${T}/hardened.env"
}

# arm_dev proves config.env + dev secrets fails, naming each offender, and
# that the sentinel value never reaches output, xtrace included.
arm_dev() {
  local sentinel sh_
  sentinel="change-me-m194-$(rand 8)"
  {
    cat config.env
    printf 'POSTGRES_PASSWORD=postgres\nDATABASE_URL=postgres://postgres:postgres@postgres:5432/postgres\n'
    printf 'MINIO_ROOT_USER=minioadmin\nVAULT_ENC_KEY=0123456789abcdef0123456789abcdef\n'
    printf 'GOTRUE_MAILER_AUTOCONFIRM=true\nLOG_STREAM_TOKEN=%s\n' "${sentinel}"
  } >"${T}/dev.env"
  expect_fail "${T}/dev.env" POSTGRES_PASSWORD DATABASE_URL MINIO_ROOT_USER VAULT_ENC_KEY \
    GOTRUE_MAILER_AUTOCONFIRM LOG_STREAM_TOKEN SMTP_HOST API_EXTERNAL_URL
  ok "dev env: exit 1, POSTGRES_PASSWORD DATABASE_URL MINIO_ROOT_USER VAULT_ENC_KEY GOTRUE_MAILER_AUTOCONFIRM LOG_STREAM_TOKEN SMTP_HOST API_EXTERNAL_URL named"
  for sh_ in "sh" "sh -x" "bash -x"; do
    run_pf "${T}/dev.env" "${sh_}"
    [ "${RC}" = 1 ] || fail "${sh_}: expected exit 1, got ${RC}"
    ! grep -qF "${sentinel}" <<<"${OUT}" || {
      OUT=""
      fail "${sh_}: the sentinel value leaked into stdout/stderr"
    }
  done
  ok "sentinel value absent from stdout+stderr under sh, sh -x and bash -x"
}

# arm_hardened proves a hardened env passes and none of its values print.
arm_hardened() {
  local sh_ jwt pg
  jwt="$(sed -n 's/^JWT_SECRET=//p' "${T}/hardened.env" | tail -n1)"
  pg="$(sed -n 's/^POSTGRES_PASSWORD=//p' "${T}/hardened.env" | tail -n1)"
  for sh_ in "sh" "bash" "sh -x"; do
    run_pf "${T}/hardened.env" "${sh_}"
    [ "${RC}" = 0 ] || fail "${sh_}: hardened env expected exit 0, got ${RC}"
    grep -qx 'PASS' <<<"${OUT}" || fail "${sh_}: no PASS line"
    ! grep -q '^  ✗ ' <<<"${OUT}" || fail "${sh_}: hardened env produced an offender"
    ! grep -q '^  ! ' <<<"${OUT}" || fail "${sh_}: hardened env produced an advisory"
    ! grep -qF -e "${jwt}" -e "${pg}" <<<"${OUT}" || {
      OUT=""
      fail "${sh_}: a hardened value leaked"
    }
  done
  ok "hardened env: exit 0 + PASS under sh, bash and sh -x; no value printed"
}

# arm_missing proves one missing secret fails alone and by name.
arm_missing() {
  grep -v '^JWT_SECRET=' "${T}/hardened.env" >"${T}/missing.env"
  expect_fail "${T}/missing.env" JWT_SECRET
  [ "$(grep -c '^  ✗ ' <<<"${OUT}")" = 1 ] || fail "missing.env: expected exactly one offender"
  ok "hardened minus JWT_SECRET: exit 1, JWT_SECRET is the only offender"
}

# parser_cases prints one "EXPECTED_VAR|line appended to the hardened env" per
# bad compose .env form (CRLF last, via printf).
parser_cases() {
  cat <<'CASES'
POSTGRES_PASSWORD|export POSTGRES_PASSWORD=postgres
POSTGRES_PASSWORD|POSTGRES_PASSWORD='postgres'
POSTGRES_PASSWORD|POSTGRES_PASSWORD="postgres"
POSTGRES_PASSWORD|POSTGRES_PASSWORD=postgres   # rotated later
POSTGRES_PASSWORD|POSTGRES_PASSWORD=POSTGRES
POSTGRES_PASSWORD|POSTGRES_PASSWORD="pre$SUFFIX"
DATABASE_URL|DATABASE_URL=postgres://postgres:%70ostgres@postgres:5432/postgres
DATABASE_URL|DATABASE_URL=postgres://postgres:postgres@postgres:5432/postgres?application_name=a@b
DATABASE_URL|DATABASE_URL=postgres://postgres@postgres:5432/postgres
JWT_SECRET|JWT_SECRET= # set me
JWT_SECRET|JWT_SECRET=0123456789abcdef
JWT_SECRET|JWT_SECRET=${JWT_FROM_VAULT}
SMTP_HOST|SMTP_HOST=${RELAY}
MINIO_ROOT_PASSWORD|MINIO_ROOT_PASSWORD=your-super-secret-and-long-password
SERVICE_ROLE_KEY|SERVICE_ROLE_KEY=CHANGEME
ENGINE_BIND_ADDR|ENGINE_BIND_ADDR=0.0.0.0
SERVICE_TOKEN_MODE|SERVICE_TOKEN_MODE=legacy
GOTRUE_SITE_URL|GOTRUE_SITE_URL=http://127.0.0.1:5173
CASES
  printf 'POSTGRES_PASSWORD|POSTGRES_PASSWORD=postgres\r\n'
}

# arm_parser_fail proves every parser_cases form is caught and named.
arm_parser_fail() {
  local c i=0
  local -a cases
  mapfile -t cases < <(parser_cases)
  [ "${#cases[@]}" -ge 19 ] || fail "parser_cases produced ${#cases[@]} cases"
  for c in "${cases[@]}"; do
    i=$((i + 1))
    expect_fail "$(with_line "p${i}.env" "${c#*|}")" "${c%%|*}"
  done
  expect_fail "$(with_line unknown.env 'JWT_SECRET=${JWT_FROM_VAULT}')" JWT_SECRET
  grep -q 'JWT_SECRET — unresolvable.*UNKNOWN = FAIL' <<<"${OUT}" || fail "\${...} not reported as UNKNOWN"
  ok "${i} bad forms caught: export, quotes, inline #, CRLF, case, \${..}/\$NAME, %XX, @-split, no-password DSN, short, wildcard bind"
}

# arm_advisories proves SECURITY_MODE, API_KEY_ABAC_ENABLED and
# DATA_PLANE_RATELIMIT_BACKEND at their dev values, or unset, each print an
# advisory line and still pass.
arm_advisories() {
  local f k
  run_pf "$(with_line advisory.env "$(printf 'SECURITY_MODE=baseline\nAPI_KEY_ABAC_ENABLED=0\nDATA_PLANE_RATELIMIT_BACKEND=memory')")"
  [ "${RC}" = 0 ] || fail "dev advisory values must only warn — got ${RC}"
  for k in SECURITY_MODE API_KEY_ABAC_ENABLED DATA_PLANE_RATELIMIT_BACKEND; do
    grep -q "^  ! ${k} " <<<"${OUT}" || fail "no advisory line for ${k} at its dev value"
  done
  f="${T}/unset.env"
  grep -vE '^(SECURITY_MODE|API_KEY_ABAC_ENABLED|DATA_PLANE_RATELIMIT_BACKEND)=' "${T}/hardened.env" >"${f}"
  run_pf "${f}"
  [ "${RC}" = 0 ] || fail "unset advisory keys must only warn — got ${RC}"
  for k in SECURITY_MODE API_KEY_ABAC_ENABLED DATA_PLANE_RATELIMIT_BACKEND; do
    grep -q "^  ! ${k} " <<<"${OUT}" || fail "no advisory line for ${k} when unset"
  done
  ok "SECURITY_MODE, API_KEY_ABAC_ENABLED, DATA_PLANE_RATELIMIT_BACKEND: dev value or unset = advisory only (exit 0)"
}

# arm_backups proves BACKUP_AGE_RECIPIENTS unset only warns and
# BACKUP_AGE_IDENTITY_FILE set is refused by name.
arm_backups() {
  grep -v '^BACKUP_AGE_RECIPIENTS=' "${T}/hardened.env" >"${T}/plain-backups.env"
  run_pf "${T}/plain-backups.env"
  [ "${RC}" = 0 ] || fail "BACKUP_AGE_RECIPIENTS unset must only warn — got ${RC}"
  grep -q '^  ! BACKUP_AGE_RECIPIENTS ' <<<"${OUT}" || fail "no advisory line for BACKUP_AGE_RECIPIENTS unset"
  expect_fail "$(with_line identity.env 'BACKUP_AGE_IDENTITY_FILE=/secrets/backup-age.key')" BACKUP_AGE_IDENTITY_FILE
  ok "BACKUP_AGE_RECIPIENTS unset = advisory (exit 0); BACKUP_AGE_IDENTITY_FILE in the env file refused by name"
}

# arm_no_new_privileges proves CONTAINER_NO_NEW_PRIVILEGES=false is refused by
# name, accepted with a warning under CONTAINER_NO_NEW_PRIVILEGES_ACK=1, and
# that true (or unset, in hardened.env) passes silently.
arm_no_new_privileges() {
  expect_fail "$(with_line nnp-off.env 'CONTAINER_NO_NEW_PRIVILEGES=false')" CONTAINER_NO_NEW_PRIVILEGES
  run_pf "$(with_line nnp-ack.env "$(printf 'CONTAINER_NO_NEW_PRIVILEGES=false\nCONTAINER_NO_NEW_PRIVILEGES_ACK=1')")"
  [ "${RC}" = 0 ] || fail "an acknowledged CONTAINER_NO_NEW_PRIVILEGES=false must only warn — got ${RC}"
  grep -q '^  ! CONTAINER_NO_NEW_PRIVILEGES ' <<<"${OUT}" || fail "no warning line for an acknowledged opt-out"
  run_pf "$(with_line nnp-on.env 'CONTAINER_NO_NEW_PRIVILEGES=true')"
  [ "${RC}" = 0 ] || fail "CONTAINER_NO_NEW_PRIVILEGES=true must pass — got ${RC}"
  ! grep -q 'CONTAINER_NO_NEW_PRIVILEGES' <<<"${OUT}" || fail "CONTAINER_NO_NEW_PRIVILEGES=true must not be mentioned"
  ok "CONTAINER_NO_NEW_PRIVILEGES: false refused, false + ACK=1 warns, true silent (m208)"
}

# arm_parser_pass proves last-wins, single-quoted literals, inline comments
# and a non-deny realtime fallback do not fail a hardened env.
arm_parser_pass() {
  {
    printf 'POSTGRES_PASSWORD=postgres\n'
    cat "${T}/hardened.env"
  } >"${T}/lastwins.env"
  run_pf "${T}/lastwins.env"
  [ "${RC}" = 0 ] || fail "last assignment must win (default first, strong last) — got ${RC}"
  run_pf "$(with_line literal.env "LOG_STREAM_TOKEN='lit\$eral-\$abc-$(rand 8)'")"
  [ "${RC}" = 0 ] || fail "single-quoted \$NAME is literal, not UNKNOWN — got ${RC}"
  run_pf "$(with_line comment.env "LOG_STREAM_TOKEN=$(rand 12)   # rotated 2026")"
  [ "${RC}" = 0 ] || fail "unquoted inline comment must be stripped — got ${RC}"
  run_pf "$(with_line realtime.env 'REALTIME_NAMESPACE_FALLBACK=permissive')"
  [ "${RC}" = 0 ] || fail "REALTIME_NAMESPACE_FALLBACK must only warn — got ${RC}"
  grep -q '! REALTIME_NAMESPACE_FALLBACK' <<<"${OUT}" || fail "no advisory line for a permissive realtime fallback"
  ok "last-wins, single-quoted \$, inline comment pass; realtime permissive = advisory only (exit 0)"
}

# arm_source proves command substitutions in values are never executed.
arm_source() {
  {
    cat "${T}/hardened.env"
    printf 'EVIL=$(touch "%s/pwned")\nEVIL2=`touch %s/pwned2`\n' "${T}" "${T}"
  } >"${T}/evil.env"
  run_pf "${T}/evil.env"
  [ "${RC}" = 0 ] || fail "evil.env expected exit 0 (EVIL is not a checked key), got ${RC}"
  [ ! -e "${T}/pwned" ] && [ ! -e "${T}/pwned2" ] || fail "a value was executed — the file is being sourced"
  ok "\$(..) and backticks in values never executed (parsed, not sourced)"
}

# arm_drift proves every credential fallback literal in compose/base is
# caught, both when set as that literal and when left unset.
arm_drift() {
  local n name lit
  n="$(wc -l <"${T}/fallbacks")"
  [ "${n}" -ge 10 ] || fail "only ${n} credential fallbacks extracted from compose/base — the extraction broke"
  while IFS=$'\t' read -r name lit; do
    case "${lit}" in *"'"*) fail "${name} fallback holds a quote; cannot encode it" ;; esac
    expect_fail "$(with_line drift.env "${name}='${lit}'")" "${name}"
    grep -v "^${name}=" "${T}/hardened.env" >"${T}/unset.env"
    expect_fail "${T}/unset.env" "${name}"
  done <"${T}/fallbacks"
  ok "${n} compose credential fallbacks: each caught as its literal and when unset ($(cut -f1 "${T}/fallbacks" | tr '\n' ' '))"
}

# arm_dsn_drift proves every compose DSN fallback with a password is covered:
# set to its dev DSN it is named; unset, it is named, or (when it inherits its
# password) its source key is named once that is unset too.
arm_dsn_drift() {
  local n name dsn src
  n="$(wc -l <"${T}/dsns")"
  [ "${n}" -ge 5 ] || fail "only ${n} DSN fallbacks extracted from compose/base — the extraction broke"
  grep -q $'^PG_BACKUP_DATABASE_URL\tpostgres://postgres:postgres@[^\t]*\tDATABASE_URL$' "${T}/dsns" ||
    fail "ops.yml PG_BACKUP_DATABASE_URL -> DATABASE_URL chain not extracted"
  while IFS=$'\t' read -r name dsn src; do
    case "${dsn}" in *"'"*) fail "${name} DSN fallback holds a quote; cannot encode it" ;; esac
    expect_fail "$(with_line "dsn-${name}.env" "${name}='${dsn}'")" "${name}"
    grep -v "^${name}=" "${T}/hardened.env" >"${T}/dsn-unset.env"
    [ -n "${src}" ] || {
      expect_fail "${T}/dsn-unset.env" "${name}"
      continue
    }
    grep -v "^${src}=" "${T}/dsn-unset.env" >"${T}/dsn-src.env"
    expect_fail "${T}/dsn-src.env" "${src}"
  done <"${T}/dsns"
  ok "${n} compose DSN fallbacks: each caught as its dev DSN; unset, caught or inherited from a caught key ($(awk -F'\t' '{ printf "%s%s ", $1, ($3 == "" ? "" : "<-" $3) }' "${T}/dsns"))"
}

# arm_usage proves an unreadable file exits 2 and --help exits 0.
arm_usage() {
  run_pf "${T}/does-not-exist.env"
  [ "${RC}" = 2 ] || fail "missing file expected exit 2, got ${RC}"
  run_pf --help
  [ "${RC}" = 0 ] || fail "--help expected exit 0, got ${RC}"
  ok "missing file -> exit 2; --help -> exit 0"
}

# arm_prod_up: `make prod-up` must run the preflight on .env BEFORE compose up
# (a refused env stops the recipe), layer the prod overlay, and never resolve-ports.
arm_prod_up() {
  local plan pf up
  plan="$(make -n --no-print-directory prod-up 2>/dev/null)" || fail "make -n prod-up failed"
  pf="$(grep -n 'preflight-production.sh .env' <<<"${plan}" | head -1 | cut -d: -f1)"
  up="$(grep -n 'docker-compose.prod.yml.* up -d' <<<"${plan}" | head -1 | cut -d: -f1)"
  [ -n "${pf}" ] || fail "prod-up does not run the preflight on .env"
  [ -n "${up}" ] || fail "prod-up does not bring the stack up with docker-compose.prod.yml"
  [ "${pf}" -lt "${up}" ] || fail "prod-up runs compose up before the preflight"
  ! grep -q 'resolve-ports' <<<"${plan}" || fail "prod-up must not auto-move busy ports"
  ok "make prod-up: preflight .env -> compose up with the prod overlay, no resolve-ports"
}

command -v od >/dev/null || fail "od is required"
step "extract credential fallbacks from orchestrators/compose/base/*.yml"
compose_fallbacks >"${T}/fallbacks" || fail "fallback extraction failed"
compose_dsn_fallbacks >"${T}/dsns" || fail "DSN fallback extraction failed"
write_hardened
step "(a) dev-default env and value leak"
arm_dev
step "(b) hardened env"
arm_hardened
step "(c) one missing secret"
arm_missing
step "(d) parser semantics"
arm_parser_fail
arm_parser_pass
arm_advisories
arm_no_new_privileges
arm_backups
step "(e) never sourced"
arm_source
step "(f) drift against compose defaults"
arm_drift
arm_dsn_drift
step "(g) usage"
arm_usage
step "(h) make prod-up wiring"
arm_prod_up
printf '\033[0;32m[M194] PASS — preflight-production refuses dev env files, accepts hardened ones, never prints a value\033[0m\n'
