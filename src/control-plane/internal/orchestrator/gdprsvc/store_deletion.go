package gdprsvc

import "context"

/* ─────── deletion (user-scoped) ─────── */

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
	return firstDeletion(rows, errNotFound)
}

func (s *store) myRequest(ctx context.Context, userID string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT `+deletionCols+` FROM gdpr.data_deletion_request
		 WHERE user_id = $1 ORDER BY requested_at DESC LIMIT 1`, userID)
	if err != nil {
		return nil, err
	}
	return firstDeletion(rows, nil)
}

func (s *store) cancelRequest(ctx context.Context, userID string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`DELETE FROM gdpr.data_deletion_request WHERE user_id = $1 AND status = 'pending'
		 RETURNING `+deletionCols, userID)
	if err != nil {
		return nil, err
	}
	return firstDeletion(rows, errNotFound)
}
