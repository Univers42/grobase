#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m217-public-addresses.sh — one setting, GROBASE_PUBLIC_ADDRESSES, makes the #
#  stack answer at every address it is reached at (LAN IP, VM bridge, router,  #
#  ts.net name, …): cert SANs, Kong CORS origins and GoTrue redirect entries   #
#  all follow it; unset/empty changes nothing.                                 #
#                                                                              #
#  HELPER   scripts/ops/public-origins.sh: exact output for hosts, IPv6, the   #
#           dev list re-hosted (deduplicated) and a suffix; empty → nothing;   #
#           `*`, a path, a scheme, an empty field → exit 2, nothing printed.   #
#  KONG     render-kong-config.sh: unset and empty render byte-identical with  #
#           no public origin; set → https://<host> + the dev list re-hosted;   #
#           prod (empty dev list) → https://<host> only; a bad one fails it.   #
#  COMPOSE  base and base+prod pass the key to kong and gotrue, "" when unset, #
#           and mount the helper into both.                                    #
#  GOTRUE   gotrue's rendered command, run under busybox with `auth` stubbed,  #
#           appends the derived entries; empty leaves the allow list as is.   #
#  CERT     generate-localhost-cert.sh adds one IP/DNS SAN per address, keeps #
#           the default set when empty, refuses a bad one and keeps the cert. #
#  MUTANT   a helper without its address check lets `*` through; caught.      #
#  Needs docker (compose + busybox, M217_BUSYBOX_IMAGE overrides). No stack.  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/lib-required-env.sh
. "${SCRIPT_DIR}/../lib/lib-required-env.sh"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M217] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M217] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HELPER="${ROOT}/scripts/ops/public-origins.sh"
TREE="${WORK}/tree"
BUSYBOX="${M217_BUSYBOX_IMAGE:-mirror.gcr.io/library/busybox:1.37}"
KONG_DIR="${ROOT}/infra/docker/services/kong"
DEV='http://127.0.0.1:5180,http://localhost:5180, http://localhost:3001,https://app.example.com'
NL=$'\n'

# expect_eq fails with label $1 unless $2 (got) equals $3 (want).
expect_eq() {
  [ "$2" = "$3" ] && return 0
  printf '    want:\n%s\n    got:\n%s\n' "$3" "$2" >&2
  fail "$1"
}

# refuses succeeds when helper $1 exits 2 and prints nothing for every bad address.
refuses() {
  local bad out
  for bad in '*' 'evil.com/x' 'http://x' 'a b;c' 'x,,y'; do
    out="$(sh "$1" "${bad}" 2>/dev/null)"
    [ "$?" -eq 2 ] && [ -z "${out}" ] || return 1
  done
}

# helper_arm checks the helper's exact output and its refusals.
helper_arm() {
  step "HELPER — exact origins, dedup, IPv6, suffix, refusals"
  expect_eq "hosts + dev list" "$(sh "${HELPER}" '192.168.1.20, box.ts.net' "${DEV}")" \
    "https://192.168.1.20${NL}http://192.168.1.20:5180${NL}http://192.168.1.20:3001${NL}https://box.ts.net${NL}http://box.ts.net:5180${NL}http://box.ts.net:3001"
  ok "hosts: https base + localhost dev origins re-hosted once each, foreign origins untouched"
  expect_eq "ipv6 + suffix" "$(sh "${HELPER}" 'fd7a::1' 'http://localhost:5173/**' '/**')" \
    "https://[fd7a::1]/**${NL}http://[fd7a::1]:5173/**"
  ok "IPv6 bracketed, suffix on the base origin, path kept on re-hosted entries"
  expect_eq "empty" "$(sh "${HELPER}" '' "${DEV}")" ""
  ok "empty addresses print nothing"
  refuses "${HELPER}" || fail "a bad address was accepted or printed output"
  ok "'*', a path, a scheme, a space/semicolon and an empty field exit 2 with no output"
}

# render_kong renders kong.yml to $1 with GROBASE_PUBLIC_ADDRESSES=$2 (the literal
# word UNSET leaves it unset) and dev list $3; returns the render status.
render_kong() {
  local set_arg=()
  [ "$2" = UNSET ] || set_arg=(GROBASE_PUBLIC_ADDRESSES="$2")
  cp "${KONG_DIR}/render-kong-config.sh" "${HELPER}" "${WORK}/"
  env -u GROBASE_PUBLIC_ADDRESSES "${set_arg[@]}" KONG_CORS_ORIGIN_DEV_LIST="$3" \
    sh "${WORK}/render-kong-config.sh" "${KONG_DIR}/conf/kong.yml" "$1" 2>/dev/null
}

