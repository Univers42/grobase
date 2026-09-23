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

restore_services() {
    local c
    for c in $STOPPED; do
        docker start "$c" >/dev/null 2>&1 || true
    done
    STOPPED=""
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
        cors-origin-hostile) printf 'TEST_ORIGIN=http://hostile.invalid:5181' ;;
        gateway-unreachable) printf 'BASE_URL=http://127.0.0.1:1' ;;
        offers-no-identity) printf 'AUTH_EMAIL=not-an-email AUTH_PASSWORD=x' ;;
        *) return 2 ;;
    esac
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
    if [ "$kind" = env ]; then
        overrides=$(mutant_env "$id") || {
            printf 'unknown mutant: %s\n' "$id" >&2
            continue
        }
    else
        mutant_stop "$id"
        case $? in
            3)
                skipped=$((skipped + 1))
                printf '%sSKIPPED%s  %s — the service it stops is not running here\n' "$C_Y" "$C_0" "$id"
                printf '%s\t%s\t%s\tSKIPPED\t%s\n' "$id" "$kind" "$suite" "$means" >>"$TMP/rows"
                continue
                ;;
            2)
                printf 'unknown mutant: %s\n' "$id" >&2
                continue
                ;;
        esac
        sleep 3
    fi

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
    printf 'killed %s · survived %s · baseline %s · skipped %s\n\n' \
        "$killed" "$survived" "$baseline" "$skipped"
    printf '| mutant | suite | verdict | what its survival would mean |\n'
    printf '| --- | --- | --- | --- |\n'
    while IFS=$'\t' read -r id _kind suite verdict means; do
        printf '| `%s` | %s | %s | %s |\n' "$id" "$suite" "$verdict" "$means"
    done <"$TMP/rows"
    printf '\nA percentage here is a claim about these mutants only: a suite earns its\n'
    printf 'place by having one written against it.\n'
} >"$REPORT"

printf '\n── killed %s · survived %s · baseline %s · skipped %s ──\nreport: %s\n' \
    "$killed" "$survived" "$baseline" "$skipped" "$REPORT"
[ "$survived" = 0 ] && [ "$baseline" = 0 ]
