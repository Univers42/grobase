-- ============================================================
-- 005_secure_roles.sql — SECURITY: trust the staff role from
-- app_metadata (server-controlled), never user_metadata.
--
-- Threat fixed (privilege escalation): GoTrue's /auth/v1/signup writes its
-- `data` field into the JWT's user_metadata, which is FULLY CLIENT-CONTROLLED.
-- Once visitor self-signup exists, anyone can POST {"data":{"role":"admin"}}
-- and, if RLS reads user_metadata.role, instantly gain admin — reading every
-- visitor's tickets (PII) and writing staff. app_metadata, by contrast, is
-- writable ONLY through the GoTrue admin API (service role), so it is the
-- trustworthy place to carry a privilege.
--
--   • zoo_jwt_role() now reads request.jwt.claims->'app_metadata'->>'role'.
--   • A self-signup visitor has no app_metadata.role → NULL → owner-scoped
--     only (no admin/reception bypass). A forged user_metadata.role is ignored.
--   • The real staff get their role written into app_metadata below, keyed on a
--     fixed server-side allowlist (NOT on any client-supplied value).
-- ============================================================
SET search_path TO public;

CREATE OR REPLACE FUNCTION public.zoo_jwt_role() RETURNS TEXT AS $$
  SELECT current_setting('request.jwt.claims', true)::jsonb
    -> 'app_metadata' ->> 'role';
$$ LANGUAGE SQL STABLE;

-- Promote ONLY the known staff accounts into the trusted app_metadata.role.
-- The allowlist is the security boundary — it is server-defined here, never
-- derived from user_metadata (which the user controls). Visitors are absent,
-- so they stay unprivileged no matter what role they typed at signup.
UPDATE auth.users AS u
SET raw_app_meta_data =
      coalesce(u.raw_app_meta_data, '{}'::jsonb)
      || jsonb_build_object('role', s.role)
FROM (VALUES
        ('sophie.laurent@savanna-zoo.com', 'admin'),
        ('marcus.osei@savanna-zoo.com',    'zookeeper'),
        ('elena.moreau@savanna-zoo.com',   'zookeeper'),
        ('yuki.tanaka@savanna-zoo.com',    'vet'),
        ('lucas.petit@savanna-zoo.com',    'reception')
     ) AS s(email, role)
WHERE u.email = s.email;
