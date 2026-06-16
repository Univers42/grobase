package gdprsvc

import (
	"context"
	"errors"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Sentinel errors → HTTP status in the handler layer (parity with the Nest
// NotFoundException / ConflictException / BadRequestException).
var (
	errNotFound  = errors.New("not found")
	errConflict  = errors.New("conflict")
	errCompleted = errors.New("already completed")
)

type store struct {
	pg *shared.Postgres
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

func scanConsent(s scanner, c *Consent) error {
	return s.Scan(&c.ID, &c.UserID, &c.ConsentType, &c.IsGranted, &c.GrantedAt, &c.RevokedAt, &c.CreatedAt)
}

func scanDeletion(s scanner, d *DeletionRequest) error {
	return s.Scan(&d.ID, &d.UserID, &d.Reason, &d.Status, &d.AdminNote, &d.ProcessedBy,
		&d.RequestedAt, &d.ProcessedAt)
}

const consentCols = `id, user_id, consent_type, is_granted, granted_at, revoked_at, created_at`
const deletionCols = `id, user_id, reason, status, admin_note, processed_by, requested_at, processed_at`

// bootstrap ensures both gdpr tables + their owner RLS policies (parity with the
// two onModuleInit hooks, merged into one idempotent migration).
func (s *store) bootstrap(ctx context.Context) error {
	return s.pg.AdminExec(ctx, `
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
	`)
}

/* ─────── consent ─────── */

func (s *store) userConsents(ctx context.Context, userID string) ([]Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+consentCols+` FROM gdpr.user_consent WHERE user_id = $1 ORDER BY consent_type ASC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Consent{}
	for rows.Next() {
		var c Consent
		if err := scanConsent(rows, &c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *store) userConsent(ctx context.Context, userID, ctype string) (*Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+consentCols+` FROM gdpr.user_consent WHERE user_id = $1 AND consent_type = $2 LIMIT 1`,
		userID, ctype)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	var c Consent
	if err := scanConsent(rows, &c); err != nil {
		return nil, err
	}
	return &c, rows.Err()
}

func (s *store) setConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error) {
	now := time.Now()
	var grantedAt, revokedAt *time.Time
	if consented {
		grantedAt = &now
	} else {
		revokedAt = &now
	}
	rows, err := s.pg.AdminQuery(ctx,
		`INSERT INTO gdpr.user_consent (user_id, consent_type, is_granted, granted_at, revoked_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (user_id, consent_type) DO UPDATE SET
		   is_granted = EXCLUDED.is_granted,
		   granted_at = CASE WHEN EXCLUDED.is_granted THEN now() ELSE gdpr.user_consent.granted_at END,
		   revoked_at = CASE WHEN NOT EXCLUDED.is_granted THEN now() ELSE NULL END
		 RETURNING `+consentCols,
		userID, ctype, consented, grantedAt, revokedAt)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var c Consent
	if err := scanConsent(rows, &c); err != nil {
		return nil, err
	}
	return &c, rows.Err()
}

func (s *store) updateConsent(ctx context.Context, userID, ctype string, consented bool) (*Consent, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.user_consent
		 SET is_granted = $3,
		     granted_at = CASE WHEN $3 THEN now() ELSE granted_at END,
		     revoked_at = CASE WHEN NOT $3 THEN now() ELSE NULL END
		 WHERE user_id = $1 AND consent_type = $2 RETURNING `+consentCols,
		userID, ctype, consented)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var c Consent
	if err := scanConsent(rows, &c); err != nil {
		return nil, err
	}
	return &c, rows.Err()
}

func (s *store) withdrawNonEssential(ctx context.Context, userID string) (int, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.user_consent SET is_granted = false, revoked_at = now()
		 WHERE user_id = $1 AND consent_type != 'essential' AND is_granted = true RETURNING id`, userID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		n++
	}
	return n, rows.Err()
}

/* ─────── deletion ─────── */

func (s *store) pendingExists(ctx context.Context, userID string) (bool, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id FROM gdpr.data_deletion_request
		 WHERE user_id = $1 AND status IN ('pending','in_progress') LIMIT 1`, userID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	exists := rows.Next()
	return exists, rows.Err()
}

func (s *store) createDeletion(ctx context.Context, userID string, reason *string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`INSERT INTO gdpr.data_deletion_request (user_id, reason) VALUES ($1, $2) RETURNING `+deletionCols,
		userID, reason)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}

func (s *store) myRequest(ctx context.Context, userID string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+deletionCols+` FROM gdpr.data_deletion_request
		 WHERE user_id = $1 ORDER BY requested_at DESC LIMIT 1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}

func (s *store) cancelRequest(ctx context.Context, userID string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`DELETE FROM gdpr.data_deletion_request WHERE user_id = $1 AND status = 'pending'
		 RETURNING `+deletionCols, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}

func (s *store) allRequests(ctx context.Context, status string) ([]DeletionRequest, error) {
	q := `SELECT ` + deletionCols + ` FROM gdpr.data_deletion_request`
	args := []any{}
	if status != "" {
		q += ` WHERE status = $1`
		args = append(args, status)
	}
	q += ` ORDER BY requested_at DESC`
	rows, err := s.pg.AdminQuery(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DeletionRequest{}
	for rows.Next() {
		var d DeletionRequest
		if err := scanDeletion(rows, &d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *store) getRequest(ctx context.Context, id string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+deletionCols+` FROM gdpr.data_deletion_request WHERE id = $1`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}

func (s *store) updateRequest(ctx context.Context, id, status, adminID string, note *string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.data_deletion_request
		 SET status = $2, processed_by = $3, processed_at = now(), admin_note = $4
		 WHERE id = $1 RETURNING `+deletionCols, id, status, adminID, note)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var d DeletionRequest
	if err := scanDeletion(rows, &d); err != nil {
		return nil, err
	}
	return &d, rows.Err()
}
