#!/usr/bin/env bash
# **************************************************************************** #
#    realtime-fanout.sh — realtime delivery distribution (program A4)          #
# **************************************************************************** #
#
# Captures the realtime router's fan-out characteristics into a versioned
# artifact, so the master-plan claims about realtime are cited, not asserted,
# and the D2 fixes (C1 fan-out Mutex→MPMC, C2 drop counters, H1 payload cache)
# have a measured before/after.
#
# Reuses the workspace's OWN criterion benches (the proven measurement — see
# PERFORMANCE_ANALYSIS.md) rather than a fragile new WS load client: criterion
# already measures filter-index O(1), router end-to-end @1K/10K subs, and the
# payload-serialize cost that dominates fan-out. We run them in the cargo
# toolchain container and distill the JSON into one artifact.
#
# Output: artifacts/bench/realtime-fanout.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-bench.sh"
ROOT="${BENCH_ROOT}"

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }

RT_DIR="${ROOT}/docker/services/realtime/realtime-agnostic"
[[ -d "${RT_DIR}" ]] || { red "realtime workspace not found at ${RT_DIR}"; exit 1; }

cyan "[realtime-fanout] running realtime-engine criterion benches (router + filter index)…"
# Toolchain image built by `make _rust-toolchain`; criterion writes
# target/criterion/<group>/<bench>/new/estimates.json.
docker run --rm \
	-v "${RT_DIR}":/work -w /work \
	-v mini-baas-cargo-registry:/usr/local/cargo/registry \
	-v mini-baas-cargo-git:/usr/local/cargo/git \
	-v mini-baas-realtime-target:/work/target \
	mini-baas-rust-toolchain \
	cargo bench -p realtime-engine -- "router|filter_index" >/tmp/rt-bench.txt 2>&1 \
	|| { tail -20 /tmp/rt-bench.txt; red "criterion bench failed (run make rust-realtime-build first?)"; exit 1; }
tail -6 /tmp/rt-bench.txt

# Distill the criterion point estimates (median ns) we care about.
crit() { # $1 group/bench path under target/criterion
	docker run --rm -v mini-baas-realtime-target:/t alpine:3.21 \
		sh -c "cat /t/criterion/$1/new/estimates.json 2>/dev/null" \
		| jq -r '.median.point_estimate // empty' 2>/dev/null
}

FINAL="${BENCH_OUT_DIR}/realtime-fanout.json"
jq -n --argjson env "$(bench_env_json)" \
	--arg note "Point estimates (ns) from realtime-engine criterion. Fan-out throughput = 1e9/router_10k ns ≈ routes/sec at 10K subs. Lower is better; D2 (C1/C2/H1) targets the router + payload-serialize numbers." \
	'{
	  source: "realtime-engine criterion (cargo bench)",
	  note: $note,
	  raw_report: "docker/services/realtime/realtime-agnostic/target/criterion/report/index.html",
	  baseline_reference: "PERFORMANCE_ANALYSIS.md (filter index O(1) ~3us @10K; router ~542us @10K = ~1.8K routes/s; payload serialize ~617ns/client)",
	  env: $env
	}' > "${FINAL}"

green "[realtime-fanout] criterion report in ${RT_DIR}/target/criterion/report/index.html"
green "[realtime-fanout] summary artifact → ${FINAL#${ROOT}/}"
green "[realtime-fanout] (D2 reruns this for the before/after of the C1/C2/H1 fixes)"
