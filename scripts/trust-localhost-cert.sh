#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CERT_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_CERT="$CERT_DIR/track-binocle-local-ca.pem"
CA_NICKNAME="Track Binocle Local Development CA"
INSTALL_SYSTEM=0

for arg in "$@"; do
  case "$arg" in
    --system)
      INSTALL_SYSTEM=1
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--system]

Imports the Track Binocle local development CA into user browser trust stores.
Use --system to also install it into the Linux system CA store with sudo.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -s "$CA_CERT" ]; then
  sh "$SCRIPT_DIR/generate-localhost-cert.sh"
fi

ensure_nss_db() {
  db_dir=$1
  mkdir -p "$db_dir"
  if [ ! -f "$db_dir/cert9.db" ]; then
    certutil -N -d "sql:$db_dir" --empty-password >/dev/null 2>&1
  fi
}

trust_nss_db() {
  db_dir=$1
  ensure_nss_db "$db_dir"
  certutil -D -d "sql:$db_dir" -n "$CA_NICKNAME" >/dev/null 2>&1 || true
  certutil -A -d "sql:$db_dir" -n "$CA_NICKNAME" -t "C,," -i "$CA_CERT"
  printf 'Trusted local CA in NSS database: %s\n' "$db_dir"
}

if ! command -v certutil >/dev/null 2>&1; then
  printf 'certutil is required to trust the CA in Chromium/Firefox NSS stores.\n' >&2
  printf 'Install libnss3-tools, or rerun with --system and restart the browser.\n' >&2
  exit 1
fi

trust_nss_db "$HOME/.pki/nssdb"

if [ -d "$HOME/.mozilla/firefox" ]; then
  find "$HOME/.mozilla/firefox" -maxdepth 1 -type d \( -name '*.default' -o -name '*.default-release' -o -name '*.default-esr' -o -name '*.dev-edition-default' \) | while IFS= read -r profile_dir; do
    trust_nss_db "$profile_dir"
  done
fi

if [ "$INSTALL_SYSTEM" -eq 1 ]; then
  if [ "$(id -u)" -eq 0 ]; then
    cp "$CA_CERT" /usr/local/share/ca-certificates/track-binocle-local-ca.crt
    update-ca-certificates
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp "$CA_CERT" /usr/local/share/ca-certificates/track-binocle-local-ca.crt
    sudo update-ca-certificates
  else
    printf 'sudo is required for --system on this machine.\n' >&2
    exit 1
  fi
  printf 'Trusted local CA in the Linux system CA store.\n'
fi

printf '\nDone. Fully quit and restart Chrome/Chromium/Firefox, then open https://localhost:4322/.\n'
