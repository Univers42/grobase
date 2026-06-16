#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    nano-vs-pocketbase-load.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# CONCURRENT load benchmark: binocle-nano vs the OFFICIAL PocketBase release
# binary. The sequential bench (nano-vs-pocketbase.sh) is curl-spawn-dominated;
# this one drives both with `oha` (HTTP load generator) at c=1/16/64 and
# reports what actually matters under load: RPS, p50/p95/p99, RSS during the
# heaviest run, a 100k-row insert (TrailBase-style) with disk-after, and
# boot-to-first-200. Honest by construction: same box, same driver, official
# upstream binary, identical 8s windows.
#
# Inputs: PB_VERSION (default 0.39.3), DUR (default 8s), BIG_N (default 100000).
# Writes artifacts/nano-vs-pocketbase-load.json + a human table.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

PB_VERSION="${PB_VERSION:-0.39.3}"
DUR="${DUR:-8s}"
BIG_N="${BIG_N:-100000}"
NANO_PORT=18951
PB_PORT=18952
WORK="$(mktemp -d)"
OHA_IMG="ghcr.io/hatoo/oha:latest"

cleanup(){
  docker rm -fv load-nano load-pb >/dev/null 2>&1 || true
  docker volume rm -f load-nano-data >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/pb_data /w/pb_migrations' >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

docker image inspect binocle-nano >/dev/null 2>&1 || { echo "build first: make nano-build"; exit 1; }
docker pull -q "${OHA_IMG}" >/dev/null

# oha runner: --network host so it reaches the published 127.0.0.1 ports.
oha(){ docker run --rm --network host "${OHA_IMG}" --no-tui --output-format json "$@"; }
# Extract "rps p50 p95 p99(ms)" from an oha JSON report.
parse(){ python3 -c "
import sys, json
r = json.load(sys.stdin)
rps = r['summary']['requestsPerSec']
lp = r.get('latencyPercentiles', {})
def ms(k): return (lp.get(k) or 0) * 1000
print(f\"{rps:.0f} {ms('p50'):.1f} {ms('p95'):.1f} {ms('p99'):.1f}\")"; }

# ── boot ─────────────────────────────────────────────────────────────────────
cyan "[load] booting binocle-nano (:${NANO_PORT}) + PocketBase v${PB_VERSION} (:${PB_PORT})"
NK="load-admin-$(date +%s)"
docker run -d --name load-nano -p "${NANO_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" \
  -v load-nano-data:/data binocle-nano >/dev/null
NANO="http://127.0.0.1:${NANO_PORT}"

curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name load-pb -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
PB="http://127.0.0.1:${PB_PORT}"

for i in $(seq 1 30); do
  curl -sf "${NANO}/v1/health" >/dev/null 2>&1 && curl -sf "${PB}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 30 ]] && { echo "boot timeout"; exit 1; }
  sleep 0.5
done

# ── schema (bench table WITHOUT a client id — static oha bodies must insert) ─
curl -s -X POST "${NANO}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS bench (owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
docker exec load-pb /pb/pocketbase superuser upsert bench@local.dev super-secret-pw-123 --dir /pb/pb_data >/dev/null 2>&1
PB_TOKEN=$(curl -s -X POST "${PB}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" \
  -d '{"identity":"bench@local.dev","password":"super-secret-pw-123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[[ -n "${PB_TOKEN}" ]] || { echo "PocketBase auth failed"; exit 1; }
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"bench","type":"base","fields":[{"name":"title","type":"text"}]}' >/dev/null

NANO_INS_BODY='{"db_id":"main","operation":{"op":"insert","resource":"bench","data":{"title":"load"}}}'
NANO_LIST_BODY='{"db_id":"main","operation":{"op":"list","resource":"bench","limit":30}}'
PB_INS_BODY='{"title":"load"}'

# ── concurrency sweep ────────────────────────────────────────────────────────
declare -A R   # R[system,op,c] = "rps p50 p95 p99"
for c in 1 16 64; do
  cyan "[load] c=${c} insert ${DUR} each"
  R[nano,ins,$c]=$(oha -z "${DUR}" -c "${c}" -m POST \
    -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "${NANO_INS_BODY}" "${NANO}/data/v1/query" | parse)
  R[pb,ins,$c]=$(oha -z "${DUR}" -c "${c}" -m POST \
    -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
    -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse)
  cyan "[load] c=${c} list(30) ${DUR} each"
  R[nano,list,$c]=$(oha -z "${DUR}" -c "${c}" -m POST \
    -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "${NANO_LIST_BODY}" "${NANO}/data/v1/query" | parse)
  R[pb,list,$c]=$(oha -z "${DUR}" -c "${c}" \
    -H "Authorization: ${PB_TOKEN}" \
    "${PB}/api/collections/bench/records?perPage=30&skipTotal=1" | parse)
done

# ── RSS under load (sampled mid-flight of a c=64 insert run) ────────────────
cyan "[load] RSS under c=64 insert load"
( sleep 3; docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' load-nano load-pb > "${WORK}/rss.txt" ) &
SAMPLER=$!
oha -z 7s -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${NANO_INS_BODY}" "${NANO}/data/v1/query" >/dev/null &
P1=$!
oha -z 7s -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" >/dev/null &
P2=$!
wait "${SAMPLER}" "${P1}" "${P2}"
NANO_RSS_LOAD=$(awk '/load-nano/{print $2}' "${WORK}/rss.txt")
PB_RSS_LOAD=$(awk '/load-pb/{print $2}' "${WORK}/rss.txt")

# ── 100k-row insert (TrailBase-style) + disk after ──────────────────────────
cyan "[load] ${BIG_N}-row insert run (c=64)"
NANO_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${NANO_INS_BODY}" "${NANO}/data/v1/query" | parse)
PB_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse)
NANO_DISK=$(docker run --rm -v load-nano-data:/d public.ecr.aws/docker/library/alpine:3.20 du -sk /d | awk '{printf "%.1f MB", $1/1024}')
PB_DISK=$(docker exec load-pb du -sk /pb/pb_data | awk '{printf "%.1f MB", $1/1024}')

# ── boot-to-first-200 ────────────────────────────────────────────────────────
boot_ms(){ # container url
  docker restart "$1" >/dev/null
  local t0; t0=$(date +%s%N)
  while ! curl -sf "$2" >/dev/null 2>&1; do sleep 0.01; done
  awk -v d=$(( $(date +%s%N) - t0 )) 'BEGIN{printf "%.0f", d/1000000}'
}
cyan "[load] boot-to-first-200"
NANO_BOOT=$(boot_ms load-nano "${NANO}/v1/health")
PB_BOOT=$(boot_ms load-pb "${PB}/api/health")

# ── report ───────────────────────────────────────────────────────────────────
row(){ # label key
  local n=(${R[nano,$2,$3]}) p=(${R[pb,$2,$3]})
  printf '  %-22s %9s %7s %7s %7s   %9s %7s %7s %7s\n' \
    "$1" "${n[0]}" "${n[1]}" "${n[2]}" "${n[3]}" "${p[0]}" "${p[1]}" "${p[2]}" "${p[3]}"
}
echo
green "── CONCURRENT: binocle-nano vs PocketBase v${PB_VERSION} (oha, ${DUR}/run) ──"
printf '  %-22s %s   %s\n' "" "──────── binocle-nano ───────" "──────── PocketBase ─────────"
printf '  %-22s %9s %7s %7s %7s   %9s %7s %7s %7s\n' "op @ concurrency" "RPS" "p50" "p95" "p99" "RPS" "p50" "p95" "p99"
for c in 1 16 64; do row "insert @ c=${c}" ins "$c"; done
for c in 1 16 64; do row "list 30 @ c=${c}" list "$c"; done
N_BIG=(${NANO_BIG}); P_BIG=(${PB_BIG})
printf '  %-22s %9s %7s %7s %7s   %9s %7s %7s %7s\n' "${BIG_N}-row @ c=64" "${N_BIG[0]}" "${N_BIG[1]}" "${N_BIG[2]}" "${N_BIG[3]}" "${P_BIG[0]}" "${P_BIG[1]}" "${P_BIG[2]}" "${P_BIG[3]}"
printf '  %-22s %25s   %25s\n' "RSS under c=64 load" "${NANO_RSS_LOAD}" "${PB_RSS_LOAD}"
printf '  %-22s %25s   %25s\n' "disk after ${BIG_N}+" "${NANO_DISK}" "${PB_DISK}"
printf '  %-22s %22s ms   %22s ms\n' "boot → first 200" "${NANO_BOOT}" "${PB_BOOT}"
echo

mkdir -p artifacts
python3 - "$PB_VERSION" "$DUR" "$BIG_N" <<EOF > artifacts/nano-vs-pocketbase-load.json
import json, sys, datetime
R = {
$(for c in 1 16 64; do for op in ins list; do
  echo "  (\"nano\",\"$op\",$c): \"${R[nano,$op,$c]}\","
  echo "  (\"pb\",\"$op\",$c): \"${R[pb,$op,$c]}\","
done; done)
}
def unpack(s):
    rps, p50, p95, p99 = s.split()
    return {"rps": float(rps), "p50_ms": float(p50), "p95_ms": float(p95), "p99_ms": float(p99)}
out = {
  "generated": datetime.datetime.utcnow().isoformat() + "Z",
  "pocketbase_version": sys.argv[1], "duration": sys.argv[2], "big_n": int(sys.argv[3]),
  "sweep": {f"{sys_}/{op}/c{c}": unpack(v) for (sys_, op, c), v in R.items()},
  "big_run": {"nano": unpack("${NANO_BIG}"), "pocketbase": unpack("${PB_BIG}")},
  "rss_under_load": {"nano": "${NANO_RSS_LOAD}", "pocketbase": "${PB_RSS_LOAD}"},
  "disk_after_big": {"nano": "${NANO_DISK}", "pocketbase": "${PB_DISK}"},
  "boot_ms": {"nano": ${NANO_BOOT}, "pocketbase": ${PB_BOOT}},
}
print(json.dumps(out, indent=2))
EOF
green "→ artifacts/nano-vs-pocketbase-load.json"
