#!/bin/sh
# lib-required-env.sh — the floor of env keys a compose render REQUIRES.
#
# Sourced, never executed. Secret-bearing compose entries are written
# `${KEY:?unset - run make env}` so a stack can never boot on a published default
# (the 45 literal fallbacks that used to do exactly that). A gate that renders the
# tree with its own synthetic .env must therefore supply every required key, or the
# render fails for a reason that has nothing to do with what the gate tests.
#
# The floor is DERIVED from the compose sources, so a newly-required key is picked
# up with no gate edit. The filler value is deliberately caller-chosen: a gate that
# detects leakage by matching its sentinel string must not have the floor share it,
# or every legitimate consumer looks like a leak.
#
# Ponytail: the key list comes from a regex over the compose YAML, not a parse.
# `${KEY:?...}` and `${KEY?...}` are both found; a key made required only inside an
# `extends:` chain in a file outside the two globs below is not. Direction of failure is safe: a missed
# key means a gate render fails loudly with that key's name, never a silent pass.

# required_env_keys prints every env key a compose render requires, one per line,
# sorted and unique.
#   $1  repo root to scan (default: the current directory)
required_env_keys() {
  _ren_root="${1:-.}"
  grep -rhoE '\$\{[A-Z_][A-Z0-9_]*:?\?' \
    "${_ren_root}/orchestrators/compose/base/" \
    "${_ren_root}/orchestrators/compose/" 2>/dev/null |
    sed -E 's/^\$\{([A-Z_0-9]+):?\?$/\1/' |
    sort -u
}

# required_env_floor prints `KEY=<filler>` for every required key, so a synthetic
# .env can satisfy the render.
#
# $3 is the point of the whole helper: a caller appending the floor to an env file
# that already sets one of these keys would have its OWN value overridden, because
# the last assignment in an env file wins. That failure is silent and it makes the
# caller's assertions vacuous — it passed m210's compose arm while its JWT_SECRET
# sentinel had been replaced by the filler. Keys already present are skipped.
#   $1  filler value — MUST differ from any sentinel the caller greps for
#   $2  repo root to scan (default: the current directory)
#   $3  env file whose already-set keys to skip (optional)
# A key the env schema declares `format: ipv4` (WAF_BIND_ADDR, a port bind) gets the RFC 5737
# documentation address instead: compose rejects any other word there, so the filler alone
# fails the render. Without jq or the schema the filler stands, and that render fails naming it.
required_env_floor() {
  _ref_filler="${1:?required_env_floor: filler value required}"
  _ref_root="${2:-.}"
  _ref_skip="${3:-}"
  _ref_ipv4=" $(jq -r '.keys | to_entries[] | select(.value.format == "ipv4") | .key' \
    "${_ref_root}/infra/config/env/schema.json" 2>/dev/null | tr '\n' ' ') "
  required_env_keys "${_ref_root}" | while IFS= read -r _ref_k; do
    if [ -n "${_ref_skip}" ] && [ -f "${_ref_skip}" ] &&
      grep -qE "^[[:space:]]*(export[[:space:]]+)?${_ref_k}=" "${_ref_skip}"; then
      continue
    fi
    case "${_ref_ipv4}" in
    *" ${_ref_k} "*) printf '%s=192.0.2.1\n' "${_ref_k}" ;;
    *) printf '%s=%s\n' "${_ref_k}" "${_ref_filler}" ;;
    esac
  done
}
