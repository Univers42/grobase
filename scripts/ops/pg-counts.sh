#!/usr/bin/env bash
# pg-counts.sh — proves a restored PostgreSQL holds exactly the rows a pg_dumpall dump carried,
# table by table: the dump's COPY blocks are counted, then each of those tables is counted live
# in the postgres container, logged in with that container's own POSTGRES_USER/PASSWORD (so no
# credential crosses this script).
#
#   pg-counts.sh dump FILE    TSV db<TAB>table<TAB>rows of a .sql or .sql.gz dump, sorted
#   pg-counts.sh live         reads that TSV on stdin, prints the same TSV counted live
#   pg-counts.sh check FILE   dump vs live; prints db<TAB>table<TAB>dump=N<TAB>live=M per
#                             difference (live=missing when the database cannot be counted)
#
# Exit: 0 equal · 1 a step failed · 2 usage, unreadable FILE or a dump without COPY · 3 differ.
# The awk is POSIX (the data center's is mawk): no gawk extension.
#
# Ponytail: counts only — a changed value under an unchanged row count passes, and tables the
# dump did not carry are never looked at. One COPY data line is one row, exact for pg_dump's
# text format (it writes an embedded newline as \n). A database whose count query fails (a
# table missing, or the container down) reports every one of its tables as live=missing.
set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-mini-baas-postgres}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '7,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit "$1"
}

# dump_counts FILE — `\connect` names the database for the COPY blocks after it, in both forms
# pg_dumpall writes: `\connect name` and `\connect -reuse-previous=on "dbname='name'"`.
dump_counts() {
  gzip -cdf -- "$1" | LC_ALL=C awk -v OFS='\t' -v q="'" '
    /^\\connect / {
      db = $0
      sub(/^\\connect +(-reuse-previous=on +)?/, "", db)
      sub(/^"dbname=/, "", db)
      sub(/"$/, "", db)
      if (substr(db, 1, 1) == q) db = substr(db, 2, length(db) - 2)
      next
    }
    /^COPY .* FROM stdin;$/ { t = $0; sub(/^COPY /, "", t); sub(/ (\(.*\) )?FROM stdin;$/, "", t); n = 0; on = 1; next }
    on && $0 == "\\." { print (db == "" ? "postgres" : db), t, n; on = 0; next }
    on { n++ }
  ' | LC_ALL=C sort
}

# count_db DB — one psql call per database (stdin: the dump TSV): one UNION ALL query over every
# table the dump listed for DB, each count labelled with the table name as the dump wrote it.
count_db() {
  awk -F '\t' -v db="$1" -v q="'" '$1 == db {
      l = $2; gsub(q, q q, l)
      printf "%sSELECT %s%s%s, count(*) FROM %s\n", (n++ ? "UNION ALL " : ""), q, l, q, $2
    } END { print ";" }' |
    docker exec -i "$PG_CONTAINER" sh -c \
      'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -XAtq -v ON_ERROR_STOP=1 -F "$(printf "\t")" -U "$POSTGRES_USER" -d "$1"' \
      pg-counts "$1"
}

# live_counts — stdin is dump TSV; a database that cannot be counted prints `missing` per table.
live_counts() {
  local tsv db out
  tsv="$(cat)"
  while IFS= read -r db; do
    if out="$(count_db "$db" <<<"$tsv")"; then
      awk -v OFS='\t' -v db="$db" 'NF { print db, $0 }' <<<"$out"
    else
      awk -F '\t' -v OFS='\t' -v db="$db" '$1 == db { print db, $2, "missing" }' <<<"$tsv"
    fi
  done < <(cut -f1 <<<"$tsv" | LC_ALL=C sort -u) | LC_ALL=C sort
}

# check_counts FILE — prints only the tables that differ; the summary goes to stderr. The live
# side is told apart by FILENAME, not NR == FNR, which an empty live side would turn into "equal".
check_counts() {
  local dump live diff
  dump="$(dump_counts "$1")"
  [ -n "$dump" ] || die "$1 holds no COPY block — not a pg_dumpall data dump" 2
  live="$(live_counts <<<"$dump")"
  diff="$(awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { got[$1 FS $2] = $3; next }
    { k = $1 FS $2; v = (k in got) ? got[k] : "missing" }
    v != $3 { print $1, $2, "dump=" $3, "live=" v }' <(printf '%s\n' "$live") <(printf '%s\n' "$dump"))"
  printf '[pg-counts] %s tables, %s differ\n' "$(wc -l <<<"$dump")" "$(grep -c . <<<"$diff" || true)" >&2
  [ -z "$diff" ] || {
    printf '%s\n' "$diff"
    return 3
  }
}

main() {
  case "${1:-}" in
  dump | check)
    [ "$#" -eq 2 ] || usage 2
    [ -r "$2" ] || die "cannot read $2" 2
    if [ "$1" = dump ]; then dump_counts "$2"; else check_counts "$2"; fi
    ;;
  live)
    [ "$#" -eq 1 ] || usage 2
    live_counts
    ;;
  -h | --help) usage 0 ;;
  *) usage 2 ;;
  esac
}

main "$@"
