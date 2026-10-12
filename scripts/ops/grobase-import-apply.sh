#!/usr/bin/env bash
# grobase-import-apply.sh — the destructive half of grobase-import.sh: replays a verified
# import dir into the engines on THIS docker daemon, so it runs on the data center.
# Order (verdicts C5-C9 + the apply BLOCK): verify · every target engine exists · helper images ·
# disk · record the running compose-project containers (id, name; `--rm` ones are left alone,
# stopping one deletes it) · stop them · cold tar of each target volume · start the engines ·
# re-check nothing else started · one vault-restore.sh call PER PACKET · pg-counts.sh check ·
# the target's own db-bootstrap + pg-migrate one-shots · `docker start` the recorded ids
# (never `make up`: C6). A trap restarts the recorded set on any exit before the first DROP;
# after it, a failure leaves the stack down and names the rollback.
# Writes <id>/apply/{running.before,running.after,restore.log,migrate.log,counts.*,volumes/}.
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
IMPORT_ROOT="${IMPORT_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/grobase/import}"
VAULT_RESTORE="${VAULT_RESTORE:-${SCRIPT_DIR}/vault-restore.sh}"
PG_COUNTS="${PG_COUNTS:-${SCRIPT_DIR}/pg-counts.sh}"
SNAPSHOT_IMAGE="${SNAPSHOT_IMAGE:-alpine:latest}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
PROJECT="${COMPOSE_PROJECT:-mini-baas}"
MIGRATE_CONTAINERS="${MIGRATE_CONTAINERS:-mini-baas-db-bootstrap mini-baas-pg-migrate}"
VERB="" ID="" CONFIRM=0 FORCE=0 IMPORT_DIR="" APPLY_DIR="" ENGINES="" COUNTS_RC=0 PHASE=""

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}
refuse() { die "$1" 2; }
note() { printf '[grobase-import] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
usage: grobase-import-apply.sh apply ID [--confirm] [--force]
       grobase-import-rollback.sh rollback ID [--confirm]

apply     replay import ID into the engines on this docker daemon. Without --confirm it
          prints the plan and changes nothing. With it: stop the running compose-project
          containers, snapshot the target volumes, restore packet by packet, count postgres
          rows, run the target's own bootstrap + migrations, start what was running.
          --force re-applies (replacing the snapshot of the previous run).
rollback  put each target volume back from apply's snapshot (checksummed first), then
          start what was running before apply.

exit codes: 0 done · 1 a step failed · 2 refused before any change · 3 counts differ.
EOF
}

parse_args() {
  [ "$#" -ge 2 ] || refuse "$(usage)"
  VERB="$1" ID="$2"
  shift 2
  case "$ID" in '' | . | .. | *[!A-Za-z0-9._-]*) refuse "invalid import id: ${ID}" ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --confirm) CONFIRM=1 ;;
    --force) FORCE=1 ;;
    *) refuse "unknown argument: $1" ;;
    esac
    shift
  done
  IMPORT_DIR="${IMPORT_ROOT%/}/${ID}"
  APPLY_DIR="${IMPORT_DIR}/apply"
  [ -f "${IMPORT_DIR}/manifest.json" ] || refuse "no import named ${ID} under ${IMPORT_ROOT%/}"
}

packet_rows() { jq -r '.packets[] | [.id, .engine, .artifact] | @tsv' "${IMPORT_DIR}/manifest.json"; }
set_state() { printf '%s\n' "$2" >"${IMPORT_DIR}/state/${1}"; }

already_applied() {
  local pid engine artifact
  while IFS=$'\t' read -r pid engine artifact; do
    case "$(cat "${IMPORT_DIR}/state/${pid}" 2>/dev/null || true)" in applied | verified) ;; *) return 1 ;; esac
  done < <(packet_rows)
}

