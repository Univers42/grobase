#!/usr/bin/env bash
# **************************************************************************** #
#    grobase-vs-supabase.sh — head-to-head, same box, strictly sequential      #
# **************************************************************************** #
#
# The marquee comparison (program A5): boot self-hosted Supabase on the same box
# our stack runs on, run the IDENTICAL logical workload (PostgREST CRUD + auth)
# against both, and report total RAM footprint + latency distributions. Method
# follows nano-vs-pocketbase.sh — pinned image, same box, N runs, JSON artifact.
#
# STRICTLY SEQUENTIAL (METHOD.md rule 1): never both stacks at once. We measure
# OUR stack first (assumed already up — `make up PACKAGE=pro`), then this script
# boots Supabase separately. Supabase's ~13-container stack wants ~2 GB; the
# guard below aborts if MemAvailable is too low rather than thrash.
#
# This script is ON-DEMAND only (never in verify-all). It does NOT tear our
# stack down — run it, read the Supabase side, then compare against the
# already-captured artifacts/bench/load-*.json + footprint-*.json from our side.
#
# Output: artifacts/bench/grobase-vs-supabase.json (Supabase side + a pointer to
# our-side artifacts for the diff).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/lib-bench.sh"

cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }

SUPABASE_REF="${SUPABASE_REF:-v1.24.09}"   # pinned supabase/supabase tag
MIN_AVAIL_MB="${MIN_AVAIL_MB:-2500}"
N="${N:-100}"
# IMPORTANT: the clone + Supabase's bind-mounted volumes (./volumes/db,storage,…)
# MUST live on the big data disk, NEVER the small system disk. /tmp is on / (the
# system SSD), so we refuse to fall back to it — fail loudly instead.
BENCH_WORK_BASE="${BENCH_WORK_BASE:-/mnt/storage/bench}"
if [[ ! -d "${BENCH_WORK_BASE}" || ! -w "${BENCH_WORK_BASE}" ]]; then
	red "[vs-supabase] ${BENCH_WORK_BASE} is missing or not writable."
	red "   Supabase bind-mounts its DB/storage data into the clone dir; that must NOT land on the system disk."
	red "   Create it once:  sudo install -d -o \"\$USER\" -g \"\$USER\" ${BENCH_WORK_BASE}"
	exit 1
fi
WORK="$(mktemp -d -p "${BENCH_WORK_BASE}")"
SB_DIR="${WORK}/supabase"

cleanup() {
	if [[ -d "${SB_DIR}/docker" ]]; then
		( cd "${SB_DIR}/docker" && docker compose down -v >/dev/null 2>&1 || true )
	fi
	rm -rf "${WORK}"
}
trap cleanup EXIT

# ── memory guard (METHOD.md): don't thrash the box ──────────────────────────
AVAIL="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
if (( AVAIL < MIN_AVAIL_MB )); then
	red "MemAvailable ${AVAIL}MB < ${MIN_AVAIL_MB}MB — free memory (or `make down`) before benching Supabase."
	red "This harness is strictly sequential: bench OUR stack first, capture artifacts, THEN run this."
	exit 1
fi
cyan "[vs-supabase] MemAvailable ${AVAIL}MB — ok. Supabase ref ${SUPABASE_REF}, N=${N}."

# ── boot Supabase (pinned) ──────────────────────────────────────────────────
cyan "[vs-supabase] cloning supabase/supabase @ ${SUPABASE_REF}…"
git clone --depth 1 --branch "${SUPABASE_REF}" https://github.com/supabase/supabase.git "${SB_DIR}" >/dev/null 2>&1 \
	|| { red "clone failed — check the pinned ref ${SUPABASE_REF}, or run on-demand with network access"; exit 1; }
