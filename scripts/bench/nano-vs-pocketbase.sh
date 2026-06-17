#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    nano-vs-pocketbase.sh                              :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Head-to-head: binocle-nano vs the OFFICIAL PocketBase release binary, same
# box, same method — binary size, idle RSS, and sequential insert/list
# latency over each system's native REST API. Honest by construction: both
# run in containers, both timed by the same curl loop from the host, and the
# PocketBase binary is the unmodified upstream release.
#
# Inputs: PB_VERSION (default 0.39.3), N (requests per op, default 100).
# Writes artifacts/nano-vs-pocketbase.json + a human table.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

PB_VERSION="${PB_VERSION:-0.39.3}"
N="${N:-100}"
NANO_PORT=18941
PB_PORT=18942
WORK="$(mktemp -d)"

cleanup(){
  # -v: binocle-nano declares VOLUME /data — drop its anonymous volume too.
  docker rm -fv bench-nano bench-pb >/dev/null 2>&1 || true
  # pb_data is written by root inside the PB container — remove it the same way.
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/pb_data /w/pb_migrations' >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ── boot binocle-nano ────────────────────────────────────────────────────────
cyan "[bench] booting binocle-nano (:${NANO_PORT})"
docker image inspect binocle-nano >/dev/null 2>&1 || { echo "build first: make nano-build"; exit 1; }
NK="bench-admin-$(date +%s)"
docker run -d --name bench-nano -p "${NANO_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" binocle-nano >/dev/null
NANO="http://127.0.0.1:${NANO_PORT}"

# ── boot official PocketBase ─────────────────────────────────────────────────
cyan "[bench] booting PocketBase v${PB_VERSION} (:${PB_PORT}) — official release binary"
if [[ ! -x "${WORK}/pocketbase" ]]; then
  curl -sL -o "${WORK}/pb.zip" \
    "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
  (cd "${WORK}" && unzip -oq pb.zip)
fi
PB_BIN_BYTES=$(stat -c%s "${WORK}/pocketbase")
docker run -d --name bench-pb -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
PB="http://127.0.0.1:${PB_PORT}"

for i in $(seq 1 30); do
  curl -sf "${NANO}/v1/health" >/dev/null 2>&1 && curl -sf "${PB}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 30 ]] && { echo "boot timeout"; exit 1; }
  sleep 0.5
done

# ── schema setup on both ─────────────────────────────────────────────────────
cyan "[bench] schema setup"
curl -s -X POST "${NANO}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null

docker exec bench-pb /pb/pocketbase superuser upsert bench@local.dev super-secret-pw-123 --dir /pb/pb_data >/dev/null 2>&1
PB_TOKEN=$(curl -s -X POST "${PB}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" \
  -d '{"identity":"bench@local.dev","password":"super-secret-pw-123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[[ -n "${PB_TOKEN}" ]] || { echo "PocketBase auth failed"; exit 1; }
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"notes","type":"base","fields":[{"name":"title","type":"text"}]}' >/dev/null

# ── latency: N sequential inserts + N sequential lists ──────────────────────
ms_per_req(){ # cmd-prefix array via "$@"; echoes ms/req for N runs
  local start end
  start=$(date +%s%N)
  for i in $(seq 1 "${N}"); do "$@" >/dev/null; done
  end=$(date +%s%N)
  awk -v d=$(( end - start )) -v n="${N}" 'BEGIN{printf "%.1f", d/1000000/n}'
}

cyan "[bench] ${N} sequential inserts each"
NANO_INS=$(ms_per_req curl -s -X POST "${NANO}/data/v1/query" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  --data-raw '{"db_id":"main","operation":{"op":"insert","resource":"notes","data":{"title":"bench"}}}' )
PB_INS=$(ms_per_req curl -s -X POST "${PB}/api/collections/notes/records" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  --data-raw '{"title":"bench"}' )

cyan "[bench] ${N} sequential list reads each (limit 30)"
NANO_LIST=$(ms_per_req curl -s -X POST "${NANO}/data/v1/query" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  --data-raw '{"db_id":"main","operation":{"op":"list","resource":"notes","limit":30}}' )
PB_LIST=$(ms_per_req curl -s "${PB}/api/collections/notes/records?perPage=30" -H "Authorization: ${PB_TOKEN}")

# ── footprint ────────────────────────────────────────────────────────────────
sleep 2
NANO_MEM=$(docker stats --no-stream --format '{{.MemUsage}}' bench-nano | awk '{print $1}')
PB_MEM=$(docker stats --no-stream --format '{{.MemUsage}}' bench-pb | awk '{print $1}')
NANO_BIN_BYTES=$(docker image inspect --format '{{.Size}}' binocle-nano)

# ── report ───────────────────────────────────────────────────────────────────
PB_BIN_MB=$(awk -v b="${PB_BIN_BYTES}" 'BEGIN{printf "%.1f", b/1024/1024}')
NANO_BIN_MB=$(awk -v b="${NANO_BIN_BYTES}" 'BEGIN{printf "%.1f", b/1024/1024}')
echo
green "── binocle-nano vs PocketBase v${PB_VERSION} (same box, official binary, N=${N}) ──"
printf '  %-28s %14s %16s\n' "" "binocle-nano" "PocketBase"
printf '  %-28s %14s %16s\n' "binary / image size" "${NANO_BIN_MB} MB" "${PB_BIN_MB} MB"
printf '  %-28s %14s %16s\n' "RSS after load" "${NANO_MEM}" "${PB_MEM}"
printf '  %-28s %14s %16s\n' "insert (ms/req, sequential)" "${NANO_INS}" "${PB_INS}"
printf '  %-28s %14s %16s\n' "list 30 (ms/req, sequential)" "${NANO_LIST}" "${PB_LIST}"
echo

mkdir -p artifacts
printf '{"generated":"%s","pocketbase_version":"%s","n":%s,"nano":{"image_mb":%s,"rss":"%s","insert_ms":%s,"list_ms":%s},"pocketbase":{"binary_mb":%s,"rss":"%s","insert_ms":%s,"list_ms":%s}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PB_VERSION}" "${N}" \
  "${NANO_BIN_MB}" "${NANO_MEM}" "${NANO_INS}" "${NANO_LIST}" \
  "${PB_BIN_MB}" "${PB_MEM}" "${PB_INS}" "${PB_LIST}" \
  > artifacts/nano-vs-pocketbase.json
green "→ artifacts/nano-vs-pocketbase.json"
