#!/usr/bin/env bash
# retry-on-429.sh — run a command; rerun it when it failed on a registry rate limit.
#
# Anonymous public.ecr.aws base-image pulls hit per-runner-IP limits in CI
# ("toomanyrequests: Data limit exceeded", "429 Too Many Requests"). This reruns
# the command up to RETRY_429_ATTEMPTS times (default 3), sleeping
# attempt × RETRY_429_BASE_S seconds (default 60) between attempts. Any other
# failure returns at once with the command's own status. The combined output is
# tee'd to RETRY_429_LOG (default: a temp file), so a later step can explain it.
#
# Ponytail: "rate limited" is a grep of the output. A command that prints
# "toomanyrequests" for another reason is retried (minutes lost, never a false
# green); a registry that words its limit differently is not retried.
#
# Usage: retry-on-429.sh <command> [args...]
# Exit:  the command's last status; 2 on misuse.
set -uo pipefail

# rate_limited reports whether log file $1 shows a registry rate limit.
rate_limited() {
  grep -qE '429 Too Many Requests|toomanyrequests' "$1"
}

# main runs "$@" until it succeeds, fails for another reason, or runs out of attempts.
main() {
  local attempts="${RETRY_429_ATTEMPTS:-3}" base="${RETRY_429_BASE_S:-60}"
  local log="${RETRY_429_LOG:-$(mktemp)}" attempt rc
  [ "$#" -gt 0 ] || {
    echo "usage: retry-on-429.sh <command> [args...]" >&2
    return 2
  }
  for ((attempt = 1; ; attempt++)); do
    "$@" 2>&1 | tee "${log}"
    rc="${PIPESTATUS[0]}"
    [ "${rc}" -eq 0 ] && return 0
    { rate_limited "${log}" && [ "${attempt}" -lt "${attempts}" ]; } || return "${rc}"
    echo "::warning title=registry rate limit::attempt ${attempt} of '$1' hit a registry limit; retrying in $((attempt * base))s"
    sleep $((attempt * base))
  done
}

main "$@"
