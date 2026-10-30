# shellcheck shell=bash
# lib-overlay-render.sh — the static half shared by the overlay gates (m262, m263): a
# compose render as JSON, a Makefile variable as make expands it, and the cloud overlay
# with its gitignored env_file stubbed. The caller sets ROOT and WORK, defines fail, and
# exports any *_CERT_DIR its overlays interpolate.
#
# Caveat: render reads `docker compose config`, so it proves what compose would run, not
# what a running stack does; make_var blanks the overlay switches a host .env.local may
# set, so a gate never inherits the operator's choice.

# render OUT FILE... — every profile's config as JSON, base docker-compose.yml first.
render() {
  local out="$1" f
  local -a files=(-f "${ROOT}/docker-compose.yml")
  shift
  for f in "$@"; do
    [[ "${f}" == /* ]] || f="${ROOT}/${f}"
    files+=(-f "${f}")
  done
  docker compose --project-directory "${ROOT}" "${files[@]}" \
    --profile '*' config --format json >"${WORK}/${out}" 2>"${WORK}/render.err" ||
    fail "compose cannot render ${out}: $(head -c 300 "${WORK}/render.err")"
}

# make_var NAME [MAKE_ARGS...] — a variable as the Makefile expands it.
make_var() {
  local name="$1"
  shift
  make -s --no-print-directory -C "${ROOT}" ENGINE_TLS_ENGINES= CLOUD= "$@" \
    --eval "overlay-var: ; @echo \$(${name})" overlay-var 2>&1
}

# cloud_stub — a copy of the cloud overlay with its flags.env.cloud env_file pointed at a
# one-key stub, as m195 does: the real file is gitignored and absent on a fresh clone.
cloud_stub() {
  printf 'OVERLAY_CLOUD_SENTINEL=1\n' >"${WORK}/flags.env.cloud"
  sed "s#infra/config/cloud/flags\.env\.cloud#${WORK}/flags.env.cloud#g" \
    "${ROOT}/orchestrators/compose/docker-compose.cloud.yml" >"${WORK}/cloud.yml"
  printf '%s' "${WORK}/cloud.yml"
}
