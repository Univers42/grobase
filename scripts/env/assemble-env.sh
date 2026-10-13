#!/usr/bin/env bash
# Assemble .env from the three source layers (later overrides earlier):
#   config.env    committed, non-secret config
#   .env.secrets  generated secrets   (minted by generate-env.sh if absent)
#   .env.local    optional API keys + per-developer overrides
#
# `.env` is a BUILD PRODUCT of those three files and 96 compose services read it,
# so a key that lives only in `.env` is a key the next `make env` drops without a
# word — measured 2026-10-13 on an `.env` holding 10 keys its `.env.local` no
# longer had. Two guards, both naming keys and never values:
#
#   orphans_secrets   a value only the old .env held is put BACK into .env.secrets
#                     before any top-up, so an initialized database volume is
#                     never handed a re-minted password.
#   orphans_local     a key no source layer holds any more is REFUSED; the caller
#                     picks ENV_ORPHANS=carry (back into .env.local) or
#                     ENV_ORPHANS=drop (assemble without it).
#
# Credentials meant for the host (GitHub, deploy) are withheld from .env on the
# way in; the previous .env is kept as .env.prev, so every run is undoable by hand.
set -euo pipefail
# Every file written here holds secrets. With the host's umask (0002 here) each
# one was group/world-readable from its creation until the chmod 600 after it.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.." # repo root
# shellcheck source=../lib/lib-dotenv.sh
. "${SCRIPT_DIR}/../lib/lib-dotenv.sh"

CONFIG="config.env"
SECRETS=".env.secrets"
LOCAL=".env.local"
OUT=".env"
PREV=".env.prev"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DATE_ONLY="${NOW%%T*}"

# The generated key set lives in generate-env.sh next to the values it mints and
# is READ from there (one sed, the file is never sourced): a hand-kept copy here
# went stale and the migration re-minted MYSQL/MARIADB/MSSQL passwords a live
# volume had already been initialized with.
GENERATED_KEYS="$(sed -n 's/^GENERATED_KEYS="\(.*\)"$/\1/p' "${SCRIPT_DIR}/generate-env.sh")"
[ -n "$GENERATED_KEYS" ] || {
  echo "Error: no GENERATED_KEYS line in scripts/env/generate-env.sh — refusing to guess the secrets migration." >&2
  exit 1
}
OPTIONAL_KEYS="GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GITHUB_CLIENT_ID \
GITHUB_CLIENT_SECRET FORTYTWO_CLIENT_ID FORTYTWO_CLIENT_SECRET SMTP_USER SMTP_PASS \
LLM_API_KEY GDPR_DELETION_WEBHOOK_URL GDPR_EXPORT_WEBHOOK_URL SONAR_TOKEN"

[ -f "$CONFIG" ] || {
  echo "Error: $CONFIG missing (the committed config layer)." >&2
  exit 1
}

# ── ENV_ORPHANS is validated before anything is read or written ─────────────
ENV_ORPHANS="${ENV_ORPHANS:-}"
case "$ENV_ORPHANS" in
'' | carry | drop) ;;
*)
  echo "Error: unknown ENV_ORPHANS=${ENV_ORPHANS}: carry or drop" >&2
  exit 1
  ;;
esac

# ── read the old $OUT BEFORE anything rewrites a layer ──────────────────────
# The sections carry the provenance: a config value that left config.env was
# dropped on purpose, a secrets value has to go back or it gets re-minted, and a
# local value that left .env.local is the silent-loss case `make env` refuses.
# A legacy flat .env (no markers at all) has no provenance: only the generated
# keys can be told apart, the rest is treated as a local override.
# ASSEMBLED_DROPPED: keys the config layer no longer carries — named, dropped.
# ASSEMBLED_SECRETS: old lines to put back into .env.secrets before any top-up.
# ASSEMBLED_DRIFT:   secrets keys whose two copies disagree — named, not refused.
# ASSEMBLED_LOCAL:   old lines .env.local lost — refused unless the caller chose.
# Every bucket holds the LINE, never the name: names_of reads the name off the
# `=` and a stored bare name would print as nothing.
ASSEMBLED_DROPPED=()
ASSEMBLED_SECRETS=()
ASSEMBLED_DRIFT=()
ASSEMBLED_LOCAL=()

