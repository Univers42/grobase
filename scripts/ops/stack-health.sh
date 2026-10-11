#!/bin/sh
# stack-health.sh — is the whole stack alive, and can its services reach each other?
#
# Six legs, each of which must pass for exit 0:
#   1. containers  every container of the compose project is running + healthy and was
#                  not OOM-killed; a one-shot init job (restart policy "no") must have
#                  exited 0; every service a container depends on has a container; and,
#                  when HEALTH_EXPECT names the selected shape's services, each of those
#                  has one too
#   2. network     every service→service edge accepts a TCP connection, opened from INSIDE
#                  the client's own network namespace (so DNS, the bridge and the port are
#                  all exercised exactly as the client sees them)
#   3. published   every port published on the host accepts a TCP connection from the host
#   4. engines     each engine executes a query with the credentials that are in the env file
#   5. gateway     every Kong route answers without a gateway error, auth + rest with 200
#   6. monitoring  Prometheus has no scrape target down and no alert firing
# Legs 4 to 6 live in stack-health-requests.sh.
#
# Ponytail: explicit edges are found by scanning each container's env + command (and
# kong.yml's upstream urls) for `<host>:<port>` where <host> is a container name, service
# name or network alias of this project; a compose `depends_on` with no explicit address
# is probed on the dependency's exposed ports and passes when ANY of them accepts. So an
# edge is MISSED (under-reported) when it is neither a depends_on nor an explicit
# `host:port` — an FQDN, a config file, a code default. An edge is OVER-reported when a
# service merely carries another's address without calling it — under NETSEG=1 that can
# show an unreachable-by-design edge. Without HEALTH_EXPECT a service nothing depends on
# and that was never created is invisible: `make health` only sets it when the shape is
# given explicitly (PACKAGE= / EDITION= / PROFILES=), because the shape a stack was started
# with is not recorded anywhere it could be read back from.
#
# Ponytail: a TCP accept proves reachability, not that the peer answers correctly — the
# per-container healthchecks (leg 1) and the requests of legs 4-6 carry that half. Leg 3
# probes from the Docker host's network namespace, which on Docker Desktop is the VM, not
# the machine you type on.
#
# Usage:
#   sh scripts/ops/stack-health.sh                 # all six legs
#   HEALTH_EXPECT="kong postgres …" sh scripts/ops/stack-health.sh  # also require these services
#   HEALTH_WAIT=180 sh scripts/ops/stack-health.sh # first wait for "starting" to settle
#   sh scripts/ops/stack-health.sh parse-edges     # stdin: S/A/P/D/E/K lines → edges (gate use)
#   sh scripts/ops/stack-health.sh probe <client>  # stdin: "host port[,port]" lines → ok|fail lines
#   sh scripts/ops/stack-health.sh --help
# Exit: 0 every leg passed · 1 at least one leg failed or could not run.
set -eu

PROJECT="${COMPOSE_PROJECT_NAME:-mini-baas}"
KONG_YML="${KONG_YML:-infra/docker/services/kong/conf/kong.yml}"
PROBE_IMAGE="${HEALTH_PROBE_IMAGE:-busybox:1.36}"
HEALTH_WAIT="${HEALTH_WAIT:-0}"
HEALTH_EXPECT="${HEALTH_EXPECT:-}"
PROBE_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-3}"

STATE_FMT='{{.Name}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}} {{or .HostConfig.RestartPolicy.Name "no"}} {{.State.OOMKilled}} {{.RestartCount}} {{index .Config.Labels "com.docker.compose.depends_on"}}'
EDGE_FMT='{{$n := .Name}}S {{.Name}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}}
D {{.Name}} {{index .Config.Labels "com.docker.compose.depends_on"}}
{{range $p, $_ := .Config.ExposedPorts}}P {{$n}} {{$p}}
{{end}}{{range .NetworkSettings.Networks}}{{range .Aliases}}A {{$n}} {{.}}
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
# (or, for a one-shot job, not exited 0), was OOM-killed, depends on a service that has
# no container at all, or when a service named in HEALTH_EXPECT has none.
check_states() {
  project_ids | xargs docker inspect --format "$STATE_FMT" | sort -k2 | awk -v expect="$HEALTH_EXPECT" '
    { present[$2] = 1; deps[$2] = $9; oneshot = ($6 != "always" && $6 != "unless-stopped" && $6 != "on-failure")
      note = ($4 == "none" ? "  (no healthcheck)" : "") ($8 > 0 ? "  (restarted " $8 "×)" : "") }
    $7 == "true" { bad++; printf "  ✗ %s — OOM-killed\n", $2; next }
    $3 == "running" && ($4 == "healthy" || $4 == "none") { ok++; printf "  ✓ %s%s\n", $2, note; next }
    $3 == "exited" && $5 == 0 && oneshot { done++; printf "  ✓ %s  (one-shot, completed)\n", $2; next }
    { bad++; printf "  ✗ %s — state=%s health=%s exit=%s\n", $2, $3, $4, $5 }
    END {
      for (svc in deps) {
        count = split(deps[svc], list, ",")
        for (i = 1; i <= count; i++) {
          sub(/:.*/, "", list[i])
          if (list[i] != "" && !(list[i] in present)) { bad++; printf "  ✗ %s depends on %s, which has no container\n", svc, list[i] }
        }
      }
      wanted = split(expect, want, " ")
      for (i = 1; i <= wanted; i++) if (!(want[i] in present)) { bad++; printf "  ✗ %s is part of the selected shape but has no container\n", want[i] }
      if (wanted == 0) printf "  • shape not given: a service that was never created is not detected (make health PACKAGE=… | EDITION=…)\n"
      printf "  → %d healthy · %d completed · %d failing\n", ok, done, bad; exit (bad > 0 || NR == 0)
    }'
}

