#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    lib-bench.sh                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Shared benchmark plumbing (see METHOD.md — the rules every number follows).
# Source this from bench scripts. Provides:
#   bench_env_json            — the env block every artifact embeds
#   bench_k6 <script> <out> [k6 -e args…]
#                             — run the PINNED k6 image on the host network
#   bench_budget <jq-path>    — read a bar from budgets.json
#   bench_median3_by <jq-num-path> f1 f2 f3
#                             — pick the median artifact of three runs
#   bench_port <container> <port/proto>
#                             — published host port (resolve-ports aware)
#   bench_container_env <container> <VAR>

set -euo pipefail

BENCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${BENCH_LIB_DIR}/../.." && pwd)"
BENCH_OUT_DIR="${BENCH_ROOT}/artifacts/bench"
BUDGETS_JSON="${BENCH_LIB_DIR}/budgets.json"

# Pinned load generator (METHOD.md rule 2). Override only for an upgrade PR.
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.57.0}"

mkdir -p "${BENCH_OUT_DIR}"

bench_port() { # $1 container, $2 container-port/proto
	docker port "$1" "$2" 2>/dev/null | head -1 | sed 's/.*://'
}

bench_container_env() { # $1 container, $2 var
	docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
		| grep "^$2=" | head -1 | cut -d= -f2-
}

# The env block (METHOD.md rule 1): box + code identity for reproducibility.
bench_env_json() {
	local sha
	sha="$(git -C "${BENCH_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	printf '{"nproc":%s,"mem_total_mib":%s,"kernel":"%s","git_sha":"%s","generated":"%s"}' \
		"$(nproc)" \
		"$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)" \
		"$(uname -r)" \
		"${sha}" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

bench_budget() { # $1 jq path, e.g. '.load.pro.p95_ms'
	jq -r "$1" "${BUDGETS_JSON}"
}

# Run k6 from the pinned image on the host network (the stack publishes on
# 127.0.0.1). The k6 script writes its own compact summary JSON via
# handleSummary to /out/<basename of $2>.
bench_k6() { # $1 script (path under scripts/bench/k6/), $2 out json (under artifacts/bench/), $3… extra -e args
	local script="$1" out="$2"; shift 2
	# -u host uid: the k6 image's default user can't write the bind-mounted
	# artifacts dir (and root would litter it with root-owned files).
	docker run --rm --network host -u "$(id -u):$(id -g)" \
		-v "${BENCH_LIB_DIR}/k6:/scripts:ro" \
		-v "${BENCH_OUT_DIR}:/out" \
		-e "K6_OUT_FILE=/out/$(basename "${out}")" \
		"${K6_IMAGE}" run --quiet "/scripts/$(basename "${script}")" "$@"
}

# Median-of-three by a numeric jq path (METHOD.md rule 4): echoes the filename
# of the median artifact.
bench_median3_by() { # $1 jq path, $2 $3 $4 filenames
	local path="$1" a="$2" b="$3" c="$4"
	{
		printf '%s %s\n' "$(jq -r "${path}" "${a}")" "${a}"
		printf '%s %s\n' "$(jq -r "${path}" "${b}")" "${b}"
		printf '%s %s\n' "$(jq -r "${path}" "${c}")" "${c}"
	} | sort -n | sed -n '2p' | cut -d' ' -f2-
}
