/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_query.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sessionsvc

import (
	"context"
	"time"
)

// Stats mirrors the admin/stats aggregate row.
type Stats struct {
	Total       int64 `json:"total"`
	Active      int64 `json:"active"`
	Expired     int64 `json:"expired"`
	ActiveUsers int64 `json:"active_users"`
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