# open_verified — the checksums are re-proven here, on the machine that replays them.
open_verified() {
  IMPORT_ROOT="$IMPORT_ROOT" bash "${SCRIPT_DIR}/grobase-import.sh" verify "$ID" ||
    refuse "verify ${ID} failed — nothing was applied"
  ENGINES="$(jq -r '[.packets[].engine] | join(" ")' "${IMPORT_DIR}/manifest.json")"
  [ -n "$ENGINES" ] || refuse "${ID} carries no packets"
}

# engine_containers — one container name per packet engine. ENGINES stays a plain word
# list because it is handed to vault-restore as an environment variable.
engine_containers() {
  local e
  for e in $ENGINES; do printf 'mini-baas-%s\n' "$e"; done
}

# require_targets — a packet whose engine has no container would be skipped by vault-restore
# and still be reported applied, so every target (and each migrate one-shot) must exist.
require_targets() {
  local c
  docker info >/dev/null 2>&1 || refuse "no docker daemon reachable — nothing was changed"
  for c in $(engine_containers) $MIGRATE_CONTAINERS; do
    docker inspect "$c" >/dev/null 2>&1 || refuse "container ${c} does not exist on this daemon — nothing was changed"
  done
  [ -x "$PG_COUNTS" ] || [ -f "$PG_COUNTS" ] || refuse "${PG_COUNTS} is missing — the restore could not be proven"
}

engine_volumes() {
  local e
  for e in $ENGINES; do
    docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' "mini-baas-${e}"
  done | sed '/^$/d' | LC_ALL=C sort -u
}

# Ponytail: the list repeats vault-restore.sh's MONGO_IMAGE/MC_IMAGE/REDIS_IMAGE defaults. A
# helper added there and not here is pulled after the stop; a failed pull then exits 1.
prefetch_helpers() {
  local img
  for img in "$SNAPSHOT_IMAGE" "${MONGO_IMAGE:-mongo:7}" "${MC_IMAGE:-ghcr.io/univers42/grobase-mc:latest}" \
    "${REDIS_IMAGE:-ghcr.io/univers42/grobase-redis:latest}"; do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    [ "$CONFIRM" -eq 1 ] || { note "would pull ${img} before stopping anything" && continue; }
    docker pull -q "$img" >/dev/null || refuse "cannot pull ${img} — nothing was changed"
  done
}

# Ponytail: sizes are `du` of the live volumes before the stop; growth between this check and
# the tar is not counted. The 2x margin (C9: at most half the free space) is the cushion.
require_disk() {
  local vol bytes=0 need free
  for vol in $(engine_volumes); do
    bytes=$((bytes + $(docker run --rm -v "${vol}:/v:ro" "$SNAPSHOT_IMAGE" du -sb /v | cut -f1)))
  done
  need=$(((2 * bytes + $(jq '[.packets[].bytes] | add // 0' "${IMPORT_DIR}/manifest.json")) * 2))
  free="$(df -PB1 "$IMPORT_DIR" | awk 'NR == 2 { print $4 }')"
  [ "$need" -le "$free" ] || refuse "need ${need} bytes free under ${IMPORT_DIR}, have ${free}"
}

# project_running — "<id> <name>" of each running container of the compose project that is not
# --rm: those are what apply stops and restarts. Anything else keeps running untouched.
project_running() {
  local id
  docker ps -q --filter "label=com.docker.compose.project=${PROJECT}" | while read -r id; do
    docker inspect -f '{{if not .HostConfig.AutoRemove}}{{.ID}} {{slice .Name 1}}{{end}}' "$id"
  done | sed '/^$/d' | LC_ALL=C sort -k2
}

record_running() {
  mkdir -p "${APPLY_DIR}/volumes" "${APPLY_DIR}/seed"
  chmod 700 "$APPLY_DIR"
  project_running >"${APPLY_DIR}/running.before"
  [ -s "${APPLY_DIR}/running.before" ] || refuse "no running ${PROJECT} container — is this the data center?"
}

