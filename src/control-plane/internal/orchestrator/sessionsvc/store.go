package sessionsvc

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// sessionsvcErr is a constant error type — the sentinel values below are true
// consts (no package-level var). Equal-valued instances compare ==, so
// errors.Is keeps working, and they wrap with %w like any error.
// Sentinel errors map to HTTP status in the handler layer (parity with the Nest
// NotFoundException / ForbiddenException the TS service threw).
const (
	errNotFound  sessionsvcErr = "session not found"
	errForbidden sessionsvcErr = "not your session"
)

// store is the Postgres-backed session repository — a faithful port of the
// NestJS SessionService DB methods over pg.Postgres.
type store struct {
	pg      *pg.Postgres
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

// bootstrapSQL reproduces onModuleInit: schema + table + indexes + RLS policy.
// Idempotent (IF NOT EXISTS throughout), so re-running on every boot is safe.
const bootstrapSQL = `
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
`

func (s *store) bootstrap(ctx context.Context) error {
	return s.pg.AdminExec(ctx, bootstrapSQL)
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
