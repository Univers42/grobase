#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    nano-one-pb-load.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Phase G: THREE-column concurrent benchmark — binocle-nano, binocle-one
# (full app backend: accounts/OAuth/MFA/files/admin UI compiled in), and the
# official PocketBase release. Method identical to nano-vs-pocketbase-load.sh:
# oha at c=1/16/64, RSS sampled mid-load, BIG_N-row run with disk-after,
# boot-to-first-200. Proves the one edition's feature weight costs ~nothing
# on the hot path (same engine, same group-commit writer).
#
# Inputs: PB_VERSION (default 0.39.3), DUR (default 8s), BIG_N (default 100000).
# Writes artifacts/nano-one-pb-load.json + a human table.

set -euo pipefail
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

PB_VERSION="${PB_VERSION:-0.39.3}"
DUR="${DUR:-8s}"
BIG_N="${BIG_N:-100000}"
NANO_PORT=18954
ONE_PORT=18955
PB_PORT=18956
WORK="$(mktemp -d)"
OHA_IMG="ghcr.io/hatoo/oha:latest"

cleanup() {
  docker rm -fv g-nano g-one g-pb >/dev/null 2>&1 || true
  docker volume rm -f g-nano-data g-one-data >/dev/null 2>&1 || true
  docker run --rm -v "${WORK}:/w" public.ecr.aws/docker/library/alpine:3.20 \
    sh -c 'rm -rf /w/pb_data /w/pb_migrations' >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

docker image inspect binocle-nano >/dev/null 2>&1 || {
  echo "build first: make nano-build"
  exit 1
}
docker image inspect binocle-one >/dev/null 2>&1 || {
  echo "build first: make one-build"
  exit 1
}
docker pull -q "${OHA_IMG}" >/dev/null

oha() { docker run --rm --network host "${OHA_IMG}" --no-tui --output-format json "$@"; }
parse() { python3 -c "
import sys, json
r = json.load(sys.stdin)
rps = r['summary']['requestsPerSec']
lp = r.get('latencyPercentiles', {})
def ms(k): return (lp.get(k) or 0) * 1000
print(f\"{rps:.0f} {ms('p50'):.1f} {ms('p95'):.1f} {ms('p99'):.1f}\")"; }

# ── boot all three ───────────────────────────────────────────────────────────
cyan "[G] booting nano (:${NANO_PORT}), one (:${ONE_PORT}), PocketBase v${PB_VERSION} (:${PB_PORT})"
NK="g-admin-$(date +%s)"
docker run -d --name g-nano -p "${NANO_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" \
  -v g-nano-data:/data binocle-nano >/dev/null
docker run -d --name g-one -p "${ONE_PORT}:8090" -e NANO_ADMIN_KEY="${NK}" \
  -v g-one-data:/data binocle-one >/dev/null
NANO="http://127.0.0.1:${NANO_PORT}"
ONE="http://127.0.0.1:${ONE_PORT}"

curl -sL -o "${WORK}/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
(cd "${WORK}" && unzip -oq pb.zip)
docker run -d --name g-pb -p "${PB_PORT}:8090" -v "${WORK}:/pb" \
  public.ecr.aws/docker/library/alpine:3.20 \
  /pb/pocketbase serve --http 0.0.0.0:8090 --dir /pb/pb_data >/dev/null
PB="http://127.0.0.1:${PB_PORT}"

for i in $(seq 1 30); do
  curl -sf "${NANO}/v1/health" >/dev/null 2>&1 &&
    curl -sf "${ONE}/v1/health" >/dev/null 2>&1 &&
    curl -sf "${PB}/api/health" >/dev/null 2>&1 && break
  [[ $i -eq 30 ]] && {
    echo "boot timeout"
    exit 1
  }
  sleep 0.5
done

# ── schema on all three ──────────────────────────────────────────────────────
for base in "${NANO}" "${ONE}"; do
  curl -s -X POST "${base}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d '{"db_id":"main","statement":"CREATE TABLE IF NOT EXISTS bench (owner_id TEXT NOT NULL, title TEXT)"}' >/dev/null
  # FAIRNESS: index owner_id so the per-request owner-scope predicate is not an
  # unindexed scan — PocketBase's collection is indexed by default, so without
  # this the list comparison penalised binocle on an avoidable table scan.
  curl -s -X POST "${base}/nano/v1/raw" -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d '{"db_id":"main","statement":"CREATE INDEX IF NOT EXISTS bench_owner ON bench(owner_id)"}' >/dev/null
done
docker exec g-pb /pb/pocketbase superuser upsert bench@local.dev super-secret-pw-123 --dir /pb/pb_data >/dev/null 2>&1
PB_TOKEN=$(curl -s -X POST "${PB}/api/collections/_superusers/auth-with-password" \
  -H "Content-Type: application/json" \
  -d '{"identity":"bench@local.dev","password":"super-secret-pw-123"}' |
  python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[[ -n "${PB_TOKEN}" ]] || {
  echo "PocketBase auth failed"
  exit 1
}
curl -s -X POST "${PB}/api/collections" -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d '{"name":"bench","type":"base","fields":[{"name":"title","type":"text"}]}' >/dev/null

INS_BODY='{"db_id":"main","operation":{"op":"insert","resource":"bench","data":{"title":"load"}}}'
LIST_BODY='{"db_id":"main","operation":{"op":"list","resource":"bench","limit":30}}'
PB_INS_BODY='{"title":"load"}'

run_ins() { # base
  oha -z "${DUR}" -c "$2" -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "${INS_BODY}" "$1/data/v1/query" | parse
}
run_list() { # base c
  oha -z "${DUR}" -c "$2" -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
    -d "${LIST_BODY}" "$1/data/v1/query" | parse
}

# ── warmup (discarded) — prime statement cache + page cache + seed a few rows
#    equally so the measured list sweep is warm + fair for all three, per
#    scripts/bench/METHOD.md rule #3 (warmup excluded from the measurement).
cyan "[G] warmup (discarded)"
for base in "${NANO}" "${ONE}"; do
  for _ in $(seq 1 60); do
    curl -s -X POST "${base}/data/v1/query" -H "X-Baas-Api-Key: ${NK}" \
      -H "Content-Type: application/json" -d "${INS_BODY}" >/dev/null
  done
  curl -s -X POST "${base}/data/v1/query" -H "X-Baas-Api-Key: ${NK}" \
    -H "Content-Type: application/json" -d "${LIST_BODY}" >/dev/null
done
for _ in $(seq 1 60); do
  curl -s -X POST "${PB}/api/collections/bench/records" -H "Authorization: ${PB_TOKEN}" \
    -H "Content-Type: application/json" -d "${PB_INS_BODY}" >/dev/null
done
curl -s "${PB}/api/collections/bench/records?perPage=30&skipTotal=1" -H "Authorization: ${PB_TOKEN}" >/dev/null

# ── concurrency sweep ────────────────────────────────────────────────────────
declare -A R
for c in 1 16 64; do
  cyan "[G] c=${c} insert ${DUR} × 3"
  R[nano,ins,$c]=$(run_ins "${NANO}" "$c")
  R[one,ins,$c]=$(run_ins "${ONE}" "$c")
  R[pb,ins,$c]=$(oha -z "${DUR}" -c "${c}" -m POST \
    -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
    -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse)
  cyan "[G] c=${c} list(30) ${DUR} × 3"
  R[nano,list,$c]=$(run_list "${NANO}" "$c")
  R[one,list,$c]=$(run_list "${ONE}" "$c")
  R[pb,list,$c]=$(oha -z "${DUR}" -c "${c}" \
    -H "Authorization: ${PB_TOKEN}" \
    "${PB}/api/collections/bench/records?perPage=30&skipTotal=1" | parse)
done

# ── RSS under load (sampled mid-flight of a c=64 insert run) ────────────────
cyan "[G] RSS under c=64 insert load"
(
  sleep 3
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' g-nano g-one g-pb >"${WORK}/rss.txt"
) &
SAMPLER=$!
oha -z 7s -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${NANO}/data/v1/query" >/dev/null &
P1=$!
oha -z 7s -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${ONE}/data/v1/query" >/dev/null &
P2=$!
oha -z 7s -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" >/dev/null &
P3=$!
wait "${SAMPLER}" "${P1}" "${P2}" "${P3}"
NANO_RSS=$(awk '/g-nano/{print $2}' "${WORK}/rss.txt")
ONE_RSS=$(awk '/g-one/{print $2}' "${WORK}/rss.txt")
PB_RSS=$(awk '/g-pb/{print $2}' "${WORK}/rss.txt")

# ── BIG_N-row insert + disk after ────────────────────────────────────────────
cyan "[G] ${BIG_N}-row insert run (c=64) × 3"
NANO_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${NANO}/data/v1/query" | parse)
ONE_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "X-Baas-Api-Key: ${NK}" -H "Content-Type: application/json" \
  -d "${INS_BODY}" "${ONE}/data/v1/query" | parse)
PB_BIG=$(oha -n "${BIG_N}" -c 64 -m POST -H "Authorization: ${PB_TOKEN}" -H "Content-Type: application/json" \
  -d "${PB_INS_BODY}" "${PB}/api/collections/bench/records" | parse)
NANO_DISK=$(docker run --rm -v g-nano-data:/d public.ecr.aws/docker/library/alpine:3.20 du -sk /d | awk '{printf "%.1f MB", $1/1024}')
ONE_DISK=$(docker run --rm -v g-one-data:/d public.ecr.aws/docker/library/alpine:3.20 du -sk /d | awk '{printf "%.1f MB", $1/1024}')
PB_DISK=$(docker exec g-pb du -sk /pb/pb_data | awk '{printf "%.1f MB", $1/1024}')

# ── boot-to-first-200 ────────────────────────────────────────────────────────
boot_ms() { # container url
  docker restart "$1" >/dev/null
  local t0
  t0=$(date +%s%N)
  while ! curl -sf "$2" >/dev/null 2>&1; do sleep 0.01; done
  awk -v d=$(($(date +%s%N) - t0)) 'BEGIN{printf "%.0f", d/1000000}'
}
cyan "[G] boot-to-first-200 × 3"
NANO_BOOT=$(boot_ms g-nano "${NANO}/v1/health")
ONE_BOOT=$(boot_ms g-one "${ONE}/v1/health")
PB_BOOT=$(boot_ms g-pb "${PB}/api/health")

# ── report ───────────────────────────────────────────────────────────────────
row() { # label op c
  local n o p
  read -ra n <<<"${R[nano,$2,$3]}"
  read -ra o <<<"${R[one,$2,$3]}"
  read -ra p <<<"${R[pb,$2,$3]}"
  printf '  %-20s %8s %7s   %8s %7s   %8s %7s\n' \
    "$1" "${n[0]}" "${n[3]}" "${o[0]}" "${o[3]}" "${p[0]}" "${p[3]}"
}
echo
green "── nano vs one vs PocketBase v${PB_VERSION} (oha ${DUR}/run; RPS + p99 ms) ──"
printf '  %-20s %-16s   %-16s   %-16s\n' "" "── nano ──" "── one ──" "── PocketBase ──"
printf '  %-20s %8s %7s   %8s %7s   %8s %7s\n' "op @ c" "RPS" "p99" "RPS" "p99" "RPS" "p99"
for c in 1 16 64; do row "insert @ c=${c}" ins "$c"; done
for c in 1 16 64; do row "list 30 @ c=${c}" list "$c"; done
read -ra NB <<<"${NANO_BIG}"
read -ra OB <<<"${ONE_BIG}"
read -ra PBB <<<"${PB_BIG}"
printf '  %-20s %8s %7s   %8s %7s   %8s %7s\n' "${BIG_N} rows @ c=64" "${NB[0]}" "${NB[3]}" "${OB[0]}" "${OB[3]}" "${PBB[0]}" "${PBB[3]}"
printf '  %-20s %16s   %16s   %16s\n' "RSS under load" "${NANO_RSS}" "${ONE_RSS}" "${PB_RSS}"
printf '  %-20s %16s   %16s   %16s\n' "disk after big run" "${NANO_DISK}" "${ONE_DISK}" "${PB_DISK}"
printf '  %-20s %13s ms   %13s ms   %13s ms\n' "boot → first 200" "${NANO_BOOT}" "${ONE_BOOT}" "${PB_BOOT}"
echo

mkdir -p artifacts
python3 - "$PB_VERSION" "$DUR" "$BIG_N" <<EOF >artifacts/nano-one-pb-load.json
import json, sys, datetime
R = {
$(for c in 1 16 64; do for op in ins list; do for s in nano one pb; do
  echo "  (\"$s\",\"$op\",$c): \"${R[$s,$op,$c]}\","
done; done; done)
}
def unpack(s):
    rps, p50, p95, p99 = s.split()
    return {"rps": float(rps), "p50_ms": float(p50), "p95_ms": float(p95), "p99_ms": float(p99)}
out = {
  "generated": datetime.datetime.utcnow().isoformat() + "Z",
  "pocketbase_version": sys.argv[1], "duration": sys.argv[2], "big_n": int(sys.argv[3]),
  "sweep": {f"{s}/{op}/c{c}": unpack(v) for (s, op, c), v in R.items()},
  "big_run": {"nano": unpack("${NANO_BIG}"), "one": unpack("${ONE_BIG}"), "pocketbase": unpack("${PB_BIG}")},
  "rss_under_load": {"nano": "${NANO_RSS}", "one": "${ONE_RSS}", "pocketbase": "${PB_RSS}"},
  "disk_after_big": {"nano": "${NANO_DISK}", "one": "${ONE_DISK}", "pocketbase": "${PB_DISK}"},
  "boot_ms": {"nano": ${NANO_BOOT}, "one": ${ONE_BOOT}, "pocketbase": ${PB_BOOT}},
}
print(json.dumps(out, indent=2))
EOF
green "→ artifacts/nano-one-pb-load.json"
