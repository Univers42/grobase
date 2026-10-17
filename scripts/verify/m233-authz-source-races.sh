#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m233-authz-source-races.sh — authz.tuples is source-owned: two sources that #
#  derive one grant never collide, never deadlock, and never leave it stale    #
#                                                                              #
#  Migration 091 puts `source` in the primary key of authz.tuples and writes   #
#  tuples only through authz.replace_source_tuples. With a shared row (no      #
#  source) READ COMMITTED gave four failures (devil round 2, N1a-N1d):         #
#    N1a  two objects, each written by a page row and a share rule: 40P01      #
#    N1b  concurrent ADD of one grant from two sources: 23505                  #
#    N1c  concurrent REMOVE of both sources: the grant stays (write skew)      #
#    N1d  N1c with the opposite order of arrival                               #
#  This gate boots a throwaway postgres, applies 091, builds a scratch page /  #
#  share-rule domain with per-row triggers (the P2 shape), and replays all     #
#  four with forced interleavings (pg_sleep inside an open transaction).       #
#  Each case must give zero ERROR lines (so zero 40P01 and zero 23505) and    #
#  zero stale or missing grants against the mapping.                           #
#    SEMANTICS  an unchanged set writes 0 rows; '[]' removes; another source's #
#               identical tuple survives the first one's removal; 22023 on     #
#               bad input; the migration re-applies and records 91 once        #
#    C1         as anon, authenticated and a bare role (PUBLIC): SELECT,       #
#               INSERT, UPDATE, DELETE on both tables and EXECUTE of the       #
#               primitive are 42501, with schema USAGE granted inside a        #
#               rolled-back transaction so each table and function privilege   #
#               is tested alone; service_role reads and executes but cannot    #
#               write a table directly                                         #
#    STRESS     pgbench, 8 clients on overlapping objects, one source each:    #
#               zero failed transactions                                       #
#  Image: postgres:16-alpine, the one the devil measured on, plus the three    #
#  roles and public.schema_migrations that 091 depends on (the pattern of      #
#  m172). grobase-postgres adds extensions 091 never touches.                  #
#  M233_MIGRATION points at a scratch copy of 091: the mutation tests in the   #
#  commit message run it with the source column out of the PK, with EXECUTE    #
#  granted to anon, and with SELECT granted to PUBLIC; each MUST fail here.    #
#                                                                              #
#  Caveat: the interleavings are forced by 0.6 s sleeps, so a very slow host   #
#  could serialize a case and pass it without the race having happened; the    #
#  PK-mutation run is what shows the cases bite. STRESS is random and proves   #
#  absence of errors in 2400 transactions, not their absence in general.       #
#  Needs docker and the image already present (nothing is pulled); otherwise   #
#  SKIP, exit 77, never 0. Container and temp files go in an EXIT trap.        #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATION="${M233_MIGRATION:-${ROOT}/scripts/migrations/postgresql/091_authz_tuples.sql}"
PG_IMAGE="${M233_PG_IMAGE:-postgres:16-alpine}"
PG="authz-a-pg-$$"
WORK="$(mktemp -d)"
PASS=0

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M233] $*"; }
ok() {
  printf '\033[0;32m  ✓ %s\033[0m\n' "$*"
  PASS=$((PASS + 1))
}
fail() {
  printf '\033[0;31m[M233] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -f "${PG}" >/dev/null 2>&1
  rm -rf "${WORK}"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
  echo "[M233] SKIP — docker absent"
  exit 77
}
docker image inspect "${PG_IMAGE}" >/dev/null 2>&1 || {
  echo "[M233] SKIP — ${PG_IMAGE} not present (nothing is pulled)"
  exit 77
}
[ -f "${MIGRATION}" ] || fail "migration not found: ${MIGRATION}"

