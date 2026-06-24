-- ════════════════════════════════════════════════════════════════
-- NIMBUS — Grobase data-plane schema (PostgreSQL, ACID money model)
--
-- Applied by scripts/seed/nimbus-tenant.sh into the DEDICATED `nimbus`
-- database on the stack's own postgres. A money/ledger model: every
-- monetary value is `bigint` cents (never float). Double-entry ledger:
-- a payment posts a paired debit/credit so the books always balance.
--
-- owner_id is the data-plane scope column the gateway DDL path auto-fills
-- per request (api-key:<key_id> for the single app key). It is created
-- nullable here explicitly; the data plane stamps it on writes.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS,
-- so re-runs of the seeder converge.
-- ════════════════════════════════════════════════════════════════

-- ── app_users: app-side identity, 1:1 with GoTrue auth.users by id (sub) ──
CREATE TABLE IF NOT EXISTS public.app_users (
    id         text PRIMARY KEY,
    email      varchar(255) NOT NULL UNIQUE,
    name       varchar(120),
    role       varchar(20)  NOT NULL DEFAULT 'customer'
                 CHECK (role IN ('admin', 'staff', 'customer')),
    status     varchar(20)  NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'suspended', 'deleted')),
    owner_id   text,
    created_at timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_app_users_role   ON public.app_users (role);
CREATE INDEX IF NOT EXISTS idx_app_users_status ON public.app_users (status);

-- ── accounts: balances in cents; kinds split customer / revenue / fees ──
CREATE TABLE IF NOT EXISTS public.accounts (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_user_id text   REFERENCES public.app_users(id) ON DELETE SET NULL,
    kind          varchar(20) NOT NULL
                    CHECK (kind IN ('customer', 'revenue', 'fees')),
    balance_cents bigint  NOT NULL DEFAULT 0,
    currency      char(3) NOT NULL DEFAULT 'USD',
    owner_id      text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_accounts_owner ON public.accounts (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_accounts_kind  ON public.accounts (kind);

-- ── txns: a money movement; amount strictly positive ────────────────
CREATE TABLE IF NOT EXISTS public.txns (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind         varchar(20) NOT NULL
                   CHECK (kind IN ('payment', 'refund', 'payout')),
    amount_cents bigint  NOT NULL CHECK (amount_cents > 0),
    currency     char(3) NOT NULL DEFAULT 'USD',
    status       varchar(20) NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'posted', 'failed')),
    reference    varchar(120) UNIQUE,
    owner_id     text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_txns_status ON public.txns (status);
CREATE INDEX IF NOT EXISTS idx_txns_kind   ON public.txns (kind);

-- ── ledger_entries: double-entry rows for a txn (debit/credit) ──────
CREATE TABLE IF NOT EXISTS public.ledger_entries (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id bigint REFERENCES public.txns(id)     ON DELETE CASCADE,
    account_id     bigint REFERENCES public.accounts(id) ON DELETE RESTRICT,
    direction      varchar(10) NOT NULL
                     CHECK (direction IN ('debit', 'credit')),
    amount_cents   bigint  NOT NULL CHECK (amount_cents > 0),
    owner_id       text,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ledger_txn     ON public.ledger_entries (transaction_id);
CREATE INDEX IF NOT EXISTS idx_ledger_account ON public.ledger_entries (account_id);
CREATE INDEX IF NOT EXISTS idx_ledger_dir     ON public.ledger_entries (direction);

-- ── subscriptions: a recurring plan owned by an app_user ────────────
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            text REFERENCES public.app_users(id) ON DELETE CASCADE,
    plan               varchar(60),
    amount_cents       bigint  NOT NULL DEFAULT 0 CHECK (amount_cents >= 0),
    currency           char(3) NOT NULL DEFAULT 'USD',
    status             varchar(20) NOT NULL DEFAULT 'active'
                         CHECK (status IN ('trialing', 'active', 'past_due', 'canceled')),
    current_period_end timestamptz,
    owner_id           text,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user   ON public.subscriptions (user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON public.subscriptions (status);

-- ── invoices: a bill against a subscription, optionally paid by a txn ──
CREATE TABLE IF NOT EXISTS public.invoices (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id bigint REFERENCES public.subscriptions(id) ON DELETE SET NULL,
    user_id         text   REFERENCES public.app_users(id)     ON DELETE CASCADE,
    amount_cents    bigint  NOT NULL DEFAULT 0 CHECK (amount_cents >= 0),
    currency        char(3) NOT NULL DEFAULT 'USD',
    status          varchar(20) NOT NULL DEFAULT 'open'
                      CHECK (status IN ('draft', 'open', 'paid', 'void')),
    transaction_id  bigint REFERENCES public.txns(id) ON DELETE SET NULL,
    due_at          timestamptz,
    owner_id        text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_invoices_sub    ON public.invoices (subscription_id);
CREATE INDEX IF NOT EXISTS idx_invoices_user   ON public.invoices (user_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON public.invoices (status);
CREATE INDEX IF NOT EXISTS idx_invoices_txn    ON public.invoices (transaction_id);
