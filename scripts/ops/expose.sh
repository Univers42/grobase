#!/usr/bin/env bash
# expose.sh — one command: grobase answers over trusted HTTPS at every address it
# is reached at (LAN, VM bridge, Tailscale, a router name you --add), and the
# frontend is told where it lives.
#   expose.sh [up] [--add HOST]... [--replace] [--no-detect] [--no-trust]
#             [--no-restart] [--dry-run]
#       addresses (detected + --add + the kept current list) → .env.local → .env →
#       cert SANs → trust the CA (system via sudo, Chrome/Firefox NSS) → recreate
#       kong/gotrue/waf if running → refresh emitted frontend configs → probe.
#   expose.sh detect | status | untrust | trust [CA]  (trust runs alone on a client)
# Exit: 0 done · 1 a step failed · 2 usage.  Make: make expose ARGS="…"
# Ponytail: detection reads interfaces (docker/br-/veth/cni excluded, VM bridges
# kept), `tailscale status`, <hostname>.local; a router's public IP/DNS needs --add.
# A name is probed resolved to 127.0.0.1 (cert + CORS, not the remote DNS route).
set -euo pipefail
ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CA="${ROOT}/certs/track-binocle-local-ca.pem"
NICK="Grobase Local Development CA"
SYS_NAME="grobase-local-ca.crt"
DRY=0

# say prints a step line; warn and die print to stderr (die exits 1).
say() { printf '\033[0;36m[expose]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[expose] %s\033[0m\n' "$*" >&2; }
die() { warn "$*" && exit 1; }

# run executes "$@", or only prints it under --dry-run.
run() {
  if [ "${DRY}" = 1 ]; then printf '  (dry-run) %s\n' "$*"; else "$@"; fi
}

# detect_addresses prints one address per line: global IPv4 on real and VM
# interfaces, the Tailscale name and IPv4, and <hostname>.local if it resolves.
detect_addresses() {
  ip -4 -o addr show scope global 2>/dev/null |
    awk '$2 !~ /^(docker|br-|veth|cni|flannel|kube|lo)/ { split($4, a, "/"); print a[1] }'
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null |
      jq -r '.Self | (.DNSName // "" | sub("\\.$"; "")), (.TailscaleIPs[]? | select(test("^[0-9.]+$")))' |
      grep . || true
  fi
  getent hosts "$(hostname -s).local" >/dev/null 2>&1 && printf '%s.local\n' "$(hostname -s)"
  return 0
}

# env_value prints KEY's last value in file $2 (empty if absent).
env_value() {
  [ -f "$2" ] || return 0
  sed -n "s/^$1=//p" "$2" | tail -n 1
}

# set_env_line sets KEY=VALUE in file $3 in place (inode and mode kept).
set_env_line() {
  local tmp
  tmp="$(mktemp)"
  touch "$3"
  awk -v k="$1" -v v="$2" 'BEGIN { done = 0 }
    $0 ~ "^" k "=" { if (!done) print k "=" v; done = 1; next } { print }
    END { if (!done) print k "=" v }' "$3" >"${tmp}"
  run sh -c 'cat "$1" >"$2"' _ "${tmp}" "$3"
  rm -f "${tmp}"
}

# join_unique prints its stdin lines, deduplicated in order, joined by commas.
join_unique() {
  awk 'NF && !seen[$0]++' | paste -sd, -
}

# waf_port prints the WAF's published HTTPS port.
waf_port() {
  local p
  p="$(docker port mini-baas-waf 443/tcp 2>/dev/null | head -n 1 | sed 's/.*://')"
  printf '%s\n' "${p:-$(env_value WAF_HTTPS_PORT "${ROOT}/.env" | grep . || echo 8443)}"
}

# nss_dirs prints every NSS certificate database of this user (Chrome, Firefox).
nss_dirs() {
  [ -d "${HOME}/.pki/nssdb" ] && printf '%s\n' "${HOME}/.pki/nssdb"
  find "${HOME}/.mozilla/firefox" "${HOME}/snap/firefox/common/.mozilla/firefox" \
    -maxdepth 2 -name cert9.db -printf '%h\n' 2>/dev/null || true
}

