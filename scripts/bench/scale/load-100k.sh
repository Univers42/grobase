#!/usr/bin/env bash
# **************************************************************************** #
#   load-100k.sh — 100K-tenant LOAD SLO harness (Track C / C6)                 #
# **************************************************************************** #
#
# Drives the full 100K-tenant load run end-to-end and writes a single artifact
# under artifacts/scale/. It is the ON-DEMAND validation for the 100K headline —
# NOT a CI gate: a ~50-min Argon2id-bound seed + a multi-minute load is far too
# slow for CI, and a trustworthy p99-under-load needs a QUIET/ISOLATED node (the
# load generator off-box, or a dedicated cloud instance). The 24,887-live-tenant
# at-rest measurement already on record (artifacts/scale/footprint-live-24887.json,
# wiki/scale-slo.md §3) is the in-hand evidence; this harness is how the FULL
# 100K *load* SLO gets measured when a quiet node is available.
#
# STAGES
#   0. preflight    — confirm a quiet node + the scale-tuned stack is up
#   1. seed         — provision SCALE tenants (resumable; the Argon2id wall)
#   2. footprint    — capture server-side density facts (RSS, pools, 0×5xx)
#   3. load         — drive multitenant k6 load → latency distribution
#   4. artifact     — fold both into artifacts/scale/load-100k-<SCALE>.json
#
# USAGE (on a quiet/isolated node, stack already scale-tuned):
#   docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d   # PG max_connections=2000, SHARE_POOLS=1
#   SCALE=100000 RATE=20 DURATION=60s DIST=zipf PREFIX=scale-100k \
#       bash scripts/scale/load-100k.sh
#
# Env:
#   SCALE       tenant count            (default 100000)
#   RATE        aggregate rps for load  (default 20 — a quiet node sustains more)
#   DURATION    load window             (default 60s)
#   DIST        uniform|zipf            (default zipf — realistic hot-tenant shape)
#   ISOLATION   mount isolation         (default shared_rls — the single-pool lever)
#   CONCURRENCY seed parallelism        (default 16 — Argon2id is CPU-bound)
#   PREFIX      slug prefix             (default scale-100k)
#   SKIP_SEED=1 reuse an already-seeded fleet (artifacts/scale/tenants-<SCALE>.jsonl)
#   DRY_RUN=1   print the plan + validate inputs, run nothing live
#
# This harness only ORCHESTRATES existing, gate-proven tools (make scale-seed,
# scripts/bench/footprint.sh, scripts/bench/multitenant.sh). It changes no
# defaults and runs nothing unless invoked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" # repo root (script now at scripts/bench/scale/)
ART_DIR="${INFRA_ROOT}/artifacts/scale"
BENCH_OUT="${INFRA_ROOT}/artifacts/bench"

SCALE="${SCALE:-100000}"
RATE="${RATE:-20}"
DURATION="${DURATION:-60s}"
DIST="${DIST:-zipf}"
ISOLATION="${ISOLATION:-shared_rls}"
CONCURRENCY="${CONCURRENCY:-16}"
PREFIX="${PREFIX:-scale-100k}"
SKIP_SEED="${SKIP_SEED:-0}"
DRY_RUN="${DRY_RUN:-0}"

TENANTS_JSONL="${ART_DIR}/tenants-${SCALE}.jsonl"
LOAD_ARTIFACT="${ART_DIR}/load-100k-${SCALE}.json"
MT_ARTIFACT="${BENCH_OUT}/multitenant-${SCALE}.json"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
die() {
  red "$*"
  exit 1
}

mkdir -p "${ART_DIR}"

# ── Stage 0: preflight ────────────────────────────────────────────────────
preflight() {
  cyan "[0/4] preflight — SCALE=${SCALE} RATE=${RATE} DUR=${DURATION} DIST=${DIST} ISO=${ISOLATION}"
  command -v docker >/dev/null || die "docker not found"
  docker inspect mini-baas-tenant-control >/dev/null 2>&1 ||
    die "stack not up — start the scale-tuned stack first (see USAGE header)"
  docker inspect mini-baas-data-plane-router-rust >/dev/null 2>&1 ||
    die "data plane not up — this run needs the rust-data-plane profile"

  # Honest QUIET-NODE warning: a clean 100K *load* p99 is not credible on a busy
  # box (the 10K run was k6/Chrome-CPU-starved — wiki/scale-slo.md §5). Warn loud.
  local loadavg cores
  loadavg="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
  cores="$(nproc 2>/dev/null || echo 1)"
  yellow "[0/4] node load1=${loadavg} cores=${cores} — a trustworthy p99 needs a QUIET node"
  awk -v l="${loadavg}" -v c="${cores}" 'BEGIN{ if (l+0 > c+0) exit 1 }' ||
    yellow "[0/4] WARNING: load1 > cores — latency will reflect the load gen, not the stack"

  # Confirm the SHARE_POOLS lever (the single-pool result) is on — else 100K
  # tenants would spawn 100K pools and the run measures the wrong thing.
  local sp
  sp="$(docker inspect mini-baas-data-plane-router-rust \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    sed -n 's/^DATA_PLANE_SHARE_POOLS=//p' | head -1)"
  [ "${sp}" = "1" ] || yellow "[0/4] WARNING: DATA_PLANE_SHARE_POOLS!=1 (got '${sp}') — apply docker-compose.scale.yml"
}

