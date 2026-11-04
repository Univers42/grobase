#!/usr/bin/env bash
# set-seeds.sh — the team's data from vault42 into this stack, in the one order that works.
#
# WHY NOT `FETCH=1 make vault-restore`
#   That is the disaster-recovery path of a machine that already has its identity. This one runs
#   on a fresh clone: it needs 42ctl, a keystore and a session first, it must not overwrite a
#   platform that holds data, and it has to end with the stack it found. vault-restore's own
#   restart is `make up EDITION=devlean`, whose _rm-stale drops containers a PACKAGE=max stack never
#   gets back, so it runs here under SKIP_STACK_CYCLE=1 and this script owns the cycle.
#
# CREDENTIALS: ONE FILE
#   FT_CREDENTIALS (~/.config/42ctl/secrets/42admin.env): FT_PASSPHRASE, FT_EMAIL, FT_PASSWORD,
#   FT_TENANT, FT_KEYSTORE_B64, KEY=VALUE, read with sed and never sourced. Values stay in this
#   process's environment, off every command line and log.
#   Vault42 is zero-knowledge, so a login alone stops at "no keystore", and `keys recover` wants a
#   code from a mailbox. FT_KEYSTORE_B64 is that keystore, sealed by FT_PASSPHRASE, so carrying it
#   beside the passphrase costs nothing the file did not already hold.
#   `bash scripts/ops/set-seeds.sh --bundle` writes it, once, where the keystore exists.
#
# WHAT COMES FROM THE VAULT, AND WHAT DOES NOT
#   The rows, and the keys they were written under: JWT_SECRET, VAULT_ENC_KEY and the API keys,
#   which the apps' env files in the same vault carry too. A stack that kept its own could load
#   the data and read none of it. Never the engines' passwords: this .env stays the authority on
#   credentials, so no volume is wiped and no superuser password is rewritten
#   (vault-restore.sh: "A RESTORE MOVES DATA, NEVER CREDENTIALS").
#
# Caveat: the data is as old as the last `make vault-seed`. Its MANIFEST says when, and this
# prints it. "Populated" reads accounts, tenants and keys: an engine holding rows while those three
# tables are empty reads as empty.
#
# On success $STATE/seeds.last (~/.local/state/grobase) holds seeded_at, vintage, project and rows.
#
#   make set_seeds               fetch and load; a platform with data is left alone
#   make set_seeds FORCE=1       replace it, keeping a pre-restore dump in the state directory
#   set-seeds.sh --bundle        put the sealed keystore into the credentials file
set -u

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)" || exit 1

MODE=""
SHAPE=()
for arg in "$@"; do
  case "$arg" in
  --auto | --bundle) MODE=$arg ;;
  *) SHAPE+=("$arg") ;;
  esac
done
CRED="${FT_CREDENTIALS:-$HOME/.config/42ctl/secrets/42admin.env}"
SEEDS_ORG="${SEEDS_ORG:-univers42}"
PROJECT="${SEEDS_PROJECT:-groot}"
SEEDS_ENV="${SEEDS_ENV:-prod}"
SEEDS_BLOBSTORE="${SEEDS_BLOBSTORE:-https://fly.storage.tigris.dev}"
SEEDS_BUCKET="${SEEDS_BUCKET:-vault42-seeds}"
SEED_FILES="MANIFEST.json SHA256SUMS postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz redis.rdb mssql-all.tar.gz dynamodb-all.tar.gz sqlite-data.tar.gz"
FORCE="${SEEDS_FORCE:-0}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/grobase"
SEEDS="${SEEDS_DIR:-$STATE/seeds}"
KEYSTORE="${XDG_CONFIG_HOME:-$HOME/.config}/42ctl/keystore.v42"
CTL="${SEEDS_CTL:-}"
# Engine credentials and the URLs that embed them: this .env's, see the header.
ENGINE_CREDENTIALS="POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD DATABASE_URL PGRST_DB_URI ADAPTER_REGISTRY_DATABASE_URL MINIO_ROOT_PASSWORD MONGO_INITDB_ROOT_PASSWORD"
ENGINES_RUN="postgres mysql mongo redis minio mssql dynamodb-local"

note() { printf '[seeds] %s\n' "$*"; }
die() {
  printf '[seeds] ERROR: %s\n' "$*" >&2
  exit 1
}
# not_now <why>: a stop for a direct call, a line for `make all`, which deploys without data.
not_now() {
  [ "$MODE" = --auto ] || die "$1"
  note "no data loaded: $1"
  exit 0
}
cred() { sed -n "s/^$1=//p" "$CRED" | head -n1; }

