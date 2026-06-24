#!/bin/sh
set -eu

if [ -z "${FLY_ACCESS_TOKEN:-}" ] && [ -n "${FLY_API_TOKEN:-}" ]; then
    export FLY_ACCESS_TOKEN="$FLY_API_TOKEN"
fi

exec "$@"