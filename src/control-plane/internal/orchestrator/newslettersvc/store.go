package newslettersvc

import (
	"context"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// newslettersvcErr is a constant error type — the sentinel values below are true
// consts (no package-level var). Equal-valued instances compare ==, so
// errors.Is keeps working, and they wrap with %w like any error.
// Sentinel errors → HTTP status in the handler layer (parity with the Nest
// ConflictException / NotFoundException).
const (
	errConflict newslettersvcErr = "already subscribed"
	errNotFound newslettersvcErr = "invalid token"
)

type store struct {
	pg *pg.Postgres
}

// Subscriber is the full newsletter.subscriber row (RETURNING *).
type Subscriber struct {
	ID             int64      `json:"id,string"`
	Email          string     `json:"email"`
	FirstName      *string    `json:"first_name"`
	Token          string     `json:"token"`
	IsActive       bool       `json:"is_active"`
	ConfirmedAt    *time.Time `json:"confirmed_at"`
	UnsubscribedAt *time.Time `json:"unsubscribed_at"`
	CreatedAt      time.Time  `json:"created_at"`
}

// SubscriberSummary is the redacted admin-list projection (no token).
type SubscriberSummary struct {
	ID          int64      `json:"id,string"`
	Email       string     `json:"email"`
	FirstName   *string    `json:"first_name"`
	ConfirmedAt *time.Time `json:"confirmed_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

// Stats mirrors the admin/stats counts.
type Stats struct {
	Total     int `json:"total"`
	Active    int `json:"active"`
	Confirmed int `json:"confirmed"`
}

// Recipient is a confirmed subscriber target for a campaign send.
type Recipient struct {
	Email string `json:"email"`
	Token string `json:"token"`
}

// SendLog is one newsletter.send_log row (history).
type SendLog struct {
	ID             int64     `json:"id,string"`
	Subject        string    `json:"subject"`
	RecipientCount int       `json:"recipient_count"`
	SentAt         time.Time `json:"sent_at"`
	SentBy         *string   `json:"sent_by"`
}

func (s *store) bootstrap(ctx context.Context) error {
	return s.pg.AdminExec(ctx, `
		CREATE SCHEMA IF NOT EXISTS newsletter;

		CREATE TABLE IF NOT EXISTS newsletter.subscriber (
			id              BIGSERIAL PRIMARY KEY,
			email           TEXT NOT NULL UNIQUE,
			first_name      TEXT,
			token           TEXT NOT NULL UNIQUE,
			is_active       BOOLEAN NOT NULL DEFAULT true,
			confirmed_at    TIMESTAMPTZ,
			unsubscribed_at TIMESTAMPTZ,
			created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
		);

		CREATE TABLE IF NOT EXISTS newsletter.send_log (
			id              BIGSERIAL PRIMARY KEY,
			subject         TEXT NOT NULL,
			recipient_count INT NOT NULL DEFAULT 0,
			sent_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
			sent_by         TEXT
		);
	`)
}

// existing returns (id, is_active, first_name) for an email, or found=false.
func (s *store) existing(ctx context.Context, email string) (id int64, active bool, first *string, found bool, err error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, is_active, first_name FROM newsletter.subscriber WHERE email = $1 LIMIT 1`, email)
	if err != nil {
		return 0, false, nil, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return 0, false, nil, false, rows.Err()
	}
	if err := rows.Scan(&id, &active, &first); err != nil {
		return 0, false, nil, false, err
	}
	return id, active, first, true, rows.Err()
}

func scanSubscriber(rows interface {
	Scan(...any) error
}, out *Subscriber) error {
	return rows.Scan(&out.ID, &out.Email, &out.FirstName, &out.Token, &out.IsActive,
		&out.ConfirmedAt, &out.UnsubscribedAt, &out.CreatedAt)
}

func (s *store) reactivate(ctx context.Context, id int64, token string, firstName *string) (*Subscriber, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE newsletter.subscriber
		 SET is_active = true, unsubscribed_at = NULL, token = $2,
		     first_name = COALESCE($3, first_name)
		 WHERE id = $1 RETURNING id, email, first_name, token, is_active, confirmed_at, unsubscribed_at, created_at`,
		id, token, firstName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var out Subscriber
	if err := scanSubscriber(rows, &out); err != nil {
		return nil, err
	}
	return &out, rows.Err()
}

func (s *store) insert(ctx context.Context, email string, firstName *string, token string) (*Subscriber, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`INSERT INTO newsletter.subscriber (email, first_name, token) VALUES ($1, $2, $3)
		 RETURNING id, email, first_name, token, is_active, confirmed_at, unsubscribed_at, created_at`,
		email, firstName, token)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, errNotFound
	}
	var out Subscriber
	if err := scanSubscriber(rows, &out); err != nil {
		return nil, err
	}
	return &out, rows.Err()
}
