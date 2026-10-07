#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m214-env-schema.sh — configuration and secrets are separated, by schema     #
#                                                                              #
#  infra/config/env/schema.json classifies every env key. This gate holds the  #
#  tree to it, so the separation cannot rot back:                              #
#                                                                              #
#   SCHEMA    the file parses; every key has a known category; a SECRET names   #
#             a vault42 path or is derived; required_in lists real environments.#
#   COMPOSE   no SECRET carries a literal default (the 45 published credentials #
#             that used to let a stack boot without .env); every key the        #
#             compose tree marks required is a schema key.                      #
#   COMMITTED no SECRET value sits in a tracked file: config.env holds no       #
#             schema SECRET, and .env.example / .env.local.example carry only   #
#             empty or CHANGE_ME placeholders.                                  #
#   PUBLIC    no SECRET is exposed under a browser-facing name (PUBLIC_*,       #
#             VITE_*, NEXT_PUBLIC_*), in the schema or in a contract's          #
#             frontend_config.                                                  #
#   ENVIRON   GROBASE_ENV is declared, defaulted in config.env, and its allowed #
#             values match the vault42 environments.                            #
#   MUTANTS   each check refuses the way back in.                               #
#                                                                              #
#  Static only: no stack, no credential read, no value ever printed.            #
#                                                                              #
# **************************************************************************** #
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA="${ROOT}/infra/config/env/schema.json"
# shellcheck source=../lib/lib-required-env.sh
. "${SCRIPT_DIR}/../lib/lib-required-env.sh"

_B=$'\033[0;36m' _G=$'\033[0;32m' _R=$'\033[0;31m' _0=$'\033[0m'
rc=0
step() { printf '%s[M214] %s%s\n' "${_B}" "$1" "${_0}"; }
ok() { printf '%s  ✓ %s%s\n' "${_G}" "$1" "${_0}"; }
fail() {
  printf '%s[M214] FAIL — %s%s\n' "${_R}" "$1" "${_0}"
  rc=1
}

command -v jq >/dev/null || {
  fail "jq is required"
  exit 1
}
[ -f "${SCHEMA}" ] || {
  fail "no ${SCHEMA#"${ROOT}"/}"
  exit 1
}

