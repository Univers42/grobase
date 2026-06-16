package newslettersvc

import (
	"context"
	"errors"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Sentinel errors → HTTP status in the handler layer (parity with the Nest
// ConflictException / NotFoundException).
var (
	errConflict = errors.New("already subscribed")
	errNotFound = errors.New("invalid token")
)

type store struct {
	pg *shared.Postgres
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

// confirm flips confirmed_at for an unconfirmed token; returns false if no row
// matched (invalid or already-used token).
func (s *store) confirm(ctx context.Context, token string) (bool, error) {
	return s.affected(ctx,
		`UPDATE newsletter.subscriber SET confirmed_at = now(), is_active = true
		 WHERE token = $1 AND confirmed_at IS NULL RETURNING id`, token)
}

func (s *store) unsubscribe(ctx context.Context, token string) (bool, error) {
	return s.affected(ctx,
		`UPDATE newsletter.subscriber SET is_active = false, unsubscribed_at = now()
		 WHERE token = $1 RETURNING id`, token)
}

func (s *store) listSubscribers(ctx context.Context, limit, offset int) ([]SubscriberSummary, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, email, first_name, confirmed_at, created_at
		 FROM newsletter.subscriber WHERE is_active = true ORDER BY created_at DESC LIMIT $1 OFFSET $2`,
		limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SubscriberSummary{}
	for rows.Next() {
		var s SubscriberSummary
		if err := rows.Scan(&s.ID, &s.Email, &s.FirstName, &s.ConfirmedAt, &s.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (s *store) stats(ctx context.Context) (Stats, error) {
	var st Stats
	rows, err := s.pg.AdminQuery(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE is_active = true),
		       COUNT(*) FILTER (WHERE confirmed_at IS NOT NULL AND is_active = true)
		FROM newsletter.subscriber`)
	if err != nil {
		return st, err
	}
	defer rows.Close()
	if rows.Next() {
		if err := rows.Scan(&st.Total, &st.Active, &st.Confirmed); err != nil {
			return st, err
		}
	}
	return st, rows.Err()
}

func (s *store) confirmedEmails(ctx context.Context) ([]Recipient, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT email, token FROM newsletter.subscriber WHERE is_active = true AND confirmed_at IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Recipient{}
	for rows.Next() {
		var r Recipient
		if err := rows.Scan(&r.Email, &r.Token); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *store) logSend(ctx context.Context, subject string, count int, sentBy *string) error {
	return s.pg.AdminExec(ctx,
		`INSERT INTO newsletter.send_log (subject, recipient_count, sent_by) VALUES ($1, $2, $3)`,
		subject, count, sentBy)
}

func (s *store) history(ctx context.Context, limit int) ([]SendLog, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, subject, recipient_count, sent_at, sent_by
		 FROM newsletter.send_log ORDER BY sent_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SendLog{}
	for rows.Next() {
		var l SendLog
		if err := rows.Scan(&l.ID, &l.Subject, &l.RecipientCount, &l.SentAt, &l.SentBy); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// affected runs a `... RETURNING id` statement and reports whether a row matched.
func (s *store) affected(ctx context.Context, sql string, args ...any) (bool, error) {
	rows, err := s.pg.AdminQuery(ctx, sql, args...)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	matched := rows.Next()
	return matched, rows.Err()
}
