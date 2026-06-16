# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    trust-localhost-cert.sh                            :+:      :+:    :+:    #
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
CA_NICKNAME="Track Binocle Local Development CA"
SYSTEM_CA_CERT="/usr/local/share/ca-certificates/track-binocle-local-ca.crt"
INSTALL_SYSTEM=0
AUTO_INSTALL_DEPS=${TRACK_BINOCLE_CERTS_INSTALL_DEPS:-auto}
FIREFOX_ENTERPRISE_ROOTS=${TRACK_BINOCLE_FIREFOX_ENTERPRISE_ROOTS:-1}

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
On Debian/Ubuntu, --system installs missing ca-certificates and libnss3-tools unless TRACK_BINOCLE_CERTS_INSTALL_DEPS=0.
Firefox profiles are also configured to read enterprise/system roots unless TRACK_BINOCLE_FIREFOX_ENTERPRISE_ROOTS=0.
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

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//;s/://g'
}

same_certificate() {
  [ -s "$1" ] && [ -s "$2" ] && [ "$(fingerprint "$1")" = "$(fingerprint "$2")" ]
}

resolve_command() {
  command_name=$1
  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return 0
  fi
  for command_dir in /usr/sbin /usr/bin /sbin /bin; do
    if [ -x "$command_dir/$command_name" ]; then
      printf '%s\n' "$command_dir/$command_name"
      return 0
    fi
  done
  return 1
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif sudo_path=$(resolve_command sudo); then
    "$sudo_path" "$@"
  else
    printf '[certs] sudo is required for --system on this machine.\n' >&2
    return 1
  fi
}

append_debian_package() {
  package=$1
  case " $DEBIAN_PACKAGES " in
    *" $package "*) ;;
    *) DEBIAN_PACKAGES="${DEBIAN_PACKAGES}${DEBIAN_PACKAGES:+ }$package" ;;
  esac
}

install_debian_packages() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  if ! apt_get_path=$(resolve_command apt-get); then
    return 1
  fi
  printf '[certs] Installing missing Debian packages: %s\n' "$*"
  run_as_root "$apt_get_path" update
  run_as_root env DEBIAN_FRONTEND=noninteractive "$apt_get_path" install -y --no-install-recommends "$@"
}

ensure_system_dependencies() {
  [ "$INSTALL_SYSTEM" -eq 1 ] || return 0

  DEBIAN_PACKAGES=""
  missing_certutil=0
  missing_system_store=0

  if ! resolve_command certutil >/dev/null 2>&1; then
    missing_certutil=1
    append_debian_package libnss3-tools
  fi
  if ! resolve_command update-ca-certificates >/dev/null 2>&1; then
    missing_system_store=1
    append_debian_package ca-certificates
  fi
  [ -n "$DEBIAN_PACKAGES" ] || return 0

  case "$AUTO_INSTALL_DEPS" in
    0|false|FALSE|no|NO)
      printf '[certs] Missing local certificate tooling: %s\n' "$DEBIAN_PACKAGES" >&2
      if [ "$missing_system_store" -eq 1 ]; then
        printf '[certs] Install ca-certificates, then rerun this script with --system.\n' >&2
        return 1
      fi
      printf '[certs] Browser NSS import will be skipped until libnss3-tools is installed.\n' >&2
      return 0
      ;;
  esac

  if install_debian_packages $DEBIAN_PACKAGES; then
    return 0
  fi

  if [ "$missing_system_store" -eq 1 ]; then
    printf '[certs] update-ca-certificates is missing; install ca-certificates, then rerun this script with --system.\n' >&2
    return 1
  fi
  if [ "$missing_certutil" -eq 1 ]; then
    printf '[certs] certutil is missing; install libnss3-tools to import the CA into Chromium/Firefox NSS stores.\n' >&2
  fi
  return 0
}

ensure_system_dependencies

ensure_nss_db() {
  db_dir=$1
  mkdir -p "$db_dir"
  if [ ! -f "$db_dir/cert9.db" ]; then
    "$CERTUTIL" -N -d "sql:$db_dir" --empty-password >/dev/null 2>&1
  fi
}

trust_nss_db() {
  db_dir=$1
  ensure_nss_db "$db_dir"
  "$CERTUTIL" -D -d "sql:$db_dir" -n "$CA_NICKNAME" >/dev/null 2>&1 || true
  "$CERTUTIL" -A -d "sql:$db_dir" -n "$CA_NICKNAME" -t "C,," -i "$CA_CERT"
  printf 'Trusted local CA in NSS database: %s\n' "$db_dir"
}