# ── SCHEMA ───────────────────────────────────────────────────────────────────
schema_arm() {
  step "SCHEMA — every key classified, every SECRET addressable"
  jq -e . "${SCHEMA}" >/dev/null 2>&1 || {
    fail "schema.json does not parse"
    return
  }
  local cats bad n
  cats="$(jq -r '.categories | keys[]' "${SCHEMA}")"
  bad="$(jq -r --argjson c "$(jq -c '.categories|keys' "${SCHEMA}")" \
    '.keys | to_entries[] | select((.value.category // "") as $k | ($c | index($k)) == null)
     | .key' "${SCHEMA}")"
  [ -z "${bad}" ] || fail "unknown category: $(tr '\n' ' ' <<<"${bad}")"
  # A SECRET is either stored (vault42_path) or rebuilt (derived_from) — never neither,
  # or there is nowhere for it to come from.
  bad="$(jq -r '.keys | to_entries[]
    | select(.value.category == "SECRET")
    | select((.value.vault42_path // "") == "" and (.value.derived_from // "") == "")
    | .key' "${SCHEMA}")"
  [ -z "${bad}" ] || fail "SECRET with no vault42_path and no derived_from: $(tr '\n' ' ' <<<"${bad}")"
  # required_in must name declared environments only.
  bad="$(jq -r --argjson e "$(jq -c '.environments' "${SCHEMA}")" \
    '.keys | to_entries[] | select([(.value.required_in // [])[] | select(($e|index(.))==null)] | length > 0)
     | .key' "${SCHEMA}")"
  [ -z "${bad}" ] || fail "required_in names an undeclared environment: $(tr '\n' ' ' <<<"${bad}")"
  n="$(jq -r '[.keys[] | select(.category=="SECRET")] | length' "${SCHEMA}")"
  [ "${n}" -ge 20 ] || fail "only ${n} SECRET keys classified — schema looks truncated"
  [ "${rc}" -eq 0 ] && ok "$(jq -r '.keys|length' "${SCHEMA}") keys, ${n} SECRET, categories $(tr '\n' ' ' <<<"${cats}")"
}

# ── COMPOSE ──────────────────────────────────────────────────────────────────
# literal_defaults prints `file:line KEY` for every schema SECRET whose compose
# fallback is a PUBLISHED credential: a default that is plain text. `${K:-}` (empty)
# and `${K:-$OTHER}` are not. Neither is a default that interpolates its credential
# from a required variable, e.g.
#   ${PGRST_DB_URI:-postgres://authenticator:${AUTHENTICATOR_PASSWORD:?}@pg/db}
# which publishes a USER and a HOST but no secret — the password still has to be set.
#
# Ponytail: "contains ${" is the test, so a default that mixes a literal password with
# an unrelated interpolation (…:-postgres://u:realpw@h/db?opt=${X}) is missed. It
# under-reports in exactly that shape; a fully literal default, which is what every
# historical offender was, is always caught.
literal_defaults() {
  local tree="$1" keys re
  keys="$(jq -r '.keys | to_entries[] | select(.value.category=="SECRET") | .key' "${SCHEMA}" | paste -sd '|' -)"
  [ -n "${keys}" ] || {
    echo "SCHEMA:0 no-secret-keys-in-schema"
    return
  }
  # A key with a regex metacharacter would silently break the alternation below, so
  # the shape is asserted rather than assumed.
  printf '%s\n' "${keys}" | tr '|' '\n' | grep -qvE '^[A-Z][A-Z0-9_]*$' &&
    echo "SCHEMA:0 secret-key-name-is-not-A-Z0-9_"
  re="\\\$\\{(${keys}):-[^}\$][^}]*\\}"
  grep -rnoE "${re}" "${tree}/orchestrators/compose/base/" "${tree}/orchestrators/compose/" 2>/dev/null |
    grep -vE ':-[^}]*\$\{' |
    sed -E 's#^.*/([^/]+\.yml):([0-9]+):\$\{([A-Z_0-9]+):-.*#\1:\2 \3#' | sort -u
  # A nested default hides the same defect one level down: ${OUTER:-${SECRET:-hunter2}}
  # publishes hunter2 while the outer match above skips it (its default starts with $).
  # This form is already idiomatic in the tree, so it is the one a reader will copy.
  grep -rnoE "\\\$\\{[A-Z_0-9]+:-\\\$\\{(${keys}):-[^}\$][^}]*\\}" \
    "${tree}/orchestrators/compose/base/" "${tree}/orchestrators/compose/" 2>/dev/null |
    sed -E 's#^.*/([^/]+\.yml):([0-9]+):.*\$\{([A-Z_0-9]+):-\$\{([A-Z_0-9]+):-.*#\1:\2 \4(nested)#' | sort -u
}

compose_arm() {
  step "COMPOSE — no SECRET boots from a published default"
  local bad unknown
  bad="$(literal_defaults "${ROOT}")"
  # The preserved pre-split monolith and the carried-over monorepo overlay are not
  # built from (stale paths, skipped by the compose lint); they are reported, not fatal.
  local live stale
  live="$(grep -vE '^(docker-compose\.monolith|docker-compose\.track-binocle|docker-compose\.ci)\.yml' <<<"${bad}")"
  stale="$(grep -cE '^(docker-compose\.monolith|docker-compose\.track-binocle|docker-compose\.ci)\.yml' <<<"${bad}")"
  if [ -n "${live}" ]; then
    fail "SECRET with a literal compose default: $(tr '\n' ' ' <<<"${live}" | cut -c1-200)"
  else
    ok "no SECRET carries a literal default in any built plane or overlay (${stale} in preserved/CI files, not built)"
  fi
  # Every compose-required key must be a schema key, or the schema has drifted.
  unknown="$(required_env_keys "${ROOT}" | while IFS= read -r k; do
    jq -e --arg k "${k}" '.keys[$k]' "${SCHEMA}" >/dev/null 2>&1 || printf '%s ' "${k}"
  done)"
  # schema.compose_required is a CLAIM about the tree; verify it both ways or it rots
  # into decoration, which is what every unverified metadata field eventually does.
  local wrong req_now k claimed
  req_now="$(required_env_keys "${ROOT}")"
  wrong=""
  while IFS= read -r k; do
    [ -n "${k}" ] || continue
    claimed="$(jq -r --arg k "${k}" '.keys[$k].compose_required // false' "${SCHEMA}")"
    if grep -qx "${k}" <<<"${req_now}"; then
      [ "${claimed}" = true ] || wrong="${wrong}${k}(required,claims-false) "
    else
      [ "${claimed}" = false ] || wrong="${wrong}${k}(not-required,claims-true) "
    fi
  done < <(jq -r '.keys | keys[]' "${SCHEMA}")
  [ -z "${wrong}" ] && ok "schema compose_required matches the tree for every key" ||
    fail "schema compose_required disagrees with compose: ${wrong}"
  [ -z "${unknown}" ] && ok "every compose-required key is classified ($(required_env_keys "${ROOT}" | wc -l | tr -d ' ') required)" ||
    fail "compose requires an unclassified key: ${unknown}"
}

# ── SOURCEABLE ───────────────────────────────────────────────────────────────
# Every key the compose tree REQUIRES must have somewhere to come from: either
# generate-env.sh mints it into .env.secrets, or config.env ships it. A required key
# with neither is unrenderable the moment someone regenerates their env — which is
# exactly what shipping ${MYSQL_ROOT_PASSWORD:?} without teaching generate-env.sh to
# mint it did: `make up` failed, and the error told the reader to run `make env`,
# which re-read the same stale file and changed nothing.
sourceable_arm() {
  step "SOURCEABLE — every required key can be produced"
  local k orphan minted
  minted="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${ROOT}/scripts/env/generate-env.sh" |
    tr -d '=' | sort -u)"
  orphan=""
  while IFS= read -r k; do
    [ -n "${k}" ] || continue
    grep -qx "${k}" <<<"${minted}" && continue
    grep -qE "^[[:space:]]*(export[[:space:]]+)?${k}=" "${ROOT}/config.env" && continue
    orphan="${orphan}${k} "
  done < <(required_env_keys "${ROOT}")
  [ -z "${orphan}" ] &&
    ok "all $(required_env_keys "${ROOT}" | wc -l | tr -d ' ') required keys are minted by generate-env.sh or shipped in config.env" ||
    fail "required but nothing produces it (a fresh env cannot render): ${orphan}"
}