# merge_secrets <this .env.secrets> <the vault's> <out>: this file with each key the vault also
# holds taking the vault's value, ENGINE_CREDENTIALS excepted. Not a replace: the vault's copy
# predates keys this stack minted.
merge_secrets() {
  awk -v keep=" $ENGINE_CREDENTIALS " '
    { k = $0; sub(/=.*/, "", k) }
    NR == FNR { if (k != $0 && !index(keep, " " k " ")) vault[k] = $0; next }
    k in vault { print vault[k]; seen[k] = 1; next }
    { print }
    END { for (k in vault) if (!(k in seen)) print vault[k] }
  ' "$2" "$1" >"$3"
}

# platform_rows: accounts, tenants and keys together, or nothing when Postgres cannot say.
platform_rows() {
  docker exec mini-baas-postgres psql -U postgres -tA -c \
    "select (select count(*) from auth.users) + (select count(*) from public.tenants) + (select count(*) from public.tenant_api_keys)" 2>/dev/null | tail -n1
}

[ -r "$CRED" ] || not_now "no credentials at $CRED (FT_CREDENTIALS=)"

if [ "$MODE" = --bundle ]; then
  [ -s "$KEYSTORE" ] || die "no keystore at $KEYSTORE to carry: run this where one exists"
  tmp=$(mktemp "$CRED.XXXXXX") || die "cannot write beside $CRED"
  grep -v '^FT_KEYSTORE_B64=' "$CRED" >"$tmp"
  printf 'FT_KEYSTORE_B64=%s\n' "$(base64 -w0 "$KEYSTORE")" >>"$tmp"
  chmod 600 "$tmp" || die "could not protect $tmp"
  mv "$tmp" "$CRED" || die "could not update $CRED"
  note "$CRED now carries the sealed keystore, mode 600: that file alone reproduces this data"
  exit 0
fi

rows=$(platform_rows)
case "$rows" in
'' | *[!0-9]*) populated="cannot tell" ;;
0) populated="" ;;
*) populated="$rows row(s)" ;;
esac
# A run that died half way left its mark: its partial rows are not a platform holding data, and
# without this the rerun read them as one and `make all` went green over half a restore.
if [ -n "$populated" ] && [ "$FORCE" != 1 ] && [ ! -e "$STATE/seeds.pending" ]; then
  if [ "$MODE" = --auto ]; then
    note "this platform already holds data ($populated): left alone"
    exit 0
  fi
  die "this platform already holds data ($populated): make set_seeds FORCE=1 replaces it"
fi

# 42ctl from PATH or ~/.local/bin, else its own installer, which verifies its download.
[ -n "$CTL" ] || CTL=$(command -v 42ctl 2>/dev/null) || CTL="$HOME/.local/bin/42ctl"
if [ ! -x "$CTL" ]; then
  note "no 42ctl here: installing it"
  installer=$(mktemp)
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 https://raw.githubusercontent.com/Univers42/42ctl/main/install.sh -o "$installer" &&
    env FT_BIN_DIR="$HOME/.local/bin" FT_NO_MODIFY_PATH=1 sh "$installer" >/dev/null 2>&1
  rm -f "$installer"
  CTL="$HOME/.local/bin/42ctl"
  [ -x "$CTL" ] || not_now "no 42ctl on this machine, and its installer failed"
fi

FT_PASSPHRASE=$(cred FT_PASSPHRASE)
[ -n "$FT_PASSPHRASE" ] || not_now "$CRED holds no FT_PASSPHRASE"
export FT_PASSPHRASE

if [ ! -s "$KEYSTORE" ]; then
  sealed=$(cred FT_KEYSTORE_B64)
  [ -n "$sealed" ] || not_now "no keystore at $KEYSTORE, and $CRED carries none: set-seeds.sh --bundle where it exists"
  (umask 077 && mkdir -p "${KEYSTORE%/*}" && printf '%s' "$sealed" | base64 -d >"$KEYSTORE") ||
    die "could not restore the keystore from $CRED"
  note "keystore restored from $CRED"
fi

sign_in() {
  FT_PASSWORD=$(cred FT_PASSWORD)
  export FT_PASSWORD
  "$CTL" auth login --password --email "$(cred FT_EMAIL)" --tenant "$(cred FT_TENANT)" </dev/null >/dev/null 2>&1 ||
    die "the 42ctl login was refused: check FT_EMAIL, FT_PASSWORD and FT_TENANT in $CRED"
  unset FT_PASSWORD
}
# "session only" is not enough: the contract binds the keystore, and vault and pull read through it.
case "$("$CTL" auth status 2>&1)" in
*"session and contract"*) ;;
*) sign_in ;;
esac

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/grobase-seeds.XXXXXX") || die "no temporary directory"
trap 'rm -rf "$work"' EXIT
# A fresh 42ctl knows the vault but not where its large blobs live, and anything above the
# transport ceiling (minio.tar.gz, 7 MB) then stops the pull with "this profile names no object
# store". Public configuration, not a credential; infra/S3_* below is what opens the bucket.
"$CTL" config endpoint --blobstore "$SEEDS_BLOBSTORE" --bucket "$SEEDS_BUCKET" --region auto >/dev/null ||
  die "42ctl could not record the object store"
