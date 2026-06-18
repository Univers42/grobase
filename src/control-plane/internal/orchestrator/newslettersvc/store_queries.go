package newslettersvc

import "context"

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
