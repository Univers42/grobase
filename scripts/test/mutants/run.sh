#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#    Mutation testing for grobase's OWN suites                                 #
#                                                                              #
#    Break the platform on purpose, one small change at a time, and see        #
#    whether the suite that covers it goes red. A mutant nobody catches is     #
#    "survived", and a survivor is not a curiosity: it is a suite that would   #
#    stay green while the behaviour it claims to prove is gone.                #
#                                                                              #
# **************************************************************************** #
#
# WHY THIS EXISTS
#   Four green-but-blind tests shipped in this repo and were found by hand on
#   2026-09-21, not by the suites:
#     · phase9's mc_cmd ended in `return 0`, so three storage steps passed
#       against a client image that could not even be pulled;
#     · the offers collection seeded authEmail empty and its signup assertion
#       accepted the resulting 422 as "a clean validation response";
#     · phase2/phase13 defaulted to an origin Kong does not allow, and CI
#       exported the right one so nobody saw it;
#     · waf-test curled a port nothing listens on and ended in `echo`, so the
#       security gate could only ever pass.
#   Every one of those is a mutant that had already survived, in production,
#   for as long as the test existed. This runner makes the question routine.
#
# WHAT A VERDICT MEANS
#   KILLED    the suite failed with the mutant applied — it is load-bearing
#   SURVIVED  the suite passed anyway — it does not test what it claims
#   BASELINE  the suite was already red before the mutant, so nothing can be
#             concluded; fix the suite first. Never counted as a kill.
#   SKIPPED   the mutant could not be applied here (its service is not up)
#   UNKNOWN   the manifest names a mutant this runner does not implement; a
#             typo used to be skipped silently and read as "nothing to report"
#
# USAGE
#   bash scripts/test/mutants/run.sh [mutant-id]
#   GROBASE_DIR=/opt/grobase   where the stack lives (default: repo root)
#
# SAFETY
#   Two things are ever mutated: the environment handed to ONE suite (the
#   platform is untouched), and the running state of ONE container, which is
#   started again after the case AND from the EXIT trap. Nothing here edits a
#   compose file, an image or .env, so an interrupted run cannot leave the
#   platform reconfigured — at worst a container is stopped, and the trap
#   starts it.
set -uo pipefail

cd "${GROBASE_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}" || exit 1

MANIFEST="scripts/test/mutants/mutants.tsv"
REPORT="${REPORT:-artifacts/test/mutants.md}"
ONLY="${1:-}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grobase-mutants.XXXXXX")"
mkdir -p "$(dirname "$REPORT")"

C_G=$'\033[0;32m'
C_R=$'\033[0;31m'
C_Y=$'\033[0;33m'
C_0=$'\033[0m'

# Containers this run has stopped, so both the per-case restore and the trap
# can start them again. It must be a plain variable in THIS shell: an earlier
# draft set it inside a $(...) and the assignment died with the subshell,
# which would have left a service stopped with nothing tracking it.
STOPPED=""
# Services a `recreate` mutant re-created with an override; restored by
# re-creating them from the compose files alone, and waited on until healthy
# so the next mutant's baseline run does not inherit a half-started service.
RECREATED=""

# The compose files as `make up` sees them, every profile active so any one
# service can be addressed by name; --no-deps keeps the rest untouched.
compose_one() {
    docker compose -f docker-compose.yml --profile '*' "$@"
}

wait_healthy() { # <container> [seconds]
    local c="$1" n="${2:-90}" st
    while [ "$n" -gt 0 ]; do
        st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
        case "$st" in healthy | running) return 0 ;; esac
        sleep 2
        n=$((n - 2))
    done
    return 1
}

