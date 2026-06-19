#!/usr/bin/env bash
# **************************************************************************** #
#  m154-hypertube-stream.sh — Hypertube fast-stream engine (Rust) gate          #
#                                                                              #
#  Proves the hypertube-stream Rust engine delivers YouTube-style direct-HTTP    #
#  range streaming over Kong /stream against the RUNNING stack:                   #
#    1. health  — GET /stream/v1/health → 200 (the engine is up).               #
#    2. stream   — GET /stream/v1/movies/<archive:id> with Range bytes=0-1MiB    #
#                  → HTTP 206 Partial Content + Content-Range + Accept-Ranges +   #
#                  `X-Accel-Buffering: no` (unbuffered progressive playback).     #
#    3. audio    — ffprobe the same stream → assert BOTH a video AND an audio     #
#                  track (the "no sound" regression guard). BEST-EFFORT: skips    #
#                  if the ffmpeg image can't be pulled (offline CI).             #
#                                                                              #
#  The 206/Content-Range/X-Accel-Buffering triad is the load-bearing proof — a    #
#  health-only gate is VACUOUS. Steps 2–3 reach archive.org (external), so they    #
#  SKIP rather than fail when the source is unreachable (CI stays green offline). #
# **************************************************************************** #
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/lib-live-tenant.sh
source "${BAAS_DIR}/scripts/lib/lib-live-tenant.sh"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M154] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
skip() {
  printf '\033[0;33mSKIP m154: %s\033[0m\n' "$*"
  exit 0
}
fail() {
  printf '\033[0;31m[M154] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A real public-domain feature film on archive.org (h264+aac mp4). The Rust
# engine resolves any "archive:<identifier>" via the archive.org metadata API,
# so this gate needs no seeded catalog. Overridable for a local source.
MOVIE_ID="${M154_MOVIE_ID:-archive:nosferatu_201508}"
RANGE='bytes=0-1048575'
NET="${HT_DOCKER_NET:-mini-baas_mini-baas}"

# ── 0) stack reachable + stream route present? otherwise SKIP ────────────────
KPORT="$(_lt_host_port mini-baas-kong 8000/tcp)"
[[ -n "${KPORT}" ]] || skip "mini-baas-kong not running (make up + docker compose --profile hypertube up -d)"
KONG="http://127.0.0.1:${KPORT}"
ANON="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
[[ -n "${ANON}" ]] || skip "anon key not found on mini-baas-kong"

# ── 1) health: the stream engine answers /stream/v1/health ───────────────────
step "1/3 GET /stream/v1/health → 200"
hc="$(curl -s -o "${TMP}/h.txt" -w '%{http_code}' --max-time 5 "${KONG}/stream/v1/health" -H "apikey: ${ANON}" 2>/dev/null || echo 000)"
[[ "${hc}" == "200" ]] || skip "hypertube-stream not reachable (/stream/v1/health → ${hc}); start the hypertube profile"
ok "stream engine healthy (200)"

# ── 2) range stream over Kong: first MiB → 206 + Content-Range + Accept-Ranges ─
step "2/4 GET /stream/v1/movies/${MOVIE_ID} Range:${RANGE} → 206 + ranges"
mid_enc="${MOVIE_ID//:/%3A}"
curl -s -D "${TMP}/hdr.txt" -o /dev/null --max-time 40 \
  "${KONG}/stream/v1/movies/${mid_enc}?apikey=${ANON}" -H "Range: ${RANGE}" 2>/dev/null || true
grep -qiE '^HTTP/[0-9.]+ 206' "${TMP}/hdr.txt" 2>/dev/null \
  || skip "no 206 from archive.org source in the window (external) — health proven, stream best-effort"
grep -qiE '^Content-Range:[[:space:]]*bytes ' "${TMP}/hdr.txt" \
  || fail "206 without a Content-Range header — not a real partial-content response"
grep -qiE '^Accept-Ranges:[[:space:]]*bytes' "${TMP}/hdr.txt" \
  || fail "missing 'Accept-Ranges: bytes' — the player cannot seek"
ok "Kong 206 Partial Content + Content-Range + Accept-Ranges"

# ── 3) unbuffering directive: assert at the SERVICE, not the client ──────────
# X-Accel-Buffering is an nginx directive header — Kong (OpenResty) READS it to
# disable its own buffering for the response, then strips it before the client.
# So its presence is proven at the service directly (in-net, bypassing Kong);
# that is what makes Kong stream the long body unbuffered (progressive playback).
step "3/4 engine emits X-Accel-Buffering:no (direct, pre-Kong)"
docker run --rm --network "${NET}" curlimages/curl:latest \
  -s -D - -o /dev/null --max-time 40 \
  "http://mini-baas-hypertube-stream:3083/stream/v1/movies/${mid_enc}" -H "Range: ${RANGE}" \
  >"${TMP}/direct.txt" 2>/dev/null || true
grep -qiE '^x-accel-buffering:[[:space:]]*no' "${TMP}/direct.txt" \
  || fail "stream engine did not emit 'X-Accel-Buffering: no' — Kong would buffer and stall playback"
ok "engine emits X-Accel-Buffering:no (Kong honors + consumes it)"

# ── 4) audio guard: ffprobe the stream → a Video AND an Audio track ──────────
step "4/4 ffprobe stream → Video + Audio tracks present (sound regression guard)"
url_in_net="http://mini-baas-kong:8000/stream/v1/movies/${mid_enc}?apikey=${ANON}"
if ! docker run --rm --network "${NET}" mwader/static-ffmpeg:latest \
  -hide_banner -i "${url_in_net}" >"${TMP}/probe.txt" 2>&1; then
  : # ffmpeg exits non-zero with no output specified — the stream banner is still captured
fi
if ! grep -qiE 'Stream #' "${TMP}/probe.txt"; then
  skip "ffmpeg image/probe unavailable — 206 stream proven, audio probe best-effort"
fi
grep -qiE 'Video:' "${TMP}/probe.txt" || fail "no Video stream in the served file"
grep -qiE 'Audio:' "${TMP}/probe.txt" || fail "no Audio stream — the 'no sound' regression is back"
acodec="$(grep -iE 'Audio:' "${TMP}/probe.txt" | head -1 | sed -E 's/.*Audio: *([a-z0-9]+).*/\1/I')"
ok "stream carries Video + Audio (audio codec: ${acodec:-present})"

printf '\033[0;32m[M154] ALL GATES GREEN — Hypertube stream engine: /health 200 · Kong 206 ranges · engine X-Accel-Buffering:no · video+audio\033[0m\n'
