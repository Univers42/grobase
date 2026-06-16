# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    trust-browser-host-ca.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
LOCAL_TRUST_SCRIPT="$SCRIPT_DIR/trust-localhost-cert.sh"
REMOTE_CERT_DIR=${TRACK_BINOCLE_BROWSER_HOST_CERT_DIR:-.cache/track-binocle/certs}
REMOTE_TRUST_MODE=${TRACK_BINOCLE_BROWSER_HOST_TRUST:-auto}
REQUIRED=${TRACK_BINOCLE_BROWSER_HOST_REQUIRED:-0}
CONNECT_TIMEOUT=${TRACK_BINOCLE_BROWSER_HOST_CONNECT_TIMEOUT:-5}
SSH_PORT=${TRACK_BINOCLE_BROWSER_HOST_PORT:-}
SSH_USER=${TRACK_BINOCLE_BROWSER_HOST_USER:-${USER:-}}
SSH_TARGET=${TRACK_BINOCLE_BROWSER_HOST:-}
SSH_PORTS=${TRACK_BINOCLE_BROWSER_HOST_PORTS:-}
SSH_USERS=${TRACK_BINOCLE_BROWSER_HOST_USERS:-}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--required] [--target user@host]

Copies the Track Binocle local development CA to the browser host over SSH/SCP
and runs the same Linux/NSS trust import there. This is useful when the app is
opened through VS Code Remote SSH or another forwarded localhost URL.

Configuration:
  TRACK_BINOCLE_BROWSER_HOST=user@host   SSH target for the browser host
  TRACK_BINOCLE_BROWSER_HOST_PORT=22     Optional SSH port
  TRACK_BINOCLE_BROWSER_HOST_PORTS="22 2222"
                                         Auto-detection SSH ports
  TRACK_BINOCLE_BROWSER_HOST_USER=user   User for auto-detected SSH host
  TRACK_BINOCLE_BROWSER_HOST_USERS="alice bob"
                                         Auto-detection SSH users
  TRACK_BINOCLE_BROWSER_HOST_REQUIRED=1  Fail when the host cannot be reached
  TRACK_BINOCLE_BROWSER_HOST_TRUST=skip  Disable this helper
EOF
}

for arg in "$@"; do
  case "$arg" in
    --required)
      REQUIRED=1
      ;;
    --target=*)
      SSH_TARGET=${arg#--target=}
      ;;
    --target)
      printf '[certs] --target requires user@host.\n' >&2
      exit 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '[certs] Unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

case "$REMOTE_TRUST_MODE" in
  0|false|FALSE|no|NO|skip|SKIP)
    printf '[certs] skipping browser-host CA trust because TRACK_BINOCLE_BROWSER_HOST_TRUST=%s\n' "$REMOTE_TRUST_MODE"
    exit 0
    ;;
esac

if [ ! -s "$CA_CERT" ]; then
  sh "$SCRIPT_DIR/generate-localhost-cert.sh"
fi

if [ ! -s "$LOCAL_TRUST_SCRIPT" ]; then
  printf '[certs] local trust helper is missing: %s\n' "$LOCAL_TRUST_SCRIPT" >&2
  exit 1
fi

first_word() {
  printf '%s\n' "$1" | awk '{ print $1 }'
}

default_gateway() {
  ip route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

append_unique_word() {
  current=$1
  candidate=$2
  [ -n "$candidate" ] || return 0
  case " $current " in
    *" $candidate "*) printf '%s\n' "$current" ;;
    *) printf '%s\n' "${current}${current:+ }$candidate" ;;
  esac
}

split_target_port() {
  PARSED_TARGET=$1
  PARSED_PORT=""
  case "$PARSED_TARGET" in
    *:*:*)
      return 0
      ;;
    *:*)
      maybe_port=${PARSED_TARGET##*:}
      maybe_target=${PARSED_TARGET%:*}
      case "$maybe_port" in
        ''|*[!0-9]*) ;;
        *)
          PARSED_TARGET=$maybe_target
          PARSED_PORT=$maybe_port
          ;;
      esac
      ;;
  esac
}

if [ -z "$SSH_PORTS" ]; then
  if [ -n "$SSH_PORT" ]; then
    SSH_PORTS=$SSH_PORT
  else
    SSH_PORTS="22 2222"
  fi
fi

if [ -z "$SSH_USERS" ]; then
  SSH_USERS=$SSH_USER
fi

CANDIDATE_HOSTS=""
if [ -n "$SSH_TARGET" ]; then
  CANDIDATE_HOSTS=$(append_unique_word "$CANDIDATE_HOSTS" "$SSH_TARGET")
else
  if [ -n "${SSH_CONNECTION:-}" ]; then
    CANDIDATE_HOSTS=$(append_unique_word "$CANDIDATE_HOSTS" "$(first_word "$SSH_CONNECTION")")
  fi
  CANDIDATE_HOSTS=$(append_unique_word "$CANDIDATE_HOSTS" "$(default_gateway)")
