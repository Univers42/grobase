# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    pin-digests.sh                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/pin-digests.sh
# Pin base images to SHA256 digests for reproducible production builds
# Usage: bash scripts/pin-digests.sh
#
# Reads all FROM statements in Dockerfiles, resolves their current
# digests via `docker manifest inspect`, and creates pinned versions
# in dockerfiles.pinned/

set -euo pipefail
readonly SEP_LINE='═══════════════════════════════════════════'

PINNED_DIR="dockerfiles.pinned"
mkdir -p "$PINNED_DIR"

echo "$SEP_LINE"
echo " Pin Base Image Digests"
echo "$SEP_LINE"
echo ""

# Find all Dockerfiles
mapfile -t DOCKERFILES < <(find docker/services -name 'Dockerfile' -type f | sort)

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "No Dockerfiles found in docker/services/"
  exit 1
fi

declare -A DIGEST_CACHE

resolve_digest() {
  local image="$1"

  # Skip AS aliases and scratch
  if [[ "$image" == "scratch" ]] || [[ "$image" =~ ^[a-z_]+$ && ! "$image" =~ [/:] ]]; then
    echo ""
    return
  fi

  # Already has digest
  if [[ "$image" == *"@sha256:"* ]]; then
    echo "$image"
    return
  fi

  # Check cache
  if [[ -n "${DIGEST_CACHE[$image]:-}" ]]; then
    echo "${DIGEST_CACHE[$image]}"
    return
  fi

  # Resolve via docker manifest inspect
  local digest
  digest=$(docker manifest inspect "$image" 2>/dev/null | \
    grep -m1 '"digest"' | awk -F'"' '{print $4}') || true

  if [[ -n "$digest" ]]; then
    local base="${image%%:*}"
    local pinned="${base}@${digest}"
    DIGEST_CACHE["$image"]="$pinned"
    echo "$pinned"
  else
    echo ""
  fi
  return 0
}

for df in "${DOCKERFILES[@]}"; do
  rel_path="${df#docker/services/}"
  service="${rel_path%%/*}"
  out_dir="$PINNED_DIR/$service"
  mkdir -p "$out_dir"

  echo "Processing: $df"

  cp "$df" "$out_dir/Dockerfile"

  # Find FROM lines and pin them
  while IFS= read -r line; do
    if [[ "$line" =~ ^FROM[[:space:]]+([^[:space:]]+) ]]; then
      image="${BASH_REMATCH[1]}"
      pinned=$(resolve_digest "$image")

      if [[ -n "$pinned" && "$pinned" != "$image" ]]; then
        sed -i "s|FROM ${image}|FROM ${pinned}  # was: ${image}|g" "$out_dir/Dockerfile"
        echo "  Pinned: $image -> $pinned"
      else
        echo "  Skipped: $image (already pinned or unresolvable)"
      fi
    fi
  done < "$df"

  echo ""
done

echo "$SEP_LINE"
echo " Pinned Dockerfiles written to $PINNED_DIR/"
echo "$SEP_LINE"
echo ""
echo "To use pinned versions, copy from $PINNED_DIR/ back to docker/services/"
