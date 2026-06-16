# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    trust-chrome-cert.sh                               :+:      :+:    :+:    #
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
CA_DIR=${TRACK_BINOCLE_CERT_DIR:-"$REPO_DIR/certs"}
CA_CERT="$CA_DIR/track-binocle-local-ca.pem"

if [ ! -s "$CA_CERT" ]; then
  echo "CA not found at $CA_CERT" >&2
  exit 2
fi

# This script imports the given CA into Chromium/Chrome profile NSS DBs
# and also explains how to add it to the system store for Chrome/Electron.

resolve() {
  command -v "$1" 2>/dev/null || true
}

CERTUTIL=$(resolve certutil)
if [ -z "$CERTUTIL" ]; then
  echo "certutil not found. See docs: download libnss3-tools and extract certutil." >&2
  exit 3
fi

echo "Using certutil: $CERTUTIL"

trust_existing_nss_db() {
  db_dir=$1
  [ -f "$db_dir/cert9.db" ] || return 0
  "$CERTUTIL" -D -d "sql:$db_dir" -n "Track Binocle Local Development CA" >/dev/null 2>&1 || true
  "$CERTUTIL" -A -d "sql:$db_dir" -n "Track Binocle Local Development CA" -t "C,," -i "$CA_CERT"
  printf 'Trusted local CA in NSS database: %s\n' "$db_dir"
}

# Search common Chromium profile paths
for search_root in "$HOME/.config/chromium" "$HOME/.config/google-chrome" "$HOME/.config/microsoft-edge" "$HOME/.config/BraveSoftware"; do
  [ -d "$search_root" ] || continue
  find "$search_root" -type f -name cert9.db -print 2>/dev/null | while IFS= read -r cert_db; do
    db_dir=$(dirname "$cert_db")
    trust_existing_nss_db "$db_dir"
  done
done

echo "Note: Chrome may also use the system CA store. To add system trust (requires sudo):"
echo "  sudo cp '$CA_CERT' /usr/local/share/ca-certificates/track-binocle-local-ca.crt && sudo update-ca-certificates"

echo "Done. Fully quit Chrome/Chromium and reopen https://localhost:4322"

exit 0