fi

if [ -z "$CANDIDATE_HOSTS" ]; then
  printf '[certs] no browser-host SSH target detected. Set TRACK_BINOCLE_BROWSER_HOST=user@host to enable remote browser trust.\n'
  [ "$REQUIRED" = 1 ] && exit 1
  exit 0
fi

BASE_SSH_ARGS="-T -o RequestTTY=no -o BatchMode=yes -o ConnectTimeout=$CONNECT_TIMEOUT -o StrictHostKeyChecking=accept-new"
BASE_SCP_ARGS="-o BatchMode=yes -o ConnectTimeout=$CONNECT_TIMEOUT -o StrictHostKeyChecking=accept-new"
if [ -n "${TRACK_BINOCLE_BROWSER_HOST_SSH_OPTS:-}" ]; then
  BASE_SSH_ARGS="$BASE_SSH_ARGS $TRACK_BINOCLE_BROWSER_HOST_SSH_OPTS"
  BASE_SCP_ARGS="$BASE_SCP_ARGS $TRACK_BINOCLE_BROWSER_HOST_SSH_OPTS"
fi

PROBE_OUTPUT=/tmp/track-binocle-browser-host-probe.$$
trap 'rm -f "$PROBE_OUTPUT"' EXIT HUP INT TERM
SELECTED_TARGET=""
SELECTED_SSH_ARGS=""
SELECTED_SCP_ARGS=""

for candidate_host in $CANDIDATE_HOSTS; do
  split_target_port "$candidate_host"
  candidate_ports=${PARSED_PORT:-$SSH_PORTS}
  candidate_targets=""
  case "$PARSED_TARGET" in
    *@*)
      candidate_targets=$PARSED_TARGET
      ;;
    *)
      for candidate_user in $SSH_USERS; do
        if [ -n "$candidate_user" ]; then
          candidate_targets=$(append_unique_word "$candidate_targets" "$candidate_user@$PARSED_TARGET")
        fi
      done
      candidate_targets=$(append_unique_word "$candidate_targets" "$PARSED_TARGET")
      ;;
  esac

  for candidate_target in $candidate_targets; do
    for candidate_port in $candidate_ports; do
      SSH_ARGS="$BASE_SSH_ARGS -p $candidate_port"
      SCP_ARGS="$BASE_SCP_ARGS -P $candidate_port"
      printf '[certs] probing browser host SSH target: %s:%s\n' "$candidate_target" "$candidate_port"
      if ssh $SSH_ARGS "$candidate_target" 'printf "[certs] browser host reachable: %s@%s (%s)\n" "$(id -un)" "$(hostname)" "$(uname -s)"' >"$PROBE_OUTPUT" 2>&1; then
        SELECTED_TARGET=$candidate_target
        SELECTED_SSH_ARGS=$SSH_ARGS
        SELECTED_SCP_ARGS=$SCP_ARGS
        cat "$PROBE_OUTPUT"
        break 3
      fi
    done
  done
done

if [ -z "$SELECTED_TARGET" ]; then
  cat "$PROBE_OUTPUT" >&2 || true
  printf '[certs] browser host SSH target is not reachable.\n' >&2
  printf '[certs] Auto-detected candidates: %s\n' "$CANDIDATE_HOSTS" >&2
  printf '[certs] Set TRACK_BINOCLE_BROWSER_HOST=user@host and TRACK_BINOCLE_BROWSER_HOST_PORT=port when a back-to-host SSH route exists.\n' >&2
  [ "$REQUIRED" = 1 ] && exit 1
  exit 0
fi

if ssh $SELECTED_SSH_ARGS "$SELECTED_TARGET" "mkdir -p '$REMOTE_CERT_DIR'" \
  && scp $SELECTED_SCP_ARGS "$CA_CERT" "$LOCAL_TRUST_SCRIPT" "$SELECTED_TARGET:$REMOTE_CERT_DIR/" \
  && ssh $SELECTED_SSH_ARGS "$SELECTED_TARGET" "TRACK_BINOCLE_CERT_DIR='$REMOTE_CERT_DIR' sh '$REMOTE_CERT_DIR/$(basename "$LOCAL_TRUST_SCRIPT")' --system"; then
  printf '[certs] browser host trust import completed through %s.\n' "$SELECTED_TARGET"
  exit 0
fi

printf '[certs] browser host trust import failed through %s.\n' "$SELECTED_TARGET" >&2
printf '[certs] VM-side trust is still configured; rerun with TRACK_BINOCLE_BROWSER_HOST_REQUIRED=1 if this must be fatal.\n' >&2
[ "$REQUIRED" = 1 ] && exit 1
exit 0