restore_services() {
    local c
    for c in $STOPPED; do
        docker start "$c" >/dev/null 2>&1 || true
    done
    STOPPED=""
    for c in $RECREATED; do
        compose_one up -d --no-deps --force-recreate "$c" >/dev/null 2>&1 || true
        wait_healthy "mini-baas-$c" || printf 'warning: %s did not report healthy after restore\n' "$c" >&2
    done
    RECREATED=""
}
trap 'restore_services; rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Kong's published port is read back, never assumed: resolve-ports.sh moves it
# when the port is busy, and a suite pointed at the wrong one fails for a
# reason that has nothing to do with the mutant — a kill nobody earned.
kong_base() {
    local p
    p=$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')
    printf 'http://localhost:%s' "${p:-8000}"
}
BASE_URL="$(kong_base)"
ANON_KEY=$(grep -E '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)
SERVICE_ROLE_KEY=$(grep -E '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)

# One suite, run under `env` with whatever overrides the mutant asks for.
# Returns the suite's own status: 0 green, non-zero red.
run_suite() { # <suite> [VAR=VALUE ...]
    local suite="$1" script="" rc
    shift
    case "$suite" in
        phase*) script=$(ls "scripts/test/phase/${suite}-"*.sh "scripts/test/phase/${suite}-"*.py 2>/dev/null | head -1) ;;
        m[0-9]*) script=$(ls "scripts/verify/${suite}-"*.sh 2>/dev/null | head -1) ;;
    esac
    case "$suite" in
        offers) env APIKEY="$ANON_KEY" PUBLIC_APIKEY="$ANON_KEY" BASE_URL="$BASE_URL" \
            FORCE_COLORS=0 "$@" make --no-print-directory test-offers ;;
        waf) env FORCE_COLORS=0 "$@" make --no-print-directory waf-test ;;
        *)
            [ -n "$script" ] || return 127
            case "$script" in
                *.py) env APIKEY="$ANON_KEY" PUBLIC_APIKEY="$ANON_KEY" \
                    SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" BASE_URL="$BASE_URL" \
                    TEST_ORIGIN="https://localhost:3000" FORCE_COLORS=0 "$@" \
                    python3 "$script" ;;
                *) env APIKEY="$ANON_KEY" PUBLIC_APIKEY="$ANON_KEY" \
                    SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" BASE_URL="$BASE_URL" \
                    TEST_ORIGIN="https://localhost:3000" FORCE_COLORS=0 "$@" \
                    bash "$script" ;;
            esac
            ;;
    esac >"$TMP/out" 2>&1
    rc=$?
    return $rc
}

# The environment overrides that express an `env` mutant.
#
# Note offers-no-identity uses a MALFORMED address rather than an empty one:
# run-postman.sh reads ${AUTH_EMAIL:-<generated>}, and in that form an empty
# value is indistinguishable from unset, so the mutant would quietly not be
# applied and the run would report a kill it never made.
mutant_env() { # <id>
    case "$1" in
        engine-restore-dry) printf 'M188_RESTORE_ARGS=--dry-run' ;;
        mc-image-missing) printf 'MC_IMAGE=grobase-mutant/no-such-mc:latest' ;;
        minio-secret-wrong) printf 'MINIO_SECRET_KEY=not-the-secret' ;;
        provenance-blind) printf 'M190_TOOL=scripts/test/mutants/fixtures/provenance-approve-all.sh' ;;
        cors-origin-hostile) printf 'TEST_ORIGIN=http://hostile.invalid:5181' ;;
        nest-probes-live) printf 'M191_EXTRA_COMPOSE=scripts/test/mutants/fixtures/nest-probes-live.yml' ;;
        gateway-unreachable) printf 'BASE_URL=http://127.0.0.1:1' ;;
        offers-no-identity) printf 'AUTH_EMAIL=not-an-email AUTH_PASSWORD=x' ;;
        gateway-probes-blind) printf 'M187_EXTRA_COMPOSE=scripts/test/mutants/fixtures/gateway-probes-blind.yml' ;;
        *) return 2 ;;
    esac
}

# A `recreate` mutant re-creates ONE service with a single environment key
# overridden, through a compose override file, and the platform is restored
# by re-creating it from the real files. It is for the class of claims a
# stop cannot express: "this service is configured correctly", where the
# suite must notice a service that is up, healthy and misconfigured.
# Returns 3 when the service is not running here (a SKIP).
mutant_recreate() { # <id>
    local svc key value
    case "$1" in
        node-heap-uncapped)
            svc=mongo-api
            key=NODE_OPTIONS
            value=""
            ;;
        *) return 2 ;;
    esac
    docker ps --format '{{.Names}}' | grep -qx "mini-baas-$svc" || return 3
    printf 'services:\n  %s:\n    environment:\n      %s: "%s"\n' "$svc" "$key" "$value" >"$TMP/mutant-override.yml"
    compose_one -f "$TMP/mutant-override.yml" up -d --no-deps --force-recreate "$svc" >/dev/null 2>&1 || return 3
    RECREATED="$RECREATED $svc"
    wait_healthy "mini-baas-$svc" || return 3
}