# sudo_ok succeeds when sudo can run: cached credentials, or a terminal to ask on.
sudo_ok() {
  [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null || [ -t 0 ]
}

# trust_system adds CA $1 to the OS store (Debian/Fedora/Arch/macOS).
trust_system() {
  local s=""
  [ "$(id -u)" = 0 ] || s=sudo
  if [ "$(uname)" = Darwin ]; then
    run ${s} security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$1"
  elif command -v update-ca-certificates >/dev/null 2>&1; then
    run ${s} install -m 644 "$1" "/usr/local/share/ca-certificates/${SYS_NAME}"
    run ${s} update-ca-certificates
  elif command -v update-ca-trust >/dev/null 2>&1; then
    run ${s} install -m 644 "$1" "/etc/pki/ca-trust/source/anchors/${SYS_NAME}"
    run ${s} update-ca-trust
  elif command -v trust >/dev/null 2>&1; then
    run ${s} trust anchor --store "$1"
  else
    warn "no known system trust tool; trust $1 by hand"
  fi
}

# trust_nss replaces CA $1 under NICK in every NSS database (no sudo).
trust_nss() {
  local d
  command -v certutil >/dev/null 2>&1 || warn "certutil missing (apt install libnss3-tools): browsers not updated"
  command -v certutil >/dev/null 2>&1 || return 0
  while IFS= read -r d; do
    certutil -d "sql:${d}" -D -n "${NICK}" >/dev/null 2>&1 || true
    run certutil -d "sql:${d}" -A -t "C,," -n "${NICK}" -i "$1"
    say "trusted in NSS store ${d/#${HOME}/\~}"
  done < <(nss_dirs)
}

# cmd_trust trusts CA $1 (default the repo's local CA) everywhere it can.
cmd_trust() {
  local ca="${1:-${CA}}"
  [ -s "${ca}" ] || die "no CA at ${ca} (run: make certs)"
  ca="$(cd "$(dirname -- "${ca}")" && pwd)/$(basename -- "${ca}")"
  openssl x509 -in "${ca}" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' ||
    die "${ca} is not a CA certificate"
  if sudo_ok; then trust_system "${ca}"; else
    warn "system store skipped (sudo needs a terminal); run: $0 trust ${ca}"
  fi
  trust_nss "${ca}"
  say "Node (frontend dev servers/SSR) ignores the OS store: export NODE_EXTRA_CA_CERTS=${ca}"
}

# cmd_untrust removes the CA from every store cmd_trust writes.
cmd_untrust() {
  local d s=""
  [ "$(id -u)" = 0 ] || s=sudo
  if [ -f "/usr/local/share/ca-certificates/${SYS_NAME}" ]; then
    run ${s} rm -f "/usr/local/share/ca-certificates/${SYS_NAME}"
    run ${s} update-ca-certificates --fresh
  fi
  if [ -f "/etc/pki/ca-trust/source/anchors/${SYS_NAME}" ]; then
    run ${s} rm -f "/etc/pki/ca-trust/source/anchors/${SYS_NAME}"
    run ${s} update-ca-trust
  fi
  command -v certutil >/dev/null 2>&1 || return 0
  while IFS= read -r d; do
    run certutil -d "sql:${d}" -D -n "${NICK}" 2>/dev/null || true
  done < <(nss_dirs)
  say "CA removed from the system and NSS stores"
}

# probe_one checks TLS (against CA $3) and CORS for address $1 on port $2;
# prints one status line, returns 1 on a failed TLS verification.
probe_one() {
  local url host="$1" r=() code acao
  case "${host}" in *:*) url="https://[${host}]:$2" ;; *) url="https://${host}:$2" ;; esac
  case "${host}" in *:*) ;; *[!0-9.]*) r=(--resolve "${host}:$2:127.0.0.1") ;; esac
  code="$(curl -sS -m 5 "${r[@]}" --cacert "$3" -o /dev/null -w '%{http_code}' "${url}/auth/v1/health" 2>/dev/null || true)"
  acao="$(curl -sS -m 5 "${r[@]}" --cacert "$3" -o /dev/null -D - -X OPTIONS -H "Origin: https://${host}" \
    -H 'Access-Control-Request-Method: GET' "${url}/rest/v1/" 2>/dev/null | tr -d '\r' |
    sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p')"
  if [ -z "${code}" ] || [ "${code}" = 000 ]; then
    printf '  ✗ %-36s TLS failed (untrusted cert, wrong SAN, or WAF down)\n' "${url}"
    return 1
  fi
  printf '  ✓ %-36s TLS ok (HTTP %s) · CORS %s\n' "${url}" "${code}" "${acao:-refused}"
}

