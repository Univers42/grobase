-- ============================================================================
-- gourmand-owner-scoping.sql — Grobase re-platform overlay for vite-gourmand
-- ----------------------------------------------------------------------------
-- Applied to the `gourmand` application DB (NOT the platform/control DB) by
-- scripts/seed/gourmand-local-db.sh, after the app's own schema + seeds.
--
-- Enforcement model = Mechanism A (Rust data-plane appended predicate):
--   The mount connects as a BYPASSRLS role, so in-database RLS would be a no-op.
--   Per-user isolation is instead enforced by the data plane, which stamps
--   `owner_id = 'user:<gotrue-sub>'` on every owner-scoped INSERT and filters
--   reads/updates/deletes by it (flags DATA_PLANE_PER_TABLE_ISOLATION +
--   DATA_PLANE_ADMIN_BYPASS). This file therefore (1) adds the `owner_id`
--   columns the data plane needs, (2) links the app `User` to its GoTrue sub,
--   and (3) re-homes the NestJS business invariants into Postgres triggers.
--
-- Catalog tables (Menu, Dish, …) are registered in the mount's `shared_resources`
-- by gourmand-tenant.sh and therefore get NO owner_id here (the data plane skips
-- owner-scoping for them). Fully idempotent: re-runs converge.
-- ============================================================================

\set ON_ERROR_STOP on

-- 1) owner_id on every user-private table. The data plane stamps/filters it.
--    Nullable: existing seed rows predate the GoTrue link (gourmand-tenant.sh
--    backfills them); the data plane re-stamps owner_id on every write anyway.
--    A to_regclass guard skips any table this app build doesn't ship.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'User',
    'Order','OrderMenu','OrderStatusHistory','OrderOrderTag','DeliveryAssignment',
    'LoyaltyAccount','LoyaltyTransaction',
    'Notification','UserAddress','UserConsent','UserPromotion',
    'SupportTicket','TicketMessage','Message','TimeOffRequest','DataDeletionRequest',
    'ContactMessage','NewsletterSubscriber','NewsletterSendLog'
  ] LOOP
    IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS owner_id text', t);
      EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I (owner_id)',
        'idx_' || lower(t) || '_owner', t);
    END IF;
  END LOOP;
END $$;

-- 2) Link the app "User" profile to its GoTrue identity. GoTrue now owns
--    credentials, so password becomes vestigial (nullable). auth_id holds the
--    GoTrue sub; owner_id derives from it ('user:' || auth_id).
ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "auth_id" text;
CREATE INDEX IF NOT EXISTS idx_user_auth ON "User"("auth_id");
ALTER TABLE "User" ALTER COLUMN "password" DROP NOT NULL;

-- ============================================================================
-- 3) Business-rule triggers — the NestJS server logic, re-homed into the DB so
--    it holds with no application server. RAISE EXCEPTION → the data plane maps
--    it to a non-2xx. Functions are CREATE OR REPLACE (safe even if a referenced
--    table is absent — plpgsql resolves names at runtime); trigger attachment is
--    guarded by to_regclass + DROP TRIGGER IF EXISTS (idempotent).
-- ============================================================================

-- T1 — Order finite-state machine (faithful to order-status.service.ts STATUS_FLOW)
--      + the confirmed/delivered/cancelled timestamp stamping (getStatusTimestamp).
CREATE OR REPLACE FUNCTION gourmand_order_fsm() RETURNS TRIGGER AS $$
DECLARE allowed text[];
BEGIN
  IF NEW."status" IS DISTINCT FROM OLD."status" THEN
    allowed := CASE OLD."status"
      WHEN 'pending'    THEN ARRAY['confirmed','cancelled']
      WHEN 'confirmed'  THEN ARRAY['preparing','cancelled']
      WHEN 'preparing'  THEN ARRAY['ready','cancelled']
      WHEN 'ready'      THEN ARRAY['delivering']
      WHEN 'delivering' THEN ARRAY['delivered']
      ELSE ARRAY[]::text[]
    END;
    IF NOT (NEW."status" = ANY(allowed)) THEN
      RAISE EXCEPTION 'illegal order transition % -> %', OLD."status", NEW."status"
        USING ERRCODE = 'check_violation';
    END IF;
    IF NEW."status" = 'confirmed' THEN NEW."confirmed_at" := COALESCE(NEW."confirmed_at", NOW()); END IF;
    IF NEW."status" = 'delivered' THEN NEW."delivered_at" := COALESCE(NEW."delivered_at", NOW()); END IF;
    IF NEW."status" = 'cancelled' THEN NEW."cancelled_at" := COALESCE(NEW."cancelled_at", NOW()); END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T4 — server-generated order number (order.service.ts generateOrderNumber:
--      VG-YYYYMMDD-XXXXXX). The UNIQUE(order_number) constraint backstops it.
CREATE OR REPLACE FUNCTION gourmand_order_number() RETURNS TRIGGER AS $$
BEGIN
  IF NEW."order_number" IS NULL OR NEW."order_number" = '' THEN
    NEW."order_number" := 'VG-' || to_char(NOW(), 'YYYYMMDD') || '-'
      || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T2 — order status history (augments the app's existing fn_order_status_history
--      to ALSO stamp owner_id from the parent Order, since the data plane does
--      not see this trigger-authored row).
CREATE OR REPLACE FUNCTION fn_order_status_history() RETURNS TRIGGER AS $$
BEGIN
  IF OLD."status" IS DISTINCT FROM NEW."status" THEN
    INSERT INTO "OrderStatusHistory" ("order_id", "old_status", "new_status", "owner_id", "changed_at")
    VALUES (NEW."id", OLD."status", NEW."status", NEW."owner_id", NOW());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T3/T7 — append-only ledgers (OrderStatusHistory + LoyaltyTransaction).
