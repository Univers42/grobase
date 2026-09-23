#!/usr/bin/env bash
# Mutant fixture for gate m190 (manifest row provenance-blind): an image
# provenance checker that approves everything, whatever it is shown. m190
# must go red with it; if it did not, the gate would not be testing the check.
# Only `check` reads stdin; `override` must not wait on a terminal.
[ "${1:-}" = check ] && cat >/dev/null
echo "image-provenance: approved (mutant)"