# classify_old_key KEY — file one key of the old .env into exactly one bucket.
# Never exits: a `KEY=` nobody filled in and a key a source layer still holds are
# both "nothing to do", and only orphans_local is fatal (further down).
classify_old_key() {
  local key="$1" line="${OLD_LINE[$1]}" section="${OLD_SECTION[$1]}" value current
  value="$(unquote "${line#*=}")"
  [ -n "$value" ] || return 0
  case "$section" in
  config) # config.env is authoritative: a key it dropped was dropped on purpose
    # (unless another layer took it over, which keeps it in .env — not a drop)
    assigns "$CONFIG" "$key" || assigns "$SECRETS" "$key" || assigns "$LOCAL" "$key" ||
      ASSEMBLED_DROPPED+=("$line")
    return 0
    ;;
  secrets)
    current="$(env_value "$SECRETS" "$key")"
    if [ -z "$current" ]; then
      ASSEMBLED_SECRETS+=("$line") # the last copy left: back in, never re-minted
    elif [ "$current" != "$value" ]; then
      ASSEMBLED_DRIFT+=("$line")
    fi
    return 0
    ;;
  esac
  assigns "$CONFIG" "$key" && return 0
  assigns "$SECRETS" "$key" && return 0
  assigns "$LOCAL" "$key" && return 0
  # A flat legacy .env has no provenance: a generated key goes back into
  # .env.secrets (a re-mint would break an initialized volume), and any other key
  # no layer holds is a local override like the rest — refused, never dropped.
  if [ "$section" = none ]; then
    case " $GENERATED_KEYS " in *" $key "*)
      ASSEMBLED_SECRETS+=("$line")
      return 0
      ;;
    esac
  fi
  ASSEMBLED_LOCAL+=("$line")
}

if [ -f "$OUT" ]; then
  declare -A OLD_SECTION=() OLD_LINE=()
  section=none # until a section marker says otherwise; a flat legacy file stays none
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "# ========== $CONFIG ==========") section=config ;;
    "# ========== $SECRETS ==========") section=secrets ;;
    "# ========== $LOCAL ==========") section=local ;;
    esac
    key="$(key_of "$line")"
    [ -n "$key" ] || continue # comment, blank, or a withheld `# KEY= (...)` line
    OLD_SECTION[$key]="$section"
    OLD_LINE[$key]="$line" # last assignment wins, as in every dotenv reader
  done <"$OUT"
  for key in "${!OLD_SECTION[@]}"; do
    classify_old_key "$key"
  done
fi

# ── 0. orphans_local: refuse before touching a single file ──────────────────
if [ "${#ASSEMBLED_LOCAL[@]}" -gt 0 ]; then
  if [ "$ENV_ORPHANS" = drop ]; then
    echo "Dropping ${#ASSEMBLED_LOCAL[@]} orphaned key(s) from $OUT: $(names_of "${ASSEMBLED_LOCAL[@]}")" >&2
  elif [ "$ENV_ORPHANS" != carry ]; then
    {
      echo "Error: $OUT holds key(s) that config.env, $SECRETS and $LOCAL do not:"
      for line in "${ASSEMBLED_LOCAL[@]}"; do
        echo "  $(key_of "$line")"
      done
      echo "They would be dropped without a word. Choose one:"
      echo "  ENV_ORPHANS=carry   append them verbatim to $LOCAL, then assemble"
      echo "  ENV_ORPHANS=drop    assemble without them (the lines stay in $PREV)"
      echo "Note: scripts/vault/vault-env.mjs rewrites $LOCAL on every fetch and strips the keys it manages, so a carried key it manages is refused again after the next fetch."
    } >&2
    exit 1
  fi
fi
if [ "${#ASSEMBLED_DROPPED[@]}" -gt 0 ]; then
  echo "Dropped ${#ASSEMBLED_DROPPED[@]} key(s) removed from config.env: $(names_of "${ASSEMBLED_DROPPED[@]}")" >&2
fi

# ── 1. secrets layer ───────────────────────────────────────────────────────
# A key the old .env still holds and .env.secrets does not goes BACK into
# .env.secrets (never over a file that already has it), then generate-env.sh
# --topup mints only what is still missing. The old code migrated first and
# top-up second while lifting 15 of the 22 generated keys, so the top-up
# re-minted MYSQL/MARIADB/MSSQL/... passwords a live volume already had.
for line in ${ASSEMBLED_SECRETS[@]+"${ASSEMBLED_SECRETS[@]}"}; do
  key="$(key_of "$line")"
  assigns "$SECRETS" "$key" && continue
  assigns "$LOCAL" "$key" && continue # a local override wins anyway; no duplicate
  # .env.secrets FEEDS .env, so restoring one of these here is the same leak with
  # an extra hop. Named, not restored: the host tool reads it from .env.local.
  if is_host_only "$key" || is_gh_token "$key" "${line#*=}"; then
    echo "Not restoring $key into $SECRETS: that file feeds $OUT, which every container reads. Put it back in $LOCAL." >&2
    continue
  fi
  if [ ! -f "$SECRETS" ]; then
    echo "# Migrated from $OUT on $NOW — auto-generated secrets, gitignored, mode 600." >"$SECRETS"
    chmod 600 "$SECRETS"
    echo "Migrating secrets from legacy $OUT -> $SECRETS" >&2
  fi
  printf '%s\n' "$(bare_line "$line")" >>"$SECRETS"
  echo "Restored $key into $SECRETS from the old $OUT (not re-minted)." >&2