# cors_origins prints the CORS origin lines of rendered config $1.
cors_origins() {
  sed -n '/name: cors/,/methods:/p' "$1" | sed -n 's/^        - //p'
}

# kong_arm checks parity, the derived origins, the prod shape and the refusal.
kong_arm() {
  step "KONG — render-kong-config.sh"
  render_kong "${WORK}/unset.yml" UNSET "${DEV}" || fail "render with the key unset failed"
  render_kong "${WORK}/empty.yml" '' "${DEV}" || fail "render with the key empty failed"
  cmp -s "${WORK}/unset.yml" "${WORK}/empty.yml" || fail "unset and empty render differently"
  grep -q 'box.ts.net' "${WORK}/unset.yml" && fail "a public origin appeared with the key unset"
  ok "unset and empty render byte-identical, no public origin (parity)"
  render_kong "${WORK}/set.yml" 'box.ts.net' "${DEV}" || fail "render with an address failed"
  expect_eq "set: added origins" "$(diff <(cors_origins "${WORK}/unset.yml") <(cors_origins "${WORK}/set.yml") | sed -n 's/^> //p')" \
    "https://box.ts.net${NL}http://box.ts.net:5180${NL}http://box.ts.net:3001"
  ok "set: exactly https://box.ts.net + the dev list re-hosted are added"
  render_kong "${WORK}/prod.yml" 'api.example.com' '' || fail "prod-shaped render failed"
  expect_eq "prod: origins" "$(cors_origins "${WORK}/prod.yml" | grep example.com)" "https://api.example.com"
  ok "prod (empty dev list): only https://api.example.com is added"
  render_kong "${WORK}/bad.yml" '*' "${DEV}" && fail "a '*' address rendered — Kong would start with it"
  ok "a '*' address fails the render, so Kong refuses to start"
}

# render_compose writes compose config JSON to $1 from env file $2 plus overlays,
# from a copy of the compose tree: `include:` would also read the repo's own .env.
render_compose() {
  local out="$1" envf="$2" args=(-f "${TREE}/docker-compose.yml") f
  shift 2
  for f in "$@"; do args+=(-f "${f}"); done
  env -u GROBASE_PUBLIC_ADDRESSES docker compose --project-directory "${TREE}" --env-file "${envf}" \
    "${args[@]}" --profile '*' config --format json >"${out}" 2>"${WORK}/render.err" && return
  tail -n 3 "${WORK}/render.err" | sed 's/^/    /' >&2
  return 1
}

# wiring prints `svc value mounted` for kong and gotrue in config $1.
wiring() {
  jq -r '.services | to_entries[] | select(.key == "kong" or .key == "gotrue")
    | "\(.key) [\(.value.environment.GROBASE_PUBLIC_ADDRESSES)] \([.value.volumes[]?.target]
    | any(. == "/etc/kong/public-origins.sh" or . == "/etc/gotrue/public-origins.sh"))"' "$1" | sort
}

# compose_arm checks both services get the key (and "" when unset) and the helper.
compose_arm() {
  local floor want_set="gotrue [m217.example] true${NL}kong [m217.example] true"
  step "COMPOSE — kong and gotrue get the key and the helper"
  mkdir -p "${TREE}/orchestrators"
  cp "${ROOT}/docker-compose.yml" "${TREE}/"
  cp -r "${ROOT}/orchestrators/compose" "${TREE}/orchestrators/"
  floor="$(required_env_floor m217-floor "${TREE}" /dev/null)"
  printf '%s\nGROBASE_PUBLIC_ADDRESSES=m217.example\n' "${floor}" >"${WORK}/set.env"
  printf '%s\n' "${floor}" >"${WORK}/unset.env"
  render_compose "${WORK}/base.json" "${WORK}/set.env" || fail "base did not render"
  expect_eq "base wiring" "$(wiring "${WORK}/base.json")" "${want_set}"
  render_compose "${WORK}/prod.json" "${WORK}/set.env" "${TREE}/orchestrators/compose/docker-compose.prod.yml" ||
    fail "base+prod did not render"
  expect_eq "prod wiring" "$(wiring "${WORK}/prod.json")" "${want_set}"
  ok "base and base+prod: both services receive the key and mount the helper"
  render_compose "${WORK}/unset.json" "${WORK}/unset.env" || fail "base (unset) did not render"
  expect_eq "unset wiring" "$(wiring "${WORK}/unset.json")" "gotrue [] true${NL}kong [] true"
  ok "unset: both services receive \"\" (parity)"
}

