#!/bin/sh
# Build-speed benchmark. Times one compose build in a given MODE and appends
# the measurement to artifacts/bench/build/results.tsv (mode, seconds, edition,
# git SHA, UTC date). Run from the repo root via `make bench-build MODE=…`.
#   MODE=noop       full-edition rebuild with nothing changed (cache-hit floor)
#   MODE=incr-rust  one-line change in data-plane-server → rebuild that image
#   MODE=incr-ts    one-line change in query-router      → rebuild that image
#   MODE=cold       wipe the BuildKit builder cache first (needs BENCH_COLD=1)
set -eu

MODE="${MODE:-noop}"
EDITION="${EDITION:-devlean}"
OUT_DIR="artifacts/bench/build"
RUST_PROBE="src/data-plane-router/crates/data-plane-server/src/main.rs"
TS_PROBE="src/apps/query-router/src/main.ts"
PROBE=""

restore_probe() {
	[ -z "$PROBE" ] || git checkout -- "$PROBE" 2>/dev/null || true
}

time_build() {
	t0=$(date +%s)
	make -s "$1" EDITION="$EDITION" >/dev/null
	echo $(($(date +%s) - t0))
}

record() {
	mkdir -p "$OUT_DIR"
	printf '%s\t%ss\tedition=%s\t%s\t%s\n' "$MODE" "$1" "$EDITION" \
		"$(git rev-parse --short HEAD)" "$(date -u +%FT%TZ)" \
		| tee -a "$OUT_DIR/results.tsv"
}

run_incr() {
	if [ -n "$(git status --porcelain -- "$PROBE")" ]; then
		echo "refusing: $PROBE has local changes" >&2
		exit 1
	fi
	trap restore_probe EXIT
	printf '// bench: incremental probe %s\n' "$(date +%s)" >>"$PROBE"
	record "$(time_build "build-svc-$1")"
}

main() {
	case "$MODE" in
	noop)
		record "$(time_build build)" ;;
	incr-rust)
		PROBE="$RUST_PROBE"
		run_incr data-plane-router-rust ;;
	incr-ts)
		PROBE="$TS_PROBE"
		run_incr query-router ;;
	cold)
		if [ "${BENCH_COLD:-}" != 1 ]; then
			echo "cold wipes the WHOLE default builder cache — re-run with BENCH_COLD=1" >&2
			exit 1
		fi
		docker builder prune -af >/dev/null
		record "$(time_build build)" ;;
	*)
		echo "unknown MODE=$MODE (noop|incr-rust|incr-ts|cold)" >&2
		exit 1 ;;
	esac
}

main