done
# Named, not refused: FORCE=1 rotation is legitimate, a surprise is not.
if [ "${#ASSEMBLED_DRIFT[@]}" -gt 0 ]; then
  {
    echo "Warning: $(names_of "${ASSEMBLED_DRIFT[@]}") — the old $OUT and $SECRETS disagree."
    echo "  $SECRETS wins (it is what the running stack uses). Deliberate rotation is"
    echo "  fine; if it is not one, the old values are still in $PREV."
  } >&2
fi
[ -f "$SECRETS" ] || bash scripts/env/generate-env.sh "$SECRETS"
bash scripts/env/generate-env.sh --topup "$SECRETS" >/dev/null

# ── 2. optional local layer ────────────────────────────────────────────────
if [ ! -f "$LOCAL" ]; then
  {
    echo "# $LOCAL — optional API keys + per-developer overrides (gitignored)."
    echo "# See .env.local.example. Appended last, so it overrides config/secrets."
    if [ -f "$OUT" ]; then
      for k in $OPTIONAL_KEYS; do
        [ -n "$(env_value "$OUT" "$k")" ] || continue # carry over only non-empty
        printf '%s\n' "$(bare_line "$(raw_value "$OUT" "$k")")"
      done
    fi
  } >"$LOCAL"
  chmod 600 "$LOCAL"
fi
# carry runs here, after the OPTIONAL_KEYS migration above, so a first run keeps
# both. The header carries the date because a later `make env` cannot tell a
# carried line from one the developer typed.
if [ "${#ASSEMBLED_LOCAL[@]}" -gt 0 ] && [ "$ENV_ORPHANS" = carry ]; then
  {
    echo "# Carried from .env by make env on $DATE_ONLY — no source layer held them."
    printf '%s\n' "${ASSEMBLED_LOCAL[@]}"
  } >>"$LOCAL"
  chmod 600 "$LOCAL"
  echo "Carried ${#ASSEMBLED_LOCAL[@]} key(s) into $LOCAL: $(names_of "${ASSEMBLED_LOCAL[@]}")" >&2
fi

# ── the local layer, with the two rules above applied line by line ─────────
local_layer() {
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    '#'* | '')
      printf '%s\n' "$line"
      continue
      ;;
    esac
    # key_of, not `${line%%=*}`: `export FLY_TOKEN=x` would otherwise key on the
    # literal string "export FLY_TOKEN" and walk straight into .env.
    key="$(key_of "$line")"
    if [ -z "$key" ]; then
      printf '%s\n' "$line" # not an assignment at all — pass it through
      continue
    fi
    val="${line#*=}"
    if is_host_only "$key"; then
      echo "WARNING: $LOCAL: $key is host-only -- withheld from $OUT (every container reads it). Its host tool reads it from $LOCAL directly." >&2
      printf '# %s= (host-only, withheld by assemble-env.sh; read from %s by its host tool)\n' "$key" "$LOCAL"
      continue
    fi
    if is_gh_token "$key" "$val"; then
      echo "WARNING: $LOCAL: $key looks like a GitHub token -- withheld from $OUT (every container reads it). Keep it in ~/.grobase-gh-pat (mode 600) and rotate the one that was here." >&2
      printf '# %s= (GitHub token withheld by assemble-env.sh; see ~/.grobase-gh-pat)\n' "$key"
      continue
    fi
    printf '%s\n' "$line"
  done <"$LOCAL"
}

# ── 3. assemble (config < secrets < local; duplicate keys: later wins) ────────
# The old .env is kept as .env.prev (.gitignore:6 covers it) and the new one is
# written beside it and moved in, so a reader never sees a half-written .env and
# a run that turns out wrong is undoable without git.
if [ -f "$OUT" ]; then
  cp -p "$OUT" "$PREV"
  chmod 600 "$PREV"
fi
{
  echo "# ASSEMBLED by 'make env' on $NOW — DO NOT EDIT THIS FILE."
  echo "# Edit the sources then re-run 'make env':"
  echo "#   $CONFIG (committed) · $SECRETS (generated) · $LOCAL (yours)"
  echo
  echo "# ========== $CONFIG =========="
  cat "$CONFIG"
  echo
  echo "# ========== $SECRETS =========="
  cat "$SECRETS"
  echo
  echo "# ========== $LOCAL =========="
  local_layer
} >"$OUT.tmp"
chmod 600 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Assembled $OUT  ($CONFIG + $SECRETS + $LOCAL)"