CREATE OR REPLACE FUNCTION gourmand_block_mutation() RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'append-only ledger: % on % is not allowed', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

-- T6 — loyalty balance guard (loyalty.service.ts: cannot redeem below zero).
CREATE OR REPLACE FUNCTION gourmand_loyalty_guard() RETURNS TRIGGER AS $$
DECLARE bal int;
BEGIN
  IF NEW."points" < 0 THEN
    SELECT "balance" INTO bal FROM "LoyaltyAccount" WHERE "id" = NEW."loyalty_account_id";
    IF bal IS NULL OR bal + NEW."points" < 0 THEN
      RAISE EXCEPTION 'Insufficient points balance' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T5 — loyalty ledger application (double-entry: a transaction moves the balance,
--      earn/redeem accumulate into total_earned/total_spent).
CREATE OR REPLACE FUNCTION gourmand_loyalty_apply() RETURNS TRIGGER AS $$
BEGIN
  UPDATE "LoyaltyAccount"
     SET "balance"          = "balance" + NEW."points",
         "total_earned"     = "total_earned" + GREATEST(NEW."points", 0),
         "total_spent"      = "total_spent"  + GREATEST(-NEW."points", 0),
         "last_activity_at" = NOW()
   WHERE "id" = NEW."loyalty_account_id";
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T8 — review moderation (review.service.ts: only a pending review can be
--      approved/rejected; stamp moderated_at).
CREATE OR REPLACE FUNCTION gourmand_review_moderation() RETURNS TRIGGER AS $$
BEGIN
  IF NEW."status" IS DISTINCT FROM OLD."status" THEN
    IF NEW."status" IN ('approved','rejected') AND OLD."status" <> 'pending' THEN
      RAISE EXCEPTION 'review already moderated (% -> %)', OLD."status", NEW."status"
        USING ERRCODE = 'check_violation';
    END IF;
    IF NEW."status" IN ('approved','rejected') THEN
      NEW."moderated_at" := COALESCE(NEW."moderated_at", NOW());
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T9 — delivery lifecycle timestamps (delivery.service.ts).
CREATE OR REPLACE FUNCTION gourmand_delivery_ts() RETURNS TRIGGER AS $$
BEGIN
  IF NEW."status" = 'picked_up' AND OLD."status" IS DISTINCT FROM 'picked_up' THEN
    NEW."picked_up_at" := COALESCE(NEW."picked_up_at", NOW());
  END IF;
  IF NEW."status" = 'delivered' AND OLD."status" IS DISTINCT FROM 'delivered' THEN
    NEW."delivered_at" := COALESCE(NEW."delivered_at", NOW());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- T11 — soft-delete stamping on "User".
CREATE OR REPLACE FUNCTION gourmand_soft_delete() RETURNS TRIGGER AS $$
BEGIN
  IF NEW."is_deleted" AND NOT COALESCE(OLD."is_deleted", false) THEN
    NEW."deleted_at" := COALESCE(NEW."deleted_at", NOW());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── Attach the triggers (idempotent, table-existence guarded) ───────────────
DO $$
DECLARE
  rec record;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('Order',              'gourmand_order_fsm',        'BEFORE UPDATE',           'gourmand_order_fsm'),
      ('Order',              'gourmand_order_number',     'BEFORE INSERT',           'gourmand_order_number'),
      ('OrderStatusHistory', 'gourmand_osh_immutable',    'BEFORE UPDATE OR DELETE', 'gourmand_block_mutation'),
      ('LoyaltyTransaction', 'gourmand_loyalty_guard',    'BEFORE INSERT',           'gourmand_loyalty_guard'),
      ('LoyaltyTransaction', 'gourmand_loyalty_apply',    'AFTER INSERT',            'gourmand_loyalty_apply'),
      ('LoyaltyTransaction', 'gourmand_ltx_immutable',    'BEFORE UPDATE OR DELETE', 'gourmand_block_mutation'),
      ('Publish',            'gourmand_review_moderation','BEFORE UPDATE',           'gourmand_review_moderation'),
      ('DeliveryAssignment', 'gourmand_delivery_ts',      'BEFORE UPDATE',           'gourmand_delivery_ts'),
      ('User',               'gourmand_soft_delete',      'BEFORE UPDATE',           'gourmand_soft_delete')
    ) AS v(tbl, trg, timing, fn)
  LOOP
    IF to_regclass(format('public.%I', rec.tbl)) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', rec.trg, rec.tbl);
      EXECUTE format(
        'CREATE TRIGGER %I %s ON %I FOR EACH ROW EXECUTE FUNCTION %I()',
        rec.trg, rec.timing, rec.tbl, rec.fn);
    END IF;
  END LOOP;
END $$;

-- T10 — one delivery assignment per order (best-effort: skip if dirty data).
DO $$
BEGIN
  IF to_regclass('public."DeliveryAssignment"') IS NOT NULL THEN
    BEGIN
      CREATE UNIQUE INDEX IF NOT EXISTS uq_delivery_one_per_order
        ON "DeliveryAssignment" ("order_id");
    EXCEPTION WHEN unique_violation THEN
      RAISE NOTICE 'DeliveryAssignment has duplicate order_id rows — uniqueness index skipped';
    END;
  END IF;
END $$;