pg() { timeout 60 docker exec -i "${PG}" psql -U postgres -d m233 -qtAX -v ON_ERROR_STOP=1 "$@"; }
# sqlstate_as ROLE SQL prints the SQLSTATE of SQL run as ROLE, 00000 when it succeeds.
# USAGE on the schema is granted inside the transaction and rolled back, so a missing
# table or function privilege is not hidden behind a missing schema privilege.
sqlstate_as() {
  local out
  out="$(printf 'BEGIN;\nGRANT USAGE ON SCHEMA authz TO %s;\nSET ROLE %s;\n%s;\nROLLBACK;\n' \
    "$1" "$1" "$2" | timeout 60 docker exec -i "${PG}" psql -U postgres -d m233 -qtAX \
    -v VERBOSITY=verbose 2>&1)"
  if grep -Eq 'ERROR:' <<<"${out}"; then
    sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"${out}" | head -1
  else
    echo 00000
  fi
}
expect_state() { # label want role sql
  local got
  got="$(sqlstate_as "$3" "$4")"
  [ "${got}" = "$2" ] || fail "$1: as $3 expected SQLSTATE $2, got '${got}'"
}
state_postgres() {
  local out
  out="$(timeout 60 docker exec -i "${PG}" psql -U postgres -d m233 -qtAX -v VERBOSITY=verbose \
    -c "$1" 2>&1)"
  if grep -Eq 'ERROR:' <<<"${out}"; then
    sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' <<<"${out}" | head -1
  else
    echo 00000
  fi
}

step "1/5 boot ${PG_IMAGE} and apply 091 (twice)"
docker run -d --name "${PG}" --tmpfs /var/lib/postgresql/data -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=m233 "${PG_IMAGE}" >/dev/null || fail "cannot start postgres"
for i in $(seq 1 60); do
  docker exec "${PG}" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  [ "${i}" -eq 60 ] && fail "postgres never accepted TCP"
  sleep 0.5
done
pg >/dev/null <<'SQL' || fail "bootstrap failed"
CREATE TABLE public.schema_migrations (version int PRIMARY KEY, name text, applied_at timestamptz DEFAULT now());
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;
CREATE ROLE bare_role NOLOGIN;
SQL
docker exec -i "${PG}" psql -U postgres -d m233 -qtAX -v ON_ERROR_STOP=1 >/dev/null 2>&1 <"${MIGRATION}" ||
  fail "091 failed to apply"
docker exec -i "${PG}" psql -U postgres -d m233 -qtAX -v ON_ERROR_STOP=1 >/dev/null 2>&1 <"${MIGRATION}" ||
  fail "091 failed to re-apply (not idempotent)"
[ "$(pg -c "SELECT count(*) FROM public.schema_migrations WHERE version = 91")" = 1 ] ||
  fail "091 did not record its version exactly once"
ok "091 applies, re-applies, and records version 91 once"
pg -c "SELECT string_agg(a.attname, ',' ORDER BY a.attnum) FROM pg_index i
         JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
        WHERE i.indrelid = 'authz.tuples'::regclass AND i.indisprimary" |
  grep -qx 'app,object_type,object_id,relation,subject_type,subject_id,subject_relation,source' ||
  fail "authz.tuples primary key does not end in source"
ok "primary key is (app, object_type, object_id, relation, subject_type, subject_id, subject_relation, source)"

step "2/5 primitive semantics (called as service_role)"
call() { pg -c "SET ROLE service_role; SELECT authz.replace_source_tuples('a','page','p1','$1','$2'::jsonb)"; }
V='[{"relation":"viewer","subject_type":"workspace","subject_id":"w1","subject_relation":"access"}]'
[ "$(call src_a "${V}" | tail -1)" = 1 ] || fail "first write of one tuple should change 1 row"
[ "$(call src_a "${V}" | tail -1)" = 0 ] || fail "an unchanged set must write 0 rows"
[ "$(call src_b "${V}" | tail -1)" = 1 ] || fail "a second source of the same tuple should add its own row"
[ "$(pg -c "SELECT count(*) FROM authz.tuples WHERE object_id='p1'")" = 2 ] ||
  fail "two sources of one tuple should be two rows"
[ "$(call src_a '[]' | tail -1)" = 1 ] || fail "'[]' should remove the one row of src_a"
[ "$(pg -c "SELECT string_agg(source,',') FROM authz.tuples WHERE object_id='p1'")" = src_b ] ||
  fail "the identical tuple of src_b must survive the removal of src_a"