# ── Stage 1: seed (the Argon2id wall) ─────────────────────────────────────
seed() {
  if [ "${SKIP_SEED}" = "1" ]; then
    [ -f "${TENANTS_JSONL}" ] || die "SKIP_SEED=1 but ${TENANTS_JSONL} missing"
    green "[1/4] seed SKIPPED — reusing $(wc -l <"${TENANTS_JSONL}") seeded tenants"
    return
  fi
  cyan "[1/4] seed ${SCALE} tenants (resumable; ~50 min @ ${SCALE}, Argon2id-bound)"
  # Resumable: re-running continues where it stopped (skips slugs already in
  # the JSONL). The batch-provision remedy (POST /v1/provisions, ~5 min) is the
  # PROJECTED acceleration in wiki/scale-slo.md §4 — not shipped in v1.x, so
  # this harness uses the proven per-tenant resumable path.
  make -C "${INFRA_ROOT}" scale-seed \
    SCALE="${SCALE}" ISOLATION="${ISOLATION}" \
    CONCURRENCY="${CONCURRENCY}" PREFIX="${PREFIX}" RESUME=1
  [ -f "${TENANTS_JSONL}" ] || die "seed produced no ${TENANTS_JSONL}"
  green "[1/4] seeded $(wc -l <"${TENANTS_JSONL}") tenants"
}

# ── Stage 2: footprint (server-side density facts) ────────────────────────
footprint() {
  cyan "[2/4] footprint — RSS / pools_open / lifetime (the at-density density facts)"
  local fp="${ART_DIR}/footprint-load-${SCALE}.json"
  if [ -x "${INFRA_ROOT}/scripts/bench/footprint.sh" ]; then
    bash "${INFRA_ROOT}/scripts/bench/footprint.sh" >"${fp}" 2>/dev/null ||
      yellow "[2/4] footprint.sh non-zero — capturing raw stats inline"
  fi
  # Always capture the canonical density signals directly (cheap, read-only).
  local dp_port pools rss
  dp_port="$(docker port mini-baas-data-plane-router-rust 4011/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  pools="$(curl -s "http://127.0.0.1:${dp_port:-4011}/metrics" 2>/dev/null |
    sed -n 's/^baas_data_plane_pools_open[ {].* //p' | head -1)"
  rss="$(docker stats --no-stream --format '{{.MemUsage}}' mini-baas-data-plane-router-rust 2>/dev/null | awk '{print $1}')"
  green "[2/4] data-plane RSS=${rss:-?} pools_open=${pools:-?}"
  FP_POOLS="${pools:-unknown}"
  FP_RSS="${rss:-unknown}"
}

# ── Stage 3: load (latency distribution) ──────────────────────────────────
load() {
  cyan "[3/4] load — ${RATE} rps × ${DURATION} (dist=${DIST}) across the fleet"
  SCALE="${SCALE}" RATE="${RATE}" DURATION="${DURATION}" DIST="${DIST}" \
    bash "${INFRA_ROOT}/scripts/bench/multitenant.sh"
  [ -f "${MT_ARTIFACT}" ] || die "load produced no ${MT_ARTIFACT}"
  green "[3/4] load artifact: ${MT_ARTIFACT#"${INFRA_ROOT}"/}"
}

# ── Stage 4: fold into one artifact ───────────────────────────────────────
artifact() {
  cyan "[4/4] artifact — folding density + load into ${LOAD_ARTIFACT#"${INFRA_ROOT}"/}"
  local sha
  sha="$(git -C "${INFRA_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local seeded
  seeded="$([ -f "${TENANTS_JSONL}" ] && wc -l <"${TENANTS_JSONL}" | tr -d ' ' || echo 0)"
  # Merge the multitenant load JSON with the density facts captured in stage 2.
  if command -v jq >/dev/null && [ -f "${MT_ARTIFACT}" ]; then
    jq -n \
      --arg sha "${sha}" --arg ts "$(date -u +%FT%TZ)" \
      --argjson scale "${SCALE}" --argjson seeded "${seeded}" \
      --arg rate "${RATE}" --arg dur "${DURATION}" --arg dist "${DIST}" \
      --arg rss "${FP_RSS:-unknown}" --arg pools "${FP_POOLS:-unknown}" \
      --slurpfile load "${MT_ARTIFACT}" \
      '{kind:"load-100k", git_sha:$sha, generated_at:$ts,
			  scale:$scale, tenants_seeded:$seeded,
			  load:{rate:$rate, duration:$dur, dist:$dist, result:$load[0]},
			  density:{data_plane_rss:$rss, pools_open:$pools},
			  note:"on-demand, quiet-node run — NOT a CI gate (wiki/scale-slo.md §5)"}' \
      >"${LOAD_ARTIFACT}"
  else
    printf '{"kind":"load-100k","scale":%s,"tenants_seeded":%s,"note":"jq or load artifact missing"}\n' \
      "${SCALE}" "${seeded}" >"${LOAD_ARTIFACT}"
  fi
  green "[4/4] DONE → ${LOAD_ARTIFACT#"${INFRA_ROOT}"/}"
  command -v jq >/dev/null && jq -r \
    '"  scale=\(.scale) seeded=\(.tenants_seeded) pools=\(.density.pools_open) rss=\(.density.data_plane_rss) p99=\(.load.result.http.p99 // "?")ms 5xx=\(.load.result.server_errors // "?")"' \
    "${LOAD_ARTIFACT}" 2>/dev/null || true
}

main() {
  if [ "${DRY_RUN}" = "1" ]; then
    cyan "[DRY_RUN] would run: preflight → seed(${SCALE}) → footprint → load(${RATE}/${DURATION}) → artifact"
    cyan "[DRY_RUN] artifact target: ${LOAD_ARTIFACT}"
    exit 0
  fi
  preflight
  seed
  footprint
  load
  artifact
}

main "$@"