# on_exit — before the first DROP nothing changed, so the recorded set is started again; after
# it, a half-restored stack must not serve traffic, so it stays down and the rollback is named.
on_exit() {
  local rc=$?
  case "${PHASE}:${rc}" in
  stopped:[1-9]*) note "nothing was restored; restarting the recorded containers" && start_recorded || true ;;
  restoring:[1-9]*) note "the stack is down. Roll back: grobase-import.sh rollback ${ID} --confirm" ;;
  esac
}

stop_recorded() {
  PHASE=stopped
  note "stopping $(wc -l <"${APPLY_DIR}/running.before") ${PROJECT} containers"
  cut -d' ' -f1 "${APPLY_DIR}/running.before" | xargs -r docker stop -t 30 >/dev/null || die "docker stop failed"
  [ -z "$(project_running)" ] || die "still running after the stop (another actor?): $(project_running | cut -d' ' -f2 | tr '\n' ' ')"
}

# snapshot_volumes — tar streams to stdout so the file belongs to the caller, not root. The
# archive must list exactly the entries `find` sees in the stopped volume: a legitimately empty
# volume passes, a tar that died half-way does not.
snapshot_volumes() {
  local vol out want got
  for vol in $(engine_volumes); do
    out="${APPLY_DIR}/volumes/${vol}.tar.gz"
    want="$(docker run --rm -v "${vol}:/v:ro" "$SNAPSHOT_IMAGE" find /v -mindepth 1 | wc -l)"
    docker run --rm -v "${vol}:/v:ro" "$SNAPSHOT_IMAGE" tar -czf - -C /v . >"$out" || die "snapshot of ${vol} failed"
    got="$(tar -tzf "$out" | grep -cvx '\./' || true)"
    [ "$got" -eq "$want" ] || die "snapshot of ${vol} lists ${got} entries, the volume holds ${want}"
  done
  (cd "${APPLY_DIR}/volumes" && sha256sum -- *.tar.gz >SHA256SUMS)
}

# Ponytail: an image with no healthcheck counts as healthy once `running`; one that crashes a
# few seconds later passes here and is caught only by the running-set compare at the end.
wait_healthy() {
  local waited=0
  while :; do
    case "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1")" in
    healthy | running) return 0 ;;
    esac
    [ "$waited" -lt "$HEALTH_TIMEOUT" ] || return 1
    sleep 3
    waited=$((waited + 3))
  done
}

# start_engines — then the racer check: only the engines may run before the first DROP.
start_engines() {
  local e others
  for e in $ENGINES; do docker start "mini-baas-${e}" >/dev/null || die "cannot start mini-baas-${e}"; done
  for e in $ENGINES; do wait_healthy "mini-baas-${e}" || die "mini-baas-${e} not healthy after ${HEALTH_TIMEOUT}s"; done
  others="$(project_running | cut -d' ' -f2 | grep -vxF -f <(engine_containers) || true)"
  [ -z "$others" ] || die "started by someone else during apply: ${others//$'\n'/ }"
}

# restore_packets — one vault-restore.sh call per packet over a seed dir holding only that
# packet's artifact, so each packet's state is what actually happened to it. vault-restore
# exits 2 only when it refused before touching anything: while no packet has changed an
# engine, PHASE stays `stopped` and the trap restarts the stack.
restore_packets() {
  local pid engine artifact seed all="$ENGINES" rc
  while IFS=$'\t' read -r pid engine artifact; do
    seed="${APPLY_DIR}/seed/${pid}"
    mkdir -p "$seed" && ln -f "${IMPORT_DIR}/${artifact}" "${seed}/${artifact}"
    set_state "$pid" applying
    note "restoring ${pid} (log: ${APPLY_DIR}/restore.log)"
    rc=0
    SKIP_STACK_CYCLE=1 ENGINES="$engine" KEEP_RUNNING="$all" SEED_DIR="$seed" STATE_DIR="${APPLY_DIR}/pre" \
      FETCH=0 sh "$VAULT_RESTORE" >>"${APPLY_DIR}/restore.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || PHASE=restoring
    [ "$rc" -eq 0 ] || {
      set_state "$pid" failed
      die "vault-restore.sh rc ${rc} on ${pid}: $(tail -n 3 "${APPLY_DIR}/restore.log" | tr '\n' ' ')"
    }
    set_state "$pid" applied
  done < <(packet_rows)
}