[ "$(call src_b '[]' | tail -1)" = 1 ] || fail "'[]' should remove src_b"
[ "$(pg -c "SELECT count(*) FROM authz.tuples WHERE object_id='p1'")" = 0 ] || fail "set not empty"
[ "$(call src_b '[]' | tail -1)" = 0 ] || fail "removing an absent set must write 0 rows"
ok "unchanged writes 0 rows; '[]' removes; another source's identical tuple survives"
[ "$(pg -c "SELECT count(*) FROM pg_proc WHERE oid = 'authz.replace_source_tuples(text,text,text,text,jsonb)'::regprocedure AND prosecdef AND proconfig = ARRAY['search_path=pg_catalog, authz']")" = 1 ] ||
  fail "primitive is not SECURITY DEFINER with the pinned search_path"
ok "primitive is SECURITY DEFINER with search_path = pg_catalog, authz"
bad() { # label tuples-json app type id
  local s
  s="$(state_postgres "SELECT authz.replace_source_tuples('${3-a}','${4-page}','${5-p9}','s','$2'::jsonb)")"
  [ "${s}" = 22023 ] || fail "$1: expected 22023, got ${s}"
}
bad "empty app" '[]' ''
bad "uppercase object type" '[]' a Page
bad "# in object id" '[]' a page 'p#1'
bad "object is not an array" '{"relation":"viewer"}'
bad "tuple missing subject_id" '[{"relation":"viewer","subject_type":"user"}]'
bad "tuple relation is a number" '[{"relation":1,"subject_type":"user","subject_id":"u"}]'
bad "bad relation shape" '[{"relation":"Viewer","subject_type":"user","subject_id":"u"}]'
bad "# in subject id" '[{"relation":"viewer","subject_type":"user","subject_id":"u#x"}]'
[ "$(state_postgres "SELECT authz.replace_source_tuples('a','page','p9','','[]'::jsonb)")" = 22023 ] ||
  fail "empty source must raise 22023"
[ "$(state_postgres "SELECT authz.replace_source_tuples('a','page','p9','s',NULL)")" = 22023 ] ||
  fail "NULL tuples must raise 22023"
ok "bad input raises 22023 (app, type, id, source, NULL, non-array, malformed tuples)"

step "3/5 C1 — who can touch authz.*"
for role in anon authenticated bare_role; do
  [ "$(printf 'SET ROLE %s;\nSELECT 1 FROM authz.tuples;\n' "${role}" | timeout 60 docker exec -i "${PG}" \
    psql -U postgres -d m233 -qtAX -v VERBOSITY=verbose 2>&1 | sed -n 's/^ERROR:  \([0-9A-Z]\{5\}\):.*/\1/p' | head -1)" = 42501 ] ||
    fail "${role} reached schema authz without USAGE"
  expect_state "select tuples" 42501 "${role}" "SELECT 1 FROM authz.tuples"
  expect_state "select models" 42501 "${role}" "SELECT 1 FROM authz.models"
  expect_state "insert tuples" 42501 "${role}" "INSERT INTO authz.tuples VALUES ('a','t','1','r','u','1','','s')"
  expect_state "update tuples" 42501 "${role}" "UPDATE authz.tuples SET source = 'x'"
  expect_state "delete tuples" 42501 "${role}" "DELETE FROM authz.tuples"
  expect_state "insert models" 42501 "${role}" "INSERT INTO authz.models VALUES ('a','{}')"
  expect_state "execute primitive" 42501 "${role}" \
    "SELECT authz.replace_source_tuples('a','page','p1','s','[]'::jsonb)"
done
ok "anon, authenticated and a bare role: 42501 on every table privilege and on EXECUTE"
expect_state "service_role select tuples" 00000 service_role "SELECT 1 FROM authz.tuples"
expect_state "service_role select models" 00000 service_role "SELECT 1 FROM authz.models"
expect_state "service_role execute" 00000 service_role \
  "SELECT authz.replace_source_tuples('a','page','p1','s','[]'::jsonb)"
expect_state "service_role direct insert" 42501 service_role \
  "INSERT INTO authz.tuples VALUES ('a','t','1','r','u','1','','s')"
expect_state "service_role models insert" 42501 service_role "INSERT INTO authz.models VALUES ('a','{}')"
ok "service_role reads both tables and executes the primitive; it cannot write a table directly"

