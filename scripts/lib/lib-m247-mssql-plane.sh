# shellcheck shell=bash
# lib-m247-mssql-plane.sh — the data-plane half of mssql engine TLS in
# scripts/verify/m247-engine-tls.sh (docs/adr/0027-g5-mssql-verified-data-plane.md, devil
# g5-tls-insecure-default D1–D9). Sourced by m247 only: it uses m247's dc, ROOT, WORK and
# pass/fail/step. Sets no shell options.
#
# The VM gets DATA_PLANE_TLS_INSECURE=1 from the compose default alone and holds the local
# CA, so a flipped default, or a flip keyed on the local CA, would flip the VM at its next
# data-plane recreate. Hence: the default stays 1, and 0 lives only in the mssql overlay.

MSSQL_PLANE_OVERLAY="orchestrators/compose/docker-compose.engine-tls-mssql.yml"

# D1: both compose defaults keep the escape on.
mssql_plane_defaults_stay_insecure() {
  local file
  for file in orchestrators/compose/base/data-plane.yml orchestrators/compose/docker-compose.monolith.yml; do
    grep -qxF '      DATA_PLANE_TLS_INSECURE: ${DATA_PLANE_TLS_INSECURE:-1}' "${ROOT}/${file}" ||
      fail "${file}: the DATA_PLANE_TLS_INSECURE default is no longer 1 (D1, verdict g5-tls-insecure-default)"
  done
}

# D2, D3: the overlay flips the data plane and pins the mssql engine's ca.pem, one file, read-only.
mssql_plane_overlay_pins_engine_ca() {
  local plane
  plane="$(sed -n '/^  data-plane-router-rust:/,/^  [a-z]/p' "${ROOT}/${MSSQL_PLANE_OVERLAY}")"
  grep -qxF '      DATA_PLANE_TLS_INSECURE: "0"' <<<"${plane}" || fail "the mssql overlay does not turn the escape off (D2)"
  grep -qxF '      DATA_PLANE_TLS_CA_FILE: /etc/engine-tls-ca/mssql-ca.pem' <<<"${plane}" ||
    fail "the mssql overlay does not point the data plane at the mounted CA (D2)"
  grep -qxF '        source: ${ENGINE_TLS_MSSQL_CERT_DIR:-./certs/engine-tls/mssql}/ca.pem' <<<"${plane}" ||
    fail "the data plane CA is not the mssql engine's ca.pem (D2)"
  ! grep -q 'track-binocle-local-ca' <<<"${plane}" || fail "the data plane mounts the local CA (D2: it would flip the VM)"
  grep -qxF '        target: /etc/engine-tls-ca/mssql-ca.pem' <<<"${plane}" || fail "the CA mount is not one .pem file (D3)"
  grep -qxF '        read_only: true' <<<"${plane}" || fail "the CA mount is writable (D3)"
  grep -qxF '          create_host_path: false' <<<"${plane}" || fail "the CA bind would be created root-owned (D3)"
}

# D8: no committed config, env template or compose file sets 0, the overlay aside.
mssql_plane_no_committed_zero() {
  local hits
  hits="$(git -C "${ROOT}" grep -lE 'DATA_PLANE_TLS_INSECURE"?[:=] *"?0' -- \
    '*.env' '*.env.*' '*.example' '*.yml' '*.yaml' '*.toml' '*.json' "config.env" \
    ":!${MSSQL_PLANE_OVERLAY}" || true)"
  [[ -z "${hits}" ]] || fail "committed config sets DATA_PLANE_TLS_INSECURE=0 outside the mssql overlay (D8): ${hits}"
}

mssql_plane_static_checks() {
  step "static: the data plane verifies mssql only under the mssql overlay"
  mssql_plane_defaults_stay_insecure
  mssql_plane_overlay_pins_engine_ca
  mssql_plane_no_committed_zero
  pass "defaults stay INSECURE=1, the overlay alone sets 0 and pins certs/engine-tls/mssql/ca.pem read-only"
}

# D9: the rendered data plane, without and with the overlay. Dropping the file is the rollback.
mssql_plane_render_checks() {
  local plain overlaid
  step "render: the overlay flips the data plane, dropping it restores INSECURE=1"
  plain="$(dc config data-plane-router-rust)" || fail "the default data plane does not render"
  overlaid="$(dc -f "${ROOT}/${MSSQL_PLANE_OVERLAY}" config data-plane-router-rust)" || fail "the overlaid data plane does not render"
  grep -qxF '      DATA_PLANE_TLS_INSECURE: "1"' <<<"${plain}" || fail "without the overlay the data plane is not INSECURE=1 (D9)"
  grep -qxF '      DATA_PLANE_TLS_CA_FILE: ""' <<<"${plain}" || fail "without the overlay the data plane pins a CA (D9)"
  grep -qxF '      DATA_PLANE_TLS_INSECURE: "0"' <<<"${overlaid}" || fail "the overlaid data plane is not INSECURE=0 (D2)"
  grep -qF "source: ${ENGINE_TLS_MSSQL_CERT_DIR}/ca.pem" <<<"${overlaid}" || fail "the overlaid data plane does not mount the engine CA"
  pass "default render INSECURE=1 and no CA; overlaid render INSECURE=0 with ${ENGINE_TLS_MSSQL_CERT_DIR##*/}/ca.pem"
}