firefox_enterprise_roots_enabled() {
  case "$FIREFOX_ENTERPRISE_ROOTS" in
    0|false|FALSE|no|NO)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

set_firefox_enterprise_roots_pref() {
  profile_dir=$1
  firefox_enterprise_roots_enabled || return 0
  mkdir -p "$profile_dir"
  prefs_file="$profile_dir/user.js"
  tmp_file="$prefs_file.tmp.$$"

  if [ -f "$prefs_file" ]; then
    grep -v '^[[:space:]]*user_pref("security\.enterprise_roots\.enabled"' "$prefs_file" >"$tmp_file" || true
  else
    : >"$tmp_file"
  fi
  printf 'user_pref("security.enterprise_roots.enabled", true);\n' >>"$tmp_file"
  mv "$tmp_file" "$prefs_file"
  printf 'Enabled Firefox enterprise roots in profile: %s\n' "$profile_dir"
}

trust_firefox_profile() {
  profile_dir=$1
  trust_nss_db "$profile_dir"
  set_firefox_enterprise_roots_pref "$profile_dir"
}

trust_firefox_profiles_ini() {
  profiles_ini=$1
  base_dir=$(CDPATH= cd -- "$(dirname -- "$profiles_ini")" && pwd)
  awk '
    function emit() { if (path != "") print rel "|" path }
    /^\[/ { emit(); path=""; rel="1"; next }
    /^Path=/ { path=substr($0, 6); next }
    /^IsRelative=/ { rel=substr($0, 12); next }
    END { emit() }
  ' "$profiles_ini" | while IFS='|' read -r is_relative profile_path; do
    [ -n "$profile_path" ] || continue
    case "$profile_path" in
      /*)
        profile_dir=$profile_path
        ;;
      *)
        if [ "$is_relative" = "1" ]; then
          profile_dir="$base_dir/$profile_path"
        else
          profile_dir=$profile_path
        fi
        ;;
    esac
    trust_firefox_profile "$profile_dir"
  done
}

trust_firefox_profiles() {
  for profiles_ini in \
    "$HOME/.mozilla/firefox/profiles.ini" \
    "$HOME/snap/firefox/common/.mozilla/firefox/profiles.ini" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini"; do
    [ -f "$profiles_ini" ] || continue
    trust_firefox_profiles_ini "$profiles_ini"
  done

  for firefox_root in \
    "$HOME/.mozilla/firefox" \
    "$HOME/snap/firefox/common/.mozilla/firefox" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
    [ -d "$firefox_root" ] || continue
    [ ! -f "$firefox_root/profiles.ini" ] || continue
    find "$firefox_root" -type f -name cert9.db -print 2>/dev/null | while IFS= read -r cert_db; do
      trust_firefox_profile "$(dirname "$cert_db")"
    done
  done
}

warn_if_firefox_running() {
  if resolve_command pgrep >/dev/null 2>&1 \
    && { pgrep -x firefox >/dev/null 2>&1 || pgrep -f '/firefox/firefox' >/dev/null 2>&1; }; then
    printf '[certs] Firefox is running; fully quit every Firefox process before retesting localhost HTTPS.\n' >&2
  fi
}

if CERTUTIL=$(resolve_command certutil); then
  trust_nss_db "$HOME/.pki/nssdb"
  trust_firefox_profiles
  warn_if_firefox_running
else
  printf '[certs] certutil is required to trust the CA in Chromium/Firefox NSS stores.\n' >&2
  printf '[certs] Install libnss3-tools for browser profile import.\n' >&2
fi

if [ "$INSTALL_SYSTEM" -eq 1 ]; then
  if [ -s "$SYSTEM_CA_CERT" ] && same_certificate "$CA_CERT" "$SYSTEM_CA_CERT"; then
    printf '[certs] Linux system CA store already has the current Track Binocle CA.\n'
  else
    if ! UPDATE_CA_CERTIFICATES=$(resolve_command update-ca-certificates); then
      printf '[certs] update-ca-certificates is required for --system on this machine. Install ca-certificates.\n' >&2
      exit 1
    fi
    run_as_root cp "$CA_CERT" "$SYSTEM_CA_CERT"
    run_as_root "$UPDATE_CA_CERTIFICATES"
    printf 'Trusted local CA in the Linux system CA store.\n'
  fi
fi

printf '\nDone. Fully quit and restart Chrome/Chromium/Firefox, then open https://localhost:4322/.\n'
