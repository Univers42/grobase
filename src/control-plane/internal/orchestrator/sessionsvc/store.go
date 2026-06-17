package sessionsvc

import (
	"context"
	"errors"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Sentinel errors map to HTTP status in the handler layer (parity with the Nest
// NotFoundException / ForbiddenException the TS service threw).
var (
	errNotFound  = errors.New("session not found")
	errForbidden = errors.New("not your session")
)

// store is the Postgres-backed session repository — a faithful port of the
// NestJS SessionService DB methods over shared.Postgres.
type store struct {
	pg      *shared.Postgres
	ttlDays int
}

// Session is the row projection. Nullable columns are pointers; UserID /
// SessionToken / UpdatedAt / IsCurrent are omitempty so each query's SELECT set
// renders the same JSON shape the TS service returned.
type Session struct {
	ID           string     `json:"id"`
	UserID       string     `json:"user_id,omitempty"`
	SessionToken string     `json:"session_token,omitempty"`
	DeviceInfo   *string    `json:"device_info"`
	IPAddress    *string    `json:"ip_address"`
	ExpiresAt    time.Time  `json:"expires_at"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    *time.Time `json:"updated_at,omitempty"`
	IsCurrent    *bool      `json:"isCurrent,omitempty"`
}

// bootstrap reproduces onModuleInit: schema + table + indexes + RLS policy.
// Idempotent (IF NOT EXISTS throughout), so re-running on every boot is safe.
func (s *store) bootstrap(ctx context.Context) error {
	return s.pg.AdminExec(ctx, `
		CREATE SCHEMA IF NOT EXISTS session;

		CREATE TABLE IF NOT EXISTS session.user_sessions (
			id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			user_id       TEXT NOT NULL,
			session_token TEXT NOT NULL UNIQUE,
			device_info   TEXT,
			ip_address    TEXT,
			expires_at    TIMESTAMPTZ NOT NULL,
			created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

		CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON session.user_sessions(user_id);
		CREATE INDEX IF NOT EXISTS idx_sessions_token ON session.user_sessions(session_token);
		CREATE INDEX IF NOT EXISTS idx_sessions_expires ON session.user_sessions(expires_at);

		ALTER TABLE session.user_sessions ENABLE ROW LEVEL SECURITY;

		DO $$ BEGIN
			IF NOT EXISTS (
				SELECT 1 FROM pg_policies WHERE tablename = 'user_sessions'
				  AND schemaname = 'session' AND policyname = 'user_own_sessions'
			) THEN
				CREATE POLICY user_own_sessions ON session.user_sessions
					FOR ALL USING (user_id = auth.current_user_id()::text);
			END IF;
		END $$;
	`)
}

func nullable(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

func (s *store) create(ctx context.Context, userID, token, device, ip string) (*Session, error) {
	expires := time.Now().AddDate(0, 0, s.ttlDays)
	rows, err := s.pg.AdminQuery(ctx,
		`INSERT INTO session.user_sessions (user_id, session_token, device_info, ip_address, expires_at)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, user_id, session_token, device_info, ip_address, expires_at, created_at`,
		userID, token, nullable(device), nullable(ip), expires)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var out Session
	if err := rows.Scan(&out.ID, &out.UserID, &out.SessionToken, &out.DeviceInfo,
		&out.IPAddress, &out.ExpiresAt, &out.CreatedAt); err != nil {
		return nil, err
	}
	return &out, rows.Err()
}

func (s *store) byToken(ctx context.Context, token string) (*Session, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, user_id, session_token, device_info, ip_address, expires_at, created_at, updated_at
		 FROM session.user_sessions WHERE session_token = $1`, token)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, nil
	}
	var out Session
	if err := rows.Scan(&out.ID, &out.UserID, &out.SessionToken, &out.DeviceInfo,
		&out.IPAddress, &out.ExpiresAt, &out.CreatedAt, &out.UpdatedAt); err != nil {
		return nil, err
	}
	return &out, rows.Err()
}

// userSessions returns the caller's sessions newest-first, each flagged
// isCurrent. The TS path used a tenant RLS query; the explicit user_id filter
// here returns the identical row set without per-query GUC plumbing.
func (s *store) userSessions(ctx context.Context, userID, currentToken string) ([]Session, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, session_token, device_info, ip_address, expires_at, created_at, updated_at
		 FROM session.user_sessions WHERE user_id = $1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		var s Session
		if err := rows.Scan(&s.ID, &s.SessionToken, &s.DeviceInfo, &s.IPAddress,
			&s.ExpiresAt, &s.CreatedAt, &s.UpdatedAt); err != nil {
			return nil, err
		}
		cur := currentToken != "" && s.SessionToken == currentToken
		s.IsCurrent = &cur
		out = append(out, s)
	}
	return out, rows.Err()
}

