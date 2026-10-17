-- m232 seed: a 100k-page ternary tree (depth 10 at page 88888), 2000 users, 50
-- workspaces, plus a noise app. The shape of .groot-collab/2026-10-17/r2/frontier-seed.sql with
-- the `source` column of the contract and workspace#member as the userset.
INSERT INTO authz.models (app, model) VALUES
  ('osionos', '{"types":{
    "workspace":{"relations":{"member":{"types":["user"]}}},
    "page":{"relations":{"parent":{"types":["page"]},"owner":{"types":["user"]},
      "viewer":{"types":["user","workspace#member"]}},
     "permissions":{"read":{"union":[{"relation":"owner"},{"relation":"viewer"},{"from":"parent","permission":"read"}]}}}}}'::jsonb);
INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, source)
  SELECT 'osionos', 'page', g::text, 'parent', 'page', ((g - 1) / 3)::text, 'seed' FROM generate_series(2, 100000) g;
INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, source)
  SELECT 'osionos', 'page', g::text, 'owner', 'user', 'u' || (g % 2000), 'seed' FROM generate_series(1, 100000) g;
INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, subject_relation, source)
  SELECT 'osionos', 'page', g::text, 'viewer', 'workspace', 'w' || (g % 50), 'member', 'seed'
    FROM generate_series(1, 100000) g WHERE g % 3 = 0;
INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, source)
  SELECT 'osionos', 'workspace', 'w' || (g % 50), 'member', 'user', 'u' || g, 'seed' FROM generate_series(1, 2000) g;
INSERT INTO authz.tuples (app, object_type, object_id, relation, subject_type, subject_id, source)
  SELECT 'other', 'page', g::text, 'owner', 'user', 'x' || g, 'seed' FROM generate_series(1, 10000) g;
VACUUM ANALYZE authz.tuples;
