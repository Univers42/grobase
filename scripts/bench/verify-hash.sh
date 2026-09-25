#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  verify-hash.sh — cost of ONE api-key verify, per hash scheme (H-4).          #
#                                                                              #
#  API_KEY_VERIFY_CACHE_TTL_MS (TS, 30 s) and the Go verify cache (60 s) bound   #
#  how long a revoked key keeps working. Lowering either was blocked on a        #
#  number: how expensive is the verify they avoid? That depends entirely on the  #
#  stored hash scheme, so both are measured — fast SHA-256 (what new keys get)   #
#  and legacy argon2id (32 MiB, what pre-migration keys still carry), the        #
#  latter also through the ARGON2_MAX_CONCURRENT semaphore that bounds it.       #
#                                                                              #
#  Ponytail: this measures the HASH only, which is the part the 60 s TTL was     #
#  chosen for. A cache miss in the TS middleware also costs an HTTP round trip   #
#  to tenant-control plus its Postgres lookup, which this does NOT measure — so  #
#  treat the fast-scheme figure as a floor on verify cost, not the whole bill.   #
#                                                                              #
#  Usage: bash scripts/bench/verify-hash.sh [BENCHTIME]   (default 2s)          #
#  Writes artifacts/bench/verify-hash/<UTC date>.json and prints the summary.    #
#                                                                              #
# **************************************************************************** #
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCHTIME="${1:-2s}"
OUT_DIR="${ROOT}/artifacts/bench/verify-hash"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT="${OUT_DIR}/${STAMP}.json"
mkdir -p "${OUT_DIR}"

RAW="$(
  docker run --rm -v "${ROOT}/src/control-plane":/src -w /src \
    -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
    golang:1.25-bookworm \
    go test ./internal/tenants -run '^$' -bench 'BenchmarkVerifyKeyHash' \
    -benchtime "${BENCHTIME}" -cpu 4
)" || {
  printf 'verify-hash: the benchmark did not run\n' >&2
  exit 1
}
printf '%s\n' "${RAW}" | grep -q '^ok' || {
  printf 'verify-hash: benchmark output has no ok line\n%s\n' "${RAW}" >&2
  exit 1
}

# rows emits one JSON object per Benchmark line: name, ns/op and, when the
# benchmark reported them, bytes and allocs per op. verify_per_sec is derived
# from ns/op, which for the parallel cases is wall time per verify.
rows() {
  printf '%s\n' "${RAW}" | awk '
    /^Benchmark/ {
      name = $1; sub(/-[0-9]+$/, "", name)
      ns = ""; bytes = "null"; allocs = "null"
      for (i = 2; i <= NF; i++) {
        if ($(i + 1) == "ns/op") ns = $i
        if ($(i + 1) == "B/op") bytes = $i
        if ($(i + 1) == "allocs/op") allocs = $i
      }
      if (ns == "") next
      if (sep) printf ","
      sep = 1
      printf "{\"name\":\"%s\",\"ns_per_op\":%s,\"verify_per_sec\":%.1f,\"bytes_per_op\":%s,\"allocs_per_op\":%s}",
        name, ns, 1e9 / ns, bytes, allocs
    }'
}

printf '{"label":"api-key verify hash cost (H-4)","generated":"%s","git_sha":"%s","benchtime":"%s","env":{"nproc":%s,"mem_total_kb":%s,"kernel":"%s","cpu":"%s"},"note":"hash only; a TS cache miss also costs an HTTP round trip to tenant-control plus its Postgres lookup, not measured here","results":[%s]}\n' \
  "${STAMP}" \
  "$(git -C "${ROOT}" rev-parse --short HEAD)" \
  "${BENCHTIME}" \
  "$(nproc)" \
  "$(awk '/^MemTotal/{print $2}' /proc/meminfo)" \
  "$(uname -r)" \
  "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)" \
  "$(rows)" >"${OUT}"

printf '\n\033[1mverify cost per hash scheme\033[0m  → %s\n' "${OUT#"${ROOT}"/}"
printf '%s\n' "${RAW}" | grep '^Benchmark'