func (s *store) validate(ctx context.Context, token string) (bool, *Session, error) {
	sess, err := s.byToken(ctx, token)
	if err != nil || sess == nil {
		return false, nil, err
	}
	if sess.ExpiresAt.Before(time.Now()) {
		if err := s.pg.AdminExec(ctx, `DELETE FROM session.user_sessions WHERE id = $1`, sess.ID); err != nil {
			return false, nil, err
		}
		return false, nil, nil
	}
	return true, sess, nil
}

func (s *store) revoke(ctx context.Context, id, userID string) error {
	rows, err := s.pg.AdminQuery(ctx, `SELECT user_id FROM session.user_sessions WHERE id = $1`, id)
	if err != nil {
		return err
	}
	owner := ""
	found := rows.Next()
	if found {
		_ = rows.Scan(&owner)
	}
	rows.Close()
	if !found {
		return errNotFound
	}
	if owner != userID {
		return errForbidden
	}
	return s.pg.AdminExec(ctx, `DELETE FROM session.user_sessions WHERE id = $1`, id)
}

func (s *store) revokeAll(ctx context.Context, userID, except string) (int, error) {
	if except != "" {
		return s.countDelete(ctx,
			`DELETE FROM session.user_sessions WHERE user_id = $1 AND session_token != $2 RETURNING id`,
			userID, except)
	}
	return s.countDelete(ctx, `DELETE FROM session.user_sessions WHERE user_id = $1 RETURNING id`, userID)
}

func (s *store) extend(ctx context.Context, token string, days int) (*Session, error) {
	if days <= 0 {
		days = s.ttlDays
	}
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE session.user_sessions
		 SET expires_at = NOW() + INTERVAL '1 day' * $2, updated_at = NOW()
		 WHERE session_token = $1 RETURNING id, expires_at`, token, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var out Session
	if err := rows.Scan(&out.ID, &out.ExpiresAt); err != nil {
		return nil, err
	}
	return &out, rows.Err()
}

func (s *store) activeSessions(ctx context.Context, userID string) ([]Session, error) {
	q := `SELECT id, user_id, session_token, device_info, ip_address, expires_at, created_at, updated_at
	      FROM session.user_sessions WHERE expires_at > NOW()`
	args := []any{}
	if userID != "" {
		q += ` AND user_id = $1`
		args = append(args, userID)
	}
	q += ` ORDER BY created_at DESC`
	rows, err := s.pg.AdminQuery(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		var s Session
		if err := rows.Scan(&s.ID, &s.UserID, &s.SessionToken, &s.DeviceInfo, &s.IPAddress,
			&s.ExpiresAt, &s.CreatedAt, &s.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (s *store) cleanupExpired(ctx context.Context) (int, error) {
	return s.countDelete(ctx, `DELETE FROM session.user_sessions WHERE expires_at < NOW() RETURNING id`)
}

func (s *store) forceRevoke(ctx context.Context, id string) error {
	n, err := s.countDelete(ctx, `DELETE FROM session.user_sessions WHERE id = $1 RETURNING id`, id)
	if err != nil {
		return err
	}
	if n == 0 {
		return errNotFound
	}
	return nil
}

func (s *store) forceRevokeAll(ctx context.Context, userID string) (int, error) {
	return s.countDelete(ctx, `DELETE FROM session.user_sessions WHERE user_id = $1 RETURNING id`, userID)
}

// Stats mirrors the admin/stats aggregate row.
type Stats struct {
	Total       int64 `json:"total"`
	Active      int64 `json:"active"`
	Expired     int64 `json:"expired"`
	ActiveUsers int64 `json:"active_users"`
}

func (s *store) stats(ctx context.Context) (Stats, error) {
	var st Stats
	rows, err := s.pg.AdminQuery(ctx, `
		SELECT COUNT(*) AS total,
		       COUNT(*) FILTER (WHERE expires_at > NOW()) AS active,
		       COUNT(*) FILTER (WHERE expires_at <= NOW()) AS expired,
		       COUNT(DISTINCT user_id) FILTER (WHERE expires_at > NOW()) AS active_users
		FROM session.user_sessions`)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(&st.Total, &st.Active, &st.Expired, &st.ActiveUsers); err != nil {
			return st, err
		}
	}
	return st, rows.Err()
}

// countDelete runs a `... RETURNING id` delete and counts affected rows.
func (s *store) countDelete(ctx context.Context, sql string, args ...any) (int, error) {
	rows, err := s.pg.AdminQuery(ctx, sql, args...)
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