# ── COMMITTED ────────────────────────────────────────────────────────────────
committed_arm() {
  local root="${1:-${ROOT}}"
  step "COMMITTED — no SECRET value in a tracked file"
  local leaked k v
  leaked=""
  while IFS= read -r k; do
    v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${k}=//p" "${root}/config.env" 2>/dev/null | head -1)"
    [ -n "${v}" ] || continue
    # Interpolations carry no value, so strip them before judging.
    local bare="${v//\$\{*\}/}"
    if [ -n "$(jq -r --arg k "${k}" '.keys[$k].derived_from // ""' "${SCHEMA}")" ]; then
      # A derived key is a URI: only an embedded LITERAL password is a leak.
      # `mongodb://mongo:27017` is a host:port, not a credential.
      grep -qE '://[^/:@[:space:]]+:[^@/[:space:]]+@' <<<"${bare}" &&
        leaked="${leaked}config.env:${k}(credentialed-dsn) "
    else
      # A stored secret has no business carrying any value in the committed layer.
      leaked="${leaked}config.env:${k} "
    fi
  done < <(jq -r '.keys | to_entries[] | select(.value.category=="SECRET") | .key' "${SCHEMA}")
  [ -z "${leaked}" ] && ok "config.env assigns no schema SECRET a value" ||
    fail "SECRET assigned in a committed file: ${leaked}"

  local f bad
  for f in .env.example .env.local.example; do
    [ -f "${root}/${f}" ] || continue
    bad="$(grep -E '^[A-Z_][A-Z0-9_]*=.+' "${root}/${f}" |
      grep -vEi '=(CHANGE_ME|example|your-|<|\$\{|placeholder|local|localhost|3000|development)' | head -3)"
    [ -z "${bad}" ] && ok "${f}: values are empty or placeholders" ||
      fail "${f} carries a real-looking value: $(cut -d= -f1 <<<"${bad}" | tr '\n' ' ')"
  done
}