step "4/5 N1a-N1d — forced interleavings against a page / share-rule domain"
pg >/dev/null <<'SQL' || fail "scratch domain failed"
CREATE SCHEMA m233;
CREATE TABLE m233.pages (id int PRIMARY KEY, workspace_id int NOT NULL, visibility text NOT NULL DEFAULT 'private');
CREATE TABLE m233.share_rules (id serial PRIMARY KEY, page_id int NOT NULL, target text NOT NULL, permission text NOT NULL);
-- Each domain row maps only itself to its own source (the pure per-row mapping of N1).
CREATE FUNCTION m233.project() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE viewer jsonb;
BEGIN
  IF TG_TABLE_NAME = 'pages' THEN
    IF TG_OP = 'DELETE' THEN
      PERFORM authz.replace_source_tuples('a','page',OLD.id::text,'page_row','[]');
    ELSE
      PERFORM authz.replace_source_tuples('a','page',NEW.id::text,'page_row',
        CASE WHEN NEW.visibility = 'shared' THEN jsonb_build_array(jsonb_build_object(
          'relation','viewer','subject_type','workspace','subject_id',NEW.workspace_id::text,
          'subject_relation','access')) ELSE '[]'::jsonb END);
    END IF;
  ELSE
    IF TG_OP IN ('DELETE','UPDATE') THEN
      PERFORM authz.replace_source_tuples('a','page',OLD.page_id::text,'share_rule:'||OLD.id,'[]');
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
      SELECT jsonb_build_array(jsonb_build_object('relation','viewer','subject_type','workspace',
        'subject_id',p.workspace_id::text,'subject_relation','access')) INTO viewer
        FROM m233.pages p WHERE p.id = NEW.page_id AND NEW.target = 'workspace' AND NEW.permission = 'can_view';
      PERFORM authz.replace_source_tuples('a','page',NEW.page_id::text,'share_rule:'||NEW.id,
        coalesce(viewer,'[]'::jsonb));
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER pages_authz AFTER INSERT OR UPDATE OR DELETE ON m233.pages
  FOR EACH ROW EXECUTE FUNCTION m233.project();
CREATE TRIGGER share_authz AFTER INSERT OR UPDATE OR DELETE ON m233.share_rules
  FOR EACH ROW EXECUTE FUNCTION m233.project();
-- The expected number of DISTINCT viewer subjects: shared, or a workspace can_view rule.
CREATE FUNCTION m233.drift(p_id int) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN have = want THEN 'ok' WHEN have > want THEN 'stale' ELSE 'missing' END
  FROM (SELECT (SELECT count(DISTINCT (subject_type, subject_id, subject_relation)) FROM authz.tuples
                 WHERE app = 'a' AND object_type = 'page' AND object_id = p_id::text AND relation = 'viewer') have,
               (SELECT CASE WHEN p.visibility = 'shared' OR EXISTS (SELECT 1 FROM m233.share_rules s
                       WHERE s.page_id = p.id AND s.target = 'workspace' AND s.permission = 'can_view')
                       THEN 1 ELSE 0 END FROM m233.pages p WHERE p.id = p_id) want) x $$;
INSERT INTO m233.pages (id, workspace_id) VALUES (10,1),(20,1),(30,1),(33,1),(40,1);
SQL
# session NAME <<SQL runs one psql, output (stderr included) in $WORK/NAME.out.
session() { timeout 60 docker exec -i "${PG}" psql -U postgres -d m233 -qtAX -v VERBOSITY=verbose \
  -v ON_ERROR_STOP=1 >"${WORK}/$1.out" 2>&1; }
check_case() { # label page...
  local label="$1" p out
  shift
  if grep -Eh 'ERROR' "${WORK}"/T1.out "${WORK}"/T2.out >"${WORK}/errs" 2>/dev/null && [ -s "${WORK}/errs" ]; then
    head -3 "${WORK}/errs" >&2
    fail "${label}: a session raised an error (40P01 or 23505 expected to be zero)"
  fi
  for p in "$@"; do
    out="$(pg -c "SELECT m233.drift(${p})")"
    [ "${out}" = ok ] || fail "${label}: page ${p} is ${out} (grant out of step with the mapping)"
  done
  rm -f "${WORK}"/T1.out "${WORK}"/T2.out
  ok "${label}: no error, no stale or missing grant"
}
two() { # runs session T1 (stdin file $1) and T2 (stdin file $2) 0.2 s apart
  session T1 <"$1" &
  sleep 0.2
  session T2 <"$2" &
  wait
}

