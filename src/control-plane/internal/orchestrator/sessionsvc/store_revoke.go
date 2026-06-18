package sessionsvc

import "context"

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