# verify_counts — postgres alone gets an exact per-table proof; the other engines stay applied.
verify_counts() {
  local pid artifact
  read -r pid artifact < <(jq -r '.packets[] | select(.engine == "postgres") | "\(.id) \(.artifact)"' \
    "${IMPORT_DIR}/manifest.json") || return 0
  if bash "$PG_COUNTS" check "${IMPORT_DIR}/${artifact}" >"${APPLY_DIR}/counts.diff" 2>"${APPLY_DIR}/counts.log"; then
    set_state "$pid" verified
    return 0
  fi
  set_state "$pid" failed
  COUNTS_RC=3
  note "postgres row counts differ — see ${APPLY_DIR}/counts.diff"
}

# migrate — the target's own one-shot containers, with its own env: the seed may be older than
# the target's schema, and services must not start on a schema behind their code.
migrate() {
  local c
  for c in $MIGRATE_CONTAINERS; do
    note "running ${c}"
    docker start -a "$c" >>"${APPLY_DIR}/migrate.log" 2>&1 || die "${c} failed — see ${APPLY_DIR}/migrate.log"
  done
}

# start_recorded — by recorded id, so a container recreated meanwhile is noticed, not started.
start_recorded() {
  local id name late=""
  while read -r id name; do
    docker start "$id" >/dev/null 2>&1 || late="${late} ${name}(gone)"
  done <"${APPLY_DIR}/running.before"
  while read -r id name; do
    wait_healthy "$id" 2>/dev/null || late="${late} ${name}"
  done <"${APPLY_DIR}/running.before"
  project_running >"${APPLY_DIR}/running.after"
  [ -z "$late" ] || die "not healthy after ${HEALTH_TIMEOUT}s:${late}"
}

# cmd_apply — a packet left `applying` or `failed` means an earlier run stopped part-way; a new
# run would replace that run's snapshot with a half-restored one, so it is refused unless --force.
cmd_apply() {
  if [ "$FORCE" -ne 1 ] && already_applied; then
    note "${ID} is already applied; nothing to do (--force re-applies)"
    return 0
  fi
  ! grep -qsxE 'applying|failed' "${IMPORT_DIR}"/state/* || [ "$FORCE" -eq 1 ] ||
    refuse "an earlier apply of ${ID} did not finish: grobase-import.sh rollback ${ID} --confirm first, or --force"
  open_verified
  require_targets
  prefetch_helpers
  require_disk
  [ "$CONFIRM" -eq 1 ] || {
    note "plan: stop $(project_running | wc -l) ${PROJECT} containers, snapshot $(engine_volumes | tr '\n' ' '), restore ${ENGINES}, migrate, restart (re-run with --confirm)"
    return 0
  }
  record_running
  trap on_exit EXIT
  stop_recorded
  snapshot_volumes
  start_engines
  restore_packets
  verify_counts
  migrate
  PHASE=restarting
  start_recorded
  note "applied ${ID}; counts rc=${COUNTS_RC}"
  return "$COUNTS_RC"
}

main() {
  case "${1:-}" in -h | --help) usage && exit 0 ;; esac
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v docker >/dev/null 2>&1 || die "docker is required"
  parse_args "$@"
  [ "$VERB" = apply ] || refuse "$(usage)"
  mkdir -p "${IMPORT_DIR}/state"
  cmd_apply
}

# Sourced by grobase-import-rollback.sh for its helpers; runs only when executed.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