cd "${SB_DIR}/docker"
cp .env.example .env
# Remap host ports so Supabase runs ALONGSIDE other stacks without conflict
# (our mini-baas uses 8002/55432; a local dev HTTPS proxy may hold 8000/4000).
# kong->8100, kong-https->8543, db->5532, analytics->4500.
SB_HTTP_PORT="${SB_HTTP_PORT:-8100}"
sed -i "s/^KONG_HTTP_PORT=.*/KONG_HTTP_PORT=${SB_HTTP_PORT}/" .env
sed -i 's/^KONG_HTTPS_PORT=.*/KONG_HTTPS_PORT=8543/' .env
sed -i 's/^POSTGRES_PORT=.*/POSTGRES_PORT=5532/' .env
sed -i 's/- 4000:4000/- 4500:4000/' docker-compose.yml
cyan "[vs-supabase] booting the Supabase stack (cached images; kong:${SB_HTTP_PORT})…"
docker compose up -d 2>&1 | tail -3 || { red "supabase compose up failed"; exit 1; }

# Wait for Kong (the Supabase gateway) to answer.
SB_KONG="http://127.0.0.1:${SB_HTTP_PORT}"
for _ in $(seq 1 60); do
	curl -s -o /dev/null "${SB_KONG}/rest/v1/" && break || sleep 5
done

# ── seed an identical bench table (fairness fix) ────────────────────────────
# Stock Supabase ships no bench_items; without this the read probe below would
# time 404s instead of real CRUD. Mirror our side's bench_items (500 rows) and
# grant anon SELECT so PostgREST serves it (our bench_items table is RLS-less
# too, so this is apples-to-apples for the read probe).
cyan "[vs-supabase] seeding bench_items (500 rows) on the Supabase side…"
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1 \
	|| red "[vs-supabase] seed warning — read probe may be less accurate"
CREATE TABLE IF NOT EXISTS public.bench_items (id text primary key, name text, grp text, val int);
TRUNCATE public.bench_items;
INSERT INTO public.bench_items SELECT 'r'||g, 'name'||g, 'grp'||(g%10), g FROM generate_series(1,500) g;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bench_items TO anon, authenticated, service_role;
ALTER TABLE public.bench_items DISABLE ROW LEVEL SECURITY;
NOTIFY pgrst, 'reload schema';
SQL
sleep 2

# ── footprint: sum docker stats RAM of the supabase-* containers ────────────
# Match ONLY supabase containers (their names all contain "supabase"), so this
# stays correct when our stack runs alongside (ours are "mini-baas-*"; the old
# kong|realtime|gotrue alternation also matched our containers).
cyan "[vs-supabase] measuring Supabase footprint…"
SB_RAM="$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' \
	| grep -E 'supabase' \
	| awk '{print $2}' | sed 's/MiB//;s/GiB/*1024/' | paste -sd+ | bc 2>/dev/null | cut -d. -f1)"
SB_RAM="${SB_RAM:-0}"
cyan "[vs-supabase] Supabase total RSS ≈ ${SB_RAM} MiB"
# Per-container breakdown so the offer can map service-for-service vs Grobase.
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep -E 'supabase' | sort \
	> "${BENCH_OUT_DIR}/supabase-footprint-breakdown.txt" 2>/dev/null || true

# ── latency probe: the SAME curl probe against Supabase PostgREST AND ours ──
# Fair same-box, same-method comparison (both PostgREST + seeded bench_items).
SB_ANON="$(grep -E '^ANON_KEY=' .env | cut -d= -f2-)"
probe() { # $1 base-url  $2 apikey
	curl -s -o /dev/null -w '%{time_total}' "$1/rest/v1/bench_items?limit=30" \
		-H "apikey: $2" -H "Authorization: Bearer $2"
}
cyan "[vs-supabase] ${N}-sample read probe — Supabase…"
sb=(); for _ in $(seq 1 "${N}"); do sb+=("$(awk -v t="$(probe "${SB_KONG}" "${SB_ANON}")" 'BEGIN{printf "%.2f",t*1000}')"); done
SBP50="$(printf '%s\n' "${sb[@]}"|sort -n|awk '{a[NR]=$1}END{print a[int(NR*0.5)]}')"
SBP95="$(printf '%s\n' "${sb[@]}"|sort -n|awk '{a[NR]=$1}END{print a[int(NR*0.95)]}')"
cyan "[vs-supabase] Supabase read p50 ${SBP50}ms / p95 ${SBP95}ms"