# parse_edges reads S (state), A (alias), P (exposed port), D (depends_on), E (env/cmd)
# and K (kong url) lines on stdin and prints the unique "client host port[,port]" edges
# whose host is another running container: every explicit host:port, then each depends_on
# that had no explicit address, on the dependency's exposed tcp ports.
parse_edges() {
  awk -f "${0%/*}/stack-health-edges.awk" | sort -u
}

# list_edges feeds the live project's containers and Kong's declared upstreams to parse_edges.
list_edges() {
  {
    project_ids | xargs docker inspect --format "$EDGE_FMT"
    sed -n 's/^ *url: */K /p' "$KONG_YML" 2>/dev/null || true
  } | parse_edges
}

# probe_net reads "host port[,port]" lines on stdin and, from inside the network namespace
# $1 (`container:<name>` or `host`), prints "ok host ports" when ANY listed port accepts a
# TCP connection and "fail host ports" otherwise.
probe_net() {
  docker run --rm -i --network "$1" -e T="$PROBE_TIMEOUT" "$PROBE_IMAGE" sh -c '
    while read -r host ports; do
      hit=fail
      for port in $(echo "$ports" | tr "," " "); do
        nc -z -w "$T" "$host" "$port" 2>/dev/null && hit=ok && break
      done
      echo "$hit $host $ports"
    done' 2>/dev/null || echo "fail probe-could-not-start -"
}

# summarize_edges reads "client ok|fail host port" lines and prints one row per client,
# counting them as $1 (edges, ports); fails when any is unreachable.
summarize_edges() {
  sort | awk -v what="$1" '
    !($1 in total) { order[++clients] = $1 }
    { total[$1]++; if ($2 == "ok") good[$1]++; else { bad++; miss[$1] = miss[$1] " " $3 ":" $4 } }
    END {
      for (i = 1; i <= clients; i++) {
        c = order[i]
        printf "  %s %s → %d/%d%s\n", (miss[c] == "" ? "✓" : "✗"), c, good[c], total[c], (miss[c] == "" ? "" : "  UNREACHABLE:" miss[c])
      }
      printf "  → %d %s probed · %d unreachable\n", NR, what, bad; exit (bad > 0)
    }'
}

# ensure_probe_image succeeds when the probe image is present locally or could be pulled.
ensure_probe_image() {
  docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || docker pull -q "$PROBE_IMAGE" >/dev/null 2>&1
}

# check_edges probes every discovered edge, one throwaway probe container per client,
# all clients in parallel.
check_edges() {
  edges="$(list_edges)"
  if [ -z "$edges" ]; then
    printf '  ✗ no service→service edge discovered\n'
    return 1
  fi
  for client in $(printf '%s\n' "$edges" | cut -d' ' -f1 | sort -u); do
    printf '%s\n' "$edges" | awk -v c="$client" '$1 == c { print $2, $3 }' |
      probe_net "container:$client" | sed "s|^|$client |" >"$TMP/$client" &
  done
  wait
  cat "$TMP"/* | summarize_edges edges
}

# check_published probes, from the host's network namespace, every host port a container
# of the project publishes; a wildcard bind is probed on the loopback.
check_published() {
  published="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}} {{.Ports}}' | awk '
    { for (i = 2; i <= NF; i++) if (match($i, /^[0-9.]+:[0-9]+->/)) {
        split(substr($i, RSTART, RLENGTH - 2), bind, ":")
        print $1, (bind[1] == "0.0.0.0" ? "127.0.0.1" : bind[1]), bind[2] } }' | sort -u)"
  if [ -z "$published" ]; then
    printf '  • no host-published port\n'
    return 0
  fi
  {
    printf '%s\n---\n' "$published"
    printf '%s\n' "$published" | cut -d' ' -f2,3 | probe_net host
  } | awk '
    $0 == "---" { results = 1; next }
    !results { name[$2 " " $3] = name[$2 " " $3] (name[$2 " " $3] == "" ? "" : "+") $1; next }
    { print name[$2 " " $3], $1, $2, $3 }' | summarize_edges ports
}

# run_all runs the six legs and exits non-zero when any of them failed.
run_all() {
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  [ "$HEALTH_WAIT" -gt 0 ] && wait_settled
  failed=0
  printf 'Containers (project %s)\n' "$PROJECT"
  check_states || failed=1
  if ensure_probe_image; then
    printf 'Network — TCP from inside each client to every service it calls or depends on\n'
    check_edges || failed=1
    printf 'Published — TCP from the host to every published port\n'
    check_published || failed=1
  else
    failed=1
    printf '✗ NOT RUN: network + published legs — probe image %s unavailable\n' "$PROBE_IMAGE"
  fi
  sh "${0%/*}/stack-health-requests.sh" || failed=1
  [ "$failed" -eq 0 ] && printf '✓ stack healthy\n' || printf '✗ stack NOT healthy\n'
  return "$failed"
}

main() {
  case "${1:-}" in
  parse-edges) parse_edges ;;
  probe) probe_net "container:$2" ;;
  -h | --help) sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "$0" ;;
  *) run_all ;;
  esac
}

main "$@"
