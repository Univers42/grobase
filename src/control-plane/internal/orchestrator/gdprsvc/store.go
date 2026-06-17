package gdprsvc

import (
	"context"
	"errors"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// Sentinel errors → HTTP status in the handler layer (parity with the Nest
// NotFoundException / ConflictException / BadRequestException).
var (
	errNotFound  = errors.New("not found")
	errConflict  = errors.New("conflict")
	errCompleted = errors.New("already completed")
)

type store struct {
	pg *pg.Postgres
}

// Consent is a gdpr.user_consent row.
type Consent struct {
	ID          int64      `json:"id"`
	UserID      string     `json:"user_id"`
	ConsentType string     `json:"consent_type"`
	IsGranted   bool       `json:"is_granted"`
	GrantedAt   *time.Time `json:"granted_at"`
	RevokedAt   *time.Time `json:"revoked_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

// DeletionRequest is a gdpr.data_deletion_request row.
type DeletionRequest struct {
	ID          int64      `json:"id"`
	UserID      string     `json:"user_id"`
	Reason      *string    `json:"reason"`
	Status      string     `json:"status"`
	AdminNote   *string    `json:"admin_note"`
	ProcessedBy *string    `json:"processed_by"`
	RequestedAt time.Time  `json:"requested_at"`
	ProcessedAt *time.Time `json:"processed_at"`
}

type scanner interface{ Scan(...any) error }

// rowSet is the subset of pgx.Rows the scan helpers consume.
type rowSet interface {
	Next() bool
	Err() error
	Scan(...any) error
	Close()
}

func scanConsent(s scanner, c *Consent) error {
	return s.Scan(&c.ID, &c.UserID, &c.ConsentType, &c.IsGranted, &c.GrantedAt, &c.RevokedAt, &c.CreatedAt)
}

func scanDeletion(s scanner, d *DeletionRequest) error {
	return s.Scan(&d.ID, &d.UserID, &d.Reason, &d.Status, &d.AdminNote, &d.ProcessedBy,
		&d.RequestedAt, &d.ProcessedAt)
}

// firstConsent scans the first row into a *Consent, returning notFound when the
// result is empty (notFound==nil ⇒ empty yields (nil, rows.Err())).
func firstConsent(rows rowSet, notFound error) (*Consent, error) {
	defer rows.Close()
	if !rows.Next() {
		if notFound != nil {
			return nil, notFound
		}
		return nil, rows.Err()
	}
	var c Consent
	if err := scanConsent(rows, &c); err != nil {
		return nil, err
	}
	return &c, rows.Err()
}

// firstDeletion scans the first row into a *DeletionRequest, returning notFound
// when the result is empty (notFound==nil ⇒ empty yields (nil, rows.Err())).
func firstDeletion(rows rowSet, notFound error) (*DeletionRequest, error) {
	defer rows.Close()
	if !rows.Next() {
		if notFound != nil {
			return nil, notFound
		}
		return nil, rows.Err()
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}

const consentCols = `id, user_id, consent_type, is_granted, granted_at, revoked_at, created_at`
const deletionCols = `id, user_id, reason, status, admin_note, processed_by, requested_at, processed_at`

// bootstrapSQL ensures both gdpr tables + their owner RLS policies (parity with
// the two onModuleInit hooks, merged into one idempotent migration).
const bootstrapSQL = `
	CREATE SCHEMA IF NOT EXISTS gdpr;

	CREATE TABLE IF NOT EXISTS gdpr.user_consent (
		id            BIGSERIAL PRIMARY KEY,
		user_id       TEXT NOT NULL,
		consent_type  TEXT NOT NULL,
		is_granted    BOOLEAN NOT NULL DEFAULT false,
		granted_at    TIMESTAMPTZ,
		revoked_at    TIMESTAMPTZ,
		created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
		UNIQUE(user_id, consent_type)
	);
	ALTER TABLE gdpr.user_consent ENABLE ROW LEVEL SECURITY;
	DO $$ BEGIN
		IF NOT EXISTS (SELECT 1 FROM pg_policies
		  WHERE schemaname='gdpr' AND tablename='user_consent' AND policyname='consent_owner') THEN
			CREATE POLICY consent_owner ON gdpr.user_consent
				FOR ALL USING (user_id = auth.current_user_id()::text);
		END IF;
	END $$;

	CREATE TABLE IF NOT EXISTS gdpr.data_deletion_request (
		id            BIGSERIAL PRIMARY KEY,
		user_id       TEXT NOT NULL,
		reason        TEXT,
		status        TEXT NOT NULL DEFAULT 'pending'
		              CHECK (status IN ('pending','in_progress','completed','rejected')),
		admin_note    TEXT,
		processed_by  TEXT,
		requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
		processed_at  TIMESTAMPTZ
	);
	ALTER TABLE gdpr.data_deletion_request ENABLE ROW LEVEL SECURITY;
	DO $$ BEGIN
		IF NOT EXISTS (SELECT 1 FROM pg_policies
		  WHERE schemaname='gdpr' AND tablename='data_deletion_request' AND policyname='deletion_owner') THEN
			CREATE POLICY deletion_owner ON gdpr.data_deletion_request
				FOR ALL USING (user_id = auth.current_user_id()::text);
		END IF;
	END $$;
`

func (s *store) bootstrap(ctx context.Context) error {
	return s.pg.AdminExec(ctx, bootstrapSQL)
}