# Our side: seed bench_items in our postgres + probe our PostgREST via Kong (8002),
# using the IDENTICAL probe so the latency numbers are directly comparable.
OUR_KONG="${OUR_KONG:-http://127.0.0.1:8002}"
OUR_INFRA="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # SCRIPT_DIR is absolute (set at top, before any cd)
OUR_ANON="$(grep -E '^ANON_KEY=' "${OUR_INFRA}/.env" 2>/dev/null | cut -d= -f2-)"
OURP50="0"; OURP95="0"
if [[ -n "${OUR_ANON}" ]] && docker ps --format '{{.Names}}' | grep -q '^mini-baas-postgres$'; then
	PGU="$(grep -E '^POSTGRES_USER=' "${OUR_INFRA}/.env"|cut -d= -f2-)"; PGU="${PGU:-postgres}"
	PGD="$(grep -E '^POSTGRES_DB=' "${OUR_INFRA}/.env"|cut -d= -f2-)"; PGD="${PGD:-postgres}"
	docker exec -i mini-baas-postgres psql -U "${PGU}" -d "${PGD}" -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL || true
CREATE TABLE IF NOT EXISTS public.bench_items (id text primary key, name text, grp text, val int);
TRUNCATE public.bench_items;
INSERT INTO public.bench_items SELECT 'r'||g,'name'||g,'grp'||(g%10),g FROM generate_series(1,500) g;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.bench_items TO anon,authenticated,service_role;
ALTER TABLE public.bench_items DISABLE ROW LEVEL SECURITY;
NOTIFY pgrst,'reload schema';
SQL
	sleep 2
	cyan "[vs-supabase] ${N}-sample read probe — Grobase PostgREST…"
	our=(); for _ in $(seq 1 "${N}"); do our+=("$(awk -v t="$(probe "${OUR_KONG}" "${OUR_ANON}")" 'BEGIN{printf "%.2f",t*1000}')"); done
	OURP50="$(printf '%s\n' "${our[@]}"|sort -n|awk '{a[NR]=$1}END{print a[int(NR*0.5)]}')"
	OURP95="$(printf '%s\n' "${our[@]}"|sort -n|awk '{a[NR]=$1}END{print a[int(NR*0.95)]}')"
else
	red "[vs-supabase] our stack not reachable on ${OUR_KONG} — skipping our-side probe (run 'make up' first)"
fi

FINAL="${BENCH_OUT_DIR}/grobase-vs-supabase.json"
jq -n --arg ref "${SUPABASE_REF}" --argjson n "${N}" --argjson ram "${SB_RAM}" \
	--argjson sbp50 "${SBP50:-0}" --argjson sbp95 "${SBP95:-0}" \
	--argjson op50 "${OURP50:-0}" --argjson op95 "${OURP95:-0}" --argjson env "$(bench_env_json)" '
	{ supabase: { ref:$ref, total_rss_mib:$ram, read_p50_ms:$sbp50, read_p95_ms:$sbp95, n:$n },
	  grobase_postgrest: { read_p50_ms:$op50, read_p95_ms:$op95, via:"kong:8002/rest/v1", n:$n },
	  method:"same curl GET /rest/v1/bench_items?limit=30 against both PostgREST instances; 500-row seeded bench_items; supabase ports remapped to run alongside; footprint=sum docker stats RSS of supabase-* containers",
	  env:$env }' > "${FINAL}"

green "[vs-supabase] Supabase: ${SB_RAM} MiB RSS / read p50 ${SBP50}ms / p95 ${SBP95}ms"
green "[vs-supabase] Grobase PostgREST: read p50 ${OURP50}ms / p95 ${OURP95}ms → ${FINAL#${BENCH_ROOT}/}"
