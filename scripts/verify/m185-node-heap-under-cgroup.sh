#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m185-node-heap-under-cgroup.sh — every Node service's V8 heap ceiling must  #
#  sit below its container memory limit, MEASURED in the running container     #
#                                                                              #
#  V8 sizes its old space from the HOST's RAM, not from the cgroup the         #
#  container runs in. Measured 2026-09-23 on a 7.5 GB guest: four services     #
#  with mem_limit 128m reported heap_size_limit 259 MB. Such a service can     #
#  grow past its own ceiling; the OOM killer fires before V8 runs a            #
#  last-ditch GC, so the container dies with exit 137 and no in-process log    #
#  line, and on a 16 GB CI runner the gap is wider. NODE_OPTIONS               #
#  --max-old-space-size (75% of mem_limit) is the fix, per service.            #
#                                                                              #
#  This gate does NOT grep the compose files: a static check drifts the        #
#  moment someone edits one number. It execs into every running Node          #
#  container of the project, reads require('v8').getHeapStatistics()          #
#  .heap_size_limit, and asserts it is below HostConfig.Memory. A service       #
#  without a limit is reported and skipped: nothing to be under.              #
#                                                                              #
#  Mutant: scripts/test/mutants/mutants.tsv `node-heap-uncapped` recreates    #
#  one service with NODE_OPTIONS cleared; this gate must go red.              #
#                                                                              #
#  Read-only against the live stack. M185_PROJECT overrides the compose        #
#  project label (default mini-baas).                                         #
# **************************************************************************** #
set -euo pipefail
PROJECT="${M185_PROJECT:-mini-baas}"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M185] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m  · %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M185] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}

step "0/2 preconditions"
command -v docker >/dev/null 2>&1 || fail "docker is required"
mapfile -t containers < <(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' | sort)
[ "${#containers[@]}" -gt 0 ] || fail "no running container carries label com.docker.compose.project=${PROJECT}"
ok "${#containers[@]} running container(s) in project ${PROJECT}"

step "1/2 V8 heap ceiling vs cgroup limit, per Node container"
checked=0
unbounded=0
bad=0
printf '  %-34s %9s %9s  %s\n' "container" "limit(MB)" "heap(MB)" "verdict"
for c in "${containers[@]}"; do
  # Only containers that can run node are Node services; the exec is the
  # detection, so a scratch or Go image is skipped without a list to maintain.
  # docker prints the "exec: sh: not found" of a scratch image on STDOUT
  # (rc 127), so both streams are dropped, not just stderr.
  if ! docker exec "$c" sh -c 'command -v node >/dev/null 2>&1' >/dev/null 2>&1; then
    continue
  fi
  limit_b=$(docker inspect -f '{{.HostConfig.Memory}}' "$c")
  heap_b=$(docker exec "$c" node -e 'console.log(require("v8").getHeapStatistics().heap_size_limit)' 2>/dev/null || echo 0)
  [ "${heap_b:-0}" -gt 0 ] || fail "$c: could not read heap_size_limit (node present but the exec failed)"
  limit_mb=$((limit_b / 1048576))
  heap_mb=$((heap_b / 1048576))
  if [ "$limit_b" -eq 0 ]; then
    unbounded=$((unbounded + 1))
    printf '  %-34s %9s %9s  %s\n' "$c" "none" "$heap_mb" "no limit — nothing to be under"
    continue
  fi
  checked=$((checked + 1))
  if [ "$heap_b" -lt "$limit_b" ]; then
    printf '  %-34s %9s %9s  ok\n' "$c" "$limit_mb" "$heap_mb"
  else
    bad=$((bad + 1))
    printf '  %-34s %9s %9s  \033[0;31mheap >= limit\033[0m\n' "$c" "$limit_mb" "$heap_mb"
  fi
done
[ "$checked" -gt 0 ] || [ "$unbounded" -gt 0 ] || fail "no Node container found in project ${PROJECT} — is the stack up?"
[ "$unbounded" -eq 0 ] || warn "$unbounded Node container(s) run without a memory limit (reported, not judged)"

step "2/2 verdict"
[ "$bad" -eq 0 ] || fail "$bad of $checked limited Node container(s) can outgrow their cgroup (set NODE_OPTIONS=--max-old-space-size to ~75% of mem_limit)"
ok "all $checked limited Node container(s) keep their V8 heap below the cgroup limit"