pg -c "UPDATE m233.pages SET visibility='private'; DELETE FROM m233.share_rules" >/dev/null
cat >"${WORK}/a1" <<'SQL'
BEGIN;
UPDATE m233.pages SET visibility='shared' WHERE id=10;
SELECT pg_sleep(0.6);
INSERT INTO m233.share_rules(page_id,target,permission) VALUES (20,'workspace','can_view');
COMMIT;
SQL
cat >"${WORK}/a2" <<'SQL'
BEGIN;
UPDATE m233.pages SET visibility='shared' WHERE id=20;
SELECT pg_sleep(0.6);
INSERT INTO m233.share_rules(page_id,target,permission) VALUES (10,'workspace','can_view');
COMMIT;
SQL
two "${WORK}/a1" "${WORK}/a2"
check_case "N1a two objects, page row + share rule each" 10 20

cat >"${WORK}/b1" <<'SQL'
BEGIN;
UPDATE m233.pages SET visibility='shared' WHERE id=40;
SELECT pg_sleep(0.6);
COMMIT;
SQL
cat >"${WORK}/b2" <<'SQL'
INSERT INTO m233.share_rules(page_id,target,permission) VALUES (40,'workspace','can_view');
SQL
two "${WORK}/b1" "${WORK}/b2"
check_case "N1b concurrent add of one grant from two sources" 40

pg -c "UPDATE m233.pages SET visibility='shared' WHERE id IN (30,33);
       INSERT INTO m233.share_rules(page_id,target,permission) VALUES (30,'workspace','can_view'),(33,'workspace','can_view')" >/dev/null
[ "$(pg -c "SELECT count(*) FROM authz.tuples WHERE object_id IN ('30','33') AND relation='viewer'")" = 4 ] ||
  fail "N1c/N1d setup: pages 30 and 33 should hold two source rows each"
cat >"${WORK}/c1" <<'SQL'
BEGIN;
UPDATE m233.pages SET visibility='private' WHERE id=30;
SELECT pg_sleep(0.6);
COMMIT;
SQL
cat >"${WORK}/c2" <<'SQL'
DELETE FROM m233.share_rules WHERE page_id=30;
SQL
two "${WORK}/c1" "${WORK}/c2"
check_case "N1c concurrent removal of both sources" 30

cat >"${WORK}/d1" <<'SQL'
BEGIN;
DELETE FROM m233.share_rules WHERE page_id=33;
SELECT pg_sleep(0.6);
COMMIT;
SQL
cat >"${WORK}/d2" <<'SQL'
UPDATE m233.pages SET visibility='private' WHERE id=33;
SQL
two "${WORK}/d1" "${WORK}/d2"
check_case "N1d the same, opposite order of arrival" 33
[ "$(pg -c "SELECT count(*) FROM authz.tuples WHERE object_id IN ('30','33')")" = 0 ] ||
  fail "N1c/N1d left tuples on pages that are private with no rule"

step "5/5 STRESS — 8 clients, overlapping objects, one source per client"
docker exec -i "${PG}" sh -c 'cat >/tmp/stress.pgb' <<'SQL'
\set object random(1, 4)
\set a random(1, 6)
\set b random(1, 6)
SELECT authz.replace_source_tuples('stress', 'page', (:object)::text, 'w' || :client_id,
  jsonb_build_array(
    jsonb_build_object('relation','viewer','subject_type','user','subject_id',(:a)::text),
    jsonb_build_object('relation','viewer','subject_type','user','subject_id',(:b)::text)));
SQL
out="$(timeout 120 docker exec "${PG}" pgbench -U postgres -n -c 8 -j 4 -t 300 -f /tmp/stress.pgb m233 2>&1)"
grep -Eq 'number of transactions actually processed: 2400/2400' <<<"${out}" ||
  fail "stress did not process 2400 transactions: $(tail -4 <<<"${out}")"
grep -Eq 'number of failed transactions: 0 ' <<<"${out}" ||
  fail "stress had failed transactions: $(grep -i 'fail\|ERROR' <<<"${out}" | head -3)"
ok "stress: 2400 transactions, 0 failed (no 40P01, no 23505)"

printf '\033[1;32m[M233] PASS — %d checks\033[0m\n' "${PASS}"