# run_gotrue runs gotrue's rendered command under busybox with `auth` stubbed to
# print the allow list; $1 = GROBASE_PUBLIC_ADDRESSES, $2 = GOTRUE_URI_ALLOW_LIST.
# `config` output keeps compose's `$$` escapes; they are undone as compose does at run.
run_gotrue() {
  local cmd
  cmd="$(jq -r '.services.gotrue.command[2] | gsub("\\$\\$"; "$")' "${WORK}/base.json")"
  mkdir -p "${WORK}/stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$GOTRUE_URI_ALLOW_LIST"\n' >"${WORK}/stub/auth"
  chmod 755 "${WORK}/stub/auth"
  docker run --rm -e GROBASE_PUBLIC_ADDRESSES="$1" -e GOTRUE_URI_ALLOW_LIST="$2" -e M217_CMD="${cmd}" \
    -v "${HELPER}:/etc/gotrue/public-origins.sh:ro" -v "${WORK}/stub:/stub:ro" \
    "${BUSYBOX}" sh -c 'PATH=/stub:$PATH exec sh -ec "$M217_CMD"'
}

# gotrue_arm checks the real command extends the allow list, and only when set.
gotrue_arm() {
  local list='http://localhost:5173/**,http://localhost:3000'
  step "GOTRUE — the rendered command, run under busybox"
  expect_eq "gotrue set" "$(run_gotrue 'box.ts.net' "${list}")" \
    "${list},https://box.ts.net/**,http://box.ts.net:5173/**,http://box.ts.net:3000"
  ok "set: https://box.ts.net/** + the localhost entries re-hosted are appended"
  expect_eq "gotrue empty" "$(run_gotrue '' "${list}")" "${list}"
  ok "empty: the allow list reaches auth unchanged (parity)"
}

# gen_cert runs the cert script into $1 with GROBASE_PUBLIC_ADDRESSES=$2.
gen_cert() {
  TRACK_BINOCLE_CERT_DIR="$1" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES="$2" \
    bash "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null 2>&1
}

# sans prints the SAN extension of the cert in directory $1.
sans() {
  openssl x509 -in "$1/localhost.pem" -noout -ext subjectAltName | tail -n 1
}

# cert_arm checks SANs follow the addresses and a bad one changes nothing.
cert_arm() {
  local base before
  step "CERT — generate-localhost-cert.sh"
  gen_cert "${WORK}/c0" '' || fail "cert generation without addresses failed"
  base="$(sans "${WORK}/c0")"
  case "${base}" in *192.168*) fail "a public SAN appeared with no addresses" ;; esac
  gen_cert "${WORK}/c0" '192.168.1.20,box.ts.net,fd7a::1' || fail "cert generation with addresses failed"
  expect_eq "SANs" "$(sans "${WORK}/c0")" \
    "${base}, IP Address:192.168.1.20, DNS:box.ts.net, IP Address:FD7A:0:0:0:0:0:0:1"
  ok "each address becomes one IP or DNS SAN after the default set; changing the list re-issues"
  before="$(cat "${WORK}/c0/localhost.pem")"
  gen_cert "${WORK}/c0" '*.evil' && fail "a '*.evil' address was accepted"
  [ "$(cat "${WORK}/c0/localhost.pem")" = "${before}" ] || fail "a refused address changed the cert"
  ok "a bad address fails the script and leaves the cert as it was"
}

# mutant_arm proves the refusal check is not vacuous.
mutant_arm() {
  step "MUTANT — a helper without its address check"
  sed 's/^  for a in \$1; do check_address "\$a"; done$//' "${HELPER}" >"${WORK}/mutant.sh"
  cmp -s "${HELPER}" "${WORK}/mutant.sh" && fail "mutant: could not remove the address check"
  refuses "${WORK}/mutant.sh" && fail "mutant: the unchecked helper passed — the refusal check is vacuous"
  ok "mutant: an unchecked helper lets '*' through and is caught"
}

docker compose version >/dev/null 2>&1 || fail "docker compose is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required"
helper_arm
kong_arm
compose_arm
gotrue_arm
cert_arm
mutant_arm
cyan "[M217] PASS — GROBASE_PUBLIC_ADDRESSES drives cert SANs, Kong CORS and GoTrue redirects; unset changes nothing"