# cmd_status prints the list, the cert SANs and a probe of localhost + each address.
cmd_status() {
  local list port a rc=0
  list="$(env_value GROBASE_PUBLIC_ADDRESSES "${ROOT}/.env")"
  port="$(waf_port)"
  say "GROBASE_PUBLIC_ADDRESSES=${list:-<empty: localhost only>}"
  [ -s "${ROOT}/certs/localhost.pem" ] &&
    say "cert SANs: $(openssl x509 -in "${ROOT}/certs/localhost.pem" -noout -ext subjectAltName | tail -n 1 | sed 's/^ *//')"
  [ -s "${CA}" ] || die "no CA (run: make certs)"
  for a in localhost $(printf '%s' "${list}" | tr ',' ' '); do
    probe_one "${a}" "${port}" "${CA}" || rc=1
  done
  return "${rc}"
}

# running_services prints which of kong gotrue waf are running now.
running_services() {
  local s
  for s in kong gotrue waf; do
    [ "$(docker inspect -f '{{.State.Running}}' "mini-baas-${s}" 2>/dev/null)" = true ] && printf '%s\n' "${s}"
  done
  return 0
}

# recreate force-recreates the running kong/gotrue/waf with the compose files and
# project the stack was started with, so overlays (prod, netseg, …) are kept.
recreate() {
  local svcs files args=() f fl
  mapfile -t svcs < <(running_services)
  [ "${#svcs[@]}" -gt 0 ] || say "stack not running: nothing to recreate (make up applies it)"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  files="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "mini-baas-${svcs[0]}")"
  IFS=, read -r -a fl <<<"${files}"
  for f in "${fl[@]}"; do args+=(-f "${f}"); done
  args+=(-p "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "mini-baas-${svcs[0]}")")
  say "recreating ${svcs[*]} (they read the new list and cert at start)"
  run docker compose --project-directory "${ROOT}" "${args[@]}" up -d --no-deps --force-recreate --wait "${svcs[@]}"
}

# refresh_frontends points PUBLIC_GROBASE_URL of every frontend config a contract
# already emitted at URL $1 (re-provisioning does the same via GROBASE_FRONTEND_URL).
refresh_frontends() {
  local c path out
  for c in "${ROOT}"/infra/config/contracts/*.json; do
    path="$(jq -r '.frontend_config.path // empty' "${c}")"
    [ -n "${path}" ] || continue
    case "${path}" in /*) out="${path}" ;; *) out="${ROOT}/${path}" ;; esac
    grep -q '^PUBLIC_GROBASE_URL=' "${out}" 2>/dev/null || continue
    set_env_line PUBLIC_GROBASE_URL "$1" "${out}"
    say "frontend config ${path}: PUBLIC_GROBASE_URL=$1"
  done
}

# print_clients tells the frontend and other machines how to use the result.
print_clients() {
  local port="$1" first="$2" a
  say "frontend: PUBLIC_GROBASE_URL / realtime per address"
  for a in $(printf '%s' "$3" | tr ',' ' '); do
    printf '    https://%s:%s   wss://%s:%s/realtime/v1/ws\n' "${a}" "${port}" "${a}" "${port}"
  done
  say "provision a contract for it: GROBASE_FRONTEND_URL=https://${first}:${port} scripts/provision-contract.sh <app>"
  say "another machine (VM, laptop on the LAN): copy the CA and this script, then trust it:"
  printf '    scp %s@%s:%s %s@%s:%s/scripts/ops/expose.sh . && bash expose.sh trust %s\n' \
    "${USER}" "${first}" "${CA}" "${USER}" "${first}" "${ROOT}" "${CA##*/}"
}

