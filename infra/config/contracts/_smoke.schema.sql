-- Contract smoke schema — a tiny owner-scoped table, applied into the `smoke`
-- database by the generic provisioner. Idempotent (IF NOT EXISTS).
CREATE TABLE IF NOT EXISTS public.smoke_notes (
  id         bigserial PRIMARY KEY,
  owner_id   text NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