# ── PUBLIC ───────────────────────────────────────────────────────────────────
public_arm() {
  local schema="${1:-${SCHEMA}}"
  step "PUBLIC — no SECRET under a browser-facing name"
  local bad
  bad="$(jq -r '.keys | to_entries[] | select(.value.category=="SECRET")
    | select(.key | test("^(PUBLIC_|VITE_|NEXT_PUBLIC_)")) | .key' "${schema}")"
  [ -z "${bad}" ] && ok "no schema SECRET is named PUBLIC_*/VITE_*/NEXT_PUBLIC_*" ||
    fail "SECRET exposed under a public name: $(tr '\n' ' ' <<<"${bad}")"
  # A contract emits the frontend's config: it may reference only PUBLIC material.
  local c secretkeys hit
  secretkeys="$(jq -r '.keys | to_entries[] | select(.value.category=="SECRET") | .key' "${SCHEMA}" | paste -sd '|' -)"
  hit=""
  for c in "${ROOT}"/infra/config/contracts/*.json; do
    [ -f "${c}" ] || continue
    jq -e '.frontend_config' "${c}" >/dev/null 2>&1 || continue
    # SERVICE_ROLE_KEY et al must never appear in what a browser receives.
    jq -r '.frontend_config.vars // {} | to_entries[] | "\(.key)=\(.value)"' "${c}" |
      grep -qE "\\\$\\{(${secretkeys})\\}" && hit="${hit}${c##*/} "
  done
  [ -z "${hit}" ] && ok "no contract's frontend_config references a schema SECRET" ||
    fail "contract leaks a SECRET to the browser: ${hit}"
}

# ── ENVIRON ──────────────────────────────────────────────────────────────────
environ_arm() {
  step "ENVIRON — GROBASE_ENV is declared and defaulted"
  jq -e '.keys.GROBASE_ENV.category == "ENVIRONMENT"' "${SCHEMA}" >/dev/null ||
    fail "GROBASE_ENV is not classified ENVIRONMENT"
  local dflt allowed envs
  dflt="$(sed -n 's/^[[:space:]]*GROBASE_ENV=//p' "${ROOT}/config.env" | head -1)"
  [ -n "${dflt}" ] || fail "config.env does not default GROBASE_ENV"
  allowed="$(jq -r '.keys.GROBASE_ENV.allowed | sort | join(",")' "${SCHEMA}")"
  envs="$(jq -r '.environments | sort | join(",")' "${SCHEMA}")"
  [ "${allowed}" = "${envs}" ] || fail "GROBASE_ENV.allowed (${allowed}) != environments (${envs})"
  jq -e --arg d "${dflt}" '.keys.GROBASE_ENV.allowed | index($d) != null' "${SCHEMA}" >/dev/null ||
    fail "config.env's GROBASE_ENV=${dflt} is not an allowed value"
  grep -q 'GROBASE_ENV' "${ROOT}/scripts/ops/preflight-production.sh" ||
    fail "preflight-production.sh does not check GROBASE_ENV"
  [ "${rc}" -eq 0 ] && ok "GROBASE_ENV=${dflt} by default, allowed ${allowed}, enforced by preflight"
}