# keep_previous filters the stored list on stdin: names and public IPs stay; a
# private IP (RFC 1918, CGNAT, link-local) no longer on any interface is a stale
# lease or a network left behind, and is dropped with a note.
keep_previous() {
  local here a
  here=" $(ip -o addr show 2>/dev/null | awk '{ split($4, a, "/"); printf "%s ", a[1] }')"
  while IFS= read -r a; do
    case "${a}" in
    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].* | 169.254.* | f[cd]*:* | fe80:*)
      case "${here}" in *" ${a} "*) printf '%s\n' "${a}" ;; *) warn "dropped ${a}: no longer on this machine" ;; esac
      ;;
    *) printf '%s\n' "${a}" ;;
    esac
  done
}

# build_list prints the merged list, --add first, then detected, then kept ones:
# the first address is the one the frontend config and client hints use.
build_list() {
  {
    printf '%s\n' "${ADD[@]+"${ADD[@]}"}"
    [ "${DETECT}" = 0 ] || detect_addresses
    [ "${REPLACE}" = 1 ] || env_value GROBASE_PUBLIC_ADDRESSES "${ROOT}/.env.local" | tr ',' '\n' | keep_previous
  } | tr -d ' ' | join_unique
}

# cmd_up runs the whole flow described in the header.
cmd_up() {
  local list port
  list="$(build_list)"
  sh "${ROOT}/scripts/ops/public-origins.sh" "${list}" >/dev/null || die "invalid address in: ${list}"
  say "GROBASE_PUBLIC_ADDRESSES=${list:-<empty: localhost only>}"
  set_env_line GROBASE_PUBLIC_ADDRESSES "${list}" "${ROOT}/.env.local"
  run bash "${ROOT}/scripts/env/assemble-env.sh" >/dev/null
  run bash "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
  [ "${TRUST}" = 0 ] || cmd_trust "${CA}"
  [ "${RESTART}" = 0 ] || recreate
  port="$(waf_port)"
  [ -z "${list}" ] || refresh_frontends "https://${list%%,*}:${port}"
  [ "${DRY}" = 1 ] || cmd_status || die "a probe failed — see above"
  [ -z "${list}" ] || print_clients "${port}" "${list%%,*}" "${list}"
}

# main parses the subcommand and options.
main() {
  local cmd=up
  ADD=() REPLACE=0 DETECT=1 TRUST=1 RESTART=1
  case "${1:-}" in up | detect | status | trust | untrust) cmd="$1" && shift ;; esac
  [ "${cmd}" != trust ] || cmd_trust "${1:-}"
  [ "${cmd}" != trust ] || return 0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --add) ADD+=("${2:?--add needs a host}") && shift ;;
    --replace) REPLACE=1 ;; --no-detect) DETECT=0 ;; --no-trust) TRUST=0 ;;
    --no-restart) RESTART=0 ;; --dry-run) DRY=1 ;;
    -h | --help) sed -n '2,11p' "$0" && exit 0 ;;
    *) sed -n '2,11p' "$0" >&2 && exit 2 ;;
    esac
    shift
  done
  case "${cmd}" in
  detect) detect_addresses | join_unique ;; status) cmd_status ;; untrust) cmd_untrust ;; up) cmd_up ;;
  esac
}

main "$@"
