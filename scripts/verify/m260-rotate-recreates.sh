#!/usr/bin/env bash
# Gate (grobase#75): a secret rotation reaches the running services.
# rotate-secrets.sh writes the new value into .env; `docker compose restart` kept each
# container's old environment, so the old secret stayed live and a failed restart was
# hidden by `|| true`. This gate runs the script's own restart_services against a fake
# `docker` on PATH and asserts it recreates (up -d --no-deps --no-build --force-recreate
# <services>) and returns non-zero when compose fails. No stack, no Vault.
# Caveat: restart_services is cut out of the script with sed, from its `restart_services() {`
# line to the next line that is a lone `}`; a rewrite that nests a lone `}` inside it
# would cut it short, and the gate then fails on the missing call rather than passing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/infra/docker/services/vault/scripts/rotate-secrets.sh"
FAILED=0
ok() { echo "[M260] OK — $*"; }
bad() {
  echo "[M260] FAIL — $*"
  FAILED=1
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fn="$(sed -n '/^restart_services() {$/,/^}$/p' "${SCRIPT}")"
[ -n "${fn}" ] || {
  bad "restart_services() not found in ${SCRIPT}"
  exit 1
}

mkdir -p "${work}/bin"
cat >"${work}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${M260_CALLS}"
exit "${M260_DOCKER_RC:-0}"
FAKE
chmod +x "${work}/bin/docker"

# run_fn RC: run restart_services kong gotrue with the fake docker exiting RC.
run_fn() {
  : >"${work}/calls"
  PATH="${work}/bin:${PATH}" M260_CALLS="${work}/calls" M260_DOCKER_RC="$1" DRY_RUN=0 \
    bash -c 'log() { :; }; warn() { :; }; err() { echo "err: $*" >&2; }
      '"${fn}"'
      restart_services kong gotrue' 2>"${work}/stderr"
}

if run_fn 0; then
  calls="$(cat "${work}/calls")"
  if [ "${calls}" = "compose up -d --no-deps --no-build --force-recreate kong gotrue" ]; then
    ok "restart_services recreates the services (compose up -d --no-deps --no-build --force-recreate)"
  else
    bad "restart_services ran 'docker ${calls}', want 'docker compose up -d --no-deps --no-build --force-recreate kong gotrue'"
  fi
else
  bad "restart_services failed while compose succeeded"
fi

if run_fn 1; then
  bad "restart_services returned 0 while compose failed (a failed recreate must not be hidden)"
else
  grep -q "recreate failed" "${work}/stderr" && ok "a failed recreate returns non-zero and says so" ||
    bad "a failed recreate returned non-zero without naming the failure"
fi

if grep -nE '^[^#]*docker compose restart' "${SCRIPT}" >/dev/null; then
  bad "rotate-secrets.sh still calls 'docker compose restart' (keeps the old env)"
else
  ok "rotate-secrets.sh never calls 'docker compose restart'"
fi

exit "${FAILED}"