# ── MUTANTS ──────────────────────────────────────────────────────────────────
# Each mutant is applied to a COPY of the tree; a check that does not go red is
# a check that is not doing anything.

# arm_fails is TRUE when the named arm reports a defect against a mutated input. It
# matches the arm's own FAIL line rather than its exit status, because the arms report
# through the shared rc: running one in a command substitution keeps that write inside
# the subshell, so a mutant cannot redden the real verdict.
#
# The output is captured before matching, NOT piped into `grep -q`: under `pipefail`
# grep exits at the first match, the arm dies of SIGPIPE mid-write, and the pipeline
# returns 141 — so every mutant silently read as "survived".
#
# The ARM is invoked, never a re-implementation of its check — a mutant that re-greps
# for the same thing stays green with the arm deleted, which is how the `export KEY=`
# blind spot survived review.
arm_fails() {
  local out
  out="$("$@" 2>&1)"
  case "${out}" in *FAIL*) return 0 ;; *) return 1 ;; esac
}

mutants_arm() {
  step "MUTANTS — each check refuses the way back in"
  local work tree
  work="$(mktemp -d)" || return
  trap 'rm -rf "${work}"' RETURN
  tree="${work}/tree"
  mkdir -p "${tree}/orchestrators" "${tree}/infra/config"
  cp -r "${ROOT}/orchestrators/compose" "${tree}/orchestrators/"
  cp -r "${ROOT}/infra/config/env" "${tree}/infra/config/"

  # 1. a SECRET regains a literal compose default
  sed -i 's#\${POSTGRES_PASSWORD:?[^}]*}#${POSTGRES_PASSWORD:-postgres}#' \
    "${tree}/orchestrators/compose/base/data-engines.yml"
  [ -n "$(literal_defaults "${tree}")" ] &&
    ok "refused: POSTGRES_PASSWORD given a literal default again" ||
    fail "mutant survived: a literal SECRET default is not caught"

  # 2. a SECRET assigned in the committed CONFIG layer — and as `export KEY=`, the
  #    form compose honours, preflight strips, and this arm used to miss. The mutant
  #    calls the REAL committed_arm against the copy: a self-test that re-implements
  #    the check would stay green with the arm deleted, which is how the export blind
  #    spot survived in the first place.
  cp "${ROOT}/config.env" "${tree}/config.env"
  cp "${ROOT}/.env.example" "${tree}/.env.example" 2>/dev/null || true
  cp "${ROOT}/.env.local.example" "${tree}/.env.local.example" 2>/dev/null || true
  printf 'export JWT_SECRET=aaaabbbbccccddddeeeeffff00001111\n' >>"${tree}/config.env"
  if arm_fails committed_arm "${tree}"; then
    ok "refused: a SECRET assigned in config.env as 'export KEY=' (the real arm)"
  else
    fail "mutant survived: committed_arm misses export KEY="
  fi

  # 3. a SECRET renamed into the browser namespace — again through the real arm.
  jq '.keys["VITE_JWT_SECRET"] = {"category":"SECRET","format":"hex64","required_in":[],"vault42_path":"core/x","consumers":[]}' \
    "${SCHEMA}" >"${tree}/schema.json"
  if arm_fails public_arm "${tree}/schema.json"; then
    ok "refused: a SECRET named VITE_* (the real arm)"
  else
    fail "mutant survived: public_arm misses a browser-named SECRET"
  fi
}

schema_arm
compose_arm
sourceable_arm
committed_arm
public_arm
environ_arm
mutants_arm

if [ "${rc}" -eq 0 ]; then
  printf '%s[M214] PASS — configuration, secrets and environments stay separated%s\n' "${_G}" "${_0}"
else
  printf '%s[M214] FAIL%s\n' "${_R}" "${_0}"
fi
exit "${rc}"