note "fetching $SEEDS_ORG/$PROJECT/$SEEDS_ENV from the vault"
# groot's order (scripts/vault42-pull-everything.sh): the shared environment, then the personal
# vault, errors kept. A contract left on another login reads as logged in and still refuses with
# "contract not bound to this key", so one sign-in and one retry.
vault_secret() {
  "$CTL" env secret get "$1" --org "$SEEDS_ORG" --project "$PROJECT" --env "$SEEDS_ENV" 2>>"$work/secret.err" ||
    "$CTL" vault get "$1" 2>>"$work/secret.err"
}
load_object_store_key() {
  FT_S3_KEY=$(vault_secret infra/S3_KEY) && FT_S3_SECRET=$(vault_secret infra/S3_SECRET)
}
if ! load_object_store_key; then
  grep -q 'contract not bound to this key' "$work/secret.err" && sign_in
  load_object_store_key || die "cannot read infra/S3_KEY and infra/S3_SECRET: $(tail -n2 "$work/secret.err" | tr '\n' ' ')"
fi
export FT_S3_KEY FT_S3_SECRET
# The shared environment, by name, and only what this stack loads: the same tree holds other
# projects' archives, and `42ctl pull` is a personal tree a fresh identity may not have.
only=(--only apps/grobase/.env.secrets)
for f in $SEED_FILES; do only+=(--only "secrets/$f"); done
if ! (cd "$work" && "$CTL" env pull --org "$SEEDS_ORG" --project "$PROJECT" --env "$SEEDS_ENV" "${only[@]}" --apply) >"$work/pull.log" 2>&1; then
  tail -n3 "$work/pull.log" >&2
  die "42ctl could not fetch the seeds"
fi
unset FT_S3_KEY FT_S3_SECRET
[ -f "$work/secrets/MANIFEST.json" ] || die "project $PROJECT has no seed set (make vault-seed writes one)"
[ -f "$work/apps/grobase/.env.secrets" ] || die "project $PROJECT has no .env.secrets: its rows would load unreadable"
(cd "$work/secrets" && sha256sum -c --quiet --ignore-missing SHA256SUMS) || die "the seeds fail their checksums"

mkdir -p "$SEEDS" "$STATE" || die "cannot write $SEEDS"
rm -rf "$SEEDS/secrets"
cp -a "$work/secrets" "$SEEDS/secrets" || die "could not keep the seeds in $SEEDS"
vintage=$(sed -n 's/.*"created_utc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SEEDS/secrets/MANIFEST.json" | head -n1)
note "seeds verified, captured ${vintage:-at an unknown date}"

rm -f "$STATE/seeds.last"
: >"$STATE/seeds.pending"
mk() { make --no-print-directory "$@" "${SHAPE[@]}"; }
mk down >/dev/null 2>&1 || note "WARN make down reported a problem"
merge_secrets .env.secrets "$work/apps/grobase/.env.secrets" "$work/merged" || die "could not merge the secrets"
install -m 0600 "$work/merged" .env.secrets || die "could not install the secrets"
ENV_ORPHANS=carry make --no-print-directory env >/dev/null || die "make env failed"

mk up SERVICE="$ENGINES_RUN" >/dev/null || die "the engines did not start"
if ! SKIP_STACK_CYCLE=1 SEED_DIR="$SEEDS/secrets" STATE_DIR="$STATE/restore-state" bash scripts/ops/vault-restore.sh; then
  mk up >/dev/null || note "WARN the stack did not come back either"
  die "vault-restore failed (above); $STATE/restore-state holds the dump taken before it"
fi
mk up >/dev/null || die "the full stack did not start"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  rows=$(platform_rows)
  case "$rows" in '' | 0 | *[!0-9]*) sleep 10 ;; *) break ;; esac
done
case "$rows" in
'' | 0 | *[!0-9]*) die "the stack came back, but the platform is empty ($rows)" ;;
esac
printf 'seeded_at=%s\nvintage=%s\nproject=%s\nrows=%s\n' "$(date -u +%FT%TZ)" "$vintage" "$PROJECT" "$rows" >"$STATE/seeds.last"
rm -f "$STATE/seeds.pending"
note "loaded: $rows platform row(s), captured $vintage"
