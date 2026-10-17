-- One frontier level: every wanted (object, relation) joined to authz.tuples
-- through the primary key. $1 app, $2/$3/$4 parallel arrays of object type,
-- object id and relation, $5 row cap. A row-constructor `(type, id) = ANY(...)`
-- here is a parallel full index scan (2816 ms over 235k tuples, devil r2 R7);
-- the unnest join is one index probe per want (1.35 ms). m232 asserts the plan.
-- DISTINCT because several sources may project the same logical tuple.
SELECT DISTINCT t.object_type, t.object_id, t.relation, t.subject_type, t.subject_id, t.subject_relation
  FROM unnest($2::text[], $3::text[], $4::text[]) AS f(object_type, object_id, relation)
  JOIN authz.tuples t
    ON t.app = $1
   AND t.object_type = f.object_type
   AND t.object_id = f.object_id
   AND t.relation = f.relation
 LIMIT $5
