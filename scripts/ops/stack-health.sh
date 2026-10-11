#!/bin/sh
# stack-health.sh — is the whole stack alive, and can its services reach each other?
#
# Three legs, each of which must pass for exit 0:
#   1. state    every container of the compose project is running + healthy; a one-shot
#               init job (restart policy "no") must have exited 0
#   2. network  every service→service edge accepts a TCP connection, opened from INSIDE
#               the client's own network namespace (so DNS, the bridge and the port are
#               all exercised exactly as the client sees them)
#   3. gateway  real HTTP requests through Kong with the anon key from the env file
#
# Ponytail: edges are found by scanning each container's env + command (and kong.yml's
# upstream urls) for `<host>:<port>` where <host> is a container name, service name or
# network alias of this project. So an edge is MISSED (under-reported) when the port is
# implicit (`http://gotrue/`), the host is an FQDN, or the address lives only in a config
# file or a code default. An edge is OVER-reported when a service merely carries another's
# address without calling it — under NETSEG=1 that can show an unreachable-by-design edge.
# A service that was never created is invisible to every leg: this checks what exists,
# not what the selected EDITION/PACKAGE should contain (`make ps` shows that).
#
# Ponytail: a TCP accept proves reachability, not that the peer answers correctly — the
# per-container healthchecks (leg 1) carry that half.
#
# Usage:
#   sh scripts/ops/stack-health.sh                 # all three legs
#   HEALTH_WAIT=180 sh scripts/ops/stack-health.sh # first wait for "starting" to settle
#   sh scripts/ops/stack-health.sh parse-edges     # stdin: S/A/E/K lines → edges (gate use)
#   sh scripts/ops/stack-health.sh probe <client>  # stdin: "host port" lines → ok|fail lines
#   sh scripts/ops/stack-health.sh --help
# Exit: 0 every leg passed · 1 at least one leg failed or could not run.
set -eu

PROJECT="${COMPOSE_PROJECT_NAME:-mini-baas}"
ENV_FILE="${ENV_FILE:-.env}"
KONG_YML="${KONG_YML:-infra/docker/services/kong/conf/kong.yml}"
PROBE_IMAGE="${HEALTH_PROBE_IMAGE:-busybox:1.36}"
HEALTH_WAIT="${HEALTH_WAIT:-0}"
PROBE_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-3}"

STATE_FMT='{{.Name}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}} {{.HostConfig.RestartPolicy.Name}}'
EDGE_FMT='{{$n := .Name}}S {{.Name}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}}
{{range .NetworkSettings.Networks}}{{range .Aliases}}A {{$n}} {{.}}
{{end}}{{end}}{{range .Config.Env}}E {{$n}} {{.}}
{{end}}{{range .Config.Cmd}}E {{$n}} {{.}}
{{end}}'

# project_ids prints the id of every container (running or not) of the compose project.
project_ids() {
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"
}

# wait_settled blocks until no container reports health "starting", or HEALTH_WAIT elapses.
wait_settled() {
  deadline=$(($(date +%s) + HEALTH_WAIT))
  while [ "$(date +%s)" -lt "$deadline" ] &&
    project_ids | xargs docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' | grep -q starting; do
    sleep 3
  done
}

# check_states prints one line per container and fails when any is not running+healthy
# (or, for a one-shot job, not exited 0).
check_states() {
  project_ids | xargs docker inspect --format "$STATE_FMT" | sort -k2 | awk '
    { oneshot = ($6 != "always" && $6 != "unless-stopped" && $6 != "on-failure") }
    $3 == "running" && ($4 == "healthy" || $4 == "none") {
      ok++; printf "  ✓ %s%s\n", $2, ($4 == "none" ? "  (no healthcheck)" : ""); next }
    $3 == "exited" && $5 == 0 && oneshot { done++; printf "  ✓ %s  (one-shot, completed)\n", $2; next }
    { bad++; printf "  ✗ %s — state=%s health=%s exit=%s\n", $2, $3, $4, $5 }
    END { printf "  → %d healthy · %d completed · %d failing\n", ok, done, bad; exit (bad > 0 || NR == 0) }'
}

# parse_edges reads S (state), A (alias), E (env/cmd) and K (kong url) lines on stdin and
# prints the unique "client host port" edges whose host is another running container.
parse_edges() {
  awk '
    function scan(client, text,    tok, part) {
      while (match(text, /[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]+/)) {
        tok = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
        split(tok, part, ":")
        if ((part[1] in owner) && owner[part[1]] != client && up[owner[part[1]]])
          print client, part[1], part[2]
      }
    }
    $1 == "S" { name = substr($2, 2); owner[name] = name; owner[$3] = name; if ($4 == "running") up[name] = 1; next }
    $1 == "A" { owner[$3] = substr($2, 2); next }
    $1 == "E" || $1 == "K" { line[++count] = $0 }
    END {
      for (i = 1; i <= count; i++) {
        split(line[i], field, " ")
        client = (field[1] == "K") ? owner["kong"] : substr(field[2], 2)
        if (up[client]) scan(client, line[i])
      }
    }' | sort -u
}

