#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    footprint.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Resource footprint of a service tier — answers "how much RAM / CPU / disk
# does THIS profile actually take?" (the measurement the lean-edition work is
# judged against). Resolves the service set for a set of compose profiles via
# the compose authority, then measures each container's LIVE memory (docker
# stats) + image size, sums per profile, and verdicts against an optional
# budget bar.
#
# Non-disruptive: it measures whatever is currently running; services in the
# resolved set that are NOT up are reported as "— (down)" with RAM 0 so the sum
# is a true floor. Use `make up PACKAGE=<x>` first for an exact-shape reading.
#
# Inputs (env):
#   PROFILES   space-separated compose profile names (empty = always-on core)
#   LABEL      output name (default: "core")
#   BAR_MB     optional RAM budget; non-zero exit if the running sum exceeds it
#   COMPOSE_FILE  default docker-compose.yml
#
# Writes artifacts/footprint-<LABEL>.json and prints a human table.

set -euo pipefail

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
PROFILES="${PROFILES:-}"
LABEL="${LABEL:-core}"
BAR_MB="${BAR_MB:-}"
PREFIX="mini-baas"

# One-shot init containers exit after bootstrapping — never counted as RAM.
INIT_SVCS=" db-bootstrap mongo-init mongo-keyfile minio-iceberg-init vault-init "

# Rough language bucket for the "where's the weight" story.
lang_of() {
  case "$1" in
    data-plane-router-rust|realtime) echo rust ;;
    adapter-registry-go|tenant-control|webhook-dispatcher|gotrue) echo go ;;
    query-router|permission-engine|outbox-relay|*-service|mongo-api|functions-runtime) echo node ;;
    postgres|mysql|mariadb|mongo|redis|cockroach|mssql) echo db ;;
    trino|debezium|iceberg-rest|minio*) echo jvm/store ;;
    kong|waf|postgrest) echo edge ;;
    *) echo other ;;
  esac
}

# MiB float from a docker-stats memory token (e.g. "151.1MiB", "1.02GiB", "512B").
to_mib() {
  awk -v v="$1" 'BEGIN{
    u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n)+0;
    n=n+0;
    if(u=="GiB"||u=="GB") printf "%.1f", n*1024;
    else if(u=="MiB"||u=="MB") printf "%.1f", n;
    else if(u=="KiB"||u=="kB"||u=="KB") printf "%.3f", n/1024;
    else if(u=="B") printf "%.4f", n/1024/1024;
    else printf "%.1f", n;
  }'
}

# ── resolve the service set for these profiles (compose is the authority) ──
flags=()
for p in ${PROFILES}; do flags+=(--profile "$p"); done
mapfile -t SERVICES < <(docker compose -f "${COMPOSE_FILE}" "${flags[@]}" config --services 2>/dev/null | sort)
[[ ${#SERVICES[@]} -gt 0 ]] || { red "[footprint] no services resolved for profiles: '${PROFILES}'"; exit 1; }

# ── snapshot live stats once (name → "memTok cpu%") ──
declare -A MEM CPU
while read -r name memtok cpu; do
  [[ -n "${name}" ]] || continue
  MEM["${name}"]="${memtok}"
  CPU["${name}"]="${cpu}"
done < <(docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' 2>/dev/null | awk '{print $1, $2, $5}')

cyan "[footprint] ${LABEL} — profiles: ${PROFILES:-<always-on core>}  (${#SERVICES[@]} services)"
printf '  %-26s %-9s %10s %10s   %s\n' "SERVICE" "LANG" "RAM(MiB)" "IMG(MiB)" "STATE"
printf '  %s\n' "-------------------------------------------------------------------------------"

ram_total=0
declare -A SEEN_IMG
img_total=0
json_rows=""

for svc in "${SERVICES[@]}"; do
  cname="${PREFIX}-${svc}"
  lang="$(lang_of "${svc}")"
  state="down"; ram="0"; img="—"
  is_init=0; [[ "${INIT_SVCS}" == *" ${svc} "* ]] && is_init=1

  if docker inspect "${cname}" >/dev/null 2>&1; then
    # image size (dedup by image id across services)
    imgid="$(docker inspect --format '{{.Image}}' "${cname}" 2>/dev/null || true)"
    if [[ -n "${imgid}" ]]; then
      imgbytes="$(docker image inspect --format '{{.Size}}' "${imgid}" 2>/dev/null || echo 0)"
      img="$(awk -v b="${imgbytes}" 'BEGIN{printf "%.0f", b/1024/1024}')"
      if [[ -z "${SEEN_IMG[${imgid}]:-}" ]]; then
        SEEN_IMG["${imgid}"]=1
        img_total="$(awk -v a="${img_total}" -v b="${img}" 'BEGIN{printf "%.0f", a+b}')"
      fi
    fi
    if [[ -n "${MEM[${cname}]:-}" ]]; then
      state="up"; ram="$(to_mib "${MEM[${cname}]}")"
      [[ "${is_init}" -eq 0 ]] && ram_total="$(awk -v a="${ram_total}" -v b="${ram}" 'BEGIN{printf "%.1f", a+b}')"
      [[ "${is_init}" -eq 1 ]] && state="init"
    else
      state="$([[ ${is_init} -eq 1 ]] && echo 'init(exited)' || echo 'down')"
    fi
  fi

  printf '  %-26s %-9s %10s %10s   %s\n' "${svc}" "${lang}" "${ram}" "${img}" "${state}"
  json_rows="${json_rows}{\"service\":\"${svc}\",\"lang\":\"${lang}\",\"ram_mib\":${ram:-0},\"img_mib\":${img/—/0},\"state\":\"${state}\"},"
done

printf '  %s\n' "-------------------------------------------------------------------------------"
printf '  %-26s %-9s %10s %10s\n' "TOTAL (running)" "" "${ram_total}" "${img_total}"

verdict="n/a"; rc=0
if [[ -n "${BAR_MB}" ]]; then
  if awk -v r="${ram_total}" -v b="${BAR_MB}" 'BEGIN{exit !(r<=b)}'; then
    green "  ✓ ${ram_total} MiB ≤ ${BAR_MB} MiB budget"; verdict="pass"
  else
    red "  ✗ ${ram_total} MiB > ${BAR_MB} MiB budget"; verdict="fail"; rc=1
  fi
fi

mkdir -p artifacts
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"label":"%s","generated":"%s","profiles":"%s","ram_mib_total":%s,"img_mib_total":%s,"bar_mib":%s,"verdict":"%s","services":[%s]}\n' \
  "${LABEL}" "${ts}" "${PROFILES}" "${ram_total:-0}" "${img_total:-0}" "${BAR_MB:-null}" "${verdict}" "${json_rows%,}" \
  > "artifacts/footprint-${LABEL}.json"
yellow "  → artifacts/footprint-${LABEL}.json"
exit "${rc}"
