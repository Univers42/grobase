# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    bench_parallel.sh                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# Run benchmark suites in parallel for faster total wall-clock time.
#
# Usage:
#   ./bench_parallel.sh          # Run all 3 groups in parallel
#   ./bench_parallel.sh micro    # Run only the micro group
#   ./bench_parallel.sh filter   # Run only the filter group
#   ./bench_parallel.sh registry # Run only the registry group
#
# NOTE: Parallel benchmarks share CPU resources, so individual numbers
# may have slightly higher variance than sequential runs. For precise
# A/B comparisons, use the sequential all-in-one:
#   cargo bench -p realtime-engine --bench engine_bench

set -euo pipefail
cd "$(dirname "$0")"

PIDS=()
NAMES=()

run_bench() {
    local name=$1
    echo "▶ Starting bench_${name}..."
    cargo bench -p realtime-engine --bench "bench_${name}" 2>&1 \
        | grep -E "time:|Benchmarking|Performance|change:" &
    PIDS+=($!)
    NAMES+=("$name")
    return 0
}

if [[ $# -eq 0 ]]; then
    # Build all benches first (sequential — avoids cargo lock contention)
    echo "⏳ Building all bench targets..."
    cargo bench -p realtime-engine --no-run 2>&1 | tail -3
    echo ""

    # Run all 3 groups in parallel
    run_bench micro
    run_bench filter
    run_bench registry
else
    cargo bench -p realtime-engine --bench "bench_$1" --no-run 2>&1 | tail -3
    run_bench "$1"
fi

# Wait for all and report
FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        echo "✗ bench_${NAMES[$i]} failed"
        FAILED=1
    else
        echo "✓ bench_${NAMES[$i]} done"
    fi
done

if [[ $FAILED -eq 0 ]]; then
    echo ""
    echo "✓ All benchmarks completed."
else
    echo ""
    echo "✗ Some benchmarks failed."
    exit 1
fi