# The service an `svc` mutant takes away. Returns 3 when it is not running,
# which is a SKIP: a mutant that was never applied must not be scored.
mutant_stop() { # <id>
    local c
    case "$1" in
        storage-router-down) c=mini-baas-storage-router ;;
        realtime-down) c=mini-baas-realtime ;;
        mongo-api-down) c=mini-baas-mongo-api ;;
        waf-down) c=mini-baas-waf ;;
        *) return 2 ;;
    esac
    docker ps --format '{{.Names}}' | grep -qx "$c" || return 3
    docker stop "$c" >/dev/null 2>&1 || return 3
    STOPPED="$STOPPED $c"
}

killed=0
survived=0
skipped=0
baseline=0
unknown=0
: >"$TMP/rows"

printf '── grobase mutation run ──\ngateway: %s\n' "$BASE_URL"

while IFS=$'\t' read -r id kind suite means <&3; do
    case "$id" in \#* | '') continue ;; esac
    [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] || continue
    printf '\n=== %s (%s, %s)\n    %s\n' "$id" "$kind" "$suite" "$means"

    # A suite that is already red makes its mutant unfalsifiable: the failure
    # afterwards would be scored as a kill it did not earn.
    if ! run_suite "$suite"; then
        baseline=$((baseline + 1))
        printf '%sBASELINE%s %s — the suite was already failing; the mutant proves nothing\n' "$C_Y" "$C_0" "$id"
        printf '%s\t%s\t%s\tBASELINE\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
        continue
    fi

    overrides=""
    rc=0
    case "$kind" in
        env) overrides=$(mutant_env "$id") || rc=$? ;;
        svc) mutant_stop "$id" || rc=$? ;;
        recreate) mutant_recreate "$id" || rc=$? ;;
        *) rc=2 ;;
    esac
    case "$rc" in
        0) [ "$kind" = env ] || sleep 3 ;;
        3)
            skipped=$((skipped + 1))
            printf '%sSKIPPED%s  %s — the service it needs is not running here\n' "$C_Y" "$C_0" "$id"
            printf '%s\t%s\t%s\tSKIPPED\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
            restore_services
            continue
            ;;
        *)
            # Not silent: a manifest row nobody implemented is a claim with no
            # test behind it, and the run must say so and fail.
            unknown=$((unknown + 1))
            printf '%sUNKNOWN%s  %s — no %s mutant by that id in this runner\n' "$C_R" "$C_0" "$id" "$kind" >&2
            printf '%s\t%s\t%s\tUNKNOWN\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
            continue
            ;;
    esac

    # shellcheck disable=SC2086  # the overrides are a deliberate word list
    if run_suite "$suite" $overrides; then
        survived=$((survived + 1))
        printf '%sSURVIVED%s %s — %s\n' "$C_R" "$C_0" "$id" "$means"
        printf '%s\t%s\t%s\tSURVIVED\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
    else
        killed=$((killed + 1))
        printf '%sKILLED%s   %s\n' "$C_G" "$C_0" "$id"
        printf '%s\t%s\t%s\tKILLED\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
    fi

    restore_services
    sleep 5
done 3<"$MANIFEST"

{
    printf '# Mutation report — grobase suites\n\n'
    printf 'Generated by `scripts/test/mutants/run.sh` on %s.\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf 'killed %s · survived %s · baseline %s · skipped %s · unknown %s\n\n' \
        "$killed" "$survived" "$baseline" "$skipped" "$unknown"
    printf '| mutant | suite | verdict | what its survival would mean |\n'
    printf '| --- | --- | --- | --- |\n'
    while IFS=$'\t' read -r id _kind suite verdict means; do
        printf '| `%s` | %s | %s | %s |\n' "$id" "$suite" "$verdict" "$means"
    done <"$TMP/rows"
    printf '\nA percentage here is a claim about these mutants only: a suite earns its\n'
    printf 'place by having one written against it.\n'
} >"$REPORT"

printf '\n── killed %s · survived %s · baseline %s · skipped %s · unknown %s ──\nreport: %s\n' \
    "$killed" "$survived" "$baseline" "$skipped" "$unknown" "$REPORT"
[ "$survived" = 0 ] && [ "$baseline" = 0 ] && [ "$unknown" = 0 ]