# list_edges feeds the live project's containers and Kong's declared upstreams to parse_edges.
list_edges() {
  {
    project_ids | xargs docker inspect --format "$EDGE_FMT"
    sed -n 's/^ *url: */K /p' "$KONG_YML" 2>/dev/null || true
  } | parse_edges
}

# probe_client reads "host port" lines on stdin and, from inside container $1's network
# namespace, prints "ok host port" or "fail host port" for a TCP connect to each.
probe_client() {
  docker run --rm -i --network "container:$1" -e T="$PROBE_TIMEOUT" "$PROBE_IMAGE" sh -c '
    while read -r host port; do
      if nc -z -w "$T" "$host" "$port" 2>/dev/null; then echo "ok $host $port"; else echo "fail $host $port"; fi
    done' 2>/dev/null || echo "fail probe-could-not-start -"
}

# summarize_edges reads "client ok|fail host port" lines and prints one row per client;
# fails when any edge is unreachable.
summarize_edges() {
  sort | awk '
    !($1 in total) { order[++clients] = $1 }
    { total[$1]++; if ($2 == "ok") good[$1]++; else { bad++; miss[$1] = miss[$1] " " $3 ":" $4 } }
    END {
      for (i = 1; i <= clients; i++) {
        c = order[i]
        printf "  %s %s → %d/%d%s\n", (miss[c] == "" ? "✓" : "✗"), c, good[c], total[c], (miss[c] == "" ? "" : "  UNREACHABLE:" miss[c])
      }
      printf "  → %d edges probed · %d unreachable\n", NR, bad; exit (bad > 0)
    }'
}

# ensure_probe_image succeeds when the probe image is present locally or could be pulled.
ensure_probe_image() {
  docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || docker pull -q "$PROBE_IMAGE" >/dev/null 2>&1
}

# check_edges probes every discovered edge, one throwaway probe container per client,
# all clients in parallel. A probe image that cannot be obtained is a failure, not a pass.
check_edges() {
  edges="$(list_edges)"
  if [ -z "$edges" ]; then
    printf '  ✗ no service→service edge discovered\n'
    return 1
  fi
  if ! ensure_probe_image; then
    printf '  ✗ NOT RUN: probe image %s unavailable\n' "$PROBE_IMAGE"
    return 1
  fi
  for client in $(printf '%s\n' "$edges" | cut -d' ' -f1 | sort -u); do
    printf '%s\n' "$edges" | awk -v c="$client" '$1 == c { print $2, $3 }' |
      probe_client "$client" | sed "s|^|$client |" >"$TMP/$client" &
  done
  wait
  cat "$TMP"/* | summarize_edges
}

# check_gateway sends real requests through Kong with the env file's anon key.
check_gateway() {
  port="$(docker port "$PROJECT-kong" 8000/tcp 2>/dev/null | sed -n '1s/.*://p')"
  key="$(sed -n 's/^ANON_KEY=//p' "$ENV_FILE" 2>/dev/null | head -n 1)"
  failed=0
  for path in /auth/v1/health /rest/v1/; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "apikey: $key" "http://localhost:${port:-8000}$path" || true)"
    if [ "$code" = 200 ]; then
      printf '  ✓ %s\n' "$path"
    else
      failed=1
      printf '  ✗ %s — HTTP %s%s\n' "$path" "$code" "$([ "$code" = 401 ] && printf ' (the ANON_KEY in %s is not the one the stack runs with)' "$ENV_FILE")"
    fi
  done
  return "$failed"
}

# run_all runs the three legs and exits non-zero when any of them failed.
run_all() {
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  [ "$HEALTH_WAIT" -gt 0 ] && wait_settled
  failed=0
  printf 'Containers (project %s)\n' "$PROJECT"
  check_states || failed=1
  printf 'Network — TCP from inside each client to every service it is configured to call\n'
  check_edges || failed=1
  printf 'Gateway — HTTP through Kong\n'
  check_gateway || failed=1
  [ "$failed" -eq 0 ] && printf '✓ stack healthy\n' || printf '✗ stack NOT healthy\n'
  return "$failed"
}

main() {
  case "${1:-}" in
  parse-edges) parse_edges ;;
  probe) probe_client "$2" ;;
  -h | --help) sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "$0" ;;
  *) run_all ;;
  esac
}

main "$@"
